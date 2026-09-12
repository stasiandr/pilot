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
                          "--extensionLogDirectory=\(NSTemporaryDirectory())flint-roslyn",
                          "--stdio"],
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
            .appendingPathComponent(".config/flint/servers.json")
    }

    /// Читает ~/.config/flint/servers.json. Разбираем вручную, а не через
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
