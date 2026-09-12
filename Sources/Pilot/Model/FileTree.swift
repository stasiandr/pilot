import Foundation

/// Дерево папок для боковой панели.
///
/// Строится из уже готового индекса, а не отдельным обходом диска: так
/// в дереве ровно те файлы, что находит ⌘P, с тем же `.gitignore`.
/// Пустых папок в индексе нет — нет их и здесь.
///
/// Узлы — классы: NSOutlineView различает элементы по идентичности объекта.
final class FileTree: @unchecked Sendable {

    final class Node: @unchecked Sendable {
        let name: String
        /// Путь от корня проекта; у корня — пустая строка.
        let relPath: String
        let isDirectory: Bool
        /// Папки впереди, внутри групп — «естественный» порядок Finder'а:
        /// `file2` раньше `file10`.
        fileprivate(set) var children: [Node] = []
        fileprivate(set) weak var parent: Node?

        fileprivate init(name: String, relPath: String, isDirectory: Bool, parent: Node?) {
            self.name = name
            self.relPath = relPath
            self.isDirectory = isDirectory
            self.parent = parent
        }

        /// Цепочка папок от корня (не включая его) до самого узла.
        var ancestors: [Node] {
            var chain: [Node] = []
            var current = parent
            while let node = current, node.parent != nil {
                chain.append(node)
                current = node.parent
            }
            return chain.reversed()
        }
    }

    let root: Node
    let fileCount: Int
    /// Быстрый поиск узла по пути — чтобы подсветить в дереве открытый файл.
    private let lookup: [String: Node]

    private init(root: Node, fileCount: Int, lookup: [String: Node]) {
        self.root = root
        self.fileCount = fileCount
        self.lookup = lookup
    }

    func node(at relPath: String) -> Node? { lookup[relPath] }

    /// Пути — относительные, через `/`, как в `FileIndex.display`.
    /// Синхронно; на 100 000 файлов — десятки миллисекунд, поэтому вызывать вне главного потока.
    static func build(paths: [String]) -> FileTree {
        let root = Node(name: "", relPath: "", isDirectory: true, parent: nil)
        var lookup: [String: Node] = ["": root]
        lookup.reserveCapacity(paths.count + paths.count / 4)
        var fileCount = 0

        for path in paths {
            guard !path.isEmpty, lookup[path] == nil else { continue }

            // Поднимаемся от файла к ближайшей уже существующей папке,
            // затем создаём недостающие звенья сверху вниз.
            var missing: [Substring] = []
            var cursor = Substring(path)
            var parent = root
            while let slash = cursor.lastIndex(of: "/") {
                cursor = cursor[..<slash]
                if let existing = lookup[String(cursor)] {
                    parent = existing
                    break
                }
                missing.append(cursor)
            }
            for dirPath in missing.reversed() {
                let name = dirPath.lastIndex(of: "/").map { dirPath[dirPath.index(after: $0)...] } ?? dirPath
                let dir = Node(name: String(name), relPath: String(dirPath), isDirectory: true, parent: parent)
                parent.children.append(dir)
                lookup[dir.relPath] = dir
                parent = dir
            }

            let name = path.lastIndex(of: "/").map { path[path.index(after: $0)...] } ?? Substring(path)
            let file = Node(name: String(name), relPath: path, isDirectory: false, parent: parent)
            parent.children.append(file)
            lookup[path] = file
            fileCount += 1
        }

        sortRecursively(root)
        return FileTree(root: root, fileCount: fileCount, lookup: lookup)
    }

    private static func sortRecursively(_ node: Node) {
        node.children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for child in node.children where child.isDirectory {
            sortRecursively(child)
        }
    }
}
