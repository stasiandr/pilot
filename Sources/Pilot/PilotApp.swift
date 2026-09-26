import SwiftUI
import AppKit

@main
enum PilotMain {
    static func main() {
        if LaunchForwarding.forward(OpenRequest.launch) {
            exit(0)
        }
        // AppKit принимает пути из командной строки за документы и шлёт их
        // ещё раз, как из Finder, — а `File.cs:12:5` от Unity такого файла
        // нет, и вылезало окно ошибки. Аргументы Pilot разбирает сам.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        LanguageStore.applySaved()
        PilotApp.main()
    }
}

struct PilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Проект окна, которое впереди: у каждого окна свой, и меню работает
    /// с тем, что перед глазами.
    @FocusedObject private var focused: Workspace?
    /// Сочетания клавиш меню — свои или по умолчанию; меню перестраивается,
    /// как только их поменяли в настройках.
    @StateObject private var keys = KeymapStore.shared
    /// Язык интерфейса: сменили в настройках — меню собирается заново,
    /// а окно перестраивается целиком (`.id`), чтобы строки сменились везде.
    @StateObject private var language = LanguageStore.shared
    @AppStorage("pilot.showsInspector") private var showsInspector = true
    @AppStorage(EditorChrome.key) private var chrome = EditorChrome.regular

    /// Когда впереди нет окна проекта (настройки), пункты меню выключены,
    /// но им всё равно нужно у кого спрашивать доступность. Этот воркспейс
    /// ни к какому окну не привязан, и проект в нём не открывается.
    @MainActor private static let idle = Workspace()
    private var workspace: Workspace { focused ?? Self.idle }
    private var noProjectWindow: Bool { focused == nil }

    init() {
        // `Pilot --value-graph Файл.cs:строка:столбец` — граф значения без
        // окна: построить, напечатать, выйти (см. HeadlessGraph).
        if HeadlessGraph.isRequested {
            exit(MainActor.assumeIsolated { HeadlessGraph.run() })
        }
    }

    /// Пара проектов: например, клиент и сервер одного продукта. Всё, что ходит между ними.
    @CommandsBuilder
    private var pairCommands: some Commands {
        CommandMenu("Пара") {
            let label = workspace.partnerLabel
            let noPair = label == nil
            Button(label.map { "Открыть \($0)" } ?? "Парный проект") { workspace.openPartner() }
                .keyboardShortcut(keys.keyboardShortcut(.openPartner))
                .disabled(noPair)
            Button("Двойник в \(label ?? "паре")") { workspace.goToCounterpart() }
                .keyboardShortcut(keys.keyboardShortcut(.counterpart))
                .disabled(noPair)
            Divider()
            // Эти два — по правилам расширения проекта: без него их нет.
            Button("Сверка датаграмм…") { workspace.openPalette(mode: .contract) }
                .keyboardShortcut(keys.keyboardShortcut(.datagramContract))
                .disabled(noPair || workspace.rules.datagrams == nil)
            Button("Расхождения зеркал…") { workspace.openPalette(mode: .mirrors) }
                .keyboardShortcut(keys.keyboardShortcut(.mirrorDrift))
                .disabled(noPair || workspace.rules.pair.mirrors.isEmpty)
            Toggle("Искать и в \(label ?? "паре")", isOn: Binding(get: { workspace.searchIncludesPair },
                                                               set: { workspace.searchIncludesPair = $0 }))
                .keyboardShortcut(keys.keyboardShortcut(.pairSearch))
                .disabled(noPair)
            Toggle("Открывать пару вместе", isOn: Binding(get: { ProjectWindows.shared.pairOpensTogether },
                                                         set: { ProjectWindows.shared.pairOpensTogether = $0 }))
            Divider()
            Button("Связать с проектом…") { workspace.linkPartner() }
                .disabled(workspace.root == nil)
            Button("Разорвать пару") { workspace.unlinkPartner() }
                .disabled(noPair)
        }
    }

    /// Команда редактора — первому ответчику, тексту, если фокус в нём.
    private static func editor(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    var body: some Scene {
        // Окон несколько, в каждом свой проект: клиент и сервер одного продукта
        // открыты рядом. Куда что открывать, решает ProjectWindows.
        WindowGroup("Pilot", id: ProjectWindows.sceneID) {
            ProjectWindow()
        }
        // Заголовок рисуем сами — с веткой git, как в Xcode.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("Проверить обновления…")) { Updater.shared.checkNow() }
            }
            // Не SidebarCommands: штатный пункт шлёт AppKit'овский toggleSidebar:,
            // и на раскрытии SwiftUI сам же схлопывает панель обратно — она
            // появлялась рывком. Через настройку RootView ведёт её с анимацией.
            CommandGroup(replacing: .sidebar) {
                Button(workspace.showsSidebar ? L("Скрыть навигатор") : L("Показать навигатор")) {
                    workspace.showsSidebar.toggle()
                }
                .keyboardShortcut(keys.keyboardShortcut(.toggleSidebar))
                .disabled(workspace.root == nil)
                Button(L("Показать файл в дереве")) {
                    workspace.showsSidebar = true
                    workspace.revealInTree()
                }
                .keyboardShortcut(keys.keyboardShortcut(.revealInTree))
                .disabled(workspace.openFilePath == nil)
                // Как Compact Mode в Rider: над редактором остаётся больше кода.
                Picker(L("Панель над редактором"), selection: $chrome) {
                    ForEach(EditorChrome.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Новое окно")) { ProjectWindows.shared.openEmptyWindow() }
                    .keyboardShortcut(keys.keyboardShortcut(.newWindow))
                // Из окна с проектом папка откроется в новом окне рядом,
                // со стартового экрана — в нём же.
                Button(L("Открыть папку…")) { ProjectWindows.shared.promptForFolder() }
                    .keyboardShortcut(keys.keyboardShortcut(.openFolder))
                Menu(L("Открыть недавний")) {
                    ForEach(workspace.recentRoots, id: \.path) { url in
                        Button("\(url.lastPathComponent) — \((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)") {
                            ProjectWindows.shared.open(root: url, from: focused)
                        }
                    }
                }
                .disabled(workspace.recentRoots.isEmpty)
                Button(L("Закрыть проект")) { workspace.closeProject() }
                    .keyboardShortcut(keys.keyboardShortcut(.closeProject))
                    .disabled(workspace.root == nil)
            }
            CommandGroup(replacing: .saveItem) {
                // ⌘W закрывает вкладку, а не окно — как в Xcode и браузерах.
                Button(L("Закрыть вкладку")) { workspace.closeActiveTab() }
                    .keyboardShortcut(keys.keyboardShortcut(.closeTab))
                    .disabled(workspace.buffer == nil && workspace.loadError == nil)
                Button(L("Закрыть другие вкладки")) { workspace.closeOtherTabs() }
                    .keyboardShortcut(keys.keyboardShortcut(.closeOtherTabs))
                    .disabled(workspace.buffer == nil || workspace.tabs.count < 2)
                Divider()
                Button(L("Сохранить")) { workspace.save() }
                    .keyboardShortcut(keys.keyboardShortcut(.save))
                    .disabled(!workspace.isCurrentDirty)
                Button(L("Сохранить все")) { workspace.saveAll() }
                    .keyboardShortcut(keys.keyboardShortcut(.saveAll))
                    .disabled(workspace.unsavedCount == 0)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                // Уходит первому ответчику — тексту редактора, если фокус в нём.
                Button(L("Закомментировать строки")) {
                    NSApp.sendAction(#selector(CodeTextView.toggleLineComment(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(keys.keyboardShortcut(.toggleComment))
                Button(L("Показать варианты")) {
                    NSApp.sendAction(#selector(NSTextView.complete(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(keys.keyboardShortcut(.showCompletions))
                Divider()
                Button(L("Дублировать строку")) { Self.editor(#selector(CodeTextView.duplicateLines(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.duplicateLines))
                Button(L("Удалить строку")) { Self.editor(#selector(CodeTextView.deleteLines(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.deleteLines))
                Button(L("Строку выше")) { Self.editor(#selector(CodeTextView.moveLinesUp(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.moveLinesUp))
                Button(L("Строку ниже")) { Self.editor(#selector(CodeTextView.moveLinesDown(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.moveLinesDown))
                Button(L("Склеить строки")) { Self.editor(#selector(CodeTextView.joinLines(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.joinLines))
                Button(L("Заглавные ↔ строчные")) { Self.editor(#selector(CodeTextView.toggleCase(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.toggleCase))
                Button(L("Расширить выделение")) { Self.editor(#selector(CodeTextView.extendSelection(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.extendSelection))
                Button(L("Сузить выделение")) { Self.editor(#selector(CodeTextView.shrinkSelection(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.shrinkSelection))
                Divider()
                Button(L("Документация")) { Self.editor(#selector(CodeTextView.showQuickDocumentation(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.quickDocumentation))
                Button(L("Параметры вызова")) { Self.editor(#selector(CodeTextView.showParameterInfo(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.parameterInfo))
                Divider()
                Button(L("Свернуть")) { Self.editor(#selector(CodeTextView.foldAtCaret(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.fold))
                Button(L("Развернуть")) { Self.editor(#selector(CodeTextView.unfoldAtCaret(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.unfold))
                Button(L("Свернуть всё")) { Self.editor(#selector(CodeTextView.foldAll(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.foldAll))
                Button(L("Развернуть всё")) { Self.editor(#selector(CodeTextView.unfoldAll(_:))) }
                    .keyboardShortcut(keys.keyboardShortcut(.unfoldAll))
            }
            // Сама NSTextView ⌘F не ловит — ей нужен пункт меню, а в SwiftUI
            // его нет. Без .disabled: доступность пунктов SwiftUI обновляет
            // не сразу, и ⌘F после открытия файла мог остаться выключенным.
            // Без редактора запрос просто некому выполнить.
            CommandGroup(after: .textEditing) {
                Divider()
                Button(L("Найти…")) { workspace.find(.showFindInterface) }
                    .keyboardShortcut(keys.keyboardShortcut(.find))
                Button(L("Найти и заменить…")) { workspace.find(.showReplaceInterface) }
                    .keyboardShortcut(keys.keyboardShortcut(.findAndReplace))
                Button(L("Найти далее")) { workspace.find(.nextMatch) }
                    .keyboardShortcut(keys.keyboardShortcut(.findNext))
                Button(L("Найти ранее")) { workspace.find(.previousMatch) }
                    .keyboardShortcut(keys.keyboardShortcut(.findPrevious))
                Button(L("Искать выделенное")) { workspace.find(.setSearchString) }
                    .keyboardShortcut(keys.keyboardShortcut(.useSelectionForFind))
            }
            // Сочетания — как в Rider: F8 шаг, F7 внутрь, ⇧F8 наружу, F9 дальше.
            CommandMenu("Отладка") {
                Button("Начать отладку…") { workspace.debug.openTargetPicker() }
                    .keyboardShortcut(keys.keyboardShortcut(.debugStart))
                    .disabled(workspace.root == nil)
                if let target = workspace.debug.lastTarget {
                    Button("Ещё раз: \(target.title)") { workspace.debug.start(target) }
                        .disabled(workspace.root == nil)
                }
                Button("Остановить отладку") { workspace.debug.stop() }
                    .keyboardShortcut(keys.keyboardShortcut(.debugStop))
                    .disabled(!workspace.debug.isActive)
                Divider()
                Button("Продолжить") { workspace.debug.resume() }
                    .keyboardShortcut(keys.keyboardShortcut(.debugContinue))
                    .disabled(!workspace.debug.isPaused)
                Button("Приостановить") { workspace.debug.pause() }
                    .keyboardShortcut(keys.keyboardShortcut(.debugPause))
                    .disabled(workspace.debug.state != .running)
                Button("Шаг с обходом") { workspace.debug.step(.over) }
                    .keyboardShortcut(keys.keyboardShortcut(.stepOver))
                    .disabled(!workspace.debug.isPaused)
                Button("Шаг с заходом") { workspace.debug.step(.into) }
                    .keyboardShortcut(keys.keyboardShortcut(.stepInto))
                    .disabled(!workspace.debug.isPaused)
                Button("Шаг с выходом") { workspace.debug.step(.out) }
                    .keyboardShortcut(keys.keyboardShortcut(.stepOut))
                    .disabled(!workspace.debug.isPaused)
                Divider()
                Button("Точка останова") { workspace.toggleBreakpointAtCaret() }
                    .keyboardShortcut(keys.keyboardShortcut(.toggleBreakpoint))
                    .disabled(workspace.document.map { !DebugService.canBreak(in: $0.url) } ?? true)
                Button("Убрать все точки останова") { workspace.debug.removeAllBreakpoints() }
                    .keyboardShortcut(keys.keyboardShortcut(.removeAllBreakpoints))
                    .disabled(workspace.debug.breakpoints.isEmpty)
                Divider()
                Button(workspace.debug.isPanelVisible ? "Скрыть панель отладки" : "Показать панель отладки") {
                    workspace.debug.isPanelVisible.toggle()
                }
                .disabled(workspace.root == nil)
            }
            CommandGroup(after: .toolbar) {
                // Один поиск на всё; сочетания открывают его с разным
                // фильтром, а повторное нажатие фильтр переключает.
                Button(L("Найти везде…")) { workspace.openSearch(.everything, again: .files) }
                    .keyboardShortcut(keys.keyboardShortcut(.searchEverywhere))
                // Двойной Shift меню назначить не умеет — его ловит
                // DoubleShiftMonitor, а здесь он только подписан.
                Button(L("Найти тип…  ⇧⇧")) { workspace.openSearch(.everything, again: .types) }
                    .keyboardShortcut(keys.keyboardShortcut(.searchTypes))
                Button(L("Структура файла…")) { workspace.openPalette(mode: .outline) }
                    .keyboardShortcut(keys.keyboardShortcut(.fileStructure))
                Button(L("Символ в проекте…")) { workspace.openSearch(.symbols) }
                    .keyboardShortcut(keys.keyboardShortcut(.searchSymbols))
                Button(L("Найти в файлах…")) { workspace.openSearch(.text) }
                    .keyboardShortcut(keys.keyboardShortcut(.findInFiles))
                    .disabled(workspace.root == nil)
                Divider()
                Button(L("Следующее объявление")) { workspace.jumpToMember(1) }
                    .keyboardShortcut(keys.keyboardShortcut(.nextMember))
                Button(L("Предыдущее объявление")) { workspace.jumpToMember(-1) }
                    .keyboardShortcut(keys.keyboardShortcut(.previousMember))
                Button(L("Следующее вхождение")) { workspace.jumpToOccurrence(1) }
                    .keyboardShortcut(keys.keyboardShortcut(.nextOccurrence))
                Button(L("Предыдущее вхождение")) { workspace.jumpToOccurrence(-1) }
                    .keyboardShortcut(keys.keyboardShortcut(.previousOccurrence))
                Divider()
                Button(L("Изменённые файлы…")) { workspace.openPalette(mode: .changes) }
                    .keyboardShortcut(keys.keyboardShortcut(.changedFiles))
                    .disabled(workspace.git.repository == nil)
                Button(L("Следующее изменение")) { workspace.jumpToChange(1) }
                    .keyboardShortcut(keys.keyboardShortcut(.nextChange))
                Button(L("Предыдущее изменение")) { workspace.jumpToChange(-1) }
                    .keyboardShortcut(keys.keyboardShortcut(.previousChange))
                Button(L("Коммит…")) { workspace.openCommitWindow() }
                    .keyboardShortcut(keys.keyboardShortcut(.commit))
                    .disabled(workspace.git.repository == nil)
                Button(L("Локальная история…")) { workspace.showLocalHistory() }
                    .keyboardShortcut(keys.keyboardShortcut(.localHistory))
                    .disabled(workspace.document == nil)
                Divider()
                Button(L("Ревью мерж-реквестов")) { workspace.showReviews() }
                    .keyboardShortcut(keys.keyboardShortcut(.reviews))
                    .disabled(workspace.root == nil)
                Button(L("Комментировать строку…")) { workspace.commentOnCaretLine() }
                    .keyboardShortcut(keys.keyboardShortcut(.commentLine))
                    .disabled(!workspace.isReviewDocument)
                Button(L("Следующий тред")) { workspace.jumpToThread(1) }
                    .keyboardShortcut(keys.keyboardShortcut(.nextThread))
                    .disabled(!workspace.isReviewDocument)
                Button(L("Предыдущий тред")) { workspace.jumpToThread(-1) }
                    .keyboardShortcut(keys.keyboardShortcut(.previousThread))
                    .disabled(!workspace.isReviewDocument)
                Button(L("Следующий файл MR")) { workspace.openAdjacentReviewFile(1) }
                    .keyboardShortcut(keys.keyboardShortcut(.nextReviewFile))
                    .disabled(workspace.review.active == nil)
                Button(L("Предыдущий файл MR")) { workspace.openAdjacentReviewFile(-1) }
                    .keyboardShortcut(keys.keyboardShortcut(.previousReviewFile))
                    .disabled(workspace.review.active == nil)
                Divider()
                Button(L("Следующий конфликт")) { workspace.jumpToConflict(1) }
                    .keyboardShortcut(keys.keyboardShortcut(.nextConflict))
                    .disabled(workspace.conflicts.isEmpty)
                Button(L("Предыдущий конфликт")) { workspace.jumpToConflict(-1) }
                    .keyboardShortcut(keys.keyboardShortcut(.previousConflict))
                    .disabled(workspace.conflicts.isEmpty)
                Button(L("Принять текущее")) { workspace.acceptConflict(.current) }
                    .keyboardShortcut(keys.keyboardShortcut(.acceptCurrent))
                    .disabled(workspace.conflicts.isEmpty)
                Button(L("Принять входящее")) { workspace.acceptConflict(.incoming) }
                    .keyboardShortcut(keys.keyboardShortcut(.acceptIncoming))
                    .disabled(workspace.conflicts.isEmpty)
                Button(L("Принять оба")) { workspace.acceptConflict(.both) }
                    .keyboardShortcut(keys.keyboardShortcut(.acceptBoth))
                    .disabled(workspace.conflicts.isEmpty)
                Button(L("Отметить конфликт решённым")) { workspace.markConflictsResolved() }
                    .keyboardShortcut(keys.keyboardShortcut(.markResolved))
                    .disabled(!workspace.isConflictedFile || !workspace.conflicts.isEmpty)
                Divider()
                Button(L("Действия в контексте…")) { workspace.showContextActions() }
                    .keyboardShortcut(keys.keyboardShortcut(.contextActions))
                // C# — компилятор Rustlyn, а пока он компилирует проект —
                // быстрый навигатор по индексу объявлений.
                Button(L("Перейти к объявлению")) {
                    workspace.goToDefinition(at: workspace.caretOffset)
                }
                .keyboardShortcut(keys.keyboardShortcut(.goToDefinition))
                Button(L("Найти использования")) {
                    workspace.findReferences(at: workspace.caretOffset)
                }
                .keyboardShortcut(keys.keyboardShortcut(.findReferences))
                Button(L("Граф значения")) {
                    workspace.showValueGraph(at: workspace.caretOffset)
                }
                .keyboardShortcut(keys.keyboardShortcut(.valueGraph))
                .disabled(workspace.document == nil)
                // Иерархия вниз: считается по индексу объявлений.
                Button(L("Перейти к реализациям")) {
                    workspace.findImplementations(at: workspace.caretOffset)
                }
                .keyboardShortcut(keys.keyboardShortcut(.implementations))
                .disabled(workspace.document == nil || workspace.symbolIndex == nil)
                // Unity: ссылки на ассеты — это GUID, компилятор тут не нужен.
                Button(L("Где используется ассет")) { workspace.findAssetUsages() }
                    .keyboardShortcut(keys.keyboardShortcut(.assetUsages))
                    .disabled(!workspace.unity.isActive)
                Button(workspace.showsRenderedMarkdown ? L("Исходник Markdown") : L("Свёрстанный Markdown")) {
                    workspace.toggleMarkdownSource()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!workspace.isMarkdownDocument)
                Button(L("Ассет ↔ .meta")) { workspace.toggleMetaFile() }
                    .keyboardShortcut(keys.keyboardShortcut(.toggleMeta))
                    .disabled(!workspace.unity.isActive)
                Button(L("Консоль Unity")) { workspace.unityConsole.isVisible.toggle() }
                    .keyboardShortcut(keys.keyboardShortcut(.unityConsole))
                    .disabled(!workspace.unity.isActive)
                Button(showsInspector ? L("Скрыть инспектор") : L("Показать инспектор")) { showsInspector.toggle() }
                    .keyboardShortcut(keys.keyboardShortcut(.toggleInspector))
                    .disabled(workspace.document?.unityFile == nil)
                Divider()
                Button(L("Перейти к строке…")) { workspace.goToLine() }
                    .keyboardShortcut(keys.keyboardShortcut(.goToLine))
                    .disabled(workspace.document == nil)
                Button(L("Назад")) { workspace.goBack() }
                    .keyboardShortcut(keys.keyboardShortcut(.back))
                    .disabled(!workspace.canGoBack)
                Button(L("Вперёд")) { workspace.goForward() }
                    .keyboardShortcut(keys.keyboardShortcut(.forward))
                    .disabled(!workspace.canGoForward)
                Button(L("К последней правке")) { workspace.goToLastEdit() }
                    .keyboardShortcut(keys.keyboardShortcut(.lastEdit))
                Button(L("Недавние места…")) { workspace.openPalette(mode: .recentLocations) }
                    .keyboardShortcut(keys.keyboardShortcut(.recentLocations))
                    .disabled(workspace.root == nil)
                Divider()
                Button(L("Переименовать…")) { workspace.renameSymbol() }
                    .keyboardShortcut(keys.keyboardShortcut(.rename))
                Button(L("Следующая ошибка")) { workspace.jumpToProblem(1) }
                    .keyboardShortcut(keys.keyboardShortcut(.nextProblem))
                Button(L("Предыдущая ошибка")) { workspace.jumpToProblem(-1) }
                    .keyboardShortcut(keys.keyboardShortcut(.previousProblem))
                Divider()
                Button(L("Следующая вкладка")) { workspace.selectAdjacentTab(1) }
                    .keyboardShortcut(keys.keyboardShortcut(.nextTab))
                    .disabled(workspace.tabs.count < 2)
                Button(L("Предыдущая вкладка")) { workspace.selectAdjacentTab(-1) }
                    .keyboardShortcut(keys.keyboardShortcut(.previousTab))
                    .disabled(workspace.tabs.count < 2)
                // ⌃Tab ловит TabSwitchMonitor: с зажатым ⌃ он ходит дальше
                // по недавним, а меню так не умеет. Здесь — подпись и клик.
                Button(L("Недавняя вкладка  ⌃Tab")) { workspace.selectPreviousRecentTab() }
                    .keyboardShortcut(keys.keyboardShortcut(.recentTab))
                    .disabled(workspace.tabs.count < 2)
                Divider()
                Button(L("Крупнее")) { workspace.setFontSize(workspace.fontSize + 1) }
                    .keyboardShortcut(keys.keyboardShortcut(.fontBigger))
                Button(L("Мельче")) { workspace.setFontSize(workspace.fontSize - 1) }
                    .keyboardShortcut(keys.keyboardShortcut(.fontSmaller))
                Button(L("Исходный размер")) { workspace.setFontSize(Workspace.defaultFontSize) }
                    .keyboardShortcut(keys.keyboardShortcut(.fontReset))
                Divider()
                Toggle(L("Подсказки в строках"), isOn: Binding(get: { workspace.showsInlayHints },
                                                            set: { workspace.showsInlayHints = $0 }))
                    .disabled(noProjectWindow)
                Toggle(L("Счётчики использований"), isOn: Binding(get: { workspace.showsCodeLens },
                                                               set: { workspace.showsCodeLens = $0 }))
                    .disabled(noProjectWindow)
                Menu(L("Цветовая схема")) { ColorSchemeMenu() }
            }
            // Без .disabled, по той же причине, что и у ⌘F: цели находятся
            // фоном после открытия проекта, а доступность пунктов SwiftUI
            // обновляет не сразу — ⌃R остался бы выключенным. Без цели
            // команды просто ничего не делают.
            CommandMenu(L("Запуск")) {
                Button(workspace.run.selected.map { L("Запустить «\($0.name)»") } ?? L("Запустить")) {
                    workspace.runSelected()
                }
                .keyboardShortcut(keys.keyboardShortcut(.run))
                // Как ⌘F2 в Rider: останавливает то, что идёт, — отладку или запуск.
                Button(L("Остановить")) {
                    if workspace.debug.isActive { workspace.debug.stop() } else { workspace.run.stop() }
                }
                    .keyboardShortcut(keys.keyboardShortcut(.stop))
                Button(workspace.run.showsConsole ? L("Скрыть консоль") : L("Показать консоль")) {
                    if workspace.root != nil { workspace.run.showsConsole.toggle() }
                }
                .keyboardShortcut(keys.keyboardShortcut(.toggleConsole))
                Divider()
                ForEach(workspace.run.targets) { target in
                    Toggle(target.name, isOn: Binding(
                        get: { workspace.run.selected == target },
                        set: { if $0 { workspace.run.select(target) } }))
                }
                Divider()
                Button(L("Настроить запуск…")) { workspace.editRunConfiguration() }
                    .disabled(workspace.root == nil)
                Divider()
                Button(L("Пакеты NuGet…")) { workspace.openNuGet() }
                    .keyboardShortcut(keys.keyboardShortcut(.nuget))
                    .disabled(workspace.root == nil)
            }
        }
        .commands { pairCommands }
        // «Вид → Настроить панель инструментов…», как в Finder.
        .commands { ToolbarCommands() }
        // Окно NuGet — своё у каждого проекта: значение сцены — путь корня,
        // и повторная просьба выводит вперёд уже открытое.
        WindowGroup(id: NuGetWindow.sceneID, for: String.self) { $rootPath in
            NuGetWindow(rootPath: rootPath)
        }
        .defaultSize(width: 1000, height: 640)
        // Окно коммита — так же, своё у каждого проекта.
        WindowGroup(id: CommitWindow.sceneID, for: String.self) { $rootPath in
            CommitWindow(rootPath: rootPath)
        }
        .defaultSize(width: 1100, height: 700)
        // ⌘, — настройки: язык, оформление и сочетания клавиш.
        Settings {
            TabView {
                GeneralSettingsView(language: language)
                    .tabItem { Label(L("Общие"), systemImage: "gearshape") }
                WindowSettingsView()
                    .tabItem { Label(L("Окно"), systemImage: "macwindow") }
                ColorSchemeSettingsView()
                    .tabItem { Label(L("Оформление"), systemImage: "paintpalette") }
                KeymapSettingsView(store: keys, workspace: workspace)
                    .tabItem { Label(L("Сочетания клавиш"), systemImage: "keyboard") }
                CopilotSettingsView(copilot: CopilotService.shared)
                    .tabItem { Label("Copilot", systemImage: "sparkles") }
                ExtensionSettingsView()
                    .tabItem { Label(L("Расширения"), systemImage: "puzzlepiece.extension") }
            }
            .id(language.current)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder, `open -a Pilot File.cs` и `pilot://open?…` от второго процесса
    /// (LaunchForwarding) — в уже открытое окно. Apple Events ловим сами:
    /// `application(_:open:)` файлы не получает — их перехватывает SwiftUI.
    private func installOpenHandlers() {
        let events = NSAppleEventManager.shared()
        events.setEventHandler(self, andSelector: #selector(handleOpen(_:reply:)),
                               forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        events.setEventHandler(self, andSelector: #selector(handleOpen(_:reply:)),
                               forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// odoc несёт список файлов, GURL — одну строку с адресом. Строку
    /// в файл не приводим: AppKit сделал бы из `pilot://…` путь к файлу.
    @MainActor @objc private func handleOpen(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        if event.eventID == AEEventID(kAEGetURL) {
            receive(direct.stringValue.flatMap(URL.init(string:)).map { [$0] } ?? [])
            return
        }
        let items = direct.numberOfItems > 0 ? (1...direct.numberOfItems).compactMap { direct.atIndex($0) } : [direct]
        receive(items.compactMap(\.fileURLValue))
    }

    /// Файл — в окно его проекта; проекта, который ещё не открыт, — в
    /// пустое окно или новое. Пришло раньше первого окна — дождётся его.
    @MainActor
    private func receive(_ urls: [URL]) {
        let requests = urls.compactMap(OpenRequest.init(url:))
        requests.forEach { ProjectWindows.shared.open($0) }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ProjectWindows.shared.confirmUnsavedChanges() ? .terminateNow : .terminateCancel
    }

    /// Компиляция открытого проекта — на диск: следующий запуск прочтёт её
    /// за долю секунды вместо того, чтобы компилировать проект заново.
    /// Остальные кэши пишутся по мере построения и здесь не нужны.
    func applicationWillTerminate(_ notification: Notification) {
        Rustlyn.persist()
        // Запущенное кнопкой ▶ не переживает Pilot: сервер без окна,
        // держащий порт, потом пришлось бы искать через `lsof`.
        RunProcess.terminateAll()
        // «Перезапустить» после обновления — открыть уже новый бандл.
        MainActor.assumeIsolated { Updater.shared.relaunchIfRequested() }
    }

    /// `pkill Pilot` (так перезапускает `run.sh`) и выход системы шлют
    /// SIGTERM, а на него AppKit просто завершает процесс: до
    /// `applicationWillTerminate` дело не доходит, и компиляция не пишется —
    /// следующий запуск компилирует проект с нуля. Ловим сигнал сами.
    /// Несохранённые правки тут не спрашиваем: SIGTERM их и раньше не ждал.
    private var terminationSignal: DispatchSourceSignal?

    private func persistOnTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Rustlyn.persist()
            RunProcess.terminateAll()
            exit(0)
        }
        source.resume()
        terminationSignal = source
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Внешний вид — в тон цветовой схеме; ставим до появления окна,
        // чтобы не мигнуть хромом другого цвета.
        ThemeStore.shared.applyAppearance()
        // До конца запуска: событие, с которым Pilot запустили, приходит сразу после.
        installOpenHandlers()
        persistOnTermination()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Сервер Copilot — фоном, если его включили: окно его не ждёт.
        Task { @MainActor in CopilotService.shared.startIfEnabled() }
        // Новая версия на GitHub — плашкой над редактором (Updater).
        Task { @MainActor in Updater.shared.start() }
        // Таблицы видов и цветов Pilot повторяет за Rustlyn вручную — иначе
        // пришлось бы тянуть их через границу на каждый токен. Расхождение
        // на одно значение ничего не сломает и всё сдвинет: у полей появится
        // иконка метода, у строк цвет числа. Дешевле сказать это в лог при
        // запуске, чем искать потом.
        if !Rustlyn.buildsAgree() {
            NSLog("Pilot: таблицы видов разошлись с библиотекой Rustlyn — "
                  + "пересоберите её: ./build-rust.sh")
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
