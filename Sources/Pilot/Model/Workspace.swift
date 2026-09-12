import SwiftUI
import AppKit

@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var isIndexing = false
    @Published private(set) var fileCount = 0
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
    @Published private(set) var navigatorRows: [FileTreeRow] = []
    /// Растёт при каждой пересборке строк: по нему список понимает, что
    /// перерисовываться пора, не сравнивая тысячи строк.
    @Published private(set) var navigatorVersion = 0
    @Published private(set) var navigatorSelection: String?
    /// Фильтр вкладки «Структура» — отдельный, чтобы не сбрасывать дерево.
    @Published var outlineFilter = ""
    @Published var navigatorFilter = "" {
        didSet { if navigatorFilter != oldValue { navigatorFilterChanged() } }
    }

    private(set) var fileTree: FileTreeNode?
    private var filteredTree: FileTreeNode?
    private var expandedFolders: Set<String> = [""]
    private let treeQueue = DispatchQueue(label: "pilot.tree", qos: .userInitiated)
    private let treeGeneration = AtomicCounter()
    private let filterGeneration = AtomicCounter()
    /// Больше строк фильтр не показывает: дальше человек всё равно уточнит запрос.
    nonisolated static let navigatorFilterLimit = 2000

    private var occurrenceTask: Task<Void, Never>?
    private var occurrenceWord: String?

    let lsp = LSPService()

    private var index: FileIndex?
    private let work = DispatchQueue(label: "pilot.index", qos: .userInitiated)
    private let scanGeneration = AtomicCounter()
    private let searchGeneration = AtomicCounter()
    private let loadGeneration = AtomicCounter()
    private var symbolTask: Task<Void, Never>?
    /// Полный список использований; поле ввода фильтрует его на месте.
    private var allReferences: [PaletteItem] = []

    private let recentKey = "pilot.recentRoots"

    var recentRoots: [URL] {
        (UserDefaults.standard.array(forKey: recentKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Открытие воркспейса

    func openLastOrPrompt() {
        if let last = recentRoots.first,
           FileManager.default.fileExists(atPath: last.path) {
            open(root: last)
        } else {
            promptForFolder()
        }
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
        history.removeAll()
        historyIndex = -1
        currentOutlineItem = nil
        branch = GitInfo.branch(at: url)
        fileTree = nil
        filteredTree = nil
        expandedFolders = [""]
        navigatorSelection = nil
        navigatorFilter = ""
        _ = treeGeneration.bump()
        rebuildNavigatorRows()
        rememberRecent(url)
        lsp.workspaceChanged(to: url)

        let generation = scanGeneration.bump()
        isIndexing = true

        work.async { [weak self] in
            guard let self else { return }
            // 1. Кэш делает повторное открытие проекта мгновенным.
            if let cached = IndexCache.load(root: url) {
                Task { @MainActor in
                    guard self.scanGeneration.isCurrent(generation) else { return }
                    self.adopt(cached, indexing: true)
                }
            }
            // 2. Всё равно пересканируем — кэш мог устареть.
            let counter = self.scanGeneration
            let fresh = FileIndex.build(root: url, shouldStop: { !counter.isCurrent(generation) })
            IndexCache.save(fresh, root: url)

            Task { @MainActor in
                guard self.scanGeneration.isCurrent(generation) else { return }
                self.adopt(fresh, indexing: false)
            }
        }
    }

    private func adopt(_ newIndex: FileIndex, indexing: Bool) {
        index = newIndex
        fileCount = newIndex.count
        isIndexing = indexing
        runFileSearch()
        buildTree(from: newIndex)
    }

    // MARK: - Навигатор проекта

    /// Дерево строится в своей очереди, чтобы не задерживать поиск ⌘P,
    /// который живёт в `work`.
    private func buildTree(from index: FileIndex) {
        let generation = treeGeneration.bump()
        let counter = treeGeneration
        let rootName = index.root.lastPathComponent
        treeQueue.async { [weak self] in
            let tree = FileTreeNode.build(rootName: rootName, paths: index.display)
            Task { @MainActor in
                guard let self, counter.isCurrent(generation) else { return }
                self.fileTree = tree
                self.rebuildNavigatorRows()
                if !self.navigatorFilter.isEmpty { self.navigatorFilterChanged() }
            }
        }
    }

    private func rebuildNavigatorRows() {
        if !navigatorFilter.isEmpty {
            navigatorRows = filteredTree?.flatten(expanded: [], expandAll: true) ?? []
        } else {
            navigatorRows = fileTree?.flatten(expanded: expandedFolders) ?? []
        }
        navigatorVersion += 1
    }

    func toggleFolder(_ path: String) {
        guard navigatorFilter.isEmpty else { return }   // в фильтре раскрыто всё
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else {
            expandedFolders.insert(path)
        }
        rebuildNavigatorRows()
    }

    func setFolder(_ path: String, expanded: Bool) {
        guard navigatorFilter.isEmpty, expandedFolders.contains(path) != expanded else { return }
        toggleFolder(path)
    }

    /// Клик по строке навигатора: файл открывается, папка раскрывается.
    func selectInNavigator(_ path: String?) {
        guard let path, let root else { return }
        navigatorSelection = path
        guard let row = navigatorRows.first(where: { $0.id == path }) else { return }
        if row.node.isDirectory { return }
        let url = root.appendingPathComponent(path)
        guard document?.url != url else { return }
        navigate(to: NavTarget(url: url, range: nil))
    }

    /// Открытый файл подсвечивается в дереве, а его папки раскрываются.
    private func revealInNavigator(_ url: URL) {
        guard let root, url.path.hasPrefix(root.path + "/") else { return }
        let path = relativePath(for: url)
        navigatorSelection = path
        guard navigatorFilter.isEmpty else { return }
        let missing = FileTreeNode.ancestors(of: path).filter { !expandedFolders.contains($0) }
        if !missing.isEmpty {
            expandedFolders.formUnion(missing)
            rebuildNavigatorRows()
        }
    }

    /// Показать папку в дереве — из меню jump bar.
    func revealFolder(_ path: String) {
        navigatorTab = .project
        navigatorFilter = ""
        expandedFolders.formUnion(FileTreeNode.ancestors(of: path))
        expandedFolders.insert(path)
        navigatorSelection = path
        rebuildNavigatorRows()
    }

    private func navigatorFilterChanged() {
        let needle = navigatorFilter.trimmingCharacters(in: .whitespaces)
        let generation = filterGeneration.bump()
        guard !needle.isEmpty, let index else {
            filteredTree = nil
            rebuildNavigatorRows()
            return
        }
        let counter = filterGeneration
        let rootName = index.root.lastPathComponent
        treeQueue.async { [weak self] in
            let ids = index.filter(name: needle, limit: Self.navigatorFilterLimit,
                                   shouldStop: { !counter.isCurrent(generation) })
            let tree = FileTreeNode.build(rootName: rootName, paths: ids.map { index.relPath($0) })
            Task { @MainActor in
                guard let self, counter.isCurrent(generation) else { return }
                self.filteredTree = tree
                self.rebuildNavigatorRows()
            }
        }
    }

    private func rememberRecent(_ url: URL) {
        var list = recentRoots.map(\.path).filter { $0 != url.path }
        list.insert(url.path, at: 0)
        if list.count > 10 { list.removeSubrange(10...) }
        UserDefaults.standard.set(list, forKey: recentKey)
    }

    // MARK: - Палитра

    func openPalette(mode: PaletteMode) {
        paletteMode = mode
        query = ""
        selection = 0
        isPaletteOpen = true
        switch mode {
        case .files:      runFileSearch()
        case .symbols:    runSymbolSearch()
        case .outline:    buildOutlineItems()
        case .references: break   // наполняется через findReferences()
        }
    }

    private func queryChanged() {
        selection = 0
        switch paletteMode {
        case .files:      runFileSearch()
        case .symbols:    runSymbolSearch()
        case .references: filterReferences()
        case .outline:    buildOutlineItems()
        }
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
                        target: NavTarget(url: index.absoluteURL(hit.id), range: nil))
                }
                if self.selection >= self.items.count {
                    self.selection = max(0, self.items.count - 1)
                }
            }
        }
    }

    // MARK: - Поиск символов через LSP

    private func runSymbolSearch() {
        symbolTask?.cancel()
        guard paletteMode == .symbols else { return }
        guard lsp.isReady else {
            items = []
            return
        }
        let q = query
        paletteBusy = true

        symbolTask = Task { [weak self] in
            // Небольшая задержка: Roslyn на каждый символьный запрос
            // поднимает весь индекс, слать его на каждую букву незачем.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }

            let symbols = await self.lsp.symbols(matching: q)
            guard !Task.isCancelled, self.paletteMode == .symbols else { return }

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

    // MARK: - Переход к определению и использованиям

    /// Переход к объявлению.
    ///
    /// Если языковой сервер готов — спрашиваем его, он точнее. Если нет
    /// (или он ничего не нашёл) — ищем лексически в текущем файле. Это
    /// приблизительно, зато мгновенно и работает, пока Roslyn ещё грузится.
    func goToDefinition(at offset: Int) {
        guard let document else { return }

        guard lsp.isReady else {
            jumpToLexicalDeclaration(at: offset, in: document)
            return
        }

        let position = document.model.position(at: offset)
        let url = document.url
        Task { [weak self] in
            guard let self else { return }
            let locations = await self.lsp.definition(url: url, position: position)
            if let first = locations.first, let target = first.fileURL {
                self.navigate(to: NavTarget(url: target, range: first.range))
            } else {
                self.jumpToLexicalDeclaration(at: offset, in: document)
            }
        }
    }

    /// Лексический поиск объявления в пределах файла:
    /// сначала структура файла, затем эвристика для локальных переменных.
    private func jumpToLexicalDeclaration(at offset: Int, in document: LoadedDocument) {
        guard let identifier = Occurrences.identifier(in: document.model, at: offset) else { return }

        // 1. Объявление верхнего уровня — метод, свойство, поле, тип.
        if let item = document.outline.first(where: { $0.name == identifier.text }),
           item.range.location != identifier.range.location {
            navigate(to: NavTarget(url: document.url, range: rangeFor(item, in: document)))
            return
        }

        // 2. Локальная переменная или параметр: ближайшее объявление выше курсора.
        let all = Occurrences.find(identifier.text, in: document.model)
        let declarations = all.filter { Occurrences.looksLikeDeclaration($0, in: document.model) }
        let candidate = declarations.last { $0.location <= offset } ?? declarations.first
        guard let candidate, candidate.location != identifier.range.location else { return }

        let start = document.model.position(at: candidate.location)
        let end = document.model.position(at: candidate.location + candidate.length)
        navigate(to: NavTarget(url: document.url, range: LSPRange(start: start, end: end)))
    }

    func findReferences(at offset: Int) {
        guard let document, lsp.isReady else { return }
        let position = document.model.position(at: offset)
        let url = document.url

        paletteMode = .references
        query = ""
        selection = 0
        items = []
        allReferences = []
        paletteBusy = true
        isPaletteOpen = true

        Task { [weak self] in
            guard let self else { return }
            let locations = await self.lsp.references(url: url, position: position)
            guard self.paletteMode == .references else { return }

            let built = locations.prefix(500).enumerated().map { position, location -> PaletteItem in
                let fileURL = location.fileURL ?? url
                return PaletteItem(
                    id: position,
                    icon: "arrow.turn.down.right",
                    primary: fileURL.lastPathComponent,
                    secondary: self.relativePath(for: fileURL),
                    trailing: ":\(location.range.start.line + 1)",
                    target: NavTarget(url: fileURL, range: location.range))
            }
            self.allReferences = built
            self.items = built
            self.paletteBusy = false
        }
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
                    self.revealInNavigator(url)
                    self.requestReveal(reveal)
                    // Сервер поднимается здесь — лениво, при первом файле
                    // подходящего языка, а не при запуске приложения.
                    self.lsp.documentOpened(doc)
                case .failure(let error):
                    self.document = nil
                    self.loadError = error.localizedDescription
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

    private static func fileURL(root: URL) -> URL? {
        guard let dir = directory else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for b in root.path.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return dir.appendingPathComponent(String(format: "%016llx.idx", hash))
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
}
