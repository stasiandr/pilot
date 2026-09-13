import SwiftUI
import AppKit

/// Окно в духе Xcode 26: плавающий стеклянный навигатор слева, над
/// редактором — jump bar, в тулбаре — заголовок с веткой и капсула
/// активности посередине.
struct RootView: View {
    @ObservedObject var workspace: Workspace
    @State private var doubleShift: DoubleShiftMonitor?
    /// Видимость панели переживает перезапуск. ⌃⌘S и кнопка в тулбаре — штатные.
    @AppStorage("pilot.showsSidebar") private var showsSidebar = true

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            NavigatorView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 480)
        } detail: {
            detail
                .toolbar { toolbar }
                .pilotTransparentToolbar()
        }
        .navigationTitle(workspace.root?.lastPathComponent ?? "Pilot")
        .overlay {
            if workspace.isPaletteOpen { paletteOverlay }
        }
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            doubleShift = DoubleShiftMonitor { [workspace] in workspace.openClassSearch() }
        }
    }

    /// На стартовом экране навигатору показывать нечего — панель прячется,
    /// но выбор пользователя не трогаем: откроется проект — вернётся.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showsSidebar && workspace.root != nil ? .all : .detailOnly },
            set: { if workspace.root != nil { showsSidebar = $0 != .detailOnly } })
    }

    // MARK: - Редактор

    private var detail: some View {
        VStack(spacing: 0) {
            if workspace.root != nil {
                JumpBar(workspace: workspace)
            }
            if workspace.review.active != nil {
                ReviewBar(workspace: workspace)
            }
            content
            if workspace.root != nil {
                statusBar
            }
        }
        .background(Color(nsColor: Theme.editorBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private var content: some View {
        if let error = workspace.loadError {
            notice(icon: "exclamationmark.triangle", title: error)
        } else if workspace.document != nil {
            CodeView(document: workspace.document,
                     fontSize: workspace.fontSize,
                     reveal: workspace.reveal,
                     occurrences: workspace.occurrences,
                     lineChanges: workspace.editorLineChanges,
                     commentMarks: workspace.editorCommentMarks,
                     isReview: workspace.isReviewDocument,
                     popover: workspace.linePopover,
                     popoverContent: { request in
                         AnyView(LineInspector(workspace: workspace, line: request.line,
                                               compose: request.compose)
                            .preferredColorScheme(.dark))
                     },
                     focusRequest: workspace.editorFocusRequest,
                     onCaretChange: { workspace.caretMoved(to: $0) },
                     onGoToDefinition: { workspace.goToDefinition(at: $0) },
                     onLineClick: { workspace.lineClicked($0) },
                     onCommentLine: workspace.isReviewDocument ? { workspace.commentOnLine($0) } : nil)
        } else if workspace.root == nil {
            StartView(workspace: workspace)
        } else {
            noEditor
        }
    }

    private func notice(icon: String, title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Пустой редактор, как «No Editor» в Xcode: крупная приглушённая
    /// надпись и подсказки по клавишам.
    private var noEditor: some View {
        VStack(spacing: 18) {
            Text("Нет открытого файла")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 8) {
                shortcutHint(["⌘", "P"], "Перейти к файлу")
                shortcutHint(["⇧", "⇧"], "Найти класс")
                shortcutHint(["⌘", "⇧", "O"], "Структура файла")
                shortcutHint(["⌘", "⇧", "W"], "Закрыть проект")
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            titleView
        }
        .pilotWithoutGlassBackground()

        ToolbarItem(placement: .principal) {
            ActivityView(workspace: workspace)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { workspace.openPalette(mode: .outline) } label: {
                Label("Структура файла", systemImage: "list.bullet.indent")
            }
            .help("Структура файла (⌘⇧O)")
            .disabled(workspace.document == nil)

            Button { workspace.openPalette(mode: .symbols) } label: {
                Label("Символ в проекте", systemImage: "number")
            }
            .help("Символ в проекте (⌘T)")
            .disabled(!workspace.lsp.isReady)
        }
    }

    /// Как в Xcode: иконка ветки, под именем проекта — текущая ветка.
    /// Сначала она прочитана из HEAD при открытии, затем её сменяет живой
    /// статус git — и после checkout в терминале заголовок обновится.
    private var titleView: some View {
        let branch = workspace.git.status?.headLabel ?? workspace.branch
        return HStack(spacing: 8) {
            if branch != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(workspace.root?.lastPathComponent ?? "Pilot")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let branch {
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 170, alignment: .leading)
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
                Text(Theme.count(doc.model.lineCount, "строка", "строки", "строк"))
                    .foregroundStyle(.tertiary)

                Spacer()

                blameLabel
                changesChip
                let position = doc.model.position(at: workspace.caretOffset)
                Text("Строка: \(position.line + 1)   Столбец: \(position.character + 1)")
                    .monospacedDigit()
            } else {
                Spacer()
                changesChip
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

    // MARK: - Git

    /// Кто и когда последним трогал строку под курсором. Появляется, когда
    /// blame досчитается; до тех пор места в строке не занимает.
    @ViewBuilder
    private var blameLabel: some View {
        if let doc = workspace.document,
           let commit = workspace.git.blame?.commit(atLine: doc.model.line(containing: workspace.caretOffset)) {
            if commit.isUncommitted {
                Text("Не закоммичено")
                    .foregroundStyle(.tertiary)
                    .help("Строка отличается от HEAD")
            } else {
                HStack(spacing: 6) {
                    Text("\(commit.author), \(Self.ago(commit.time))")
                        .layoutPriority(1)
                    Text(commit.summary)
                        .foregroundStyle(.tertiary)
                        .truncationMode(.tail)
                }
                .lineLimit(1)
                .frame(maxWidth: 420, alignment: .trailing)
                .help("\(commit.shortSHA) · \(commit.author) · \(Self.fullDate(commit.time))\n\(commit.summary)")
                .contextMenu {
                    Button("Скопировать хэш коммита") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.sha, forType: .string)
                    }
                }
            }
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
            lines.append("Ветка \(branch)" + (status.upstream.map { " → \($0)" } ?? ""))
        } else {
            lines.append("HEAD отсоединён: \(status.headLabel)")
        }
        if status.ahead > 0 || status.behind > 0 {
            lines.append("Впереди на \(status.ahead), позади на \(status.behind) коммитов")
        }
        lines.append(changed > 0 ? "Изменено файлов: \(changed) — ⌃⇧G" : "Изменений нет")
        return lines.joined(separator: "\n")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    private static func ago(_ date: Date?) -> String {
        guard let date else { return "" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func fullDate(_ date: Date?) -> String {
        date.map(fullFormatter.string(from:)) ?? ""
    }

    // MARK: - Оверлей палитры

    private var paletteOverlay: some View {
        ZStack(alignment: .top) {
            // Клик мимо палитры закрывает её.
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { workspace.isPaletteOpen = false }

            PaletteView(workspace: workspace)
                .padding(.top, 60)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Капсула активности

/// Центральная капсула тулбара — как activity view в Xcode: слева «что
/// открыто», справа «что происходит». Клик — переход к файлу, как ⌘P.
struct ActivityView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Button {
            if workspace.root != nil { workspace.openPalette(mode: .files) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(workspace.root?.lastPathComponent ?? "Pilot")
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let doc = workspace.document {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    let icon = Theme.fileIcon(forName: doc.url.lastPathComponent)
                    Image(systemName: icon.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: icon.color))
                    Text(doc.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }

                // Не Spacer: Spacer внутри элемента тулбара SwiftUI принимает
                // за гибкий пробел и молча выбрасывает весь элемент.
                Color.clear.frame(minWidth: 24, maxWidth: .infinity, maxHeight: 1)
                // Статус не сжимается: ужимается имя проекта, как в Xcode.
                status.fixedSize()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(minWidth: 280, idealWidth: 440, maxWidth: 520, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Перейти к файлу (⌘P)")
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if workspace.root == nil {
                Text("Нет открытого проекта").foregroundStyle(.secondary)
            } else if workspace.isIndexing {
                ProgressView().controlSize(.mini)
                Text("Индексация…").foregroundStyle(.secondary)
            } else {
                Text("Готово").foregroundStyle(.secondary)
                Text("|").foregroundStyle(.quaternary)
                Text(Theme.count(workspace.fileCount, "файл", "файла", "файлов"))
                    .foregroundStyle(.tertiary)
            }
            languageServer
        }
        .lineLimit(1)
    }

    /// Состояние языкового сервера — единственное место, где он виден,
    /// пока не готов. Всё остальное приложение о нём не знает.
    @ViewBuilder
    private var languageServer: some View {
        let name = workspace.lsp.serverName ?? "LSP"
        switch workspace.lsp.state {
        case .stopped:
            EmptyView()
        case .starting(let detail):
            divider
            ProgressView().controlSize(.mini)
            Text(name).foregroundStyle(.secondary)
                .help("\(name): \(detail). Просмотр и поиск работают уже сейчас.")
        case .ready:
            divider
            Circle().fill(.green).frame(width: 6, height: 6)
            Text(name).foregroundStyle(.secondary)
                .help("Переход к определению: ⌘B или ⌘+клик. Символы: ⌘T. Использования: ⌘R.")
        case .failed(let why):
            divider
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(name).foregroundStyle(.secondary)
                .help("Языковой сервер не поднялся:\n\(why)")
        }
    }

    private var divider: some View {
        Text("|").foregroundStyle(.quaternary)
    }
}
