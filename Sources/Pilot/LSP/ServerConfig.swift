import Foundation

/// Описание языкового сервера. Держим это данными, а не кодом: какой сервер
/// у какого языка — вопрос настройки, а не архитектуры.
///
/// C# сюда не входит: его понимает Rustlyn, в процессе и без сервера (см.
/// `Rustlyn.swift`). Языковые серверы остались для остальных языков —
/// SourceKit-LSP для Swift и то, что человек описал в `servers.json`.
struct ServerConfig {
    var id: String
    var languageId: String            // идентификатор языка по LSP: "swift"
    var fileExtensions: Set<String>
    var command: [String]             // argv; command[0] ищется в PATH
    var environment: [String: String] = [:]
    /// Произвольный JSON в `initializationOptions`.
    var initializationOptions: [String: Any]? = nil
    /// Ответы на `workspace/configuration`: секция -> значение. На всё,
    /// чего здесь нет, отвечаем null — сервер берёт своё значение по умолчанию.
    var settings: [String: Any] = [:]
    /// Человекочитаемое имя для статус-строки.
    var displayName: String

    /// Ответ на `workspace/configuration`: по значению на каждый запрошенный
    /// элемент, в том же порядке: так требует протокол. Ответ из одного null
    /// на запрос о десятке секций сервер вправе не принять.
    func configurationResponse(_ params: Any?) -> [Any] {
        let items = (params as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.map { item in
            guard let section = item["section"] as? String else { return NSNull() }
            return settings[section] ?? NSNull()
        }
    }

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
        // типичные места установки Homebrew и системных инструментов.
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += [
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
    /// установлен в системе. Свои, из servers.json, идут первыми.
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

        // SourceKit-LSP — идёт вместе с Xcode и Command Line Tools.
        // SwiftPM-проекты понимает сам, по Package.swift.
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

    // MARK: - Пользовательские конфигурации

    static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/pilot/servers.json")
    }

    /// Читает ~/.config/pilot/servers.json.
    static func userDefined() -> [ServerConfig] {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["servers"] as? [[String: Any]] else { return [] }

        return servers.compactMap(ServerConfig.init(json:))
    }
}

// MARK: - JSON
//
// Формат servers.json. Разбираем вручную, а не через Codable, чтобы
// `initializationOptions` мог быть произвольным JSON.

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
            displayName: dict["displayName"] as? String ?? id)
    }
}
