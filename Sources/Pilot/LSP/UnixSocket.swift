import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unix-сокет — ровно то, что нужно демону языковых серверов и его клиенту.
/// Дескрипторы блокирующие: с ними работает FileHandle.
enum UnixSocket {

    enum Failure: Error {
        case pathTooLong
        case alreadyServed
        case system(String, Int32)
    }

    #if canImport(Glibc)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    private static let streamType = SOCK_STREAM
    #endif

    /// Подключение к слушающему сокету. nil — никто не слушает.
    static func connectTo(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = makeSocket()
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        noSigPipe(fd)
        return fd
    }

    /// Слушающий сокет, только для владельца. Неблокирующий: принимаем
    /// соединения из DispatchSource, пока они есть.
    static func serve(_ path: String) throws -> Int32 {
        guard var address = address(path) else { throw Failure.pathTooLong }
        // Живой демон уже слушает — второй не нужен.
        if let fd = connectTo(path) {
            close(fd)
            throw Failure.alreadyServed
        }
        unlink(path)                                  // сокет от упавшего демона
        let fd = makeSocket()
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let e = errno; close(fd); throw Failure.system("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw Failure.system("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// Следующее ожидающее соединение; nil — больше нет.
    static func acceptClient(_ listener: Int32) -> Int32? {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        // На BSD принятый сокет наследует O_NONBLOCK слушающего, а FileHandle
        // на неблокирующем дескрипторе падает на первом же пустом чтении.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        noSigPipe(fd)
        return fd
    }

    /// С явным модулем: глобальная переменная `socket` где-нибудь в модуле
    /// иначе перекрыла бы системный вызов.
    private static func makeSocket() -> Int32 {
        #if canImport(Darwin)
        return Darwin.socket(AF_UNIX, streamType, 0)
        #else
        return Glibc.socket(AF_UNIX, streamType, 0)
        #endif
    }

    /// Запись в закрытый сокет не должна убивать процесс сигналом.
    private static func noSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }
}
