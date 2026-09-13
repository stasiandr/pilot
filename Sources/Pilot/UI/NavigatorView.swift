import SwiftUI
import AppKit

/// Сайдбар в духе навигатора Xcode: ряд вкладок сверху, список посередине,
/// фильтр снизу. На macOS 26 NavigationSplitView сам делает его плавающей
/// стеклянной панелью.
struct NavigatorView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        content
            .pilotEdgeBar(.top) { tabBar }
            .pilotEdgeBar(.bottom) {
                if workspace.navigatorTab == .project || workspace.navigatorTab == .outline,
                   workspace.root != nil { filterField }
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
                         onOpen: { relPath, focusEditor in
                             guard let root = workspace.root else { return }
                             workspace.navigate(to: NavTarget(url: root.appendingPathComponent(relPath),
                                                              range: nil))
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
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Workspace.NavigatorTab.allCases, id: \.self) { tab in
                let selected = workspace.navigatorTab == tab
                Button {
                    workspace.navigatorTab = tab
                } label: {
                    Image(systemName: selected ? tab.selectedIcon : tab.icon)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: 30, height: 26)
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
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Фильтр

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Фильтр", text: filterBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
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

    /// Одно поле на две вкладки: в проекте фильтрует файлы,
    /// в структуре — объявления.
    private var filterBinding: Binding<String> {
        switch workspace.navigatorTab {
        case .outline:
            return Binding(get: { workspace.outlineFilter }, set: { workspace.outlineFilter = $0 })
        default:
            return $workspace.navigatorFilter
        }
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
                        if let id = workspace.currentOutlineItem?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: workspace.currentOutlineItem?.id) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        } else {
            empty("Откройте файл, чтобы увидеть его структуру")
        }
    }

    private var selection: Binding<Int?> {
        Binding(get: { workspace.currentOutlineItem?.id },
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
