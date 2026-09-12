import Foundation

/// Объявление типа где-то в проекте.
struct TypeDeclaration: Equatable {
    var name: String
    /// Объемлющий тип или пространство имён — как в структуре файла.
    var container: String?
    /// `class`, `struct`, `interface`, `enum`, `protocol`…
    var keyword: String
    var file: Int32          // индекс пути в TypeIndex
    var line: Int32
    var column: Int32        // UTF-16, как у LSP
    var length: Int32
}

/// Индекс типов всего проекта — для поиска по классам (⇧⇧).
///
/// Строится тем же лексером и тем же структурным разбором, что и ⌘⇧O, только
/// по всем исходникам сразу. Языковой сервер не нужен: поиск работает на
/// любом языке, который знает лексер, и доступен с первой секунды — сначала
/// из кэша, а после пересканирования — по свежим данным.
///
/// Имена лежат в одном непрерывном буфере, как пути в FileIndex: набор
/// запроса не порождает аллокаций на тип.
final class TypeIndex: @unchecked Sendable {   // неизменяем после построения

    /// Какие объявления считаются типом. `extension` и `impl` сюда не входят
    /// намеренно: это не новый тип, а дополнение к уже существующему, и
    /// в выдаче они только дублировали бы его.
    static let typeKeywords: Set<String> = [
        "class", "struct", "interface", "record", "enum", "protocol", "actor",
        "trait", "object", "type", "typealias", "union",
    ]

    /// Файлы больше этого не разбираем: это почти всегда сгенерированный код,
    /// а один такой файл съел бы больше времени, чем весь остальной проект.
    static let maxFileBytes = 1 << 20

    private struct Span {
        var start: Int32      // смещение в bytes
        var length: Int32
        var nameStart: Int32  // где внутри «Контейнер.Имя» начинается имя
    }

    let root: URL
    private(set) var paths: [String] = []
    private(set) var declarations: [TypeDeclaration] = []
    /// «контейнер.имя» в нижнем регистре, подряд — для матчинга.
    private var bytes: [UInt8] = []
    private var spans: [Span] = []
    /// Тип назван так же, как файл: `UserService` в `UserService.cs`.
    /// При равных очках такой выше — скорее всего, это и есть главный.
    private var isPrimary: [Bool] = []

    init(root: URL) { self.root = root }

    var count: Int { declarations.count }

    func declaration(_ id: Int32) -> TypeDeclaration { declarations[Int(id)] }

    func relPath(_ id: Int32) -> String { paths[Int(declarations[Int(id)].file)] }

    func target(_ id: Int32) -> NavTarget {
        let d = declarations[Int(id)]
        let start = LSPPosition(line: Int(d.line), character: Int(d.column))
        let end = LSPPosition(line: Int(d.line), character: Int(d.column + d.length))
        return NavTarget(url: root.appendingPathComponent(paths[Int(d.file)]),
                         range: LSPRange(start: start, end: end))
    }

    /// Буквенная иконка по ключевому слову: c — class, s — struct, i — interface…
    static func icon(forKeyword keyword: String) -> String {
        guard let first = keyword.first, first.isASCII, first.isLetter else { return "cube" }
        return "\(first.lowercased()).square"
    }

    private func append(path: String, _ found: [TypeDeclaration]) {
        let file = Int32(paths.count)
        paths.append(path)
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        for var d in found {
            d.file = file
            var prefix: [UInt8] = []                                        // «Контейнер.»
            if let container = d.container { prefix = Array(container.utf8) + [0x2E] }
            let start = bytes.count
            for b in prefix + Array(d.name.utf8) {
                bytes.append((b >= 0x41 && b <= 0x5A) ? b + 32 : b)
            }
            spans.append(Span(start: Int32(start),
                              length: Int32(bytes.count - start),
                              nameStart: Int32(prefix.count)))
            isPrimary.append(d.name == stem)
            declarations.append(d)
        }
    }

    // MARK: - Разбор одного файла

    /// Язык, в котором вообще бывают типы. Для остальных файлов разбор
    /// не запускается: JSON, Markdown и shell проходят мимо.
    static func spec(forPath path: String) -> LanguageSpec? {
        guard let spec = Languages.detect(filename: (path as NSString).lastPathComponent),
              spec.outline != .none,
              spec.declarationKeywords.contains(where: { $0.value == .type && typeKeywords.contains($0.key) })
        else { return nil }
        return spec
    }

    static func declarations(in text: String, spec: LanguageSpec) -> [TypeDeclaration] {
        let model = SyntaxModel(text: text, spec: spec)
        return OutlineBuilder.build(model: model).compactMap { item in
            guard item.kind == .type, let keyword = item.keyword,
                  typeKeywords.contains(keyword) else { return nil }
            let position = model.position(at: item.range.location)
            return TypeDeclaration(name: item.name, container: item.container, keyword: keyword,
                                   file: 0, line: Int32(position.line),
                                   column: Int32(position.character),
                                   length: Int32(item.range.length))
        }
    }

