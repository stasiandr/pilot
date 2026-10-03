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
/// * **Смысл** — `⌘B`, `⌘R`, автодополнение — Rustlyn как компилятор: весь
///   проект скомпилирован против его настоящих сборок, и на вопрос про имя
///   отвечает то же, что собрало бы программу. Несохранённый текст он
///   получает в самом вопросе и связывает правленый метод поверх последней
///   компиляции — поэтому отвечает и тогда, когда файл правят.
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
    /// По сессии на открытый проект: окон с проектами может быть несколько.
    private static var sessions: [Rustlyn] = []
    /// Сессия проекта в окне, которое сейчас впереди.
    private static weak var active: Rustlyn?

    /// Сессия проекта в переднем окне — для того, что не знает своего файла.
    ///
    /// Ставится с главного потока (открытие проекта, смена окна), а читается
    /// отовсюду: подсветка — с главного, структура и индекс — с фоновых.
    /// Поэтому за замком. Сама сессия внутри потокобезопасна — замок только
    /// про то, какие из них сейчас есть.
    static var shared: Rustlyn? {
        lock.lock()
        defer { lock.unlock() }
        return active ?? sessions.last
    }

    /// Сессия проекта, которому принадлежит файл: та, чей корень над ним
    /// ближе всех, — worktree внутри репозитория это свой проект. Файл вне
    /// всех проектов (сборка движка Unity) — у переднего окна.
    static func session(for url: URL) -> Rustlyn? {
        lock.lock()
        defer { lock.unlock() }
        let path = url.path
        let owner = sessions
            .filter { path.hasPrefix($0.root.path.hasSuffix("/") ? $0.root.path : $0.root.path + "/") }
            .max { $0.root.path.count < $1.root.path.count }
        return owner ?? active ?? sessions.last
    }

    /// Открывает сессию для проекта. `replacing` — прежняя сессия того же
    /// окна: она закрывается.
    ///
    /// `symbols` — символы препроцессора проекта: от них зависит, какая ветка
    /// `#if` живая, а значит — что вообще попадёт в подсветку, структуру и
    /// индекс. Кэш у сессий с разными символами разный, и это правильно:
    /// один и тот же файл под разными символами — разный код.
    @discardableResult
    static func start(root: URL, symbols: [String] = [], replacing old: Rustlyn? = nil) -> Rustlyn? {
        let fresh = Rustlyn(root: root, symbols: symbols)
        lock.lock()
        sessions.removeAll { $0 === old }
        if let fresh {
            sessions.append(fresh)
            active = fresh
        }
        lock.unlock()
        old?.saveInBackground()
        return fresh
    }

    static func stop(_ session: Rustlyn?) {
        guard let session else { return }
        lock.lock()
        sessions.removeAll { $0 === session }
        lock.unlock()
        session.saveInBackground()
    }

    /// Окно проекта вышло вперёд: его сессия отвечает за файлы вне проектов.
    static func activate(_ session: Rustlyn?) {
        guard let session else { return }
        lock.lock()
        active = session
        lock.unlock()
    }

    /// Папки кэша, в которые сейчас пишут живые сессии: удалять их незачем
    /// до закрытия проекта (Настройки → Кэши).
    static func foldersInUse() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(sessions.compactMap(\.cacheFolder?.path))
    }

    /// Выход из Pilot: снимки компиляции пишутся здесь же, синхронно, —
    /// после возврата процесса уже нет. Нечего писать (не компилировали или
    /// не менялось с прошлой записи) — сессия пропускается сразу.
    static func persist() {
        lock.lock()
        let all = sessions
        lock.unlock()
        for session in all { _ = session.saveCompilation() }
        // Окна, закрытые перед выходом, пишут свои снимки фоном — дождаться.
        saving.sync {}
    }

    private static let saving = DispatchQueue(label: "pilot.rustlyn.save", qos: .utility)

    /// Проект закрыт или сменён: его компиляция нужна при следующем открытии,
    /// а ждать записи десятков мегабайт закрытию незачем. Сессия живёт, пока
    /// очередь её держит.
    private func saveInBackground() {
        Rustlyn.saving.async { _ = self.saveCompilation() }
    }

    private let handle: OpaquePointer

    let root: URL

    /// Папка кэша проекта (`CacheStore.Locations.rustlynFolder`) — рядом с
    /// прочими кэшами Pilot, по одной на проект: у двух проектов бывают
    /// файлы с одинаковым путём относительно корня. nil — разбор файлов не
    /// хранится (Настройки → Кэши): сессия держит всё в памяти, а
    /// компиляцию писать некуда. Берётся при открытии проекта и до его
    /// закрытия не меняется.
    let cacheFolder: URL?

    private init?(root: URL, symbols: [String]) {
        self.root = root
        let caches = CacheStore.rustlynCaches(root: root, policy: .current)
        cacheFolder = caches.project
        if let folder = caches.project {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        // Массив C-строк живёт ровно до конца вызова: Rust копирует их себе.
        // Элементы опциональные — так `const char *const *` приходит в Swift.
        let defined: [UnsafeMutablePointer<CChar>?] = symbols.map { strdup($0) }
        defer { defined.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = defined.map { $0.map { UnsafePointer($0) } }

        let session: OpaquePointer? = root.path.withCString { rootPath in
            Rustlyn.withOptionalCString(caches.project?.path) { cachePath in
                pointers.withUnsafeMutableBufferPointer { buffer in
                    rln_session_new(rootPath, cachePath,
                                    buffer.baseAddress, buffer.count)
                }
            }
        }
        guard let session else { return nil }
        handle = session
        // Декомпилированные сборки — общие для всех проектов: движок Unity
        // одной версии — один и тот же файл в каждом проекте, и разбирать
        // `UnityEditor` (секунды) заново для каждого незачем. Не хранятся —
        // хранилище всё равно общее, но в памяти (`CacheStore.nowhere`):
        // без него Rustlyn сложил бы сборки в папку проекта.
        if caches.keepsAssemblies {
            try? FileManager.default.createDirectory(at: caches.assemblies, withIntermediateDirectories: true)
        }
        _ = caches.assemblies.path.withCString { rln_session_share_assembly_cache(session, $0) }
    }

    deinit {
        rln_session_free(handle)
    }

    /// Компиляция хранится между запусками: есть папка и её не выключили.
    /// Спрашивается при каждой записи — выключенную в настройках открытый
    /// проект перестаёт писать сразу, а не со следующего открытия.
    private var keepsCompilation: Bool {
        cacheFolder != nil && CachePolicy.current.stores(.compilation)
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

    /// То же по пути строкой — для списков из индекса файлов (см. `CSharpSources`).
    static func understands(path: String) -> Bool { CSharpSources.contains(path) }

    /// Исходники Rustlyn среди путей индекса — абсолютными путями.
    static func sources(among files: [String], root: URL) -> [String] {
        CSharpSources.among(files, root: root)
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        DeepStack.run { url.path.withCString { rln_open(handle, $0) == RLN_OK } }
    }

    /// Открыть буфер, текст которого уже в руках: несохранённый или тот,
    /// что разошёлся с диском.
    @discardableResult
    func open(_ url: URL, text: String) -> Bool {
        DeepStack.run {
            url.path.withCString { path in
                text.withCString { body in
                    rln_open_text(handle, path, body) == RLN_OK
                }
            }
        }
    }

    /// Заменить текст открытого файла. Всё, что про него было посчитано,
    /// выбрасывается — поэтому это вызов на устоявшуюся правку, а не на
    /// каждое нажатие клавиши.
    @discardableResult
    func setText(_ url: URL, _ text: String) -> Bool {
        DeepStack.run {
            url.path.withCString { path in
                text.withCString { body in
                    rln_set_text(handle, path, body) == RLN_OK
                }
            }
        }
    }

    func close(_ url: URL) {
        url.path.withCString { rln_close(handle, $0) }
    }

    /// Код, который написал генератор исходников (в Unity — то, что его
    /// генераторы оставили компилятору): компилируется, по нему можно
    /// ходить, но править нельзя — следующая компиляция в Unity перепишет.
    func isGenerated(_ url: URL) -> Bool {
        url.path.withCString { rln_is_generated(handle, $0) }
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
        let status = DeepStack.run { url.path.withCString { rln_outline(handle, $0, &raw) } }
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
        reindex(paths: urls.map(\.path))
    }

    /// То же по абсолютным путям — так их отдаёт `sources(among:root:)`.
    @discardableResult
    func reindex(paths files: [String]) -> IndexReport {
        var report = RlnReport()
        let paths: [UnsafeMutablePointer<CChar>?] = files.map { strdup($0) }
        defer { paths.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = paths.map { $0.map { UnsafePointer($0) } }
        let status = DeepStack.run { pointers.withUnsafeMutableBufferPointer { buffer in
            rln_reindex(handle, buffer.baseAddress, buffer.count, &report)
        } }
        guard status == RLN_OK else { return IndexReport() }
        return IndexReport(files: report.files, reused: report.reused,
                           parsed: report.parsed, unreadable: report.unreadable)
    }

    /// Куда ведёт имя в позиции `offset` (UTF-16, как везде в редакторе).
    ///
    /// `text` — несохранённый текст буфера, `nil` — файл как на диске.
    /// Смещение — в тот текст, который передан, и места в этом же файле
    /// приходят тоже в нём. Пока проект не скомпилирован, отвечает индекс
    /// объявлений; после — компилятор, и индекс — там, где тот не знает.
    func definition(_ url: URL, offset: Int, text: String? = nil) -> RustlynDefinition {
        var raw = RlnLocations()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_definition_in(handle, path, body, UInt32(max(0, offset)), &raw)
            }
        } }
        return finish(status, raw)
    }

    /// Кто наследует или переопределяет то, что в позиции `offset`.
    func implementations(_ url: URL, offset: Int) -> RustlynDefinition {
        var raw = RlnLocations()
        let status = DeepStack.run { url.path.withCString {
            rln_implementations(handle, $0, UInt32(max(0, offset)), &raw)
        } }
        return finish(status, raw)
    }

    private func finish(_ status: RlnStatus, _ raw: RlnLocations) -> RustlynDefinition {
        guard status == RLN_OK else {
            return RustlynDefinition(refusal: RustlynRefusal(status), reason: lastError)
        }
        defer { rln_locations_free(raw) }
        return RustlynDefinition(raw, root: root)
    }

    // MARK: - Слой 6: смысл кода

    /// Скомпилировать проект: что компилировать и против каких сборок,
    /// Rustlyn узнаёт из `.sln`/`.csproj`, а без них — у Unity или у .NET на
    /// машине. `urls` — исходники, о которых знает Pilot; пустой список —
    /// те, что в индексе.
    ///
    /// Блокирует на всё время компиляции — секунды на большом проекте, —
    /// поэтому только с фона. Прежняя компиляция отвечает, пока идёт новая,
    /// а файлы, не изменившиеся с прошлого раза, заново не разбираются.
    func compile(_ urls: [URL] = []) -> RustlynCompiled? {
        var raw = RlnCompiled()
        let paths: [UnsafeMutablePointer<CChar>?] = urls.map { strdup($0.path) }
        defer { paths.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = paths.map { $0.map { UnsafePointer($0) } }
        let status = DeepStack.run { pointers.withUnsafeMutableBufferPointer { buffer in
            rln_compile(handle, buffer.baseAddress, buffer.count, &raw)
        } }
        guard status == RLN_OK else { return nil }
        return RustlynCompiled(files: raw.files, references: raw.references,
                               projects: raw.projects, milliseconds: Int(raw.milliseconds),
                               kind: RustlynProjectKind(rawValue: raw.kind) ?? .folder,
                               unchanged: raw.unchanged)
    }

    /// Записать компиляцию в кэш проекта, если она изменилась с прошлой
    /// записи или чтения. Для закрытия проекта и выхода: на большом проекте
    /// это десятки мегабайт и доли секунды. Компиляцию не хранят — `false`
    /// сразу.
    @discardableResult
    func saveCompilation() -> Bool {
        guard keepsCompilation else { return false }
        return DeepStack.run { rln_save_compilation(handle) == RLN_OK }
    }

    /// Прочитать компиляцию, которую записал прошлый запуск: компилятор
    /// отвечает сразу, не дожидаясь компиляции. Она могла устареть —
    /// следующая `compile` это выяснит и заменит её, только если что-то
    /// изменилось. `nil` — читать нечего, её писала другая сборка
    /// библиотеки или компиляцию не хранят: тогда проект компилируется,
    /// как в первый раз.
    func loadCompilation() -> RustlynCompiled? {
        guard keepsCompilation else { return nil }
        var raw = RlnCompiled()
        guard DeepStack.run({ rln_load_compilation(handle, &raw) }) == RLN_OK else { return nil }
        return RustlynCompiled(files: raw.files, references: raw.references,
                               projects: raw.projects, milliseconds: Int(raw.milliseconds),
                               kind: RustlynProjectKind(rawValue: raw.kind) ?? .folder,
                               unchanged: raw.unchanged)
    }

    // MARK: - Горячая перезагрузка Unity

    /// Начать горячую перезагрузку: генераторы по всему `Assembly-CSharp`,
    /// компиляция с их выводом и сборка, на которой редактор перезагрузится.
    /// `tools` — пути к `dotnet`, `gend`, `minigen`, `runtime`. Десятки
    /// секунд — только с фона. Ответ — JSON из `rln_hot_start`.
    func hotStart(tools: [String: String]) -> [String: Any] {
        let json = (try? JSONSerialization.data(withJSONObject: tools, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return Self.answer(DeepStack.run { json.withCString { rln_hot_start(handle, $0, nil, 0) } })
    }

    /// Чем оборачивается сохранение `saved` (абсолютные пути): заплатка,
    /// «ничего не поменялось», «не компилируется», «только перезагрузка».
    func hotSave(_ saved: [String]) -> [String: Any] {
        let copies: [UnsafeMutablePointer<CChar>?] = saved.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = copies.map { $0.map { UnsafePointer($0) } }
        return Self.answer(DeepStack.run { pointers.withUnsafeMutableBufferPointer { buffer in
            rln_hot_save(handle, buffer.baseAddress, buffer.count, nil, 0)
        } })
    }

    /// Текст файла, каким его знает сборка, на которой редактор: чем была
    /// правка, сделанная мимо Pilot.
    func hotBaseText(_ path: String) -> String? {
        guard let copy = strdup(path) else { return nil }
        defer { free(copy) }
        var pointer: UnsafePointer<CChar>? = UnsafePointer(copy)
        return Self.answer(rln_hot_base_text(handle, &pointer))["text"] as? String
    }

    /// Сборка целиком, чтобы редактор перезагрузился на ней.
    func hotRebuild() -> [String: Any] {
        Self.answer(DeepStack.run { rln_hot_rebuild(handle, nil, 0) })
    }

    private static func answer(_ text: RlnString) -> [String: Any] {
        defer { rln_text_free(text) }
        guard let bytes = text.bytes, text.length > 0 else { return [:] }
        let data = Data(bytes: bytes, count: text.length)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// Все использования имени в позиции `offset` по проекту, вместе с его
    /// объявлениями. `text` — как у `definition`.
    func references(_ url: URL, offset: Int, text: String? = nil) -> RustlynDefinition {
        var raw = RlnLocations()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_references(handle, path, body, UInt32(max(0, offset)), &raw)
            }
        } }
        return finish(status, raw)
    }

    /// Что можно написать в позиции `offset`: члены типа слева от точки
    /// или всё, что видно отсюда. `text` почти всегда несохранённый —
    /// дополнение спрашивают, пока набирают.
    func completions(_ url: URL, offset: Int, text: String?) -> RustlynCompletions? {
        var raw = RlnCompletions()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_completions(handle, path, body, UInt32(max(0, offset)), &raw)
            }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_completions_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        var result = RustlynCompletions(start: Int(raw.start))
        guard let items = raw.items else { return result }
        result.items = UnsafeBufferPointer(start: items, count: raw.count).map { item in
            RustlynCompletion(label: Rustlyn.read(blob, item.label),
                              detail: Rustlyn.read(blob, item.detail),
                              kind: RustlynCompletionKind(rawValue: item.kind) ?? .field,
                              rank: Int(item.rank))
        }
        return result
    }

    /// Имя в позиции `offset` одной строкой: `int Count`, `void Add(T item)`.
    func describe(_ url: URL, offset: Int, text: String? = nil) -> String? {
        var out = RlnString()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_describe(handle, path, body, UInt32(max(0, offset)), &out)
            }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_text_free(out) }
        guard let bytes = out.bytes else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: out.length), as: UTF8.self)
    }

    /// Что не так в файле: синтаксис, а когда проект скомпилирован — и
    /// объявления с телами. Разбирает и связывает файл целиком — звать из
    /// фона, после паузы в наборе.
    func diagnostics(_ url: URL, text: String?) -> RustlynDiagnostics? {
        var raw = RlnDiagnostics()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in rln_diagnostics(handle, path, body, &raw) }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_diagnostics_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        var result = RustlynDiagnostics(semantic: raw.semantic)
        guard let items = raw.items else { return result }
        let all = UnsafeBufferPointer(start: items, count: raw.count).map { item in
            RustlynDiagnostic(range: NSRange(location: Int(item.start), length: Int(item.length)),
                              severity: RustlynDiagnostic.Severity(rawValue: item.severity) ?? .error,
                              code: Rustlyn.read(blob, item.code),
                              message: Rustlyn.read(blob, item.message),
                              unnecessary: item.tags & 1 != 0,
                              deprecated: item.tags & 2 != 0)
        }
        result.items = all.filter { $0.severity != .hidden }
        result.faded = all.filter { $0.severity == .hidden }
        return result
    }

    /// Подсказки в строках для `range` файла: имена параметров перед
    /// аргументами, типы после `var`. Связывает тела в диапазоне — звать из
    /// фона. `nil` — проект ещё не скомпилирован.
    func inlayHints(_ url: URL, text: String?, range: NSRange) -> [RustlynInlayHint]? {
        var raw = RlnInlayHints()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_inlay_hints(handle, path, body, UInt32(max(0, range.location)),
                                UInt32(max(0, NSMaxRange(range))), rln_inlay_default_options(), &raw)
            }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_inlay_hints_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        guard let items = raw.items else { return [] }
        return UnsafeBufferPointer(start: items, count: raw.count).map { item in
            RustlynInlayHint(position: Int(item.position),
                             label: Rustlyn.read(blob, item.label),
                             kind: RustlynInlayHint.Kind(rawValue: item.kind) ?? .type,
                             paddingLeft: UInt32(item.flags) & UInt32(RLN_INLAY_PADDING_LEFT) != 0,
                             paddingRight: UInt32(item.flags) & UInt32(RLN_INLAY_PADDING_RIGHT) != 0)
        }
    }

    /// Сколько использований по проекту у каждого типа и члена, объявленного
    /// в файле. Один проход поиска на все, но по всему проекту — из фона.
    func codeLens(_ url: URL, text: String?) -> [RustlynLens]? {
        var raw = RlnLenses()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in rln_code_lens(handle, path, body, &raw) }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_lenses_free(raw) }
        guard let items = raw.items else { return [] }
        return UnsafeBufferPointer(start: items, count: raw.count).map {
            RustlynLens(range: NSRange(location: Int($0.start), length: Int($0.length)), count: Int($0.count))
        }
    }

    /// Бросить подсчёт `codeLens`, который идёт сейчас: его числа уже никому
    /// не нужны, а поиск по проекту занимает все ядра. Начатый после — не
    /// задевает. С любого потока.
    func cancelCodeLens() {
        rln_cancel_code_lens(handle)
    }

    /// Где будут счётчики `codeLens` — имена объявлений, в том же порядке, —
    /// без самих чисел (`count` — nil). Смотрит только этот файл, поэтому
    /// годится при открытии: место под счётчики отводится сразу, а числа,
    /// которым нужен поиск по проекту, приходят потом и строк не двигают.
    func codeLensPlaces(_ url: URL, text: String?) -> [RustlynLens]? {
        var raw = RlnLenses()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in rln_code_lens_places(handle, path, body, &raw) }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_lenses_free(raw) }
        guard let items = raw.items else { return [] }
        return UnsafeBufferPointer(start: items, count: raw.count).map {
            RustlynLens(range: NSRange(location: Int($0.start), length: Int($0.length)), count: nil)
        }
    }

    /// Перегрузки вызова, в скобках которого `offset`. `nil` — не в скобках
    /// вызова или проект ещё не скомпилирован.
    func signatures(_ url: URL, offset: Int, text: String?) -> RustlynSignatures? {
        var raw = RlnSignatures()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_signatures(handle, path, body, UInt32(max(0, offset)), &raw)
            }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_signatures_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        let parameters = raw.parameters.map { UnsafeBufferPointer(start: $0, count: raw.parameter_count) }
        guard let items = raw.items, raw.count > 0 else { return nil }
        let signatures = UnsafeBufferPointer(start: items, count: raw.count).map { item in
            let first = Int(item.first_parameter)
            let ranges: [NSRange] = (0..<Int(item.parameter_count)).compactMap { index in
                guard let parameters, first + index < parameters.count else { return nil }
                let range = parameters[first + index]
                return NSRange(location: Int(range.start), length: Int(range.end) - Int(range.start))
            }
            return RustlynSignature(label: Rustlyn.read(blob, item.label), parameters: ranges)
        }
        return RustlynSignatures(items: signatures, active: Int(raw.active), parameter: Int(raw.parameter))
    }

    /// Документация имени в `offset`: его `///` или XML рядом со сборкой.
    func documentation(_ url: URL, offset: Int, text: String?) -> RustlynDocumentation? {
        var raw = RlnDocumentation()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_documentation(handle, path, body, UInt32(max(0, offset)), &raw)
            }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_documentation_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        let parameters = raw.parameters.map {
            UnsafeBufferPointer(start: $0, count: raw.parameter_count).map { parameter in
                (name: Rustlyn.read(blob, parameter.name), text: Rustlyn.read(blob, parameter.text))
            }
        } ?? []
        return RustlynDocumentation(signature: Rustlyn.read(blob, raw.signature),
                                    container: Rustlyn.read(blob, raw.container),
                                    summary: Rustlyn.read(blob, raw.summary),
                                    parameters: parameters,
                                    returns: Rustlyn.read(blob, raw.returns))
    }

    /// Можно ли переименовать то, что в позиции `offset`. `nil` — проект
    /// ещё не скомпилирован или библиотека отказала.
    func prepareRename(_ url: URL, offset: Int, text: String?) -> RustlynRenameInfo? {
        var raw = RlnRenameInfo()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_prepare_rename(handle, path, body, UInt32(max(0, offset)), &raw)
            }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_rename_info_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        let refused = Rustlyn.read(blob, raw.refused)
        return RustlynRenameInfo(range: NSRange(location: Int(raw.start), length: Int(raw.length)),
                                 text: Rustlyn.read(blob, raw.text),
                                 description: Rustlyn.read(blob, raw.description),
                                 refused: raw.can_rename != 0 ? nil : (refused.isEmpty ? "Не переименовать" : refused))
    }

    /// Переименовать то, что в позиции `offset`, в `newName` по всему
    /// проекту, как Roslyn: вместе с тем, что оно переопределяет или
    /// реализует, и со всем, что переопределяет или реализует его. Ничего
    /// не пишет — только считает правки. Компилирует изменённые файлы
    /// заново, чтобы найти конфликты, — поэтому с фона.
    func rename(_ url: URL, offset: Int, to newName: String, text: String?,
                options: RustlynRenameOptions) -> RustlynRenameResult? {
        var raw = RlnRenameResult()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                newName.withCString { name in
                    rln_rename(handle, path, body, UInt32(max(0, offset)), name, options.rawValue, &raw)
                }
            }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_rename_result_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.edits.strings, count: raw.edits.strings_length)
        let path = { (text: RlnText) in URL(fileURLWithPath: Rustlyn.read(blob, text)) }
        var result = RustlynRenameResult()
        let refused = Rustlyn.read(blob, raw.refused)
        result.refused = refused.isEmpty ? nil : refused
        if let items = raw.edits.items {
            result.edits = UnsafeBufferPointer(start: items, count: raw.edits.count).map {
                RustlynFileEdit(url: path($0.path),
                                range: NSRange(location: Int($0.start), length: Int($0.length)),
                                text: Rustlyn.read(blob, $0.text))
            }
        }
        if let renames = raw.edits.renames {
            result.files = UnsafeBufferPointer(start: renames, count: raw.edits.rename_count).map {
                RustlynFileMove(from: path($0.from), to: path($0.to))
            }
        }
        if let conflicts = raw.conflicts {
            result.conflicts = UnsafeBufferPointer(start: conflicts, count: raw.conflict_count).map {
                RustlynRenameConflict(url: path($0.path),
                                      range: NSRange(location: Int($0.start), length: Int($0.length)),
                                      message: Rustlyn.read(blob, $0.message),
                                      resolved: $0.resolved != 0)
            }
        }
        return result
    }

    // MARK: - Лампочка (⌥↩)

    /// Исправления ошибок в `range` и рефакторинги выделения, каждое — с
    /// правками. Нужна компиляция, поэтому с фона.
    func codeActions(_ url: URL, range: NSRange, text: String?) -> [RustlynCodeAction]? {
        var raw = RlnCodeActions()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_code_actions(handle, path, body, UInt32(max(0, range.location)),
                                 UInt32(max(0, NSMaxRange(range))), &raw)
            }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_code_actions_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        let edits = raw.edits.map { UnsafeBufferPointer(start: $0, count: raw.edit_count).map { Self.edit($0, blob) } } ?? []
        let moves = raw.renames.map { UnsafeBufferPointer(start: $0, count: raw.rename_count).map { Self.move($0, blob) } } ?? []
        guard let items = raw.items else { return [] }
        return UnsafeBufferPointer(start: items, count: raw.count).map { item in
            let e = Int(item.first_edit), r = Int(item.first_rename)
            return RustlynCodeAction(
                title: Rustlyn.read(blob, item.title),
                fixes: Rustlyn.read(blob, item.fixes),
                kind: RustlynCodeAction.Kind(rawValue: item.kind) ?? .refactor,
                edits: Array(edits[min(e, edits.count)..<min(e + Int(item.edit_count), edits.count)]),
                files: Array(moves[min(r, moves.count)..<min(r + Int(item.rename_count), moves.count)]))
        }
    }

    /// Исправление диагностики `code` везде в файле или во всём проекте.
    func fixAll(_ url: URL, code: String, inProject: Bool, text: String?) -> RustlynEdits? {
        var raw = RlnEdits()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                code.withCString { code in
                    rln_fix_all(handle, path, body, code,
                                UInt8(inProject ? RLN_FIX_ALL_PROJECT : RLN_FIX_ALL_DOCUMENT), &raw)
                }
            }
        } }
        return edits(status, raw)
    }

    // MARK: - Форматирование

    /// Правки, которые форматируют весь файл по правилам Roslyn и
    /// `.editorconfig`. Только синтаксис: работает и до компиляции.
    func formatDocument(_ url: URL, text: String?) -> RustlynEdits? {
        var raw = RlnEdits()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in rln_format_document(handle, path, body, &raw) }
        } }
        return edits(status, raw)
    }

    /// То же для строк, которых касается `range`, и ни для каких других.
    func formatRange(_ url: URL, range: NSRange, text: String?) -> RustlynEdits? {
        var raw = RlnEdits()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_format_range(handle, path, body, UInt32(max(0, range.location)),
                                 UInt32(max(0, NSMaxRange(range))), &raw)
            }
        } }
        return edits(status, raw)
    }

    private func edits(_ status: RlnStatus, _ raw: RlnEdits) -> RustlynEdits? {
        guard status == RLN_OK else { return nil }
        defer { rln_edits_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        var result = RustlynEdits()
        if let items = raw.items {
            result.edits = UnsafeBufferPointer(start: items, count: raw.count).map { Self.edit($0, blob) }
        }
        if let renames = raw.renames {
            result.files = UnsafeBufferPointer(start: renames, count: raw.rename_count).map { Self.move($0, blob) }
        }
        return result
    }

    private static func edit(_ raw: RlnEdit, _ blob: UnsafeBufferPointer<UInt8>) -> RustlynFileEdit {
        RustlynFileEdit(url: URL(fileURLWithPath: Rustlyn.read(blob, raw.path)),
                        range: NSRange(location: Int(raw.start), length: Int(raw.length)),
                        text: Rustlyn.read(blob, raw.text))
    }

    private static func move(_ raw: RlnRename, _ blob: UnsafeBufferPointer<UInt8>) -> RustlynFileMove {
        RustlynFileMove(from: URL(fileURLWithPath: Rustlyn.read(blob, raw.from)),
                        to: URL(fileURLWithPath: Rustlyn.read(blob, raw.to)))
    }

    // MARK: - Иерархии вызовов и типов

    /// Метод, свойство, поле или конструктор под курсором — корень иерархии вызовов.
    func callHierarchy(_ url: URL, offset: Int, text: String?) -> RustlynHierarchyItem? {
        var raw = RlnHierarchyItems()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in rln_call_hierarchy(handle, path, body, UInt32(max(0, offset)), &raw) }
        } }
        return hierarchy(status, raw)?.first
    }

    /// Тип под курсором или тип того, что под курсором, — корень иерархии типов.
    func typeHierarchy(_ url: URL, offset: Int, text: String?) -> RustlynHierarchyItem? {
        var raw = RlnHierarchyItems()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in rln_type_hierarchy(handle, path, body, UInt32(max(0, offset)), &raw) }
        } }
        return hierarchy(status, raw)?.first
    }

    func supertypes(_ key: String) -> [RustlynHierarchyItem]? {
        var raw = RlnHierarchyItems()
        let status = DeepStack.run { key.withCString { rln_supertypes(handle, $0, &raw) } }
        return hierarchy(status, raw)
    }

    func subtypes(_ key: String) -> [RustlynHierarchyItem]? {
        var raw = RlnHierarchyItems()
        let status = DeepStack.run { key.withCString { rln_subtypes(handle, $0, &raw) } }
        return hierarchy(status, raw)
    }

    func incomingCalls(_ key: String) -> [RustlynCall]? {
        var raw = RlnCalls()
        let status = DeepStack.run { key.withCString { rln_incoming_calls(handle, $0, &raw) } }
        return calls(status, raw)
    }

    func outgoingCalls(_ key: String) -> [RustlynCall]? {
        var raw = RlnCalls()
        let status = DeepStack.run { key.withCString { rln_outgoing_calls(handle, $0, &raw) } }
        return calls(status, raw)
    }

    private func hierarchy(_ status: RlnStatus, _ raw: RlnHierarchyItems) -> [RustlynHierarchyItem]? {
        guard status == RLN_OK else { return nil }
        defer { rln_hierarchy_items_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        guard let items = raw.items else { return [] }
        return UnsafeBufferPointer(start: items, count: raw.count).map { hierarchyItem($0, blob) }
    }

    private func calls(_ status: RlnStatus, _ raw: RlnCalls) -> [RustlynCall]? {
        guard status == RLN_OK else { return nil }
        defer { rln_calls_free(raw) }
        let blob = UnsafeBufferPointer(start: raw.strings, count: raw.strings_length)
        let ranges = raw.ranges.map { UnsafeBufferPointer(start: $0, count: raw.range_count).map {
            LSPRange(start: LSPPosition(line: Int($0.start_line), character: Int($0.start_character)),
                     end: LSPPosition(line: Int($0.end_line), character: Int($0.end_character)))
        } } ?? []
        guard let items = raw.items else { return [] }
        return UnsafeBufferPointer(start: items, count: raw.count).map { call in
            let path = Rustlyn.read(blob, call.path)
            let first = Int(call.first_range)
            return RustlynCall(
                item: hierarchyItem(call.item, blob),
                url: path.isEmpty ? nil : RustlynTarget.url(forPath: path, root: root),
                ranges: Array(ranges[min(first, ranges.count)..<min(first + Int(call.range_count), ranges.count)]),
                throughBase: call.through_base)
        }
    }

    private func hierarchyItem(_ raw: RlnHierarchyItem, _ blob: UnsafeBufferPointer<UInt8>) -> RustlynHierarchyItem {
        let name = Rustlyn.read(blob, raw.name)
        let path = Rustlyn.read(blob, raw.path)
        let target = raw.has_location && !path.isEmpty
            ? RustlynTarget(url: RustlynTarget.url(forPath: path, root: root), name: name,
                            line: Int(raw.line), character: Int(raw.character), length: Int(raw.length),
                            kind: RustlynDeclarationKind(rawValue: raw.kind) ?? .method)
            : nil
        return RustlynHierarchyItem(name: name, detail: Rustlyn.read(blob, raw.detail),
                                    container: Rustlyn.read(blob, raw.container),
                                    key: Rustlyn.read(blob, raw.key), target: target)
    }

    /// Всё более крупные куски кода вокруг выделения — шаги ⌥↑. Только
    /// синтаксис: работает и до компиляции.
    func selectionRanges(_ url: URL, selection: NSRange, text: String?) -> [NSRange]? {
        var raw = RlnRanges()
        let status = DeepStack.run { url.path.withCString { path in
            Self.withOptionalCString(text) { body in
                rln_selection_ranges(handle, path, body, UInt32(max(0, selection.location)),
                                     UInt32(max(0, NSMaxRange(selection))), &raw)
            }
        } }
        guard status == RLN_OK else { return nil }
        defer { rln_ranges_free(raw) }
        guard let items = raw.items else { return [] }
        return UnsafeBufferPointer(start: items, count: raw.count).map {
            NSRange(location: Int($0.start), length: Int($0.end) - Int($0.start))
        }
    }

    /// C-строка на время вызова, или null — «текст как на диске».
    private static func withOptionalCString<T>(_ text: String?,
                                               _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let text else { return body(nil) }
        return text.withCString { body($0) }
    }

    // MARK: - Слой 5: сборки

    /// Сборка, показанная как C#: типы, члены, сигнатуры. Тел методов здесь
    /// нет — их отдаёт `methodBody(_:token:)`, по одному и по запросу.
    func assemblyText(_ url: URL) -> String? {
        var text = RlnString()
        let status = DeepStack.run { url.path.withCString { rln_assembly_text(handle, $0, &text) } }
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
        let status = DeepStack.run { url.path.withCString { rln_method_body(handle, $0, token, &text) } }
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
            && rln_class_count() == UInt32(TokenKind.rustlynCount)
            && rln_completion_kind_count() == UInt32(RustlynCompletionKind.allCases.count)
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
                url: RustlynTarget.url(forPath: Rustlyn.read(blob, item.path), root: root),
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
        case RLN_NOT_COMPILED:     self = .notCompiled
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
