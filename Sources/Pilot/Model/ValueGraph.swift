import AppKit

/// Граф «откуда берётся значение»: значение под курсором — поле, свойство,
/// переменная, параметр, результат вызова, — места, где его пишут, и то, из
/// чего складывается записанное, — дальше по тем же правилам, пока не
/// найдутся источники: литерал или константа в коде, значение
/// перечисления, JSON конфига, инспектор Unity, время, случайное число,
/// ввод игрока. Через сеть тоже, если её описывает расширение проекта
/// (`DatagramRules`): поле сетевой структуры в одной половине пары
/// продолжается тем же полем в другой, где её заполняют перед отправкой,
/// а цикл по типу-приёмнику (`PacketFilter<T>`) срабатывает, когда вторая
/// половина шлёт `T`.
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

    struct Declaration: Equatable, Hashable, Sendable {
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

    /// С чего граф начинается — что стоит под курсором.
    enum Root {
        /// Поле, свойство или локальная переменная: кто их пишет.
        case value(Declaration)
        /// Тип-компонент: где его ставят и снимают.
        case component(String)
        /// Метод: что он возвращает.
        case call(Declaration)
        /// Параметр метода: что передают в вызовах.
        case parameter(method: Declaration, index: Int, name: String)
        /// Уже источник: значение перечисления, член сборки.
        case origin(ValueOrigin, Declaration?)
    }

    struct Node: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Поле, свойство или локальная — раскрывается в места записи.
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
            /// Источник: литерал, константа, перечисление, конфиг, инспектор,
            /// время движка — дальше идти не нужно. Конфиг и инспектор
            /// раскрываются в строки данных, где значение задано; объявление —
            /// значение, чьё это происхождение, или имя самого источника.
            case source(ValueOrigin, Declaration?)
            /// Строка данных: JSON конфига, YAML префаба или сцены.
            case data
            /// Места, которые не поместились в предел — раскрывается в них.
            case more
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
        /// Компилятор имени не узнал — поле нашлось по индексу, по имени.
        var guessed = false
        /// Код значение не пишет, и известно откуда оно: база, конфиг, инспектор.
        var origin: String?
        /// Узел — только аргумент вызова метода проекта (`entity` в
        /// `GetMax(entity)`): его видно, но сам граф туда не идёт.
        var weak = false
        var state: State = .collapsed
        /// Колонка: 0 — исходное значение (справа), дальше — к источникам.
        var depth: Int

        var isExpandable: Bool {
            switch kind {
            case .value, .component, .arrival, .more: return true
            case .call(let method): return method != nil
            case .parameter(let method, let index): return method != nil && index >= 0
            case .source(let origin, let declaration):
                return declaration != nil && [.config, .inspector].contains(origin.kind)
            default: return false
            }
        }

        /// Лист, который на предел раскрытия не влияет: источник и строка данных.
        var isLeaf: Bool {
            switch kind {
            case .source, .data: return true
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

    /// Докуда граф раскрывается сам.
    struct Reach {
        /// Пока узлов меньше (источники и строки данных — листья — не в счёт).
        var nodes = 40
        /// Колонок от исходного значения.
        var depth = 6
        /// Вызовы и параметры тоже, а не только значения и приходы: вглубь
        /// к источникам. Сначала всё равно «кто пишет».
        var calls = true
        /// Инспектор Unity — искать значение в префабах и сценах: это чтение
        /// всех ассетов, секунды на большом проекте.
        var assets = false
        /// Мест у одного узла не больше — остальные за узлом «ещё N».
        /// 0 — без предела.
        var fanIn = 12
        /// Раскрывать и значения, которые стоят только аргументом вызова
        /// метода проекта. Окно — нет: значение вызова и так видно через его
        /// return; обзор — да, как раньше, чтобы числа сравнивались.
        var arguments = false
    }

    let rootID: String
    private weak var home: (any GraphProject)?
    /// Проект по корню: свой или вторая половина пары.
    private let lookup: (URL) -> (any GraphProject)?
    /// Без окна: всё считается сразу, на этом же потоке.
    private let synchronous: Bool
    let reach: Reach
    /// Узлов, которые считаются в предел.
    private var counted = 0
    /// Места за узлами «ещё N»: узел → места, куда и откуда.
    private var hidden: [String: (sites: [ValueGraphAnalysis.Site], into: String, project: URL, datagrams: Set<String>)] = [:]

    convenience init(workspace: Workspace, root: Root) {
        self.init(home: workspace, lookup: Self.openProject, root: root)
    }

    init(home: any GraphProject, lookup: @escaping (URL) -> (any GraphProject)?, root: Root,
         synchronous: Bool = false, reach: Reach = Reach()) {
        self.home = home
        self.lookup = lookup
        self.synchronous = synchronous
        self.reach = reach
        let project = home.root ?? URL(fileURLWithPath: "/")
        let node: Node
        switch root {
        case .value(let declaration):
            node = Self.valueNode(declaration, project: home.root ?? declaration.url.deletingLastPathComponent(), depth: 0)
        case .component(let name):
            node = Self.componentNode(name, project: project, depth: 0)
        case .call(let method):
            node = Node(id: "call|\(project.path)|\(method.name)", kind: .call(method), title: method.title + "()",
                        subtitle: L("вызов · \(ProjectPair.label(of: project))"), project: project, url: method.url,
                        line: method.line, depth: 0)
        case .parameter(let method, let index, let name):
            node = Node(id: "param|\(project.path)|\(method.name)|\(name)", kind: .parameter(method: method, index: index),
                        title: name, subtitle: L("параметр \(method.title)"), project: project, url: method.url,
                        line: method.line, depth: 0)
        case .origin(let origin, let declaration):
            node = Self.sourceNode(origin, at: declaration, id: "source|\(project.path)|\(origin.title)", project: project,
                                   depth: 0)
        }
        rootID = node.id
        add(node)
        expand(rootID)
        if !node.isExpandable, !settled { settled = true }
    }

    /// Открытые окна проектов.
    private static func openProject(_ root: URL) -> (any GraphProject)? {
        ProjectWindows.shared.workspaces.first { $0.root?.path == root.path }
    }

    var title: String { nodes[rootID]?.title ?? "" }

    /// Источники, до которых граф дошёл, — в порядке появления.
    var sources: [Node] {
        order.compactMap { nodes[$0] }.filter { if case .source = $0.kind { return true }; return false }
    }

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

    /// Источник: подпись — его вид и где он (проект или сборка).
    private static func sourceNode(_ origin: ValueOrigin, at declaration: Declaration?, id: String, project: URL,
                                   depth: Int) -> Node {
        var subtitle = "\(origin.kind.label) · \(ProjectPair.label(of: project))"
        if let declaration, let library = ValueGraphAnalysis.Context.libraryName(declaration.url) {
            subtitle = "\(origin.kind.label) · \(library)"
        }
        var node = Node(id: id, kind: .source(origin, declaration), title: origin.title, subtitle: subtitle,
                        project: project, url: declaration?.url, line: declaration?.line, depth: depth)
        if !node.isExpandable { node.state = .expanded }
        return node
    }

    private func add(_ node: Node) {
        guard nodes[node.id] == nil else { return }
        nodes[node.id] = node
        order.append(node.id)
        if !node.isLeaf { counted += 1 }
    }

    private func remove(_ id: String) {
        guard let node = nodes.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        edges.removeAll { $0.from == id || $0.to == id }
        if !node.isLeaf { counted -= 1 }
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
        // «Ещё N»: места уже найдены — показать их.
        if case .more = node.kind, let pending = hidden.removeValue(forKey: id) {
            remove(id)
            adopt(pending.sites, into: pending.into, project: pending.project, datagrams: pending.datagrams, all: true)
            return
        }
        // Приход датаграммы раскрывается во второй половине: там её шлют.
        var project = node.project
        if case .arrival = node.kind {
            guard let partner = partner(of: node.project) else {
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
        let partnerRoot = owner.partner
        let context = ValueGraphAnalysis.Context(root: project, rustlyn: rustlyn, texts: owner.openTexts(),
                                                 index: owner.symbolIndex, network: owner.rules.datagrams,
                                                 configs: owner.rules.configs, partner: partnerRoot,
                                                 partnerIndex: partnerRoot.flatMap { lookup($0)?.symbolIndex })
        let kind = node.kind
        // Места и откуда значение, если его дают данные: база, конфиг, инспектор.
        let analyze = { () -> ([ValueGraphAnalysis.Site], ValueOrigin?) in
            switch kind {
            case .value(let declaration):
                // Откуда значение, известно и при записях: у поля инспектора или
                // модели конфига объявление даёт только умолчание.
                return (context.writes(to: declaration), context.origin(of: declaration))
            case .component(let name): return (context.componentChanges(of: name), nil)
            case .arrival(let datagram): return (context.sends(of: datagram), nil)
            case .call(let method?): return (context.returns(of: method), nil)
            case .parameter(let method?, let index):
                // Вызовов нет — может быть, метод зовёт движок: `OnUpdate(deltaTime)`.
                let sites = context.callers(of: method, argument: index)
                return (sites, sites.isEmpty ? context.parameterOrigin(of: method, argument: index) : nil)
            case .source(let origin, let declaration?) where origin.kind == .config:
                return (context.configValues(of: declaration), nil)
            case .source(let origin, let declaration?) where origin.kind == .inspector:
                return (context.inspectorValues(of: declaration), nil)
            default: return ([], nil)
            }
        }
        if synchronous {
            let (sites, origin) = analyze()
            adopt(sites, into: id, project: project, datagrams: context.datagrams, origin: origin)
            return
        }
        owner.referenceQueue.async { [weak self] in
            let (sites, origin) = analyze()
            let datagrams = context.datagrams
            Task { @MainActor in self?.adopt(sites, into: id, project: project, datagrams: datagrams, origin: origin) }
        }
    }

    private func adopt(_ found: [ValueGraphAnalysis.Site], into id: String, project: URL, datagrams: Set<String>,
                       origin: ValueOrigin? = nil, all: Bool = false) {
        guard let node = nodes[id] else { return }
        let depth = node.depth
        var declaration: Declaration?
        if case .value(let d) = node.kind { declaration = d }
        let isDatagram = declaration?.typeName.map(datagrams.contains) ?? false
        var isArrival = false
        if case .arrival = node.kind { isArrival = true }
        var isSource = false
        if case .source = node.kind { isSource = true }

        // Чтение из сети внутри самой датаграммы — это мост, а не код.
        let sites = found.filter { !(isDatagram && $0.isNetworkRead) }
        // Много мест — одинаковые одним узлом, первые из остальных, прочие
        // за узлом «ещё N»: граф должен читаться.
        var shown = reach.fanIn > 0 ? Self.grouped(sites) : sites
        if !all, reach.fanIn > 0, shown.count > reach.fanIn + 1 {
            let rest = Array(shown.dropFirst(reach.fanIn))
            shown = Array(shown.prefix(reach.fanIn))
            let moreID = "more|\(id)"
            let places = Localization.count(rest.count, "место", "места", "мест")
            var more = Node(id: moreID, kind: .more, title: L("ещё \(places)"),
                            subtitle: rest.prefix(3).map(\.title).joined(separator: ", "), project: project, depth: depth + 1)
            more.note = L("не поместились в граф")
            hidden[moreID] = (rest, id, project, datagrams)
            add(more)
            link(moreID, id)
        }
        for site in shown {
            let siteProject = site.project ?? project
            let siteID = "site|\(site.url.path)|\(site.offset)"
            var siteNode = Node(id: siteID, kind: site.isData ? .data : .site, title: site.title,
                                subtitle: "\(ProjectPair.label(of: siteProject)) · \(site.url.lastPathComponent):\(site.line + 1)",
                                project: siteProject, url: site.url, line: site.line, depth: depth + 1)
            siteNode.preview = site.preview
            siteNode.fullPreview = site.methodLines
            siteNode.note = site.note
            siteNode.state = .expanded
            add(siteNode)
            link(siteID, id, isArrival ? .network : .data)

            for source in site.sources {
                adoptSource(source, into: siteID, site: site, project: siteProject, depth: depth + 2)
            }
            adoptTrigger(site.trigger, into: siteID, site: site, project: siteProject, depth: depth + 2)
        }

        if let declaration, isDatagram, sites.isEmpty, !all {
            // Поле датаграммы, которое здесь только принимают, — продолжается
            // во второй половине: там его заполняют перед Send.
            bridge(from: id, declaration: declaration, project: project, depth: depth)
            nodes[id]?.state = .expanded
        } else if sites.isEmpty, let origin {
            // Код его не пишет, и это ответ: значение из базы, конфига, инспектора.
            nodes[id]?.state = .expanded
            if declaration != nil { nodes[id]?.origin = Self.phrase(origin) }
            let source = Self.sourceNode(origin, at: declaration, id: "source|\(id)", project: project, depth: depth + 1)
            add(source)
            link(source.id, id)
        } else if sites.isEmpty, isSource {
            // Строк данных не нашлось — источник всё равно известен.
            nodes[id]?.state = .expanded
            nodes[id]?.note = L("где задано — не нашлось")
        } else if !all {
            nodes[id]?.state = sites.isEmpty ? .failed(emptyReason(for: node.kind)) : .expanded
            // Значение из данных, хотя в коде оно есть: у поля инспектора и
            // модели конфига начальное значение в объявлении — только умолчание.
            if let origin, !sites.isEmpty, [.inspector, .config, .json, .database].contains(origin.kind) {
                var source = Self.sourceNode(origin, at: declaration, id: "source|\(id)", project: project, depth: depth + 1)
                source.note = sites.allSatisfy(\.isDeclaration) ? L("код задаёт только умолчание") : L("и код его меняет")
                add(source)
                link(source.id, id)
            }
        }
        autoExpand()
        if !settled, !nodes.values.contains(where: { $0.state == .loading }) { settled = true }
    }

    /// Одинаковые места — та же строка кода и те же источники, как у
    /// `SessionStartTime = ReliableTime.GetUnixIntTimestamp()` в двенадцати
    /// системах, — одним узлом: первое, с пометкой, где ещё.
    private static func grouped(_ sites: [ValueGraphAnalysis.Site]) -> [ValueGraphAnalysis.Site] {
        var result: [ValueGraphAnalysis.Site] = []
        var others: [[String]] = []
        var positions: [String: Int] = [:]
        for site in sites {
            let code = site.preview.first { $0.number == site.line }?.text.trimmingCharacters(in: .whitespaces) ?? ""
            let sources = site.sources.map { "\($0.kind)|\($0.via)" }.sorted().joined(separator: ";")
            let key = [code, site.note ?? "", sources, site.isData ? "data" : ""].joined(separator: "\n")
            if !code.isEmpty, let at = positions[key] {
                others[at].append(site.title)
            } else {
                positions[key] = result.count
                result.append(site)
                others.append([])
            }
        }
        for (index, titles) in others.enumerated() where !titles.isEmpty {
            let shown = titles.prefix(3).joined(separator: ", ") + (titles.count > 3 ? "…" : "")
            let note = L("так же ещё в \(titles.count): \(shown)")
            result[index].note = [result[index].note, note].compactMap { $0 }.joined(separator: " · ")
        }
        return result
    }

    /// Как значение без записей называлось в заметке и в обзоре: «из конфига».
    private static func phrase(_ origin: ValueOrigin) -> String {
        switch origin.kind {
        case .config: return L("из конфига")
        case .json: return L("из JSON")
        case .database: return L("из базы данных")
        case .injection: return L("из контейнера зависимостей")
        case .inspector: return L("из инспектора Unity")
        default: return origin.kind.label
        }
    }

    /// Первые шаги граф делает сам: сначала значения и приходы датаграмм
    /// («кто пишет»), потом вызовы и параметры — глубже к источникам, потом
    /// строки конфигов (и префабов, если разрешено), пока узлов немного.
    /// Дальше — по кнопкам.
    private func autoExpand() {
        for pass in 0..<3 {
            var started = false
            for id in order {
                guard counted < reach.nodes else { return }
                guard let node = nodes[id], node.state == .collapsed, node.depth <= reach.depth,
                      priority(of: node) == pass else { continue }
                expand(id)
                started = true
            }
            // Следующий шаг — когда предыдущий раскрыт целиком.
            if started || nodes.values.contains(where: { $0.state == .loading }) { return }
        }
    }

    private func priority(of node: Node) -> Int? {
        switch node.kind {
        case .value: return node.weak && !reach.arguments ? nil : 0
        case .arrival: return 0
        case .call, .parameter: return reach.calls && !node.weak ? 1 : nil
        case .source(let origin, _):
            if origin.kind == .config { return 2 }
            return origin.kind == .inspector && reach.assets ? 2 : nil
        default: return nil
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
        case .component(let name):
            sourceNode = Self.componentNode(name, project: project, depth: depth)
        case .origin(let origin, let at):
            // Именованный источник (значение перечисления, член сборки) — один
            // на граф; литерал — свой у каждого места.
            let id = at.map { "source|\(project.path)|\($0.name)" }
                ?? "source|\(siteID)|\(origin.kind.rawValue)|\(origin.title)"
            sourceNode = Self.sourceNode(origin, at: at, id: id, project: project, depth: depth)
        case .unknown(let chain, let reason):
            sourceNode = Node(id: "unknown|\(siteID)|\(chain)", kind: .unknown, title: chain,
                              subtitle: reason ?? L("компилятор не узнал имя"), project: project, depth: depth)
        }
        var notes: [String] = []
        if let call = source.argumentOf { notes.append(call == "[]" ? L("ключ элемента") : L("аргумент \(call)")) }
        if !source.via.isEmpty { notes.append(L("через \(source.via.joined(separator: " ← "))")) }
        if source.byName { notes.append(L("найдено по имени — может быть неточно")) }
        if !notes.isEmpty, nodes[sourceNode.id] == nil { sourceNode.note = notes.joined(separator: " · ") }
        sourceNode.guessed = source.byName
        sourceNode.weak = source.argumentOf != nil
        // Тот же узел, но здесь он значение, а не аргумент, — раскрывать.
        if source.argumentOf == nil, nodes[sourceNode.id]?.weak == true { nodes[sourceNode.id]?.weak = false }
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

    /// Вторая половина пары для проекта узла: у узлов из второй половины
    /// это исходный проект, а не его пара.
    private func partner(of project: URL) -> URL? {
        guard let home else { return nil }
        return home.root?.path == project.path ? home.partner : lookup(project)?.partner
    }

    /// Та же датаграмма во второй половине пары. Нет пары — источник «сеть».
    private func bridge(from id: String, declaration: Declaration, project: URL, depth: Int) {
        guard let typeName = declaration.typeName else { return }
        guard let partnerRoot = partner(of: project) else {
            let source = Self.sourceNode(ValueOrigin(kind: .network, title: typeName), at: nil, id: "source|\(id)|network",
                                         project: project, depth: depth + 1)
            add(source)
            link(source.id, id, .network)
            return
        }
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
