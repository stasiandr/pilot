#if canImport(CRustlyn)
import CRustlyn
import Foundation

/// Rustlyn — компилятор C#, из которого Pilot берёт то, что знает про C#
/// по-настоящему.
///
/// Здесь ровно граница: жизнь сессии, перевод C-структур в свифтовые и
/// освобождение всего, что выделила та сторона. Ни одного решения о том,
/// что показывать, — они выше.
///
/// **Что отдано Rust, а что осталось своим.** Rustlyn — это C#, и только C#.
/// Лексер Pilot знает два десятка языков и правит модель инкрементально, в том
/// же вызове, что и текст, — этого Rustlyn не делает и делать не должен.
/// Поэтому граница проведена так:
///
/// * **Набор текста** — свой лексер. Он инкрементальный: обычная правка
///   перелексирует одну строку. Пока файл правят, Rustlyn про него не спрашивают.
/// * **Чтение** — Rustlyn, как только файл устоялся (открыли, сохранили).
///   Настоящий лексер C# знает raw-строки, вложенную интерполяцию и мёртвые
///   ветки `#if`, а не приближается к ним.
/// * **Структура, индекс, переходы** — всегда Rustlyn для `.cs`. Здесь своя
///   эвристика по форме строки не приближается, а ошибается: `Helper(1);`
///   похоже на объявление метода, а не является им.
/// * **Сборки** — Rustlyn. Свой читатель метаданных остаётся для случая,
///   когда библиотеки нет: тогда тел методов не будет, но объявления будут.
///
/// **Потоки.** Сессия рассчитана на обращения с нескольких потоков разом —
/// это её свойство, а не наше обещание: внутри всё под замками. Поэтому
/// класс `@unchecked Sendable`, и ни один вызов не обязан быть на главном.
///
/// **Память.** Всё, что выделил Rust, освобождает Rust. Каждый результат
/// оборачивается сразу при получении и копируется в свифтовые типы, а
/// C-структура освобождается в том же вызове: наружу указатели не уходят
/// вовсе, и владеть ими некому.
final class Rustlyn: @unchecked Sendable {

    private static let lock = NSLock()
    private static var session: Rustlyn?

    /// Общая сессия проекта. Пересоздаётся при смене проекта.
    ///
    /// Ставится с главного потока (открытие проекта), а читается отовсюду:
    /// подсветка — с главного, структура и индекс — с фоновых. Поэтому за
    /// замком. Сама сессия внутри потокобезопасна — замок только про то,
    /// какая из них сейчас, а это меняется раз в открытие проекта.
    static var shared: Rustlyn? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    /// Открывает сессию для проекта. Прежняя закрывается.
    ///
    /// `symbols` — символы препроцессора проекта: от них зависит, какая ветка
    /// `#if` живая, а значит — что вообще попадёт в подсветку, структуру и
    /// индекс. Кэш у сессий с разными символами разный, и это правильно:
    /// один и тот же файл под разными символами — разный код.
    @discardableResult
    static func start(root: URL, symbols: [String] = []) -> Rustlyn? {
        let fresh = Rustlyn(root: root, symbols: symbols)
        lock.lock()
        session = fresh
        lock.unlock()
        return fresh
    }

    static func stop() {
        lock.lock()
        session = nil
        lock.unlock()
    }

    private let handle: OpaquePointer

    let root: URL

