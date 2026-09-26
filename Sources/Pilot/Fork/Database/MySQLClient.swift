import Foundation
import CryptoKit

/// Клиент MySQL/MariaDB на голом протоколе — ровно столько, сколько нужно
/// обозревателю базы: вход по паролю, текстовые запросы, несколько
/// результатов подряд. Без TLS и без подготовленных запросов: это окно для
/// локальной марии в Docker и для тестовых стендов, а не драйвер.
///
/// Соединение блокирующее и не потокобезопасное: всё, что с ним делают,
/// идёт через `MySQLSession`, у которой своя последовательная очередь.
final class MySQLConnection: @unchecked Sendable {
    struct Options: Equatable, Codable {
        var host = "127.0.0.1"
        var port = 3306
        var user = "root"
        var password = ""
        var database = ""
    }

    struct Column {
        var name: String
        var table: String
        var type: UInt8
        var charset: UInt16
        var flags: UInt16

        var isNumeric: Bool { [0, 1, 2, 3, 4, 5, 8, 9, 13, 246].contains(type) }
        var isBinary: Bool { charset == 63 && ![7, 10, 11, 12, 14].contains(type) && !isNumeric }
    }

    /// Один ответ сервера: выборка или «затронуто N строк».
    struct Result {
        var columns: [Column] = []
        /// Строки выборки; `nil` в ячейке — NULL.
        var rows: [[String?]] = []
        /// Строк пришло больше, чем держим: остальные прочитаны и отброшены.
        var totalRows = 0
        var affectedRows: UInt64 = 0
        var lastInsertID: UInt64 = 0
        var warnings: UInt16 = 0
        var info = ""
        var isResultSet: Bool { !columns.isEmpty }
    }

    struct ServerError: LocalizedError {
        var code: UInt16
        var state: String
        var message: String
        var errorDescription: String? { "\(code) (\(state)): \(message)" }
    }

    struct ProtocolError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Больше строк одной выборки в памяти не держим.
    static let rowLimit = 10_000

    private(set) var serverVersion = ""
    private(set) var connectionID: UInt32 = 0
    private var fd: Int32 = -1
    private var sequence: UInt8 = 0
    private var buffer: [UInt8] = []
    private var bufferStart = 0

    deinit { close() }

    var isOpen: Bool { fd >= 0 }

    func close() {
        guard fd >= 0 else { return }
        // COM_QUIT — вежливо; ответа на него нет.
        sequence = 0
        try? writePacket([0x01])
        Darwin.close(fd)
        fd = -1
    }

    /// Разрывает соединение из другого потока: ждущее чтение сразу вернётся с ошибкой.
    func abort() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    // MARK: - Подключение

    func connect(_ options: Options, timeout: TimeInterval = 8) throws {
        close()
        fd = try Self.openSocket(host: options.host, port: options.port, timeout: timeout)
        buffer = []
        bufferStart = 0

        let hello = try readPacket()
        if hello.first == 0xFF { throw Self.parseError(hello) }
        let handshake = try Handshake(hello)
        serverVersion = handshake.serverVersion
        connectionID = handshake.connectionID

        var caps: UInt32 = Cap.longPassword | Cap.foundRows | Cap.longFlag | Cap.protocol41 | Cap.transactions
            | Cap.secureConnection | Cap.multiStatements | Cap.multiResults | Cap.pluginAuth
        if !options.database.isEmpty { caps |= Cap.connectWithDB }
        caps &= handshake.capabilities | Cap.connectWithDB

        let plugin = handshake.authPlugin.isEmpty ? "mysql_native_password" : handshake.authPlugin
        let auth = Self.scramble(plugin: plugin, password: options.password, seed: handshake.seed) ?? []

        var p: [UInt8] = []
        p.appendLE(caps, 4)
        p.appendLE(UInt32(16 * 1024 * 1024), 4)
        p.append(45) // utf8mb4_general_ci
        p.append(contentsOf: [UInt8](repeating: 0, count: 23))
        p.appendCString(options.user)
        p.append(UInt8(auth.count))
        p.append(contentsOf: auth)
        if caps & Cap.connectWithDB != 0 { p.appendCString(options.database) }
        if caps & Cap.pluginAuth != 0 { p.appendCString(plugin) }
        try writePacket(p)
        try finishAuth(password: options.password)
    }

