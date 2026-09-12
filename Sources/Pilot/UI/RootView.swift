import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var workspace: Workspace
    @State private var doubleShift: DoubleShiftMonitor?
    /// Видимость панели переживает перезапуск. ⌃⌘S и кнопка в тулбаре — штатные.
    @AppStorage("pilot.showsSidebar") private var showsSidebar = true

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 250, max: 480)
            } detail: {
                ZStack {
                    Color(nsColor: Theme.editorBackground).ignoresSafeArea()

                    VStack(spacing: 0) {
                        content
                        statusBar
                    }
                }
            }

            if workspace.isPaletteOpen {
                paletteOverlay
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            doubleShift = DoubleShiftMonitor { [workspace] in workspace.openClassSearch() }
        }
    }

    /// На стартовом экране дереву показывать нечего — панель прячется,
    /// но выбор пользователя не трогаем: откроется проект — вернётся.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showsSidebar && workspace.root != nil ? .all : .detailOnly },
            set: { if workspace.root != nil { showsSidebar = $0 != .detailOnly } })
    }

    // MARK: - Боковая панель

    @ViewBuilder
    private var sidebar: some View {
        if workspace.fileTree != nil {
            FileTreeView(tree: workspace.fileTree,
                         selectedPath: workspace.openFilePath,
                         root: workspace.root,
                         gitFiles: workspace.git.changedFiles,
                         onOpen: { relPath, focusEditor in
                             guard let root = workspace.root else { return }
                             workspace.navigate(to: NavTarget(url: root.appendingPathComponent(relPath),
                                                              range: nil))
                             if focusEditor { workspace.focusEditor() }
                         })
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                     lineChanges: workspace.git.lineChanges,
                     focusRequest: workspace.editorFocusRequest,
                     onCaretChange: { workspace.caretMoved(to: $0) },
                     onGoToDefinition: { workspace.goToDefinition(at: $0) })
        } else if workspace.root == nil {
            StartView(workspace: workspace)
        } else {
            notice(icon: "magnifyingglass",
                   title: "Нажмите ⌘P, чтобы найти файл")
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

    // MARK: - Статусная строка

    private var statusBar: some View {
        HStack(spacing: 12) {
            historyControls

            if let doc = workspace.document {
                Text(doc.url.lastPathComponent).font(.system(size: 11, weight: .medium))
                Text(doc.languageName).font(.system(size: 11)).foregroundStyle(.secondary)
                if !workspace.breadcrumb.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.quaternary)
                    Text(workspace.breadcrumb)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Где сейчас курсор. ⌃↑ и ⌃↓ — по объявлениям.")
                } else {
                    Text("\(doc.model.lineCount) строк")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            } else if let root = workspace.root {
                Image(systemName: "folder").font(.system(size: 10))
                Text(root.lastPathComponent).font(.system(size: 11, weight: .medium))
            }

            Spacer()

            blameLabel
            languageServerChip
            branchChip

            if workspace.isIndexing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Индексация…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if workspace.fileCount > 0 {
                Text("\(workspace.fileCount) файлов")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
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
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .help("Строка отличается от HEAD")
            } else {
                HStack(spacing: 6) {
                    Text("\(commit.author), \(Self.ago(commit.time))")
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    Text(commit.summary)
                        .foregroundStyle(.tertiary)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
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

    /// Ветка. Клик — список изменённых файлов, как и ⌃⇧G.
    @ViewBuilder
    private var branchChip: some View {
        if let status = workspace.git.status {
            let changed = workspace.git.changedCount
            Button { workspace.openPalette(mode: .changes) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(status.headLabel).fontWeight(.medium)
                    if status.ahead > 0 { Text("↑\(status.ahead)") }
                    if status.behind > 0 { Text("↓\(status.behind)") }
                    if changed > 0 {
                        Text("±\(changed)").foregroundStyle(Color(nsColor: Theme.gitModified))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(branchHelp(status, changed: changed))
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

    // MARK: - Состояние языкового сервера

    /// Фишка в статус-строке — единственное место, где LSP вообще виден,
    /// пока он не готов. Всё остальное приложение о нём не знает.
    @ViewBuilder
    private var languageServerChip: some View {
        switch workspace.lsp.state {
        case .stopped:
            EmptyView()

        case .starting(let detail):
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.55)
                Text("\(workspace.lsp.serverName ?? "LSP") · \(detail)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("Языковой сервер готовится. Просмотр и поиск работают уже сейчас.")

        case .ready:
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(workspace.lsp.serverName ?? "LSP")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .help("Переход к определению: ⌘B или ⌘+клик. Символы: ⌘T. Использования: ⌘R.")

        case .failed(let why):
            HStack(spacing: 5) {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text(workspace.lsp.serverName ?? "LSP")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .help("Языковой сервер не поднялся:\n\(why)")
        }
    }

    /// Кнопки назад/вперёд появляются только когда есть куда идти.
    @ViewBuilder
    private var historyControls: some View {
        if workspace.canGoBack || workspace.canGoForward {
            HStack(spacing: 2) {
                Button { workspace.goBack() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                }
                .disabled(!workspace.canGoBack)
                Button { workspace.goForward() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .disabled(!workspace.canGoForward)
            }
            .buttonStyle(.borderless)
            .help("Назад / вперёд по переходам (⌘[ и ⌘])")
        }
    }

    // MARK: - Оверлей палитры

    private var paletteOverlay: some View {
        ZStack(alignment: .top) {
            // Клик мимо палитры закрывает её.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { workspace.isPaletteOpen = false }

            PaletteView(workspace: workspace)
                .padding(.top, 90)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
