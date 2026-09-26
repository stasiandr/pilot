import AppKit

/// Граф «откуда берётся значение»: поле, места, где в него пишут, и то, из
/// чего складывается записанное, — дальше по тем же правилам. Через сеть
/// тоже, если её описывает расширение проекта (`DatagramRules`): поле
/// сетевой структуры в одной половине пары продолжается тем же полем в
/// другой, где её заполняют перед отправкой, а цикл по типу-приёмнику
/// (`PacketFilter<T>`) срабатывает, когда вторая половина шлёт `T`.
///
/// Раскрывается лениво: узел по клику спрашивает компилятор своего проекта.
/// Всё статически, по коду.
/// Что графу нужно от проекта: компилятор, индекс, очередь запросов к
/// компилятору и вторая половина пары. Это окно проекта (`Workspace`) —
/// или проект, поднятый без окна (`HeadlessGraph`).
@MainActor
protocol GraphProject: AnyObject {
    var root: URL? { get }
    var rustlyn: Rustlyn? { get }
    var symbolIndex: SymbolIndex? { get }
    var referenceQueue: DispatchQueue { get }
    var partner: URL? { get }
    /// Правила расширений проекта: сетевые переходы графа — по ним.
    var rules: ProjectRules { get }
    func openTexts() -> [URL: String]
}

extension Workspace: GraphProject {}

@MainActor
final class ValueGraph: ObservableObject {

    struct Declaration: Equatable, Sendable {
        var url: URL
        var line: Int
        var character: Int
        var length: Int
        /// Полное имя: `Game.Health.Value`.
        var name: String

        var shortName: String { name.split(separator: ".").last.map(String.init) ?? name }
        /// `Game.Health.Value` → `Health`.
        var typeName: String? {
            let parts = name.split(separator: ".")
            return parts.count >= 2 ? String(parts[parts.count - 2]) : nil
        }
        var title: String { [typeName, shortName].compactMap { $0 }.joined(separator: ".") }
    }

