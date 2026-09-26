import Foundation

/// Граф значения без окна — тот же движок, что у ⌥⌘G, для проверки из
/// терминала и скриптов:
///
///     Pilot --value-graph File.cs:13:30 [--depth 6] [--limit 60] [--json] [--lang en]
///           [--expect "Health.value <- DamageSystem.OnUpdate"]…
///
/// Проект — ближайшая папка с `.git` над файлом, вторая половина пары — по
/// тем же правилам, что у окна. Расширения из `.pilot/extensions/` обеих
/// половин действуют без вопроса: скрипт запускают для этого проекта сознательно. Компиляция и индекс берутся из кэша: проект
/// должен хоть раз открываться в Pilot. `--expect` — цепочка названий узлов
/// от значения к источникам (подстроки); код выхода 1, если какой-то нет.
@MainActor
enum HeadlessGraph {

    static var isRequested: Bool { CommandLine.arguments.contains("--value-graph") }

    /// Проект, поднятый без окна.
    final class Project: GraphProject {
        let root: URL?
        let rustlyn: Rustlyn?
        let symbolIndex: SymbolIndex?
        let referenceQueue = DispatchQueue(label: "pilot.headless.references")
        let partner: URL?
        let rules: ProjectRules

        init(root: URL, partner: URL?, rules: ProjectRules) {
            self.root = root
            self.partner = partner
            self.rules = rules
            let symbols = UnityProjectInfo.find(inWorkspace: root)?.preprocessorSymbols ?? []
            let session = Rustlyn.start(root: root, symbols: symbols)
            let started = Date()
            if let session, session.loadCompilation() == nil {
                // Кэша компиляции нет — собрать по списку файлов из кэша индекса.
                let files = IndexCache.load(root: root)?.display ?? []
                session.reindex(files.map { root.appendingPathComponent($0) }.filter(Rustlyn.understands))
                _ = session.compile()
            }
            rustlyn = session
            symbolIndex = IndexCache.loadSymbols(root: root)?.index
            log("\(root.lastPathComponent): компилятор \(session == nil ? "не поднялся" : "готов"), "
                + "индекс \(symbolIndex.map { "\($0.count) объявлений" } ?? "нет в кэше") "
                + "за \(Int(Date().timeIntervalSince(started) * 1000)) мс")
        }

        func openTexts() -> [URL: String] { [:] }
    }

    /// Разобрать аргументы, построить граф, напечатать, проверить. Код выхода.
    static func run() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let expectations = arguments.indices.filter { arguments[$0] == "--expect" && $0 + 1 < arguments.count }
            .map { arguments[$0 + 1] }
        // Подписи — на языке исходников, а не интерфейса: эталоны не должны
        // зависеть от того, какой язык выбран в настройках.
        Localization.current = value("--lang").flatMap(AppLanguage.init(rawValue:)) ?? .ru
        guard let target = value("--value-graph"), let location = Location(target) else {
            log("нужно: --value-graph Файл.cs:строка:столбец")
            return 2
        }
        guard let root = projectRoot(of: location.url) else {
            log("над \(location.url.path) нет папки с .git — не понять, какой это проект")
            return 2
        }
        let own = ProjectExtension.discover(in: root).found.map(\.manifest.rules)
        let partnerRoot = ProjectPair.partner(of: root, links: [:], extra: ProjectRules.merged(own).pair.suffixes) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let theirs = partnerRoot.map { ProjectExtension.discover(in: $0).found.map(\.manifest.rules) } ?? []
        let rules = ProjectRules.merged(own + theirs)
        let home = Project(root: root, partner: partnerRoot, rules: rules)
        var projects: [String: Project] = [root.path: home]
        if let partnerRoot { projects[partnerRoot.path] = Project(root: partnerRoot, partner: root, rules: rules) }

        guard let rustlyn = home.rustlyn, let text = SymbolIndex.readSource(location.url) else {
            log("не открыть \(location.url.path)")
            return 2
        }
        let model = SyntaxModel(text: text, spec: nil)
        let offset = model.offset(at: LSPPosition(line: location.line - 1, character: location.column - 1))
        guard let found = rustlyn.definition(location.url, offset: offset).targets.first else {
            log("под \(target) компилятор не нашёл имени")
            return 2
        }
        let depth = value("--depth").flatMap(Int.init) ?? 6
        let limit = value("--limit").flatMap(Int.init) ?? 60
        let lookup: (URL) -> (any GraphProject)? = { projects[$0.path] }
        let graph: ValueGraph
        switch found.kind {
        case .field, .property:
            graph = ValueGraph(home: home, lookup: lookup,
                               value: ValueGraph.Declaration(url: found.url, line: found.line, character: found.character,
                                                             length: found.length, name: found.name),
                               synchronous: true, autoLimit: limit, autoDepth: depth)
        case .struct, .class:
            graph = ValueGraph(home: home, lookup: lookup, component: found.shortName,
                               synchronous: true, autoLimit: limit, autoDepth: depth)
        default:
            log("\(found.name) — не поле, не свойство и не компонент")
            return 2
        }

