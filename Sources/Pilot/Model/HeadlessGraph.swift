import Foundation

/// Граф значения без окна — тот же движок, что у ⌥⌘G, для проверки из
/// терминала и скриптов:
///
///     Pilot --value-graph File.cs:13:30 [--depth 6] [--limit 60] [--no-calls] [--arguments] [--assets]
///           [--fan-in N] [--json] [--lang en] [--expect "Health.value <- DamageSystem.OnUpdate"]…
///     Pilot --value-graph Folder/ [--depth 6] [--limit 60] [--calls] [-v]
///
/// Проект — ближайшая папка с `.git` над файлом, вторая половина пары — по
/// тем же правилам, что у окна. Встроенные расширения и расширения из
/// `.pilot/extensions/` обеих половин действуют без вопроса: скрипт
/// запускают для этого проекта сознательно. Компиляция и индекс берутся из кэша, а
/// без него (проект в Pilot не открывали или кэш выключен в настройках) —
/// строятся, как при первом открытии, только дольше. `--expect` — цепочка
/// названий узлов от значения к источникам (подстроки); код выхода 1, если какой-то нет.
///
/// В позиции — любое значение: поле, свойство, локальная, параметр, метод
/// (что он возвращает), значение перечисления, тип-компонент. Как окно, граф
/// идёт сначала по записям, потом через вызовы и параметры к источникам;
/// `--no-calls` — только записи. Имена, которые стоят лишь аргументом
/// вызова метода проекта (`entity` в `GetMax(entity)`), граф показывает, но
/// сам не раскрывает; `--arguments` — раскрывать и их. `--assets` — искать
/// значения полей инспектора в префабах и сценах (окно — по кнопке).
/// `--fan-in N` — мест у узла не больше N, как в окне (по умолчанию без
/// предела). После дерева — строка «источники:» — все, до которых дошёл граф.
///
/// С папкой — обзор: граф каждого поля и свойства из её файлов, строкой на
/// граф, и где он теряет след — имена, которых компилятор не узнал, и
/// раскрытия, которые ничего не дали. Обзор сравнивают с прошлыми, поэтому
/// раскрывает он как раньше: вызовы и параметры — только с `--calls`,
/// аргументы — всегда; `-v` — печатать и сами графы.
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
            let unity = UnityProjectInfo.find(inWorkspace: root)
            let session = Rustlyn.start(root: root, symbols: unity?.preprocessorSymbols ?? [])
            let started = Date()
            // Список файлов — из кэша индекса, а без него — обходом папки, как
            // при первом открытии. Нужен, только если чего-то нет в кэше.
            var listed: [String]?
            func files() -> [String] {
                if let listed { return listed }
                let found = IndexCache.load(root: root)?.display
                    ?? FileIndex.scan(root: root, exclude: unity.map { $0.excludedFromIndex }, shouldStop: { false }).display
                listed = found
                return found
            }
            if let session, session.loadCompilation() == nil {
                // Кэша компиляции нет — собрать по списку файлов.
                session.reindex(files().map { root.appendingPathComponent($0) }.filter(Rustlyn.understands))
                _ = session.compile()
            }
            rustlyn = session
            symbolIndex = IndexCache.loadSymbols(root: root)?.index
                ?? SymbolIndex.build(root: root, files: files(), shouldStop: { false })
            log("\(root.lastPathComponent): компилятор \(session == nil ? "не поднялся" : "готов"), "
                + "индекс \(symbolIndex.map { "\($0.count) объявлений" } ?? "не собрался") "
                + "за \(Int(Date().timeIntervalSince(started) * 1000)) мс")
        }

        func openTexts() -> [URL: String] { [:] }
    }

    /// Проект и его пара, поднятые без окна.
    private struct Projects {
        let home: Project
        let lookup: (URL) -> (any GraphProject)?
    }

    /// Разобрать аргументы, построить граф (или графы папки), напечатать,
    /// проверить. Код выхода.
    static func run() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        // Подписи — на языке исходников, а не интерфейса: эталоны не должны
        // зависеть от того, какой язык выбран в настройках.
        Localization.current = value("--lang").flatMap(AppLanguage.init(rawValue:)) ?? .ru
        let usage = "нужно: --value-graph Файл.cs:строка:столбец или папка"
        guard let target = value("--value-graph") else {
            log(usage)
            return 2
        }
        let folder = directory(target)
        let location = folder == nil ? Location(target) : nil
        guard let start = folder ?? location?.url.deletingLastPathComponent() else {
            log(usage)
            return 2
        }
        let loading = PerfSpan()
        guard let projects = load(from: start) else { return 2 }
        let loaded = loading.finish()
        // Обзор — как раньше, чтобы числа сравнивались: вызовы только с `--calls`.
        let reach = ValueGraph.Reach(nodes: value("--limit").flatMap(Int.init) ?? 60,
                                     depth: value("--depth").flatMap(Int.init) ?? 6,
                                     calls: folder == nil ? !arguments.contains("--no-calls") : arguments.contains("--calls"),
                                     assets: arguments.contains("--assets"),
                                     fanIn: value("--fan-in").flatMap(Int.init) ?? 0,
                                     arguments: folder != nil || arguments.contains("--arguments"))
        if let folder {
            return survey(folder, projects: projects, reach: reach, verbose: arguments.contains("-v"))
        }
        guard let location else { return 2 }

        guard let rustlyn = projects.home.rustlyn, let text = SymbolIndex.readSource(location.url) else {
            log("не открыть \(location.url.path)")
            return 2
        }
        let model = SyntaxModel(text: text, spec: nil)
        let offset = model.offset(at: LSPPosition(line: location.line - 1, character: location.column - 1))
        // `--definition` — только что компилятор знает об имени: для разбора
        // того, почему граф его не узнал.
        if arguments.contains("--definition") {
            let definition = rustlyn.definition(location.url, offset: offset)
            for target in definition.targets {
                print("\(target.name) [\(target.kind)] \(target.url.path):\(target.line + 1):\(target.character + 1)")
            }
            if definition.targets.isEmpty { print("компилятор не знает этого имени") }
            return definition.targets.isEmpty ? 1 : 0
        }
        let building = PerfSpan()
        guard let found = rustlyn.definition(location.url, offset: offset).targets.first else {
            log("под \(target) компилятор не нашёл имени")
            return 2
        }
        guard let graph = graph(of: found, projects: projects, reach: reach) else {
            log("\(found.name) [\(found.kind)] — не значение: ни поле, ни переменная, ни параметр, ни метод, ни компонент")
            return 2
        }
        // Замер скорости (bin/pilot-perf): подъём проекта и сам граф — отдельно.
        if PerfConfig.environment["PILOT_PERF_OUT"] != nil {
            let built = building.finish()
            PerfReport.emit("engine.graph",
                            PerfReport.metrics("graph.load", loaded).merging(PerfReport.metrics("graph.build", built)) { $1 },
                            info: ["target": target, "nodes": "\(graph.nodes.count)"])
        }

        if arguments.contains("--json") {
            print(json(graph))
        } else {
            print(tree(graph))
            let summary = sourcesSummary(graph)
            if !summary.isEmpty { print("источники: " + summary) }
        }
        let expectations = arguments.indices.filter { arguments[$0] == "--expect" && $0 + 1 < arguments.count }
            .map { arguments[$0 + 1] }
        var failed = 0
        for expectation in expectations {
            let ok = graph.hasPath(expectation.components(separatedBy: "<-").map { $0.trimmingCharacters(in: .whitespaces) })
            print((ok ? "✓ " : "✗ ") + expectation)
            if !ok { failed += 1 }
        }
        return failed == 0 ? 0 : 1
    }

    /// Проект над `start` и вторая половина его пары: правила расширений —
    /// обеих половин, компилятор и индекс — из кэша.
    private static func load(from start: URL) -> Projects? {
        guard let root = projectRoot(from: start) else {
            log("над \(start.path) нет папки с .git — не понять, какой это проект")
            return nil
        }
        let own = (Workspace.builtIns(for: root) + ProjectExtension.discover(in: root).found).map(\.manifest.rules)
        let partnerRoot = ProjectPair.partner(of: root, links: [:], extra: ProjectRules.merged(own).pair.suffixes) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let theirs = partnerRoot.map {
            (Workspace.builtIns(for: $0) + ProjectExtension.discover(in: $0).found).map(\.manifest.rules)
        } ?? []
        let rules = ProjectRules.merged(own + theirs)
        let home = Project(root: root, partner: partnerRoot, rules: rules)
        var projects: [String: Project] = [root.path: home]
        if let partnerRoot { projects[partnerRoot.path] = Project(root: partnerRoot, partner: root, rules: rules) }
        return Projects(home: home, lookup: { projects[$0.path] })
    }

    /// Граф того, что нашёл компилятор, — как по ⌥⌘G: поле, свойство,
    /// переменная — кто их пишет и откуда это берётся, параметр — что в него
    /// передают, метод — что он возвращает, класс и структура — где
    /// компонент ставят и снимают.
    private static func graph(of found: RustlynTarget, projects: Projects, reach: ValueGraph.Reach) -> ValueGraph? {
        let home = projects.home
        guard let root = home.root, let rustlyn = home.rustlyn else { return nil }
        let context = ValueGraphAnalysis.Context(root: root, rustlyn: rustlyn, texts: [:], index: home.symbolIndex,
                                                 network: home.rules.datagrams, configs: home.rules.configs)
        guard let start = context.root(for: found) else { return nil }
        return ValueGraph(home: home, lookup: projects.lookup, root: start, synchronous: true, reach: reach)
    }

    // MARK: - Обзор папки

    /// Где граф теряет след.
    struct Losses {
        /// Имена, дальше которых граф не прошёл, — почему и где они стоят.
        var unknown: [(name: String, reason: String, site: ValueGraph.Node?)] = []
        /// Раскрытия, которые ничего не дали (кроме самого значения).
        var empty: [ValueGraph.Node] = []
        /// У самого значения записей не нашлось.
        var rootEmpty = false
        /// Поля, найденные по имени, а не компилятором.
        var guessed = 0
        /// Узлы, которые можно раскрыть, но граф упёрся в предел.
        var unexplored = 0
        /// Значения, которых код не пишет, с известным источником: база, конфиг, инспектор.
        var origins: [String] = []
        /// Источники, до которых граф дошёл, — по видам.
        var sources: [ValueOrigin.Kind] = []

        @MainActor init(_ graph: ValueGraph) {
            for id in graph.order {
                guard let node = graph.nodes[id] else { continue }
                if node.kind == .unknown || node.kind == .call(nil) {
                    let site = graph.edges.first { $0.from == id }.flatMap { graph.nodes[$0.to] }
                    let reason = node.kind == .unknown ? node.subtitle : "вызов не узнан"
                    unknown.append((node.title, reason, site))
                }
                if node.guessed { guessed += 1 }
                if case .failed = node.state {
                    if id == graph.rootID { rootEmpty = true } else { empty.append(node) }
                }
                if node.state == .collapsed, node.isExpandable { unexplored += 1 }
                if let origin = node.origin { origins.append(origin) }
                if case .source(let origin, _) = node.kind { sources.append(origin.kind) }
            }
        }

        var isClean: Bool { unknown.isEmpty && empty.isEmpty && !rootEmpty && guessed == 0 }
    }

    /// Граф каждого поля и свойства из файлов папки: строка на граф и что
    /// он не смог. Код выхода 0 — это обзор, а не проверка.
    private static func survey(_ folder: URL, projects: Projects, reach: ValueGraph.Reach, verbose: Bool) -> Int32 {
        let home = projects.home
        guard let root = home.root, let index = home.symbolIndex, let rustlyn = home.rustlyn else {
            log("нет индекса или компилятора — проект должен хоть раз открываться в Pilot")
            return 2
        }
        let prefix = folder.path == root.path ? "" : String(folder.path.dropFirst(root.path.count + 1)) + "/"
        let kinds: Set<OutlineKind> = [.field, .property, .serializedField]
        let members = (0..<Int32(index.count))
            .filter { kinds.contains(index[$0].kind) && index.relPath($0).hasPrefix(prefix) }
            .sorted { (index.relPath($0), index[$0].line) < (index.relPath($1), index[$1].line) }
        log("\(prefix.isEmpty ? root.lastPathComponent : prefix): полей и свойств \(members.count)")

        var graphs = 0, nodes = 0, unresolved = 0, rootEmpty = 0, guessed = 0, cut = 0, clean = 0, sourced = 0
        var unknownNames: [String: [String: Int]] = [:]
        var emptyByKind: [String: Int] = [:]
        var originCounts: [String: Int] = [:]
        var sourceCounts: [ValueOrigin.Kind: Int] = [:]
        var slowest: (title: String, seconds: Double)?
        var models: [URL: SyntaxModel] = [:]
        let started = Date()
        for id in members {
            let symbol = index[id]
            let url = root.appendingPathComponent(index.relPath(id))
            let title = [symbol.container?.split(separator: ".").last.map(String.init), symbol.name]
                .compactMap { $0 }.joined(separator: ".")
            if models[url] == nil, let text = SymbolIndex.readSource(url) { models[url] = SyntaxModel(text: text, spec: nil) }
            guard let model = models[url] else { continue }
            let offset = model.offset(at: LSPPosition(line: Int(symbol.line), character: Int(symbol.column)))
            guard let found = rustlyn.definition(url, offset: offset).targets.first,
                  [.field, .property].contains(found.kind) else {
                unresolved += 1
                print("? \(title) — компилятор не узнал объявление · \(url.lastPathComponent):\(symbol.line + 1)")
                continue
            }
            let begun = Date()
            guard let graph = graph(of: found, projects: projects, reach: reach) else { continue }
            let seconds = Date().timeIntervalSince(begun)
            graphs += 1
            nodes += graph.nodes.count
            if seconds > slowest?.seconds ?? 0 { slowest = (graph.title, seconds) }

            let losses = Losses(graph)
            if losses.rootEmpty { rootEmpty += 1 }
            if losses.unexplored > 0 { cut += 1 }
            if losses.isClean { clean += 1 }
            guessed += losses.guessed
            for unknown in losses.unknown { unknownNames[unknown.reason, default: [:]][unknown.name, default: 0] += 1 }
            for node in losses.empty { emptyByKind[kindName(node.kind), default: 0] += 1 }
            for origin in losses.origins { originCounts[origin, default: 0] += 1 }
            for kind in losses.sources { sourceCounts[kind, default: 0] += 1 }
            if !losses.sources.isEmpty { sourced += 1 }

            var line = "\(graph.title) · \(graph.nodes.count) узл. · \(String(format: "%.1f", seconds)) с"
            if losses.rootEmpty { line += " · записей нет" }
            if !losses.unknown.isEmpty { line += " · не узнано \(losses.unknown.count)" }
            if !losses.empty.isEmpty { line += " · пусто \(losses.empty.count)" }
            if losses.guessed > 0 { line += " · по имени \(losses.guessed)" }
            if losses.unexplored > 0 { line += " · не раскрыто \(losses.unexplored)" }
            print(line)
            if verbose {
                print(tree(graph).split(separator: "\n").map { "   │ " + $0 }.joined(separator: "\n"))
            }
            for unknown in losses.unknown {
                let place = unknown.site.map { site in
                    " — в \(site.title)" + (site.url.map { url in " · \(url.lastPathComponent):\((site.line ?? 0) + 1)" } ?? "")
                } ?? ""
                print("   ? «\(unknown.name)» — \(unknown.reason)\(place)")
            }
            for node in losses.empty {
                var why = ""
                if case .failed(let reason) = node.state { why = reason }
                print("   ∅ \(describe(node)) — \(why)")
            }
        }

        let total = Date().timeIntervalSince(started)
        print("")
        print("полей и свойств \(members.count), графов \(graphs), узлов \(nodes), \(String(format: "%.0f", total)) с"
              + (slowest.map { " · дольше всех \($0.title) \(String(format: "%.1f", $0.seconds)) с" } ?? ""))
        print("чистых графов: \(clean) из \(graphs)")
        print("графов с источниками: \(sourced) из \(graphs)")
        if unresolved > 0 { print("объявлений, которых не узнал компилятор: \(unresolved)") }
        print("значений без записей: \(rootEmpty)")
        for (reason, names) in unknownNames.sorted(by: { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }) {
            let top = names.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(12)
                .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
            print("\(reason): \(names.values.reduce(0, +)) — " + top.joined(separator: ", "))
        }
        if !emptyByKind.isEmpty {
            print("пустые раскрытия: " + emptyByKind.sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        if !originCounts.isEmpty {
            print("код не пишет, но известно откуда: " + originCounts.sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        if !sourceCounts.isEmpty {
            print("источники: " + sourceCounts.sorted { ($1.value, $0.key.rawValue) < ($0.value, $1.key.rawValue) }
                .map { "\($0.key.label) \($0.value)" }.joined(separator: ", "))
        }
        if guessed > 0 { print("найдено по имени: \(guessed)") }
        if cut > 0 { print("упёрлись в предел (--limit, --depth): \(cut) графов") }
        return 0
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

    private static func kindName(_ kind: ValueGraph.Node.Kind) -> String {
        switch kind {
        case .value: return "значение"
        case .component: return "компонент"
        case .site: return "код"
        case .condition: return "условие"
        case .arrival: return "приход"
        case .network: return "сеть"
        case .call: return "вызов"
        case .parameter: return "параметр"
        case .source(let origin, _): return "источник: \(origin.kind.label)"
        case .data: return "данные"
        case .more: return "ещё"
        case .unknown: return "не узнано"
        }
    }

    /// Источники графа одной строкой: `константа 1500 · время Time.deltaTime`.
    static func sourcesSummary(_ graph: ValueGraph) -> String {
        var seen: Set<String> = []
        return graph.sources.compactMap { node -> String? in
            guard case .source(let origin, _) = node.kind else { return nil }
            let text = "\(origin.kind.label) \(origin.title)"
            return seen.insert(text).inserted ? text : nil
        }.joined(separator: " · ")
    }

    private static func describe(_ node: ValueGraph.Node) -> String {
        var text = "\(node.title) [\(kindName(node.kind)), \(ProjectPair.label(of: node.project))]"
        if let url = node.url, let line = node.line { text += " \(url.lastPathComponent):\(line + 1)" }
        if let focus = node.preview.first(where: { $0.number == node.line }) {
            text += "  │ " + focus.text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    static func json(_ graph: ValueGraph) -> String {
        let nodes: [[String: Any]] = graph.order.compactMap { graph.nodes[$0] }.map { node in
            var entry: [String: Any] = ["id": node.id, "title": node.title, "subtitle": node.subtitle,
                                        "project": node.project.path, "depth": node.depth, "kind": kindName(node.kind)]
            if case .source(let origin, _) = node.kind { entry["source"] = origin.kind.rawValue }
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

    /// Папка, если `path` — она.
    private static func directory(_ path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func projectRoot(from start: URL) -> URL? {
        var directory = start
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
