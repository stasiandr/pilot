import SwiftUI
import AppKit

/// Окно в духе Xcode 26: плавающий стеклянный навигатор слева, над
/// редактором — jump bar, в тулбаре — заголовок с веткой и капсула
/// активности посередине.
struct RootView: View {
    @ObservedObject var workspace: Workspace
    @State private var doubleShift: DoubleShiftMonitor?
    @State private var navigationKeys: NavigationKeyMonitor?
    @State private var tabSwitch: TabSwitchMonitor?
    @State private var paletteKeys: PaletteKeyMonitor?
    @State private var paletteSpace: CGSize = .zero
    /// Что показывает сплит прямо сейчас. Не вычисляется из
    /// `workspace.showsSidebar`: сплит в том же кадре читал старое значение —
    /// панель возвращалась на место и потом появлялась рывком, без анимации.
    /// @State меняется синхронно и в той же транзакции.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    /// Инспектор Unity справа. Появляется только у сцен, префабов и ассетов.
    @AppStorage("pilot.showsInspector") private var showsInspector = true
    /// Сколько окна над кодом: всё, покомпактнее или одни вкладки.
    @AppStorage(EditorChrome.key) private var chrome = EditorChrome.regular
    @AppStorage(EditorChrome.jumpBarKey) private var showsJumpBar = true
    @ObservedObject private var copilot = CopilotService.shared
    @AppStorage(EditorChrome.projectTabsKey) private var showsProjectTabs = false
    private var compact: Bool { chrome.isCompact }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            // Уже 275 — не влезут вкладки навигатора в строке заголовка:
            // тулбар спрячет их в «»».
            NavigatorView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 275, ideal: 280, max: 480)
        } detail: {
            detail
                .inspector(isPresented: inspectorVisibility) {
                    UnityInspectorView(workspace: workspace)
                        .inspectorColumnWidth(min: 260, ideal: 330, max: 600)
                }
                .toolbar(id: toolbarID) { toolbar }
                .pilotTransparentToolbar()
        }
        .navigationTitle(workspace.root?.lastPathComponent ?? "Pilot")
        .overlay {
            if workspace.isPaletteOpen { paletteOverlay }
        }
        .frame(minWidth: 860, minHeight: 520)
        .sheet(item: $workspace.localHistoryFile) { file in
            LocalHistoryView(workspace: workspace, file: file)
        }
        .background(WindowChrome(chrome: chrome, projectTabs: showsProjectTabs))
        .onAppear {
            doubleShift = DoubleShiftMonitor(workspace: workspace) { [workspace] in
                workspace.openSearch(.everything, again: .types)
            }
            tabSwitch = TabSwitchMonitor(workspace: workspace)
            navigationKeys = NavigationKeyMonitor(workspace: workspace)
            paletteKeys = PaletteKeyMonitor(workspace: workspace)
            syncSidebar(animated: false)
        }
        // Открыли или закрыли проект — панель встаёт как была, без анимации.
        .onChange(of: workspace.root) { _, _ in syncSidebar(animated: false) }
        // ⌃⌘S из меню меняет настройку — панель выезжает так же, как по кнопке.
        .onChange(of: workspace.showsSidebar) { _, _ in syncSidebar(animated: true) }
    }

    private func syncSidebar(animated: Bool) {
        let visibility: NavigationSplitViewVisibility = workspace.showsSidebar && workspace.root != nil ? .all : .detailOnly
        guard sidebarVisibility != visibility else { return }
        var transaction = Transaction(animation: animated ? .default : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) { sidebarVisibility = visibility }
    }

    private var hasUnityObjects: Bool { workspace.document?.unityFile != nil }

    /// Выбор пользователя помним, но показываем инспектор только там, где
    /// ему есть что показать.
    private var inspectorVisibility: Binding<Bool> {
        Binding(get: { showsInspector && hasUnityObjects },
                set: { if hasUnityObjects { showsInspector = $0 } })
    }

    /// На стартовом экране навигатору показывать нечего — панель прячется,
    /// но выбор пользователя не трогаем: откроется проект — вернётся.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisibility },
            set: { visibility in
                guard workspace.root != nil else { return }
                sidebarVisibility = visibility
                workspace.showsSidebar = visibility != .detailOnly
            })
    }

    // MARK: - Редактор

    private var detail: some View {
        VStack(spacing: 0) {
            UpdateBar(updater: Updater.shared)
            ExtensionBar(workspace: workspace)
            if workspace.root != nil, !workspace.tabs.isEmpty {
                TabBar(workspace: workspace)
            }
            if workspace.root != nil, showsJumpBar {
                JumpBar(workspace: workspace)
            }
            if workspace.review.active != nil {
                ReviewBar(workspace: workspace)
            }
            if workspace.showsConflictBar {
                ConflictBar(workspace: workspace)
            }
            if let mirror = workspace.mirror {
                MirrorBar(workspace: workspace, mirror: mirror)
            }
            content
            if workspace.root != nil, workspace.run.showsConsole {
                RunConsole(run: workspace.run)
            }
            if workspace.root != nil, workspace.debug.isPanelVisible {
                DebugPanel(debug: workspace.debug)
            }
            if workspace.unity.isActive {
                UnityConsoleSlot(workspace: workspace, console: workspace.unityConsole)
            }
            if workspace.root != nil {
                statusBar
            }
        }
        .background(Color(nsColor: Theme.editorBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private var content: some View {
        if let error = workspace.loadError {
            // Текстуру или модель не прочитать как текст, но в Unity-проекте
            // про неё всё равно есть что узнать.
            notice(icon: "exclamationmark.triangle", title: error,
                   hint: workspace.unity.isActive
                       ? L("⇧⌘R — где используется этот ассет  ·  ⌃⌘M — открыть его .meta") : nil)
        } else if let buffer = workspace.buffer, let media = buffer.document.media {
            MediaView(url: buffer.url, kind: media)
                .id(buffer.url)
        } else if let buffer = workspace.buffer, workspace.showsRenderedMarkdown {
            MarkdownView(buffer: buffer, version: buffer.model.version, reveal: workspace.reveal,
                         fontSize: workspace.fontSize,
                         onOpenFile: { workspace.open(file: $0) },
                         onShowSource: { workspace.showMarkdownSource(line: $0) })
                .id(ObjectIdentifier(buffer))
        } else if let buffer = workspace.buffer {
            OccurrencesReader(caret: workspace.caret) { occurrences in
                CodeView(buffer: buffer,
                         fontSize: workspace.fontSize,
                         reveal: workspace.reveal,
                         occurrences: occurrences,
                         lineChanges: workspace.editorLineChanges,
                         commentMarks: workspace.editorCommentMarks,
                         isReview: workspace.isReviewDocument,
                         popover: workspace.linePopover,
                         popoverContent: { request in
                             AnyView(LineInspector(workspace: workspace, line: request.line,
                                                   compose: request.compose)
                                .preferredColorScheme(Theme.current.isDark ? .dark : .light))
                         },
                         conflicts: workspace.conflicts,
                         conflictAction: workspace.conflictAction,
                         focusRequest: workspace.editorFocusRequest,
                         findRequest: workspace.findRequest,
                         contextActionsRequest: workspace.contextActionsRequest,
                         completionTriggers: workspace.lsp.completionTriggers,
                         decorator: workspace.archive.decorator() ?? workspace.unity.decorator(),
                         decorationsVersion: workspace.unity.decorationsVersion
                             &+ workspace.archive.decorationsVersion,
                         editRequest: workspace.editRequest,
                         onCaretChange: { workspace.caretMoved(to: $0) },
                         onGoToDefinition: { workspace.goToDefinition(at: $0) },
                         onLineClick: { workspace.lineClicked($0) },
                         onCommentLine: workspace.isReviewDocument ? { workspace.commentOnLine($0) } : nil,
                         breakpoints: workspace.editorBreakpoints,
                         executionLine: workspace.editorExecutionLine,
                         onBreakpointClick: { workspace.gutterNumberClicked($0) },
                         contextActions: { workspace.contextActions(at: $0) },
                         requestCompletions: { offset, trigger, retrigger in
                             await workspace.completions(at: offset, trigger: trigger, retrigger: retrigger)
                         },
                         requestSuggestion: copilot.isReady ? { await workspace.copilotSuggestion(at: $0) } : nil,
                         onSuggestionShown: { copilot.suggestionShown($0) },
                         onSuggestionAccepted: { copilot.suggestionAccepted($0) },
                         diagnostics: workspace.diagnostics(for: buffer),
                         diagnosticsVersion: workspace.diagnosticsVersion,
                         insights: workspace.insights(for: buffer),
                         insightsVersion: workspace.insightsVersion &* 4
                             + (workspace.showsInlayHints ? 1 : 0) + (workspace.showsCodeLens ? 2 : 0),
                         onLensClick: { workspace.findReferences(at: $0) },
                         requestDocumentation: { offset in await workspace.documentation(at: offset) },
                         requestSignatures: { offset in await workspace.signatures(at: offset) },
                         selectionSteps: { selection in workspace.selectionSteps(around: selection) })
            }
        } else if workspace.root == nil {
            StartView(workspace: workspace)
        } else {
            noEditor
        }
    }

    private func notice(icon: String, title: String, hint: String? = nil) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Пустой редактор, как «No Editor» в Xcode: крупная приглушённая
    /// надпись и подсказки по клавишам.
    private var noEditor: some View {
        VStack(spacing: 18) {
            Text(L("Нет открытого файла"))
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 8) {
                shortcutHint(["⌘", "P"], L("Перейти к файлу"))
                shortcutHint(["⇧", "⇧"], L("Найти класс"))
                shortcutHint(["⌘", "⇧", "O"], L("Структура файла"))
                shortcutHint(["⌘", "⇧", "W"], L("Закрыть проект"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcutHint(_ keys: [String], _ title: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .frame(minWidth: 20, minHeight: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.08)))
                }
            }
            .frame(width: 76, alignment: .trailing)
            Text(title).font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Тулбар

    /// Тулбар настраивается, как в Finder: «Вид → Настроить панель
    /// инструментов…» или правый клик по нему. У каждого элемента свой id —
    /// по нему macOS помнит раскладку. Кнопки, которым сейчас нечего делать
    /// (▶ без целей, Markdown не в .md), просто исчезают, и тулбар сдвигается.
    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "title", placement: .automatic) {
            // Подпись в окне настройки берётся из заголовка Label, а
            // рисуется сам заголовок окна — проект и ветка.
            Label { Text(L("Проект и ветка")) } icon: { EmptyView() }
                .labelStyle(ShowingView(view: titleView))
        }
        .pilotWithoutGlassBackground()

        // Запуск: ▶, ■ и цель. Group — у построителя тулбара предел в 10 элементов.
        Group {
            ToolbarItem(id: "run", placement: .automatic) {
                if hasRunTargets {
                    Button { workspace.runSelected() } label: {
                        Label(L("Запустить"), systemImage: "play.fill")
                    }
                    .help(KeymapStore.shared.help(runHelp, .run))
                }
            }

            ToolbarItem(id: "stop", placement: .automatic) {
                if hasRunTargets {
                    Button { workspace.run.stop() } label: {
                        Label(L("Остановить"), systemImage: "stop.fill")
                    }
                    .help(KeymapStore.shared.help(L("Остановить"), .stop))
                    .disabled(!workspace.run.isRunning)
                }
            }

            ToolbarItem(id: "runTarget", placement: .automatic) {
                if hasRunTargets {
                    RunTargetMenu(workspace: workspace, run: workspace.run)
                }
            }

        }

        ToolbarItem(id: "pair", placement: .automatic) {
            if let label = workspace.partnerLabel {
                Button { workspace.openPartner() } label: {
                    Label(label, systemImage: "arrow.left.arrow.right")
                        .labelStyle(.titleAndIcon)
                }
                .help(KeymapStore.shared.help("Вторая половина пары — \(workspace.partner?.lastPathComponent ?? label)",
                                              .openPartner))
            }
        }

        // Гибкий пробел разводит кнопки: до него — слева, после — справа.
        // У всех элементов одно размещение, поэтому любую можно переставить
        // куда угодно; пробелы — ещё и в окне настройки, как в Finder.
        Group {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .automatic)
                ToolbarSpacer(.flexible, placement: .automatic)
            }
        }

        ToolbarItem(id: "debug", placement: .automatic) {
            if workspace.root != nil {
                DebugToolbarControls(debug: workspace.debug)
            }
        }

        ToolbarItem(id: "status", placement: .automatic, showsByDefault: false) {
            StatusIndicator(workspace: workspace)
        }

        ToolbarItem(id: "outline", placement: .automatic) {
            Button { workspace.openPalette(mode: .outline) } label: {
                Label(L("Структура файла"), systemImage: "list.bullet.indent")
            }
            .help(KeymapStore.shared.help(L("Структура файла"), .fileStructure))
            .disabled(workspace.document == nil)
        }

        ToolbarItem(id: "search", placement: .automatic) {
            Button { workspace.openSearch(.everything, again: .files) } label: {
                Label(L("Поиск"), systemImage: "magnifyingglass")
            }
            .help(L("Файлы, типы, символы и текст — одним поиском (⌘P, ⇧⇧)"))
            .disabled(workspace.root == nil)
        }

        ToolbarItem(id: "markdown", placement: .automatic) {
            if workspace.isMarkdownDocument {
                Button { workspace.toggleMarkdownSource() } label: {
                    Label(workspace.showsRenderedMarkdown ? L("Исходник") : L("Просмотр"),
                          systemImage: workspace.showsRenderedMarkdown
                              ? "chevron.left.forwardslash.chevron.right" : "doc.richtext")
                }
                .help(workspace.showsRenderedMarkdown ? L("Показать исходник (⇧⌘V)") : L("Показать свёрстанным (⇧⌘V)"))
            }
        }

        ToolbarItem(id: "inspector", placement: .automatic) {
            if hasUnityObjects {
                Button { showsInspector.toggle() } label: {
                    Label(L("Инспектор Unity"), systemImage: "sidebar.trailing")
                }
                .help(KeymapStore.shared.help(L("Инспектор Unity"), .toggleInspector))
            }
        }
    }

    /// Как в Xcode: иконка ветки, под именем проекта — текущая ветка.
    /// Сначала она прочитана из HEAD при открытии, затем её сменяет живой
    /// статус git — и после checkout в терминале заголовок обновится.
    /// Свой тулбар у каждого проекта. macOS держит одинаковыми все тулбары с
    /// одним id: без целей запуска в Unity-проекте ▶ пропадала и во вкладке
    /// сервера. Заодно у каждого проекта своя настройка панели.
    private var toolbarID: String {
        "pilot.main." + (workspace.root?.lastPathComponent ?? "start")
    }

    private var hasRunTargets: Bool { workspace.root != nil && !workspace.run.targets.isEmpty }

    private var runHelp: String {
        guard let name = workspace.run.selected?.name else { return L("Запустить") }
        return workspace.run.isRunning ? L("Перезапустить «\(name)»") : L("Запустить «\(name)»")
    }

    private var titleView: some View {
        let branch = workspace.git.status?.headLabel ?? workspace.branch
        return HStack(spacing: compact ? 6 : 8) {
            if branch != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            // В компактном тулбаре на две строки нет высоты — ветка встаёт
            // рядом с именем проекта.
            let layout = compact
                ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            layout {
                Text(workspace.root?.lastPathComponent ?? "Pilot")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let branch {
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: compact ? 280 : 170, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .help(workspace.git.status.map { branchHelp($0, changed: workspace.git.changedCount) } ?? "")
    }

    // MARK: - Статусная строка

    /// Как нижняя полоса редактора Xcode: язык слева, позиция курсора справа.
    private var statusBar: some View {
        HStack(spacing: 10) {
            if let doc = workspace.document {
                let icon = Theme.fileIcon(forName: doc.url.lastPathComponent)
                Image(systemName: icon.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: icon.color))
                Text(doc.languageName)
                if doc.media == nil {
                    Text(Theme.count(doc.model.lineCount, "строка", "строки", "строк"))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                noticeLabel
                unityChip
                blameLabel
                changesChip
                if doc.media == nil, !workspace.showsRenderedMarkdown {
                    CaretPositionLabel(caret: workspace.caret, model: doc.model)
                }
                StatusIndicator(workspace: workspace)
            } else {
                Spacer()
                noticeLabel
                unityChip
                changesChip
                StatusIndicator(workspace: workspace)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: Theme.editorBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
    }

    // MARK: - Unity

    /// Короткое сообщение: «ссылка битая», «файл изменился на диске».
    @ViewBuilder
    private var noticeLabel: some View {
        if let notice = workspace.notice {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle")
                Text(notice).lineLimit(1)
            }
            .foregroundStyle(.orange)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var unityChip: some View {
        if let project = workspace.unity.project {
            HStack(spacing: 5) {
                if workspace.unity.isIndexingAssets {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "cube.fill").font(.system(size: 9))
                        .foregroundStyle(Color(nsColor: Theme.unityEvent))
                }
                Text("Unity \(project.editorVersion ?? "")")
                UnityErrorBadge(console: workspace.unityConsole)
            }
            .contentShape(Rectangle())
            .onTapGesture { workspace.unityConsole.isVisible.toggle() }
            .help(unityHelp + "\n" + KeymapStore.shared.help(L("Клик — консоль Unity"), .unityConsole))
        }
    }

    private var unityHelp: String {
        let assets = workspace.unity.assets.map { L("Ассетов с GUID: \($0.count).") } ?? L("Собираю GUID ассетов…")
        return assets + "\n" + L("⌘B или ⌘+клик по GUID — открыть ассет, по fileID — перейти к объекту.\n⇧⌘R — где используется открытый ассет. ⌃⌘M — ассет ↔ .meta.\n⌥⌘0 — инспектор сцены, префаба или ассета.\n.meta скрыты из поиска и дерева.")
    }

    // MARK: - Git

    @ViewBuilder
    private var blameLabel: some View {
        if let doc = workspace.document, let blame = workspace.git.blame {
            BlameLabel(caret: workspace.caret, blame: blame, model: doc.model)
        }
    }

    /// Сколько файлов изменено и насколько ветка разошлась с upstream.
    /// Ветка сама — в заголовке окна; клик здесь — список изменений, как ⌃⇧G.
    @ViewBuilder
    private var changesChip: some View {
        if let status = workspace.git.status {
            let changed = workspace.git.changedCount
            if changed > 0 || status.ahead > 0 || status.behind > 0 {
                Button { workspace.openPalette(mode: .changes) } label: {
                    HStack(spacing: 4) {
                        if status.ahead > 0 { Text("↑\(status.ahead)") }
                        if status.behind > 0 { Text("↓\(status.behind)") }
                        if changed > 0 {
                            Text("±\(changed)").foregroundStyle(Color(nsColor: Theme.gitModified))
                        }
                    }
                    .monospacedDigit()
                }
                .buttonStyle(.plain)
                .help(branchHelp(status, changed: changed))
            }
        }
    }

    private func branchHelp(_ status: GitStatus, changed: Int) -> String {
        var lines: [String] = []
        if let branch = status.branch {
            lines.append(L("Ветка \(branch)") + (status.upstream.map { " → \($0)" } ?? ""))
        } else {
            lines.append(L("HEAD отсоединён: \(status.headLabel)"))
        }
        if status.ahead > 0 || status.behind > 0 {
            lines.append(L("Впереди на \(status.ahead), позади на \(status.behind) коммитов"))
        }
        lines.append(changed > 0 ? L("Изменено файлов: \(changed) — ⌃⇧G") : L("Изменений нет"))
        return lines.joined(separator: "\n")
    }

    fileprivate static var relativeFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Localization.current == .ru ? "ru_RU" : "en_US")
        formatter.unitsStyle = .full
        return formatter
    }

    fileprivate static var fullFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.current == .ru ? "ru_RU" : "en_US")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }

    fileprivate static func ago(_ date: Date?) -> String {
        guard let date else { return "" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    fileprivate static func fullDate(_ date: Date?) -> String {
        date.map(fullFormatter.string(from:)) ?? ""
    }

    // MARK: - Оверлей палитры

    private var paletteOverlay: some View {
        ZStack(alignment: .top) {
            // Клик мимо палитры закрывает её.
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { workspace.isPaletteOpen = false }

            PaletteView(workspace: workspace, available: paletteSpace)
                .padding(.top, 60)
        }
        // Место под палитрой меряем фоном: GeometryReader поверх затемнения
        // перехватил бы клик мимо палитры.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { paletteSpace = geo.size }
                .onChange(of: geo.size) { _, size in paletteSpace = size }
        })
        // Появляется на месте: выезд сверху шёл поверх тулбара.
        .transition(.opacity)
    }
}

