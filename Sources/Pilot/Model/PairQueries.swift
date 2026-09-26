import Foundation

/// Индексы второй половины пары: из её окна, если оно открыто, иначе те,
/// что она оставила на диске в прошлый раз. Сверять датаграммы и искать
/// в сервере можно и не открывая его.
struct PairIndex {
    let root: URL
    /// `client`, `server` — для подписи строк.
    let label: String
    let symbols: SymbolIndex?
    let files: FileIndex?
}

/// Запросы между половинами пары по их индексам: какие датаграммы
/// разошлись, где двойник имени, что связано с конфигом. Без AppKit и без
/// воркспейса — поэтому их проверяют тесты ядра и можно прогнать по
/// настоящим проектам отдельной программой.
enum PairQueries {

    /// Двойники имени во второй половине: член того же типа, иначе тип,
    /// иначе всё одноимённое.
    static func twins(of name: String, container: String?, in index: SymbolIndex) -> [Int32] {
        if let container {
            let short = container.split(separator: ".").last.map(String.init) ?? container
            for owner in [container, short] {
                let members = (index.membersByOwner[owner] ?? []).filter { index[$0].name == name }
                if !members.isEmpty { return members }
            }
        }
        if let types = index.typesByName[name], !types.isEmpty { return types }
        return index.byName[name] ?? []
    }

    /// Датаграммы индекса: имя → объявление.
    static func datagrams(in index: SymbolIndex, rules: DatagramRules) -> [String: Int32] {
        var result: [String: Int32] = [:]
        for id in index.derivedByBase[SymbolIndex.baseKey(rules.interface)] ?? [] {
            let symbol = index[id]
            guard symbol.kind == .type, symbol.keyword != "interface" else { continue }
            if result[symbol.name] == nil { result[symbol.name] = id }
        }
        return result
    }