    private init?(root: URL, symbols: [String]) {
        self.root = root
        let cache = Rustlyn.cacheDirectory(for: root)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        // Массив C-строк живёт ровно до конца вызова: Rust копирует их себе.
        // Элементы опциональные — так `const char *const *` приходит в Swift.
        let defined: [UnsafeMutablePointer<CChar>?] = symbols.map { strdup($0) }
        defer { defined.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = defined.map { $0.map { UnsafePointer($0) } }

        let session: OpaquePointer? = root.path.withCString { rootPath in
            cache.path.withCString { cachePath in
                pointers.withUnsafeMutableBufferPointer { buffer in
                    rln_session_new(rootPath, cachePath,
                                    buffer.baseAddress, buffer.count)
                }
            }
        }
        guard let session else { return nil }
        handle = session
    }

    deinit {
        rln_session_free(handle)
    }

    /// Кэш рядом с прочими кэшами Pilot, по одной папке на проект: у двух
    /// проектов бывают файлы с одинаковым путём относительно корня.
    private static func cacheDirectory(for root: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Имя папки — из пути проекта: читаемое начало плюс хэш, чтобы два
        // проекта с одинаковым именем не делили один кэш.
        let name = root.lastPathComponent.prefix(32)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in root.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return caches.appendingPathComponent("Pilot/rustlyn/\(name)-\(String(hash, radix: 16))")
    }

    /// Последняя причина отказа, словами. Пустая строка, если ничего не
    /// ломалось.
    var lastError: String {
        let text = rln_last_error(handle)
        defer { rln_text_free(text) }
        guard let bytes = text.bytes, text.length > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: text.length), as: UTF8.self)
    }

    /// Что кэш успел не пересчитать.
    struct Statistics {
        var stamped: UInt64 = 0
        var rehashed: UInt64 = 0
        var fromDisk: UInt64 = 0
        var computed: UInt64 = 0
        var entries: Int = 0
        var bytes: Int = 0

        /// Доля ответов, которые не пришлось считать заново.
        var reuseRatio: Double {
            let total = stamped + rehashed + fromDisk + computed
            guard total > 0 else { return 0 }
            return Double(stamped + rehashed + fromDisk) / Double(total)
        }
    }

    var statistics: Statistics {
        let raw = rln_statistics(handle)
        return Statistics(stamped: raw.stamped, rehashed: raw.rehashed,
                          fromDisk: raw.from_disk, computed: raw.computed,
                          entries: raw.entries, bytes: raw.bytes)
    }

    // MARK: - Слой 1: открыть файл

    /// Файлы, которые Rustlyn понимает. Всё остальное Pilot открывает и
    /// подсвечивает сам — и это большинство того, что он открывает.
    static func understands(_ url: URL) -> Bool {
        ["cs", "csx"].contains(url.pathExtension.lowercased())
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        url.path.withCString { rln_open(handle, $0) == RLN_OK }
    }

    /// Открыть буфер, текст которого уже в руках: несохранённый или тот,
    /// что разошёлся с диском.
    @discardableResult
    func open(_ url: URL, text: String) -> Bool {
        url.path.withCString { path in
            text.withCString { body in
                rln_open_text(handle, path, body) == RLN_OK
            }
        }
    }

    /// Заменить текст открытого файла. Всё, что про него было посчитано,
    /// выбрасывается — поэтому это вызов на устоявшуюся правку, а не на
    /// каждое нажатие клавиши.
    @discardableResult
    func setText(_ url: URL, _ text: String) -> Bool {
        url.path.withCString { path in
            text.withCString { body in
                rln_set_text(handle, path, body) == RLN_OK
            }
        }
    }

    func close(_ url: URL) {
        url.path.withCString { rln_close(handle, $0) }
    }

    // MARK: - Слой 2: подсветка

    /// Токены строк `lines` — уже в тех же единицах и с теми же видами, что
    /// у своего лексера, так что подставляются вместо него один в один.
    ///
    /// `nil` — не C#, файл не открыт или что-то пошло не так; зовущий в этом
    /// случае берёт свой лексер.
    func tokens(_ url: URL, lines: ClosedRange<Int>) -> [Token]? {
        var runs = RlnRuns()
        let status = url.path.withCString {
            rln_classify(handle, $0, UInt32(max(0, lines.lowerBound)),
                         UInt32(max(0, lines.upperBound)), &runs)
        }
        guard status == RLN_OK else { return nil }
        defer { rln_runs_free(runs) }
        guard let items = runs.items else { return [] }
        return UnsafeBufferPointer(start: items, count: runs.count).map { run in
            Token(start: Int32(bitPattern: run.start),
                  length: Int32(bitPattern: run.length),
                  kind: TokenKind(run.class_))
        }
    }

    /// Пройти файл целиком, расставив все точки возврата лексера: после
    /// этого прыжок в любую строку стоит столько же, сколько прокрутка.
    /// Для фона.
    func warm(_ url: URL) {
        _ = url.path.withCString { rln_warm(handle, $0) }
    }

    // MARK: - Слой 3: структура файла

    /// Структура файла — от парсера, а не от формы строк.
    func outline(_ url: URL) -> RustlynOutline? {
        var raw = RlnOutline()
        let status = url.path.withCString { rln_outline(handle, $0, &raw) }
        guard status == RLN_OK else { return nil }
        defer { rln_outline_free(raw) }
        return RustlynOutline(raw)
    }

    // MARK: - Слой 4: индекс проекта

    /// Что переиндексация сделала, а чего не стала.
    struct IndexReport {
        var files = 0
        /// Файлы, которые не пришлось перечитывать.
        var reused = 0
        var parsed = 0
        var unreadable = 0
    }

    /// Собрать индекс проекта. Файлы, не изменившиеся с прошлого раза,
    /// достаются из кэша, а не разбираются заново, — поэтому после
    /// сохранения это дёшево, а дорого только в первый раз.
    @discardableResult
    func reindex(_ urls: [URL]) -> IndexReport {
        var report = RlnReport()
        let paths: [UnsafeMutablePointer<CChar>?] = urls.map { strdup($0.path) }
        defer { paths.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = paths.map { $0.map { UnsafePointer($0) } }
        let status = pointers.withUnsafeMutableBufferPointer { buffer in
            rln_reindex(handle, buffer.baseAddress, buffer.count, &report)
        }
        guard status == RLN_OK else { return IndexReport() }
        return IndexReport(files: report.files, reused: report.reused,
                           parsed: report.parsed, unreadable: report.unreadable)
    }

    /// Куда ведёт имя в позиции `offset` (UTF-16, как везде в редакторе).
    func definition(_ url: URL, offset: Int) -> RustlynDefinition {
        var raw = RlnLocations()
        let status = url.path.withCString {
            rln_definition(handle, $0, UInt32(max(0, offset)), &raw)
        }
        return finish(status, raw)
    }

    /// Кто наследует или переопределяет то, что в позиции `offset`.
    func implementations(_ url: URL, offset: Int) -> RustlynDefinition {
        var raw = RlnLocations()
        let status = url.path.withCString {
            rln_implementations(handle, $0, UInt32(max(0, offset)), &raw)
        }
        return finish(status, raw)
    }

    private func finish(_ status: RlnStatus, _ raw: RlnLocations) -> RustlynDefinition {
        guard status == RLN_OK else {
            return RustlynDefinition(refusal: RustlynRefusal(status), reason: lastError)
        }
        defer { rln_locations_free(raw) }
        return RustlynDefinition(raw, root: root)
    }

    // MARK: - Слой 5: сборки

    /// Сборка, показанная как C#: типы, члены, сигнатуры. Тел методов здесь
    /// нет — их отдаёт `methodBody(_:token:)`, по одному и по запросу.
    func assemblyText(_ url: URL) -> String? {
        var text = RlnString()
        let status = url.path.withCString { rln_assembly_text(handle, $0, &text) }
        guard status == RLN_OK else { return nil }
        defer { rln_text_free(text) }
        guard let bytes = text.bytes else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: text.length), as: UTF8.self)
    }

    /// Токен метода, объявленного в строке `line` текста сборки, или `nil`,
    /// если в этой строке объявления нет.
    func methodToken(_ url: URL, line: Int) -> UInt32? {
        let token = url.path.withCString {
            rln_assembly_token_at_line(handle, $0, UInt32(max(0, line)))
        }
        return token == 0 ? nil : token
    }

    /// IL одного метода, с разрешёнными именами. Это IL, а не восстановленный
    /// C#: перевод IL обратно в исходник — отдельная программа, и честный
    /// дизассемблер лучше уверенной выдумки.
    func methodBody(_ url: URL, token: UInt32) -> String? {
        var text = RlnString()
        let status = url.path.withCString { rln_method_body(handle, $0, token, &text) }
        guard status == RLN_OK else { return nil }
        defer { rln_text_free(text) }
        guard let bytes = text.bytes else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: text.length), as: UTF8.self)
    }

    // MARK: - Проверка сборки

    /// Совпадают ли таблицы в заголовке с тем, что знает библиотека.
    ///
    /// `TokenKind` и `RustlynDeclarationKind` перечислены на этой стороне
    /// вручную; если там добавили вид, а здесь нет, всё останется рабочим и
    /// начнёт молча ошибаться на одно значение. Проверяется один раз при
    /// запуске — это дешевле, чем искать потом, почему у полей иконка метода.
    static func buildsAgree() -> Bool {
        rln_declaration_kind_count() == UInt32(RustlynDeclarationKind.allCases.count)
            && rln_class_count() == UInt32(TokenKind.allCases.count)
    }
}

