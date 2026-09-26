import Foundation

// MARK: - Соединение

/// TCP-соединение с агентом отладки Mono. Чтение — на своём потоке,
/// блокирующими вызовами: пакеты идут подряд, и проще всего читать их
/// по одному ровно по длине из заголовка. Ответы находят ждущих по номеру,
/// события уходят в `onEvents`.
final class SDBConnection: @unchecked Sendable {
    private var socket: Int32 = -1
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var nextID: Int32 = 1
    private var pending: [Int32: CheckedContinuation<[UInt8], Error>] = [:]
    private var closed = false

    private(set) var version = SDBVersion(major: 2, minor: 0)
    private(set) var runtimeVersion = SDBVersion(major: 2, minor: 0)
    private(set) var runtimeName = ""

    var onEvents: (@Sendable (SDB.SuspendPolicy, [SDBEvent]) -> Void)?
    var onClose: (@Sendable () -> Void)?

    deinit { shutdown() }

    // MARK: Подключение

    /// Сокет с таймаутом на connect: у закрытого порта ответ приходит сразу,
    /// а у фаервола — никогда, и ждать системные 75 секунд незачем.
    func connect(host: String, port: Int, timeout: TimeInterval = 3) async throws {
        try await Task.detached { [self] in try self.openSocket(host: host, port: port, timeout: timeout) }.value
        let reader = Thread { [weak self] in self?.readLoop() }
        reader.name = "pilot.sdb.reader"
        reader.start()

        var versionReply = SDBReader(try await send(.vm, SDB.VM.version.rawValue, timeout: 10))
        runtimeName = try versionReply.string()
        runtimeVersion = SDBVersion(major: Int(try versionReply.int()), minor: Int(try versionReply.int()))
        guard runtimeVersion.major == 2 else {
            throw SDBError.connect("Протокол отладчика Mono \(runtimeVersion) — Pilot знает только 2.x")
        }
        let (announce, effective) = SDBVersion.negotiate(runtime: runtimeVersion)
        version = effective
        var w = SDBWriter()
        w.int(announce.major); w.int(announce.minor)
        // Совсем старые рантаймы этой команды не знают — тогда работаем
        // на их собственной версии.
        do { _ = try await send(.vm, SDB.VM.setProtocolVersion.rawValue, w) } catch let error as SDBError where error.code != nil {
            version = runtimeVersion
        }
    }

    private func openSocket(host: String, port: Int, timeout: TimeInterval) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SDBError.connect("Не создать сокет: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(fd)
            throw SDBError.connect("Адрес \(host) не IPv4")
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var noDelay: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                let reason = String(cString: strerror(errno))
                close(fd)
                throw SDBError.connect("Порт \(port) не отвечает: \(reason)")
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            if ready <= 0 || error != 0 {
                close(fd)
                throw SDBError.connect(ready <= 0
                    ? "Порт \(port) не ответил за \(Int(timeout)) с"
                    : "Порт \(port) не отвечает: \(String(cString: strerror(error)))")
            }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        // Рукопожатие: агент шлёт строку первым, мы отвечаем ей же.
        var tv = timeval(tv_sec: Int(max(timeout, 5)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let greeting = Self.readExactly(fd, SDB.handshake.count), greeting == SDB.handshake else {
            close(fd)
            throw SDBError.connect("Порт \(port) открыт, но это не отладчик Mono — или к нему уже подключён другой отладчик")
        }
        guard Self.writeAll(fd, SDB.handshake) else {
            close(fd)
            throw SDBError.connect("Рукопожатие с Mono оборвалось")
        }
        var forever = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        lock.lock(); socket = fd; lock.unlock()
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress! + got, count - got)
            }
            if n > 0 { got += n; continue }
            if n < 0, errno == EINTR { continue }
            return nil
        }
        return buffer
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + sent, bytes.count - sent)
            }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    // MARK: Команды

    func send(_ set: SDB.CommandSet, _ command: UInt8, _ body: SDBWriter = SDBWriter(),
              timeout: TimeInterval = 15) async throws -> [UInt8] {
        let (id, fd) = try lock.withLock { () throws -> (Int32, Int32) in
            guard !closed, socket >= 0 else { throw SDBError.disconnected }
            defer { nextID &+= 1 }
            return (nextID, socket)
        }
        let packet = SDBWriter.packet(id: id, set: set.rawValue, command: command, body: body.bytes)
        let name = "\(set)/\(command)"

        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.fail(id, SDBError.timeout(name))
        }
        defer { timer.cancel() }

        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            lock.withLock { pending[id] = continuation }
            let ok = writeLock.withLock { Self.writeAll(fd, packet) }
            if !ok { fail(id, SDBError.disconnected) }
        }
        var reader = SDBReader(reply, offset: 9)
        let code = try reader.short()
        guard code == 0 else { throw SDBError.remote(command: name, code: code) }
        return Array(reply[SDB.headerLength...])
    }

    private func fail(_ id: Int32, _ error: Error) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(throwing: error)
    }

    // MARK: Чтение

    private func readLoop() {
        let fd = lock.withLock { socket }
        while true {
            guard let header = Self.readExactly(fd, SDB.headerLength) else { break }
            var r = SDBReader(header)
            guard let length = try? Int(r.int()), length >= SDB.headerLength else { break }
            var packet = header
            if length > SDB.headerLength {
                guard let body = Self.readExactly(fd, length - SDB.headerLength) else { break }
                packet += body
            }
            let id = (try? r.int()) ?? 0
            let flags = (try? r.byte()) ?? 0
            if flags == SDB.replyFlag {
                let continuation = lock.withLock { pending.removeValue(forKey: id) }
                continuation?.resume(returning: packet)
                continue
            }
            let set = (try? r.byte()) ?? 0
            let command = (try? r.byte()) ?? 0
            guard set == SDB.CommandSet.event.rawValue, command == SDB.compositeEvent else { continue }
            var body = SDBReader(packet, offset: SDB.headerLength)
            if let (policy, events) = try? SDBEvent.parseComposite(&body, version: version) {
                onEvents?(policy, events)
            }
        }
        shutdown()
    }

    // MARK: Закрытие

    func shutdown() {
        let (fd, waiting, wasClosed) = lock.withLock { () -> (Int32, [CheckedContinuation<[UInt8], Error>], Bool) in
            let was = closed
            closed = true
            let fd = socket
            socket = -1
            let all = Array(pending.values)
            pending.removeAll()
            return (fd, all, was)
        }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        for continuation in waiting { continuation.resume(throwing: SDBError.disconnected) }
        if !wasClosed { onClose?() }
    }

    var isClosed: Bool { lock.withLock { closed } }
}