        if arguments.contains("--json") {
            print(json(graph))
        } else {
            print(tree(graph))
        }
        var failed = 0
        for expectation in expectations {
            let ok = graph.hasPath(expectation.components(separatedBy: "<-").map { $0.trimmingCharacters(in: .whitespaces) })
            print((ok ? "✓ " : "✗ ") + expectation)
            if !ok { failed += 1 }
        }
        return failed == 0 ? 0 : 1
    }

    // MARK: - Вывод

    /// Дерево от значения к источникам; повторно встреченный узел — ссылкой.
    static func tree(_ graph: ValueGraph) -> String {
        var incoming: [String: [ValueGraph.Edge]] = [:]
        for edge in graph.edges { incoming[edge.to, default: []].append(edge) }
        var lines: [String] = []
        var printed: Set<String> = []
        func walk(_ id: String, prefix: String, edge: ValueGraph.EdgeKind?) {
            guard let node = graph.nodes[id] else { return }
            let arrow: String
            switch edge {
            case .network?: arrow = "⇠ "
            case .condition?: arrow = "? "
            case .data?: arrow = "← "
            case nil: arrow = ""
            }
            var line = prefix + arrow + describe(node)
            if printed.contains(id) {
                lines.append(line + " (см. выше)")
                return
            }
            printed.insert(id)
            if let note = node.note { line += " — " + note }
            if case .failed(let why) = node.state { line += " ✗ " + why }
            if node.state == .collapsed, node.isExpandable { line += " …" }
            lines.append(line)
            for child in incoming[id] ?? [] { walk(child.from, prefix: prefix + "   ", edge: child.kind) }
        }
        walk(graph.rootID, prefix: "", edge: nil)
        return lines.joined(separator: "\n")
    }

    private static func describe(_ node: ValueGraph.Node) -> String {
        let kind: String
        switch node.kind {
        case .value: kind = "значение"
        case .component: kind = "компонент"
        case .site: kind = "код"
        case .condition: kind = "условие"
        case .arrival: kind = "приход"
        case .network: kind = "сеть"
        case .call: kind = "вызов"
        case .parameter: kind = "параметр"
        case .unknown: kind = "не узнано"
        }
        var text = "\(node.title) [\(kind), \(ProjectPair.label(of: node.project))]"
        if let url = node.url, let line = node.line { text += " \(url.lastPathComponent):\(line + 1)" }
        if let focus = node.preview.first(where: { $0.number == node.line }) {
            text += "  │ " + focus.text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    static func json(_ graph: ValueGraph) -> String {
        let nodes: [[String: Any]] = graph.order.compactMap { graph.nodes[$0] }.map { node in
            var entry: [String: Any] = ["id": node.id, "title": node.title, "subtitle": node.subtitle,
                                        "project": node.project.path, "depth": node.depth]
            if let url = node.url { entry["file"] = url.path }
            if let line = node.line { entry["line"] = line + 1 }
            if let note = node.note { entry["note"] = note }
            if case .failed(let why) = node.state { entry["failed"] = why }
            if !node.preview.isEmpty { entry["code"] = node.preview.map(\.text) }
            return entry
        }
        let edges: [[String: Any]] = graph.edges.map { edge in
            let kind: String
            switch edge.kind {
            case .data: kind = "data"
            case .network: kind = "network"
            case .condition: kind = "condition"
            }
            return ["from": edge.from, "to": edge.to, "kind": kind]
        }
        let data = try? JSONSerialization.data(withJSONObject: ["root": graph.rootID, "nodes": nodes, "edges": edges],
                                               options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: - Мелочи

    private struct Location {
        let url: URL
        let line: Int
        let column: Int

        init?(_ text: String) {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 3, let line = Int(parts[parts.count - 2]), let column = Int(parts[parts.count - 1])
            else { return nil }
            let path = parts.dropLast(2).joined(separator: ":")
            url = URL(fileURLWithPath: path).standardizedFileURL
            self.line = line
            self.column = column
        }
    }

    private static func projectRoot(of file: URL) -> URL? {
        var directory = file.deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// В stderr: stdout — для графа.
    private static func log(_ text: String) {
        FileHandle.standardError.write(Data(("pilot: " + text + "\n").utf8))
    }
}

extension ValueGraph {
    /// Есть ли цепочка узлов с такими названиями (подстроки), где каждый
    /// следующий — источник предыдущего.
    func hasPath(_ titles: [String]) -> Bool {
        guard let first = titles.first else { return true }
        var incoming: [String: [String]] = [:]
        for edge in edges { incoming[edge.to, default: []].append(edge.from) }
        func matches(_ id: String, _ title: String) -> Bool { nodes[id]?.title.contains(title) == true }
        func search(from id: String, rest: ArraySlice<String>) -> Bool {
            guard let next = rest.first else { return true }
            // Промежуточные узлы (сеть, условия) можно проходить, не называя.
            var seen: Set<String> = [id]
            var queue = incoming[id] ?? []
            while !queue.isEmpty {
                let candidate = queue.removeFirst()
                guard seen.insert(candidate).inserted else { continue }
                if matches(candidate, next), search(from: candidate, rest: rest.dropFirst()) { return true }
                let kind = nodes[candidate]?.kind
                if kind == .network || kind == .condition { queue += incoming[candidate] ?? [] }
            }
            return false
        }
        return order.contains { matches($0, first) && search(from: $0, rest: titles.dropFirst()) }
    }
}
