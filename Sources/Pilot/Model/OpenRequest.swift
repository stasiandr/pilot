import Foundation

/// Просьба открыть файл или проект: из командной строки (так зовёт Unity),
/// из Finder или `open -a Pilot File.cs`. В уже запущенный Pilot приходит
/// Apple Event'ом — файлом или адресом `pilot://open?…`, в который второй
/// процесс заворачивает свою командную строку (см. LaunchForwarding).
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

    /// Командная строка: `Pilot /path/Project`, `Pilot /path/File.cs`,
    /// `Pilot /path/File.cs:12:5`, или всё вместе. Так Pilot запускает Unity:
    /// External Script Editor Args `$(ProjectPath) $(File):$(Line):$(Column)`.
    /// `isDirectory` — nil, если пути нет на диске.
    init?(arguments: [String], isDirectory: (String) -> Bool?) {
        self.init(path: nil)
        // macOS может дописать свои аргументы вида `-NSFoo YES`, а Unity без
        // файла («Open C# Project») присылает `:0:0` — берём только пути.
        for argument in arguments.dropFirst() where argument.hasPrefix("/") {
            var candidate = Substring(argument)
            var numbers: [Int] = []
            while true {
                if let directory = isDirectory(String(candidate)) {
                    let url = URL(fileURLWithPath: String(candidate)).standardizedFileURL
                    if directory {
                        if project == nil { project = url }
                    } else if path == nil {
                        path = url
                        line = numbers.first.flatMap { $0 > 0 ? $0 : nil }
                        column = numbers.dropFirst().first.flatMap { $0 > 0 ? $0 : nil }
                    }
                    break
                }
                // `File.cs:12:5` — отрезаем числа справа, не больше двух.
                guard numbers.count < 2, let colon = candidate.lastIndex(of: ":"),
                      let number = Int(candidate[candidate.index(after: colon)...]) else { break }
                numbers.insert(number, at: 0)
                candidate = candidate[..<colon]
            }
        }
        if path == nil, project == nil { return nil }
    }

    /// Из аргументов этого процесса.
    static var launch: OpenRequest? {
        OpenRequest(arguments: CommandLine.arguments) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) ? isDirectory.boolValue : nil
        }
    }

    /// Та же просьба адресом `pilot://` — чтобы передать её уже запущенному Pilot.
    var url: URL {
        var items: [(String, String)] = []
        if let path { items.append(("file", path.path)) }
        if let line { items.append(("line", String(line))) }
        if let column { items.append(("column", String(column))) }
        if let project { items.append(("project", project.path)) }
        // URLComponents не кодирует `&`, `=` и `+` в значениях — а в пути
        // они сломали бы разбор.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"
        components.percentEncodedQuery = items
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return components.url!
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
