import SwiftUI
import AppKit

/// Сайдбар в духе навигатора Xcode: вкладки в тулбаре над ним, рядом
/// с кнопкой панели, список посередине, фильтр снизу. На macOS 26
/// NavigationSplitView сам делает его плавающей стеклянной панелью.
struct NavigatorView: View {
    @ObservedObject var workspace: Workspace
    @AppStorage("pilot.showsInspector") private var showsInspector = true
    @FocusState private var filterFocused: Bool

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .automatic) { tabBar }
            }
            .pilotEdgeBar(.bottom) {
                if hasFilter { filterField }
            }
            .onChange(of: workspace.navigatorFilterFocusRequest) { _, _ in
                // Поле могло появиться в этом же обновлении — фокус после него.
                DispatchQueue.main.async { filterFocused = true }
            }
    }

    private var hasFilter: Bool {
        guard workspace.root != nil else { return false }
        switch workspace.navigatorTab {
        case .project, .outline: return true
        case .review:            return workspace.isReviewSearchVisible
        case .recent:            return false
        }
    }

    /// Дерево проекта не пересоздаётся при переключении вкладок — оно
    /// только прячется: иначе раскрытые папки забывались бы.
    private var content: some View {
        ZStack {
            projectTree
                .opacity(workspace.navigatorTab == .project ? 1 : 0)
                .allowsHitTesting(workspace.navigatorTab == .project)
                .accessibilityHidden(workspace.navigatorTab != .project)
            switch workspace.navigatorTab {
            case .project: EmptyView()
            case .outline: OutlineList(workspace: workspace)
            case .review:  ReviewNavigator(workspace: workspace)
            case .recent:  RecentList(workspace: workspace)
            }
        }
    }

    @ViewBuilder
    private var projectTree: some View {
        if workspace.fileTree == nil {
            placeholder(workspace.root == nil ? "Папка не открыта" : "Индексация…")
        } else {
            // Пока отфильтрованное дерево собирается, показываем полное,
            // но не раскрываем его целиком — на 100 000 файлов это дорого.
            let filtering = !workspace.navigatorFilter.isEmpty && workspace.filteredTree != nil
            FileTreeView(tree: filtering ? workspace.filteredTree : workspace.fileTree,
                         selectedPath: workspace.openFilePath,
                         root: workspace.root,
                         expandAll: filtering,
                         gitFiles: workspace.git.changedFiles,
                         showsHierarchy: workspace.unity.isActive && !filtering,
                         hierarchy: workspace.document?.unityHierarchy,
                         selectedObject: workspace.unityHierarchySelection,
                         onOpen: { relPath, preview in
                             guard let root = workspace.root else { return }
                             workspace.navigate(to: NavTarget(url: root.appendingPathComponent(relPath),
                                                              range: nil),
                                                preview: preview)
                             if !preview { workspace.focusEditor() }
                         },
                         onSelectObject: { fileID, focusEditor in
                             // Выбрали объект — значит, будут его править: нужен инспектор.
                             showsInspector = true
                             workspace.revealUnityObject(fileID: fileID)
                             if focusEditor { workspace.focusEditor() }
                         })
                .overlay {
                    if filtering, workspace.filteredTree?.fileCount == 0 {
                        placeholder("Ничего не найдено")
                    }
                }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Вкладки

    /// Как в Xcode 26: иконки в ряд, выбранная — в залитом акцентом круге.
    /// Стоят в строке заголовка: место там всё равно пустует.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Workspace.NavigatorTab.allCases, id: \.self) { tab in
                let selected = workspace.navigatorTab == tab
                Button {
                    workspace.navigatorTab = tab
                } label: {
                    Image(systemName: selected ? tab.selectedIcon : tab.icon)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: 28, height: 26)
                        .background {
                            if selected {
                                Capsule().fill(Color.accentColor)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
            }
        }
        // Без Spacer: в элементе тулбара он выбросил бы весь элемент.
        .padding(.horizontal, 2)
    }

    // MARK: - Фильтр

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: workspace.navigatorTab == .review ? "magnifyingglass" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(workspace.navigatorTab == .review ? "Поиск мерж-реквестов" : "Фильтр",
                      text: filterBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .help(workspace.navigatorTab == .review
                      ? "Слова из названия, ветки, меток или имени; !123 — номер, @логин — автор или ревьюер. Слитые и закрытые ищутся в GitLab."
                      : "")
                .focused($filterFocused)
                .onSubmit(submitFilter)
                .onExitCommand {
                    if filterBinding.wrappedValue.isEmpty { workspace.focusEditor() }
                    else { filterBinding.wrappedValue = "" }
                }
            if !filterBinding.wrappedValue.isEmpty {
                Button { filterBinding.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Одно поле на три вкладки: в проекте фильтрует файлы,
    /// в структуре — объявления, в ревью — ищет мерж-реквесты.
    private var filterBinding: Binding<String> {
        switch workspace.navigatorTab {
        case .outline:
            return Binding(get: { workspace.outlineFilter }, set: { workspace.outlineFilter = $0 })
        case .review:
            return Binding(get: { workspace.review.searchQuery }, set: { workspace.review.searchQuery = $0 })
        default:
            return $workspace.navigatorFilter
        }
    }

    private func submitFilter() {
        if workspace.navigatorTab == .review { workspace.openTopReviewSearchResult() }
    }
}

// MARK: - Структура файла

struct OutlineList: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let document = workspace.document {
            let items = filtered(document.outline)
            if items.isEmpty {
                empty(document.outline.isEmpty ? "В этом файле объявлений не найдено" : "Ничего не найдено")
            } else {
                ScrollViewReader { proxy in
                    List(selection: selection) {
                        ForEach(items) { item in
                            OutlineRowView(item: item).tag(item.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .environment(\.sidebarRowSize, .small)
                    .onAppear {
                        if let id = workspace.caret.outlineItem?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: workspace.caret.outlineItem?.id) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        } else {
            empty("Откройте файл, чтобы увидеть его структуру")
        }
    }

    private var selection: Binding<Int?> {
        Binding(get: { workspace.caret.outlineItem?.id },
                set: { id in
                    guard let id, let item = workspace.document?.outline.first(where: { $0.id == id })
                    else { return }
                    workspace.jump(to: item)
                })
    }

    private func filtered(_ outline: [OutlineItem]) -> [OutlineItem] {
        let needle = workspace.outlineFilter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return outline }
        return outline.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OutlineRowView: View {
    let item: OutlineItem

    var body: some View {
        HStack(spacing: 6) {
            SymbolBadge(kind: item.kind, keyword: item.keyword)
            Text(item.name)
                .font(.system(size: 13))
                .lineLimit(1)
        }
        .padding(.leading, CGFloat(min(item.depth, 6)) * 12)
    }
}

/// Буква в цветном квадратике — символы в Xcode помечены так же.
struct SymbolBadge: View {
    let kind: OutlineKind
    var keyword: String? = nil
    var size: CGFloat = 16

    var body: some View {
        let badge = Theme.badge(for: kind, keyword: keyword)
        Text(badge.letter)
            .font(.system(size: size * (badge.letter.count > 1 ? 0.5 : 0.62),
                          weight: .bold, design: .rounded))
            .foregroundStyle(Color(nsColor: Theme.badgeText))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(nsColor: badge.color)))
    }
}

// MARK: - Недавние проекты

struct RecentList: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        List {
            ForEach(workspace.recentRoots, id: \.path) { url in
                Button {
                    workspace.open(root: url)
                    workspace.navigatorTab = .project
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: url == workspace.root ? "folder.fill.badge.gearshape" : "folder.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color(nsColor: Theme.folderIcon.color))
                            .font(.system(size: 14))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: url == workspace.root ? .semibold : .regular))
                            Text(url.deletingLastPathComponent().path
                                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                workspace.promptForFolder()
            } label: {
                Label("Открыть папку…", systemImage: "folder.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
    }
}
