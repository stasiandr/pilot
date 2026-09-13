import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var workspace: Workspace
    @State private var doubleShift: DoubleShiftMonitor?
    /// Видимость панели переживает перезапуск. ⌃⌘S и кнопка в тулбаре — штатные.
    @AppStorage("pilot.showsSidebar") private var showsSidebar = true
    /// Инспектор Unity справа. Появляется только у сцен, префабов и ассетов.
    @AppStorage("pilot.showsInspector") private var showsInspector = true

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
                .inspector(isPresented: inspectorVisibility) {
                    UnityInspectorView(workspace: workspace)
                        .inspectorColumnWidth(min: 260, ideal: 330, max: 600)
                }
                .toolbar {
                    if hasUnityObjects {
                        ToolbarItem(placement: .primaryAction) {
                            Button { showsInspector.toggle() } label: {
                                Image(systemName: "sidebar.trailing")
                            }
                            .help("Инспектор Unity (⌥⌘0)")
                        }
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

    private var hasUnityObjects: Bool { workspace.document?.unityFile != nil }

    /// Выбор пользователя помним, но показываем инспектор только там, где
    /// ему есть что показать.
    private var inspectorVisibility: Binding<Bool> {
        Binding(get: { showsInspector && hasUnityObjects },
                set: { if hasUnityObjects { showsInspector = $0 } })
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
            // Текстуру или модель не прочитать как текст, но в Unity-проекте
            // про неё всё равно есть что узнать.
            notice(icon: "exclamationmark.triangle", title: error,
                   hint: workspace.unity.isActive
                       ? "⇧⌘R — где используется этот ассет  ·  ⌃⌘M — открыть его .meta" : nil)
        } else if workspace.document != nil {
            CodeView(document: workspace.document,
                     fontSize: workspace.fontSize,
                     reveal: workspace.reveal,
                     occurrences: workspace.occurrences,
                     focusRequest: workspace.editorFocusRequest,
                     decorator: workspace.unity.decorator(),
                     decorationsVersion: workspace.unity.decorationsVersion,
                     onCaretChange: { workspace.caretMoved(to: $0) },
                     onGoToDefinition: { workspace.goToDefinition(at: $0) })
        } else if workspace.root == nil {
            StartView(workspace: workspace)
        } else {
            notice(icon: "magnifyingglass",
                   title: "Нажмите ⌘P, чтобы найти файл")
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

            if let notice = workspace.notice {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                    Text(notice).font(.system(size: 11)).lineLimit(1)
                }
                .foregroundStyle(.orange)
                .transition(.opacity)
            }

            unityChip
            languageServerChip

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

    // MARK: - Unity

    @ViewBuilder
    private var unityChip: some View {
        if let project = workspace.unity.project {
            HStack(spacing: 5) {
                if workspace.unity.isIndexingAssets {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                } else {
                    Image(systemName: "cube.fill").font(.system(size: 9))
                        .foregroundStyle(Color(nsColor: Theme.unityEvent))
                }
                Text("Unity \(project.editorVersion ?? "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .help(unityHelp)
        }
    }

    private var unityHelp: String {
        let assets = workspace.unity.assets.map { "Ассетов с GUID: \($0.count)." } ?? "Собираю GUID ассетов…"
        return """
            \(assets)
            ⌘B или ⌘+клик по GUID — открыть ассет, по fileID — перейти к объекту.
            ⇧⌘R — где используется открытый ассет. ⌃⌘M — ассет ↔ .meta.
            .meta скрыты из поиска и дерева.
            """
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
