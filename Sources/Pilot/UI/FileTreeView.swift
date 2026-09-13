import SwiftUI
import AppKit

/// Боковая панель: дерево папок проекта.
///
/// NSOutlineView, а не SwiftUI `List`: он ленивый (в проекте на 100 000
/// файлов строки создаются только для видимого), даёт штатную клавиатуру
/// (стрелки, ← → сворачивают и разворачивают, набор имени прыгает к файлу)
/// и позволяет программно раскрыть путь до открытого файла.
///
/// У открытой сцены или префаба под файлом раскрывается его иерархия —
/// как окно Hierarchy в Unity. Клик по объекту ставит на него курсор,
/// и инспектор показывает его компоненты.
struct FileTreeView: NSViewRepresentable {
    let tree: FileTree?
    /// Открытый файл — подсвечивается в дереве, папки до него раскрываются.
    let selectedPath: String?
    let root: URL?
    /// Отфильтрованное дерево маленькое и показывается раскрытым целиком.
    var expandAll = false
    /// Изменённые относительно HEAD файлы — подкрашиваются, как в VS Code.
    var gitFiles: [String: GitFileState] = [:]
    /// Показывать ли у сцен и префабов иерархию: только в Unity-проекте
    /// и не под фильтром — там дерево раскрыто целиком.
    var showsHierarchy = false
    /// Иерархия открытого файла (`selectedPath`).
    var hierarchy: UnityHierarchy? = nil
    /// GameObject или вложенный префаб под курсором.
    var selectedObject: Int64? = nil
    let onOpen: (_ relPath: String, _ focusEditor: Bool) -> Void
    var onSelectObject: (_ fileID: Int64, _ focusEditor: Bool) -> Void = { _, _ in }

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
        outline.doubleAction = #selector(Coordinator.rowDoubleClicked(_:))
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
        coordinator.onSelectObject = onSelectObject
        coordinator.root = root
        coordinator.update(tree: tree, selectedPath: selectedPath, expandAll: expandAll,
                           hierarchy: showsHierarchy ? hierarchy : nil, selectedObject: selectedObject,
                           showsHierarchy: showsHierarchy)
        coordinator.update(gitFiles: gitFiles)
    }

    // MARK: - Координатор

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outline: NSOutlineView?
        var onOpen: ((String, Bool) -> Void)?
        var onSelectObject: ((Int64, Bool) -> Void)?
        var root: URL?

        private var tree: FileTree?
        private var shownSelection: String?
        private var shownObject: Int64?
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
        /// Выделение ставим мы сами — это не выбор объекта пользователем.
        private var isSelecting = false

        // Иерархия сцены или префаба — ветка под его файлом.
        private var showsHierarchy = false
        private var hierarchy: UnityHierarchy?
        /// Под каким файлом она висит.
        private var hierarchyPath: String?
        /// Строки иерархии, по одной на узел. Объекты переживают перечитывание
        /// файла после правки — иначе NSOutlineView забыл бы, что раскрыто.
        private var hierarchyItems: [HierarchyItem] = []
        /// Сцены и префабы, чью иерархию свернули руками: сами не раскрываем.
        private var collapsedHierarchies: Set<String> = []
        /// Раскрытые GameObject'ы по файлам: вернулся в префаб — всё как было.
        private var expandedObjects: [String: Set<Int64>] = [:]

        func update(tree newTree: FileTree?, selectedPath: String?, expandAll: Bool,
                    hierarchy newHierarchy: UnityHierarchy?, selectedObject: Int64?, showsHierarchy: Bool) {
            guard let outline else { return }

            if showsHierarchy != self.showsHierarchy {
                self.showsHierarchy = showsHierarchy
                // У каждого файла сцены меняется, есть ли у него стрелка.
                if newTree === tree { outline.reloadData(); restoreExpansion() }
            }

            // Сравнение по идентичности: дерево меняется целиком и редко,
            // а update вызывается на каждое движение курсора.
            let treeChanged = newTree !== tree
            if treeChanged {
                // nil приходит только при смене проекта; пересканирование
                // того же проекта подменяет дерево сразу, минуя nil.
                if newTree == nil { expanded.removeAll() }
                tree = newTree
                outline.reloadData()
                if expandAll {
                    // Раскрытое фильтром — не выбор пользователя: в `expanded`
                    // не пишем, чтобы после фильтра дерево стало как было.
                    isRestoring = true
                    outline.expandItem(nil, expandChildren: true)
                    isRestoring = false
                } else {
                    restoreExpansion()
                }
                shownSelection = nil
            }

            let hierarchyPath = newHierarchy != nil && selectedPath.map(Self.hasHierarchy) == true ? selectedPath : nil
            if treeChanged || newHierarchy !== hierarchy || hierarchyPath != self.hierarchyPath {
                let sameFile = !treeChanged && hierarchyPath == self.hierarchyPath
                adopt(newHierarchy, at: hierarchyPath, treeChanged: treeChanged)
                // Файл перечитали после правки: строки пересоздались, а с ними
                // пропало выделение. Ставим его обратно, не дёргая прокрутку.
                if sameFile { select(path: selectedPath, object: selectedObject, scroll: false) }
            }

            if selectedPath != shownSelection || selectedObject != shownObject {
                shownSelection = selectedPath
                shownObject = selectedObject
                select(path: selectedPath, object: selectedObject, scroll: true)
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

        /// Выделить строку открытого файла, а если под курсором объект его
        /// иерархии и она раскрыта — строку объекта.
        private func select(path: String?, object: Int64?, scroll: Bool) {
            guard let outline else { return }
            isSelecting = true
            defer { isSelecting = false }
            guard let path, let node = tree?.node(at: path) else {
                outline.deselectAll(nil)
                return
            }
            for folder in node.ancestors where !outline.isItemExpanded(folder) {
                outline.expandItem(folder)
            }
            var target: Any = node
            if let object, path == hierarchyPath, let hierarchy, outline.isItemExpanded(node),
               let index = hierarchy.node(forFileID: object) {
                // Как Unity: выделенный объект виден, его предки раскрыты.
                for ancestor in hierarchy.ancestors(of: index) {
                    let item = hierarchyItems[ancestor]
                    if !outline.isItemExpanded(item) {
                        outline.expandItem(item)
                        expandedObjects[path, default: []].insert(item.fileID)
                    }
                }
                target = hierarchyItems[index]
            }
            let row = outline.row(forItem: target)
            guard row >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            guard scroll else { return }

            // scrollRowToVisible прижал бы строку к краю; если она за экраном,
            // ставим её посередине, чтобы было видно соседей по папке.
            let rowRect = outline.rect(ofRow: row)
            let visible = outline.visibleRect
            guard !visible.contains(rowRect) else { return }
            let margin = max(0, (visible.height - rowRect.height) / 2)
            outline.scrollToVisible(rowRect.insetBy(dx: 0, dy: -margin))
        }

        // MARK: Иерархия

        static func hasHierarchy(_ name: String) -> Bool {
            name.hasSuffix(".prefab") || name.hasSuffix(".unity")
        }

        /// Новая иерархия: другой файл открыли или этот перечитали после правки.
        private func adopt(_ newHierarchy: UnityHierarchy?, at path: String?, treeChanged: Bool) {
            guard let outline else { return }
            isRestoring = true
            defer { isRestoring = false }

            // Ветку прежнего файла сворачиваем, пока её строки ещё на месте:
            // NSOutlineView спросит у источника данных детей, которых сейчас не станет.
            let oldPath = hierarchyPath
            let oldNode = treeChanged ? nil : oldPath.flatMap { tree?.node(at: $0) }
            if let oldNode, oldPath != path {
                outline.collapseItem(oldNode)
            }

            let reused = path == oldPath
                ? Dictionary(hierarchyItems.map { ($0.fileID, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
            hierarchyItems = newHierarchy.map { hierarchy in
                hierarchy.nodes.enumerated().map { index, node in
                    let item = reused[node.fileID] ?? HierarchyItem(fileID: node.fileID)
                    item.index = index
                    item.name = node.name
                    item.isPrefab = node.isPrefab
                    item.isActive = node.isActive
                    return item
                }
            } ?? []
            hierarchy = newHierarchy
            hierarchyPath = path

            if let oldNode, oldPath != path { outline.reloadItem(oldNode, reloadChildren: true) }
            guard let path, let fileNode = tree?.node(at: path) else { return }
            outline.reloadItem(fileNode, reloadChildren: true)

            // Открыли сцену или префаб — сразу видно, что внутри.
            if !collapsedHierarchies.contains(path) {
                for folder in fileNode.ancestors where !outline.isItemExpanded(folder) {
                    outline.expandItem(folder)
                }
                outline.expandItem(fileNode)
            }
            guard outline.isItemExpanded(fileNode), let hierarchy else { return }

            // У префаба один корень — он раскрыт, как в режиме префаба Unity.
            // У сцены корней много, раскрываем только то, что раскрывали руками.
            let saved = expandedObjects[path] ?? (path.hasSuffix(".prefab")
                ? Set(hierarchy.roots.map { hierarchy.nodes[$0].fileID }) : [])
            expandedObjects[path] = saved
            func expand(_ nodes: [Int]) {
                for node in nodes where saved.contains(hierarchy.nodes[node].fileID) {
                    outline.expandItem(hierarchyItems[node])
                    expand(hierarchy.nodes[node].children)
                }
            }
            expand(hierarchy.roots)
        }

        /// Строки удалённых объектов NSOutlineView может ещё держать до перечитывания ветки.
        private func node(of item: HierarchyItem) -> UnityHierarchy.Node? {
            guard let hierarchy, item.index < hierarchyItems.count, hierarchyItems[item.index] === item else { return nil }
            return hierarchy.nodes[item.index]
        }

        private func hierarchyChildren(of item: Any?) -> [Int]? {
            if let item = item as? HierarchyItem { return node(of: item)?.children ?? [] }
            if let node = item as? FileTree.Node, !node.isDirectory, node.relPath == hierarchyPath {
                return hierarchy?.roots
            }
            return nil
        }

        /// `Canvas/Panel/Button` — как для `transform.Find`.
        private func hierarchyPath(of item: HierarchyItem) -> String {
            guard let hierarchy, node(of: item) != nil else { return item.name }
            return (hierarchy.ancestors(of: item.index) + [item.index])
                .map { hierarchy.nodes[$0].name }.joined(separator: "/")
        }

        // MARK: Действия

        @objc func rowClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0 else { return }
            if let item = sender.item(atRow: row) as? HierarchyItem {
                select(item, focusEditor: false)
                return
            }
            guard let node = sender.item(atRow: row) as? FileTree.Node else { return }
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

        /// Двойной клик по объекту иерархии раскрывает его — одинарный
        /// уже выбрал объект. Папки раскрываются и одинарным.
        @objc func rowDoubleClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let item = sender.item(atRow: row) as? HierarchyItem,
                  sender.isExpandable(item) else { return }
            if sender.isItemExpanded(item) {
                sender.animator().collapseItem(item)
            } else {
                sender.animator().expandItem(item)
            }
        }

        /// Return: папку раскрыть, файл открыть и уйти в текст.
        func openSelected() {
            guard let outline, outline.selectedRow >= 0 else { return }
            if let item = outline.item(atRow: outline.selectedRow) as? HierarchyItem {
                select(item, focusEditor: true)
                return
            }
            guard let node = outline.item(atRow: outline.selectedRow) as? FileTree.Node else { return }
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
            shownObject = nil
            onOpen?(node.relPath, focusEditor)
        }

        private func select(_ item: HierarchyItem, focusEditor: Bool) {
            // Курсор встанет на объект, и дерево не должно никуда прыгать.
            shownSelection = hierarchyPath
            shownObject = item.fileID
            onSelectObject?(item.fileID, focusEditor)
        }

        /// Стрелки по иерархии ведут за собой инспектор, как в Unity.
        /// По файлам — нет: открытие файла дороже, для него есть Return.
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSelecting, let outline, outline.window?.firstResponder === outline,
                  NSApp.currentEvent?.type == .keyDown, outline.selectedRow >= 0,
                  let item = outline.item(atRow: outline.selectedRow) as? HierarchyItem else { return }
            select(item, focusEditor: false)
        }

        // MARK: Контекстное меню

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0 else { return }
            if let item = outline.item(atRow: outline.clickedRow) as? HierarchyItem {
                let copy = NSMenuItem(title: "Скопировать путь в иерархии", action: #selector(copyHierarchyPath(_:)),
                                      keyEquivalent: "")
                copy.target = self
                copy.representedObject = item
                menu.addItem(copy)
                return
            }
            guard let node = outline.item(atRow: outline.clickedRow) as? FileTree.Node else { return }

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

        @objc private func copyHierarchyPath(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? HierarchyItem else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hierarchyPath(of: item), forType: .string)
        }

        // MARK: Источник данных

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let children = hierarchyChildren(of: item) { return children.count }
            guard let node = node(item), node.isDirectory else { return 0 }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let children = hierarchyChildren(of: item) { return hierarchyItems[children[index]] }
            return node(item)!.children[index]
        }

        /// У сцен и префабов стрелка есть, даже пока они не открыты:
        /// раскрыть — значит открыть файл, иерархия подтянется следом.
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            if let item = item as? HierarchyItem { return !(node(of: item)?.children.isEmpty ?? true) }
            guard let node = item as? FileTree.Node else { return false }
            return node.isDirectory || (showsHierarchy && Self.hasHierarchy(node.name))
        }

        private func node(_ item: Any?) -> FileTree.Node? {
            item == nil ? tree?.root : item as? FileTree.Node
        }

        // MARK: Строки

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let cell = outlineView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
            if let item = item as? HierarchyItem {
                cell.configure(with: item)
                return cell
            }
            guard let node = item as? FileTree.Node else { return nil }
            cell.configure(with: node, git: gitState(of: node))
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            (item as? FileTree.Node)?.name ?? (item as? HierarchyItem)?.name
        }

        func outlineView(_ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer,
                         tableColumn: NSTableColumn?, item: Any, mouseLocation: NSPoint) -> String {
            if let item = item as? HierarchyItem {
                let path = hierarchyPath(of: item)
                return item.isPrefab ? "\(path) — вложенный префаб" : path
            }
            guard let node = item as? FileTree.Node else { return "" }
            guard !node.isDirectory, let state = gitFiles[node.relPath] else { return node.relPath }
            return "\(node.relPath) — \(state.label)"
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isRestoring else { return }
            let object = notification.userInfo?["NSObject"]
            if let item = object as? HierarchyItem, let path = hierarchyPath {
                expandedObjects[path, default: []].insert(item.fileID)
            } else if let node = object as? FileTree.Node {
                if node.isDirectory {
                    expanded.insert(node.relPath)
                } else {
                    collapsedHierarchies.remove(node.relPath)
                    // Раскрыли неоткрытую сцену — открываем, иерархия придёт с разбором.
                    if node.relPath != hierarchyPath { open(node, focusEditor: false) }
                }
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isRestoring else { return }
            let object = notification.userInfo?["NSObject"]
            if let item = object as? HierarchyItem, let path = hierarchyPath {
                expandedObjects[path]?.remove(item.fileID)
            } else if let node = object as? FileTree.Node {
                if node.isDirectory {
                    expanded.remove(node.relPath)
                } else {
                    collapsedHierarchies.insert(node.relPath)
                }
            }
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
        icon.alphaValue = 1
        // Цветные иконки по типу файла, как в навигаторе Xcode.
        let style = node.isDirectory ? Theme.folderIcon : Theme.fileIcon(forName: node.name)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = style.color

        // У папки вместо буквы точка: бледно-жёлтое имя на стекле сайдбара
        // почти не отличить от белого, а изменение внутри видно и так.
        if let state {
            badge.stringValue = node.isDirectory ? "•" : state.letter
        } else {
            badge.stringValue = ""
        }
        gitColor = state.map(Theme.git)
        dimmed = false
        applyGitColor()
    }

    /// Объект иерархии сцены или префаба. Выключенный — бледный, как в Unity.
    func configure(with item: HierarchyItem) {
        label.stringValue = item.name
        let style = item.isPrefab ? Theme.prefabInstanceIcon : Theme.gameObjectIcon
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = style.color
        icon.alphaValue = item.isActive ? 1 : 0.45
        badge.stringValue = ""
        gitColor = nil
        dimmed = !item.isActive
        applyGitColor()
    }

    /// Ячейки переиспользуются — цвет задаётся и у неизменённых, иначе
    /// файл унаследует жёлтый от предыдущего хозяина ячейки.
    private var gitColor: NSColor?
    /// Выключенный GameObject.
    private var dimmed = false

    /// На синем фоне выделения цветной текст не читается — там белый.
    /// Фон строки меняется при выделении и при смене фокуса окна.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyGitColor() }
    }

    private func applyGitColor() {
        let emphasized = backgroundStyle == .emphasized
        let color = emphasized ? nil : gitColor
        label.textColor = color ?? (dimmed && !emphasized ? .tertiaryLabelColor : .labelColor)
        badge.textColor = color ?? .secondaryLabelColor
    }
}

