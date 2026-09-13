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
    /// Ответы на `workspace/configuration`: секция -> значение. На всё,
    /// чего здесь нет, отвечаем null — сервер берёт своё значение по умолчанию.
    var settings: [String: Any] = [:]
    /// Roslyn после initialize ждёт нестандартное `solution/open`,
    /// иначе молча не отдаёт ни одного символа.
    var opensSolution = false
    /// Уведомление, которым сервер сообщает, что проекты загружены. До него
    /// initialize уже прошёл, но семантики ещё нет: запросы вернут пустоту.
    var projectsLoadedNotification: String? = nil
    /// Подстрока в `window/logMessage`, которой сервер отмечает загрузку
    /// одного проекта. По ней считается прогресс «проекты 57 из 134».
    var projectLoadedMessage: String? = nil
    /// Человекочитаемое имя для статус-строки.
    var displayName: String

    /// Абсолютный путь к исполняемому файлу, если он вообще есть в системе.
    /// Ответ на `workspace/configuration`: по значению на каждый запрошенный
    /// элемент, в том же порядке: так требует протокол. Roslyn спрашивает
    /// за раз десятки секций, и ответ из одного null ему не подходит.
    func configurationResponse(_ params: Any?) -> [Any] {
        let items = (params as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.map { item in
            guard let section = item["section"] as? String else { return NSNull() }
            return settings[section] ?? NSNull()
        }
    }

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

    /// Сервер, которому нужен solution, — если solution в корне есть и такой
    /// сервер установлен. Его стоит поднимать сразу при открытии проекта.
    static func solutionServer(root: URL) -> ServerConfig? {
        guard findSolution(root: root) != nil else { return nil }
        return all(root: root).first { $0.opensSolution && $0.resolvedExecutable() != nil }
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
                // Information, а не Warning: только на этом уровне Roslyn пишет
                // «Successfully completed load of X.csproj», по которым
                // считается прогресс загрузки. Это пара сотен строк за запуск.
                command: [roslyn,
                          "--logLevel=Information",
                          "--extensionLogDirectory=\(NSTemporaryDirectory())pilot-roslyn",
                          "--stdio"],
                environment: DotnetRuntime.environment(forAppHost: roslyn),
                settings: roslynSettings,
                opensSolution: true,
                projectsLoadedNotification: "workspace/projectInitializationComplete",
                projectLoadedMessage: "Successfully completed load of",
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

        // 4. SourceKit-LSP — идёт вместе с Xcode и Command Line Tools.
        //    SwiftPM-проекты понимает сам, по Package.swift.
        if let sourcekit = discoverSourceKit() {
            list.append(ServerConfig(
                id: "sourcekit-lsp",
                languageId: "swift",
                fileExtensions: ["swift"],
                command: [sourcekit],
                displayName: "SourceKit-LSP"))
        }

        return list
    }

    /// Сначала PATH (swiftly, свой тулчейн), затем выбранный Xcode и CLT.
    /// `xcrun --find` не зовём: лишний процесс на каждый поиск сервера.
    private static func discoverSourceKit() -> String? {
        if let onPath = ServerConfig.searchPath(for: "sourcekit-lsp") { return onPath }
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
            "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Настройки Roslyn под читателя кода. Секции — ровно те, что сервер сам
    /// запрашивает через `workspace/configuration`.
    static let roslynSettings: [String: Any] = [
        // Главное. По умолчанию Roslyn гоняет NuGet restore для каждого
        // проекта, где видит неразрешённые зависимости, — по очереди, по
        // полсекунды на проект. На Unity-проекте из 134 csproj это минута из
        // полутора, и всё впустую: в сгенерированных Unity проектах нет
        // PackageReference, восстанавливать там нечего.
        "projects.dotnet_enable_automatic_restore": false,
        // Диагностики Pilot не показывает — незачем их и считать.
        "csharp|background_analysis.dotnet_analyzer_diagnostics_scope": "none",
        "csharp|background_analysis.dotnet_compiler_diagnostics_scope": "none",
        // ⌘T ищет по коду проекта, а не по UnityEngine.dll и прочим сборкам.
        "csharp|symbol_search.dotnet_search_reference_assemblies": false,
    ]

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

    /// Сколько C#-проектов перечислено в .sln/.slnx; для одиночного .csproj — один.
    /// nil, если файл не прочитался.
    static func projectCount(solution: URL) -> Int? {
        if solution.pathExtension == "csproj" { return 1 }
        guard let text = try? String(contentsOf: solution, encoding: .utf8) else { return nil }
        return projectCount(solutionText: text, isXML: solution.pathExtension == "slnx")
    }

    /// .sln: `Project("{guid}") = "Name", "Path\Name.csproj", "{guid}"`.
    /// .slnx: `<Project Path="Path/Name.csproj" />`. Папки решения тоже
    /// записаны как Project, поэтому считаем только строки с .csproj.
    static func projectCount(solutionText text: String, isXML: Bool) -> Int {
        let opener = isXML ? "<Project " : "Project("
        return text.split(whereSeparator: \.isNewline).filter { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(opener) && line.contains(".csproj\"")
        }.count
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

        return servers.compactMap(ServerConfig.init(json:))
    }
}

// MARK: - JSON
//
// Тот же формат, что в servers.json. По нему же конфигурация уходит демону:
// сервер он поднимает ровно такой, какой описал Pilot.

extension ServerConfig {
    init?(json dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let command = dict["command"] as? [String], !command.isEmpty,
              let extensions = dict["extensions"] as? [String] else { return nil }
        self.init(
            id: id,
            languageId: dict["languageId"] as? String ?? "plaintext",
            fileExtensions: Set(extensions.map { $0.lowercased() }),
            command: command,
            environment: dict["env"] as? [String: String] ?? [:],
            initializationOptions: dict["initializationOptions"] as? [String: Any],
            settings: dict["settings"] as? [String: Any] ?? [:],
            opensSolution: dict["opensSolution"] as? Bool ?? false,
            projectsLoadedNotification: dict["projectsLoadedNotification"] as? String,
            projectLoadedMessage: dict["projectLoadedMessage"] as? String,
            displayName: dict["displayName"] as? String ?? id)
    }

    var json: [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "languageId": languageId,
            "extensions": fileExtensions.sorted(),
            "command": command,
            "env": environment,
            "settings": settings,
            "opensSolution": opensSolution,
            "displayName": displayName,
        ]
        if let initializationOptions { dict["initializationOptions"] = initializationOptions }
        if let projectsLoadedNotification { dict["projectsLoadedNotification"] = projectsLoadedNotification }
        if let projectLoadedMessage { dict["projectLoadedMessage"] = projectLoadedMessage }
        return dict
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
    /// (MSBuild) взял тот же SDK, а не системный. Mono из PATH убран.
    static func environment(forAppHost appHost: String) -> [String: String] {
        let path = pathWithoutMono(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        let required = requiredMajor(forAppHost: appHost) ?? 0
        guard let root = findRoot(minimumMajor: required) else { return ["PATH": path] }
        return ["DOTNET_ROOT": root, "PATH": "\(root):\(path)"]
    }

    /// PATH без папок, где лежит `mono`.
    ///
    /// Старые, не-SDK csproj — а Unity генерирует именно такие — Roslyn
    /// загружает через Mono, если находит его в PATH, и через .NET, если нет.
    /// Результат одинаковый, скорость — нет: Unity-проект из 134 csproj
    /// грузится 23 с через Mono и 8 с через .NET. Pilot, запущенный из
    /// терминала, наследует PATH оболочки, а установщик Mono кладёт его туда.
    static func pathWithoutMono(_ path: String) -> String {
        let fm = FileManager.default
        return path.split(separator: ":", omittingEmptySubsequences: true)
            .filter { !fm.isExecutableFile(atPath: "\($0)/mono") }
            .joined(separator: ":")
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