// MARK: - Разбор того, что пришло с той стороны

extension RustlynDefinition {
    init(_ raw: RlnLocations, root: URL) {
        self.init()
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        word = Rustlyn.read(blob, raw.word)
        certain = raw.certain
        guard let items = raw.items else { return }
        targets = UnsafeBufferPointer(start: items, count: raw.count).map { item in
            RustlynTarget(
                url: root.appendingPathComponent(Rustlyn.read(blob, item.path)),
                name: Rustlyn.read(blob, item.name),
                line: Int(item.line),
                character: Int(item.character),
                length: Int(item.length),
                kind: RustlynDeclarationKind(rawValue: item.kind) ?? .class
            )
        }
    }
}

extension RustlynOutline {
    init(_ raw: RlnOutline) {
        self.init()
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        let read = { (slice: RlnText) in Rustlyn.read(blob, slice) }
        // Списки лежат в том же блобе, разделённые `\n`: ни имя, ни тип в C#
        // перевода строки не содержат, поэтому экранировать нечего.
        let list = { (slice: RlnText) -> [String] in
            let text = read(slice)
            return text.isEmpty ? [] : text.components(separatedBy: "\n")
        }

        parseErrors = Int(raw.parse_errors)
        namespaces = list(raw.namespaces)
        usings = list(raw.usings).map(RustlynUsing.init)

        guard let items = raw.declarations else { return }
        declarations = UnsafeBufferPointer(start: items, count: raw.count).map { item in
            let container = read(item.container)
            let typeText = read(item.type_text)
            return RustlynDeclaration(
                name: read(item.name),
                kind: RustlynDeclarationKind(rawValue: item.kind) ?? .class,
                keyword: read(item.keyword),
                container: container.isEmpty ? nil : container,
                typeText: typeText.isEmpty ? nil : typeText,
                bases: list(item.bases),
                genericParams: list(item.type_parameters),
                attributes: list(item.attributes),
                parameters: list(item.parameters),
                nameRange: NSRange(location: Int(item.name_start), length: Int(item.name_length)),
                fullRange: NSRange(location: Int(item.full_start), length: Int(item.full_length)),
                line: Int(item.line),
                depth: Int(item.depth),
                isStatic: item.flags & UInt8(RLN_FLAG_STATIC) != 0,
                isAbstract: item.flags & UInt8(RLN_FLAG_ABSTRACT) != 0,
                isOverride: item.flags & UInt8(RLN_FLAG_OVERRIDE) != 0,
                isPartial: item.flags & UInt8(RLN_FLAG_PARTIAL) != 0,
                isExtensionMethod: item.flags & UInt8(RLN_FLAG_EXTENSION_METHOD) != 0
            )
        }
    }
}

