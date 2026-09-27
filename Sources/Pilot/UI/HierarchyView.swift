import SwiftUI

/// Иерархия вызовов или типов — дерево, которое раскрывается по уровням:
/// каждый уровень — отдельный вопрос к Rustlyn (`key` узла называет символ
/// и переживает перекомпиляцию), так что глубина не стоит ничего, пока её
/// не раскрыли.
@MainActor
final class HierarchyModel: ObservableObject {
    enum Kind { case calls, types }
    /// Куда растёт дерево: к вызывающим или к вызываемым, к базовым или к наследникам.
    enum Direction: Hashable { case callers, callees, supertypes, subtypes }

    final class Node: ObservableObject, Identifiable {
        let id = UUID()
        let item: RustlynHierarchyItem
        /// Вызов: где именно (файл и места); у иерархии типов — `nil`.
        let call: RustlynCall?
        let depth: Int
        @Published var children: [Node]?
        @Published var expanded = false
        @Published var loading = false

        init(item: RustlynHierarchyItem, call: RustlynCall? = nil, depth: Int) {
            self.item = item
            self.call = call
            self.depth = depth
        }
    }

    let kind: Kind
    let root: Node
    @Published var direction: Direction
    private let rustlyn: Rustlyn
    private let queue: DispatchQueue

    init(kind: Kind, root: RustlynHierarchyItem, rustlyn: Rustlyn, queue: DispatchQueue) {
        self.kind = kind
        self.root = Node(item: root, depth: 0)
        self.direction = kind == .calls ? .callers : .subtypes
        self.rustlyn = rustlyn
        self.queue = queue
        expand(self.root)
    }

    var directions: [Direction] {
        kind == .calls ? [.callers, .callees] : [.subtypes, .supertypes]
    }

    func setDirection(_ new: Direction) {
        guard new != direction else { return }
        direction = new
        root.children = nil
        root.expanded = false
        expand(root)
    }

    /// Раскрыть или свернуть; дети спрашиваются один раз.
    func toggle(_ node: Node) {
        if node.expanded { node.expanded = false } else { expand(node) }
    }

    private func expand(_ node: Node) {
        node.expanded = true
        guard node.children == nil, !node.loading else { return }
        node.loading = true
        let key = node.item.key, direction = direction, rustlyn = rustlyn, depth = node.depth + 1
        queue.async {
            let children: [Node]
            switch direction {
            case .callers:
                children = (rustlyn.incomingCalls(key) ?? []).map { Node(item: $0.item, call: $0, depth: depth) }
            case .callees:
                children = (rustlyn.outgoingCalls(key) ?? []).map { Node(item: $0.item, call: $0, depth: depth) }
            case .supertypes:
                children = (rustlyn.supertypes(key) ?? []).map { Node(item: $0, depth: depth) }
            case .subtypes:
                children = (rustlyn.subtypes(key) ?? []).map { Node(item: $0, depth: depth) }
            }
            DispatchQueue.main.async {
                // Направление успели сменить — ответ уже не про это дерево.
                guard self.direction == direction else { return }
                node.children = children
                node.loading = false
            }
        }
    }

    /// Куда вести по щелчку: у вызывающего — на сам вызов, у остальных — на
    /// объявление.
    func target(of node: Node) -> NavTarget? {
        if direction == .callers, let call = node.call, let url = call.url, let first = call.ranges.first {
            return NavTarget(url: url, range: first)
        }
        return node.item.target?.navTarget
    }

    /// Строки дерева по порядку — список рисует их плоско, с отступами.
    var rows: [Node] {
        var result: [Node] = []
        func walk(_ node: Node) {
            result.append(node)
            guard node.expanded, let children = node.children else { return }
            children.forEach(walk)
        }
        walk(root)
        return result
    }
}

struct HierarchyNavigator: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: HierarchyModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { model.direction }, set: { model.setDirection($0) })) {
                ForEach(model.directions, id: \.self) { direction in
                    Text(title(direction)).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            List(model.rows) { node in
                HierarchyRow(node: node, model: model) {
                    if let target = model.target(of: node) { workspace.navigate(to: target) }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func title(_ direction: HierarchyModel.Direction) -> String {
        switch direction {
        case .callers: return L("Кто вызывает")
        case .callees: return L("Что вызывает")
        case .supertypes: return L("Базовые")
        case .subtypes: return L("Наследники")
        }
    }
}

private struct HierarchyRow: View {
    @ObservedObject var node: HierarchyModel.Node
    let model: HierarchyModel
    let open: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(node.depth) * 14, height: 1)
            Button { model.toggle(node) } label: {
                Group {
                    if node.loading {
                        ProgressView().controlSize(.mini)
                    } else if node.children?.isEmpty == true {
                        Color.clear
                    } else {
                        Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(node.item.name).font(.system(size: 13, weight: node.depth == 0 ? .semibold : .regular))
                        if node.call?.throughBase == true {
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help(L("Вызов через базовый метод или интерфейс — может дойти сюда, а может нет"))
                        }
                        if let count = node.call?.ranges.count, count > 1 {
                            Text("×\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    Text(node.item.container.isEmpty ? node.item.detail : node.item.container)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.target(of: node) == nil)
            .help(node.item.detail)
        }
        .padding(.vertical, 1)
    }
}
