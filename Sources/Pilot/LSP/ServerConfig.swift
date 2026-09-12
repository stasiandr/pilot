import Foundation

/// Описание языкового сервера. Держим это данными, а не кодом: выбор между
/// Roslyn, csharp-ls и OmniSharp — вопрос настройки, а не архитектуры.
struct ServerConfig {
    var id: String
    var languageId: String            // идентификатор языка по LSP: "csharp"
    var fileExtensions: Set<String>
    var command: [String]             // argv; command[0] ищется в PATH
    var environment: [String: String] = [:]
    /// Произвольный JSON в `initializationOptions`.
    var initializationOptions: [String: Any]? = nil
    /// Roslyn после initialize ждёт нестандартное `solution/open`,
    /// иначе молча не отдаёт ни одного символа.
    var opensSolution = false
    /// Человекочитаемое имя для статус-строки.
    var displayName: String

    /// Абсолютный путь к исполняемому файлу, если он вообще есть в системе.
    func resolvedExecutable() -> String? {
        guard let first = command.first else { return nil }
        if first.contains("/") {
            return FileManager.default.isExecutableFile(atPath: first) ? first : nil
        }
        return Self.searchPath(for: first)
    }

    static func searchPath(for name: String) -> String? {
        // GUI-приложение наследует урезанный PATH, поэтому добавляем
        // типичные места установки dotnet-инструментов и Homebrew.
        let home = NSHomeDirectory()
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += [
            "\(home)/.dotnet/tools",
            "/usr/local/share/dotnet",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
        let fm = FileManager.default
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

enum ServerRegistry {

    /// Возвращает первый сервер для расширения файла, который реально
    /// установлен в системе. Порядок — по убыванию качества семантики.
    static func server(forExtension ext: String, root: URL) -> ServerConfig? {
        let lower = ext.lowercased()
        for config in all(root: root) where config.fileExtensions.contains(lower) {
            if config.resolvedExecutable() != nil { return config }
        }
        return nil
    }

    static func all(root: URL) -> [ServerConfig] {
        userDefined() + builtIn(root: root)
    }

    // MARK: - Встроенные конфигурации

    static func builtIn(root: URL) -> [ServerConfig] {
        var list: [ServerConfig] = []

        // 1. Roslyn — тот же сервер, что стоит за C# Dev Kit в VS Code.
        //    Семантика лучшая из доступных, прогрев самый долгий.
        if let roslyn = discoverRoslyn() {
            list.append(ServerConfig(
                id: "roslyn",
                languageId: "csharp",
                fileExtensions: ["cs", "csx"],
                command: [roslyn,
                          "--logLevel=Warning",
                          "--extensionLogDirectory=\(NSTemporaryDirectory())pilot-roslyn",
                          "--stdio"],
                environment: DotnetRuntime.environment(forAppHost: roslyn),
                opensSolution: true,
                displayName: "Roslyn"))
        }

        // 2. csharp-ls — лёгкая community-обёртка над тем же Roslyn.
        //    Ставится как `dotnet tool install --global csharp-ls`.
        list.append(ServerConfig(
            id: "csharp-ls",
            languageId: "csharp",
            fileExtensions: ["cs", "csx"],
            command: solutionArguments(root: root, executable: "csharp-ls"),
            displayName: "csharp-ls"))

        // 3. OmniSharp — старый, но всё ещё встречается.
        list.append(ServerConfig(
            id: "omnisharp",
            languageId: "csharp",
            fileExtensions: ["cs", "csx"],
            command: ["omnisharp", "-lsp"],
            displayName: "OmniSharp"))

        return list
    }

    private static func solutionArguments(root: URL, executable: String) -> [String] {
        if let sln = findSolution(root: root) {
            return [executable, "-s", sln.path]
        }
        return [executable]
    }

    /// Ищет .sln в корне проекта: без него Roslyn и csharp-ls
    /// сами угадывают, что грузить, и часто угадывают не то.
    static func findSolution(root: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return nil }
        if let sln = entries.first(where: { $0.pathExtension == "sln" }) { return sln }
        if let slnx = entries.first(where: { $0.pathExtension == "slnx" }) { return slnx }
        return entries.first { $0.pathExtension == "csproj" }
    }

    /// Roslyn обычно приезжает вместе с расширением C# для VS Code,
    /// поэтому в первую очередь смотрим туда.
    private static func discoverRoslyn() -> String? {
        if let onPath = ServerConfig.searchPath(for: "Microsoft.CodeAnalysis.LanguageServer") {
            return onPath
        }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let extensionRoots = [
            "\(home)/.vscode/extensions",
            "\(home)/.vscode-insiders/extensions",
            "\(home)/.cursor/extensions",
        ]
        for dir in extensionRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            // ms-dotnettools.csharp-2.x.x-darwin-arm64
            let candidates = entries
                .filter { $0.hasPrefix("ms-dotnettools.csharp-") }
                .sorted()
                .reversed()
            for name in candidates {
                let path = "\(dir)/\(name)/.roslyn/Microsoft.CodeAnalysis.LanguageServer"
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    // MARK: - Пользовательские конфигурации

    static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/pilot/servers.json")
    }

    /// Читает ~/.config/pilot/servers.json. Разбираем вручную, а не через
    /// Codable, чтобы `initializationOptions` мог быть произвольным JSON.
    static func userDefined() -> [ServerConfig] {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["servers"] as? [[String: Any]] else { return [] }

        return servers.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let command = dict["command"] as? [String], !command.isEmpty,
                  let extensions = dict["extensions"] as? [String] else { return nil }

            return ServerConfig(
                id: id,
                languageId: dict["languageId"] as? String ?? "plaintext",
                fileExtensions: Set(extensions.map { $0.lowercased() }),
                command: command,
                environment: dict["env"] as? [String: String] ?? [:],
                initializationOptions: dict["initializationOptions"] as? [String: Any],
                opensSolution: dict["opensSolution"] as? Bool ?? false,
                displayName: dict["displayName"] as? String ?? id)
        }
    }
}

// MARK: - Рантайм .NET для серверов на .NET

/// Roslyn из расширения VS Code — это apphost, собранный под свежий .NET
/// (сейчас 10). Системный `/usr/local/share/dotnet` часто старее, и тогда
/// сервер падает на старте с «You must install or update .NET». VS Code
/// обходит это, подсовывая свой рантайм через DOTNET_ROOT; делаем так же.
enum DotnetRuntime {

    /// Окружение для запуска apphost: DOTNET_ROOT с подходящим рантаймом
    /// и его `dotnet` первым в PATH — чтобы и загрузчик проектов Roslyn
    /// (MSBuild) взял тот же SDK, а не системный.
    static func environment(forAppHost appHost: String) -> [String: String] {
        let required = requiredMajor(forAppHost: appHost) ?? 0
        guard let root = findRoot(minimumMajor: required) else { return [:] }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return ["DOTNET_ROOT": root, "PATH": "\(root):\(path)"]
    }

    /// Мажорная версия Microsoft.NETCore.App из `<app>.runtimeconfig.json`.
    static func requiredMajor(forAppHost appHost: String) -> Int? {
        let config = appHost + ".runtimeconfig.json"
        guard let data = FileManager.default.contents(atPath: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let options = json["runtimeOptions"] as? [String: Any] else { return nil }
        let frameworks = (options["frameworks"] as? [[String: Any]])
            ?? [options["framework"] as? [String: Any]].compactMap { $0 }
        let core = frameworks.first { $0["name"] as? String == "Microsoft.NETCore.App" }
        guard let version = core?["version"] as? String else { return nil }
        return majorVersion(version)
    }

    /// Первый корень .NET, где есть рантайм не старше нужного. Корни с SDK
    /// предпочтительнее: без SDK Roslyn поднимется, но не загрузит проекты.
    static func findRoot(minimumMajor: Int, candidates: [String]? = nil) -> String? {
        let roots = candidates ?? candidateRoots()
        let suitable = roots.filter { root in
            installedVersions(in: root, "shared/Microsoft.NETCore.App")
                .contains { $0 >= minimumMajor }
        }
        return suitable.first { !installedVersions(in: $0, "sdk").isEmpty } ?? suitable.first
    }

    static func candidateRoots() -> [String] {
        let home = NSHomeDirectory()
        var roots: [String] = []
        if let env = ProcessInfo.processInfo.environment["DOTNET_ROOT"] { roots.append(env) }
        roots.append("\(home)/.dotnet")
        // Рантаймы, которые скачало расширение .NET Install Tool для VS Code.
        let acquired = "\(home)/Library/Application Support/Code/User/globalStorage/ms-dotnettools.vscode-dotnet-runtime/.dotnet"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: acquired) {
            let sorted = entries.sorted { (majorVersion($0) ?? 0) > (majorVersion($1) ?? 0) }
            roots += sorted.map { "\(acquired)/\($0)" }
        }
        roots += ["/usr/local/share/dotnet", "/opt/homebrew/share/dotnet"]
        return roots
    }

    private static func installedVersions(in root: String, _ subdirectory: String) -> [Int] {
        let dir = (root as NSString).appendingPathComponent(subdirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return entries.compactMap(majorVersion)
    }

    /// "10.0.12~arm64" -> 10, "8.0.3" -> 8.
    static func majorVersion(_ text: String) -> Int? {
        Int(text.prefix { $0.isNumber })
    }
}
