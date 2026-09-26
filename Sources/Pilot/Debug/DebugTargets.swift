import Foundation

/// Что можно отлаживать в открытом проекте.
enum DebugTarget: Identifiable, Hashable, Sendable {
    /// Редактор Unity с этим проектом: Play Mode, всегда Mono.
    case unityEditor(pid: Int32, port: Int)
    /// Development-сборка со Script Debugging — IL2CPP или Mono: сама
    /// объявляет о себе по UDP.
    case unityPlayer(name: String, host: String, port: Int)
    /// Адрес вручную: Android через `adb forward`, iOS через iproxy.
    case unityRemote(host: String, port: Int)
    /// Проект .NET с `OutputType Exe`: собрать и запустить под отладчиком.
    case dotnetLaunch(project: URL)
    /// Уже работающий процесс .NET из этого проекта.
    case dotnetAttach(pid: Int32, name: String)

    var id: String {
        switch self {
        case .unityEditor(let pid, _): return "unity-editor-\(pid)"
        case .unityPlayer(_, let host, let port): return "unity-player-\(host):\(port)"
        case .unityRemote(let host, let port): return "unity-remote-\(host):\(port)"
        case .dotnetLaunch(let project): return "dotnet-launch-\(project.path)"
        case .dotnetAttach(let pid, _): return "dotnet-attach-\(pid)"
        }
    }

    var title: String {
        switch self {
        case .unityEditor: return "Редактор Unity"
        case .unityPlayer(let name, _, _): return name
        case .unityRemote(let host, let port): return "\(host):\(port)"
        case .dotnetLaunch(let project): return project.deletingPathExtension().lastPathComponent
        case .dotnetAttach(_, let name): return name
        }
    }

    var subtitle: String {
        switch self {
        case .unityEditor(let pid, let port): return "Play Mode · процесс \(pid) · порт \(port)"
        case .unityPlayer(_, let host, let port): return "Сборка · \(host):\(port)"
        case .unityRemote: return "Unity-сборка по адресу"
        case .dotnetLaunch: return "Собрать и запустить"
        case .dotnetAttach(let pid, _): return "Подключиться · процесс \(pid)"
        }
    }

    var symbol: String {
        switch self {
        case .unityEditor: return "cube.fill"
        case .unityPlayer: return "iphone.gen3"
        case .unityRemote: return "network"
        case .dotnetLaunch: return "play.fill"
        case .dotnetAttach: return "link"
        }
    }

    var isUnity: Bool {
        switch self {
        case .unityEditor, .unityPlayer, .unityRemote: return true
        default: return false
        }
    }
}

enum DebugTargets {
    /// Агент отладки Unity слушает 56000 + последние три цифры: у
    /// редактора — номера процесса, у сборки — её GUID из анонса.
    static func unityPort(for number: UInt64) -> Int { 56000 + Int(number % 1000) }

    // MARK: Процессы

    struct ProcessLine {
        var pid: Int32
        var arguments: String
    }

