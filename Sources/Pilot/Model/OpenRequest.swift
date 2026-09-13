import Foundation

/// Просьба снаружи открыть файл или проект: из Unity (`pilot://open?…`),
/// из Finder или `open -a Pilot File.cs`. Приходит Apple Event'ом в уже
/// запущенный Pilot — аргументы командной строки до него бы не дошли.
struct OpenRequest: Equatable {
    /// Файл или папка; nil — только проект («Open C# Project» в Unity).
    var path: URL?
    /// С единицы, как у Unity и компиляторов. nil — строка неизвестна:
    /// уже открытый файл остаётся, где был.
    var line: Int?
    var column: Int?
    /// Корень, который знает вызвавший. Unity передаёт папку своего проекта:
    /// без неё корнем стал бы git-репозиторий, а он может лежать выше —
    /// и тогда Pilot не узнал бы в нём Unity.
    var project: URL?

    static let scheme = "pilot"

    init(path: URL?, line: Int? = nil, column: Int? = nil, project: URL? = nil) {
        self.path = path
        self.line = line
        self.column = column
        self.project = project
    }

    /// `file://…` — от Finder и `open -a`;
    /// `pilot://open?file=/abs/File.cs&line=12&column=5&project=/abs/Project`.
    init?(url: URL) {
        if url.isFileURL {
            self.init(path: url.standardizedFileURL)
            return
        }
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { values[item.name] = value }
        }
        func absolute(_ key: String) -> URL? {
            guard let path = values[key], path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        // Unity шлёт -1 и 0, когда места не знает.
        func positive(_ key: String) -> Int? {
            guard let value = values[key].flatMap(Int.init), value > 0 else { return nil }
            return value
        }
        self.init(path: absolute("file"), line: positive("line"), column: positive("column"),
                  project: absolute("project"))
        if path == nil, project == nil { return nil }
    }

    /// Место для перехода: LSP считает строки и столбцы с нуля.
    var range: LSPRange? {
        guard let line else { return nil }
        let position = LSPPosition(line: line - 1, character: max((column ?? 1) - 1, 0))
        return LSPRange(start: position, end: position)
    }

    /// Открывать ли в текущем проекте, не переключаясь на `desired`.
    ///
    /// Файл — да, если лежит внутри открытой папки и в том же git-репозитории,
    /// что и `desired`: worktree в `.claude/worktrees/` лежит внутри основного
    /// репозитория, но это другой проект. Проект без файла — только если он
    /// и открыт: его просили открыть, а не показать файл.
    static func staysInRoot(_ root: URL?, file: URL?, desired: URL, repository: (URL) -> URL?) -> Bool {
        guard let root else { return false }
        guard let file else { return root.path == desired.path }
        guard file.path.hasPrefix(root.path + "/") else { return false }
        return repository(root)?.path == repository(desired)?.path
    }
}
