import AppKit

/// Токен декомпилированного кода, о котором jadx знает, что это:
/// объявление или ссылка на класс, метод, поле, переменную.
struct DecompiledSpan: Sendable {
    enum Kind: Int, Sendable {
        case declClass = 1, declMethod = 2, declField = 3, declVariable = 4
        case refClass = 11, refMethod = 12, refField = 13, refVariable = 14, refPackage = 15
    }

    var location: Int   // UTF-16
    var length: Int
    var kind: Kind

    var range: NSRange { NSRange(location: location, length: length) }
}

/// Открытый архив: процесс jadx и что лежит по каким путям.
/// Неизменяем после открытия — им пользуются и фоновые очереди.
final class ArchiveSession: @unchecked Sendable {
    enum Entry: Sendable {
        case javaClass(raw: String)
        case resource(name: String)
        case tableFile(table: String, index: Int)
    }

    let root: URL
    let client: JadxClient
    let entries: [String: Entry]
    /// Сырое имя класса → путь: цели переходов jadx называет классами.
    let classPaths: [String: String]

    fileprivate init(root: URL, client: JadxClient, entries: [String: Entry], classPaths: [String: String]) {
        self.root = root
        self.client = client
        self.entries = entries
        self.classPaths = classPaths
    }

    func relativePath(of url: URL) -> String? {
        let prefix = root.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return String(url.path.dropFirst(prefix.count))
    }

    func owns(_ url: URL) -> Bool { relativePath(of: url) != nil }

    /// Запрос содержимого файла по его пути.
    fileprivate func request(for url: URL) throws -> (method: String, params: [String: Any]) {
        guard let path = relativePath(of: url), let entry = entries[path] else {
            throw JadxError(message: L("В архиве нет \(url.lastPathComponent)"))
        }
        switch entry {
        case .javaClass(let raw):              return ("code", ["cls": raw])
        case .resource(let name):              return ("resource", ["name": name])
        case .tableFile(let table, let index): return ("resource", ["name": table, "sub": index])
        }
    }

    /// Текст ответа движка: код класса или ресурс. Бинарный ресурс — ошибка, как у файла с диска.
    static func text(from reply: [String: Any]) throws -> String {
        if let code = reply["code"] as? String { return code }
        if let text = reply["text"] as? String { return text }
        guard let base64 = reply["data"] as? String, let data = Data(base64Encoded: base64) else {
            throw LoadedDocument.LoadError.binary
        }
        if data.prefix(8192).contains(0) { throw LoadedDocument.LoadError.binary }
        guard let text = String(data: data, encoding: .utf8) else { throw LoadedDocument.LoadError.binary }
        return text
    }

    static func spans(from reply: [String: Any]) -> [DecompiledSpan] {
        guard let flat = reply["spans"] as? [Int] else { return [] }
        var spans: [DecompiledSpan] = []
        spans.reserveCapacity(flat.count / 3)
        var i = 0
        while i + 2 < flat.count {
            // На одной позиции бывает несколько аннотаций — берём первую.
            if let kind = DecompiledSpan.Kind(rawValue: flat[i + 2]), spans.last?.location != flat[i] {
                spans.append(DecompiledSpan(location: flat[i], length: flat[i + 1], kind: kind))
            }
            i += 3
        }
        return spans
    }

    /// Для предпросмотра в палитре — из фоновой очереди.
    func textSync(for url: URL) throws -> String {
        let (method, params) = try request(for: url)
        return try Self.text(from: client.objectSync(method, params))
    }
}

/// APK, JAR, AAR или DEX, открытый как проект только для чтения.
///
/// Корень — файл архива; классы лежат в `sources/`, ресурсы — в `resources/`
/// (см. ArchiveLayout). Текст файлов даёт jadx, git, Unity и языковой сервер
/// в таком проекте не участвуют.
@MainActor
final class ArchiveService: ObservableObject {
    private(set) var session: ArchiveSession?
    /// Смысловая разметка открытых классов — по пути файла.
    private var spans: [String: [DecompiledSpan]] = [:]
    @Published private(set) var decorationsVersion = 0
    /// Растёт при каждом закрытии: открытие, которое не дождалось jadx до следующего, отменяется.
    private var openCount = 0

    var isActive: Bool { session != nil }

    func owns(_ url: URL) -> Bool { session?.owns(url) ?? false }