    private func finishAuth(password: String) throws {
        while true {
            let reply = try readPacket()
            switch reply.first {
            case 0x00:
                return
            case 0xFF:
                throw Self.parseError(reply)
            case 0xFE:
                // Сервер просит другой способ входа — с новой солью.
                var r = Reader(reply, at: 1)
                let plugin = r.cString()
                var seed = Array(reply[r.offset...])
                if seed.last == 0 { seed.removeLast() }
                guard let auth = Self.scramble(plugin: plugin, password: password, seed: seed) else {
                    throw ProtocolError(message: L("Способ входа «\(plugin)» не поддерживается — нужен mysql_native_password"))
                }
                try writePacket(auth)
            case 0x01:
                // caching_sha2_password: 3 — пароль в кэше сервера, дальше придёт OK;
                // 4 — полный вход, а он возможен только по TLS или с ключом RSA.
                if reply.count > 1 && reply[1] == 3 { continue }
                throw ProtocolError(message: L("Серверу нужен полный вход caching_sha2_password (TLS или RSA) — он не поддерживается"))
            default:
                throw ProtocolError(message: L("Непонятный ответ сервера при входе"))
            }
        }
    }

    // MARK: - Запросы

    /// Выполняет текст целиком — в нём может быть несколько запросов через `;`.
    /// Ответы — по одному на запрос; ошибка в середине прерывает остальные.
    func query(_ sql: String) throws -> [Result] {
        guard fd >= 0 else { throw ProtocolError(message: L("Нет подключения")) }
        sequence = 0
        try writePacket([0x03] + Array(sql.utf8))
        var results: [Result] = []
        while true {
            let (result, more) = try readResult()
            results.append(result)
            if !more { return results }
        }
    }

    private func readResult() throws -> (Result, Bool) {
        let first = try readPacket()
        switch first.first {
        case 0x00:
            var r = Reader(first, at: 1)
            var result = Result()
            result.affectedRows = r.lenenc()
            result.lastInsertID = r.lenenc()
            let status = r.uint16()
            result.warnings = r.uint16()
            result.info = r.info()
            return (result, status & Status.moreResults != 0)
        case 0xFF:
            throw Self.parseError(first)
        case 0xFB:
            throw ProtocolError(message: L("LOAD DATA LOCAL INFILE не поддерживается"))
        default:
            break
        }
        var r = Reader(first, at: 0)
        let count = Int(r.lenenc())
        var result = Result()
        for _ in 0..<count {
            result.columns.append(try Self.parseColumn(readPacket()))
        }
        _ = try readPacket() // EOF после описания столбцов
        while true {
            let row = try readPacket()
            if row.first == 0xFE && row.count < 9 {
                var e = Reader(row, at: 1)
                result.warnings = e.uint16()
                let status = e.uint16()
                return (result, status & Status.moreResults != 0)
            }
            if row.first == 0xFF { throw Self.parseError(row) }
            result.totalRows += 1
            guard result.rows.count < Self.rowLimit else { continue }
            var rr = Reader(row, at: 0)
            var cells: [String?] = []
            cells.reserveCapacity(count)
            for column in result.columns {
                if rr.peek == 0xFB { rr.offset += 1; cells.append(nil); continue }
                let bytes = rr.lenencBytes()
                cells.append(Self.text(bytes, binary: column.isBinary))
            }
            result.rows.append(cells)
        }
    }

    /// Текст ячейки: UTF-8, а двоичное и невалидное — шестнадцатерично, как в DBeaver.
    static func text(_ bytes: ArraySlice<UInt8>, binary: Bool) -> String {
        if !binary, let s = String(bytes: bytes, encoding: .utf8) { return s }
        if binary, let s = String(bytes: bytes, encoding: .utf8),
           !s.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r" }) {
            return s
        }
        return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Пакеты

    private func readPacket() throws -> [UInt8] {
        var payload: [UInt8] = []
        while true {
            let header = try readBytes(4)
            let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
            sequence = header[3] &+ 1
            payload += try readBytes(length)
            // Ровно 16 МБ — значит, продолжение в следующем пакете.
            if length < 0xFF_FFFF { return payload }
        }
    }

    private func writePacket(_ payload: [UInt8]) throws {
        var offset = 0
        repeat {
            let chunk = min(payload.count - offset, 0xFF_FFFF)
            var packet: [UInt8] = [UInt8(chunk & 0xFF), UInt8(chunk >> 8 & 0xFF), UInt8(chunk >> 16 & 0xFF), sequence]
            packet += payload[offset..<offset + chunk]
            sequence &+= 1
            try writeAll(packet)
            offset += chunk
            if chunk < 0xFF_FFFF { break }
        } while true
    }