    static func processes() -> [ProcessLine] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Ao", "pid=,args="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { raw in
            let line = raw.drop { $0 == " " }
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]) else { return nil }
            return ProcessLine(pid: pid, arguments: String(line[line.index(after: space)...]))
        }
    }

    /// Путь проекта из командной строки редактора: `-projectPath <путь>`.
    /// ps склеивает аргументы пробелами, поэтому путь — до следующего ` -`.
    static func unityProjectPath(in arguments: String) -> String? {
        guard arguments.contains("/Unity.app/Contents/MacOS/Unity") else { return nil }
        guard let flag = arguments.range(of: "-projectpath ", options: .caseInsensitive) else { return nil }
        let rest = arguments[flag.upperBound...]
        let end = rest.range(of: " -")?.lowerBound ?? rest.endIndex
        let path = rest[..<end].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return path.isEmpty ? nil : path
    }

    static func samePath(_ a: String, _ b: URL) -> Bool {
        let left = URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        let right = b.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        return left == right
    }

    static func unityEditors(root: URL, in list: [ProcessLine]) -> [DebugTarget] {
        list.compactMap { process in
            guard let path = unityProjectPath(in: process.arguments), samePath(path, root) else { return nil }
            return .unityEditor(pid: process.pid, port: unityPort(for: UInt64(process.pid)))
        }
    }

    /// Процессы .NET, чья сборка лежит в проекте: `dotnet …/bin/…/X.dll`
    /// или apphost `…/bin/…/X`.
    static func dotnetProcesses(root: URL, in list: [ProcessLine]) -> [DebugTarget] {
        let base = root.standardizedFileURL.path + "/"
        return list.compactMap { process in
            let args = process.arguments
            guard args.contains(base), args.contains("/bin/") else { return nil }
            let words = args.split(separator: " ").map(String.init)
            if let dll = words.first(where: { $0.hasSuffix(".dll") && $0.hasPrefix(base) }),
               words.first.map({ ($0 as NSString).lastPathComponent == "dotnet" }) == true {
                return .dotnetAttach(pid: process.pid, name: ((dll as NSString).lastPathComponent as NSString).deletingPathExtension)
            }
            if let exe = words.first, exe.hasPrefix(base), exe.contains("/bin/"),
               FileManager.default.fileExists(atPath: exe + ".dll") {
                return .dotnetAttach(pid: process.pid, name: (exe as NSString).lastPathComponent)
            }
            return nil
        }
    }

    // MARK: Проекты .NET

    /// `.csproj` с исполняемым выходом. Тесты и бенчмарки запускают иначе,
    /// их в списке не нужно.
    static func dotnetProjects(root: URL) -> [URL] {
        let skip: Set<String> = [".git", "bin", "obj", "node_modules", "Library", "Temp", "Packages", ".build", ".idea"]
        var found: [URL] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walker {
            if walker.level > 3 { walker.skipDescendants(); continue }
            if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard url.pathExtension == "csproj",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if isExecutableProject(text, name: url.deletingPathExtension().lastPathComponent) { found.append(url) }
        }
        // Главный проект — тот, что называется как решение или просто короче.
        return found.sorted { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }
    }

    static func isExecutableProject(_ csproj: String, name: String) -> Bool {
        guard csproj.range(of: "<OutputType>\\s*(Exe|WinExe)\\s*</OutputType>", options: [.regularExpression, .caseInsensitive]) != nil
        else { return false }
        if csproj.contains("Microsoft.NET.Test.Sdk") || csproj.contains("BenchmarkDotNet") { return false }
        let lower = name.lowercased()
        return !lower.hasSuffix(".tests") && !lower.hasSuffix(".test") && !lower.hasSuffix(".benchmarks")
    }

    // MARK: Сборки Unity в сети

    /// Анонс плеера — строка вида
    /// `[IP] 192.168.1.5 [Port] 55000 [Flags] 3 [Guid] 1234 [EditorId] 5678 [Version] 1048832 [Id] OSXPlayer(1,Mac) [Debug] 1 …`.
    struct PlayerAnnouncement: Equatable {
        var ip: String
        var guid: UInt64
        var id: String
        var debug: Bool
        var project: String?

        static func parse(_ text: String) -> PlayerAnnouncement? {
            var fields: [String: String] = [:]
            var key: String?
            var value = ""
            var i = text.startIndex
            while i < text.endIndex {
                if text[i] == "[", let close = text[i...].firstIndex(of: "]") {
                    if let key { fields[key] = value.trimmingCharacters(in: .whitespaces) }
                    key = String(text[text.index(after: i)..<close])
                    value = ""
                    i = text.index(after: close)
                    continue
                }
                value.append(text[i])
                i = text.index(after: i)
            }
            if let key { fields[key] = value.trimmingCharacters(in: CharacterSet.whitespaces.union(.controlCharacters)) }
            guard let ip = fields["IP"], let guid = fields["Guid"].flatMap({ UInt64($0) }) else { return nil }
            return PlayerAnnouncement(ip: ip, guid: guid, id: fields["Id"] ?? "Unity Player",
                                      debug: fields["Debug"] == "1", project: fields["ProjectName"])
        }
    }

    static let multicastGroup = "225.0.0.222"
    static let multicastPorts: [UInt16] = [54997, 34997, 57997, 58997]

    /// Слушает анонсы плееров `duration` секунд: они шлют их раз в секунду.
    /// Сборки без Script Debugging тоже объявляются — их отсеиваем.
    static func unityPlayers(duration: TimeInterval = 1.5) async -> [DebugTarget] {
        await Task.detached {
            var sockets: [Int32] = []
            for port in multicastPorts {
                let fd = socket(AF_INET, SOCK_DGRAM, 0)
                guard fd >= 0 else { continue }
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr = in_addr(s_addr: INADDR_ANY)
                let bound = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                var request = ip_mreq()
                inet_pton(AF_INET, multicastGroup, &request.imr_multiaddr)
                request.imr_interface = in_addr(s_addr: INADDR_ANY)
                let joined = setsockopt(fd, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP, &request,
                                        socklen_t(MemoryLayout<ip_mreq>.size))
                if bound != 0 || joined != 0 { close(fd); continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                sockets.append(fd)
            }
            defer { for fd in sockets { close(fd) } }
            guard !sockets.isEmpty else { return [] }

            var found: [String: DebugTarget] = [:]
            let deadline = Date().addingTimeInterval(duration)
            var buffer = [UInt8](repeating: 0, count: 2048)
            while Date() < deadline {
                var fds = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                guard poll(&fds, nfds_t(fds.count), left) > 0 else { continue }
                for pfd in fds where pfd.revents & Int16(POLLIN) != 0 {
                    let n = recv(pfd.fd, &buffer, buffer.count, 0)
                    guard n > 0, let player = PlayerAnnouncement.parse(String(decoding: buffer[0..<n], as: UTF8.self)),
                          player.debug else { continue }
                    let target = DebugTarget.unityPlayer(name: player.id, host: player.ip, port: unityPort(for: player.guid))
                    found[target.id] = target
                }
            }
            return found.values.sorted { $0.title < $1.title }
        }.value
    }
}
