import SwiftUI
import AppKit

/// Jump bar над редактором, как в Xcode: назад/вперёд и путь до символа
/// под курсором. Каждый сегмент — меню его соседей: папка показывает
/// содержимое родителя, файл — файлы рядом, символ — структуру файла.
struct JumpBar: View {
    @ObservedObject var workspace: Workspace

    /// Больше пунктов в меню не кладём: NSMenu на тысячи строк открывается заметно.
    private let menuLimit = 400

    var body: some View {
        HStack(spacing: 0) {
            history
            Rectangle()
                .fill(Color(nsColor: Theme.separator))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) { components }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: Theme.editorBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
    }

    // MARK: - Назад / вперёд

    private var history: some View {
        HStack(spacing: 2) {
            Button { workspace.goBack() } label: {
                Image(systemName: "chevron.left").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .disabled(!workspace.canGoBack)
            .help("Назад (⌘[)")
            Button { workspace.goForward() } label: {
                Image(systemName: "chevron.right").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .disabled(!workspace.canGoForward)
            .help("Вперёд (⌘])")
        }
        .font(.system(size: 11, weight: .semibold))
        .buttonStyle(.borderless)
    }

    // MARK: - Сегменты пути

    @ViewBuilder
    private var components: some View {
        if let root = workspace.root {
            segment {
                projectMenu
            } label: {
                SegmentLabel(symbol: "folder.fill.badge.gearshape", color: Theme.folderIcon.color,
                             title: root.lastPathComponent)
            }

            if let document = workspace.document {
                let path = workspace.relativePath(for: document.url)
                let insideRoot = document.url.path.hasPrefix(root.path + "/")
                let parts = insideRoot ? path.split(separator: "/").map(String.init)
                                       : [document.url.lastPathComponent]

                ForEach(Array(parts.enumerated()), id: \.offset) { position, name in
                    let parent = parts[..<position].joined(separator: "/")
                    let isFile = position == parts.count - 1
                    chevron
                    segment {
                        if insideRoot { siblingsMenu(parent: parent) }
                    } label: {
                        let icon = isFile ? Theme.fileIcon(forName: name) : Theme.folderIcon
                        SegmentLabel(symbol: icon.symbol, color: icon.color, title: name)
                    }
                }

                chevron
                symbolSegment(document)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 1)
            .accessibilityHidden(true)
    }

    private func segment<Content: View, Label: View>(@ViewBuilder content: () -> Content,
                                                     @ViewBuilder label: () -> Label) -> some View {
        Menu(content: content, label: label)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    @ViewBuilder
    private func symbolSegment(_ document: LoadedDocument) -> some View {
        segment {
            ForEach(document.outline.prefix(menuLimit)) { item in
                Button {
                    workspace.jump(to: item)
                } label: {
                    Label(String(repeating: "   ", count: min(item.depth, 6)) + item.name,
                          systemImage: item.kind.icon)
                }
            }
        } label: {
            if let item = workspace.currentOutlineItem {
                SegmentLabel(badge: item.kind, keyword: item.keyword, title: item.name)
            } else {
                SegmentLabel(title: document.outline.isEmpty ? "Нет структуры" : "Нет выделения",
                             dimmed: true)
            }
        }
        .disabled(document.outline.isEmpty)
    }

    // MARK: - Меню

    @ViewBuilder
    private var projectMenu: some View {
        ForEach(workspace.recentRoots.prefix(10), id: \.path) { url in
            Button {
                workspace.open(root: url)
            } label: {
                Label(url.lastPathComponent, systemImage: url == workspace.root ? "checkmark" : "folder")
            }
        }
        Divider()
        Button("Открыть папку…") { workspace.promptForFolder() }
    }

    /// Содержимое папки. Подпапки — подменю, как в Xcode, но только на один
    /// уровень: SwiftUI строит меню целиком, и рекурсия по большому проекту
    /// собирала бы тысячи пунктов ради одного клика.
    @ViewBuilder
    private func siblingsMenu(parent: String) -> some View {
        let siblings = workspace.fileTree?.node(at: parent)?.children ?? []
        ForEach(siblings.prefix(menuLimit), id: \.relPath) { node in
            if node.isDirectory {
                Menu {
                    ForEach(node.children.prefix(menuLimit), id: \.relPath) { child in
                        if child.isDirectory {
                            Label(child.name, systemImage: Theme.folderIcon.symbol)
                        } else {
                            fileButton(child)
                        }
                    }
                } label: {
                    Label(node.name, systemImage: Theme.folderIcon.symbol)
                }
            } else {
                fileButton(node)
            }
        }
        if siblings.count > menuLimit {
            Text("… и ещё \(siblings.count - menuLimit)")
        }
    }

    private func fileButton(_ node: FileTree.Node) -> some View {
        Button {
            guard let root = workspace.root else { return }
            workspace.navigate(to: NavTarget(url: root.appendingPathComponent(node.relPath), range: nil))
        } label: {
            Label(node.name, systemImage: Theme.fileIcon(forName: node.name).symbol)
        }
    }
}

/// Иконка + подпись сегмента jump bar.
struct SegmentLabel: View {
    var symbol: String? = nil
    var color: NSColor = .secondaryLabelColor
    var badge: OutlineKind? = nil
    var keyword: String? = nil
    let title: String
    var dimmed = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if let badge {
                    SymbolBadge(kind: badge, keyword: keyword, size: 14)
                } else if let symbol {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: color))
                }
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
