import SwiftUI
import AppKit
import Combine

@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var isIndexing = false
    @Published private(set) var fileCount = 0
    /// Индекс типов строится после индекса файлов и заметно дольше.
    @Published private(set) var isTypeIndexing = false
    @Published private(set) var typeCount = 0
    /// Индекс объявлений проекта. На нём работает быстрый навигатор (⌘B, ⌘T,
    /// ⌘R), пока Roslyn греется; строится тем же проходом, что и индекс типов.
    @Published private(set) var symbolIndex: SymbolIndex?
    /// Roslyn «готов» сразу после рукопожатия, а solution грузит ещё минуты:
    /// до тех пор его ответы пусты или неполны. Доверять ему начинаем, когда
    /// он впервые что-то нашёл; до этого первым отвечает быстрый навигатор.
    @Published private(set) var languageServerProven = false
    /// Дерево папок для боковой панели. Строится из того же индекса, что и ⌘P.
    @Published private(set) var fileTree: FileTree?
    @Published var query = "" { didSet { queryChanged() } }
    @Published private(set) var results: [SearchHit] = []
    @Published private(set) var items: [PaletteItem] = []
    /// Открытый в редакторе файл: текст, история правок, синтаксическая модель.
    @Published private(set) var buffer: TextBuffer?
    /// Открытый документ. Модель в нём та же, что правит редактор.
    var document: LoadedDocument? { buffer?.document }
    /// Файлы с несохранёнными правками. Живут в памяти, пока смотрим другие:
    /// вернулся — правки и история отмены на месте.
    private var unsaved: [URL: TextBuffer] = [:]
    @Published private(set) var unsavedCount = 0
    @Published private(set) var loadError: String?
    @Published var selection: Int = 0
    @Published var isPaletteOpen = false
    @Published private(set) var paletteMode: PaletteMode = .files
    @Published private(set) var paletteBusy = false
    @Published var fontSize: CGFloat = 12.5

    /// Куда проскроллить и что подсветить. Порядковый номер нужен, чтобы
    /// повторный переход в то же самое место всё равно сработал.
    struct RevealRequest: Equatable {
        var seq: Int
        var range: LSPRange?
    }
    @Published private(set) var reveal: RevealRequest?
    private var revealCounter = 0

    func requestReveal(_ range: LSPRange?) {
        revealCounter += 1
        reveal = RevealRequest(seq: revealCounter, range: range)
    }
    /// Просьба перевести фокус клавиатуры в текст; счётчик — по той же причине, что и у reveal.
    @Published private(set) var editorFocusRequest = 0

    func focusEditor() { editorFocusRequest += 1 }

    /// Курсор в открытом документе: позиция, объявление под ним, вхождения.
    /// Не @Published — см. EditorCaret.
    let caret = EditorCaret()
    var caretOffset: Int { caret.offset }
    /// Ветка git — подзаголовок окна, как в Xcode.
    @Published private(set) var branch: String?

    // MARK: Навигатор

    enum NavigatorTab: Hashable, CaseIterable {
        case project, outline, review, recent

        var icon: String {
            switch self {
            case .project: return "folder"
            case .outline: return "list.bullet.indent"
            case .review:  return "arrow.triangle.pull"
            case .recent:  return "clock"
            }
        }

        var selectedIcon: String {
            switch self {
            case .project: return "folder.fill"
            case .outline: return "list.bullet.indent"
            case .review:  return "arrow.triangle.pull"
            case .recent:  return "clock.fill"
            }
        }

        var title: String {
            switch self {
            case .project: return "Проект"
            case .outline: return "Структура файла"
            case .review:  return "Ревью мерж-реквестов"
            case .recent:  return "Недавние проекты"
            }
        }
    }

    @Published var navigatorTab: NavigatorTab = .project
    /// Фильтр вкладки «Структура» — отдельный, чтобы не сбрасывать дерево.
    @Published var outlineFilter = ""
    @Published var navigatorFilter = "" {
        didSet { if navigatorFilter != oldValue { navigatorFilterChanged() } }
    }
    /// Дерево только из файлов, подошедших под фильтр навигатора.
    @Published private(set) var filteredTree: FileTree?

    private let filterQueue = DispatchQueue(label: "pilot.filter", qos: .userInitiated)
    private let filterGeneration = AtomicCounter()
    /// Больше строк фильтр не показывает: дальше человек всё равно уточнит запрос.
    nonisolated static let navigatorFilterLimit = 2000

    private var occurrenceTask: Task<Void, Never>?
    private var occurrenceWord: String?

    let lsp = LSPService()
    let unity = UnityService()

    /// Короткое сообщение в статус-строке: «ссылка битая», «ничего не найдено».
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?
    /// Последний файл, который просили открыть, — даже если он не открылся
    /// (текстура, модель). Для «где используется ассет».
    private(set) var requestedFile: URL?
    /// Имя ассета, чьи использования сейчас в палитре.
    @Published private(set) var usagesTitle: String = ""

    private var unityChanges: AnyCancellable?
    let git = GitService()
    let review = ReviewService()
    private var observations: [AnyCancellable] = []
    private var lspObservation: AnyCancellable?
    private var lspReadyObservation: AnyCancellable?

    init() {
        unity.onAssetsReady = { [weak self] in self?.unityAssetsReady() }
        // Статус-строка и меню смотрят на воркспейс — пусть видят и Unity.
        unityChanges = unity.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Статус-строка, полоски у номеров строк и панель ревью читают git
        // и GitLab через workspace: их изменения должны перерисовывать то же,
        // что и наши.
        for publisher in [git.objectWillChange, review.objectWillChange] {
            observations.append(publisher.sink { [weak self] _ in self?.objectWillChange.send() })
        }
        git.onStatusChange = { [weak self] in self?.gitStatusChanged() }
        // То же с языковым сервером: без этого фишка в статус-строке и пункты
        // меню ⌘T/⌘R узнавали бы о его готовности только при следующем клике.
        lspObservation = lsp.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        lspReadyObservation = lsp.$state.removeDuplicates().sink { [weak self] state in
            guard state == .ready else { return }
            // Издатель срабатывает до записи нового значения — ждём её.
            Task { @MainActor in self?.languageServerBecameReady() }
        }
    }

    /// Окно у строки: удалённое, треды, новый комментарий. Номер запроса —
    /// по той же причине, что и у reveal: повторный клик по той же строке.
    struct LinePopoverRequest: Equatable {
        var seq: Int
        var line: Int
        /// Сразу с полем для нового комментария.
        var compose: Bool
    }
    @Published private(set) var linePopover: LinePopoverRequest?

    /// Конфликты слияния в открытом файле — пересчитываются на каждой правке.
    @Published private(set) var conflicts: [MergeConflict] = []
    /// Ошибка «отметить решённым» — показывается в полосе конфликтов.
    @Published var conflictError: String?

    /// Решить конфликт: правку делает редактор, чтобы она попала в ⌘Z.
    /// `start` — строка `<<<<<<<`; nil — все конфликты файла разом.
    struct ConflictActionRequest: Equatable {
        var seq: Int
        var start: Int?
        var choice: ConflictChoice
    }
    @Published private(set) var conflictAction: ConflictActionRequest?
    private var conflictActionCounter = 0

    func requestConflictAction(start: Int?, choice: ConflictChoice) {
        conflictActionCounter += 1
        conflictAction = ConflictActionRequest(seq: conflictActionCounter, start: start, choice: choice)
    }

    private func updateConflicts() {
        let fresh = buffer.map { MergeConflicts.find(in: $0.model) } ?? []
        if fresh != conflicts { conflicts = fresh }
    }
    private var popoverCounter = 0

    func requestLinePopover(line: Int, compose: Bool) {
        popoverCounter += 1
        linePopover = LinePopoverRequest(seq: popoverCounter, line: line, compose: compose)
    }

    private var index: FileIndex?
    private var typeIndex: TypeIndex?
    private let work = DispatchQueue(label: "pilot.index", qos: .userInitiated)
    /// Отдельная очередь: на крупном проекте разбор всех исходников — секунды, и на `work`
    /// он задержал бы и поиск файлов, и открытие файла.
    private let typeWork = DispatchQueue(label: "pilot.types", qos: .utility)
    /// ⌘R без сервера читает все исходники — не на `work`, чтобы в это время
    /// открывались файлы и работал поиск.
    private let referenceQueue = DispatchQueue(label: "pilot.references", qos: .userInitiated)
    private let scanGeneration = AtomicCounter()
    private let searchGeneration = AtomicCounter()
    private let loadGeneration = AtomicCounter()
    private var symbolTask: Task<Void, Never>?
    /// Полный список использований; поле ввода фильтрует его на месте.
    private var allReferences: [PaletteItem] = []

    private static let recentKey = "pilot.recentRoots"

    /// Недавние проекты, свежие первыми. Папки, которых больше нет
    /// на диске, отсеиваются при чтении — в список их не выводим.
    @Published private(set) var recentRoots: [URL] = Workspace.loadRecentRoots()

    private static func loadRecentRoots() -> [URL] {
        let fm = FileManager.default
        return (UserDefaults.standard.array(forKey: recentKey) as? [String] ?? [])
            .filter { fm.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Открытие воркспейса

    /// Старт приложения. Путь из командной строки открывается сразу,
    /// иначе остаётся стартовый экран с выбором из недавних проектов.
    func start() {
        openLaunchTarget()
    }

    /// Путь из командной строки: `Pilot /path/to/project` или `Pilot /path/File.cs`.
    /// Для файла корнем проекта становится ближайший git-репозиторий над ним.
    private func openLaunchTarget() {
        // macOS может дописать свои аргументы вида `-NSFoo YES` — берём
        // первый абсолютный путь, который существует на диске.
        var isDirectory: ObjCBool = false
        guard let path = CommandLine.arguments.dropFirst().first(where: {
            $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
        }) else { return }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        if isDirectory.boolValue {
            open(root: url)
        } else {
            open(root: Self.projectRoot(containing: url))
            open(file: url)
        }
    }

    private static func projectRoot(containing file: URL) -> URL {
        let dir = file.deletingLastPathComponent()
        return Git.repositoryRoot(for: dir) ?? dir
    }

    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Открыть"
        panel.message = "Выберите папку проекта"
        if panel.runModal() == .OK, let url = panel.url {
            open(root: url)
        }
    }

    func open(root url: URL) {
        guard confirmUnsavedChanges() else { return }
        dropAllBuffers()
        root = url
        loadError = nil
        query = ""
        results = []
        items = []
        fileTree = nil
        history.removeAll()
        historyIndex = -1
        caret.setOutlineItem(nil)
        branch = GitInfo.branch(at: url)
        navigatorFilter = ""
        filteredTree = nil
        rememberRecent(url)
        languageServerProven = false
        lsp.workspaceChanged(to: url)
        git.workspaceChanged(to: url)
        review.workspaceChanged(to: url)
        unity.workspaceChanged(to: url)
        requestedFile = nil
        let exclude: FileIndex.Exclusion? = unity.project.map { $0.excludedFromIndex }

        let generation = scanGeneration.bump()
        isIndexing = true
        typeIndex = nil
        typeCount = 0
        isTypeIndexing = true
        symbolIndex = nil

        typeWork.async { [weak self] in
            guard let cached = IndexCache.loadTypes(root: url) else { return }
            Task { @MainActor in
                // Свежий индекс мог успеть раньше — тогда кэш уже не нужен.
                guard let self, self.scanGeneration.isCurrent(generation),
                      self.typeIndex == nil else { return }
                self.adoptTypes(cached, indexing: true)
            }
        }
        // Символы из кэша — чтобы быстрый навигатор работал с первой секунды,
        // не дожидаясь разбора всего проекта.
        typeWork.async { [weak self] in
            guard let cached = IndexCache.loadSymbols(root: url) else { return }
            Task { @MainActor in
                guard let self, self.scanGeneration.isCurrent(generation),
                      self.symbolIndex == nil else { return }
                self.symbolIndex = cached
            }
        }

        work.async { [weak self] in
            guard let self else { return }
            // 1. Кэш делает повторное открытие проекта мгновенным.
            let cached = IndexCache.load(root: url, exclude: exclude)
            if let cached {
                let tree = FileTree.build(paths: cached.display)
                Task { @MainActor in
                    guard self.scanGeneration.isCurrent(generation) else { return }
                    self.adopt(cached, tree: tree, indexing: true)
                }
            }
            // 2. Всё равно пересканируем — кэш мог устареть.
            let counter = self.scanGeneration
            var shown = cached?.display
            let fresh = FileIndex.scan(root: url, exclude: exclude, shouldStop: { !counter.isCurrent(generation) },
                                       early: { early in
                // Без кэша отслеживаемые файлы от git — первое, что можно
                // показать: ⌘P начинает работать через доли секунды.
                guard cached == nil else { return }
                shown = early.display
                Task { @MainActor in
                    guard counter.isCurrent(generation) else { return }
                    self.adopt(early, tree: nil, indexing: true)
                }
                let tree = FileTree.build(paths: early.display)
                Task { @MainActor in
                    guard counter.isCurrent(generation) else { return }
                    self.fileTree = tree
                }
            })
            guard counter.isCurrent(generation) else { return }
            IndexCache.save(fresh, root: url)

            // Обычно свежий список совпадает с уже показанным один в один —
            // тогда дерево не пересобираем, и панель не перерисовывается впустую.
            let tree = shown == fresh.display ? nil : FileTree.build(paths: fresh.display)
            Task { @MainActor in
                guard self.scanGeneration.isCurrent(generation) else { return }
                self.adopt(fresh, tree: tree, indexing: false)
                self.rebuildTypeIndex(files: fresh.display, root: url, generation: generation)
            }
        }
    }

    /// `tree == nil` — оставить текущее дерево: список файлов не изменился.
    private func adopt(_ newIndex: FileIndex, tree: FileTree?, indexing: Bool) {
        index = newIndex
        fileCount = newIndex.count
        isIndexing = indexing
        if let tree { fileTree = tree }
        runFileSearch()
        runClassSearch()
        // Индекс сменился — отфильтрованное дерево собрано по старому.
        if !navigatorFilter.isEmpty { navigatorFilterChanged() }
    }

    /// Исходники разбираются по уже готовому списку файлов — второй раз
    /// обходить диск незачем. Проход один на оба индекса: символы для
    /// быстрого навигатора, а типы для ⇧⇧ просто выбираются из них.
    private func rebuildTypeIndex(files: [String], root url: URL, generation: Int) {
        let counter = scanGeneration
        typeWork.async { [weak self] in
            guard let symbols = SymbolIndex.build(root: url, files: files,
                                                  shouldStop: { !counter.isCurrent(generation) })
            else { return }
            let fresh = TypeIndex.make(root: url, entries: symbols.typeEntries())
            Task { @MainActor in
                guard let self, counter.isCurrent(generation) else { return }
                self.symbolIndex = symbols
                self.adoptTypes(fresh, indexing: false)
            }
            IndexCache.saveTypes(fresh, root: url)
            IndexCache.saveSymbols(symbols, root: url)
        }
    }

    private func adoptTypes(_ newIndex: TypeIndex, indexing: Bool) {
        typeIndex = newIndex
        typeCount = newIndex.count
        isTypeIndexing = indexing
        runClassSearch()
    }

    /// Путь открытого файла относительно корня — чтобы найти его в дереве.
    var openFilePath: String? {
        guard let url = document?.url, let root, url.path.hasPrefix(root.path + "/") else { return nil }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    /// Назад на стартовый экран. Индексация и языковой сервер
    /// старого проекта останавливаются.
    func closeProject() {
        guard confirmUnsavedChanges() else { return }
        dropAllBuffers()
        // Новое поколение отменяет обход ФС и загрузку файла, что ещё идут.
        _ = scanGeneration.bump()
        _ = loadGeneration.bump()
        languageServerProven = false
        lsp.workspaceChanged(to: nil)
        git.workspaceChanged(to: nil)
        review.workspaceChanged(to: nil)
        unity.workspaceChanged(to: nil)
        requestedFile = nil
        root = nil
        index = nil
        symbolIndex = nil
        fileTree = nil
        loadError = nil
        isIndexing = false
        fileCount = 0
        isPaletteOpen = false
        query = ""
        results = []
        items = []
        caret.reset()
        occurrenceWord = nil
        branch = nil
        navigatorFilter = ""
        filteredTree = nil
        history.removeAll()
        historyIndex = -1
    }

    // MARK: - Фильтр навигатора

    /// Как фильтр навигатора Xcode: подстрока в имени файла. Под фильтр
    /// собирается своё маленькое дерево — его панель показывает раскрытым.
    private func navigatorFilterChanged() {
        let needle = navigatorFilter.trimmingCharacters(in: .whitespaces)
        let generation = filterGeneration.bump()
        guard !needle.isEmpty, let index else {
            filteredTree = nil
            return
        }
        let counter = filterGeneration
        filterQueue.async { [weak self] in
            let ids = index.filter(name: needle, limit: Self.navigatorFilterLimit,
                                   shouldStop: { !counter.isCurrent(generation) })
            let tree = FileTree.build(paths: ids.map { index.relPath($0) })
            Task { @MainActor in
                guard let self, counter.isCurrent(generation) else { return }
                self.filteredTree = tree
            }
        }
    }

    private func rememberRecent(_ url: URL) {
        var list = recentRoots.filter { $0.path != url.path }
        list.insert(url, at: 0)
        if list.count > 10 { list.removeSubrange(10...) }
        saveRecent(list)
    }

    func forgetRecent(_ url: URL) {
        saveRecent(recentRoots.filter { $0.path != url.path })
    }

    private func saveRecent(_ list: [URL]) {
        recentRoots = list
        UserDefaults.standard.set(list.map(\.path), forKey: Self.recentKey)
    }

    // MARK: - Палитра

    func openPalette(mode: PaletteMode) {
        paletteMode = mode
        query = ""
        selection = 0
        isPaletteOpen = true
        switch mode {
        case .files:      runFileSearch()
        case .classes:    runClassSearch()
        case .symbols:    runSymbolSearch()
        case .outline:    buildOutlineItems()
        case .changes:    buildChangeItems()
        case .references, .declarations, .assetUsages: break   // наполняются переходом, findReferences() и findAssetUsages()
        }
    }

    /// ⇧⇧. Повторное ⇧⇧ при уже открытом поиске не стирает набранное.
    func openClassSearch() {
        if isPaletteOpen && paletteMode == .classes { return }
        openPalette(mode: .classes)
    }

    private func queryChanged() {
        selection = 0
        switch paletteMode {
        case .files:      runFileSearch()
        case .classes:    runClassSearch()
        case .symbols:    runSymbolSearch()
        case .references, .declarations, .assetUsages: filterReferences()
        case .outline:    buildOutlineItems()
        case .changes:    buildChangeItems()
        }
    }

    // MARK: - Git

    /// Изменённые файлы проекта. Удалённые не показываем — открывать нечего.
    /// Ранжирование и подсветка — те же, что у ⌘P: список прогоняется через
    /// маленький FileIndex.
    private func buildChangeItems() {
        guard let root else { items = []; return }
        let changed = git.changedFiles.filter { $0.value != .deleted }
        let index = FileIndex(root: root)
        // Конфликты — первыми: пока они есть, слияние не закончить.
        let ordered = changed.keys.sorted { a, b in
            let aConflict = changed[a] == .conflicted, bConflict = changed[b] == .conflicted
            return aConflict != bConflict ? aConflict : a < b
        }
        for path in ordered { index.appendCached(rel: path) }

        let hits = index.search(query, limit: 500, shouldStop: { false })
        items = hits.enumerated().map { position, hit in
            let path = index.relPath(hit.id)
            return PaletteItem(
                id: position,
                icon: Self.icon(forPath: path),
                primary: path,
                nameOffset: index.nameOffset(hit.id),
                positions: hit.positions,
                trailing: changed[path]?.letter,
                target: NavTarget(url: index.absoluteURL(hit.id), range: nil))
        }
        if selection >= items.count { selection = max(0, items.count - 1) }
    }

    /// Вернулись в приложение, а список изменённых файлов стал другим —
    /// буквы в открытой палитре должны это отразить.
    private func gitStatusChanged() {
        guard isPaletteOpen else { return }
        switch paletteMode {
        case .files:   runFileSearch()
        case .changes: buildChangeItems()
        case .classes, .outline, .symbols, .references, .declarations, .assetUsages: break
        }
    }

    /// Следующий/предыдущий изменённый блок; по кругу, как и вхождения.
    func jumpToChange(_ direction: Int) {
        let changes = editorLineChanges
        guard let document, !changes.isEmpty else { return }
        let line = document.model.line(containing: caretOffset)
        let target: LineDiff.Change?
        if direction > 0 {
            target = changes.first { $0.lines.lowerBound > line } ?? changes.first
        } else {
            target = changes.last { $0.lines.lowerBound < line } ?? changes.last
        }
        guard let target else { return }
        // Блок целиком выделяется и вспыхивает: видно, что именно поменялось.
        // Удаление за последней строкой ставит курсор на неё же.
        let model = document.model
        let first = min(target.lines.lowerBound, model.lineCount - 1)
        let last = min(max(first, target.lines.upperBound - 1), model.lineCount - 1)
        let start = LSPPosition(line: first, character: 0)
        let end = target.lines.isEmpty
            ? start
            : LSPPosition(line: last, character: model.lineRange(last).count)
        requestReveal(LSPRange(start: start, end: end))
    }

    // MARK: - Структура текущего файла
    //
    // Языковой сервер здесь не участвует: структура построена лексером
    // при открытии файла, поэтому ⌘⇧O работает с нулевой секунды.

    private func buildOutlineItems() {
        guard let document else { items = []; return }
        let matches = filterOutline(document.outline, query: query)
        items = matches.enumerated().map { position, item in
            PaletteItem(
                id: position,
                icon: item.kind.icon,
                primary: item.name,
                secondary: item.container,
                trailing: item.kind.label,
                target: NavTarget(url: document.url,
                                  range: rangeFor(item, in: document)))
        }
        if selection >= items.count { selection = max(0, items.count - 1) }
    }

    private func filterOutline(_ outline: [OutlineItem], query: String) -> [OutlineItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return outline }

        let fuzzy = FuzzyMatch.Query(trimmed)
        var scored: [(OutlineItem, Int)] = []
        for item in outline {
            var bytes = Array(item.name.lowercased().utf8)
            var positions: [Int32]? = nil
            let score: Int? = bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return nil }
                return FuzzyMatch.score(fuzzy, text: base, len: bytes.count,
                                        nameStart: 0, positions: &positions)
            }
            if let score { scored.append((item, score)) }
            bytes.removeAll(keepingCapacity: false)
        }
        scored.sort { $0.1 > $1.1 }
        return scored.map(\.0)
    }

    private func rangeFor(_ item: OutlineItem, in document: LoadedDocument) -> LSPRange {
        let start = document.model.position(at: item.range.location)
        let end = document.model.position(at: item.range.location + item.range.length)
        return LSPRange(start: start, end: end)
    }

    // MARK: - Положение курсора

    func caretMoved(to offset: Int) {
        guard offset != caretOffset else { return }
        caret.setOffset(offset)
        updateOutlineItem()
        scheduleOccurrences()
    }

    /// Объемлющее объявление — последнее, начавшееся до курсора.
    private func updateOutlineItem() {
        guard let document else { return caret.setOutlineItem(nil) }
        var current: OutlineItem?
        for item in document.outline {
            if item.range.location <= caretOffset { current = item } else { break }
        }
        caret.setOutlineItem(current)
    }

    /// Подсветка вхождений. С задержкой: при протягивании выделения
    /// курсор двигается десятки раз в секунду.
    private func scheduleOccurrences() {
        occurrenceTask?.cancel()
        guard let document else { caret.setOccurrences([]); occurrenceWord = nil; return }

        guard let identifier = Occurrences.identifier(in: document.model, at: caretOffset) else {
            caret.setOccurrences([])
            occurrenceWord = nil
            return
        }
        guard identifier.text != occurrenceWord else { return }

        occurrenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self, !Task.isCancelled, let document = self.document else { return }
            let found = Occurrences.find(identifier.text, in: document.model)
            guard !Task.isCancelled else { return }
            self.occurrenceWord = identifier.text
            self.caret.setOccurrences(found)
        }
    }

    // MARK: - Прыжки внутри файла

    /// Переход к объявлению из навигатора структуры или jump bar.
    func jump(to item: OutlineItem) {
        guard let document else { return }
        navigate(to: NavTarget(url: document.url, range: rangeFor(item, in: document)))
    }

    /// Следующее/предыдущее объявление относительно курсора.
    func jumpToMember(_ direction: Int) {
        guard let document, !document.outline.isEmpty else { return }
        let sorted = document.outline
        let target: OutlineItem?
        if direction > 0 {
            target = sorted.first { $0.range.location > caretOffset }
        } else {
            target = sorted.last { $0.range.location < caretOffset }
        }
        guard let target else { return }
        requestReveal(rangeFor(target, in: document))
    }

    /// Следующее/предыдущее вхождение слова под курсором.
    func jumpToOccurrence(_ direction: Int) {
        let occurrences = caret.occurrences
        guard let document, !occurrences.isEmpty else { return }
        let next: NSRange?
        if direction > 0 {
            next = occurrences.first { $0.location > caretOffset } ?? occurrences.first
        } else {
            next = occurrences.last { $0.location < caretOffset } ?? occurrences.last
        }
        guard let next else { return }
        let start = document.model.position(at: next.location)
        let end = document.model.position(at: next.location + next.length)
        requestReveal(LSPRange(start: start, end: end))
    }

    private func filterReferences() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { items = allReferences; return }
        items = allReferences.filter {
            $0.primary.lowercased().contains(needle)
                || ($0.secondary?.lowercased().contains(needle) ?? false)
        }
    }

    // MARK: - Поиск по файлам

    private func runFileSearch() {
        guard paletteMode == .files else { return }
        guard let index else { results = []; items = []; return }

        let generation = searchGeneration.bump()
        let counter = searchGeneration
        let q = query

        work.async { [weak self] in
            guard let self else { return }
            let hits = index.search(q, limit: 200,
                                    shouldStop: { !counter.isCurrent(generation) })
            Task { @MainActor in
                guard counter.isCurrent(generation), self.paletteMode == .files else { return }
                self.results = hits
                self.items = hits.enumerated().map { position, hit in
                    let path = index.relPath(hit.id)
                    return PaletteItem(
                        id: position,
                        icon: Self.icon(forPath: path),
                        primary: path,
                        nameOffset: index.nameOffset(hit.id),
                        positions: hit.positions,
                        trailing: self.git.changedFiles[path]?.letter,
                        target: NavTarget(url: index.absoluteURL(hit.id), range: nil))
                }
                if self.selection >= self.items.count {
                    self.selection = max(0, self.items.count - 1)
                }
            }
        }
    }

    // MARK: - Поиск по классам
    //
    // В основном — типы проекта из лексического индекса. Под ними несколько
    // файлов: если искомое оказалось не классом, а конфигом или README,
    // не нужно переключаться на ⌘P. Пока индекс типов строится впервые,
    // эти файлы — вообще всё, что есть.

    private func runClassSearch() {
        guard paletteMode == .classes else { return }
        let generation = searchGeneration.bump()
        let counter = searchGeneration
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            items = []
            return
        }
        let types = typeIndex
        let files = index

        work.async { [weak self] in
            let stop = { !counter.isCurrent(generation) }
            let typeHits = types?.search(q, limit: 150, shouldStop: stop) ?? []
            // Файл, где объявлен уже найденный тип, — повтор той же строки.
            let typeFiles = Set(typeHits.lazy.compactMap { types?.relPath($0.id) })
            var fileHits: [SearchHit] = []
            if let files {
                fileHits = Array(files.search(q, limit: 30, shouldStop: stop)
                    .filter { !typeFiles.contains(files.relPath($0.id)) }
                    .prefix(10))
            }

            Task { @MainActor in
                guard let self, counter.isCurrent(generation), self.paletteMode == .classes else { return }
                var built: [PaletteItem] = []
                built.reserveCapacity(typeHits.count + fileHits.count)
                if let types {
                    for hit in typeHits {
                        let declaration = types.declaration(hit.id)
                        let path = types.relPath(hit.id)
                        var secondary = path
                        if let container = declaration.container, !container.isEmpty {
                            secondary = "\(container) · \(path)"
                        }
                        built.append(PaletteItem(
                            id: built.count,
                            icon: TypeIndex.icon(forKeyword: declaration.keyword),
                            primary: declaration.name,
                            positions: hit.positions,
                            secondary: secondary,
                            trailing: declaration.keyword,
                            target: types.target(hit.id)))
                    }
                }
                if let files {
                    for hit in fileHits {
                        let path = files.relPath(hit.id)
                        built.append(PaletteItem(
                            id: built.count,
                            icon: Self.icon(forPath: path),
                            primary: path,
                            nameOffset: files.nameOffset(hit.id),
                            positions: hit.positions,
                            trailing: "file",
                            target: NavTarget(url: files.absoluteURL(hit.id), range: nil)))
                    }
                }
                self.items = built
                if self.selection >= self.items.count {
                    self.selection = max(0, self.items.count - 1)
                }
            }
        }
    }

    // MARK: - Навигация по проекту: быстрый индекс, затем Roslyn
    //
    // Каждый запрос (⌘B, ⌘T, ⌘R) идёт в Roslyn, если тот готов, и в быстрый
    // навигатор, если нет. Пустой ответ Roslyn тоже добирается быстрым
    // навигатором: сервер бывает «готов», но ещё не проиндексировал проект.
    // Переключение незаметно — меняется только точность ответа.

    /// Есть ли чем отвечать на ⌘T. ⌘B и ⌘R работают всегда.
    var canSearchSymbols: Bool { lsp.isReady || symbolIndex != nil }

    /// Кто сейчас отвечает на навигацию — для статус-строки.
    var navigationEngine: NavigationEngine {
        if lsp.isReady && languageServerProven { return .languageServer }
        return symbolIndex != nil ? .index : .indexing
    }

    private func languageServerAnswered(_ found: Bool) {
        if found && !languageServerProven { languageServerProven = true }
    }

    enum NavigationEngine { case indexing, index, languageServer }

    /// Roslyn догрелся. Если открыт поиск символов — пересобираем выдачу уже
    /// по нему, не закрывая палитру и не стирая набранное.
    private func languageServerBecameReady() {
        if isPaletteOpen && paletteMode == .symbols { runSymbolSearch() }
    }

    private func runSymbolSearch() {
        symbolTask?.cancel()
        guard paletteMode == .symbols else { return }
        // Свой индекс отвечает сразу — и пока Roslyn греется, и пока он
        // думает над запросом; его ответ потом заменит этот.
        runLocalSymbolSearch()
        guard lsp.isReady else { return }
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        paletteBusy = symbolIndex == nil

        symbolTask = Task { [weak self] in
            // Небольшая задержка: Roslyn на каждый символьный запрос
            // поднимает весь индекс, слать его на каждую букву незачем.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }

            let wasProven = self.languageServerProven
            let symbols = await self.lsp.symbols(matching: q)
            self.languageServerAnswered(!symbols.isEmpty)
            guard !Task.isCancelled, self.paletteMode == .symbols else { return }
            // Пусто — сервер ещё не загрузил проект. Первый непустой ответ
            // может быть по части проектов — он лишь переключает следующие
            // запросы на сервер, а полную выдачу индекса не вытесняет.
            if self.symbolIndex != nil, symbols.isEmpty || !wasProven {
                self.paletteBusy = false
                return
            }

            self.items = symbols.prefix(200).enumerated().map { position, symbol in
                let path = self.relativePath(for: symbol.fileURL)
                var secondary = path
                if let container = symbol.containerName, !container.isEmpty {
                    secondary = "\(container) · \(path)"
                }
                return PaletteItem(
                    id: position,
                    icon: symbol.iconName,
                    primary: symbol.name,
                    secondary: secondary,
                    trailing: symbol.kindLabel,
                    target: NavTarget(url: symbol.fileURL ?? self.rootOrCurrent(),
                                      range: symbol.range))
            }
            self.paletteBusy = false
            if self.selection >= self.items.count {
                self.selection = max(0, self.items.count - 1)
            }
        }
    }

    /// ⌘T по своему индексу: ~10 мс на проекте в четверть миллиона объявлений.
    private func runLocalSymbolSearch() {
        let generation = searchGeneration.bump()
        let counter = searchGeneration
        let q = query
        paletteBusy = false
        guard let symbols = symbolIndex, !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            items = []
            return
        }
        work.async { [weak self] in
            let hits = symbols.search(q, limit: 200, shouldStop: { !counter.isCurrent(generation) })
            Task { @MainActor in
                guard let self, counter.isCurrent(generation), self.paletteMode == .symbols else { return }
                self.items = hits.enumerated().map { position, hit in
                    let symbol = symbols[hit.id]
                    let path = symbols.relPath(hit.id)
                    var secondary = path
                    if let container = symbol.container, !container.isEmpty {
                        secondary = "\(container) · \(path)"
                    }
                    return PaletteItem(
                        id: position,
                        icon: Self.icon(for: symbol.kind, keyword: symbol.keyword),
                        primary: symbol.name,
                        positions: hit.positions,
                        secondary: secondary,
                        trailing: symbol.keyword ?? symbol.kind.label,
                        target: symbols.target(hit.id))
                }
                if self.selection >= self.items.count {
                    self.selection = max(0, self.items.count - 1)
                }
            }
        }
    }

    static func icon(for kind: OutlineKind, keyword: String?) -> String {
        if kind == .type, let keyword { return TypeIndex.icon(forKeyword: keyword) }
        return kind.icon
    }

    // MARK: - Переход к объявлению и использованиям

    /// Переход к объявлению.
    ///
    /// Если языковой сервер готов — спрашиваем его, он точнее. Если нет
    /// (или он ничего не нашёл) — быстрый навигатор по индексу объявлений.
    func goToDefinition(at offset: Int) {
        guard let document else { return }

        // Сцены, префабы, .asmdef: ссылка — это GUID и fileID, языковой
        // сервер о них ничего не знает.
        if unity.isReferenceFile(document) {
            Task { [weak self] in
                guard let self else { return }
                switch await self.unity.definition(in: document, at: offset) {
                case .target(let target):   self.navigate(to: target)
                case .unavailable(let why): self.showNotice(why)
                case .notReference:         self.jumpToLocalDeclaration(at: offset, in: document)
                }
            }
            return
        }

        // Файл из MR сервер не видел: у него на руках рабочая копия, и его
        // позиции указали бы не туда. Для версии MR — только свой навигатор.
        guard lsp.isReady, document.revision == nil else {
            jumpToLocalDeclaration(at: offset, in: document)
            return
        }

        let position = document.model.position(at: offset)
        let url = document.url

        // Сервер ещё не показал, что загрузил проект: отвечаем сами сразу,
        // а его спрашиваем фоном — узнать, не прогрелся ли уже.
        if !languageServerProven {
            let answer = LocalNavigator(index: symbolIndex, document: navDocument(document)).definition(at: offset)
            if answer.isExact, let first = answer.declarations.first {
                navigate(to: first.target)
                Task { [weak self] in
                    let locations = await self?.lsp.definition(url: url, position: position) ?? []
                    self?.languageServerAnswered(!locations.isEmpty)
                }
                return
            }
        }

        Task { [weak self] in
            guard let self else { return }
            let locations = await self.lsp.definition(url: url, position: position)
            self.languageServerAnswered(!locations.isEmpty)
            if let first = locations.first, let target = first.fileURL {
                self.navigate(to: NavTarget(url: target, range: first.range))
            } else {
                self.jumpToLocalDeclaration(at: offset, in: document)
            }
        }
    }

    private func navDocument(_ document: LoadedDocument) -> NavDocument {
        var relPath: String?
        if let root, document.url.path.hasPrefix(root.path + "/") {
            relPath = String(document.url.path.dropFirst(root.path.count + 1))
        }
        // Снимок, а не живая модель: навигатор работает и в фоне (поиск
        // использований), а редактор тем временем правит модель на главном.
        return NavDocument(url: document.url, relPath: relPath,
                           model: document.model.snapshot(), outline: document.outline)
    }

    /// ⌘B без сервера. Тип цели выяснен — прыгаем; не выяснен, а объявлений
    /// с таким именем несколько — показываем их списком, ближние первыми.
    private func jumpToLocalDeclaration(at offset: Int, in document: LoadedDocument) {
        let answer = LocalNavigator(index: symbolIndex, document: navDocument(document)).definition(at: offset)
        guard let first = answer.declarations.first else { return }
        if answer.isExact {
            navigate(to: first.target)
        } else {
            showDeclarations(answer.declarations)
        }
    }

    private func showDeclarations(_ declarations: [FoundDeclaration]) {
        paletteMode = .declarations
        query = ""
        selection = 0
        allReferences = declarations.enumerated().map { position, declaration in
            var secondary = declaration.path
            if let container = declaration.container, !container.isEmpty {
                secondary = "\(container) · \(declaration.path)"
            }
            return PaletteItem(
                id: position,
                icon: Self.icon(for: declaration.kind, keyword: nil),
                primary: declaration.name,
                secondary: secondary,
                trailing: declaration.target.range.map { ":\($0.start.line + 1)" },
                target: declaration.target)
        }
        items = allReferences
        paletteBusy = false
        isPaletteOpen = true
    }

    func findReferences(at offset: Int) {
        guard let document else { return }
        let position = document.model.position(at: offset)
        let url = document.url

        paletteMode = .references
        query = ""
        selection = 0
        items = []
        allReferences = []
        paletteBusy = true
        isPaletteOpen = true

        // Неполный ответ полузагруженного сервера хуже честного поиска по тексту.
        guard lsp.isReady, languageServerProven else {
            findLocalReferences(at: offset, in: document)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let locations = await self.lsp.references(url: url, position: position)
            guard self.paletteMode == .references else { return }
            if locations.isEmpty {
                self.findLocalReferences(at: offset, in: document)
                return
            }
            self.showReferences(locations.map { ($0.fileURL ?? url, $0.range) })
        }
    }

    /// ⌘R без сервера: слово целиком по исходникам того же языка, без строк
    /// и комментариев. На проекте в 26 000 файлов — доли секунды, в фоне.
    private func findLocalReferences(at offset: Int, in document: LoadedDocument) {
        guard let root else { return }
        let files = index?.display ?? []
        let navigator = LocalNavigator(index: symbolIndex, document: navDocument(document))
        let generation = searchGeneration.bump()
        let counter = searchGeneration
        referenceQueue.async { [weak self] in
            let found = navigator.references(at: offset, root: root, files: files,
                                             shouldStop: { !counter.isCurrent(generation) })
            Task { @MainActor in
                guard let self, counter.isCurrent(generation), self.paletteMode == .references else { return }
                self.showReferences(found.map { ($0.target.url, $0.target.range ?? LSPRange(
                    start: LSPPosition(line: $0.line, character: 0), end: LSPPosition(line: $0.line, character: 0))) })
            }
        }
    }

    private func showReferences(_ locations: [(url: URL, range: LSPRange)]) {
        let built = locations.prefix(500).enumerated().map { position, location -> PaletteItem in
            PaletteItem(
                id: position,
                icon: "arrow.turn.down.right",
                primary: location.url.lastPathComponent,
                secondary: relativePath(for: location.url),
                trailing: ":\(location.range.start.line + 1)",
                target: NavTarget(url: location.url, range: location.range))
        }
        allReferences = built
        items = built
        paletteBusy = false
    }

    // MARK: - История переходов

    private var history: [NavTarget] = []
    private var historyIndex = -1

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    /// Переход с записью в историю. Без истории go-to-definition —
    /// ловушка: провалился и не вернёшься.
    func navigate(to target: NavTarget) {
        if let document {
            let current = NavTarget(
                url: document.url,
                range: LSPRange(start: document.model.position(at: caretOffset),
                                end: document.model.position(at: caretOffset)))
            if historyIndex < 0 {
                history = [current]
                historyIndex = 0
            } else if history[historyIndex].url != current.url
                        || history[historyIndex].range?.start != current.range?.start {
                history[historyIndex] = current
            }
        }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(target)
        historyIndex = history.count - 1
        jump(to: target)
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        jump(to: history[historyIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        jump(to: history[historyIndex])
    }

    private func jump(to target: NavTarget) {
        isPaletteOpen = false
        if document?.url == target.url {
            requestReveal(target.range)
        } else {
            open(file: target.url, reveal: target.range)
        }
    }

    // MARK: - Открытие файла

    func activateSelection() {
        guard selection >= 0, selection < items.count else { return }
        navigate(to: items[selection].target)
    }

    /// Чтение и разбор уходят в фон: на файле в сотни тысяч строк первый
    /// проход лексера занимает сотни миллисекунд, и делать это на главном
    /// потоке — значит подвесить интерфейс.
    func open(file url: URL, reveal: LSPRange? = nil) {
        isPaletteOpen = false
        loadError = nil
        requestedFile = url
        let generation = loadGeneration.bump()
        let counter = loadGeneration
        let unityContext = unity.context

        // Несохранённый буфер важнее файла на диске: там правки и ⌘Z.
        if let cached = unsaved[url] {
            let caret = cached.model.position(at: cached.lastCaret)
            activate(cached, reveal: reveal ?? LSPRange(start: caret, end: caret))
            return
        }

        work.async { [weak self] in
            guard let self else { return }
            let result = Result { try LoadedDocument.load(url: url, unity: unityContext) }
            Task { @MainActor in
                guard counter.isCurrent(generation) else { return }
                self.present(result, reveal: reveal)
            }
        }
    }

    /// Файл в версии MR: текст берётся из коммита, а не с диска.
    func open(reviewFile file: ReviewFile, reveal: LSPRange? = nil) {
        isPaletteOpen = false
        loadError = nil
        let generation = loadGeneration.bump()
        let counter = loadGeneration

        Task { [weak self] in
            guard let self else { return }
            let result: Result<LoadedDocument, Error>
            do {
                result = .success(try await self.review.loadDocument(for: file))
            } catch {
                result = .failure(error)
            }
            guard counter.isCurrent(generation) else { return }
            self.present(result, reveal: reveal)
        }
    }

    private func present(_ result: Result<LoadedDocument, Error>, reveal: LSPRange?) {
        switch result {
        case .success(let doc):
            activate(TextBuffer(document: doc, fontSize: fontSize), reveal: reveal)
        case .failure(let error):
            setBuffer(nil)
            loadError = error.localizedDescription
            git.documentOpened(nil)
        }
    }

    // MARK: - Буферы и правки

    private func activate(_ buffer: TextBuffer, reveal: LSPRange?) {
        setBuffer(buffer)
        loadError = nil
        caret.reset()
        occurrenceWord = nil
        requestReveal(reveal)
        if buffer.isReadOnly {
            // Версия из MR: полоски и треды даёт ревью, а не HEAD. Серверу
            // её не показываем — у него на руках рабочая копия того же файла.
            git.documentOpened(nil)
        } else {
            // Сервер поднимается здесь — лениво, при первом файле
            // подходящего языка, а не при запуске приложения.
            lsp.documentOpened(buffer.document)
            git.documentOpened(buffer.document)
        }
    }

    /// Смена открытого буфера. Уходящий остаётся в памяти, только если
    /// в нём есть несохранённые правки.
    private func setBuffer(_ new: TextBuffer?) {
        if let old = buffer, old !== new {
            old.lastCaret = caretOffset
            if !old.isDirty, !old.isReadOnly {
                unsaved[old.url] = nil
                lsp.documentClosed(old.url)
            }
        }
        buffer = new
        updateConflicts()
        guard let new else { return }
        new.onEdit = { [weak self] buffer, range, text in self?.bufferEdited(buffer, range: range, text: text) }
        new.onDirtyChange = { [weak self] buffer in self?.dirtyChanged(buffer) }
    }

    private func dropAllBuffers() {
        setBuffer(nil)
        unsaved.removeAll()
        updateUnsavedCount()
    }

    private var outlineTask: Task<Void, Never>?
    private var gitTask: Task<Void, Never>?

    /// Правка в буфере. Модель уже обновлена — рассылаем тем, кому нужно.
    private func bufferEdited(_ buffer: TextBuffer, range: LSPRange, text: String) {
        lsp.documentEdited(buffer.document, range: range, text: text)
        guard buffer === self.buffer else { return }
        // Сразу, без задержки: проход по началам строк — доли миллисекунды,
        // а кнопки «принять» должны стоять у своих маркеров после каждой правки.
        updateConflicts()

        // Вхождения посчитаны по старому тексту; пересчитаются на следующем
        // движении курсора, а оно после набора будет всегда.
        caret.setOccurrences([])
        occurrenceWord = nil

        // Структура и полоски git — с задержкой: пока печатаешь, незачем.
        // Правку инспектора Unity разбираем сразу: он ждёт свежих позиций.
        let delay: UInt64 = pendingInspectorEdit ? 0 : 300_000_000
        pendingInspectorEdit = false
        outlineTask?.cancel()
        outlineTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled else { return }
            self.rebuildOutline(buffer)
        }
        gitTask?.cancel()
        gitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled, buffer === self.buffer else { return }
            self.git.documentEdited(buffer.document)
        }
    }

    /// Структура строится по снимку модели в фоне и принимается, только
    /// если за это время текст не менялся — иначе её диапазоны уже врут.
    ///
    /// Сцены и префабы разбираются здесь же: после правки — из инспектора
    /// или руками — у объектов новые позиции, и старому разбору верить нельзя.
    private func rebuildOutline(_ buffer: TextBuffer) {
        let snapshot = buffer.model.snapshot()
        let context = unity.context
        work.async { [weak self] in
            let outline = OutlineBuilder.build(model: snapshot)
            let semantics = UnitySemantics.analyze(model: snapshot, lexicalOutline: outline, context: context)
            Task { @MainActor in
                guard let self, buffer === self.buffer,
                      buffer.model.version == snapshot.version else { return }
                self.objectWillChange.send()
                buffer.setSemantics(outline: semantics?.outline ?? outline,
                                    unityFile: semantics?.serialized, version: snapshot.version)
                self.updateOutlineItem()
            }
        }
    }

    // MARK: - Unity

    /// Индекс GUID дособрался: у скриптов в открытой сцене появились имена.
    /// Разбираем файл заново, не трогая ни текст, ни прокрутку.
    private func unityAssetsReady() {
        guard let buffer else { return }
        rebuildOutline(buffer)
    }

    /// ⇧⌘R: какие сцены, префабы и ассеты ссылаются на открытый файл.
    /// Работает и для файлов, которые не открываются как текст: текстур, моделей.
    func findAssetUsages() {
        guard unity.isActive else { return }
        guard let url = document?.url ?? requestedFile,
              let asset = unity.assetPath(for: url) else {
            showNotice("Сначала откройте ассет")
            return
        }
        let paths = index?.display ?? []

        paletteMode = .assetUsages
        query = ""
        selection = 0
        items = []
        allReferences = []
        paletteBusy = true
        isPaletteOpen = true
        usagesTitle = (asset as NSString).lastPathComponent

        Task { [weak self] in
            guard let self else { return }
            let result = await self.unity.usages(ofAsset: asset, among: paths)
            guard self.paletteMode == .assetUsages else { return }
            self.paletteBusy = false
            switch result {
            case .failure(let error):
                self.isPaletteOpen = false
                self.showNotice(error.message)
            case .success(let hits):
                self.allReferences = hits.prefix(1000).enumerated().map { position, hit in
                    let place = LSPPosition(line: hit.line, character: hit.column)
                    return PaletteItem(
                        id: position,
                        icon: Self.icon(forPath: hit.relPath),
                        primary: hit.context ?? (hit.relPath as NSString).lastPathComponent,
                        secondary: hit.relPath,
                        trailing: ":\(hit.line + 1)",
                        target: NavTarget(url: self.unity.url(forAsset: hit.relPath) ?? url, range: LSPRange(
                            start: place,
                            end: LSPPosition(line: hit.line, character: hit.column + 32))))
                }
                self.items = self.allReferences
            }
        }
    }

    /// ⌃⌘M: из ассета в его `.meta` и обратно. В дереве и ⌘P `.meta`
    /// спрятаны, а заглянуть в настройки импорта иногда нужно.
    func toggleMetaFile() {
        guard unity.isActive, let url = document?.url ?? requestedFile else { return }
        let target = url.pathExtension == "meta" ? url.deletingPathExtension()
                                                 : url.appendingPathExtension("meta")
        guard FileManager.default.fileExists(atPath: target.path) else {
            showNotice("Нет файла \(target.lastPathComponent)")
            return
        }
        navigate(to: NavTarget(url: target, range: nil))
    }

    // MARK: - Инспектор Unity: правки

    /// Правки инспектора, которые редактор применит к тексту.
    @Published private(set) var editRequest: TextEditRequest?
    private var editCounter = 0
    /// Следующая правка буфера пришла из инспектора — разобрать без задержки.
    private var pendingInspectorEdit = false

    /// Правка из инспектора Unity — такая же правка текста, как набор:
    /// файл становится несохранённым (⌘S — записать, как сцену в Unity),
    /// ⌘Z в редакторе её отменяет. Меняются только значения, поэтому в
    /// `git diff` потом ровно изменённые строки. Разбор, по которому она
    /// посчитана, должен совпадать с текстом — иначе позиции уже сдвинулись.
    func applyUnityEdits(_ edits: [UnityEdit], actionName: String) {
        guard !edits.isEmpty, let buffer, buffer.document.isSemanticsFresh else { return }
        guard buffer.document.revision == nil else {
            showNotice("Это версия файла из мерж-реквеста — она только для чтения")
            return
        }
        guard UnityEdits.validate(edits, in: buffer.storage.string as NSString) else {
            showNotice("Текст уже другой — правка не применена")
            return
        }
        editCounter += 1
        pendingInspectorEdit = true
        editRequest = TextEditRequest(seq: editCounter, buffer: buffer, edits: edits, actionName: actionName)
    }

    /// Перейти к объекту этого же файла — из хлебных крошек и ссылок инспектора.
    func revealUnityObject(fileID: Int64) {
        guard let document, let file = document.unityFile, let object = file.object(fileID) else { return }
        let range = object.nameRange ?? object.typeNameRange
        navigate(to: NavTarget(url: document.url, range: LSPRange(
            start: document.model.position(at: range.location),
            end: document.model.position(at: NSMaxRange(range)))))
    }

    /// Открыть ассет по GUID — ссылка в инспекторе.
    func openUnityAsset(guid: UnityGUID, fileID: Int64? = nil) {
        Task { [weak self] in
            guard let self else { return }
            switch await self.unity.target(forAsset: guid, fileID: fileID) {
            case .target(let target):   self.navigate(to: target)
            case .unavailable(let why): self.showNotice(why)
            case .notReference:         break
            }
        }
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func dirtyChanged(_ buffer: TextBuffer) {
        unsaved[buffer.url] = buffer.isDirty ? buffer : nil
        updateUnsavedCount()
    }

    private func updateUnsavedCount() {
        let count = unsaved.values.filter(\.isDirty).count
        if unsavedCount != count { unsavedCount = count }
        // Точка в красной кнопке окна — как у любого документа в macOS.
        for window in NSApp.windows where !(window is NSPanel) {
            window.isDocumentEdited = count > 0
        }
    }

    var isCurrentDirty: Bool { buffer?.isDirty == true }

    func isUnsaved(_ url: URL) -> Bool { unsaved[url]?.isDirty == true }

    // MARK: - Сохранение

    func save() {
        guard let buffer else { return }
        save(buffer)
    }

    func saveAll() {
        for buffer in unsaved.values where buffer.isDirty { save(buffer) }
    }

    @discardableResult
    private func save(_ buffer: TextBuffer) -> Bool {
        do {
            try buffer.save()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить «\(buffer.url.lastPathComponent)»"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }
        lsp.documentSaved(buffer.url)
        git.refresh()
        if buffer === self.buffer { git.documentEdited(buffer.document) }
        return true
    }

    /// Перед сменой проекта и выходом. true — можно продолжать: всё
    /// сохранено или правки решили выбросить.
    func confirmUnsavedChanges() -> Bool {
        let dirty = unsaved.values.filter(\.isDirty).sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        guard !dirty.isEmpty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if dirty.count == 1 {
            alert.messageText = "Сохранить изменения в «\(dirty[0].url.lastPathComponent)»?"
        } else {
            alert.messageText = "Сохранить изменения в \(Theme.count(dirty.count, "файле", "файлах", "файлах"))?"
            alert.informativeText = dirty.prefix(8).map(\.url.lastPathComponent).joined(separator: ", ")
                + (dirty.count > 8 ? "…" : "")
        }
        alert.informativeText += (alert.informativeText.isEmpty ? "" : "\n\n") + "Если не сохранить, правки пропадут."
        alert.addButton(withTitle: dirty.count == 1 ? "Сохранить" : "Сохранить все")
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Не сохранять")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return dirty.allSatisfy { save($0) }
        case .alertThirdButtonReturn:
            for buffer in dirty { unsaved[buffer.url] = nil }
            updateUnsavedCount()
            return true
        default:
            return false
        }
    }

    // MARK: - Автодополнение

    /// Варианты в позиции курсора: от языкового сервера, а если его нет
    /// (или он не ответил) — слова файла и ключевые слова языка.
    func completions(at offset: Int, trigger: String?, retrigger: Bool) async -> CompletionList? {
        guard let buffer else { return nil }
        let url = buffer.url
        if lsp.providesCompletion(for: url) {
            let position = buffer.model.position(at: offset)
            if let list = await lsp.completion(url: url, position: position,
                                               trigger: trigger, retrigger: retrigger) {
                return list
            }
        }
        // После точки нужны члены типа — словами файла тут не помочь.
        guard trigger == nil, buffer === self.buffer else { return nil }
        // Слова — по снимку и в фоне: на большом файле это десятки
        // миллисекунд, и набор их ждать не должен.
        let snapshot = buffer.model.snapshot()
        let items = await Task.detached(priority: .userInitiated) {
            WordCompletion.items(in: snapshot, excluding: offset)
        }.value
        return CompletionList(items: items)
    }

    // MARK: - Навигация в палитре

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
    }

    // MARK: - Мелочи

    private func rootOrCurrent() -> URL {
        root ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    func relativePath(for url: URL?) -> String {
        guard let url else { return "" }
        guard let root, url.path.hasPrefix(root.path + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    static func icon(forPath path: String) -> String {
        Theme.fileIcon(forName: (path as NSString).lastPathComponent).symbol
    }
}

// MARK: - Кэш индекса на диске

/// Кэш — просто список относительных путей, по одному на строку. Читается
/// за десятки миллисекунд даже на 100k файлов, поэтому повторный запуск
/// не ждёт обхода файловой системы.
enum IndexCache {

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Pilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(root: URL, extension ext: String = "idx") -> URL? {
        guard let dir = directory else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for b in root.path.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return dir.appendingPathComponent(String(format: "%016llx.", hash) + ext)
    }

    static func save(_ index: FileIndex, root: URL) {
        guard let url = fileURL(root: root) else { return }
        let payload = index.display.joined(separator: "\n")
        try? payload.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func load(root: URL, exclude: ((String, Bool) -> Bool)? = nil) -> FileIndex? {
        guard let url = fileURL(root: root),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }

        let index = FileIndex(root: root)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let rel = String(line)
            if let exclude, exclude(rel, false) { continue }
            index.appendCached(rel: rel)
        }
        return index.count > 0 ? index : nil
    }

    // Типы лежат рядом, в соседнем файле с тем же хэшем.

    static func saveTypes(_ index: TypeIndex, root: URL) {
        guard let url = fileURL(root: root, extension: "types") else { return }
        try? index.serialized().data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func loadTypes(root: URL) -> TypeIndex? {
        guard let url = fileURL(root: root, extension: "types"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return TypeIndex.deserialize(text, root: root)
    }

    static func saveSymbols(_ index: SymbolIndex, root: URL) {
        guard let url = fileURL(root: root, extension: "symbols") else { return }
        try? index.serialized().data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func loadSymbols(root: URL) -> SymbolIndex? {
        guard let url = fileURL(root: root, extension: "symbols"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return SymbolIndex.deserialize(text, root: root)
    }
}