    struct Contents {
        var paths: [String]
        var types: [(path: String, declarations: [TypeDeclaration])]
        /// Что показать сразу после открытия.
        var manifest: String?
    }

    /// Запускает jadx и загружает архив: список классов и ресурсов, без декомпиляции.
    func open(_ url: URL) async throws -> Contents {
        close()
        let generation = openCount
        let client = try JadxClient()
        do {
            let reply = try await client.object("open", ["paths": [url.path]])
            // Пока jadx читал архив, открыли другой проект: этот процесс уже никому не нужен.
            guard generation == openCount else { throw CancellationError() }
            let (session, contents) = Self.layout(root: url, client: client, reply: reply)
            self.session = session
            return contents
        } catch {
            client.stop()
            throw error
        }
    }

    func close() {
        openCount += 1
        session?.client.stop()
        session = nil
        spans = [:]
    }

    private static func layout(root: URL, client: JadxClient, reply: [String: Any]) -> (ArchiveSession, Contents) {
        var entries: [String: ArchiveSession.Entry] = [:]
        var classPaths: [String: String] = [:]
        var paths: [String] = []
        var types: [(path: String, declarations: [TypeDeclaration])] = []

        for row in reply["classes"] as? [[String]] ?? [] where row.count == 3 {
            let (raw, fullName, kind) = (row[0], row[1], row[2])
            var path = ArchiveLayout.sourcePath(className: fullName)
            // Два класса с одним именем после переименования — второй по сырому имени.
            if entries[path] != nil { path = ArchiveLayout.sourcePath(className: raw) }
            guard entries[path] == nil else { continue }
            entries[path] = .javaClass(raw: raw)
            classPaths[raw] = path
            paths.append(path)
            let (name, package) = ArchiveLayout.split(className: fullName)
            types.append((path, [TypeDeclaration(name: name, container: package,
                                                 keyword: ArchiveLayout.keyword(kind: kind),
                                                 file: 0, line: 0, column: 0, length: 0)]))
        }

        var manifest: String?
        for row in reply["resources"] as? [[String]] ?? [] where row.count == 2 {
            let path = ArchiveLayout.resourcePath(row[0])
            guard entries[path] == nil else { continue }
            entries[path] = .resource(name: row[0])
            paths.append(path)
            if row[1] == "MANIFEST", manifest == nil { manifest = path }
        }
        for (table, files) in reply["tables"] as? [String: [String]] ?? [:] {
            for (index, file) in files.enumerated() {
                let path = ArchiveLayout.resourcePath(file)
                guard entries[path] == nil else { continue }
                entries[path] = .tableFile(table: table, index: index)
                paths.append(path)
            }
        }

        let session = ArchiveSession(root: root, client: client, entries: entries, classPaths: classPaths)
        return (session, Contents(paths: paths, types: types, manifest: manifest))
    }

    /// Декомпилированный класс или ресурс — документом редактора.
    func loadDocument(_ url: URL) async throws -> LoadedDocument {
        guard let session else { throw JadxError(message: L("Архив не открыт")) }
        let (method, params) = try session.request(for: url)
        let reply = try await session.client.object(method, params)
        let text = try ArchiveSession.text(from: reply)
        let found = ArchiveSession.spans(from: reply)
        let document = await Task.detached(priority: .userInitiated) {
            LoadedDocument.decompiled(url: url, text: text)
        }.value
        guard self.session === session else { throw JadxError(message: L("Архив закрыт")) }
        if !found.isEmpty {
            spans[url.path] = found
            decorationsVersion += 1
        }
        return document
    }

    /// Цвета по смыслу поверх лексера: jadx точно знает, где тип, метод и поле.
    func decorator() -> CodeDecorator? {
        guard isActive else { return nil }
        let spans = self.spans
        return { document, range in
            guard let list = spans[document.url.path], !list.isEmpty else { return [] }
            // Первый токен, заканчивающийся в видимой области.
            var low = 0, high = list.count
            while low < high {
                let mid = (low + high) / 2
                if list[mid].location + list[mid].length <= range.location { low = mid + 1 } else { high = mid }
            }
            var result: [TextDecoration] = []
            let end = NSMaxRange(range)
            let units = document.model.units
            var i = low
            while i < list.count, list[i].location < end {
                let span = list[i]
                i += 1
                guard let color = Theme.decompiledColor(span.kind) else { continue }
                var start = span.location
                // Полное имя в импорте или при конфликте имён: цветом — только сам класс,
                // как у лексера, пакет остаётся обычным текстом.
                if span.kind == .refClass {
                    var j = min(span.location + span.length, units.count) - 1
                    while j > span.location, units[j] != 0x2E { j -= 1 }
                    if units[j] == 0x2E { start = j + 1 }
                }
                result.append(TextDecoration(range: NSRange(location: start, length: span.location + span.length - start),
                                             color: color))
            }
            return result
        }
    }
}

