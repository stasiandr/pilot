import Foundation

/// Дерево файлов для навигатора.
///
/// Строится из плоского списка путей индекса — в фоне, одним проходом.
/// Дети каждой папки сортируются лениво, при первом раскрытии: на проекте
/// в 100 000 файлов сортировать всё дерево заранее незачем, человек
/// раскроет от силы пару десятков папок.
///
/// После передачи на главный поток дерево трогает только он (ленивая
/// сортировка мутирует узел), отсюда @unchecked Sendable.
final class FileTreeNode: @unchecked Sendable {
    let name: String
    /// Путь относительно корня; у корня — пустая строка. Он же id строки.
    let path: String
    let isDirectory: Bool

    private var children: [FileTreeNode] = []
    /// Только у папок и только для сборки: быстрый поиск подпапки по имени.
    private var subdirectories: [String: FileTreeNode] = [:]
    private var isSorted = false

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    static func build<S: Sequence>(rootName: String, paths: S) -> FileTreeNode where S.Element == String {
        let root = FileTreeNode(name: rootName, path: "", isDirectory: true)
        for path in paths { root.insert(path) }
        return root
    }

    private func insert(_ path: String) {
        var node = self
        var start = path.startIndex
        while let slash = path[start...].firstIndex(of: "/") {
            node = node.subdirectory(named: String(path[start..<slash]),
                                     path: String(path[..<slash]))
            start = path.index(after: slash)
        }
        node.children.append(FileTreeNode(name: String(path[start...]), path: path, isDirectory: false))
    }

    private func subdirectory(named name: String, path: String) -> FileTreeNode {
        if let existing = subdirectories[name] { return existing }
        let dir = FileTreeNode(name: name, path: path, isDirectory: true)
        subdirectories[name] = dir
        children.append(dir)
        return dir
    }

    /// Сначала папки, затем файлы; внутри — «человеческий» порядок,
    /// как в Finder: file2 раньше file10.
    var sortedChildren: [FileTreeNode] {
        if !isSorted {
            children.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            isSorted = true
        }
        return children
    }

    /// Строки навигатора в порядке показа: сам узел и содержимое раскрытых
    /// папок. `expandAll` — для отфильтрованного дерева, где видно всё.
    func flatten(expanded: Set<String>, expandAll: Bool = false) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        func visit(_ node: FileTreeNode, depth: Int) {
            let isOpen = node.isDirectory && (expandAll || expanded.contains(node.path))
            rows.append(FileTreeRow(node: node, depth: depth, isExpanded: isOpen))
            guard isOpen else { return }
            for child in node.sortedChildren { visit(child, depth: depth + 1) }
        }
        visit(self, depth: 0)
        return rows
    }

    /// Папки, которые надо раскрыть, чтобы файл стал виден:
    /// "a/b/c.swift" → ["", "a", "a/b"].
    static func ancestors(of path: String) -> [String] {
        var result = [""]
        var index = path.startIndex
        while let slash = path[index...].firstIndex(of: "/") {
            result.append(String(path[..<slash]))
            index = path.index(after: slash)
        }
        return result
    }

    /// Непосредственное содержимое папки по пути — для меню jump bar.
    func children(ofDirectory dirPath: String) -> [FileTreeNode] {
        var node = self
        if !dirPath.isEmpty {
            for part in dirPath.split(separator: "/") {
                guard let next = node.subdirectories[String(part)] else { return [] }
                node = next
            }
        }
        return node.sortedChildren
    }
}

struct FileTreeRow: Identifiable {
    let node: FileTreeNode
    let depth: Int
    let isExpanded: Bool
    var id: String { node.path }
}
