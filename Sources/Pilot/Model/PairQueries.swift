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

    /// Тип `name` — датаграмма этого индекса, в том же смысле, что у `datagrams`.
    static func isDatagram(_ name: String, in index: SymbolIndex, rules: DatagramRules) -> Bool {
        let base = SymbolIndex.baseKey(rules.interface)
        return (index.typesByName[name] ?? []).contains { id in
            let symbol = index[id]
            return symbol.kind == .type && symbol.keyword != "interface"
                && symbol.bases.contains { SymbolIndex.baseKey($0) == base }
        }
    }

    /// Сверка одной датаграммы: первая строка — она сама во второй
    /// половине, дальше её расхождения с ней (сначала те, что ломают
    /// провод) с переходом к полю или шагу в своём файле. nil — во второй
    /// половине такой датаграммы нет.
    static func datagramReport(named name: String, ownText: String, ownURL: URL, ownPath: String, ownLabel: String,
                               theirs: SymbolIndex, label: String, rules: DatagramRules) -> [PaletteItem]? {
        guard let id = datagrams(in: theirs, rules: rules)[name] else { return nil }
        let twin = theirs.target(id)
        var items = [PaletteItem(id: 0, icon: "arrow.left.arrow.right", primary: name,
                                 secondary: "\(label) · \(theirs.relPath(id))", trailing: L("двойник"), target: twin)]
        guard let own = DatagramContract.shape(named: name, in: ownText, rules: rules),
              let otherText = SymbolIndex.readSource(twin.url),
              let other = DatagramContract.shape(named: name, in: otherText, rules: rules) else { return items }
        let issues = DatagramContract.compare(own, with: other, label: label, rules: rules)
        for issue in issues.filter(\.breaksWire) + issues.filter({ !$0.breaksWire }) {
            let range = LSPRange(start: position(of: issue.range.location, in: ownText),
                                 end: position(of: issue.range.location + issue.range.length, in: ownText))
            items.append(PaletteItem(id: items.count, icon: issue.breaksWire ? "exclamationmark.triangle" : "textformat",
                                     primary: issue.message, secondary: "\(ownLabel) · \(ownPath)",
                                     trailing: issue.breaksWire ? L("провод") : L("имена"),
                                     target: NavTarget(url: ownURL, range: range)))
        }
        return items
    }

    /// Строка и колонка (UTF-16, как у LSP) смещения в тексте.
    static func position(of offset: Int, in text: String) -> LSPPosition {
        var line = 0, lineStart = 0, index = 0
        for unit in text.utf16 {
            guard index < offset else { break }
            if unit == 0x0A { line += 1; lineStart = index + 1 }
            index += 1
        }
        return LSPPosition(line: line, character: offset - lineStart)
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

    /// Связи конфига и кода у строки курсора. `model` — тип этой строки:
    /// объявленный в ней или тот, чьё поле с ключом в ней объявлено. У поля
    /// первыми идут ключи в конфигах этой модели, а объявление модели ведёт
    /// к её конфигам и alias'ам — так же, как строка самого alias'а.
    static func configLinks(file: URL, text: String, offset: Int, line: String, model: String? = nil,
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
        /// Тип объявлен в одной из половин.
        func isType(_ name: String) -> Bool { sides.contains { $0.symbols?.typesByName[name] != nil } }
        /// Классы алиасов половины — разбираются один раз на запрос.
        var aliasClasses: [Int: ConfigModels] = [:]
        func models(_ i: Int) -> ConfigModels {
            if let known = aliasClasses[i] { return known }
            let side = sides[i]
            let found = ConfigModels(files: csharp(side)
                .filter { $0.hasSuffix("/" + rules.aliasesFile) || $0 == rules.aliasesFile }
                .compactMap { path in
                    SymbolIndex.readSource(side.root.appendingPathComponent(path)).map { (path: path, text: $0) }
                })
            aliasClasses[i] = found
            return found
        }
        /// alias → константа, модель и те, кто читает, в обеих половинах.
        /// Модель — как у «Модели конфига»: последнее имя в `typeof(…)`,
        /// которое — тип (атрибут может стоять и строкой выше).
        func alias(_ alias: String, readers: Bool = true) {
            for (i, side) in sides.enumerated() {
                for use in models(i).uses(ofAlias: alias) {
                    let declaration = use.declaration
                    add(PaletteItem(id: 0, icon: "tag", primary: "\(declaration.constant) = \"\(alias)\"",
                                    secondary: "\(side.label) · \(use.file)", trailing: "alias",
                                    target: use.target(root: side.root)))
                    for text in declaration.types {
                        if let model = ConfigLinks.model(inTypeof: text, isType: isType) {
                            types(model, icon: "cube", what: "модель")
                        }
                    }
                    guard readers else { continue }
                    for (usePath, hit) in search("\(rules.aliases).\(declaration.constant)", in: side, paths: csharp(side))
                    where hit.wholeWord {
                        add(item(side, usePath, hit, icon: "arrow.turn.down.right", what: "читает"))
                    }
                }
            }
        }
        /// Alias'ы, чья модель — `name`, в обеих половинах, по порядку объявления.
        func aliases(ofModel name: String) -> [String] {
            var result: [String] = []
            for i in sides.indices {
                for use in models(i).uses(ofModel: name, isType: isType) where !result.contains(use.alias) {
                    result.append(use.alias)
                }
            }
            return result
        }
        /// Реестры половин: путь JSON от корня половины → alias.
        var registries: [Int: [(path: String, alias: String)]] = [:]
        func registry(_ i: Int) -> [(path: String, alias: String)] {
            if let known = registries[i] { return known }
            var found: [(path: String, alias: String)] = []
            for path in sides[i].files?.display ?? [] where (path as NSString).lastPathComponent == rules.registry {
                guard let data = try? Data(contentsOf: sides[i].root.appendingPathComponent(path)) else { continue }
                let folder = (path as NSString).deletingLastPathComponent
                for (file, alias) in ConfigLinks.aliases(meta: data).sorted(by: { $0.key < $1.key }) {
                    found.append((folder.isEmpty ? file : folder + "/" + file, alias))
                }
            }
            registries[i] = found
            return found
        }
        /// JSON с этим alias по реестру той половины, где он лежит.
        func jsonFiles(alias wanted: String) {
            for (i, side) in sides.enumerated() {
                for entry in registry(i) where entry.alias == wanted {
                    add(PaletteItem(id: 0, icon: "doc.text", primary: (entry.path as NSString).lastPathComponent,
                                    secondary: "\(side.label) · \(entry.path)", trailing: "конфиг",
                                    target: NavTarget(url: side.root.appendingPathComponent(entry.path), range: nil)))
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
            // Поле модели конфига — сперва этот ключ в её конфигах, по
            // первому в файле: общий поиск ниже упирается в предел и до них
            // может не дойти.
            if let model {
                let wanted = aliases(ofModel: model)
                for (i, side) in sides.enumerated() {
                    let entries = registry(i)
                    let paths = wanted.flatMap { alias in entries.filter { $0.alias == alias }.map(\.path) }
                    var done = Set<String>()
                    for (path, hit) in search("\"\(key)\"", in: side, paths: paths, limit: 400)
                    where ConfigLinks.isKey(key, in: hit.text) {
                        guard done.insert(path).inserted else { continue }
                        add(item(side, path, hit, icon: "doc.text", what: "конфиг"))
                    }
                }
            }
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
        } else if let model {
            // Объявление модели конфига: её JSON, она сама в обеих половинах
            // (двойник — там же) и alias'ы, которые её читают. Кто читает
            // каждый конфиг — только когда их немного: это поиск по всему C#
            // на каждый alias.
            let names = aliases(ofModel: model)
            names.forEach { jsonFiles(alias: $0) }
            types(model, icon: "cube", what: "модель")
            names.forEach { alias($0, readers: names.count <= 3) }
        }
        return result
    }
}
