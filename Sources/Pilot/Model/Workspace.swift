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
    @Published private(set) var document: LoadedDocument?
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

    /// Позиция курсора в открытом документе — отсюда берутся запросы к LSP.
    @Published private(set) var caretOffset: Int = 0
    /// Вхождения идентификатора под курсором — подсвечиваются в тексте.
    @Published private(set) var occurrences: [NSRange] = []
    /// Где мы находимся: «Класс › Метод».
    @Published private(set) var breadcrumb: String = ""
    /// Объявление, внутри которого курсор, — для jump bar и навигатора структуры.
    @Published private(set) var currentOutlineItem: OutlineItem?
    /// Ветка git — подзаголовок окна, как в Xcode.
    @Published private(set) var branch: String?

    // MARK: Навигатор

    enum NavigatorTab: Hashable, CaseIterable {
        case project, outline, recent

        var icon: String {
            switch self {
            case .project: return "folder"
            case .outline: return "list.bullet.indent"
            case .recent:  return "clock"
            }
        }

        var selectedIcon: String {
            switch self {
            case .project: return "folder.fill"
            case .outline: return "list.bullet.indent"
            case .recent:  return "clock.fill"
            }
        }

        var title: String {
            switch self {
            case .project: return "Проект"
            case .outline: return "Структура файла"
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
    let git = GitService()
    private var gitObservation: AnyCancellable?
    private var lspObservation: AnyCancellable?
    private var lspReadyObservation: AnyCancellable?

    init() {
        // Статус-строка и полоски у номеров строк читают git через workspace:
        // его изменения должны перерисовывать то же, что и наши.
        gitObservation = git.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
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
        root = url
        document = nil
        loadError = nil
        query = ""
        results = []
        items = []
        fileTree = nil
        history.removeAll()
        historyIndex = -1
        currentOutlineItem = nil
        branch = GitInfo.branch(at: url)
        navigatorFilter = ""
        filteredTree = nil
        rememberRecent(url)
        languageServerProven = false
        lsp.workspaceChanged(to: url)
        git.workspaceChanged(to: url)

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
            let cached = IndexCache.load(root: url)
            if let cached {
                let tree = FileTree.build(paths: cached.display)
                Task { @MainActor in
                    guard self.scanGeneration.isCurrent(generation) else { return }
                    self.adopt(cached, tree: tree, indexing: true)
                }
            }
            // 2. Всё равно пересканируем — кэш мог устареть.
            let counter = self.scanGeneration
            let fresh = FileIndex.build(root: url, shouldStop: { !counter.isCurrent(generation) })
            guard counter.isCurrent(generation) else { return }
            IndexCache.save(fresh, root: url)

            // Обычно кэш совпадает с диском один в один — тогда дерево
            // не пересобираем, и панель не перерисовывается впустую.
            let tree = cached?.display == fresh.display ? nil : FileTree.build(paths: fresh.display)
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
        // Новое поколение отменяет обход ФС и загрузку файла, что ещё идут.
        _ = scanGeneration.bump()
        _ = loadGeneration.bump()
        languageServerProven = false
        lsp.workspaceChanged(to: nil)
        git.workspaceChanged(to: nil)
        root = nil
        index = nil
        symbolIndex = nil
        fileTree = nil
        document = nil
        loadError = nil
        isIndexing = false
        fileCount = 0
        isPaletteOpen = false
        query = ""
        results = []
        items = []
        occurrences = []
        breadcrumb = ""
        currentOutlineItem = nil
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
        case .references, .declarations: break   // наполняются переходом или findReferences()
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
        case .references, .declarations: filterReferences()
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
        for path in changed.keys.sorted() { index.appendCached(rel: path) }

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
        case .classes, .outline, .symbols, .references, .declarations: break
        }
    }

    /// Следующий/предыдущий изменённый блок; по кругу, как и вхождения.
    func jumpToChange(_ direction: Int) {
        guard let document, !git.lineChanges.isEmpty else { return }
        let changes = git.lineChanges
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
        caretOffset = offset
        updateBreadcrumb()
        scheduleOccurrences()
    }

    private func updateBreadcrumb() {
        guard let document, !document.outline.isEmpty else {
            breadcrumb = ""
            currentOutlineItem = nil
            return
        }
        // Объемлющее объявление — последнее, начавшееся до курсора.
        var current: OutlineItem?
        for item in document.outline {
            if item.range.location <= caretOffset { current = item } else { break }
        }
        currentOutlineItem = current
        guard let current else { breadcrumb = ""; return }
        if let container = current.container, !container.isEmpty {
            breadcrumb = "\(container) › \(current.name)"
        } else {
            breadcrumb = current.name
        }
    }

    /// Подсветка вхождений. С задержкой: при протягивании выделения
    /// курсор двигается десятки раз в секунду.
    private func scheduleOccurrences() {
        occurrenceTask?.cancel()
        guard let document else { occurrences = []; occurrenceWord = nil; return }

        guard let identifier = Occurrences.identifier(in: document.model, at: caretOffset) else {
            occurrences = []
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
            self.occurrences = found
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

        guard lsp.isReady else {
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
        return NavDocument(url: document.url, relPath: relPath,
                           model: document.model, outline: document.outline)
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
        let generation = loadGeneration.bump()
        let counter = loadGeneration

        work.async { [weak self] in
            guard let self else { return }
            let result = Result { try LoadedDocument.load(url: url) }
            Task { @MainActor in
                guard counter.isCurrent(generation) else { return }
                switch result {
                case .success(let doc):
                    self.document = doc
                    self.loadError = nil
                    self.caretOffset = 0
                    self.occurrences = []
                    self.occurrenceWord = nil
                    self.breadcrumb = ""
                    self.currentOutlineItem = nil
                    self.requestReveal(reveal)
                    // Сервер поднимается здесь — лениво, при первом файле
                    // подходящего языка, а не при запуске приложения.
                    self.lsp.documentOpened(doc)
                    self.git.documentOpened(doc)
                case .failure(let error):
                    self.document = nil
                    self.loadError = error.localizedDescription
                    self.git.documentOpened(nil)
                }
            }
        }
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

    static func load(root: URL) -> FileIndex? {
        guard let url = fileURL(root: root),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }

        let index = FileIndex(root: root)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            index.appendCached(rel: String(line))
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
