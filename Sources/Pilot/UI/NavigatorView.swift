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
                if workspace.navigatorTab != .recent, workspace.root != nil { filterField }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.navigatorTab {
        case .project:
            if workspace.root == nil {
                placeholder("Папка не открыта")
            } else if workspace.navigatorRows.isEmpty {
                placeholder(workspace.navigatorFilter.isEmpty ? "Индексация…" : "Ничего не найдено")
            } else {
                FileTreeList(rows: workspace.navigatorRows,
                             version: workspace.navigatorVersion,
                             selection: workspace.navigatorSelection,
                             onSelect: { workspace.selectInNavigator($0) },
                             onToggle: { workspace.toggleFolder($0) },
                             onSetExpanded: { workspace.setFolder($0, expanded: $1) })
                    .equatable()
            }
        case .outline:
            OutlineList(workspace: workspace)
        case .recent:
            RecentList(workspace: workspace)
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

// MARK: - Дерево файлов

/// Список отдельным Equatable-видом: воркспейс публикует изменения на каждое
/// движение курсора, а сравнивать тысячи строк дерева на каждое — зря.
/// Перерисовка — только когда сменилась версия строк или выделение.
struct FileTreeList: View, Equatable {
    let rows: [FileTreeRow]
    let version: Int
    let selection: String?
    let onSelect: (String?) -> Void
    let onToggle: (String) -> Void
    let onSetExpanded: (String, Bool) -> Void

    static func == (a: FileTreeList, b: FileTreeList) -> Bool {
        a.version == b.version && a.selection == b.selection
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { selection }, set: { onSelect($0) })) {
                ForEach(rows) { row in
                    FileTreeRowView(row: row, onToggle: onToggle)
                        .tag(row.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .small)
            .onChange(of: selection) { _, new in
                guard let new else { return }
                proxy.scrollTo(new)
            }
            .onKeyPress(.leftArrow) { expand(false) }
            .onKeyPress(.rightArrow) { expand(true) }
        }
    }

    /// ← и → сворачивают и раскрывают выбранную папку, как в Finder.
    private func expand(_ open: Bool) -> KeyPress.Result {
        guard let selection, let row = rows.first(where: { $0.id == selection }),
              row.node.isDirectory, row.isExpanded != open else { return .ignored }
        onSetExpanded(selection, open)
        return .handled
    }
}

struct FileTreeRowView: View {
    let row: FileTreeRow
    let onToggle: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            disclosure
            icon
            Text(row.node.name)
                .font(.system(size: 13, weight: row.depth == 0 ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(max(0, row.depth - 1)) * 14)
        .contentShape(Rectangle())
        // simultaneous — чтобы одиночный клик выделял строку сразу,
        // а не ждал, не окажется ли он двойным.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if row.node.isDirectory { onToggle(row.id) }
        })
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.node.isDirectory {
            Button { onToggle(row.id) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 12, height: 16)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if row.depth == 0 {
            // Корень проекта — синяя «папка-проект», как у Xcode.
            Image(systemName: "folder.fill.badge.gearshape")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(nsColor: Theme.folderIcon.color))
                .font(.system(size: 13))
                .frame(width: 18)
        } else {
            let icon = row.node.isDirectory ? Theme.folderIcon : Theme.fileIcon(forName: row.node.name)
            Image(systemName: icon.symbol)
                .foregroundStyle(Color(nsColor: icon.color))
                .font(.system(size: 12))
                .frame(width: 18)
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
            SymbolBadge(kind: item.kind)
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
    var size: CGFloat = 16

    var body: some View {
        let badge = Theme.badge(for: kind)
        Text(badge.letter)
            .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
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
