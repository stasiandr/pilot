import SwiftUI
import AppKit

/// Боковая панель: дерево папок проекта.
///
/// NSOutlineView, а не SwiftUI `List`: он ленивый (в проекте на 100 000
/// файлов строки создаются только для видимого), даёт штатную клавиатуру
/// (стрелки, ← → сворачивают и разворачивают, набор имени прыгает к файлу)
/// и позволяет программно раскрыть путь до открытого файла.
struct FileTreeView: NSViewRepresentable {
    let tree: FileTree?
    /// Открытый файл — подсвечивается в дереве, папки до него раскрываются.
    let selectedPath: String?
    let root: URL?
    /// Изменённые относительно HEAD файлы — подкрашиваются, как в VS Code.
    let gitFiles: [String: GitFileState]
    let onOpen: (_ relPath: String, _ focusEditor: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.floatsGroupRows = false
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.indentationPerLevel = 13

        let coordinator = context.coordinator
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.action = #selector(Coordinator.rowClicked(_:))
        outline.onReturn = { [weak coordinator] in coordinator?.openSelected() }
        outline.menu = coordinator.makeContextMenu()

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpen = onOpen
        coordinator.root = root
        coordinator.update(tree: tree, selectedPath: selectedPath)
        coordinator.update(gitFiles: gitFiles)
    }

    // MARK: - Координатор

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outline: NSOutlineView?
        var onOpen: ((String, Bool) -> Void)?
        var root: URL?

        private var tree: FileTree?
        private var shownSelection: String?
        private var gitFiles: [String: GitFileState] = [:]
        /// Папки, внутри которых что-то изменено, — чтобы изменение было
        /// видно и в свёрнутом дереве.
        private var gitFolders: [String: GitFileState] = [:]
        /// Раскрытые папки по путям, а не по узлам: при пересканировании
        /// дерево собирается заново, а раскрытое должно остаться раскрытым.
        private var expanded: Set<String> = []
        /// Раскрытие, которое делаем мы сами, не должно попадать в `expanded`
        /// как пользовательское — иначе переоткрытие проекта раскроет всё подряд.
        private var isRestoring = false

        func update(tree newTree: FileTree?, selectedPath: String?) {
            guard let outline else { return }

            // Сравнение по идентичности: дерево меняется целиком и редко,
            // а update вызывается на каждое движение курсора.
            if newTree !== tree {
                // nil приходит только при смене проекта; пересканирование
                // того же проекта подменяет дерево сразу, минуя nil.
                if newTree == nil { expanded.removeAll() }
                tree = newTree
                outline.reloadData()
                restoreExpansion()
                shownSelection = nil
            }

            if selectedPath != shownSelection {
                shownSelection = selectedPath
                reveal(selectedPath)
            }
        }

        /// Статус меняется редко (на возврате в приложение), а дерево может
        /// быть огромным — перекрашиваем только уже созданные строки,
        /// остальные получат цвет, когда до них доскроллят.
        func update(gitFiles newFiles: [String: GitFileState]) {
            guard newFiles != gitFiles, let outline else { return }
            gitFiles = newFiles
            gitFolders = Self.folderStates(newFiles)
            outline.enumerateAvailableRowViews { rowView, row in
                guard let node = outline.item(atRow: row) as? FileTree.Node,
                      let cell = rowView.view(atColumn: 0) as? FileCell else { return }
                cell.configure(with: node, git: self.gitState(of: node))
            }
        }

        private func gitState(of node: FileTree.Node) -> GitFileState? {
            node.isDirectory ? gitFolders[node.relPath] : gitFiles[node.relPath]
        }

        /// Цвет папки — по самому важному изменению внутри:
        /// конфликт важнее правки, правка важнее новых файлов.
        private static func folderStates(_ files: [String: GitFileState]) -> [String: GitFileState] {
            func rank(_ state: GitFileState) -> Int {
                switch state {
                case .conflicted:        return 2
                case .added, .untracked: return 0
                default:                 return 1
                }
            }
            var folders: [String: GitFileState] = [:]
            for (path, state) in files {
                let folderState: GitFileState = rank(state) == 0 ? .added : (rank(state) == 2 ? .conflicted : .modified)
                var cursor = Substring(path)
                while let slash = cursor.lastIndex(of: "/") {
                    cursor = cursor[..<slash]
                    let key = String(cursor)
                    if let existing = folders[key], rank(existing) >= rank(folderState) { continue }
                    folders[key] = folderState
                }
            }
            return folders
        }

        private func restoreExpansion() {
            guard let outline, let tree, !expanded.isEmpty else { return }
            isRestoring = true
            defer { isRestoring = false }
            // Родители раньше детей: свёрнутую папку не раскрыть изнутри.
            let paths = expanded.sorted { $0.count < $1.count }
            var alive: Set<String> = []
            for path in paths {
                guard let node = tree.node(at: path), node.isDirectory,
                      node.parent.map({ $0.parent == nil || outline.isItemExpanded($0) }) ?? false
                else { continue }
                outline.expandItem(node)
                alive.insert(path)
            }
            expanded = alive
        }

