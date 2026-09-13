import SwiftUI
import AppKit

@main
enum PilotMain {
    static func main() {
        // Тот же исполняемый файл работает и демоном языковых серверов —
        // тогда никакого интерфейса, только сокет (см. LSPDaemon).
        if let socket = LSPDaemon.socketArgument(CommandLine.arguments) {
            LSPDaemon.run(socketPath: socket)
        }
        PilotApp.main()
    }
}

struct PilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var workspace = Workspace()
    @AppStorage(Experimental.lspDaemonKey) private var lspDaemon = false
    @AppStorage("pilot.showsInspector") private var showsInspector = true
    @AppStorage("pilot.showsSidebar") private var showsSidebar = true

    var body: some Scene {
        Window("Pilot", id: "main") {
            RootView(workspace: workspace)
                .task {
                    // Путь из командной строки открываем после первого кадра:
                    // окно должно появиться мгновенно, а индексация идёт фоном.
                    // Без пути остаётся стартовый экран с выбором проекта.
                    delegate.attach(workspace)
                }
                .animation(.easeOut(duration: 0.14), value: workspace.isPaletteOpen)
        }
        // Заголовок рисуем сами — с веткой git, как в Xcode.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 720)
        .commands {
            // Не SidebarCommands: штатный пункт шлёт AppKit'овский toggleSidebar:,
            // и на раскрытии SwiftUI сам же схлопывает панель обратно — она
            // появлялась рывком. Через настройку RootView ведёт её с анимацией.
            CommandGroup(replacing: .sidebar) {
                Button(showsSidebar ? "Скрыть навигатор" : "Показать навигатор") { showsSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    .disabled(workspace.root == nil)
            }
            CommandGroup(after: .appSettings) {
                Menu("Экспериментальное") {
                    // Перезапуск — прямо в сеттере: onChange в меню команд
                    // срабатывает ненадёжно. @AppStorage пишет в UserDefaults
                    // синхронно, и LSPService уже видит новое значение.
                    Toggle("Держать языковые серверы между запусками", isOn: Binding(
                        get: { lspDaemon },
                        set: {
                            lspDaemon = $0
                            workspace.lsp.daemonSettingChanged(reopening: workspace.document)
                        }))
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Открыть папку…") { workspace.promptForFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Открыть недавний") {
                    ForEach(workspace.recentRoots, id: \.path) { url in
                        Button("\(url.lastPathComponent) — \((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)") {
                            workspace.open(root: url)
                        }
                    }
                }
                .disabled(workspace.recentRoots.isEmpty)
                Button("Закрыть проект") { workspace.closeProject() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(workspace.root == nil)
            }
            CommandGroup(replacing: .saveItem) {
                // ⌘W закрывает вкладку, а не окно — как в Xcode и браузерах.
                Button("Закрыть вкладку") { workspace.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(workspace.buffer == nil && workspace.loadError == nil)
                Button("Закрыть другие вкладки") { workspace.closeOtherTabs() }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                    .disabled(workspace.buffer == nil || workspace.tabs.count < 2)
                Divider()
                Button("Сохранить") { workspace.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!workspace.isCurrentDirty)
                Button("Сохранить все") { workspace.saveAll() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(workspace.unsavedCount == 0)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                // Уходит первому ответчику — тексту редактора, если фокус в нём.
                Button("Закомментировать строки") {
                    NSApp.sendAction(#selector(CodeTextView.toggleLineComment(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
                Button("Показать варианты") {
                    NSApp.sendAction(#selector(NSTextView.complete(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.escape, modifiers: .option)
            }
            // Сама NSTextView ⌘F не ловит — ей нужен пункт меню, а в SwiftUI
            // его нет. Без .disabled: доступность пунктов SwiftUI обновляет
            // не сразу, и ⌘F после открытия файла мог остаться выключенным.
            // Без редактора запрос просто некому выполнить.
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Найти…") { workspace.find(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Найти и заменить…") { workspace.find(.showReplaceInterface) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Найти далее") { workspace.find(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Найти ранее") { workspace.find(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Искать выделенное") { workspace.find(.setSearchString) }
                    .keyboardShortcut("e", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Перейти к файлу…") { workspace.openPalette(mode: .files) }
                    .keyboardShortcut("p", modifiers: .command)
                // Двойной Shift меню назначить не умеет — его ловит
                // DoubleShiftMonitor, а здесь он только подписан.
                Button("Найти класс…  ⇧⇧") { workspace.openClassSearch() }
                Button("Структура файла…") { workspace.openPalette(mode: .outline) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Символ в проекте…") { workspace.openPalette(mode: .symbols) }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!workspace.canSearchSymbols)
                Divider()
                Button("Следующее объявление") { workspace.jumpToMember(1) }
                    .keyboardShortcut(.downArrow, modifiers: .control)
                Button("Предыдущее объявление") { workspace.jumpToMember(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .control)
                Button("Следующее вхождение") { workspace.jumpToOccurrence(1) }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                Button("Предыдущее вхождение") { workspace.jumpToOccurrence(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Divider()
                Button("Изменённые файлы…") { workspace.openPalette(mode: .changes) }
                    .keyboardShortcut("g", modifiers: [.control, .shift])
                    .disabled(workspace.git.repository == nil)
                Button("Следующее изменение") { workspace.jumpToChange(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .option])
                Button("Предыдущее изменение") { workspace.jumpToChange(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .option])
                Divider()
                Button("Ревью мерж-реквестов") { workspace.showReviews() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(workspace.root == nil)
                Button("Комментировать строку…") { workspace.commentOnCaretLine() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(!workspace.isReviewDocument)
                Button("Следующий тред") { workspace.jumpToThread(1) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(!workspace.isReviewDocument)
                Button("Предыдущий тред") { workspace.jumpToThread(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(!workspace.isReviewDocument)
                Button("Следующий файл MR") { workspace.openAdjacentReviewFile(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(workspace.review.active == nil)
                Button("Предыдущий файл MR") { workspace.openAdjacentReviewFile(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(workspace.review.active == nil)
                Divider()
                Button("Следующий конфликт") { workspace.jumpToConflict(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .option, .command])
                    .disabled(workspace.conflicts.isEmpty)
                Button("Предыдущий конфликт") { workspace.jumpToConflict(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .option, .command])
                    .disabled(workspace.conflicts.isEmpty)
                Button("Принять текущее") { workspace.acceptConflict(.current) }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .option, .command])
                    .disabled(workspace.conflicts.isEmpty)
                Button("Принять входящее") { workspace.acceptConflict(.incoming) }
                    .keyboardShortcut(.rightArrow, modifiers: [.control, .option, .command])
                    .disabled(workspace.conflicts.isEmpty)
                Button("Принять оба") { workspace.acceptConflict(.both) }
                    .disabled(workspace.conflicts.isEmpty)
                Button("Отметить конфликт решённым") { workspace.markConflictsResolved() }
                    .disabled(!workspace.isConflictedFile || !workspace.conflicts.isEmpty)
                Divider()
                // Не требует LSP: пока сервер не готов, отвечает быстрый
                // навигатор по индексу объявлений проекта.
                Button("Перейти к объявлению") {
                    workspace.goToDefinition(at: workspace.caretOffset)
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Найти использования") {
                    workspace.findReferences(at: workspace.caretOffset)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(workspace.document == nil)
                // Unity: ссылки на ассеты — это GUID, языковой сервер тут не нужен.
                Button("Где используется ассет") { workspace.findAssetUsages() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!workspace.unity.isActive)
                Button("Ассет ↔ .meta") { workspace.toggleMetaFile() }
                    .keyboardShortcut("m", modifiers: [.command, .control])
                    .disabled(!workspace.unity.isActive)
                Button(showsInspector ? "Скрыть инспектор" : "Показать инспектор") { showsInspector.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(workspace.document?.unityFile == nil)
                Divider()
                Button("Назад") { workspace.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!workspace.canGoBack)
                Button("Вперёд") { workspace.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!workspace.canGoForward)
                Divider()
                Button("Следующая вкладка") { workspace.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(workspace.tabs.count < 2)
                Button("Предыдущая вкладка") { workspace.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(workspace.tabs.count < 2)
                // ⌃Tab ловит TabSwitchMonitor: с зажатым ⌃ он ходит дальше
                // по недавним, а меню так не умеет. Здесь — подпись и клик.
                Button("Недавняя вкладка  ⌃Tab") { workspace.selectPreviousRecentTab() }
                    .disabled(workspace.tabs.count < 2)
                Divider()
                Button("Крупнее") { workspace.fontSize += 1 }
                    .keyboardShortcut("=", modifiers: .command)   // ⌘+ без Shift
                Button("Мельче") { workspace.fontSize -= 1 }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Исходный размер") { workspace.fontSize = 12.5 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Чтобы при выходе спросить про несохранённые правки.
    weak var workspace: Workspace?
    /// Файлы и `pilot://`, пришедшие раньше первого кадра: Unity запускает
    /// Pilot сразу с файлом, и событие обгоняет окно.
    private var pendingRequests: [OpenRequest] = []

    /// Окно готово. Присланное снаружи важнее командной строки: без него
    /// открывается путь из аргументов или остаётся стартовый экран.
    @MainActor
    func attach(_ workspace: Workspace) {
        self.workspace = workspace
        if pendingRequests.isEmpty {
            workspace.start()
        } else {
            pendingRequests.forEach(workspace.open)
            pendingRequests = []
        }
    }

    /// Finder, `open -a Pilot File.cs` и `pilot://open?…` из Unity —
    /// в уже запущенный экземпляр, без перезапуска. Apple Events ловим сами:
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

    @MainActor
    private func receive(_ urls: [URL]) {
        let requests = urls.compactMap(OpenRequest.init(url:))
        guard let workspace else {
            pendingRequests += requests
            return
        }
        requests.forEach(workspace.open)
        for window in NSApp.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace?.confirmUnsavedChanges() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Палитра — Catppuccin Macchiato, тёмная; ставим до появления окна,
        // чтобы не мигнуть светлым хромом.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // До конца запуска: событие, с которым Pilot запустили, приходит сразу после.
        installOpenHandlers()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