// MARK: - Outline с клавишей Return

private final class FileOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    /// Штатная стрелка — мишень в десяток точек. Ловим клик на всю высоту
    /// строки и с запасом по бокам: от отступа уровня до начала иконки.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row >= 0, let item = item(atRow: row), isExpandable(item) {
            let arrow = frameOfOutlineCell(atRow: row)
            let rowRect = rect(ofRow: row)
            let target = NSRect(x: arrow.minX - 6, y: rowRect.minY,
                                width: arrow.width + 10, height: rowRect.height)
            if !arrow.isEmpty, target.contains(point) {
                // ⌥ — раскрыть или свернуть всё вложенное, как у штатной стрелки.
                let recursive = event.modifierFlags.contains(.option)
                if isItemExpanded(item) {
                    animator().collapseItem(item, collapseChildren: recursive)
                } else {
                    animator().expandItem(item, expandChildren: recursive)
                }
                return
            }
        }
        super.mouseDown(with: event)
    }

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

// MARK: - Строка иерархии

/// GameObject или вложенный префаб в ветке сцены. Объект, а не структура:
/// NSOutlineView помнит раскрытое и выделенное по идентичности строки.
final class HierarchyItem: NSObject {
    let fileID: Int64
    /// Узел в текущей `UnityHierarchy`.
    var index = 0
    var name = ""
    var isPrefab = false
    var isActive = true

    init(fileID: Int64) {
        self.fileID = fileID
    }
}