        private func reveal(_ path: String?) {
            guard let outline else { return }
            guard let path, let node = tree?.node(at: path) else {
                outline.deselectAll(nil)
                return
            }
            for folder in node.ancestors where !outline.isItemExpanded(folder) {
                outline.expandItem(folder)
            }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

            // scrollRowToVisible прижал бы строку к краю; если она за экраном,
            // ставим её посередине, чтобы было видно соседей по папке.
            let rowRect = outline.rect(ofRow: row)
            let visible = outline.visibleRect
            guard !visible.contains(rowRect) else { return }
            let margin = max(0, (visible.height - rowRect.height) / 2)
            outline.scrollToVisible(rowRect.insetBy(dx: 0, dy: -margin))
        }

        // MARK: Действия

        @objc func rowClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? FileTree.Node else { return }
            if node.isDirectory {
                // Клик по папке раскрывает её — стрелочка слишком мелкая мишень.
                if sender.isItemExpanded(node) {
                    sender.animator().collapseItem(node)
                } else {
                    sender.animator().expandItem(node)
                }
            } else {
                open(node, focusEditor: false)
            }
        }

        /// Return: папку раскрыть, файл открыть и уйти в текст.
        func openSelected() {
            guard let outline, outline.selectedRow >= 0,
                  let node = outline.item(atRow: outline.selectedRow) as? FileTree.Node else { return }
            if node.isDirectory {
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            } else {
                open(node, focusEditor: true)
            }
        }

        private func open(_ node: FileTree.Node, focusEditor: Bool) {
            // Отмечаем заранее: когда документ загрузится, дерево уже
            // выделило эту строку и прыгать никуда не должно.
            shownSelection = node.relPath
            onOpen?(node.relPath, focusEditor)
        }

        // MARK: Контекстное меню

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? FileTree.Node else { return }

            let reveal = NSMenuItem(title: "Показать в Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            let copyRel = NSMenuItem(title: "Скопировать путь", action: #selector(copyPath(_:)), keyEquivalent: "")
            let copyAbs = NSMenuItem(title: "Скопировать полный путь", action: #selector(copyAbsolutePath(_:)), keyEquivalent: "")
            for item in [reveal, copyRel, copyAbs] {
                item.target = self
                item.representedObject = node
                menu.addItem(item)
                if item === reveal { menu.addItem(.separator()) }
            }
        }

        private func url(for sender: NSMenuItem) -> (URL, FileTree.Node)? {
            guard let root, let node = sender.representedObject as? FileTree.Node else { return nil }
            return (root.appendingPathComponent(node.relPath), node)
        }

        @objc private func revealInFinder(_ sender: NSMenuItem) {
            guard let (url, _) = url(for: sender) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc private func copyPath(_ sender: NSMenuItem) {
            guard let (_, node) = url(for: sender) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.relPath, forType: .string)
        }

        @objc private func copyAbsolutePath(_ sender: NSMenuItem) {
            guard let (url, _) = url(for: sender) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }

        // MARK: Источник данных

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            node(item)?.children.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            node(item)!.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileTree.Node)?.isDirectory ?? false
        }

        private func node(_ item: Any?) -> FileTree.Node? {
            item == nil ? tree?.root : item as? FileTree.Node
        }

        // MARK: Строки

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileTree.Node else { return nil }
            let cell = outlineView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
            cell.configure(with: node, git: gitState(of: node))
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            (item as? FileTree.Node)?.name
        }

        func outlineView(_ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer,
                         tableColumn: NSTableColumn?, item: Any, mouseLocation: NSPoint) -> String {
            guard let node = item as? FileTree.Node else { return "" }
            guard !node.isDirectory, let state = gitFiles[node.relPath] else { return node.relPath }
            return "\(node.relPath) — \(state.label)"
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isRestoring, let node = notification.userInfo?["NSObject"] as? FileTree.Node else { return }
            expanded.insert(node.relPath)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileTree.Node else { return }
            expanded.remove(node.relPath)
        }
    }
}

// MARK: - Строка дерева

private final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// Статус git справа: буква у файла (M, A, ?, U, R), точка у папки.
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(icon)
        addSubview(label)
        addSubview(badge)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func configure(with node: FileTree.Node, git state: GitFileState?) {
        label.stringValue = node.name
        let symbol = node.isDirectory ? "folder.fill" : Workspace.icon(forPath: node.name)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = node.isDirectory ? Theme.sidebarFolder : Theme.sidebarFile

        // У папки вместо буквы точка: бледно-жёлтое имя на стекле сайдбара
        // почти не отличить от белого, а изменение внутри видно и так.
        if let state {
            badge.stringValue = node.isDirectory ? "•" : state.letter
        } else {
            badge.stringValue = ""
        }
        gitColor = state.map(Theme.git)
        applyGitColor()
    }

    /// Ячейки переиспользуются — цвет задаётся и у неизменённых, иначе
    /// файл унаследует жёлтый от предыдущего хозяина ячейки.
    private var gitColor: NSColor?

    /// На синем фоне выделения цветной текст не читается — там белый.
    /// Фон строки меняется при выделении и при смене фокуса окна.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyGitColor() }
    }

    private func applyGitColor() {
        let color = backgroundStyle == .emphasized ? nil : gitColor
        label.textColor = color ?? .labelColor
        badge.textColor = color ?? .secondaryLabelColor
    }
}

// MARK: - Outline с клавишей Return

private final class FileOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 — Return, 76 — Enter на цифровом блоке.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Правый клик не должен сбрасывать выделение открытого файла:
    /// меню работает с `clickedRow`, а подсветка остаётся где была.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return row(at: point) >= 0 ? super.menu(for: event) : nil
    }
}
