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
    /// ⌘R), пока Rustlyn компилирует проект; строится тем же проходом, что и
    /// индекс типов.
    @Published private(set) var symbolIndex: SymbolIndex?
    /// С какого момента собран `symbolIndex`: при следующей сборке заново
    /// разбирается только изменённое после него.
    private var symbolsBuiltFrom: Date?
    /// То же для `assemblyIndex`.
    private var assembliesBuiltFrom: Date?
    /// Типы из сборок, к которым нет исходников: плагины проекта и сам
    /// движок Unity. Отвечает на ⌘B и ⇧⇧ там, где ни исходников, ни
    /// компиляции проекта нет.
    @Published private(set) var assemblyIndex: AssemblyIndex?
    /// Компиляция проекта Rustlyn'ом: пока её нет, на ⌘B и ⌘R по C# отвечает
    /// индекс объявлений, когда есть — компилятор.
    @Published private(set) var compiler: CompilerState = .idle
    /// Сессия Rustlyn этого проекта. У каждого окна своя: два открытых
    /// проекта — две компиляции, и вопрос про файл одного другой не видит.
    private(set) var rustlyn: Rustlyn?
    /// Дерево папок для боковой панели. Строится из того же индекса, что и ⌘P.
    @Published private(set) var fileTree: FileTree?
    @Published var query = "" { didSet { queryChanged() } }
    @Published private(set) var items: [PaletteItem] = []
    /// Открытые вкладки, слева направо. У каждой свой буфер: текст, история
    /// отмены, выделение и прокрутка — ушёл на другую и вернулся, всё на месте.
    @Published private(set) var tabs: [TextBuffer] = []
    /// Временная вкладка, как в Rider: файл, открытый кликом в дереве.
    /// Следующий такой клик занимает её место; правка, двойной клик
    /// по файлу или по вкладке оставляют её насовсем. Всегда одна и
    /// всегда без несохранённых правок.
    @Published private(set) var previewTab: TextBuffer?
    /// Файл, который сейчас читается во временную вкладку.
    private var previewLoad: URL?
    /// Активная вкладка — файл в редакторе. nil — пустой редактор или
    /// файл, который не открылся как текст.
    @Published private(set) var buffer: TextBuffer?
    /// Открытый документ. Модель в нём та же, что правит редактор.
    var document: LoadedDocument? { buffer?.document }
    @Published private(set) var unsavedCount = 0
    private var activationCounter = 0
    @Published private(set) var loadError: String?
    @Published var selection: Int = 0
    /// Закрылась палитра — фокус возвращается в текст: иначе он остаётся
    /// у окна, и до клика мышью ни набор, ни ⌘F никуда не попадают.
    @Published var isPaletteOpen = false {
        didSet { if oldValue && !isPaletteOpen { focusEditor() } }
    }
    @Published private(set) var paletteMode: PaletteMode = .search
    /// Фильтр единого поиска.
    @Published private(set) var searchScope: SearchScope = .everything
    @Published private(set) var paletteBusy = false
    /// Размер шрифта редактора — общий на все проекты и переживает перезапуск.
    @Published private(set) var fontSize: CGFloat = Workspace.loadFontSize()

    static let defaultFontSize: CGFloat = 12.5
    private static let fontSizeRange: ClosedRange<CGFloat> = 8...32
    private static let fontSizeKey = "pilot.fontSize"

    private static func loadFontSize() -> CGFloat {
        guard let stored = UserDefaults.standard.object(forKey: fontSizeKey) as? Double else {
            return defaultFontSize
        }
        return min(max(CGFloat(stored), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// Те же пределы, что у редактора: иначе ⌘+ за 32 копил бы невидимый
    /// запас, и ⌘− потом несколько раз ничего не делал бы.
    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        guard clamped != fontSize else { return }
        fontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.fontSizeKey)
        // Размер общий на все проекты — и на все открытые окна.
        for other in ProjectWindows.shared.workspaces where other !== self {
            other.setFontSize(clamped)
        }
    }

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
    /// То же для поля фильтра внизу навигатора.
    @Published private(set) var navigatorFilterFocusRequest = 0

    func focusNavigatorFilter() { navigatorFilterFocusRequest += 1 }
    /// ⇧⌘J — открытый файл в дереве проекта: выделить, прокрутить к нему
    /// и отдать дереву клавиатуру. Счётчик — чтобы повтор тоже срабатывал.
    @Published private(set) var treeRevealRequest = 0

    func revealInTree() {
        guard openFilePath != nil else { return }
        navigatorTab = .project
        // Под фильтром файла в дереве может не оказаться.
        navigatorFilter = ""
        treeRevealRequest += 1
    }

    /// ⌘F и соседи — панель поиска над редактором. Идут запросом, а не
    /// через цепочку ответчиков: фокус может быть в дереве файлов,
    /// а панель всё равно должна открыться и забрать курсор.
    struct FindRequest: Equatable {
        var seq: Int
        var action: NSTextFinder.Action
    }
    @Published private(set) var findRequest: FindRequest?
    private var findCounter = 0

    func find(_ action: NSTextFinder.Action) {
        isPaletteOpen = false
        findCounter += 1
        findRequest = FindRequest(seq: findCounter, action: action)
    }

    /// ⌘. — меню действий у курсора; номер запроса, как у reveal.
    @Published private(set) var contextActionsRequest = 0

    func showContextActions() {
        guard buffer != nil else { return }
        isPaletteOpen = false
        contextActionsRequest += 1
    }

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
            case .project: return L("Проект")
            case .outline: return L("Структура файла")
            case .review:  return L("Ревью мерж-реквестов")
            case .recent:  return L("Недавние проекты")
            }
        }
    }

    @Published var navigatorTab: NavigatorTab = .project
    /// Навигатор слева — у каждого окна свой. Последний выбор запоминается
    /// и достаётся следующему окну и следующему запуску.
    @Published var showsSidebar = UserDefaults.standard.object(forKey: Workspace.sidebarKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsSidebar, forKey: Self.sidebarKey) }
    }
    private static let sidebarKey = "pilot.showsSidebar"
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
    /// Каталог конфигов по правилам расширения: ⌘B по алиасу — в JSON.
    let configCatalogs = ConfigCatalogCache()
    /// APK, JAR, AAR и DEX: проект только для чтения, файлы даёт jadx.
    let archive = ArchiveService()

    /// Короткое сообщение в статус-строке: «ссылка битая», «ничего не найдено».
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?
    /// Что сейчас декомпилируется для показа: сборка .NET или класс из
    /// архива. Первое открытие `UnityEngine.CoreModule` — это секунды, и
    /// без отметки в статус-строке ⌘B выглядит так, будто не сработал.
    @Published private(set) var decompiling: String?
    /// Последний файл, который просили открыть, — даже если он не открылся
    /// (текстура, модель). Для «где используется ассет».
    private(set) var requestedFile: URL?
    /// Имя ассета, чьи использования сейчас в палитре.
    @Published private(set) var usagesTitle: String = ""

    private var unityChanges: AnyCancellable?
    private var archiveChanges: AnyCancellable?
    let git = GitService()
    let review = ReviewService()
    /// Кнопка ▶: цели запуска проекта и консоль.
    let run = RunService()
    /// Отладка: точки останова, сессия с Unity или .NET.
    let debug = DebugService()
    /// Окно NuGet: пакеты проектов .NET, поиск и установка.
    let nuget = NuGetService()
    /// Консоль Unity: Editor.log следом за редактором. Не пробрасывается
    /// в objectWillChange — лог пишется часто, а смотрят его только панель
    /// и значок в строке состояния, подписанные сами.
    let unityConsole = UnityConsole()
    /// Локальная история: версии файлов при сохранении и изменении снаружи
    /// (см. Workspace+LocalHistory). nil — проекта нет или это архив.
    private(set) var localHistory: LocalHistory?
    let localHistoryQueue = DispatchQueue(label: "pilot.history", qos: .utility)
    /// Окно истории открыто для этого файла.
    @Published var localHistoryFile: LocalHistoryFile?
    /// Окно коммита: подготовка, дифф, коммит и push. Подписано само —
    /// в objectWillChange воркспейса не пробрасывается.
    let commits = GitCommitService()
    private var observations: [AnyCancellable] = []

    // MARK: Расширения (см. Workspace+Extensions)

    /// Расширения в `.pilot/extensions/` этого проекта и второй половины пары.
    @Published var projectExtensions: [ProjectExtension] = []
    /// Правила включённых расширений — по ним работают пара, конфиги и граф.
    @Published var rules = ProjectRules.none
    /// Сломанные `extension.json`: что не так.
    @Published var extensionProblems: [String] = []

    // MARK: Пара (см. Workspace+Pair)

    /// Второй проект пары: клиент для сервера и наоборот.
    @Published var partner: URL?
    /// Единый поиск заодно ищет во второй половине пары.
    @Published var searchIncludesPair = UserDefaults.standard.bool(forKey: Workspace.pairSearchKey) {
        didSet {
            UserDefaults.standard.set(searchIncludesPair, forKey: Self.pairSearchKey)
            refreshSearch()
        }
    }
    static let pairSearchKey = "pilot.pairSearch"
    /// Замечания сверки с парой для открытого файла — поверх ошибок Rustlyn.
    var pairDiagnostics: [RustlynDiagnostic] = []
    var pairDiagnosticsBuffer: ObjectIdentifier?
    let pairCheckGeneration = AtomicCounter()
    /// Открытый файл из зеркальных папок и его копия во второй половине.
    @Published var mirror: MirrorState?
    /// Использования во второй половине пары — дописываются к ⌘R.
    var pairReferenceItems: [PaletteItem] = []
    let pairReferenceGeneration = AtomicCounter()

    /// Окно этого проекта. У каждого окна свой воркспейс — см. ProjectWindows.
    private(set) weak var window: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var closeGuard: WindowCloseGuard?
    private var lspObservation: AnyCancellable?
    private var lspReadyObservation: AnyCancellable?

    init() {
        unity.onAssetsReady = { [weak self] in self?.unityAssetsReady() }
        // Статус-строка и меню смотрят на воркспейс — пусть видят и Unity.
        unityChanges = unity.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        archiveChanges = archive.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Статус-строка, полоски у номеров строк и панель ревью читают git
        // и GitLab через workspace: их изменения должны перерисовывать то же,
        // что и наши.
        // Точки останова и стрелка выполнения рисуются в редакторе, который
        // смотрит на воркспейс. Вывод программы сюда не идёт: у него свой объект.
        for publisher in [git.objectWillChange, review.objectWillChange, run.objectWillChange, debug.objectWillChange] {
            observations.append(publisher.sink { [weak self] _ in self?.objectWillChange.send() })
        }
        git.onStatusChange = { [weak self] in self?.gitStatusChanged() }
        // git поменялся — сохранили файл, вернулись из терминала: окно коммита,
        // если его открывали, перечитывает статус.
        observations.append(git.$status.dropFirst().sink { [weak self] _ in
            guard let self, self.commits.isLoaded else { return }
            DispatchQueue.main.async { self.commits.refresh() }
        })
        commits.beforeDiscard = { [weak self] url in self?.recordBeforeDiscard(url) }
        debug.onShowLocation = { [weak self] url, line in self?.showDebugLocation(url, line: line) }
        // То же с языковым сервером (Swift и то, что описано в servers.json):
        // без этого фишка в статус-строке и ⌘T узнавали бы о его готовности
        // только при следующем клике.
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
    /// Файлы проекта — для поиска по тексту из расширений.
    var projectFiles: FileIndex? { index }
    /// Список файлов проекта — для второй половины пары.
    var fileIndex: FileIndex? { index }
    private var typeIndex: TypeIndex?
    /// Короткое и срочное: чтение открываемого файла, поиск в палитре, структура.
    let work = DispatchQueue(label: "pilot.index", qos: .userInitiated)
    /// Обход проекта — секунды на крупном проекте. На `work` файл, открытый
    /// в это время, и поиск ждали бы его конца.
    private let scanWork = DispatchQueue(label: "pilot.scan", qos: .userInitiated)
    /// Отдельная очередь: на крупном проекте разбор всех исходников — секунды, и на `work`
    /// он задержал бы и поиск файлов, и открытие файла.
    private let typeWork = DispatchQueue(label: "pilot.types", qos: .utility)
    /// Чтение метаданных сборок: короче разбора исходников и не должно
    /// стоять за ним в очереди.
    private let assemblyWork = DispatchQueue(label: "pilot.assemblies", qos: .utility)
    /// ⌘R без сервера читает все исходники — не на `work`, чтобы в это время
    /// открывались файлы и работал поиск.
    let referenceQueue = DispatchQueue(label: "pilot.references", qos: .userInitiated)
    /// Компиляция проекта Rustlyn'ом: секунды на большом проекте, и ждать её
    /// не должен никто — ни индекс, ни поиск.
    private let compileWork = DispatchQueue(label: "pilot.compile", qos: .utility)
    /// Компиляция идёт одна за раз; просьбы, пришедшие во время неё,
    /// сливаются в одну следующую.
    private var compileRunning = false
    private var compilePending = false

    /// Сохранённые файлы, ждущие переиндексации, и поколение символов.
    /// Поколение своё: полный разбор проекта и переиндексация по сохранению
    /// идут по одному пути и не должны затирать друг друга задним числом.
    private var pendingReindex: Set<String> = []
    private var pendingRemoved: Set<String> = []
    private var reindexScheduled = false
    private let symbolGeneration = AtomicCounter()

    /// Слежение за диском: правки мимо Pilot, переключение ветки, новые файлы.
    private let watcher = FileWatcher()
    /// Правила отсева шума для событий — по корневому .gitignore проекта.
    private var watchIgnore = IgnoreMatcher(layers: [], useSoftSkip: true)
    private var rescanScheduled = false
    private var rescanPending = false
    /// Пути, которые Pilot записал сам. Запись атомарная — через временный файл
    /// и переименование, — и системе видна как создание. Список файлов от
    /// своего же сохранения не меняется, пересобирать его незачем.
    private var ownWrites: Set<String> = []
    /// Переиндексация Rustlyn отложена до пересборки списка файлов.
    private var rustlynAfterRescan = false
    /// Корень, как его видит FSEvents: без симлинков.
    private var watchRoot: URL?

    /// Путь, как его пишет FSEvents. Не `resolvingSymlinksInPath`: тот
    /// нарочно отрезает `/private`, а FSEvents присылает `/private/tmp/…`.
    /// Удалённого файла уже нет — тогда настоящей делается его папка.
    nonisolated static func realPath(_ url: URL) -> URL {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, let resolved = realpath(parent.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(url.lastPathComponent)
    }
    private let scanGeneration = AtomicCounter()
    private let searchGeneration = AtomicCounter()
    private let loadGeneration = AtomicCounter()
    private var symbolTask: Task<Void, Never>?
    /// Единый поиск: что нашли имена, текст и языковой сервер по последнему
    /// запросу, и индексы, по которым это нашли.
    private var nameCandidates: [SearchCandidate] = []
    private var textCandidates: [SearchCandidate] = []
    private var lspCandidates: [SearchCandidate] = []
    private var searchSnapshot = SearchSnapshot()
    /// Своя очередь у текста: он дольше имён, и имена его не ждут.
    let textWork = DispatchQueue(label: "pilot.text-search", qos: .userInitiated)
    /// Полный список использований; поле ввода фильтрует его на месте.
    var allReferences: [PaletteItem] = []

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

    /// Файл или проект из командной строки или присланный снаружи: Unity,
    /// Finder, `open -a Pilot`. Для файла без проекта корнем становится
    /// ближайший git-репозиторий над ним; файл из другого проекта
    /// переключает на тот проект.
    ///
    /// Какое окно её получит, решает ProjectWindows: это — то, что уже
    /// открыло нужный проект, или пустое.
    func open(_ request: OpenRequest) {
        guard let resolved = Self.resolve(request) else { return }
        if resolved.isArchive {
            if root?.path != resolved.project.path { open(root: resolved.project) }
            return
        }
        let target = resolved.file.map { NavTarget(url: $0, range: request.range) }
        if !OpenRequest.staysInRoot(root, file: resolved.file, desired: resolved.project,
                                    repository: Git.repositoryRoot(for:)) {
            open(root: resolved.project, first: target)
            return
        }
        if let target { navigate(to: target) }
    }

    /// Откроется ли просьба здесь, не меняя проекта окна.
    func accepts(_ request: OpenRequest) -> Bool {
        guard let root, let resolved = Self.resolve(request) else { return false }
        if resolved.isArchive { return root.path == resolved.project.path }
        return OpenRequest.staysInRoot(root, file: resolved.file, desired: resolved.project,
                                       repository: Git.repositoryRoot(for:))
    }

    /// Что просьба значит на диске: какой проект и какой файл в нём. nil —
    /// такого пути нет.
    static func resolve(_ request: OpenRequest) -> (project: URL, file: URL?, isArchive: Bool)? {
        var isDirectory: ObjCBool = false
        if let path = request.path,
           !FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) { return nil }
        let file = isDirectory.boolValue ? nil : request.path
        // APK, JAR, DEX — это не файл для редактора, а сам проект.
        if let file, ArchiveLayout.isArchive(file) { return (file, nil, true) }
        guard let desired = request.project ?? (file.map(Self.projectRoot(containing:)) ?? request.path)
        else { return nil }
        return (desired, file, false)
    }

    /// Проект из списка недавних, из меню или стартового экрана: окно, где
    /// он уже открыт, выходит вперёд; иначе он открывается здесь, если окно
    /// пустое, или в новом окне рядом.
    func openProject(_ url: URL) {
        ProjectWindows.shared.open(root: url, from: self)
    }

    private static func projectRoot(containing file: URL) -> URL {
        let dir = file.deletingLastPathComponent()
        return Git.repositoryRoot(for: dir) ?? dir
    }

    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        // APK, JAR и прочие архивы открываются как проект, а не как файл.
        panel.canChooseFiles = true
        panel.allowedContentTypes = ArchiveLayout.openPanelTypes
        panel.allowsOtherFileTypes = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Открыть")
        panel.message = L("Выберите папку проекта или архив: APK, AAB, JAR, AAR, DEX")
        if panel.runModal() == .OK, let url = panel.url {
            openProject(url)
        }
    }

    /// `first` — файл, ради которого проект открывают (Unity, Finder).
    /// Он читается первым, а обход проекта, индексы, git, языковой сервер
    /// и прочие вкладки начинаются, когда файл уже показан: на проекте
    /// в четверть миллиона файлов всё это — секунды работы на всех ядрах.
    func open(root url: URL, first: NavTarget? = nil) {
        guard confirmUnsavedChanges() else { return }
        dropAllBuffers()
        root = url
        loadError = nil
        query = ""
        items = []
        index = nil
        fileCount = 0
        fileTree = nil
        forgetHistory()
        caret.setOutlineItem(nil)
        let archived = ArchiveLayout.isArchiveFile(url)
        branch = archived ? nil : GitInfo.branch(at: url)
        navigatorFilter = ""
        filteredTree = nil
        rememberRecent(url)
        refreshExtensions()
        // Вторая половина пары — следом, в своём окне: после этого хода,
        // когда это окно уже показывает свой проект.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.root == url else { return }
            ProjectWindows.shared.projectOpened(self)
        }
        compiler = .idle
        compilePending = false
        // Архив — не рабочая копия: ни git, ни ревью, ни Unity к нему не относятся.
        git.workspaceChanged(to: archived ? nil : url)
        review.workspaceChanged(to: archived ? nil : url)
        unity.workspaceChanged(to: archived ? nil : url)
        run.workspaceChanged(to: archived ? nil : url)
        nuget.workspaceChanged(to: archived ? nil : url)
        unityConsole.workspaceChanged(to: archived ? nil : unity.project?.root)
        commits.workspaceChanged(to: git.repository)
        localHistory = archived ? nil : LocalHistory(directory: LocalHistory.directory(forProject: url))
        localHistoryFile = nil
        if let history = localHistory {
            localHistoryQueue.asyncAfter(deadline: .now() + 30) { history.collectGarbage() }
        }
        debug.workspaceChanged(to: archived ? nil : url)
        archive.close()
        requestedFile = nil
        let generation = scanGeneration.bump()
        isIndexing = true
        typeIndex = nil
        typeCount = 0
        isTypeIndexing = true
        symbolIndex = nil
        symbolsBuiltFrom = nil
        assemblyIndex = nil
        assembliesBuiltFrom = nil
        pendingReindex.removeAll()
        pendingRemoved.removeAll()
        rescanPending = false
        rustlynAfterRescan = false
        ownWrites.removeAll()
        _ = symbolGeneration.bump()

        if archived {
            Rustlyn.stop(rustlyn)
            rustlyn = nil
            lsp.workspaceChanged(to: nil)
            openArchive(url, generation: generation)
            return
        }

        // Сначала — что лежит в корне: одно чтение папки, и боковая панель
        // уже не пустая. Остальное (кэши, обход, git, Unity, Rustlyn) — со
        // следующего хода, когда это дерево уже нарисовано: на большом
        // проекте они занимают все ядра, и дерево из кэша иначе ждало бы их.
        let exclude: FileIndex.Exclusion? = unity.project.map { $0.excludedFromIndex }
        fileTree = FileTree.shallow(root: url, ignore: FileChanges.rootMatcher(root: url), exclude: exclude)

        guard let first else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration.isCurrent(generation) else { return }
                self.lsp.workspaceChanged(to: url)
                self.restoreTabs(root: url)
                self.startIndexing(root: url, generation: generation)
            }
            return
        }
        // Сервер старого проекта не должен увидеть файл нового,
        // а новый поднимется вместе с остальным.
        lsp.workspaceChanged(to: nil)
        // Список вкладок не сохраняем, пока старые не дочитаны: иначе
        // сохранился бы один этот файл.
        isRestoringTabs = true
        history.navigate(from: nil, to: first)
        syncHistoryFlags()
        open(file: first.url, reveal: first.range) { [weak self] in
            guard let self, self.scanGeneration.isCurrent(generation) else { return }
            self.lsp.workspaceChanged(to: url)
            if let buffer = self.buffer, !buffer.isReadOnly { self.lsp.documentOpened(buffer.document) }
            if !archived {
                CopilotService.shared.projectOpened(url)
                if let buffer = self.buffer, !buffer.isReadOnly { CopilotService.shared.documentOpened(buffer.document) }
            }
            self.restoreTabs(root: url, takingFocus: false)
            self.startIndexing(root: url, generation: generation)
        }
    }

    /// APK, JAR, AAR, DEX: обходить нечего — список классов и ресурсов
    /// отдаёт jadx, он же потом даёт их текст. Индекс типов для ⇧⇧ строится
    /// из этого же списка, без декомпиляции.
    private func openArchive(_ url: URL, generation: Int) {
        let counter = scanGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let contents = try await self.archive.open(url)
                guard counter.isCurrent(generation) else { return }
                self.adopt(FileIndex(root: url, paths: contents.paths),
                           tree: FileTree.build(paths: contents.paths), indexing: false)
                self.adoptTypes(TypeIndex.make(root: url, entries: contents.types), indexing: false)
                // Манифест — то, с чего смотрят APK.
                if let manifest = contents.manifest {
                    self.open(file: url.appendingPathComponent(manifest))
                }
            } catch {
                guard counter.isCurrent(generation) else { return }
                self.isIndexing = false
                self.isTypeIndexing = false
                self.loadError = error.localizedDescription
            }
        }
    }

    /// Обход проекта и всё, что по нему строится; плюс git и Unity.
    private func startIndexing(root url: URL, generation: Int) {
        // Сессия Rustlyn живёт ровно столько, сколько открыт проект: её кэш
        // и её индекс — про этот корень, и у другого проекта они другие.
        // Символы препроцессора берутся у Unity, потому что от них зависит,
        // какая ветка `#if` живая, а значит — что вообще попадёт в разбор.
        rustlyn = Rustlyn.start(root: url, symbols: unity.project?.preprocessorSymbols ?? [], replacing: rustlyn)
        if let rustlyn {
            // Компиляция прошлого запуска: по ней ⌘B, ссылки и дополнение
            // работают, пока идёт обход и разбор. Очередь та же, что у
            // компиляции, — значит, чтение успевает до первой компиляции, а
            // та потом лишь сверяет файлы и, если ничего не менялось, её
            // оставляет.
            compileWork.async { [weak self] in
                guard let loaded = rustlyn.loadCompilation() else { return }
                Task { @MainActor in
                    guard let self, self.rustlyn === rustlyn, !self.compiler.isReady else { return }
                    NSLog("[rustlyn] компиляция из кэша: %d файлов за %d мс",
                          loaded.files, loaded.milliseconds)
                    self.compiler = .ready(loaded)
                    self.scheduleDiagnostics(delay: 0)
                }
            }
        }
        git.refresh()
        unity.indexAssets()
        let exclude: FileIndex.Exclusion? = unity.project.map { $0.excludedFromIndex }
        watchIgnore = FileChanges.rootMatcher(root: url)
        watchRoot = Self.realPath(url)
        watcher.onChange = { [weak self] events in self?.fileSystemChanged(events) }
        watcher.watch(root: url)

        // Типы сборок из кэша: без них ⇧⇧ и ⌘B по `Vector3` ждали бы чтения
        // сотен сборок. Свежий индекс сравнит свой список сборок с этим и,
        // если он тот же, строиться не станет вовсе.
        assemblyWork.async { [weak self] in
            guard let cached = IndexCache.loadAssemblies(root: url) else { return }
            Task { @MainActor in
                guard let self, self.scanGeneration.isCurrent(generation),
                      self.assemblyIndex == nil else { return }
                self.assemblyIndex = cached.index
                self.assembliesBuiltFrom = cached.builtAt
                self.refreshSearch()
            }
        }
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
                self.symbolIndex = cached.index
                self.symbolsBuiltFrom = cached.builtAt
            }
        }

        scanWork.async { [weak self] in
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
                self.rebuildAssemblyIndex(generation: generation)
            }
        }
    }

    /// `tree == nil` — оставить текущее дерево: список файлов не изменился.
    private func adopt(_ newIndex: FileIndex, tree: FileTree?, indexing: Bool) {
        index = newIndex
        fileCount = newIndex.count
        isIndexing = indexing
        if let tree { fileTree = tree }
        refreshSearch()
        // Индекс сменился — отфильтрованное дерево собрано по старому.
        if !navigatorFilter.isEmpty { navigatorFilterChanged() }
        if !indexing, rescanPending { scheduleRescan() }
    }

    /// Исходники разбираются по уже готовому списку файлов — второй раз
    /// обходить диск незачем. Проход один на оба индекса: символы для
    /// быстрого навигатора, а типы для ⇧⇧ просто выбираются из них.
    private func rebuildTypeIndex(files: [String], root url: URL, generation: Int) {
        let counter = scanGeneration
        let batch = symbolGeneration
        let symbolBatch = symbolGeneration.bump()
        // Индекс Rustlyn собирается по тому же списку файлов и в том же
        // фоне. Файлы, не изменившиеся с прошлого раза, он достаёт из кэша,
        // а не разбирает заново, — поэтому после сохранения это работа над
        // одним файлом, а не над проектом, и при повторном открытии проекта
        // это чтение, а не разбор.
        let sources = files.filter { Rustlyn.understands(url.appendingPathComponent($0)) }
            .map { url.appendingPathComponent($0) }
        if !sources.isEmpty, let rustlyn = rustlyn {
            typeWork.async { [weak self] in
                guard counter.isCurrent(generation) else { return }
                rustlyn.reindex(sources)
                // Индекс собран — теперь компиляция: она берёт файлы из него.
                Task { @MainActor in
                    guard counter.isCurrent(generation) else { return }
                    self?.scheduleCompile()
                }
            }
        }
        // Прошлый индекс и время, с которого он собран: разбирать заново
        // нужно только то, что менялось после. Без него — весь проект.
        let base = symbolIndex.flatMap { index in symbolsBuiltFrom.map { (index, $0) } }
        typeWork.async { [weak self] in
            let builtFrom = Date()
            let stop = { !counter.isCurrent(generation) }
            let symbols: SymbolIndex?
            // Кэш с диска мог ещё не дойти до главного потока — тогда он
            // читается здесь: разобрать заново весь проект дороже.
            let previous = base ?? IndexCache.loadSymbols(root: url).flatMap { cached in
                cached.builtAt.map { (cached.index, $0) }
            }
            if let (index, since) = previous, index.root == url {
                let (changed, removed) = SymbolIndex.changes(from: index, files: files, since: since)
                symbols = SymbolIndex.updating(index, changed: changed, removed: removed, shouldStop: stop)
                NSLog("[index] объявления: разобрано заново %d файлов, убрано %d, за %d мс",
                      changed.count, removed.count, Int(Date().timeIntervalSince(builtFrom) * 1000))
            } else {
                symbols = SymbolIndex.build(root: url, files: files, shouldStop: stop)
                NSLog("[index] объявления: весь проект (%@) за %d мс",
                      previous == nil ? "кэша нет" : "кэш другого корня",
                      Int(Date().timeIntervalSince(builtFrom) * 1000))
            }
            guard let symbols else { return }
            let fresh = TypeIndex.make(root: url, entries: symbols.typeEntries())
            Task { @MainActor in
                guard let self, counter.isCurrent(generation), batch.isCurrent(symbolBatch) else { return }
                self.symbolIndex = symbols
                self.symbolsBuiltFrom = builtFrom
                self.adoptTypes(fresh, indexing: false)
            }
            IndexCache.saveTypes(fresh, root: url)
            IndexCache.saveSymbols(symbols, root: url, builtFrom: builtFrom)
        }
    }

    /// Сборки, к которым у проекта нет исходников: плагины и библиотеки
    /// пакетов (их видно по индексу ассетов Unity), обычные `.dll` из
    /// индекса файлов и сборки самого редактора Unity. Собственные сборки
    /// проекта (`Library/ScriptAssemblies`) сюда не идут: на них есть
    /// исходники, и отвечать по ним должен индекс исходников.
    private func rebuildAssemblyIndex(generation: Int) {
        guard let root else { return }
        var urls: [URL] = []
        if let assets = unity.assets, let project = unity.project {
            urls += assets.assemblyPaths.map { project.root.appendingPathComponent($0) }
        }
        if let index {
            urls += index.display.filter { $0.hasSuffix(".dll") }.map { root.appendingPathComponent($0) }
        }
        let project = unity.project
        let previous = assemblyIndex
        let known = previous?.sources.map(\.path)
        let since = assembliesBuiltFrom
        let counter = scanGeneration
        // Своя очередь: на `typeWork` сейчас разбираются исходники всего
        // проекта, а ждать их ⌘B по `Vector3` незачем. Сборки редактора
        // ищутся тоже здесь: это листинг чужой папки, не дело главного потока.
        assemblyWork.async { [weak self] in
            let all = urls + (project?.engineAssemblies ?? [])
            // Тот же список — тот же индекс: пересобирать нечего.
            guard !all.isEmpty, all.map(\.path) != known else { return }
            let started = Date()
            // Не менявшиеся с прошлой сборки — из прошлого индекса.
            let fresh = AssemblyIndex.build(assemblies: all, reusing: previous, since: since,
                                            shouldStop: { !counter.isCurrent(generation) })
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if counter.isCurrent(generation), fresh.count > 0 {
                IndexCache.saveAssemblies(fresh, root: root, builtFrom: started)
            }
            Task { @MainActor in
                guard let self, counter.isCurrent(generation), fresh.count > 0 else { return }
                NSLog("[index] типы сборок: %d из %d сборок за %d мс",
                      fresh.count, fresh.assemblyCount, ms)
                self.assemblyIndex = fresh
                self.assembliesBuiltFrom = started
                self.refreshSearch()
            }
        }
    }

    private func adoptTypes(_ newIndex: TypeIndex, indexing: Bool) {
        typeIndex = newIndex
        typeCount = newIndex.count
        isTypeIndexing = indexing
        refreshSearch()
        // Полный разбор закончился — можно применить сохранения, которые
        // пришлись на него: ждать следующего было бы неоткуда.
        if !indexing, !pendingReindex.isEmpty || !pendingRemoved.isEmpty { scheduleReindexFlush() }
        if !indexing, rescanPending { scheduleRescan() }
    }

    // MARK: - Переиндексация правленого файла

    /// Файл сохранён — его объявления в индексе устарели. Пересобираем индекс,
    /// перечитав с диска только его: символы остальных файлов переносятся из
    /// старого индекса как есть. Полный разбор проекта стоил бы секунды.
    /// Файл сохранён — значит он снова совпадает с диском, и про C# опять
    /// отвечает Rustlyn.
    ///
    /// Первая же правка сбросила `settledFile`, и с тех пор красил свой
    /// лексер. Здесь связь восстанавливается: заново прочитать файл на той
    /// стороне (его отпечаток изменился, кэш это увидит сам), пометить
    /// модель и в фоне расставить точки возврата.
    ///
    /// Структура пересобирается тем же путём, что и всегда, — через
    /// `reindexAfterSave` ниже; здесь только про подсветку и про то, кому
    /// теперь верить.
    private func settleWithRustlyn(_ buffer: TextBuffer) {
        guard let rustlyn = rustlyn, Rustlyn.understands(buffer.url) else { return }
        guard rustlyn.open(buffer.url) else { return }
        buffer.model.useRustlyn(for: buffer.url)
        let url = buffer.url
        DispatchQueue.global(qos: .utility).async { rustlyn.warm(url) }
    }

    private func reindexAfterSave(_ url: URL) {
        guard let root, url.path.hasPrefix(root.path + "/") else { return }
        let path = String(url.path.dropFirst(root.path.count + 1))
        // Событие об этой записи придёт через полсекунды — к тому времени
        // путь должен быть здесь, иначе своё же сохранение выглядит как
        // появление файла и тянет полное пересканирование.
        ownWrites.insert(path)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.ownWrites.remove(path)
        }
        guard SymbolIndex.spec(forPath: path) != nil else { return }   // не исходник — нечего разбирать
        pendingReindex.insert(path)
        scheduleReindexFlush()
    }

    /// ⌥⌘S сохраняет пачкой — ждём, пока она уляжется, и пересобираем один раз.
    private func scheduleReindexFlush() {
        guard !reindexScheduled else { return }
        reindexScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.flushReindex()
        }
    }

    private func flushReindex() {
        reindexScheduled = false
        guard !pendingReindex.isEmpty || !pendingRemoved.isEmpty else { return }
        guard let root, let base = symbolIndex else {
            pendingReindex.removeAll()
            pendingRemoved.removeAll()
            return
        }
        // Полный разбор проекта всё равно прочитает эти файлы с диска. Не
        // мешаем ему: он сам позовёт сюда снова, когда закончит.
        guard !isTypeIndexing else { return }

        let changed = Array(pendingReindex)
        let removed = pendingRemoved
        pendingReindex.removeAll()
        pendingRemoved.removeAll()
        // Правка C# — это и индекс Rustlyn, и компиляция проекта. Удалённый
        // файл языка уже не скажет, поэтому любое удаление тоже в счёт.
        if !removed.isEmpty || changed.contains(where: { Rustlyn.understands(root.appendingPathComponent($0)) }) {
            // Список файлов вот-вот соберут заново (checkout, новые файлы):
            // компилировать по старому — значит компилировать дважды.
            if rescanScheduled { rustlynAfterRescan = true } else { refreshRustlyn() }
        }
        // Поколение сканирования не трогаем — оно про обход диска, и его
        // сдвиг отменил бы идущий разбор проекта.
        let batch = symbolGeneration
        let symbolBatch = symbolGeneration.bump()
        typeWork.async { [weak self] in
            let started = Date()
            guard let fresh = SymbolIndex.updating(base, changed: changed, removed: removed,
                                                   shouldStop: { !batch.isCurrent(symbolBatch) })
            else { return }
            let types = TypeIndex.make(root: root, entries: fresh.typeEntries())
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Task { @MainActor in
                guard let self, batch.isCurrent(symbolBatch), self.root == root else { return }
                if changed.count + removed.count >= 20 {
                    NSLog("[fs] объявления: изменено %d, удалено %d, за %d мс", changed.count, removed.count, ms)
                }
                self.symbolIndex = fresh
                self.adoptTypes(types, indexing: false)
            }
            // Кэш на диске не трогаем: его переписывание стоит дороже самой
            // пересборки, а при следующем открытии проекта полный разбор
            // всё равно молча заменит его свежим.
        }
    }

    // MARK: - Компиляция проекта (Rustlyn)

    /// Индекс Rustlyn по текущему списку исходников, затем компиляция. Файлы,
    /// которые не менялись, индекс достаёт из кэша, а компиляция — из прошлой
    /// компиляции: после сохранения это работа над одним файлом и проход
    /// объявлений.
    private func refreshRustlyn() {
        guard let root, let rustlyn = rustlyn, let files = index?.display else { return }
        let sources = files.map { root.appendingPathComponent($0) }.filter(Rustlyn.understands)
        typeWork.async { [weak self] in
            if !sources.isEmpty { rustlyn.reindex(sources) }
            Task { @MainActor in self?.scheduleCompile() }
        }
    }

    /// Скомпилировать проект заново. Пока компиляция идёт, отвечает прежняя;
    /// просьбы, пришедшие за это время, сливаются в одну следующую.
    private func scheduleCompile() {
        guard let rustlyn = rustlyn, root != nil else { return }
        guard !compileRunning else {
            compilePending = true
            return
        }
        compileRunning = true
        compilePending = false
        compiler = .compiling(first: !compiler.isReady)
        compileWork.async { [weak self] in
            let compiled = rustlyn.compile()
            Task { @MainActor in
                guard let self else { return }
                self.compileRunning = false
                let current = self.rustlyn === rustlyn
                if current {
                    if let compiled {
                        NSLog("[rustlyn] скомпилировано: %d файлов, %d сборок за %d мс",
                              compiled.files, compiled.references, compiled.milliseconds)
                        self.compiler = .ready(compiled)
                        // Компилятор знает больше разбора: проверяем заново.
                        self.scheduleDiagnostics(delay: 0)
                    } else {
                        self.compiler = .idle
                    }
                }
                // Проект сменили, пока шла компиляция: просьба нового ждала
                // здесь, и теперь её очередь.
                if self.compilePending || !current { self.scheduleCompile() }
            }
        }
    }

    // MARK: - Изменения на диске

    /// Файл, который пишут генераторы исходников Unity: `Temp/GeneratedCode`
    /// или папка, которую сборка Unity отдаёт компилятору в `Library/Bee`.
    static func isGeneratedCode(_ path: String) -> Bool {
        path.hasSuffix(".cs") && (path.contains("/Temp/GeneratedCode/") || path.contains("/Library/Bee/"))
    }

    /// Пачка событий от FSEvents: что-то поменялось мимо Pilot — правка в другом
    /// редакторе, переключение ветки, новый файл. Разбор в `FileChanges`,
    /// здесь только развод по трём делам: git, символы, список файлов.
    private func fileSystemChanged(_ events: [FileEvent]) {
        guard let root else { return }
        // Unity перекомпилировал скрипты, и генераторы переписали свой код.
        // Индекс эти папки не видит (Temp, Library), поэтому смотрим на
        // события до разбора: компиляция Rustlyn должна взять новый текст.
        if events.contains(where: { Self.isGeneratedCode($0.path) }) { scheduleCompile() }
        // Новый проект .NET или правка `.pilot/run.json` — другой список у ▶.
        if events.contains(where: { RunTargets.isRelevant($0.path) }) { run.refresh() }
        // Пакеты перечитываем, только если окно NuGet уже открывали.
        if nuget.isLoaded, events.contains(where: { NuGetProjects.isRelevant($0.path) }) { nuget.refresh() }
        reloadOpenTabs(touched: events)
        // FSEvents присылает настоящие пути: `/private/tmp/…` для проекта,
        // открытого как `/tmp/…`, путь без симлинков — для открытого через
        // ссылку. Сравнивать их с корнем как он есть — значит счесть все
        // события чужими: ни списка, ни индекса, ни git после checkout.
        let batch = FileChanges.classify(events, root: watchRoot ?? root, ignore: watchIgnore, ownWrites: ownWrites)
        guard !batch.isEmpty else { return }

        if batch.gitTouched { git.refresh() }
        // Разбирать заново стоит только исходники; остальное меняет лишь список.
        for path in batch.changed where SymbolIndex.spec(forPath: path) != nil {
            pendingReindex.insert(path)
        }
        // Удалённое проверять на язык нельзя — файла уже нет; лишний путь
        // в `removed` просто ни с чем не совпадёт.
        pendingRemoved.formUnion(batch.removed)
        if !pendingReindex.isEmpty || !pendingRemoved.isEmpty { scheduleReindexFlush() }
        // Проект описан заново: другие ссылки, другие символы, другие файлы.
        if batch.changed.contains(where: RustlynProjectKind.isProjectFile) { scheduleCompile() }
        if batch.needsRescan { scheduleRescan() }
    }

    /// Открытые вкладки, чей файл переписали снаружи. Чистая — перечитывается
    /// с диска, иначе после checkout в ней остался бы текст прежней ветки, и
    /// ⌘S записал бы его поверх. С несохранёнными правками — не трогаем, но
    /// говорим: выбирать, чья версия останется, должен человек.
    ///
    /// Сверяем с событиями до фильтра игнорирования: сгенерированный код
    /// Unity лежит в `Temp` и `Library`, в индекс не попадает, но открыт.
    private func reloadOpenTabs(touched events: [FileEvent]) {
        let touched = Set(events.map { Self.realPath(URL(fileURLWithPath: $0.path)).path })
        let prefix = ((watchRoot ?? root)?.path ?? "") + "/"
        let candidates = tabs.filter { tab in
            let path = Self.realPath(tab.url).path
            // Своё сохранение — не изменение снаружи.
            let own = path.hasPrefix(prefix) && ownWrites.contains(String(path.dropFirst(prefix.count)))
            return tab.document.media == nil && tab.document.decompiled == nil && !tab.isReviewVersion
                && touched.contains(path) && !own
        }
        for tab in candidates {
            if tab.isDirty {
                showNotice(L("\(tab.url.lastPathComponent) изменён на диске — несохранённые правки остались в редакторе"))
                continue
            }
            let url = tab.url
            let encoding = tab.document.encoding
            let before = tab.storage.string
            work.async { [weak self] in
                // Удалён — вкладка остаётся как есть: закрыть её или сохранить
                // заново решает человек.
                guard let data = try? Data(contentsOf: url) else { return }
                let text = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
                guard text != before else { return }
                Task { @MainActor in
                    // Пока читали, могли начать править — тогда не трогаем.
                    guard let self, !tab.isDirty, tab.storage.string == before,
                          self.tabs.contains(where: { $0 === tab }) else { return }
                    self.recordExternal(tab, previous: before, text: text)
                    tab.reload(from: text)
                }
            }
        }
    }

    /// Список файлов собирается заново целиком: правила игнорирования у git
    /// свои, и повторить их один раз в конце дешевле и честнее, чем угадывать
    /// по каждому событию. Отсюда и задержка побольше, чем у переиндексации, —
    /// распаковка ветки или импорт ассетов идут пачками.
    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        Task { @MainActor [weak self] in
            // Сам обход — десятки миллисекунд, а FSEvents и так копит события
            // по полсекунды: ждать дольше — только тянуть с деревом после checkout.
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.rescanFiles()
        }
    }

    private func rescanFiles() {
        rescanScheduled = false
        guard let url = root else { return }
        // Первый обход проекта ещё идёт — он и так принесёт свежий список,
        // а сдвиг поколения его бы отменил. Позовут обратно, когда закончится.
        guard !isIndexing, !isTypeIndexing else { rescanPending = true; return }
        rescanPending = false

        let exclude: FileIndex.Exclusion? = unity.project.map { $0.excludedFromIndex }
        let shown = index?.display
        let counter = scanGeneration
        let generation = counter.bump()
        scanWork.async { [weak self] in
            let started = Date()
            let fresh = FileIndex.scan(root: url, exclude: exclude,
                                       shouldStop: { !counter.isCurrent(generation) })
            guard counter.isCurrent(generation) else { return }
            NSLog("[fs] список файлов заново: %d файлов за %d мс", fresh.count,
                  Int(Date().timeIntervalSince(started) * 1000))
            IndexCache.save(fresh, root: url)
            // Список обычно совпадает с уже показанным — тогда дерево не
            // пересобираем и панель не перерисовывается впустую.
            let tree = shown == fresh.display ? nil : FileTree.build(paths: fresh.display)
            Task { @MainActor in
                guard let self, counter.isCurrent(generation), self.root == url else { return }
                self.adopt(fresh, tree: tree, indexing: false)
                // Файлы появились или пропали — компилятор узнаёт их только из
                // этого списка: переиндексация по изменённым шла по старому.
                if tree != nil || self.rustlynAfterRescan {
                    self.rustlynAfterRescan = false
                    self.refreshRustlyn()
                }
                // Плагин могли положить в проект только что; если список
                // сборок не изменился, пересборка индекса и не начнётся.
                self.rebuildAssemblyIndex(generation: generation)
            }
        }
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
        tearDown()
    }

    /// Окно проекта закрыли: всё, что держал проект, отпускается. Про
    /// несохранённое уже спросили — перед закрытием окна.
    func windowClosed() {
        tearDown()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        closeGuard = nil
        ProjectWindows.shared.disappeared(self)
    }

    private func tearDown() {
        dropAllBuffers()
        Rustlyn.stop(rustlyn)
        rustlyn = nil
        // Новое поколение отменяет обход ФС и загрузку файла, что ещё идут.
        _ = scanGeneration.bump()
        _ = loadGeneration.bump()
        compiler = .idle
        compilePending = false
        lsp.workspaceChanged(to: nil)
        git.workspaceChanged(to: nil)
        review.workspaceChanged(to: nil)
        unity.workspaceChanged(to: nil)
        run.workspaceChanged(to: nil)
        nuget.workspaceChanged(to: nil)
        unityConsole.workspaceChanged(to: nil)
        commits.workspaceChanged(to: nil)
        localHistory = nil
        localHistoryFile = nil
        configCatalogs.warm(root: nil, rules: nil)
        projectExtensions = []
        extensionProblems = []
        rules = .none
        debug.workspaceChanged(to: nil)
        archive.close()
        requestedFile = nil
        root = nil
        partner = nil
        mirror = nil
        index = nil
        symbolIndex = nil
        symbolsBuiltFrom = nil
        assemblyIndex = nil
        assembliesBuiltFrom = nil
        pendingReindex.removeAll()
        pendingRemoved.removeAll()
        rescanPending = false
        ownWrites.removeAll()
        _ = symbolGeneration.bump()
        watcher.watch(root: nil)
        fileTree = nil
        loadError = nil
        isIndexing = false
        fileCount = 0
        isPaletteOpen = false
        query = ""
        items = []
        caret.reset()
        occurrenceWord = nil
        branch = nil
        navigatorFilter = ""
        filteredTree = nil
        forgetHistory()
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
        UserDefaults.standard.set(list.map(\.path), forKey: Self.recentKey)
        // Список один на все окна: стартовый экран соседнего окна тоже его видит.
        recentRoots = list
        for other in ProjectWindows.shared.workspaces where other !== self {
            other.recentRoots = list
        }
    }

    // MARK: - Палитра

    func openPalette(mode: PaletteMode) {
        paletteMode = mode
        query = ""
        selection = 0
        isPaletteOpen = true
        switch mode {
        case .search:     runSearch()
        case .outline:    buildOutlineItems()
        case .changes:    buildChangeItems()
        case .recentLocations: buildRecentLocations()
        case .references, .declarations, .implementations, .assetUsages: break   // наполняются переходом, findReferences() и findAssetUsages()
        case .contract:   auditDatagrams()
        case .mirrors:    showMirrorDrift()
        case .counterparts: break                                              // наполняет goToCounterpart()
        }
    }

    private func queryChanged() {
        selection = 0
        switch paletteMode {
        case .search:     runSearch()
        case .references, .declarations, .implementations, .assetUsages, .recentLocations,
             .contract, .mirrors, .counterparts: filterReferences()
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
        case .search:  refreshSearch()
        case .changes: buildChangeItems()
        case .outline, .references, .declarations, .implementations, .assetUsages, .recentLocations,
             .counterparts, .contract, .mirrors: break
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
        recordCaret(offset)
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

    /// Место из консоли Unity: строка и столбец — с единицы, как в логе.
    func openLogLocation(_ url: URL, line: Int, column: Int?) {
        let position = LSPPosition(line: max(0, line - 1), character: max(0, (column ?? 1) - 1))
        navigate(to: NavTarget(url: url, range: LSPRange(start: position, end: position)))
        focusEditor()
    }

    /// ⌘L — к строке (и столбцу) текущего файла: `42` или `42:7`. Через
    /// историю переходов: ⌘[ вернёт туда, откуда пришли.
    func goToLine() {
        guard let document, let model = buffer?.model, model.lineCount > 0 else { NSSound.beep(); return }
        let current = model.position(at: caretOffset)
        let alert = NSAlert()
        alert.messageText = L("Перейти к строке")
        alert.informativeText = L("Строка или строка:столбец. В файле \(Localization.count(model.lineCount, "строка", "строки", "строк")).")
        let field = NSTextField(string: "\(current.line + 1):\(current.character + 1)")
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Перейти"))
        alert.addButton(withTitle: L("Отмена"))
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async { field.currentEditor()?.selectAll(nil) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let target = LineEditing.lineTarget(field.stringValue) else { NSSound.beep(); return }
        // За концом строки или файла — подрезать, как делает LSP.
        let position = model.position(at: model.offset(at: LSPPosition(line: target.line, character: target.column ?? 0)))
        navigate(to: NavTarget(url: document.url, range: LSPRange(start: position, end: position)))
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

    /// Список, который собрал кто-то снаружи основного файла (режимы пары).
    /// Открытую палитру того же режима не сбрасывает: набранное остаётся.
    func presentList(_ built: [PaletteItem], mode: PaletteMode, busy: Bool = false) {
        if !(isPaletteOpen && paletteMode == mode) {
            query = ""
            selection = 0
        }
        paletteMode = mode
        allReferences = built
        filterReferences()
        if selection >= items.count { selection = max(0, items.count - 1) }
        paletteBusy = busy
        isPaletteOpen = true
    }

    func filterReferences() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { items = allReferences; return }
        items = allReferences.filter {
            $0.primary.lowercased().contains(needle)
                || ($0.secondary?.lowercased().contains(needle) ?? false)
        }
    }

    // MARK: - Единый поиск
    //
    // Одна палитра на файлы, типы, символы и текст в файлах. Каждый источник
    // ищет своим индексом, а ранжирует их вместе `UnifiedSearch` — по тому,
    // что, судя по запросу, имеется в виду. Имена отвечают сразу; текст в
    // файлах — следом, как только прочитан диск, и встаёт в тот же список.

    /// Индексы, по которым собрана текущая выдача: строка собирается по
    /// номеру в том индексе, где её нашли, а индекс тем временем мог смениться.
    private struct SearchSnapshot {
        var files: FileIndex?
        var symbols: SymbolIndex?
        var types: TypeIndex?
        var assemblies: AssemblyIndex?
        /// Типы взяты из `types`, а не из `symbols`.
        var typesFromTypeIndex = false
        var textHits: [TextHit] = []
        var lspSymbols: [LSPSymbol] = []
        /// Имена из APK или JAR — у jadx. Номер кандидата отрицательный,
        /// как у символов сервера: сервера в архиве нет.
        var archiveSymbols: [ArchiveService.Symbol] = []
        /// Корень, от которого пути `files` и строк текста.
        var root: URL?
        /// Вторая половина пары, если ищем и в ней: её индексы и найденный текст.
        var pair: PairIndex?
        var pairTextHits: [TextHit] = []
    }
    private var pairNameCandidates: [SearchCandidate] = []
    private var pairTextCandidates: [SearchCandidate] = []

    /// ⌘P, ⇧⇧, ⌘T, ⇧⌘F. Повторное нажатие того же сочетания переключает
    /// между его фильтром и `again`; набранное остаётся.
    func openSearch(_ scope: SearchScope, again: SearchScope = .everything) {
        if isPaletteOpen && paletteMode == .search {
            setSearchScope(searchScope == scope ? again : scope)
            return
        }
        searchScope = scope
        openPalette(mode: .search)
    }

    func setSearchScope(_ scope: SearchScope) {
        guard scope != searchScope else { return }
        searchScope = scope
        selection = 0
        runSearch()
    }

    /// Индекс сменился — открытая выдача пересобирается по новому.
    private func refreshSearch() {
        if isPaletteOpen && paletteMode == .search { runSearch() }
    }

    private func runSearch() {
        guard paletteMode == .search else { return }
        symbolTask?.cancel()
        let generation = searchGeneration.bump()
        let counter = searchGeneration
        let q = query
        let scope = searchScope
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        let intent = SearchIntent.classify(q)

        var snapshot = SearchSnapshot(files: index, symbols: symbolIndex, assemblies: assemblyIndex, root: root)
        // Только типы — индекс типов: он меньше и готов раньше. Иначе
        // символы: в них и типы, и члены.
        if scope == .types, let typeIndex {
            snapshot.types = typeIndex
            snapshot.typesFromTypeIndex = true
        } else if symbolIndex == nil, let typeIndex {
            snapshot.types = typeIndex
            snapshot.typesFromTypeIndex = true
        }
        searchSnapshot = snapshot
        nameCandidates = []
        textCandidates = []
        lspCandidates = []
        pairNameCandidates = []
        pairTextCandidates = []
        paletteBusy = false

        guard !trimmed.isEmpty else {
            showRecentFiles(scope: scope)
            return
        }

        // Имена. Запрос с пробелом, скобкой или кириллицей — не имя, а
        // нечёткий поиск, который пробелов не замечает, нашёл бы по нему ерунду.
        if !intent.text && scope != .text {
            work.async { [weak self] in
                let found = Self.searchNames(q, scope: scope, in: snapshot,
                                             shouldStop: { !counter.isCurrent(generation) })
                Task { @MainActor in
                    guard let self, counter.isCurrent(generation) else { return }
                    self.nameCandidates = found
                    self.publishSearch(intent: intent)
                }
            }
        }

        // Текст в файлах: от трёх букв — иначе совпадает всё; в фильтре
        // «Текст» и для явно текстового запроса — сразу.
        let wantsText = scope.includes(.text)
            && (scope == .text || intent.text ? !trimmed.isEmpty : trimmed.count >= 3)
        if wantsText, let files = snapshot.files, let root {
            paletteBusy = true
            let paths = textSearchOrder(files.display, data: scope == .text)
            let needle = scope == .text ? q : trimmed
            // Пауза: на каждую букву читать проект незачем.
            textWork.asyncAfter(deadline: .now() + .milliseconds(scope == .text ? 80 : 160)) { [weak self] in
                guard counter.isCurrent(generation) else { return }
                let hits = ContentSearch.search(needle, root: root, paths: paths,
                                                shouldStop: { !counter.isCurrent(generation) })
                let candidates = hits.enumerated().map { number, hit in
                    Self.textCandidate(hit, number: number, path: paths[Int(hit.file)])
                }
                Task { @MainActor in
                    guard let self, counter.isCurrent(generation) else { return }
                    self.searchSnapshot.textHits = hits
                    self.textCandidates = candidates
                    self.paletteBusy = false
                    self.publishSearch(intent: intent)
                }
            }
        }

        // Вторая половина пары: те же имена и тот же текст по её индексам —
        // из её окна или из кэша, если окно не открыто.
        if searchIncludesPair, partner != nil {
            paletteBusy = true
            Task { [weak self] in
                guard let self, let pair = await self.partnerIndex(), counter.isCurrent(generation) else {
                    if counter.isCurrent(generation) { self?.paletteBusy = false }
                    return
                }
                self.searchSnapshot.pair = pair
                let pairSnapshot = SearchSnapshot(files: pair.files, symbols: pair.symbols, root: pair.root)
                if !intent.text && scope != .text {
                    self.work.async { [weak self] in
                        let found = Self.searchNames(q, scope: scope, in: pairSnapshot,
                                                     shouldStop: { !counter.isCurrent(generation) })
                            .map { candidate -> SearchCandidate in
                                var candidate = candidate
                                candidate.pair = true
                                // Своё выше чужого при прочих равных.
                                candidate.score -= 4
                                return candidate
                            }
                        Task { @MainActor in
                            guard let self, counter.isCurrent(generation) else { return }
                            self.pairNameCandidates = found
                            if !wantsText { self.paletteBusy = false }
                            self.publishSearch(intent: intent)
                        }
                    }
                }
                guard wantsText, let files = pair.files else {
                    // Имён по такому запросу не ищут — ждать больше нечего.
                    if intent.text || scope == .text { self.paletteBusy = false }
                    return
                }
                let paths = files.display.filter {
                    scope == .text || !Self.serializedExtensions.contains(($0 as NSString).pathExtension.lowercased())
                }
                let needle = scope == .text ? q : trimmed
                self.textWork.asyncAfter(deadline: .now() + .milliseconds(scope == .text ? 120 : 200)) { [weak self] in
                    guard counter.isCurrent(generation) else { return }
                    let hits = ContentSearch.search(needle, root: pair.root, paths: paths,
                                                    shouldStop: { !counter.isCurrent(generation) })
                    let candidates = hits.enumerated().map { number, hit -> SearchCandidate in
                        var candidate = Self.textCandidate(hit, number: number, path: paths[Int(hit.file)])
                        candidate.pair = true
                        candidate.score -= 4
                        return candidate
                    }
                    Task { @MainActor in
                        guard let self, counter.isCurrent(generation) else { return }
                        self.searchSnapshot.pairTextHits = hits
                        self.pairTextCandidates = candidates
                        self.paletteBusy = false
                        self.publishSearch(intent: intent)
                    }
                }
            }
        }

        // APK или JAR: имена классов, методов и полей — у jadx, без декомпиляции.
        if archive.isActive, scope.includes(.type) || scope.includes(.member), !intent.text {
            paletteBusy = true
            symbolTask = Task { [weak self] in
                // Как и с сервером: на каждую букву движок не дёргаем.
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard let self, !Task.isCancelled else { return }
                let found = Array(await self.archive.symbols(matching: trimmed).prefix(300))
                guard !Task.isCancelled, counter.isCurrent(generation) else { return }
                var symbols: [ArchiveService.Symbol] = []
                var candidates: [SearchCandidate] = []
                for symbol in found {
                    let source: SearchSource = symbol.kind == "m" || symbol.kind == "f" ? .member : .type
                    guard scope.includes(source), self.archive.fileURL(of: symbol) != nil else { continue }
                    let fuzzy = UnifiedSearch.fuzzy(intent.qualified ? intent.name : trimmed, symbol.name)
                    candidates.append(SearchCandidate(source: source, name: symbol.name, path: symbol.owner,
                                                      score: fuzzy?.score ?? 0, id: -Int32(symbols.count) - 1,
                                                      positions: fuzzy?.positions ?? []))
                    symbols.append(symbol)
                }
                self.searchSnapshot.archiveSymbols = symbols
                self.lspCandidates = candidates
                self.paletteBusy = false
                self.publishSearch(intent: intent)
            }
        }

        // Языковой сервер — для языков, которых не знают свои индексы.
        if scope.includes(.member), !intent.text, lsp.isReady, !archive.isActive {
            symbolTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self, !Task.isCancelled else { return }
                let symbols = Array(await self.lsp.symbols(matching: trimmed).prefix(200))
                guard !Task.isCancelled, counter.isCurrent(generation) else { return }
                self.searchSnapshot.lspSymbols = symbols
                self.lspCandidates = symbols.enumerated().map { number, symbol in
                    let fuzzy = UnifiedSearch.fuzzy(intent.qualified ? intent.name : trimmed, symbol.name)
                    return SearchCandidate(source: .member, name: symbol.name,
                                           path: self.relativePath(for: symbol.fileURL),
                                           // Отрицательный номер — символ сервера, а не своего индекса.
                                           score: fuzzy?.score ?? 0, id: -Int32(number) - 1,
                                           positions: fuzzy?.positions ?? [])
                }
                self.publishSearch(intent: intent)
            }
        }
    }

    /// Имена из своих индексов. Вне главного потока.
    nonisolated private static func searchNames(_ q: String, scope: SearchScope, in snapshot: SearchSnapshot,
                                                shouldStop: () -> Bool) -> [SearchCandidate] {
        var found: [SearchCandidate] = []
        if scope.includes(.file), let files = snapshot.files {
            for hit in files.search(q, limit: 200, shouldStop: shouldStop) {
                let path = files.relPath(hit.id)
                found.append(SearchCandidate(source: .file, name: path, path: path, score: hit.score,
                                             id: hit.id, positions: hit.positions))
            }
        }
        if scope.includes(.type) || scope.includes(.member) {
            if snapshot.typesFromTypeIndex, let types = snapshot.types {
                for hit in types.search(q, limit: 200, shouldStop: shouldStop) {
                    found.append(SearchCandidate(source: .type, name: types.declaration(hit.id).name,
                                                 path: types.relPath(hit.id), score: hit.score,
                                                 id: hit.id, positions: hit.positions))
                }
            } else if let symbols = snapshot.symbols {
                for hit in symbols.search(q, limit: 300, shouldStop: shouldStop) {
                    let symbol = symbols[hit.id]
                    let source: SearchSource = symbol.kind == .type ? .type : .member
                    guard scope.includes(source) else { continue }
                    found.append(SearchCandidate(source: source, name: symbol.name,
                                                 path: symbols.relPath(hit.id), score: hit.score,
                                                 id: hit.id, positions: hit.positions))
                }
            }
        }
        if scope.includes(.assembly), let assemblies = snapshot.assemblies {
            // Сборки дальше от проекта, и во «Всём» их немного.
            let limit = scope == .everything ? 20 : 100
            for hit in assemblies.search(q, limit: limit, shouldStop: shouldStop) {
                found.append(SearchCandidate(source: .assembly, name: assemblies.entry(hit.id).name,
                                             path: "", score: hit.score, id: hit.id,
                                             positions: hit.positions))
            }
        }
        return shouldStop() ? [] : found
    }

    /// Очки строки текста: целое слово, код, а не данные, и короткая строка —
    /// скорее то, что искали.
    nonisolated private static func textCandidate(_ hit: TextHit, number: Int, path: String) -> SearchCandidate {
        var score = hit.wholeWord ? 20 : 0
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.dataExtensions.contains(ext) { score -= 15 }
        score -= min(hit.text.count, 200) / 20
        return SearchCandidate(source: .text, name: hit.text, path: path, score: score,
                               id: Int32(number), wholeWord: hit.wholeWord, positions: hit.positions)
    }

    /// Сцены, префабы, ассеты: текст, но не код — совпадения в них ниже.
    nonisolated private static let dataExtensions: Set<String> = serializedExtensions.union([
        "json", "csv", "lock", "svg",
    ])

    /// Сериализованное Unity: во «Всём» не читается вовсе.
    nonisolated private static let serializedExtensions: Set<String> = [
        "unity", "prefab", "asset", "mat", "anim", "controller", "meta",
    ]

    /// Файлы для поиска текста: сначала открытые вкладки и папка открытого
    /// файла. Поиск останавливается на пределе совпадений, и то, что рядом,
    /// должно успеть в него попасть.
    ///
    /// Сцены, префабы и ассеты (`data`) читаются только в фильтре «Текст»:
    /// их бывают сотни мегабайт, а во «Всём» ищут код.
    private func textSearchOrder(_ all: [String], data: Bool) -> [String] {
        let open = Set(tabs.map { relativePath(for: $0.document.url) })
        let folder = openFilePath.map { ($0 as NSString).deletingLastPathComponent + "/" }
        var first: [String] = [], near: [String] = [], rest: [String] = []
        first.reserveCapacity(open.count)
        rest.reserveCapacity(all.count)
        for path in all {
            if !data, Self.serializedExtensions.contains((path as NSString).pathExtension.lowercased()) { continue }
            if open.contains(path) { first.append(path) }
            else if let folder, folder != "/", path.hasPrefix(folder) { near.append(path) }
            else { rest.append(path) }
        }
        return first + near + rest
    }

    /// Пустой запрос: открытые вкладки, дальше файлы проекта — как ⌘P.
    private func showRecentFiles(scope: SearchScope) {
        guard scope == .everything || scope == .files, let files = index else {
            items = []
            return
        }
        var built: [PaletteItem] = []
        var seen = Set<String>()
        for tab in tabs.reversed() {
            let path = relativePath(for: tab.document.url)
            guard seen.insert(path).inserted, tab.document.url.path.hasPrefix((root?.path ?? "") + "/") else { continue }
            built.append(PaletteItem(id: built.count, icon: Self.icon(forPath: path), primary: path,
                                     nameOffset: path.utf8.count - (path as NSString).lastPathComponent.utf8.count,
                                     trailing: git.changedFiles[path]?.letter ?? L("открыт"),
                                     target: NavTarget(url: tab.document.url, range: nil)))
        }
        for hit in files.search("", limit: 200, shouldStop: { false }) {
            let path = files.relPath(hit.id)
            guard seen.insert(path).inserted else { continue }
            built.append(PaletteItem(id: built.count, icon: Self.icon(forPath: path), primary: path,
                                     nameOffset: files.nameOffset(hit.id),
                                     trailing: git.changedFiles[path]?.letter,
                                     target: NavTarget(url: files.absoluteURL(hit.id), range: nil)))
        }
        items = built
        if selection >= items.count { selection = max(0, items.count - 1) }
    }

    /// Всё найденное — одним списком. Выделенная строка остаётся выделенной,
    /// когда следом приходит текст и список перестраивается.
    private func publishSearch(intent: SearchIntent) {
        let kept = selection > 0 && items.indices.contains(selection) ? items[selection].target : nil
        let tabPaths = Set(tabs.map { relativePath(for: $0.document.url) })
        let ranked = UnifiedSearch.rank(nameCandidates + lspCandidates + textCandidates
                                            + pairNameCandidates + pairTextCandidates, intent: intent,
                                        near: openFilePath, recent: tabPaths)
        let snapshot = searchSnapshot
        var archived: [Int: ArchiveService.Symbol] = [:]
        items = ranked.enumerated().compactMap { position, candidate in
            if candidate.id < 0, candidate.source != .text,
               snapshot.archiveSymbols.indices.contains(Int(-candidate.id - 1)) {
                archived[position] = snapshot.archiveSymbols[Int(-candidate.id - 1)]
            }
            return searchItem(candidate, id: position, in: snapshot)
        }
        archiveSymbols = archived
        if let kept, let again = items.firstIndex(where: { $0.target == kept }) {
            selection = again
        } else if selection >= items.count {
            selection = max(0, items.count - 1)
        }
    }

    private func searchItem(_ c: SearchCandidate, id: Int, in snapshot: SearchSnapshot) -> PaletteItem? {
        if c.pair {
            guard let pair = snapshot.pair else { return nil }
            var own = c
            own.pair = false
            var pairSnapshot = SearchSnapshot(files: pair.files, symbols: pair.symbols, root: pair.root)
            pairSnapshot.textHits = snapshot.pairTextHits
            guard var item = searchItem(own, id: id, in: pairSnapshot) else { return nil }
            // Метка половины пары — первой в приглушённой строке.
            item.secondary = [pair.label, item.secondary].compactMap { $0 }.joined(separator: " · ")
            if c.source == .file { item.trailing = nil }
            return item
        }
        switch c.source {
        case .file:
            guard let files = snapshot.files else { return nil }
            return PaletteItem(id: id, icon: Self.icon(forPath: c.path), primary: c.path,
                               nameOffset: files.nameOffset(c.id), positions: c.positions,
                               trailing: git.changedFiles[c.path]?.letter,
                               target: NavTarget(url: files.absoluteURL(c.id), range: nil))
        case .type where snapshot.typesFromTypeIndex:
            guard let types = snapshot.types else { return nil }
            let declaration = types.declaration(c.id)
            var secondary = c.path
            if let container = declaration.container, !container.isEmpty {
                secondary = "\(container) · \(c.path)"
            }
            return PaletteItem(id: id, icon: TypeIndex.icon(forKeyword: declaration.keyword),
                               primary: declaration.name, positions: c.positions, secondary: secondary,
                               trailing: declaration.keyword, target: types.target(c.id))
        case .type, .member:
            if c.id < 0, !snapshot.archiveSymbols.isEmpty { return archiveItem(c, id: id, in: snapshot) }
            if c.id < 0 { return lspItem(c, id: id, in: snapshot) }
            guard let symbols = snapshot.symbols, Int(c.id) < symbols.count else { return nil }
            let symbol = symbols[c.id]
            var secondary = c.path
            if let container = symbol.container, !container.isEmpty {
                secondary = "\(container) · \(c.path)"
            }
            return PaletteItem(id: id, icon: Self.icon(for: symbol.kind, keyword: symbol.keyword),
                               primary: symbol.name, positions: c.positions, secondary: secondary,
                               trailing: symbol.keyword ?? symbol.kind.label, target: symbols.target(c.id))
        case .assembly:
            guard let assemblies = snapshot.assemblies else { return nil }
            let entry = assemblies.entry(c.id)
            let assembly = assemblies.assembly(c.id).lastPathComponent
            return PaletteItem(id: id, icon: "shippingbox", primary: entry.display, positions: c.positions,
                               secondary: entry.namespace.isEmpty ? assembly : "\(entry.namespace) · \(assembly)",
                               trailing: L("сборка"), target: assemblies.target(c.id))
        case .text:
            guard snapshot.textHits.indices.contains(Int(c.id)), let root = snapshot.root else { return nil }
            let hit = snapshot.textHits[Int(c.id)]
            let start = LSPPosition(line: hit.line, character: hit.column)
            let end = LSPPosition(line: hit.line, character: hit.column + hit.length)
            return PaletteItem(id: id, icon: "text.alignleft", primary: hit.text, positions: hit.positions,
                               secondary: "\(c.path):\(hit.line + 1)", trailing: L("текст"),
                               target: NavTarget(url: root.appendingPathComponent(c.path),
                                                 range: LSPRange(start: start, end: end)))
        }
    }

    /// Символы из архива по номеру строки палитры: их место jadx
    /// выясняет при выборе, а не для всей выдачи сразу.
    private var archiveSymbols: [Int: ArchiveService.Symbol] = [:]

    private func archiveItem(_ c: SearchCandidate, id: Int, in snapshot: SearchSnapshot) -> PaletteItem? {
        let number = Int(-c.id - 1)
        guard snapshot.archiveSymbols.indices.contains(number) else { return nil }
        let symbol = snapshot.archiveSymbols[number]
        guard let url = archive.fileURL(of: symbol) else { return nil }
        let kind: OutlineKind = symbol.kind == "m" ? .method : symbol.kind == "f" ? .field : .type
        return PaletteItem(id: id, icon: kind == .type ? TypeIndex.icon(forKeyword: "class") : kind.icon,
                           primary: symbol.name, positions: c.positions, secondary: symbol.owner,
                           trailing: kind.label, target: NavTarget(url: url, range: nil))
    }

    private func lspItem(_ c: SearchCandidate, id: Int, in snapshot: SearchSnapshot) -> PaletteItem? {
        let number = Int(-c.id - 1)
        guard snapshot.lspSymbols.indices.contains(number) else { return nil }
        let symbol = snapshot.lspSymbols[number]
        var secondary = c.path
        if let container = symbol.containerName, !container.isEmpty {
            secondary = "\(container) · \(c.path)"
        }
        return PaletteItem(id: id, icon: symbol.iconName, primary: symbol.name, positions: c.positions,
                           secondary: secondary, trailing: symbol.kindLabel,
                           target: NavTarget(url: symbol.fileURL ?? rootOrCurrent(), range: symbol.range))
    }

    // MARK: - Навигация по проекту: быстрый индекс, затем компилятор
    //
    // C# понимает Rustlyn. Пока он компилирует проект, на ⌘B отвечает индекс
    // объявлений — его и Pilot, — а на ⌘R поиск по тексту; когда компиляция
    // готова — компилятор, и индекс там, где тот не знает. Переключение
    // незаметно — меняется только точность ответа. Остальные языки — свой
    // языковой сервер, если он есть, и тот же быстрый навигатор, если нет.

    /// Есть ли чем отвечать на поиск символов. ⌘B и ⌘R работают всегда.
    var canSearchSymbols: Bool { lsp.isReady || symbolIndex != nil || archive.isActive }

    /// Кто сейчас отвечает на навигацию — для статус-строки.
    var navigationEngine: NavigationEngine {
        if compiler.isReady { return .compiler }
        return symbolIndex != nil ? .index : .indexing
    }

    enum NavigationEngine { case indexing, index, compiler }

    /// Языковой сервер догрелся. Если открыт поиск — пересобираем выдачу уже
    /// с ним, не закрывая палитру и не стирая набранное.
    private func languageServerBecameReady() {
        refreshSearch()
    }

    static func icon(for kind: OutlineKind, keyword: String?) -> String {
        if kind == .type, let keyword { return TypeIndex.icon(forKeyword: keyword) }
        return kind.icon
    }

    // MARK: - Переход к объявлению и использованиям

    /// Переход к объявлению.
    ///
    /// C# — Rustlyn: компилятор, если проект скомпилирован, индекс
    /// объявлений — пока нет (см. `LocalNavigator`). Остальные языки — свой
    /// языковой сервер, если он готов, и быстрый навигатор, если нет или он
    /// ничего не нашёл.
    ///
    /// `followConfigs: false` — к объявлению константы, а не в конфиг, на
    /// который указывает её значение (`ConfigNames.Jobs` → `jobs.json`).
    func goToDefinition(at offset: Int, followConfigs: Bool = true) {
        guard let document else { return }

        if followConfigs, goToConfig(at: offset, in: document) { return }

        // Декомпилированный класс: куда ведёт имя, точно знает jadx.
        if archive.owns(document.url) {
            Task { [weak self] in
                guard let self else { return }
                switch await self.archive.definition(in: document, at: offset) {
                case .target(let target):   self.navigate(to: target)
                case .declaration:          self.findReferences(at: offset)
                case .unavailable(let why): self.showNotice(why)
                }
            }
            return
        }

        // Сцены, префабы, .asmdef: ссылка — это GUID и fileID, ни
        // компилятор, ни языковой сервер о них ничего не знают.
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
        // позиции указали бы не туда. Текст, собранный Pilot из метаданных
        // .dll, — тем более: по этому пути у сервера лежит сборка, а не код.
        guard !Rustlyn.understands(document.url), lsp.isReady,
              document.revision == nil, document.decompiled == nil else {
            jumpToLocalDeclaration(at: offset, in: document)
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
                self.jumpToLocalDeclaration(at: offset, in: document)
            }
        }
    }

    func navDocument(_ document: LoadedDocument) -> NavDocument {
        var relPath: String?
        if let root, document.url.path.hasPrefix(root.path + "/") {
            relPath = String(document.url.path.dropFirst(root.path.count + 1))
        }
        // Снимок, а не живая модель: навигатор работает и в фоне (поиск
        // использований), а редактор тем временем правит модель на главном.
        return NavDocument(url: document.url, relPath: relPath,
                           model: document.model.snapshot(), outline: document.outline)
    }

    /// ⌘B через Rustlyn и быстрый навигатор. Тип цели выяснен — прыгаем; не
    /// выяснен, а объявлений с таким именем несколько — показываем их
    /// списком, ближние первыми.
    private func jumpToLocalDeclaration(at offset: Int, in document: LoadedDocument) {
        let navigator = LocalNavigator(index: symbolIndex, document: navDocument(document))
        var answer = navigator.definition(at: offset)
        // Догадка по имени против типа из сборки, который файл видит через
        // `using`: `Vector3` в файле с `using UnityEngine` — движковый, даже
        // если где-то в пакетах лежит одноимённый тестовый.
        if !answer.isExact, let visible = visibleAssemblyType(at: offset, in: document, context: navigator.fileInfo) {
            answer = LocalNavigator.Answer(declarations: [visible], isExact: true)
        }
        // Одна строка на ⌘B: куда ответили вести. Без неё «никуда не
        // перешло» не отличить от «перешло не туда» и «ответа не было».
        NSLog("[nav] ⌘B %@:%d → %@", document.url.lastPathComponent, offset,
              answer.declarations.isEmpty ? "ничего"
                : answer.declarations.prefix(3).map { d in
                    "\(d.target.url.lastPathComponent):\(d.target.range.map { "\($0.start.line + 1)" } ?? "?")"
                  }.joined(separator: ", ") + (answer.isExact ? "" : " (список)"))
        guard let first = answer.declarations.first else {
            // Исходников с таким именем в проекте нет — может быть, это тип
            // из сборки: `Vector3`, класс плагина, что угодно без исходников.
            if !jumpToAssemblyType(at: offset, in: document) { explainMissingDefinition() }
            return
        }
        if answer.isExact {
            navigate(to: first.target)
        } else {
            showDeclarations(answer.declarations)
        }
    }

    /// Тип из сборки с именем под курсором, который файл видит: его
    /// namespace — один из `using` или тот, в котором файл сам. Ответ, только
    /// если такой ровно один.
    private func visibleAssemblyType(at offset: Int, in document: LoadedDocument,
                                     context: SourceFileInfo) -> FoundDeclaration? {
        guard let assemblies = assemblyIndex,
              let identifier = Occurrences.identifier(in: document.model, at: offset) else { return nil }
        let visible = visibleAssemblyTypes(assemblies.matching(name: identifier.text), context: context)
        guard visible.count == 1, let only = visible.first else { return nil }
        return assemblies.declaration(only)
    }

    private func visibleAssemblyTypes(_ ids: [Int32], context: SourceFileInfo) -> [Int32] {
        guard let assemblies = assemblyIndex else { return [] }
        return ids.filter { id in
            let namespace = assemblies.entry(id).namespace
            return namespace.isEmpty || context.usings.contains(namespace)
                || context.namespaces.contains { $0 == namespace || $0.hasPrefix(namespace + ".") }
        }
    }

    /// Имя под курсором — в индексе сборок. Одно совпадение — открываем
    /// сборку на этом типе, несколько — показываем списком, как одноимённые
    /// объявления; видимые из файла по `using` — прежде прочих, и если такой
    /// один, прыгаем к нему. `false` — в сборках такого типа нет.
    private func jumpToAssemblyType(at offset: Int, in document: LoadedDocument) -> Bool {
        guard let assemblies = assemblyIndex,
              let identifier = Occurrences.identifier(in: document.model, at: offset) else { return false }
        let all = assemblies.matching(name: identifier.text)
        let context = LocalNavigator(index: symbolIndex, document: navDocument(document)).fileInfo
        let visible = visibleAssemblyTypes(all, context: context)
        let found = visible.isEmpty ? all : visible
        guard let first = found.first else { return false }
        if found.count == 1 {
            navigate(to: assemblies.target(first))
        } else {
            showDeclarations(found.map { assemblies.declaration($0) })
        }
        return true
    }

    /// ⌘B не нашёл ничего. Молчание в ответ выглядит как сломанная клавиша,
    /// а причина бывает простая: проект ещё не скомпилирован, и ответить
    /// может только индекс объявлений.
    private func explainMissingDefinition() {
        if let document, Rustlyn.understands(document.url), rustlyn != nil {
            switch compiler {
            case .compiling(first: true):
                showNotice(L("Объявление не найдено: Rustlyn ещё компилирует проект"))
            case .idle:
                showNotice(L("Объявление не найдено: проект ещё не скомпилирован"))
            default:
                showNotice(L("Объявление не найдено"))
            }
            return
        }
        switch lsp.state {
        case .starting(let progress):
            let detail = progress.isEmpty ? "" : " (\(progress))"
            showNotice(L("Объявление знает языковой сервер — он ещё запускается\(detail)"))
        case .failed(let why):
            showNotice(L("Объявление не найдено: языковой сервер не работает — \(why)"))
        case .stopped, .ready:
            showNotice(L("Объявление не найдено"))
        }
    }

    func showDeclarations(_ declarations: [FoundDeclaration], mode: PaletteMode = .declarations) {
        paletteMode = mode
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

    /// ⌥⌘B — кто наследует тип под курсором или переопределяет его метод.
    /// Только индексы объявлений, Rustlyn и свой: `bases` они знают с первой
    /// секунды. Единственная реализация — прыгаем сразу, иначе список.
    func findImplementations(at offset: Int) {
        guard let document else { return }
        let answer = LocalNavigator(index: symbolIndex, document: navDocument(document)).implementations(at: offset)
        if answer.isExact, let first = answer.declarations.first {
            navigate(to: first.target)
            return
        }
        // Пустой ответ тоже показываем палитрой: молчание в ответ на клавишу
        // неотличимо от того, что она не сработала.
        showDeclarations(answer.declarations, mode: .implementations)
    }

    func findReferences(at offset: Int) {
        guard let document else { return }
        let position = document.model.position(at: offset)
        let url = document.url
        pairReferenceItems = []
        let word = Occurrences.identifier(in: document.model, at: offset)?.text

        paletteMode = .references
        query = ""
        selection = 0
        items = []
        allReferences = []
        paletteBusy = true
        isPaletteOpen = true
        // Имя типа — ищем его и во второй половине пары: датаграмму шлёт
        // одна сторона, а ловит другая.
        if let word { findPartnerReferences(of: word) }

        if archive.owns(url) {
            let generation = searchGeneration.bump()
            let counter = searchGeneration
            Task { [weak self] in
                guard let self else { return }
                let found = await self.archive.usages(in: document, at: offset)
                guard counter.isCurrent(generation), self.paletteMode == .references else { return }
                self.showReferences(found)
            }
            return
        }

        // C# — Rustlyn: использования символа, а не слова.
        if Rustlyn.understands(document.url), let rustlyn = rustlyn, document.decompiled == nil {
            findRustlynReferences(rustlyn, at: offset, in: document)
            return
        }
        // Про текст из метаданных .dll сервер ничего не знает.
        guard lsp.isReady, document.decompiled == nil else {
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

    /// ⌘R по C#: скомпилированный проект, и в нём всё, что связывается с
    /// тем же символом — перегрузка не спутается с перегрузкой, а поле с
    /// одноимённой локальной переменной. Пока компиляции нет — по тексту.
    private func findRustlynReferences(_ rustlyn: Rustlyn, at offset: Int, in document: LoadedDocument) {
        let url = document.url
        // Правленый файл спрашиваем его текстом: смещение — в нём.
        let text: String? = document.model.settledFile == nil ? document.model.text : nil
        let generation = searchGeneration.bump()
        let counter = searchGeneration
        referenceQueue.async { [weak self] in
            let found = rustlyn.references(url, offset: offset, text: text)
            Task { @MainActor in
                guard let self, counter.isCurrent(generation), self.paletteMode == .references else { return }
                switch found.refusal {
                case .none where !found.targets.isEmpty:
                    self.showReferences(found.targets.map { target in
                        (target.url, LSPRange(
                            start: LSPPosition(line: target.line, character: target.character),
                            end: LSPPosition(line: target.line, character: target.character + target.length)))
                    })
                case .notAName:
                    self.showReferences([])
                default:
                    if found.refusal == .notCompiled, case .compiling = self.compiler {
                        self.showNotice(L("Rustlyn ещё компилирует проект — ищу по тексту"))
                    }
                    self.findLocalReferences(at: offset, in: document)
                }
            }
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
        allReferences = renumbered(built + pairReferenceItems)
        filterReferences()
        paletteBusy = false
        ownReferencesShown(built)
    }

    /// Номера строк палитры подряд: списки собраны из разных источников.
    func renumbered(_ list: [PaletteItem]) -> [PaletteItem] {
        list.enumerated().map { position, item in
            var item = item
            item.id = position
            return item
        }
    }

    // MARK: - История курсора
    //
    // ⌘[ и ⌘] ходят не только по переходам, но и по далёким прыжкам курсора
    // внутри файла; ⇧⌘⌫ — к местам правок; ⇧⌘E — список недавних мест.
    // Правила — в `NavigationHistory`, здесь только откуда берутся события.

    private var history = NavigationHistory()
    /// Где курсор был в прошлый раз и какой длины был текст: курсор, сдвинутый
    /// вместе с изменением длины, — правка, а не прыжок.
    private var lastCaretPlace: NavTarget?
    private var lastTextLength = 0

    /// Опубликованы отдельно от истории: сама она меняется на каждое движение
    /// курсора, а меню и кнопкам нужно знать только, есть ли куда идти.
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private func syncHistoryFlags() {
        if canGoBack != history.canGoBack { canGoBack = history.canGoBack }
        if canGoForward != history.canGoForward { canGoForward = history.canGoForward }
    }

    private func forgetHistory() {
        history.removeAll()
        lastCaretPlace = nil
        lastTextLength = 0
        syncHistoryFlags()
    }

    /// Место в открытом файле.
    private func place(at offset: Int, in document: LoadedDocument) -> NavTarget {
        let position = document.model.position(at: offset)
        return NavTarget(url: document.url, range: LSPRange(start: position, end: position))
    }

    /// Где курсор сейчас.
    private var caretPlace: NavTarget? {
        document.map { place(at: caretOffset, in: $0) }
    }

    /// Курсор сдвинулся: прыжок, шаг или правка.
    private func recordCaret(_ offset: Int) {
        guard let document else {
            lastCaretPlace = nil
            return
        }
        let now = place(at: offset, in: document)
        let length = document.model.units.count
        if lastCaretPlace?.url == document.url, length != lastTextLength {
            history.edited(at: now)
        }
        // Правка (вставили сто строк) курсор уносит далеко, но это не прыжок.
        history.caretMoved(from: length != lastTextLength && lastCaretPlace?.url == document.url
                               ? now : lastCaretPlace,
                           to: now)
        lastCaretPlace = now
        lastTextLength = length
        syncHistoryFlags()
    }

    /// Переход с записью в историю. Без истории go-to-definition —
    /// ловушка: провалился и не вернёшься. `preview` — во временную вкладку.
    func navigate(to target: NavTarget, preview: Bool = false, then: (() -> Void)? = nil) {
        // Файл второй половины пары — в её окне, со своим индексом.
        if handOffToPartner(target) { return }
        history.navigate(from: caretPlace, to: target)
        syncHistoryFlags()
        jump(to: target, preview: preview, then: then)
    }

    func goBack() {
        guard let target = history.back(from: caretPlace) else { return }
        syncHistoryFlags()
        jump(to: target)
    }

    func goForward() {
        guard let target = history.forward(from: caretPlace) else { return }
        syncHistoryFlags()
        jump(to: target)
    }

    /// ⇧⌘⌫ — к последней правке; повтор — к правке перед ней.
    func goToLastEdit() {
        let now = caretPlace
        guard let target = history.previousEdit(from: now) else { return }
        history.navigate(from: now, to: target)
        syncHistoryFlags()
        jump(to: target)
    }

    /// ⇧⌘E — недавние места: правки и переходы, со строкой кода.
    private func buildRecentLocations() {
        var texts: [URL: [Substring]] = [:]
        func line(_ n: Int, of url: URL) -> String {
            if let tab = tab(for: url, revision: nil) {
                let model = tab.document.model
                guard n < model.lineCount else { return "" }
                return String(decoding: model.units[model.lineRange(n)], as: UTF16.self)
            }
            if texts[url] == nil {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                texts[url] = text.split(separator: "\n", omittingEmptySubsequences: false)
            }
            return texts[url].map { n < $0.count ? String($0[n]) : "" } ?? ""
        }
        let built = history.recent().enumerated().map { position, entry in
            let path = relativePath(for: entry.place.url)
            let number = entry.place.range?.start.line
            let code = number.map { line($0, of: entry.place.url).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            return PaletteItem(
                id: position,
                icon: entry.edited ? "pencil" : Self.icon(forPath: path),
                primary: code.isEmpty ? entry.place.url.lastPathComponent : code,
                secondary: number.map { "\(path):\($0 + 1)" } ?? path,
                trailing: entry.edited ? L("правка") : nil,
                target: entry.place)
        }
        allReferences = built
        items = built
    }

    /// Переход без диапазона — «открыть файл»: уже открытый остаётся,
    /// где был, а не прыгает в начало.
    private func jump(to target: NavTarget, preview: Bool = false, then: (() -> Void)? = nil) {
        isPaletteOpen = false
        if document?.url == target.url {
            if !preview, target.range == nil, let buffer { keepTabOpen(buffer) }
            if let range = target.range { requestReveal(range) }
            revealDeclaration(target)
            then?()
        } else {
            open(file: target.url, reveal: target.range, preview: preview) { [weak self] in
                self?.revealDeclaration(target)
                then?()
            }
        }
    }

    /// Цель, у которой вместо строки — имя объявления: так открывается тип
    /// из сборки. Где он окажется в тексте, видно только после разбора,
    /// поэтому ищем его в структуре уже открытого файла.
    private func revealDeclaration(_ target: NavTarget) {
        guard let name = target.declaration, let document,
              document.url.standardizedFileURL == target.url.standardizedFileURL else { return }
        let types = document.outline.filter { $0.kind == .type && $0.name == name }
        guard let item = types.first ?? document.outline.first(where: { $0.name == name }) else { return }
        requestReveal(rangeFor(item, in: document))
    }

    // MARK: - Открытие файла

    func activateSelection() {
        guard selection >= 0, selection < items.count else { return }
        if paletteMode == .search, let symbol = archiveSymbols[items[selection].id] {
            let fallback = items[selection].target
            isPaletteOpen = false
            Task { [weak self] in
                guard let self else { return }
                self.navigate(to: await self.archive.locate(symbol) ?? fallback)
            }
            return
        }
        navigate(to: items[selection].target)
    }

    /// Чтение и разбор уходят в фон: на файле в сотни тысяч строк первый
    /// проход лексера занимает сотни миллисекунд, и делать это на главном
    /// потоке — значит подвесить интерфейс.
    ///
    /// Файл, уже открытый во вкладке, не перечитывается: переходим на неё,
    /// а там правки, ⌘Z, выделение и прокрутка.
    ///
    /// `preview` — во временную вкладку, на место прежней временной.
    /// Открыть файл явно (⌘P, двойной клик) — значит оставить его вкладку
    /// насовсем; переход к месту в файле (⌘B) её временность не трогает.
    ///
    /// `then` — когда файл показан, не открылся или его сменил другой.
    func open(file url: URL, reveal: LSPRange? = nil, preview: Bool = false,
              then: (() -> Void)? = nil) {
        isPaletteOpen = false
        requestedFile = url
        let generation = loadGeneration.bump()
        // Второй клик двойного приходит, пока файл первого ещё читается:
        // он займёт временную вкладку так же, но уже насовсем. Иначе
        // исход зависел бы от того, успел ли файл прочитаться между кликами.
        let replacingPreview = preview || previewLoad == url
        previewLoad = preview ? url : nil
        if let tab = tab(for: url, revision: nil) {
            if !preview, reveal == nil { keepTabOpen(tab) }
            activate(tab, reveal: reveal)
            then?()
            return
        }
        loadError = nil
        let counter = loadGeneration
        // Отметку снимает тот, кто её поставил, и только свою: пока эта
        // сборка читалась, могли начать другую — та и решает, что показывать.
        let decompiled = archive.owns(url) || AssemblySource.isAssembly(url)
        let name = url.lastPathComponent
        if decompiled { decompiling = name }
        let finish = { [weak self] in
            guard let self, decompiled, self.decompiling == name else { return }
            self.decompiling = nil
        }
        // Класс из архива: текста на диске нет, его декомпилирует jadx.
        if archive.owns(url) {
            Task { [weak self] in
                guard let self else { return }
                let result: Result<LoadedDocument, Error>
                do {
                    result = .success(try await self.archive.loadDocument(url))
                } catch {
                    result = .failure(error)
                }
                finish()
                if counter.isCurrent(generation) {
                    self.present(result, reveal: reveal, preview: preview, replacingPreview: replacingPreview)
                }
                then?()
            }
            return
        }
        let unityContext = unity.context

        work.async { [weak self] in
            guard let self else { return }
            let result = Result { try LoadedDocument.load(url: url, unity: unityContext) }
            Task { @MainActor in
                finish()
                if counter.isCurrent(generation) {
                    self.present(result, reveal: reveal, preview: preview, replacingPreview: replacingPreview)
                }
                then?()
            }
        }
    }

    /// Файл в версии MR: текст берётся из коммита, а не с диска. Файлы MR
    /// обычно проходят подряд (⌥⌘↓), поэтому следующий занимает вкладку
    /// предыдущего, а не открывает новую.
    func open(reviewFile file: ReviewFile, reveal: LSPRange? = nil) {
        isPaletteOpen = false
        previewLoad = nil
        let generation = loadGeneration.bump()
        if let tab = reviewTab(for: file) {
            activate(tab, reveal: reveal)
            return
        }
        loadError = nil
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
            self.present(result, reveal: reveal, replacingReviewTab: true)
        }
    }

    /// IL метода, объявленного в строке `line` открытой сборки — отдельной
    /// вкладкой, только для чтения.
    ///
    /// Второй вопрос к сборке, задаваемый по одному: её поверхность — это
    /// проход по таблицам метаданных и ни одной инструкции, а тело читается
    /// у того метода, который открыли. На `System.Runtime` разница между
    /// «показать объявления» и «показать всё» — это разница между кадром и
    /// минутой.
    func showMethodBody(of url: URL, line: Int) {
        guard let rustlyn = rustlyn,
              let token = rustlyn.methodToken(url, line: line) else { return }
        guard let text = rustlyn.methodBody(url, token: token) else {
            loadError = rustlyn.lastError
            return
        }
        // Имя метода — первая строка ответа, комментарием: оно же годится
        // заголовком вкладки.
        let name = text.split(separator: "\n", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) } ?? ""
        present(.success(LoadedDocument.methodBody(assembly: url, token: token,
                                             name: name, text: text)),
                reveal: nil)
    }

    private func present(_ result: Result<LoadedDocument, Error>, reveal: LSPRange?,
                         preview: Bool = false, replacingPreview: Bool = false,
                         replacingReviewTab: Bool = false) {
        previewLoad = nil
        switch result {
        case .success(let doc):
            // Пока файл читался, его могли открыть другим путём.
            if let existing = tab(for: doc.url, revision: doc.revision) {
                if !preview, reveal == nil { keepTabOpen(existing) }
                activate(existing, reveal: reveal)
                return
            }
            let buffer = TextBuffer(document: doc, fontSize: fontSize)
            if replacingReviewTab, let current = self.buffer, current.isReviewVersion,
               let index = tabs.firstIndex(where: { $0 === current }) {
                // Версия из MR правок не знает — терять при замене нечего.
                discard(current)
                tabs.insert(buffer, at: index)
            } else if replacingPreview, let old = previewTab,
                      let index = tabs.firstIndex(where: { $0 === old }) {
                // Во временной вкладке правок нет: с первой же она перестаёт быть временной.
                discard(old)
                tabs.insert(buffer, at: index)
            } else {
                let active = self.buffer.flatMap { current in tabs.firstIndex { $0 === current } }
                tabs.insert(buffer, at: Tabs.insertionIndex(active: active, count: tabs.count))
            }
            if preview { previewTab = buffer }
            adopt(buffer)
            activate(buffer, reveal: reveal)
            trimTabs()
        case .failure(let error):
            setBuffer(nil)
            loadError = error.localizedDescription
            git.documentOpened(nil)
        }
    }

    // MARK: - Вкладки

    /// Вкладка рабочей копии (`revision == nil`) или версии файла из MR.
    func tab(for url: URL, revision: String?) -> TextBuffer? {
        let path = url.standardizedFileURL.path
        return tabs.first { $0.document.revision == revision && $0.url.standardizedFileURL.path == path }
    }

    /// Временная вкладка остаётся насовсем: двойной клик по ней или по
    /// файлу в дереве, первая правка.
    func keepTabOpen(_ tab: TextBuffer) {
        guard tab === previewTab else { return }
        previewTab = nil
        persistTabs()
    }

    /// Буфер стал вкладкой: его правки и «грязность» теперь касаются нас.
    private func adopt(_ buffer: TextBuffer) {
        buffer.onEdit = { [weak self] buffer, range, text in self?.bufferEdited(buffer, range: range, text: text) }
        buffer.onDirtyChange = { [weak self] buffer in self?.dirtyChanged(buffer) }
    }

    /// Клик по вкладке. Переход записывается в историю, как и любой другой:
    /// ⌘[ вернёт на прежнюю вкладку.
    func selectTab(_ tab: TextBuffer) {
        guard tab !== buffer else { return }
        isPaletteOpen = false
        _ = loadGeneration.bump()
        // Историю ведут по пути: версию из MR она открыла бы рабочей копией.
        // Сборка по своему пути откроется той же — её записать можно.
        if !tab.isReviewVersion {
            history.navigate(from: caretPlace, to: NavTarget(url: tab.url, range: nil))
            syncHistoryFlags()
        }
        requestedFile = tab.url
        activate(tab, reveal: nil)
    }

    /// ⇧⌘] и ⇧⌘[ — соседняя вкладка, по кругу.
    func selectAdjacentTab(_ direction: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = buffer, let index = tabs.firstIndex(where: { $0 === current }) else {
            selectTab(direction > 0 ? tabs[0] : tabs[tabs.count - 1])
            return
        }
        selectTab(tabs[(index + direction + tabs.count) % tabs.count])
    }

    /// Вкладки от недавней к давней.
    var recentTabs: [TextBuffer] {
        Tabs.recentOrder(lastActivated: tabs.map(\.lastActivated)).map { tabs[$0] }
    }

    /// Пункт меню «⌃Tab»: на вкладку, где был перед этой.
    func selectPreviousRecentTab() {
        guard let previous = recentTabs.first(where: { $0 !== buffer }) else { return }
        selectTab(previous)
    }

    // ⌃Tab: пока держат ⌃, вкладки только показываются — порядок недавних
    // не меняется, иначе второй Tab вернул бы на первую. Выбор фиксируется,
    // когда ⌃ отпустили.

    /// Где был курсор, когда начали ⌃Tab: пока листают, он уже в другой вкладке.
    private var tabSwitchOrigin: NavTarget?

    func beginTabSwitch() -> [TextBuffer] {
        tabSwitchOrigin = caretPlace
        return recentTabs
    }

    func showTabWhileSwitching(_ tab: TextBuffer) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        isPaletteOpen = false
        _ = loadGeneration.bump()
        activate(tab, reveal: nil, remember: false)
    }

    func endTabSwitch(startedAt start: TextBuffer?) {
        guard let current = buffer, current !== start else { return }
        activationCounter += 1
        current.lastActivated = activationCounter
        if !current.isReviewVersion {
            history.navigate(from: tabSwitchOrigin, to: NavTarget(url: current.url, range: nil))
            syncHistoryFlags()
        }
        tabSwitchOrigin = nil
        persistTabs()
    }

    func moveTab(_ tab: TextBuffer, to target: TextBuffer) {
        guard tab !== target, let from = tabs.firstIndex(where: { $0 === tab }),
              let to = tabs.firstIndex(where: { $0 === target }) else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        persistTabs()
    }

    /// ⌘W. Если вместо текста — сообщение «файл не открыть», убирает его.
    func closeActiveTab() {
        if let buffer {
            closeTabs([buffer])
        } else if loadError != nil {
            loadError = nil
            if let next = recentTabs.first { activate(next, reveal: nil) }
        }
    }

    func closeTab(_ tab: TextBuffer) { closeTabs([tab]) }

    /// ⌥⌘W — все, кроме этой (по умолчанию — активной).
    func closeOtherTabs(_ keep: TextBuffer? = nil) {
        guard let keep = keep ?? buffer else { return }
        closeTabs(tabs.filter { $0 !== keep })
    }

    func closeTabsToTheRight(of tab: TextBuffer) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        closeTabs(Array(tabs[(index + 1)...]))
    }

    /// Несохранённое без спроса не закрывается. После активной открывается
    /// та, где были перед ней: ⌘B, прочитал, ⌘W — и ты там, откуда пришёл.
    func closeTabs(_ closing: [TextBuffer]) {
        guard !closing.isEmpty, confirmUnsavedChanges(in: closing) else { return }
        let wasActive = buffer.map { current in closing.contains { $0 === current } } ?? false
        for tab in closing { discard(tab) }
        updateUnsavedCount()
        if wasActive {
            _ = loadGeneration.bump()
            if let next = recentTabs.first {
                activate(next, reveal: nil)
            } else {
                showNoEditor()
            }
        }
        persistTabs()
    }

    /// Вкладка уходит из памяти вместе с правками — спрашивать надо до этого.
    private func discard(_ tab: TextBuffer) {
        tabs.removeAll { $0 === tab }
        if tab === previewTab { previewTab = nil }
        tab.onEdit = nil
        tab.onDirtyChange = nil
        if !tab.isReadOnly {
            lsp.documentClosed(tab.url)
            CopilotService.shared.documentClosed(tab.url)
        }
    }

    /// Сверх лимита закрываются вкладки, где дольше всех не были.
    /// Несохранённые не трогаем, даже если их больше лимита.
    private func trimTabs() {
        guard tabs.count > Tabs.limit else { return }
        while tabs.count > Tabs.limit {
            let active = buffer.flatMap { current in tabs.firstIndex { $0 === current } }
            guard let victim = Tabs.evictionIndex(lastActivated: tabs.map(\.lastActivated),
                                                  dirty: tabs.map(\.isDirty), active: active)
            else { break }
            discard(tabs[victim])
        }
        persistTabs()
    }

    private func showNoEditor() {
        setBuffer(nil)
        loadError = nil
        caret.reset()
        occurrenceWord = nil
        git.documentOpened(nil)
    }

    // MARK: - Буферы и правки

    /// `remember: false` — показать, не меняя порядок недавних (⌃Tab).
    private func activate(_ buffer: TextBuffer, reveal: LSPRange?, remember: Bool = true) {
        if remember {
            activationCounter += 1
            buffer.lastActivated = activationCounter
        }
        loadError = nil
        if buffer !== self.buffer {
            // Прежний переход относится к прежнему файлу. Редактор, который
            // появится заново после картинки или Markdown, не должен его повторить.
            if reveal == nil { self.reveal = nil }
            // Курсор — там, где его оставили; редактор восстановит его сам,
            // и совпадение значений не даст ему опубликовать смену посреди
            // обновления вьюхи.
            caret.setOffset(buffer.lastCaret)
            setBuffer(buffer)
            caret.setOccurrences([])
            occurrenceWord = nil
            updateOutlineItem()
            scheduleOccurrences()
            // Правили и ушли, не дождавшись разбора, — разберём сейчас.
            if !buffer.document.isSemanticsFresh { rebuildOutline(buffer) }
            if buffer.isReadOnly {
                // Версия из MR: полоски и треды даёт ревью, а не HEAD. Серверу
                // её не показываем — у него на руках рабочая копия того же файла.
                // Текст сборки тем более: на диске по этому пути не C#, а байты.
                git.documentOpened(nil)
            } else {
                // Сервер поднимается здесь — лениво, при первом файле
                // подходящего языка, а не при запуске приложения. Повторное
                // открытие того же документа сервер не заметит.
                lsp.documentOpened(buffer.document)
                CopilotService.shared.documentOpened(buffer.document)
                git.documentOpened(buffer.document)
            }
        }
        if let reveal { requestReveal(reveal) }
        if remember { persistTabs() }
    }

    // MARK: - Markdown

    /// Markdown показывается свёрстанным; исходник — по ⇧⌘V или двойному клику.
    var isMarkdownDocument: Bool {
        guard let document, document.media == nil else { return false }
        return document.model.spec?.name == Languages.markdown.name
    }

    var showsRenderedMarkdown: Bool { isMarkdownDocument && buffer?.showsMarkdownSource == false }

    func toggleMarkdownSource() {
        guard isMarkdownDocument, let buffer else { return }
        buffer.showsMarkdownSource.toggle()
        objectWillChange.send()
        if buffer.showsMarkdownSource {
            focusEditor()
        } else {
            // Просмотр открывается там, где стоял курсор в исходнике.
            requestReveal(LSPRange(start: buffer.model.position(at: caretOffset), end: buffer.model.position(at: caretOffset)))
        }
    }

    /// Двойной клик по блоку просмотра — исходник на его строке.
    func showMarkdownSource(line: Int) {
        guard isMarkdownDocument, let buffer else { return }
        buffer.showsMarkdownSource = true
        objectWillChange.send()
        let position = LSPPosition(line: line, character: 0)
        requestReveal(LSPRange(start: position, end: position))
        focusEditor()
    }

    private func setBuffer(_ new: TextBuffer?) {
        buffer = new
        updateConflicts()
        scheduleDiagnostics(delay: 0.05)
    }

    private func dropAllBuffers() {
        _ = restoreGeneration.bump()
        isRestoringTabs = false
        for tab in tabs where !tab.isReadOnly {
            lsp.documentClosed(tab.url)
            CopilotService.shared.documentClosed(tab.url)
        }
        tabs = []
        previewTab = nil
        previewLoad = nil
        setBuffer(nil)
        updateUnsavedCount()
    }

    // MARK: - Вкладки между запусками
    //
    // Открытые файлы помнятся для каждого проекта: вернулся к нему — те же
    // вкладки, та же активная. Несохранённые правки на диск не пишутся —
    // перед закрытием Pilot про них спрашивает.

    private static let tabsKey = "pilot.openTabs"
    private let restoreGeneration = AtomicCounter()
    private let restoreQueue = DispatchQueue(label: "pilot.tabs", qos: .userInitiated)
    /// Пока вкладки проекта дочитываются, список не сохраняем: иначе
    /// сохранился бы недочитанный.
    private var isRestoringTabs = false
    private var persistedTabs: [String: Any]?

    private func persistTabs() {
        guard let root, !isRestoringTabs else { return }
        // Вкладка со сборкой помнится наравне с файлом: её текст соберётся
        // заново из той же .dll.
        let files = tabs.filter(\.isRestorable).map(\.url.path)
        let active = buffer.flatMap { $0.isRestorable ? $0.url.path : nil } ?? ""
        let preview = previewTab?.url.path ?? ""
        let entry: [String: Any] = ["files": files, "active": active, "preview": preview]
        if let persistedTabs, persistedTabs["files"] as? [String] == files,
           persistedTabs["active"] as? String == active,
           persistedTabs["preview"] as? String == preview { return }
        persistedTabs = entry

        var all = UserDefaults.standard.dictionary(forKey: Self.tabsKey) ?? [:]
        all[root.path] = entry
        // Проекты, выпавшие из недавних, не копим.
        let keep = Set(recentRoots.map(\.path)).union([root.path])
        all = all.filter { keep.contains($0.key) }
        UserDefaults.standard.set(all, forKey: Self.tabsKey)
    }

    /// Сначала читается активная — она показывается сразу, — затем
    /// остальные встают по местам, не отнимая фокус. `takingFocus: false` —
    /// уже открыт файл, ради которого открыли проект: остаётся он.
    private func restoreTabs(root: URL, takingFocus: Bool = true) {
        persistedTabs = nil
        isRestoringTabs = false
        guard let entry = UserDefaults.standard.dictionary(forKey: Self.tabsKey)?[root.path] as? [String: Any],
              let files = entry["files"] as? [String], !files.isEmpty else {
            persistTabs()
            return
        }
        persistedTabs = entry
        let active = entry["active"] as? String
        let preview = entry["preview"] as? String
        let urls = files.map { URL(fileURLWithPath: $0) }
        let activeURL = urls.first { $0.path == active }

        let restore = restoreGeneration.bump()
        let restoreCounter = restoreGeneration
        // Файл, который открывают в это время, важнее сохранённой активной.
        let load = takingFocus ? loadGeneration.bump() : nil
        let loadCounter = loadGeneration
        let unityContext = unity.context
        isRestoringTabs = true

        // Не на `work`: он для срочного, а ⌘P важнее вкладок.
        restoreQueue.async { [weak self] in
            var documents: [URL: LoadedDocument] = [:]
            let ordered = (activeURL.map { [$0] } ?? []) + urls.filter { $0 != activeURL }
            for url in ordered {
                guard restoreCounter.isCurrent(restore) else { return }
                guard let document = try? LoadedDocument.load(url: url, unity: unityContext) else { continue }
                documents[url] = document
                if url == activeURL {
                    Task { @MainActor in
                        guard let self, restoreCounter.isCurrent(restore) else { return }
                        self.adoptRestored([url], documents: [url: document], preview: preview,
                                           activate: load.map(loadCounter.isCurrent) == true ? url : nil)
                    }
                }
            }
            Task { @MainActor in
                guard let self, restoreCounter.isCurrent(restore) else { return }
                self.adoptRestored(urls, documents: documents, preview: preview, activate: nil)
                self.isRestoringTabs = false
                self.persistTabs()
            }
        }
    }

    /// Прочитанные вкладки — в сохранённом порядке, впереди открытых за это
    /// время. Уже открытый файл второй раз не открывается. Временная
    /// вкладка остаётся временной, если за это время не появилась другая.
    private func adoptRestored(_ urls: [URL], documents: [URL: LoadedDocument], preview: String?,
                               activate url: URL?) {
        var restored: [TextBuffer] = []
        for url in urls {
            if let existing = tab(for: url, revision: nil) {
                restored.append(existing)
            } else if let document = documents[url] {
                let buffer = TextBuffer(document: document, fontSize: fontSize)
                adopt(buffer)
                restored.append(buffer)
                if url.path == preview, previewTab == nil { previewTab = buffer }
            }
        }
        tabs = restored + tabs.filter { tab in !restored.contains { $0 === tab } }
        if let url, let active = tab(for: url, revision: nil) {
            requestedFile = url
            activate(active, reveal: nil)
        }
    }

    private var outlineTask: Task<Void, Never>?
    private var gitTask: Task<Void, Never>?

    /// Правка в буфере. Модель уже обновлена — рассылаем тем, кому нужно.
    private func bufferEdited(_ buffer: TextBuffer, range: LSPRange, text: String) {
        lsp.documentEdited(buffer.document, range: range, text: text)
        if !buffer.isReadOnly { CopilotService.shared.documentEdited(buffer.url, range: range, text: text) }
        if !buffer.isReviewVersion {
            debug.textEdited(buffer.url, start: (range.start.line, range.start.character),
                             endLine: range.end.line, text: text)
        }
        guard buffer === self.buffer else { return }
        // Сразу, без задержки: проход по началам строк — доли миллисекунды,
        // а кнопки «принять» должны стоять у своих маркеров после каждой правки.
        updateConflicts()

        // Вхождения посчитаны по старому тексту; пересчитаются на следующем
        // движении курсора, а оно после набора будет всегда.
        caret.setOccurrences([])
        occurrenceWord = nil
        scheduleDiagnostics()

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
                                    unityFile: semantics?.serialized, hierarchy: semantics?.hierarchy,
                                    version: snapshot.version)
                self.updateOutlineItem()
            }
        }
    }

    // MARK: - Unity

    /// Индекс GUID дособрался: у скриптов в открытой сцене появились имена.
    /// Разбираем файл заново, не трогая ни текст, ни прокрутку.
    private func unityAssetsReady() {
        // В индексе ассетов видны и сборки пакетов — второй раз обходить
        // кэш пакетов ради них не нужно.
        rebuildAssemblyIndex(generation: scanGeneration.current)
        // Фоновые вкладки переразберутся, когда на них вернутся.
        for tab in tabs where tab !== buffer { tab.invalidateSemantics() }
        guard let buffer else { return }
        rebuildOutline(buffer)
    }

    /// ⇧⌘R: какие сцены, префабы и ассеты ссылаются на открытый файл.
    /// Работает и для файлов, которые не открываются как текст: текстур, моделей.
    func findAssetUsages() {
        guard unity.isActive else { return }
        guard let url = document?.url ?? requestedFile,
              let asset = unity.assetPath(for: url) else {
            showNotice(L("Сначала откройте ассет"))
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
            showNotice(L("Нет файла \(target.lastPathComponent)"))
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
            showNotice(L("Это версия файла из мерж-реквеста — она только для чтения"))
            return
        }
        guard UnityEdits.validate(edits, in: buffer.storage.string as NSString) else {
            showNotice(L("Текст уже другой — правка не применена"))
            return
        }
        editCounter += 1
        pendingInspectorEdit = true
        editRequest = TextEditRequest(seq: editCounter, buffer: buffer, edits: edits, actionName: actionName)
    }

    /// Правка текущего файла одним шагом ⌘Z — из окна локальной истории.
    func applyEdits(_ edits: [UnityEdit], to url: URL, actionName: String) -> Bool {
        guard let buffer, buffer.url == url, !buffer.isReadOnly else { return false }
        editCounter += 1
        editRequest = TextEditRequest(seq: editCounter, buffer: buffer, edits: edits, actionName: actionName)
        return true
    }

    /// Перейти к объекту этого же файла — из хлебных крошек и ссылок инспектора.
    func revealUnityObject(fileID: Int64) {
        guard let document, let file = document.unityFile, let object = file.object(fileID) else { return }
        let range = object.nameRange ?? object.typeNameRange
        navigate(to: NavTarget(url: document.url, range: LSPRange(
            start: document.model.position(at: range.location),
            end: document.model.position(at: NSMaxRange(range)))))
    }

    /// GameObject или вложенный префаб под курсором — его строка выделена
    /// в иерархии под файлом в дереве проекта.
    var unityHierarchySelection: Int64? {
        guard let document, let file = document.unityFile, let hierarchy = document.unityHierarchy,
              let index = file.objectIndex(containing: caretOffset),
              let node = hierarchy.node(forObjectAt: index, in: file) else { return nil }
        return hierarchy.nodes[node].fileID
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
        // Начали править — файл нужен, временной вкладке больше не быть.
        if buffer.isDirty { keepTabOpen(buffer) }
        // Точка на вкладке — у любой, не только у активной.
        objectWillChange.send()
        updateUnsavedCount()
    }

    private func updateUnsavedCount() {
        let count = tabs.filter(\.isDirty).count
        if unsavedCount != count { unsavedCount = count }
        // Точка в красной кнопке окна — как у любого документа в macOS.
        window?.isDocumentEdited = count > 0
    }

    var isCurrentDirty: Bool { buffer?.isDirty == true }

    // MARK: - Окно

    /// SwiftUI показал окно этого проекта.
    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // Окна проектов восстанавливает не система, а Pilot: пустое окно
        // без проекта после перезапуска никому не нужно.
        window.isRestorable = false
        window.isDocumentEdited = unsavedCount > 0
        closeGuard = WindowCloseGuard(window: window) { [weak self] in
            self?.confirmUnsavedChanges() ?? true
        }
        let center = NotificationCenter.default
        windowObservers = [
            // Файлы вне проектов (сборки движка) спрашивают у сессии переднего окна.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { Rustlyn.activate(self?.rustlyn) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed() }
            },
        ]
        ProjectWindows.shared.appeared(self)
    }

    /// Нажатие или клик — этому окну? Мониторы клавиш локальные на всё
    /// приложение, а окон с проектами может быть несколько.
    func owns(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        var target = event.window ?? NSApp.keyWindow
        while let current = target {
            if current === window { return true }
            target = current.parent ?? current.sheetParent
        }
        return false
    }

    func bringToFront() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Ошибки, подсказки, переименование

    /// Ошибки открытого файла от Rustlyn. Версия — чтобы редактор знал, что
    /// перерисовать; буфер — чьи они: пока проверяли, вкладку могли сменить.
    @Published private(set) var diagnosticsVersion = 0
    private var currentDiagnostics: RustlynDiagnostics?
    private var diagnosticsBuffer: ObjectIdentifier?
    private let diagnosticsWork = DispatchQueue(label: "pilot.diagnostics", qos: .utility)
    private let diagnosticsGeneration = AtomicCounter()

    func diagnostics(for buffer: TextBuffer) -> [RustlynDiagnostic] {
        let own = diagnosticsBuffer == ObjectIdentifier(buffer) ? currentDiagnostics?.items ?? [] : []
        let pair = pairDiagnosticsBuffer == ObjectIdentifier(buffer) ? pairDiagnostics : []
        return own + pair
    }

    /// Ошибки и предупреждения открытого файла — для строки состояния.
    var problemCounts: (errors: Int, warnings: Int)? {
        guard let buffer else { return nil }
        let pair = pairDiagnosticsBuffer == ObjectIdentifier(buffer) ? pairDiagnostics : []
        let own = diagnosticsBuffer == ObjectIdentifier(buffer) ? currentDiagnostics : nil
        guard own != nil || !pair.isEmpty else { return nil }
        return ((own?.errors ?? 0) + pair.filter { $0.severity == .error }.count,
                (own?.warnings ?? 0) + pair.filter { $0.severity == .warning }.count)
    }

    /// Замечания сверки с парой готовы — редактор перерисует волны.
    func pairDiagnosticsChanged() { diagnosticsVersion += 1 }

    /// Проверка файла — после паузы в наборе, в фоне, по снимку текста.
    /// Ответ по устаревшему снимку выбрасывается: после него была правка,
    /// и она уже заказала свою проверку.
    private func scheduleDiagnostics(delay: Double = 0.6) {
        // Сверка с парой — для любого файла: датаграммы, зеркала.
        schedulePairChecks(delay: delay)
        guard let buffer, Rustlyn.understands(buffer.url), !buffer.isReadOnly,
              let rustlyn = rustlyn else {
            if currentDiagnostics != nil {
                currentDiagnostics = nil
                diagnosticsBuffer = nil
                diagnosticsVersion += 1
            }
            return
        }
        let generation = diagnosticsGeneration.bump()
        let counter = diagnosticsGeneration
        let url = buffer.url
        let snapshot = buffer.model.snapshot()
        let id = ObjectIdentifier(buffer)
        diagnosticsWork.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard counter.isCurrent(generation) else { return }
            let found = rustlyn.diagnostics(url, text: snapshot.text)
            Task { @MainActor in
                guard let self, counter.isCurrent(generation), let buffer = self.buffer,
                      ObjectIdentifier(buffer) == id, buffer.model.version == snapshot.version else { return }
                self.currentDiagnostics = found
                self.diagnosticsBuffer = id
                self.diagnosticsVersion += 1
            }
            // Подсказки и счётчики — следом, тем же снимком: ошибки не ждут
            // поиска по проекту, который нужен счётчикам.
            guard counter.isCurrent(generation) else { return }
            let hints = rustlyn.inlayHints(url, text: snapshot.text,
                                           range: NSRange(location: 0, length: snapshot.units.count))
            guard counter.isCurrent(generation) else { return }
            let lenses = rustlyn.codeLens(url, text: snapshot.text)
            Task { @MainActor in
                guard let self, counter.isCurrent(generation), let buffer = self.buffer,
                      ObjectIdentifier(buffer) == id, buffer.model.version == snapshot.version else { return }
                // Проект ещё не скомпилирован — прежние остаются: они
                // сдвигаются вместе с правками и лучше, чем ничего.
                if hints == nil, lenses == nil, self.insightsBuffer == id { return }
                self.currentInsights = RustlynInsights(hints: hints ?? [], lenses: lenses ?? [])
                self.insightsBuffer = id
                self.insightsVersion += 1
            }
        }
    }

    // MARK: - Подсказки в строках и счётчики использований

    /// Как в Rider: имена параметров и выведенные типы прямо в строке,
    /// «3 использования» над объявлением.
    @Published private(set) var insightsVersion = 0
    private var currentInsights: RustlynInsights?
    private var insightsBuffer: ObjectIdentifier?

    private static let inlayHintsKey = "pilot.inlayHints"
    private static let codeLensKey = "pilot.codeLens"
    @Published var showsInlayHints = UserDefaults.standard.object(forKey: Workspace.inlayHintsKey) as? Bool ?? true {
        didSet {
            guard showsInlayHints != oldValue else { return }
            UserDefaults.standard.set(showsInlayHints, forKey: Self.inlayHintsKey)
            for other in ProjectWindows.shared.workspaces { other.showsInlayHints = showsInlayHints }
        }
    }
    @Published var showsCodeLens = UserDefaults.standard.object(forKey: Workspace.codeLensKey) as? Bool ?? true {
        didSet {
            guard showsCodeLens != oldValue else { return }
            UserDefaults.standard.set(showsCodeLens, forKey: Self.codeLensKey)
            for other in ProjectWindows.shared.workspaces { other.showsCodeLens = showsCodeLens }
        }
    }

    func insights(for buffer: TextBuffer) -> RustlynInsights {
        guard insightsBuffer == ObjectIdentifier(buffer), let found = currentInsights else { return RustlynInsights() }
        return RustlynInsights(hints: showsInlayHints ? found.hints : [],
                               lenses: showsCodeLens ? found.lenses : [])
    }

    /// F2 и ⇧F2 — к следующей ошибке файла и к предыдущей, по кругу. Пока
    /// есть ошибки, предупреждения пропускаются.
    func jumpToProblem(_ direction: Int) {
        guard let buffer else { NSSound.beep(); return }
        let items = diagnostics(for: buffer).filter { $0.severity != .hidden && $0.severity != .info }
            .sorted { $0.range.location < $1.range.location }
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        let pool = items.contains { $0.severity == .error } ? items.filter { $0.severity == .error } : items
        let caret = caretOffset
        let target = direction > 0
            ? pool.first(where: { $0.range.location > caret }) ?? pool.first
            : pool.last(where: { $0.range.location < caret }) ?? pool.last
        guard let target else { return }
        let model = buffer.model
        let end = min(NSMaxRange(target.range), model.units.count)
        requestReveal(LSPRange(start: model.position(at: min(target.range.location, model.units.count)),
                               end: model.position(at: end)))
        showNotice(target.message)
    }

    /// Документация имени в позиции — ⌃J и наведение мышью.
    func documentation(at offset: Int) async -> RustlynDocumentation? {
        guard let buffer, Rustlyn.understands(buffer.url), let rustlyn = rustlyn,
              buffer.document.decompiled == nil else { return nil }
        let url = buffer.url
        let text: String? = buffer.model.settledFile == nil ? buffer.model.text : nil
        return await Task.detached(priority: .userInitiated) {
            rustlyn.documentation(url, offset: offset, text: text)
        }.value
    }

    /// Перегрузки вызова, в скобках которого курсор.
    func signatures(at offset: Int) async -> RustlynSignatures? {
        guard let buffer, Rustlyn.understands(buffer.url), let rustlyn = rustlyn,
              buffer.document.decompiled == nil else { return nil }
        let url = buffer.url
        let text: String? = buffer.model.settledFile == nil ? buffer.model.text : nil
        return await Task.detached(priority: .userInitiated) {
            rustlyn.signatures(url, offset: offset, text: text)
        }.value
    }

    /// Шаги ⌃W по синтаксическому дереву. Только разбор, без компиляции:
    /// миллисекунды и на большом файле. `nil` — не C#, шаги по тексту.
    func selectionSteps(around selection: NSRange) -> [NSRange]? {
        guard let buffer, Rustlyn.understands(buffer.url), let rustlyn = rustlyn else { return nil }
        return rustlyn.selectionRanges(buffer.url, selection: selection, text: buffer.model.text)
    }

    /// ⇧F6 — имя под курсором и все его использования по проекту.
    ///
    /// Что менять, считает Rustlyn, как Roslyn: у метода — вместе со всем
    /// семейством (что он переопределяет или реализует, и все остальные
    /// переопределения и реализации), у типа — с конструкторами и файлом.
    /// Переименовать один `override` значило бы сломать программу.
    func renameSymbol() {
        guard let buffer, !buffer.isReadOnly else { NSSound.beep(); return }
        guard Rustlyn.understands(buffer.url), let rustlyn = rustlyn else {
            showNotice(L("Переименование пока только для C#"))
            return
        }
        guard compiler.isReady else {
            showNotice(L("Rustlyn ещё компилирует проект — переименование будет через несколько секунд"))
            return
        }
        let url = buffer.url
        let offset = caretOffset
        let text = buffer.model.text
        // Индекс второй половины пары — пока компилятор ищет использования:
        // окну переименования надо знать, есть ли у имени двойник.
        if partner != nil { Task { [weak self] in _ = await self?.partnerIndex() } }
        referenceQueue.async { [weak self] in
            let info = rustlyn.prepareRename(url, offset: offset, text: text)
            let reason = info == nil ? rustlyn.lastError : ""
            Task { @MainActor in
                guard let self else { return }
                guard let info else {
                    self.showNotice(reason.isEmpty ? "Rustlyn не смог разобрать, что под курсором" : reason)
                    return
                }
                if let refused = info.refused {
                    self.showNotice("«\(info.text)» не переименовать: \(refused)")
                    return
                }
                self.confirmRename(info, url: url, offset: offset, text: text)
            }
        }
    }

    private func confirmRename(_ info: RustlynRenameInfo, url: URL, offset: Int, text: String) {
        let old = info.text
        let alert = NSAlert()
        alert.messageText = L("Переименовать «\(old)»")
        alert.informativeText = info.description
        let width: CGFloat = 320
        let field = NSTextField(string: old)
        var boxes: [NSButton] = []
        let fileBox = info.isType ? NSButton(checkboxWithTitle: L("И файл — вслед за типом"), target: nil, action: nil) : nil
        fileBox?.state = .on
        let overloadsBox = info.isMethod ? NSButton(checkboxWithTitle: L("Все перегрузки"), target: nil, action: nil) : nil
        let textBox = NSButton(checkboxWithTitle: L("И в комментариях и строках"), target: nil, action: nil)
        // Двойник во второй половине пары: датаграмма, модель конфига.
        let pairRename = partnerRenameOption(for: old)
        let pairBox = pairRename?.checkbox.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        pairBox?.state = .on
        if let pairRename { alert.informativeText += "\n\n" + pairRename.note }
        boxes = [fileBox, overloadsBox, textBox, pairBox].compactMap { $0 }
        // Рамками, а не NSStackView: у стека поле ужималось до своей
        // «естественной» ширины — в один символ.
        let rowHeight: CGFloat = 22, gap: CGFloat = 8
        let height = 24 + CGFloat(boxes.count) * (rowHeight + gap)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        field.frame = NSRect(x: 0, y: height - 24, width: width, height: 24)
        accessory.addSubview(field)
        for (index, box) in boxes.enumerated() {
            box.frame = NSRect(x: 0, y: height - 24 - CGFloat(index + 1) * (rowHeight + gap),
                               width: width, height: rowHeight)
            accessory.addSubview(box)
        }
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("Переименовать"))
        alert.addButton(withTitle: L("Отмена"))
        alert.window.initialFirstResponder = field
        // Имя выделено целиком: набранное сразу его заменяет.
        DispatchQueue.main.async { field.currentEditor()?.selectAll(nil) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let new = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard new != old else { return }
        if let problem = Rename.problem(with: new) {
            let warning = NSAlert()
            warning.messageText = L("Так назвать нельзя")
            warning.informativeText = problem
            warning.runModal()
            return
        }
        var options: RustlynRenameOptions = []
        if fileBox?.state == .on { options.insert(.file) }
        if overloadsBox?.state == .on { options.insert(.overloads) }
        if textBox.state == .on { options.formUnion([.inComments, .inStrings]) }

        guard let rustlyn else { return }
        showNotice("Переименование «\(old)»…")
        referenceQueue.async { [weak self] in
            let result = rustlyn.rename(url, offset: offset, to: new, text: text, options: options)
            let reason = result == nil ? rustlyn.lastError : ""
            Task { @MainActor in
                guard let self else { return }
                guard let result else {
                    self.showNotice("Не удалось переименовать: " + (reason.isEmpty ? "Rustlyn отказал" : reason))
                    return
                }
                if let refused = result.refused {
                    self.showNotice("Не переименовать: \(refused)")
                    return
                }
                guard !result.edits.isEmpty else {
                    self.showNotice("«\(old)»: менять нечего")
                    return
                }
                guard self.acceptConflicts(result.conflicts.filter { !$0.resolved }, old: old, new: new) else { return }
                self.applyRename(result, old: old, new: new)
                if pairBox?.state == .on { self.renameInPartner(old: old, new: new) }
            }
        }
    }

    /// Новое имя с чем-то столкнулось — показать, с чем, и спросить.
    private func acceptConflicts(_ conflicts: [RustlynRenameConflict], old: String, new: String) -> Bool {
        guard !conflicts.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "«\(new)» с чем-то столкнётся: "
            + Theme.count(conflicts.count, "конфликт", "конфликта", "конфликтов")
        let shown = conflicts.prefix(5).map { "\($0.url.lastPathComponent): \($0.message)" }
        alert.informativeText = shown.joined(separator: "\n")
            + (conflicts.count > shown.count ? "\n…и ещё \(conflicts.count - shown.count)" : "")
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Всё равно переименовать")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Правки — открытым вкладкам через их историю ⌘Z, остальным файлам —
    /// на диск. Вкладки, в которых не было несохранённого, сохраняются:
    /// иначе компилятор видел бы половину переименования.
    ///
    /// Перед заменой каждое место сверяется со старым именем: для других
    /// файлов Rustlyn считает правки в тексте последней компиляции, и
    /// открытая вкладка с несохранённым могла от него уйти. Такой файл
    /// пропускается целиком и называется в итоге — лучше недоделать, чем
    /// вписать имя посреди чужого слова.
    func applyRename(_ result: RustlynRenameResult, old: String, new: String) {
        var byFile: [URL: [(range: NSRange, text: String)]] = [:]
        for edit in result.edits { byFile[edit.url.standardizedFileURL, default: []].append((edit.range, edit.text)) }
        var skipped: Set<URL> = []
        let actionName = L("Переименование «\(old)»")

        func fits(_ edits: [(range: NSRange, text: String)], in text: NSString) -> Bool {
            edits.allSatisfy { NSMaxRange($0.range) <= text.length
                && Rename.isOccurrence(text.substring(with: $0.range), of: old) }
        }

        for (url, edits) in byFile {
            if let tab = tab(for: url, revision: nil) {
                guard !tab.isReadOnly, fits(edits, in: tab.storage.string as NSString) else {
                    skipped.insert(url)
                    continue
                }
                let wasClean = !tab.isDirty
                tab.applyEdits(edits, actionName: actionName)
                if wasClean { save(tab) }
                continue
            }
            do {
                let document = try LoadedDocument.load(url: url)
                guard fits(edits, in: document.text as NSString),
                      let updated = Rename.apply(edits, to: document.text) else {
                    skipped.insert(url)
                    continue
                }
                var data = updated.data(using: document.encoding) ?? Data(updated.utf8)
                if let head = try? FileHandle(forReadingFrom: url).read(upToCount: 3), head == Rename.utf8BOM {
                    data = Rename.utf8BOM + data
                }
                try data.write(to: url, options: .atomic)
                reindexAfterSave(url)
            } catch {
                skipped.insert(url)
            }
        }
        for move in result.files where !skipped.contains(move.from.standardizedFileURL) {
            renameFile(move.from, to: move.to)
        }
        scheduleCompile()
        let applied = result.edits.count - byFile.filter { skipped.contains($0.key) }
            .reduce(0) { $0 + $1.value.count }
        let occurrences = Theme.count(applied, "вхождение", "вхождения", "вхождений")
        let inFiles = Theme.count(byFile.count - skipped.count, "файле", "файлах", "файлах")
        let summary = L("«\(old)» → «\(new)»: \(occurrences) в \(inFiles)")
        let skippedList = skipped.map(\.lastPathComponent).sorted().joined(separator: ", ")
        showNotice(skipped.isEmpty ? summary
                   : L("\(summary). Пропущены — текст ушёл от компиляции: \(skippedList)"))
    }

    /// Файл — вслед за классом, и его `.meta` рядом: иначе Unity потеряет
    /// GUID скрипта, и сцены — ссылки на него.
    private func renameFile(_ from: URL, to: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: to.path) else {
            showNotice(L("Файл \(to.lastPathComponent) уже есть — имя файла осталось прежним"))
            return
        }
        let openTab = tab(for: from, revision: nil)
        if let openTab, openTab.isDirty, !save(openTab) { return }
        do {
            try fm.moveItem(at: from, to: to)
            let meta = from.appendingPathExtension("meta")
            if fm.fileExists(atPath: meta.path) {
                try fm.moveItem(at: meta, to: to.appendingPathExtension("meta"))
            }
        } catch {
            showNotice(L("Не удалось переименовать файл: \(error.localizedDescription)"))
            return
        }
        if let openTab {
            let wasActive = openTab === buffer
            closeTabs([openTab])
            if wasActive { open(file: to) }
        }
    }

    // MARK: - Запуск

    /// ▶ и ⌃R. Как в Rider: сначала несохранённое — на диск, иначе
    /// `dotnet run` собрал бы то, что было до правки.
    func runSelected() {
        guard root != nil, run.selected != nil else { return }
        saveAll()
        run.run()
    }

    /// Окно коммита этого проекта; уже открыто — выходит вперёд.
    func openCommitWindow() {
        guard let root, git.repository != nil else {
            showNotice(L("Проект не в git-репозитории"))
            return
        }
        ProjectWindows.shared.openWindow?(id: CommitWindow.sceneID, value: root.path)
    }

    /// Окно NuGet этого проекта; уже открыто — выходит вперёд.
    func openNuGet() {
        guard let root else { return }
        ProjectWindows.shared.openWindow?(id: NuGetWindow.sceneID, value: root.path)
    }

    /// `.pilot/run.json` в редакторе. Нет файла — он появляется с тем, что
    /// Pilot нашёл сам: поправить команду проще, чем вспомнить формат.
    func editRunConfiguration() {
        guard let root else { return }
        let url = root.appendingPathComponent(RunTargets.configPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try RunTargets.configTemplate(for: run.targets).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                showNotice("Не удалось создать \(RunTargets.configPath): \(error.localizedDescription)")
                return
            }
        }
        open(file: url)
    }

    // MARK: - Сохранение

    func save() {
        guard let buffer else { return }
        save(buffer)
    }

    func saveAll() {
        for buffer in tabs where buffer.isDirty { save(buffer) }
    }

    @discardableResult
    private func save(_ buffer: TextBuffer) -> Bool {
        // Каким файл был на диске — до записи: первая версия в истории.
        let before = historyPath(for: buffer).flatMap { _ in try? String(contentsOf: buffer.url, encoding: buffer.document.encoding) }
        do {
            try buffer.save()
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Не удалось сохранить «\(buffer.url.lastPathComponent)»")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }
        recordSaved(buffer, before: before)
        lsp.documentSaved(buffer.url)
        debug.fileSaved(buffer.url)
        settleWithRustlyn(buffer)
        reindexAfterSave(buffer.url)
        extensionFileChanged(buffer.url)
        git.refresh()
        if buffer === self.buffer { git.documentEdited(buffer.document) }
        return true
    }

    /// Перед сменой проекта и выходом. true — можно продолжать: всё
    /// сохранено или правки решили выбросить.
    func confirmUnsavedChanges() -> Bool {
        confirmUnsavedChanges(in: tabs)
    }

    /// То же перед закрытием вкладок — только про те, что закрываются.
    private func confirmUnsavedChanges(in buffers: [TextBuffer]) -> Bool {
        let dirty = buffers.filter(\.isDirty).sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        guard !dirty.isEmpty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if dirty.count == 1 {
            alert.messageText = L("Сохранить изменения в «\(dirty[0].url.lastPathComponent)»?")
        } else {
            let inFiles = Theme.count(dirty.count, "файле", "файлах", "файлах")
            alert.messageText = L("Сохранить изменения в \(inFiles)?")
            alert.informativeText = dirty.prefix(8).map(\.url.lastPathComponent).joined(separator: ", ")
                + (dirty.count > 8 ? "…" : "")
        }
        alert.informativeText += (alert.informativeText.isEmpty ? "" : "\n\n") + L("Если не сохранить, правки пропадут.")
        alert.addButton(withTitle: dirty.count == 1 ? L("Сохранить") : L("Сохранить все"))
        alert.addButton(withTitle: L("Отмена"))
        alert.addButton(withTitle: L("Не сохранять"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return dirty.allSatisfy { save($0) }
        case .alertThirdButtonReturn:
            // Буферы с правками выбросит тот, кто спрашивал: закрытие вкладок
            // или смена проекта. При выходе — вместе с процессом.
            return true
        default:
            return false
        }
    }

    // MARK: - Автодополнение

    /// Варианты в позиции курсора: для C# — от Rustlyn, для остального —
    /// от языкового сервера, а если их нет (или они не ответили) — слова
    /// файла и ключевые слова языка.
    /// ⌥⌘G — граф «откуда берётся значение» для поля под курсором.
    func showValueGraph(at offset: Int) {
        guard let buffer, Rustlyn.understands(buffer.url), let rustlyn else {
            showNotice(L("Граф значения — для C#, когда Rustlyn скомпилировал проект"))
            return
        }
        let url = buffer.url
        let text: String? = buffer.isDirty ? buffer.model.text : nil
        referenceQueue.async {
            let definition = rustlyn.definition(url, offset: offset, text: text)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let target = definition.targets.first else {
                    self.showNotice(L("Поставьте курсор на поле, свойство или компонент — граф покажет, откуда они берутся"))
                    return
                }
                if [.field, .property].contains(target.kind) {
                    let value = ValueGraph.Declaration(url: target.url, line: target.line, character: target.character,
                                                       length: target.length, name: target.name)
                    ValueGraphWindows.show(ValueGraph(workspace: self, value: value))
                } else if [.struct, .class].contains(target.kind) {
                    // Тип — как компонент: где его ставят в стэш и где убирают.
                    ValueGraphWindows.show(ValueGraph(workspace: self, component: target.shortName))
                } else {
                    self.showNotice(L("Поставьте курсор на поле, свойство или компонент — граф покажет, откуда они берутся"))
                }
            }
        }
    }

    /// Тексты открытых вкладок: в них могут быть несохранённые правки,
    /// а графу значения нужен тот же текст, что у компилятора.
    func openTexts() -> [URL: String] {
        var texts: [URL: String] = [:]
        for tab in tabs where !tab.isReadOnly && tab.isDirty { texts[tab.url] = tab.model.text }
        return texts
    }

    /// Подсказка Copilot у курсора — серым текстом в редакторе.
    func copilotSuggestion(at offset: Int) async -> CopilotSuggestion? {
        guard let buffer, !buffer.isReadOnly else { return nil }
        let unit = buffer.indentUnit
        return await CopilotService.shared.suggestion(
            url: buffer.url, position: buffer.model.position(at: offset),
            tabSize: unit == "\t" ? 4 : max(1, unit.count), insertSpaces: unit != "\t")
    }

    func completions(at offset: Int, trigger: String?, retrigger: Bool) async -> CompletionList? {
        guard let buffer else { return nil }
        let url = buffer.url
        if Rustlyn.understands(url), let rustlyn = rustlyn, buffer.document.decompiled == nil {
            // Текст — буфера, а не диска: дополнение спрашивают, пока
            // набирают. Rustlyn связывает правленый метод поверх последней
            // компиляции, поэтому на это хватает миллисекунд.
            let model = buffer.model
            let text: String? = model.settledFile == nil ? model.text : nil
            let found = await Task.detached(priority: .userInitiated) {
                rustlyn.completions(url, offset: offset, text: text)
            }.value
            if let found, !found.items.isEmpty { return found.list }
        } else if lsp.providesCompletion(for: url) {
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

    static func saveAssemblies(_ index: AssemblyIndex, root: URL, builtFrom: Date) {
        guard let url = fileURL(root: root, extension: "assemblies") else { return }
        try? index.serialized().data(using: .utf8)?.write(to: url, options: .atomic)
        stamp(url, builtFrom)
    }

    static func loadAssemblies(root: URL) -> (index: AssemblyIndex, builtAt: Date?)? {
        guard let url = fileURL(root: root, extension: "assemblies"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let index = AssemblyIndex.deserialize(text) else { return nil }
        return (index, modified(url))
    }

    /// Индекс GUID Unity — по корню Unity-проекта, а не открытой папки:
    /// это один и тот же индекс, откуда бы проект ни открыли.
    ///
    /// `builtFrom` — когда начали читать файлы, по которым он собран: это
    /// время ставится файлу кэша, и следующий запуск перечитывает только то,
    /// что менялось после него (`builtAt`).
    static func saveAssets(_ index: UnityAssetIndex, root: URL, builtFrom: Date) {
        guard let url = fileURL(root: root, extension: "unity") else { return }
        try? index.serialized().data(using: .utf8)?.write(to: url, options: .atomic)
        stamp(url, builtFrom)
    }

    static func loadAssets(root: URL) -> (index: UnityAssetIndex, builtAt: Date?)? {
        guard let url = fileURL(root: root, extension: "unity"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let index = UnityAssetIndex.deserialize(text) else { return nil }
        return (index, modified(url))
    }

    /// Файл кэша помечен временем начала сборки, а не записи: что поменялось,
    /// пока шла сборка, могло в неё не попасть, и в следующий раз его надо
    /// перечитать.
    private static func stamp(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func saveSymbols(_ index: SymbolIndex, root: URL, builtFrom: Date) {
        guard let url = fileURL(root: root, extension: "symbols") else { return }
        try? index.serialized().data(using: .utf8)?.write(to: url, options: .atomic)
        stamp(url, builtFrom)
    }

    static func loadSymbols(root: URL) -> (index: SymbolIndex, builtAt: Date?)? {
        guard let url = fileURL(root: root, extension: "symbols"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let index = SymbolIndex.deserialize(text, root: root) else { return nil }
        return (index, modified(url))
    }
}