    private func readBytes(_ count: Int) throws -> [UInt8] {
        while buffer.count - bufferStart < count {
            if bufferStart > 0 {
                buffer.removeFirst(bufferStart)
                bufferStart = 0
            }
            var chunk = [UInt8](repeating: 0, count: max(65536, count - buffer.count))
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ProtocolError(message: L("Соединение с сервером разорвано")) }
            buffer += chunk[0..<n]
        }
        let out = Array(buffer[bufferStart..<bufferStart + count])
        bufferStart += count
        return out
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ProtocolError(message: L("Соединение с сервером разорвано")) }
            sent += n
        }
    }

    private static func openSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let host = host.trimmingCharacters(in: .whitespaces)
        let status = getaddrinfo(host.isEmpty ? "127.0.0.1" : host, String(port), &hints, &list)
        guard status == 0, let first = list else {
            throw ProtocolError(message: L("Не найден хост \(host)"))
        }
        defer { freeaddrinfo(list) }
        var lastError = ECONNREFUSED
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let ai = node {
            node = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            // Подключение с тайм-аутом: неблокирующий connect и poll.
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var ok = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0
            if !ok && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, Int32(timeout * 1000)) == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    ok = err == 0
                    if !ok { lastError = err }
                } else {
                    lastError = ETIMEDOUT
                }
            } else if !ok {
                lastError = errno
            }
            _ = fcntl(fd, F_SETFL, flags)
            if ok { return fd }
            Darwin.close(fd)
        }
        throw ProtocolError(message: L("Не подключиться к \(host):\(String(port)): \(String(cString: strerror(lastError)))"))
    }

    // MARK: - Разбор

    private enum Cap {
        static let longPassword: UInt32 = 0x1
        static let foundRows: UInt32 = 0x2
        static let longFlag: UInt32 = 0x4
        static let connectWithDB: UInt32 = 0x8
        static let protocol41: UInt32 = 0x200
        static let transactions: UInt32 = 0x2000
        static let secureConnection: UInt32 = 0x8000
        static let multiStatements: UInt32 = 0x10000
        static let multiResults: UInt32 = 0x20000
        static let pluginAuth: UInt32 = 0x80000
    }

    private enum Status {
        static let moreResults: UInt16 = 0x0008
    }

    private struct Handshake {
        var serverVersion: String
        var connectionID: UInt32
        var seed: [UInt8]
        var capabilities: UInt32
        var authPlugin = ""

        init(_ p: [UInt8]) throws {
            guard p.first == 10 else { throw ProtocolError(message: L("Сервер говорит не на протоколе MySQL")) }
            var r = Reader(p, at: 1)
            serverVersion = r.cString()
            connectionID = r.uint32()
            seed = Array(r.bytes(8))
            r.offset += 1
            capabilities = UInt32(r.uint16())
            guard !r.atEnd else { return }
            r.offset += 1 + 2 // кодировка, статус
            capabilities |= UInt32(r.uint16()) << 16
            let seedLength = Int(r.uint8())
            r.offset += 10
            if capabilities & Cap.secureConnection != 0 {
                let rest = max(13, seedLength - 8)
                var part = Array(r.bytes(rest))
                if part.last == 0 { part.removeLast() }
                seed += part
            }
            if capabilities & Cap.pluginAuth != 0 { authPlugin = r.cString() }
        }
    }

    /// Ответ на соль для способа входа; `nil` — способ не знаем.
    static func scramble(plugin: String, password: String, seed: [UInt8]) -> [UInt8]? {
        let pw = Array(password.utf8)
        switch plugin {
        case "mysql_native_password":
            guard !pw.isEmpty else { return [] }
            let seed = Array(seed.prefix(20))
            // SHA1(pw) XOR SHA1(соль + SHA1(SHA1(pw)))
            let h1 = Array(Insecure.SHA1.hash(data: pw))
            let h2 = Array(Insecure.SHA1.hash(data: h1))
            let h3 = Array(Insecure.SHA1.hash(data: seed + h2))
            return zip(h1, h3).map { $0 ^ $1 }
        case "caching_sha2_password":
            guard !pw.isEmpty else { return [] }
            let seed = Array(seed.prefix(20))
            // SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) + соль)
            let h1 = Array(SHA256.hash(data: pw))
            let h2 = Array(SHA256.hash(data: h1))
            let h3 = Array(SHA256.hash(data: h2 + seed))
            return zip(h1, h3).map { $0 ^ $1 }
        default:
            return nil
        }
    }

    private static func parseColumn(_ p: [UInt8]) throws -> Column {
        var r = Reader(p, at: 0)
        _ = r.lenencString() // catalog
        _ = r.lenencString() // schema
        let table = r.lenencString()
        _ = r.lenencString() // org_table
        let name = r.lenencString()
        _ = r.lenencString() // org_name
        _ = r.lenenc()
        let charset = r.uint16()
        _ = r.uint32() // длина
        let type = r.uint8()
        let flags = r.uint16()
        return Column(name: name, table: table, type: type, charset: charset, flags: flags)
    }

    private static func parseError(_ p: [UInt8]) -> ServerError {
        var r = Reader(p, at: 1)
        let code = r.uint16()
        var state = ""
        if r.peek == UInt8(ascii: "#") {
            r.offset += 1
            state = String(decoding: r.bytes(5), as: UTF8.self)
        }
        return ServerError(code: code, state: state, message: r.rest())
    }
}

