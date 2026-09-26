import Foundation

/// Иерархия сцены или префаба — как окно Hierarchy в Unity: GameObject'ы
/// и вложенные префабы, дети в порядке `m_Children`.
///
/// Строится по уже разобранному файлу, в фоне, вместе с ним; неизменяема.
/// Новый разбор — новая иерархия: по идентичности дерево понимает, что
/// пора перечитать ветку.
final class UnityHierarchy: @unchecked Sendable {   // неизменяема после build

    struct Node {
        /// GameObject или PrefabInstance.
        var fileID: Int64
        var name: String
        var isPrefab: Bool
        var isActive: Bool
        var parent: Int?
        var children: [Int] = []
    }

    let nodes: [Node]
    let roots: [Int]
    /// GameObject, его Transform, вложенный префаб и его заглушки → узел.
    private let nodeByFileID: [Int64: Int]

    private init(nodes: [Node], roots: [Int], nodeByFileID: [Int64: Int]) {
        self.nodes = nodes
        self.roots = roots
        self.nodeByFileID = nodeByFileID
    }

    func node(forFileID fileID: Int64) -> Int? { nodeByFileID[fileID] }

    /// Узел, к которому относится объект файла: сам GameObject, любой его
    /// компонент, вложенный префаб или заглушка из него.
    func node(forObjectAt index: Int, in file: UnityYAMLFile) -> Int? {
        let object = file.objects[index]
        if let node = nodeByFileID[object.fileID] { return node }
        if let go = object.gameObject, go != 0 { return nodeByFileID[go] }
        return nil
    }

    /// Предки узла от корня. `budget` страхует от циклов в битом файле.
    func ancestors(of node: Int) -> [Int] {
        var chain: [Int] = []
        var current = nodes[node].parent
        var budget = 256
        while let parent = current, budget > 0 {
            chain.append(parent)
            current = nodes[parent].parent
            budget -= 1
        }
        return chain.reversed()
    }

    // MARK: - Сборка

    /// `nil` — в файле нет ни GameObject'ов, ни вложенных префабов:
    /// материал, ScriptableObject, настройки.
    static func build(file: UnityYAMLFile, resolve: UnityYAMLFile.Resolver) -> UnityHierarchy? {
        let objects = file.objects
        var nodes: [Node] = []
        var byFileID: [Int64: Int] = [:]

        for object in objects where !object.stripped {
            if object.isGameObject {
                byFileID[object.fileID] = nodes.count
                nodes.append(Node(fileID: object.fileID, name: object.name ?? "GameObject",
                                  isPrefab: false, isActive: !object.isInactive))
            } else if object.isPrefabInstance {
                byFileID[object.fileID] = nodes.count
                nodes.append(Node(fileID: object.fileID, name: file.displayName(of: object, resolve: resolve),
                                  isPrefab: true, isActive: true))
            }
        }
        guard !nodes.isEmpty else { return nil }

        // Transform'ы — к своим GameObject'ам, заглушки — к своему префабу:
        // m_Father, m_TransformParent и m_Children ссылаются именно на них.
        var transformOf: [Int: Int] = [:]   // узел GameObject'а → индекс его Transform'а
        var sceneRoots: [Int64]?
        for (i, object) in objects.enumerated() {
            if object.stripped {
                if let instance = object.prefabInstance, let node = byFileID[instance] {
                    byFileID[object.fileID] = node
                }
            } else if object.father != nil, let go = object.gameObject, let node = byFileID[go] {
                byFileID[object.fileID] = node
                transformOf[node] = i
            } else if object.typeName == "SceneRoots", let roots = object.children {
                sceneRoots = roots
            }
        }

        // Родители. Ссылка в никуда — пусть лучше будет корнем, чем пропадёт.
        for node in nodes.indices {
            let parentID: Int64?
            if nodes[node].isPrefab {
                parentID = objects[file.index(ofFileID: nodes[node].fileID)!].transformParent
            } else {
                parentID = transformOf[node].flatMap { objects[$0].father }
            }
            if let parentID, parentID != 0, let parent = byFileID[parentID], parent != node {
                nodes[node].parent = parent
            }
        }

        // Дети — в порядке m_Children родителя; кого там нет (добавленное
        // в чужой вложенный префаб), ставим следом в порядке файла.
        var childrenOf: [[Int]] = Array(repeating: [], count: nodes.count)
        var roots: [Int] = []
        for node in nodes.indices {
            if let parent = nodes[node].parent { childrenOf[parent].append(node) } else { roots.append(node) }
        }
        for parent in nodes.indices where childrenOf[parent].count > 1 {
            guard let t = transformOf[parent], let listed = objects[t].children else { continue }
            childrenOf[parent] = ordered(childrenOf[parent], by: listed, byFileID)
        }
        for node in nodes.indices { nodes[node].children = childrenOf[node] }

        // Корни: SceneRoots (Unity 2022+), иначе m_RootOrder, иначе порядок файла.
        if let sceneRoots {
            roots = ordered(roots, by: sceneRoots, byFileID)
        } else if roots.count > 1 {
            func rootOrder(_ node: Int) -> Int {
                let object = nodes[node].isPrefab
                    ? file.object(nodes[node].fileID)
                    : transformOf[node].map { objects[$0] }
                return object?.rootOrder ?? Int.max
            }
            roots = roots.enumerated()
                .sorted { (rootOrder($0.element), $0.offset) < (rootOrder($1.element), $1.offset) }
                .map(\.element)
        }
        return UnityHierarchy(nodes: nodes, roots: roots, nodeByFileID: byFileID)
    }

    /// Узлы в порядке списка ссылок; не попавшие в список — в конце, как были.
    private static func ordered(_ nodes: [Int], by list: [Int64], _ byFileID: [Int64: Int]) -> [Int] {
        var position: [Int: Int] = [:]
        for (i, id) in list.enumerated() {
            if let node = byFileID[id], position[node] == nil { position[node] = i }
        }
        return nodes.enumerated()
            .sorted { (position[$0.element] ?? Int.max, $0.offset) < (position[$1.element] ?? Int.max, $1.offset) }
            .map(\.element)
    }
}