    /// Читаем так же, как LoadedDocument: иначе колонки разъедутся
    /// на файлах не в UTF-8, и переход подсветит не то.
    private static func readSource(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxFileBytes,
              !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Построение

    /// Разбирает все исходники проекта. Синхронно и на всех ядрах — вызывать
    /// только из фона. `shouldStop` прерывает работу, если воркспейс сменился;
    /// тогда возвращается nil, а не половина индекса.
    static func build(root: URL, files: [String], shouldStop: @escaping () -> Bool) -> TypeIndex? {
        var specsByExtension: [String: LanguageSpec?] = [:]
        var candidates: [(path: String, spec: LanguageSpec)] = []
        for path in files {
            let ext = (path as NSString).pathExtension.lowercased()
            let spec: LanguageSpec?
            if let known = specsByExtension[ext] {
                spec = known
            } else {
                spec = Self.spec(forPath: path)
                specsByExtension[ext] = spec
            }
            if let spec { candidates.append((path, spec)) }
        }

        // Файлы раздаются по одному из общей очереди: крупные файлы
        // обычно лежат кучно, и нарезка заранее оставила бы ядра без дела.
        let lock = NSLock()
        var next = 0
        var found: [(path: String, declarations: [TypeDeclaration])] = []
        let workers = max(1, min(candidates.count, ProcessInfo.processInfo.activeProcessorCount))

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var local: [(path: String, declarations: [TypeDeclaration])] = []
            while !shouldStop() {
                lock.lock()
                let i = next
                next += 1
                lock.unlock()
                guard i < candidates.count else { break }

                let (path, spec) = candidates[i]
                guard let text = readSource(root.appendingPathComponent(path)) else { continue }
                let types = Self.declarations(in: text, spec: spec)
                if !types.isEmpty { local.append((path, types)) }
            }
            lock.lock()
            found.append(contentsOf: local)
            lock.unlock()
        }
        if shouldStop() { return nil }

        // Порядок потоков случаен — сортируем, чтобы выдача была стабильной.
        found.sort { $0.path < $1.path }
        let index = TypeIndex(root: root)
        for entry in found { index.append(path: entry.path, entry.declarations) }
        return index
    }

    // MARK: - Поиск

    /// До `limit` лучших типов. Пустой запрос ничего не находит: список
    /// из тысяч классов по алфавиту никому не нужен.
    ///
    /// Запрос с точкой (`Outer.Inner`) матчится по полному имени с контейнером,
    /// без точки — только по имени: иначе `user` цеплялся бы за контейнер
    /// `UserModule` раньше, чем за сам `UserRole`. Позиции для подсветки
    /// в обоих случаях — внутри имени.
    func search(_ queryString: String, limit: Int, shouldStop: () -> Bool) -> [SearchHit] {
        let q = FuzzyMatch.Query(queryString)
        guard !q.isEmpty else { return [] }
        let qualified = q.lower.contains(0x2E)

        var results: [SearchHit] = []
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var positions: [Int32]? = []

            for i in 0..<spans.count {
                if i & 0x3FF == 0 && shouldStop() { return }
                let span = spans[i]
                let skip = qualified ? 0 : Int(span.nameStart)
                let ptr = base + Int(span.start) + skip
                let len = Int(span.length) - skip
                guard FuzzyMatch.firstPass(q, ptr, len) != nil,
                      let s = FuzzyMatch.score(q, text: ptr, len: len,
                                               nameStart: Int(span.nameStart) - skip,
                                               positions: &positions) else { continue }
                let shift = Int32(Int(span.nameStart) - skip)
                let inName = (positions ?? []).compactMap { $0 >= shift ? $0 - shift : nil }
                results.append(SearchHit(id: Int32(i), score: s, positions: inName))
            }
        }
        if shouldStop() { return [] }

        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = Int($0.id), b = Int($1.id)
            if isPrimary[a] != isPrimary[b] { return isPrimary[a] }
            if spans[a].length != spans[b].length { return spans[a].length < spans[b].length }
            return paths[Int(declarations[a].file)].count < paths[Int(declarations[b].file)].count
        }
        if results.count > limit { results.removeSubrange(limit...) }
        return results
    }

    // MARK: - Кэш на диске
    //
    // Текстом, по строке на тип: `F<tab>путь` открывает файл, дальше его
    // типы — `ключевое слово, имя, контейнер, строка, колонка, длина`.

    private static let cacheHeader = "pilot-types 1"

    func serialized() -> String {
        var out = [Self.cacheHeader]
        var currentFile: Int32 = -1
        for d in declarations {
            if d.file != currentFile {
                currentFile = d.file
                out.append("F\t" + paths[Int(d.file)])
            }
            out.append("\(d.keyword)\t\(d.name)\t\(d.container ?? "")\t\(d.line)\t\(d.column)\t\(d.length)")
        }
        return out.joined(separator: "\n")
    }

    /// nil, если формат чужой или битый — тогда просто ждём свежего индекса.
    static func deserialize(_ text: String, root: URL) -> TypeIndex? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard lines.next() == Substring(cacheHeader) else { return nil }

        let index = TypeIndex(root: root)
        var path: String?
        var pending: [TypeDeclaration] = []

        func flush() {
            if let path, !pending.isEmpty { index.append(path: path, pending) }
            pending.removeAll(keepingCapacity: true)
        }

        while let line = lines.next() {
            if line.hasPrefix("F\t") {
                flush()
                path = String(line.dropFirst(2))
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard path != nil, fields.count == 6,
                  let row = Int32(fields[3]), let column = Int32(fields[4]),
                  let length = Int32(fields[5]) else { return nil }
            pending.append(TypeDeclaration(
                name: String(fields[1]),
                container: fields[2].isEmpty ? nil : String(fields[2]),
                keyword: String(fields[0]),
                file: 0, line: row, column: column, length: length))
        }
        flush()
        return index
    }
}