    static func contractReport(own: SymbolIndex, theirs: SymbolIndex, label: String, ownLabel: String,
                               rules: DatagramRules) -> [PaletteItem] {
        let ours = datagrams(in: own, rules: rules)
        let others = datagrams(in: theirs, rules: rules)
        let common = Array(Set(ours.keys).intersection(others.keys)).sorted()

        // Разбор — на всех ядрах: их бывают тысячи с каждой стороны.
        var issues = [[DatagramIssue]?](repeating: nil, count: common.count)
        issues.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: common.count) { i in
                let name = common[i]
                guard let a = ours[name], let b = others[name],
                      let ownText = SymbolIndex.readSource(own.target(a).url),
                      let otherText = SymbolIndex.readSource(theirs.target(b).url),
                      let ownShape = DatagramContract.shape(named: name, in: ownText, rules: rules),
                      let otherShape = DatagramContract.shape(named: name, in: otherText, rules: rules) else { return }
                buffer[i] = DatagramContract.compare(ownShape, with: otherShape, label: label, rules: rules)
            }
        }

        var broken: [PaletteItem] = [], lonely: [PaletteItem] = [], renamed: [PaletteItem] = []
        for (i, name) in common.enumerated() {
            guard let found = issues[i], !found.isEmpty, let id = ours[name] else { continue }
            let breaks = found.filter(\.breaksWire)
            let shown = breaks.first ?? found[0]
            let more = (breaks.isEmpty ? found.count : breaks.count) - 1
            let item = PaletteItem(id: 0, icon: breaks.isEmpty ? "textformat" : "exclamationmark.triangle",
                                   primary: name,
                                   secondary: shown.message + (more > 0 ? " · ещё \(more)" : ""),
                                   trailing: breaks.isEmpty ? "имена" : "провод",
                                   target: own.target(id))
            if breaks.isEmpty { renamed.append(item) } else { broken.append(item) }
        }
        for name in Set(ours.keys).subtracting(others.keys).sorted() {
            guard let id = ours[name] else { continue }
            lonely.append(PaletteItem(id: 0, icon: "arrow.up.right", primary: name,
                                      secondary: "Есть только в \(ownLabel) · \(own.relPath(id))",
                                      trailing: "нет в \(label)", target: own.target(id)))
        }
        for name in Set(others.keys).subtracting(ours.keys).sorted() {
            guard let id = others[name] else { continue }
            lonely.append(PaletteItem(id: 0, icon: "arrow.down.left", primary: name,
                                      secondary: "Есть только в \(label) · \(theirs.relPath(id))",
                                      trailing: "только в \(label)", target: theirs.target(id)))
        }
        return (broken + lonely + renamed).enumerated().map { position, item in
            var item = item
            item.id = position
            return item
        }
    }

    static func pairDiagnostics(text: String, theirs: SymbolIndex, label: String,
                                rules: DatagramRules) -> [RustlynDiagnostic] {
        let others = datagrams(in: theirs, rules: rules)
        // Если во второй половине датаграмм нет вовсе, её индекс не про то —
        // «нет в server» у каждой было бы шумом.
        guard !others.isEmpty else { return [] }
        var result: [RustlynDiagnostic] = []
        for name in declaredDatagrams(in: text, rules: rules) {
            guard let own = DatagramContract.shape(named: name, in: text, rules: rules) else { continue }
            guard let id = others[name] else {
                result.append(RustlynDiagnostic(range: own.nameRange, severity: .info, code: "PAIR",
                                                message: "В \(label) нет датаграммы \(name) — на проводе её там не узнают"))
                continue
            }
            guard let otherText = SymbolIndex.readSource(theirs.target(id).url),
                  let other = DatagramContract.shape(named: name, in: otherText, rules: rules) else { continue }
            for issue in DatagramContract.compare(own, with: other, label: label, rules: rules) {
                result.append(RustlynDiagnostic(range: issue.range, severity: issue.breaksWire ? .warning : .info,
                                                code: "PAIR", message: issue.message))
            }
        }
        return result
    }

    /// Имена структур файла, которые объявляют себя датаграммами.
    static func declaredDatagrams(in text: String, rules: DatagramRules) -> [String] {
        let pattern = #"(?:struct|class)\s+([A-Za-z_][A-Za-z0-9_]*)[^{;]*\b"#
            + NSRegularExpression.escapedPattern(for: rules.interface) + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    static func usageIcon(_ usage: DatagramContract.Usage?) -> String {
        switch usage {
        case .sends: return "paperplane"
        case .receives: return "tray.and.arrow.down"
        case nil: return "arrow.turn.down.right"
        }
    }

    static func usageTrailing(_ usage: DatagramContract.Usage?, line: Int) -> String {
        switch usage {
        case .sends: return "шлёт · :\(line + 1)"
        case .receives: return "ловит · :\(line + 1)"
        case nil: return ":\(line + 1)"
        }
    }

    static func configLinks(file: URL, text: String, offset: Int, line: String,
                            sides: [PairIndex], rules: ConfigRules) -> [PaletteItem] {
        var result: [PaletteItem] = []
        var seen = Set<String>()
        func add(_ item: PaletteItem) {
            let key = "\(item.target.url.path):\(item.target.range?.start.line ?? -1)"
            if seen.insert(key).inserted { result.append(item) }
        }
        func csharp(_ side: PairIndex) -> [String] { side.files?.display.filter { $0.hasSuffix(".cs") } ?? [] }
        func search(_ needle: String, in side: PairIndex, paths: [String], limit: Int = 200) -> [(String, TextHit)] {
            var options = ContentSearch.Options()
            options.limit = limit
            return ContentSearch.search(needle, root: side.root, paths: paths, options: options, shouldStop: { false })
                .map { (paths[Int($0.file)], $0) }
        }
        func item(_ side: PairIndex, _ path: String, _ hit: TextHit, icon: String, what: String) -> PaletteItem {
            let start = LSPPosition(line: hit.line, character: hit.column)
            return PaletteItem(id: 0, icon: icon, primary: hit.text, secondary: "\(side.label) · \(path)",
                               trailing: "\(what) · :\(hit.line + 1)",
                               target: NavTarget(url: side.root.appendingPathComponent(path),
                                                 range: LSPRange(start: start, end: start)))
        }
        func types(_ name: String, icon: String, what: String) {
            for side in sides {
                guard let symbols = side.symbols else { continue }
                for id in symbols.typesByName[name] ?? [] {
                    add(PaletteItem(id: 0, icon: icon, primary: name,
                                    secondary: "\(side.label) · \(symbols.relPath(id))",
                                    trailing: what, target: symbols.target(id)))
                }
            }
        }
        /// Поля с атрибутом ключа (`[JsonProperty("key")]`) в обеих половинах.
        func properties(_ key: String) {
            for side in sides {
                for (path, hit) in search("\"\(key)\"", in: side, paths: csharp(side))
                where ConfigLinks.jsonProperty(in: hit.text, attribute: rules.keyAttribute) == key {
                    add(item(side, path, hit, icon: "curlybraces", what: "поле"))
                }
            }
        }
        /// alias → константа, модель и те, кто читает, в обеих половинах.
        func alias(_ alias: String) {
            for side in sides {
                let paths = csharp(side)
                for path in paths where path.hasSuffix("/" + rules.aliasesFile) || path == rules.aliasesFile {
                    let url = side.root.appendingPathComponent(path)
                    guard let source = SymbolIndex.readSource(url),
                          let declaration = ConfigLinks.declaration(of: alias, in: source) else { continue }
                    let position = LSPPosition(line: declaration.line, character: 0)
                    add(PaletteItem(id: 0, icon: "tag", primary: "\(declaration.constant) = \"\(alias)\"",
                                    secondary: "\(side.label) · \(path)", trailing: "alias",
                                    target: NavTarget(url: url, range: LSPRange(start: position, end: position))))
                    if let model = declaration.model { types(model, icon: "cube", what: "модель") }
                    for (usePath, hit) in search("\(rules.aliases).\(declaration.constant)", in: side, paths: paths)
                    where hit.wholeWord {
                        add(item(side, usePath, hit, icon: "arrow.turn.down.right", what: "читает"))
                    }
                }
            }
        }
        /// JSON с этим alias по реестру той половины, где он лежит.
        func jsonFiles(alias wanted: String) {
            for side in sides {
                for path in side.files?.display ?? [] where (path as NSString).lastPathComponent == rules.registry {
                    let meta = side.root.appendingPathComponent(path)
                    guard let data = try? Data(contentsOf: meta) else { continue }
                    let folder = (path as NSString).deletingLastPathComponent
                    for (file, alias) in ConfigLinks.aliases(meta: data) where alias == wanted {
                        let relative = folder.isEmpty ? file : folder + "/" + file
                        add(PaletteItem(id: 0, icon: "doc.text", primary: (file as NSString).lastPathComponent,
                                        secondary: "\(side.label) · \(relative)", trailing: "конфиг",
                                        target: NavTarget(url: side.root.appendingPathComponent(relative), range: nil)))
                    }
                }
            }
        }

        if file.pathExtension.lowercased() == "json" {
            if let key = ConfigLinks.jsonKey(at: offset, in: text) { properties(key) }
            if let configs = ConfigLinks.configsRoot(of: file, registry: rules.registry, exists: { FileManager.default.fileExists(atPath: $0) }),
               let data = try? Data(contentsOf: configs.appendingPathComponent(rules.registry)) {
                let relative = String(file.path.dropFirst(configs.path.count + 1))
                if let name = ConfigLinks.aliases(meta: data)[relative] { alias(name) }
            }
        } else if let key = ConfigLinks.jsonProperty(in: line, attribute: rules.keyAttribute) {
            properties(key)
            // И сами JSON, где этот ключ есть.
            for side in sides {
                let json = side.files?.display.filter { $0.hasSuffix(".json") } ?? []
                for (path, hit) in search("\"\(key)\"", in: side, paths: json, limit: 100) {
                    add(item(side, path, hit, icon: "doc.text", what: "конфиг"))
                }
            }
        } else if let name = ConfigLinks.alias(declaredIn: line) {
            jsonFiles(alias: name)
            alias(name)
        }
        return result
    }
}