/// Чтение полей пакета. За конец пакета не выходит: вместо падения — нули.
private struct Reader {
    let p: [UInt8]
    var offset: Int

    init(_ p: [UInt8], at offset: Int) {
        self.p = p
        self.offset = offset
    }

    var atEnd: Bool { offset >= p.count }
    var peek: UInt8? { offset < p.count ? p[offset] : nil }

    mutating func uint8() -> UInt8 {
        guard offset < p.count else { return 0 }
        defer { offset += 1 }
        return p[offset]
    }

    mutating func uint16() -> UInt16 { UInt16(truncatingIfNeeded: int(2)) }
    mutating func uint32() -> UInt32 { UInt32(truncatingIfNeeded: int(4)) }

    mutating func int(_ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(uint8()) << (8 * UInt64(i)) }
        return v
    }

    mutating func bytes(_ n: Int) -> ArraySlice<UInt8> {
        let end = min(p.count, offset + max(0, n))
        defer { offset = end }
        return p[min(offset, end)..<end]
    }

    mutating func lenenc() -> UInt64 {
        let first = uint8()
        switch first {
        case 0xFC: return int(2)
        case 0xFD: return int(3)
        case 0xFE: return int(8)
        default: return UInt64(first)
        }
    }

    mutating func lenencBytes() -> ArraySlice<UInt8> { bytes(Int(clamping: lenenc())) }
    mutating func lenencString() -> String { String(decoding: lenencBytes(), as: UTF8.self) }

    mutating func cString() -> String {
        let start = offset
        while offset < p.count && p[offset] != 0 { offset += 1 }
        defer { offset = min(p.count, offset + 1) }
        return String(decoding: p[start..<offset], as: UTF8.self)
    }

    /// Хвост OK-пакета: MariaDB шлёт его строкой с длиной, MySQL — просто до конца.
    mutating func info() -> String {
        if let n = peek, n < 0xFB, Int(n) == p.count - offset - 1 { return lenencString() }
        return rest()
    }

    mutating func rest() -> String {
        defer { offset = p.count }
        return String(decoding: p[min(offset, p.count)...], as: UTF8.self)
    }
}

private extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T, _ bytes: Int) {
        for i in 0..<bytes { append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }

    mutating func appendCString(_ s: String) {
        append(contentsOf: Array(s.utf8))
        append(0)
    }
}

// MARK: - Сессия

/// Соединение на своей очереди: запросы из интерфейса идут по одному и не
/// держат главный поток. Остановить идущий запрос можно — вторым
/// соединением с `KILL QUERY`, как это делает DBeaver.
final class MySQLSession: @unchecked Sendable {
    let options: MySQLConnection.Options
    private let connection = MySQLConnection()
    private let queue = DispatchQueue(label: "pilot.mysql")

    init(options: MySQLConnection.Options) {
        self.options = options
    }

    var serverVersion: String { queue.sync { connection.serverVersion } }

    func perform<T>(_ body: @escaping (MySQLConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [connection] in
                continuation.resume(with: Result { try body(connection) })
            }
        }
    }

    func connect() async throws {
        let options = options
        try await perform { try $0.connect(options) }
    }

    func query(_ sql: String) async throws -> [MySQLConnection.Result] {
        try await perform { try $0.query(sql) }
    }

    /// Прерывает идущий запрос, не закрывая соединения.
    func cancelQuery() {
        let options = options
        let id = connection.connectionID
        DispatchQueue.global().async {
            let killer = MySQLConnection()
            try? killer.connect(options, timeout: 3)
            _ = try? killer.query("KILL QUERY \(id)")
            killer.close()
        }
    }

    func close() {
        connection.abort()
        queue.async { [connection] in connection.close() }
    }
}