// MARK: - Навигация
//
// В декомпилированном коде jadx знает, на что указывает каждое имя, —
// эвристики быстрого навигатора и языковой сервер здесь не нужны.

extension ArchiveService {
    enum Definition {
        case target(NavTarget)
        /// Курсор на самом объявлении: ⌘B показывает его использования.
        case declaration
        case unavailable(String)
    }

    /// Символ из ⌘T. Куда он ведёт, известно только после декомпиляции
    /// его класса, поэтому место выясняется при выборе.
    struct Symbol {
        var name: String
        var owner: String
        /// c — класс, m — метод, f — поле.
        var kind: String
        fileprivate var raw: String
        fileprivate var ref: Int?
    }

    /// Токен под курсором или сразу перед ним: курсор после имени — тоже на нём.
    func span(in document: LoadedDocument, at offset: Int) -> DecompiledSpan? {
        guard let list = spans[document.url.path] else { return nil }
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].location + list[mid].length < offset { low = mid + 1 } else { high = mid }
        }
        guard low < list.count, list[low].location <= offset else { return nil }
        return list[low]
    }

    private func className(of document: LoadedDocument) -> String? {
        guard let session, let path = session.relativePath(of: document.url),
              case .javaClass(let raw)? = session.entries[path] else { return nil }
        return raw
    }

    /// `{cls, line, col}` из ответа jadx — место в проекте.
    private func target(from reply: Any?) -> NavTarget? {
        guard let session, let reply = reply as? [String: Any], let cls = reply["cls"] as? String,
              let path = session.classPaths[cls] else { return nil }
        let position = LSPPosition(line: reply["line"] as? Int ?? 0, character: reply["col"] as? Int ?? 0)
        return NavTarget(url: session.root.appendingPathComponent(path),
                         range: LSPRange(start: position, end: position))
    }

    func definition(in document: LoadedDocument, at offset: Int) async -> Definition {
        guard let session, let cls = className(of: document) else {
            return .unavailable(L("Переходы есть только в коде классов"))
        }
        guard let span = span(in: document, at: offset) else { return .unavailable(L("Здесь нет имени")) }
        switch span.kind {
        case .declClass, .declMethod, .declField: return .declaration
        default: break
        }
        let reply = try? await session.client.call("resolve", ["cls": cls, "pos": span.location])
        guard let target = target(from: reply) else {
            return .unavailable(L("Объявление не в этом архиве — например, в Android SDK"))
        }
        return .target(target)
    }

    func usages(in document: LoadedDocument, at offset: Int) async -> [(url: URL, range: LSPRange)] {
        guard let session, let cls = className(of: document), let span = span(in: document, at: offset),
              let hits = try? await session.client.call("usages", ["cls": cls, "pos": span.location]) as? [[String: Any]]
        else { return [] }
        return hits.compactMap { hit in target(from: hit).flatMap { t in t.range.map { (t.url, $0) } } }
    }

    func symbols(matching query: String) async -> [Symbol] {
        guard let session, !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let reply = try? await session.client.object("search", ["token": UUID().uuidString, "query": query])
        else { return [] }
        return (reply["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let raw = item["cls"] as? String, let name = item["text"] as? String else { return nil }
            return Symbol(name: name, owner: item["name"] as? String ?? "", kind: item["kind"] as? String ?? "c",
                          raw: raw, ref: item["ref"] as? Int)
        }
    }

    /// Файл, где лежит символ, — для строки в палитре и предпросмотра.
    func fileURL(of symbol: Symbol) -> URL? {
        guard let session, let path = session.classPaths[symbol.raw] else { return nil }
        return session.root.appendingPathComponent(path)
    }

    /// Точное место символа: jadx декомпилирует его класс.
    func locate(_ symbol: Symbol) async -> NavTarget? {
        guard let session else { return nil }
        var params: [String: Any] = ["cls": symbol.raw]
        if let ref = symbol.ref { params["ref"] = ref }
        return target(from: try? await session.client.call("locate", params))
    }
}