// MARK: - Статус

/// Значок в правом углу статус-строки: крутится, пока проект индексируется
/// или компилируется, зелёный, когда всё готово. По клику — что именно
/// происходит. Рядом — ошибки открытого файла.
struct StatusIndicator: View {
    @ObservedObject var workspace: Workspace
    @State private var showsDetails = false

    private enum Overall { case busy, failed, ready }

    private var overall: Overall {
        if workspace.root == nil { return .ready }
        if case .failed = workspace.lsp.state { return .failed }
        if workspace.isIndexing || workspace.decompiling != nil { return .busy }
        if case .indexing = workspace.navigationEngine, workspace.isTypeIndexing { return .busy }
        if case .compiling = workspace.compiler { return .busy }
        if case .starting = workspace.lsp.state { return .busy }
        return .ready
    }

    var body: some View {
        HStack(spacing: 8) {
            problems
            Button { showsDetails.toggle() } label: {
                Label { Text(L("Статус")) } icon: {
                    icon.frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help(L("Статус"))
            .popover(isPresented: $showsDetails, arrowEdge: .top) { details }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch overall {
        case .busy:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.gitAdded))
        }
    }

    /// Ошибки и предупреждения открытого файла. F2 — к следующей.
    @ViewBuilder
    private var problems: some View {
        if let counts = workspace.problemCounts, counts.errors + counts.warnings > 0 {
            HStack(spacing: 4) {
                if counts.errors > 0 {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Color(nsColor: Theme.diagnosticError))
                    Text("\(counts.errors)")
                }
                if counts.warnings > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
                    Text("\(counts.warnings)")
                }
            }
            .font(.system(size: 10))
            .help(L("Ошибки в этом файле. F2 — к следующей, ⇧F2 — к предыдущей."))
        }
    }

    // MARK: Подробности

    private enum State { case busy, ready, failed, info }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if workspace.root == nil {
                row(.info, L("Нет открытого проекта"))
            } else if workspace.isIndexing {
                row(.busy, L("Индексация…"))
            } else {
                row(.ready, L("Готово"), Theme.count(workspace.fileCount, "файл", "файла", "файлов"))
            }
            navigationIndex
            decompiling
            compilerStatus
            languageServer
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func row(_ state: State, _ title: String, _ detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch state {
                case .busy: ProgressView().controlSize(.mini)
                case .ready: Circle().fill(Color(nsColor: Theme.gitAdded)).frame(width: 7, height: 7)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .info: Circle().fill(.secondary).frame(width: 7, height: 7)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Быстрый навигатор виден, только пока он и отвечает: как только
    /// Rustlyn скомпилировал проект, остаётся одна его строка.
    @ViewBuilder
    private var navigationIndex: some View {
        if workspace.root != nil {
            switch workspace.navigationEngine {
            case .compiler:
                EmptyView()
            case .indexing:
                if workspace.isTypeIndexing {
                    row(.busy, L("Индекс"), L("Собираю объявления проекта для ⌘B, ⌘T и ⌘R."))
                }
            case .index:
                row(.ready, L("Индекс"), indexHelp)
            }
        }
    }

    private var indexHelp: String {
        let count = Localization.count(workspace.symbolIndex?.count ?? 0, "объявление", "объявления", "объявлений")
        return L("⌘B, ⌘T и ⌘R отвечают по быстрому индексу: \(count). Это приближение — без перегрузок и типов из лямбд. Когда Rustlyn скомпилирует проект, ⌘B и ⌘R по C# незаметно перейдут на него.")
    }

    /// Открывается сборка или класс из архива: их текст сначала собирают, и
    /// на крупной сборке это заметно.
    @ViewBuilder
    private var decompiling: some View {
        if let name = workspace.decompiling {
            row(.busy, L("Декомпиляция \(name)"), L("Собираю текст \(name) из метаданных. Откроется, как только будет готов."))
        }
    }

    /// Компилятор C# — Rustlyn: пока компилирует и когда готов.
    @ViewBuilder
    private var compilerStatus: some View {
        switch workspace.compiler {
        case .idle:
            EmptyView()
        case .compiling(let first):
            row(.busy, "Rustlyn", first
                ? L("Rustlyn компилирует проект. Пока ⌘B отвечает индекс объявлений, а ⌘R ищет по тексту.")
                : L("Rustlyn перекомпилирует проект после правки. Пока отвечает прошлая компиляция."))
        case .ready(let compiled):
            row(.ready, "Rustlyn", L("Проект скомпилирован: \(compiled.summary).\n⌘B или ⌘+клик — объявление, ⌘R — использования, дополнение — по типам."))
        }
    }

    /// Языковой сервер.
    @ViewBuilder
    private var languageServer: some View {
        let name = workspace.lsp.serverName ?? "LSP"
        switch workspace.lsp.state {
        case .stopped:
            EmptyView()
        case .starting(let detail):
            row(.busy, name, L("\(name): \(detail). Просмотр и поиск работают уже сейчас."))
        case .ready:
            row(.ready, name, L("Переход к определению: ⌘B или ⌘+клик. Символы: ⌘T. Использования: ⌘R."))
        case .failed(let why):
            row(.failed, name, L("Языковой сервер не поднялся:\n\(why)"))
        }
    }
}

// MARK: - Надписи, которые следят за курсором

/// Строка и столбец курсора. Отдельными видами, а не частью RootView:
/// курсор двигается на каждое нажатие, и перерисовываться должны только
/// эти надписи, а не всё окно.
private struct CaretPositionLabel: View {
    let caret: EditorCaret
    let model: SyntaxModel

    var body: some View {
        let position = model.position(at: caret.offset)
        Text(L("Строка: \(position.line + 1)   Столбец: \(position.character + 1)"))
            .monospacedDigit()
    }
}

/// Кто и когда последним трогал строку под курсором. Появляется, когда
/// blame досчитается; до тех пор места в строке не занимает.
private struct BlameLabel: View {
    let caret: EditorCaret
    let blame: GitBlame
    let model: SyntaxModel

    var body: some View {
        if let commit = blame.commit(atLine: model.line(containing: caret.offset)) {
            if commit.isUncommitted {
                Text(L("Не закоммичено"))
                    .foregroundStyle(.tertiary)
                    .help(L("Строка отличается от HEAD"))
            } else {
                HStack(spacing: 6) {
                    Text("\(commit.author), \(RootView.ago(commit.time))")
                        .layoutPriority(1)
                    Text(commit.summary)
                        .foregroundStyle(.tertiary)
                        .truncationMode(.tail)
                }
                .lineLimit(1)
                .frame(maxWidth: 420, alignment: .trailing)
                .help("\(commit.shortSHA) · \(commit.author) · \(RootView.fullDate(commit.time))\n\(commit.summary)")
                .contextMenu {
                    Button(L("Скопировать хэш коммита")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.sha, forType: .string)
                    }
                }
            }
        }
    }
}