extension RustlynRefusal {
    init(_ status: RlnStatus) {
        switch status {
        case RLN_OK:               self = .none
        case RLN_NOT_OPEN:         self = .notOpen
        case RLN_NOT_CSHARP:       self = .notCsharp
        case RLN_NOT_INDEXED:      self = .notIndexed
        case RLN_NOT_A_NAME:       self = .notAName
        case RLN_RECEIVER_UNKNOWN: self = .receiverUnknown
        case RLN_NOT_IN_PROJECT:   self = .notInProject
        case RLN_ASSEMBLY:         self = .assembly
        case RLN_IO:               self = .io
        default:                   self = .other
        }
    }
}

extension Rustlyn {
    /// Кусок общего блоба строк. Границы приходят с той стороны и там же
    /// проверены, но лишняя проверка здесь стоит одно сравнение и снимает
    /// целый класс отказов.
    static func read(_ blob: UnsafeBufferPointer<UInt8>, _ slice: RlnText) -> String {
        let start = Int(slice.offset)
        let end = start + Int(slice.length)
        guard start >= 0, end <= blob.count, start <= end,
              let base = blob.baseAddress else { return "" }
        return String(decoding: UnsafeBufferPointer(start: base + start, count: end - start),
                      as: UTF8.self)
    }
}

#endif