    struct Node: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Поле или свойство — раскрывается в места записи.
            case value(Declaration)
            /// Компонент целиком — раскрывается в Set, Add и Remove.
            case component(String)
            /// Место в коде: запись, Set/Remove, отправка, return, вызов.
            case site
            /// Условие, при котором место выполняется: фильтр системы.
            case condition
            /// Приход датаграммы — раскрывается в её отправки во второй половине.
            case arrival(String)
            /// Переход через сеть к той же датаграмме во второй половине.
            case network
            /// Вызов — раскрывается в то, что метод возвращает.
            case call(Declaration?)
            /// Параметр — раскрывается в аргументы в местах вызова.
            case parameter(method: Declaration?, index: Int)
            /// Имя, которое не удалось разрешить.
            case unknown
        }
        enum State: Equatable {
            case collapsed
            case loading
            case expanded
            case failed(String)
        }

        let id: String
        var kind: Kind
        var title: String
        var subtitle: String
        var project: URL
        var url: URL?
        /// С нуля.
        var line: Int?
        /// Строки кода вокруг места, с разметкой для подсветки.
        var preview: [FilePreview.Line] = []
        /// Весь метод — когда превью раскрыли.
        var fullPreview: [FilePreview.Line] = []
        var showsFull = false
        /// Пометка: «меняет прежнее значение», «через mult».
        var note: String?
        var state: State = .collapsed
        /// Колонка: 0 — исходное значение (справа), дальше — к источникам.
        var depth: Int

        var isExpandable: Bool {
            switch kind {
            case .value, .component, .arrival: return true
            case .call(let method): return method != nil
            case .parameter(let method, let index): return method != nil && index >= 0
            default: return false
            }
        }
    }

    enum EdgeKind: Hashable { case data, network, condition }

    struct Edge: Hashable {
        var from: String
        var to: String
        var kind: EdgeKind = .data
    }

    @Published private(set) var nodes: [String: Node] = [:]
    /// Порядок появления — от него раскладка.
    @Published private(set) var order: [String] = []
    @Published private(set) var edges: [Edge] = []
    @Published var selection: String?
    /// Первое раскрытие закончилось: больше ничего не грузится — окно
    /// подгоняет масштаб, чтобы граф был виден целиком.
    @Published private(set) var settled = false

    let rootID: String
    private weak var home: (any GraphProject)?
    /// Проект по корню: свой или вторая половина пары.
    private let lookup: (URL) -> (any GraphProject)?
    /// Без окна: всё считается сразу, на этом же потоке.
    private let synchronous: Bool
    /// Докуда граф раскрывается сам.
    var autoLimit = 40
    var autoDepth = 6

    convenience init(workspace: Workspace, value: Declaration) {
        self.init(home: workspace, lookup: Self.openProject, value: value)
    }

    convenience init(workspace: Workspace, component: String) {
        self.init(home: workspace, lookup: Self.openProject, component: component)
    }

    init(home: any GraphProject, lookup: @escaping (URL) -> (any GraphProject)?, value: Declaration,
         synchronous: Bool = false, autoLimit: Int = 40, autoDepth: Int = 6) {
        self.home = home
        self.lookup = lookup
        self.synchronous = synchronous
        self.autoLimit = autoLimit
        self.autoDepth = autoDepth
        let project = home.root ?? value.url.deletingLastPathComponent()
        let node = Self.valueNode(value, project: project, depth: 0)
        rootID = node.id
        add(node)
        expand(rootID)
    }

    init(home: any GraphProject, lookup: @escaping (URL) -> (any GraphProject)?, component: String,
         synchronous: Bool = false, autoLimit: Int = 40, autoDepth: Int = 6) {
        self.home = home
        self.lookup = lookup
        self.synchronous = synchronous
        self.autoLimit = autoLimit
        self.autoDepth = autoDepth
        let node = Self.componentNode(component, project: home.root ?? URL(fileURLWithPath: "/"), depth: 0)
        rootID = node.id
        add(node)
        expand(rootID)
    }

    /// Открытые окна проектов.
    private static func openProject(_ root: URL) -> (any GraphProject)? {
        ProjectWindows.shared.workspaces.first { $0.root?.path == root.path }
    }

    var title: String { nodes[rootID]?.title ?? "" }

    // MARK: - Узлы

    private static func valueNode(_ declaration: Declaration, project: URL, depth: Int) -> Node {
        Node(id: "value|\(project.path)|\(declaration.name)", kind: .value(declaration),
             title: declaration.title, subtitle: ProjectPair.label(of: project),
             project: project, url: declaration.url, line: declaration.line, depth: depth)
    }

    private static func componentNode(_ name: String, project: URL, depth: Int) -> Node {
        Node(id: "component|\(project.path)|\(name)", kind: .component(name), title: name,
             subtitle: L("компонент · \(ProjectPair.label(of: project))"), project: project, depth: depth)
    }

    private func add(_ node: Node) {
        guard nodes[node.id] == nil else { return }
        nodes[node.id] = node
        order.append(node.id)
    }

    private func link(_ from: String, _ to: String, _ kind: EdgeKind = .data) {
        let edge = Edge(from: from, to: to, kind: kind)
        if !edges.contains(edge) { edges.append(edge) }
    }

    func togglePreview(_ id: String) {
        nodes[id]?.showsFull.toggle()
    }

    // MARK: - Раскрытие

    func expand(_ id: String) {
        guard let node = nodes[id], node.isExpandable, let home else { return }
        switch node.state {
        case .loading, .expanded: return
        default: break
        }
        // Приход датаграммы раскрывается во второй половине: там её шлют.
        var project = node.project
        if case .arrival = node.kind {
            guard let partner = home.partner else {
                nodes[id]?.state = .failed(L("У проекта нет пары — отправок не найти"))
                return
            }
            project = partner
        }
        let owner = home.root?.path == project.path ? home : lookup(project)
        guard let owner, let rustlyn = owner.rustlyn else {
            nodes[id]?.state = .failed(L("Откройте \(ProjectPair.label(of: project)) — граф идёт по его компилятору"))
            return
        }
        nodes[id]?.state = .loading
        let context = ValueGraphAnalysis.Context(root: project, rustlyn: rustlyn, texts: owner.openTexts(),
                                                 index: owner.symbolIndex, network: owner.rules.datagrams)
        let kind = node.kind
        let analyze = { () -> [ValueGraphAnalysis.Site] in
            switch kind {
            case .value(let declaration): return context.writes(to: declaration)
            case .component(let name): return context.componentChanges(of: name)
            case .arrival(let datagram): return context.sends(of: datagram)
            case .call(let method?): return context.returns(of: method)
            case .parameter(let method?, let index): return context.callers(of: method, argument: index)
            default: return []
            }
        }
        if synchronous {
            adopt(analyze(), into: id, project: project, datagrams: context.datagrams)
            return
        }
        owner.referenceQueue.async { [weak self] in
            let sites = analyze()
            let datagrams = context.datagrams
            Task { @MainActor in self?.adopt(sites, into: id, project: project, datagrams: datagrams) }
        }
    }

    private func adopt(_ sites: [ValueGraphAnalysis.Site], into id: String, project: URL, datagrams: Set<String>) {
        guard let node = nodes[id] else { return }
        let depth = node.depth
        var declaration: Declaration?
        if case .value(let d) = node.kind { declaration = d }
        let isDatagram = declaration?.typeName.map(datagrams.contains) ?? false
        var isArrival = false
        if case .arrival = node.kind { isArrival = true }

        var shown = 0
        for site in sites {
            // Чтение из сети внутри самой датаграммы — это мост, а не код.
            if isDatagram, site.isNetworkRead { continue }
            shown += 1
            let siteID = "site|\(site.url.path)|\(site.offset)"
            var siteNode = Node(id: siteID, kind: .site, title: site.title,
                                subtitle: "\(ProjectPair.label(of: project)) · \(site.url.lastPathComponent):\(site.line + 1)",
                                project: project, url: site.url, line: site.line, depth: depth + 1)
            siteNode.preview = site.preview
            siteNode.fullPreview = site.methodLines
            siteNode.note = site.note
            siteNode.state = .expanded
            add(siteNode)
            link(siteID, id, isArrival ? .network : .data)

            for source in site.sources {
                adoptSource(source, into: siteID, site: site, project: project, depth: depth + 2)
            }
            adoptTrigger(site.trigger, into: siteID, site: site, project: project, depth: depth + 2)
        }

        // Поле датаграммы, которое здесь только принимают, — продолжается
        // во второй половине: там его заполняют перед Send.
        if let declaration, isDatagram, !sites.contains(where: { !$0.isNetworkRead }) {
            bridge(from: id, declaration: declaration, depth: depth)
            nodes[id]?.state = .expanded
            return
        }
        nodes[id]?.state = shown == 0 ? .failed(emptyReason(for: node.kind)) : .expanded
        autoExpand()
        if !settled, !nodes.values.contains(where: { $0.state == .loading }) { settled = true }
    }

    /// Первые шаги граф делает сам: значения и приходы датаграмм на
    /// несколько колонок вглубь, пока узлов немного. Дальше — по кнопкам.
    private func autoExpand() {
        for id in order {
            guard nodes.count < autoLimit else { return }
            guard let node = nodes[id], node.state == .collapsed, node.depth <= autoDepth else { continue }
            switch node.kind {
            case .value, .arrival: expand(id)
            default: break
            }
        }
    }


    private func adoptSource(_ source: ValueGraphAnalysis.Source, into siteID: String, site: ValueGraphAnalysis.Site,
                             project: URL, depth: Int) {
        var sourceNode: Node
        switch source.kind {
        case .value(let target):
            sourceNode = Self.valueNode(target, project: project, depth: depth)
        case .call(let name, let method):
            sourceNode = Node(id: "call|\(project.path)|\(method?.name ?? siteID + "|" + name)", kind: .call(method),
                              title: name + "()", subtitle: L("вызов · \(ProjectPair.label(of: project))"),
                              project: project, url: method?.url, line: method?.line, depth: depth)
        case .parameter(let name, let method, let index):
            sourceNode = Node(id: "param|\(project.path)|\(method?.name ?? siteID)|\(name)",
                              kind: .parameter(method: method, index: index), title: name,
                              subtitle: L("параметр \(method?.title ?? site.title)"), project: project,
                              url: method?.url, line: method?.line, depth: depth)
        case .unknown(let chain):
            sourceNode = Node(id: "unknown|\(siteID)|\(chain)", kind: .unknown, title: chain,
                              subtitle: L("компилятор не узнал имя"), project: project, depth: depth)
        }
        var notes: [String] = []
        if !source.via.isEmpty { notes.append(L("через \(source.via.joined(separator: " ← "))")) }
        if source.byName { notes.append(L("найдено по имени — может быть неточно")) }
        if !notes.isEmpty, nodes[sourceNode.id] == nil { sourceNode.note = notes.joined(separator: " · ") }
        add(sourceNode)
        link(sourceNode.id, siteID)
    }

    /// Когда место выполняется: пришла датаграмма или сущность попала в фильтр.
    private func adoptTrigger(_ trigger: ValueGraphAnalysis.Trigger?, into siteID: String,
                              site: ValueGraphAnalysis.Site, project: URL, depth: Int) {
        switch trigger {
        case .network(let datagram, let receiver):
            let arrival = Node(id: "arrival|\(project.path)|\(datagram)", kind: .arrival(datagram),
                               title: L("Пришла \(datagram)"), subtitle: L("цикл по \(receiver)<\(datagram)>"),
                               project: project, depth: depth)
            add(arrival)
            link(arrival.id, siteID, .condition)
        case .filter(let name, let with, let without):
            var parts = [with.joined(separator: ", ")]
            if !without.isEmpty { parts.append(L("без \(without.joined(separator: ", "))")) }
            var condition = Node(id: "filter|\(site.url.path)|\(name)", kind: .condition, title: L("Фильтр \(name)"),
                                 subtitle: parts.filter { !$0.isEmpty }.joined(separator: " · "),
                                 project: project, url: site.url, line: site.filterLine ?? site.line, depth: depth)
            condition.state = .expanded
            add(condition)
            link(condition.id, siteID, .condition)
            for component in with {
                let node = Self.componentNode(component, project: project, depth: depth + 1)
                add(node)
                link(node.id, condition.id, .condition)
            }
        case nil:
            break
        }
    }

    private func emptyReason(for kind: Node.Kind) -> String {
        switch kind {
        case .component: return L("Set, Add и Remove этого компонента не нашлись")
        case .arrival: return L("Отправок не нашлось")
        case .call: return L("return не нашёлся — метод без тела или из сборки")
        case .parameter: return L("Вызовов не нашлось — метод зовёт движок или рефлексия")
        default: return L("Записей не нашлось — значение задают в объявлении или через рефлексию")
        }
    }

    /// Та же датаграмма во второй половине пары.
    private func bridge(from id: String, declaration: Declaration, depth: Int) {
        guard let home, let typeName = declaration.typeName,
              let partnerRoot = home.partner else { return }
        let label = ProjectPair.label(of: partnerRoot)
        let bridgeID = "net|\(id)"
        add(Node(id: bridgeID, kind: .network, title: L("Сеть: \(typeName)"),
                 subtitle: L("приходит из \(label)"), project: partnerRoot, depth: depth + 1))
        link(bridgeID, id, .network)
        guard let index = lookup(partnerRoot)?.symbolIndex else {
            nodes[bridgeID]?.note = L("Откройте \(label), чтобы пройти дальше")
            return
        }
        guard let member = (index.membersByOwner[typeName] ?? []).first(where: { index[$0].name == declaration.shortName })
        else {
            nodes[bridgeID]?.note = L("В \(label) у \(typeName) нет поля \(declaration.shortName)")
            return
        }
        let symbol = index[member]
        let theirs = Declaration(url: index.target(member).url, line: Int(symbol.line),
                                 character: Int(symbol.column), length: Int(symbol.length),
                                 name: [symbol.container, symbol.name].compactMap { $0 }.joined(separator: "."))
        let value = Self.valueNode(theirs, project: partnerRoot, depth: depth + 2)
        add(value)
        link(value.id, bridgeID, .network)
        autoExpand()
    }

    /// Открыть место в окне его проекта.
    func open(_ id: String) {
        guard let node = nodes[id], let url = node.url,
              let owner = (home?.root?.path == node.project.path ? home : lookup(node.project)) as? Workspace
        else { return }
        let position = LSPPosition(line: node.line ?? 0, character: 0)
        owner.navigate(to: NavTarget(url: url, range: LSPRange(start: position, end: position)))
        owner.bringToFront()
    }
}