/// Вхождения слова под курсором меняются при каждом переходе на другое
/// слово — перечитывает их только редактор, а не всё окно.
private struct OccurrencesReader<Content: View>: View {
    let caret: EditorCaret
    @ViewBuilder let content: ([NSRange]) -> Content

    var body: some View { content(caret.occurrences) }
}

// MARK: - Запуск

/// Выбор цели запуска: что запустит ▶.
struct RunTargetMenu: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var run: RunService

    var body: some View {
        Menu {
            ForEach(run.targets) { target in
                Toggle(target.name, isOn: Binding(
                    get: { run.selected == target },
                    set: { if $0 { run.select(target) } }))
            }
            Divider()
            Button(run.showsConsole ? L("Скрыть консоль") : L("Показать консоль")) { run.showsConsole.toggle() }
            Button(L("Настроить запуск…")) { workspace.editRunConfiguration() }
        } label: {
            Label(run.selected?.name ?? L("Цель"),
                  systemImage: run.isRunning ? "circle.fill" : "scope")
                .labelStyle(.titleOnly)
        }
        .help(run.selected?.command ?? "")
    }
}

/// Файл из зеркальных папок пары (соглашения, навыки Claude) разошёлся со
/// своей копией во второй половине: их держат одинаковыми.
private struct MirrorBar: View {
    @ObservedObject var workspace: Workspace
    let mirror: MirrorState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
            Text(mirror.missing ? "Этого файла нет в \(mirror.label), а он зеркальный"
                                : "Копия в \(mirror.label) отличается")
                .font(.system(size: 12))
            Spacer()
            if !mirror.missing {
                Button("Открыть копию") { workspace.openMirrorCopy() }
                    .controlSize(.small)
            }
            Button(mirror.missing ? "Создать копию" : "Заменить копию этой версией") { workspace.copyToMirror() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: Theme.chromeBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
    }
}

/// Label, который рисует произвольный вид, а заголовок отдаёт только как
/// подпись — для окна настройки тулбара.
struct ShowingView<V: View>: LabelStyle {
    let view: V
    func makeBody(configuration: Configuration) -> some View { view }
}

/// Консоль Unity под редактором. Отдельным видом: консоль подписана
/// сама, и новая строка лога перерисовывает её, а не всё окно.
private struct UnityConsoleSlot: View {
    let workspace: Workspace
    @ObservedObject var console: UnityConsole

    var body: some View {
        if console.isVisible {
            UnityConsolePanel(console: console) { url, line, column in
                workspace.openLogLocation(url, line: line, column: column)
            }
        }
    }
}

/// Сколько ошибок Unity пришло, пока консоль закрыта.
private struct UnityErrorBadge: View {
    @ObservedObject var console: UnityConsole

    var body: some View {
        if console.unreadErrors > 0 {
            Text(console.unreadErrors > 99 ? "99+" : String(console.unreadErrors))
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: Theme.badgeText))
                .padding(.horizontal, 4)
                .background(Capsule().fill(Color(nsColor: Theme.diagnosticError)))
        }
    }
}
