import Foundation

/// Поиск для графа значения — в фоне, на очереди запросов к компилятору
/// проекта. Компилятор (Rustlyn) говорит, где упомянуто имя и что оно
/// значит; `ValueFlow` — запись это или чтение и что стоит справа.
enum ValueGraphAnalysis {

    struct Source {
        enum Kind {
            case value(ValueGraph.Declaration)
            case call(String, ValueGraph.Declaration?)
            case parameter(String, ValueGraph.Declaration?, Int)
            case unknown(String)
        }
        var kind: Kind
        /// Локальные переменные, через которые значение пришло: `dmg ← mult`.
        var via: [String] = []
        /// Компилятор имя не узнал — нашли поле с таким именем в индексе.
        var byName = false
    }

    /// Когда место выполняется.
    enum Trigger {
        /// Цикл по типу-приёмнику из правил (`PacketFilter<T>`): пришла T.
        case network(String, receiver: String)
        /// Цикл по фильтру Morpeh.
        case filter(name: String, with: [String], without: [String])
    }

    struct Site {
        var url: URL
        var offset: Int
        var line: Int
        var title: String
        var note: String?
        /// Чтение датаграммы из сети — в её же `Read`.
        var isNetworkRead = false
        var sources: [Source] = []
        var trigger: Trigger?
        var filterLine: Int?
        /// Строки с разметкой лексера — для подсветки в карточке.
        var preview: [FilePreview.Line] = []
        var methodLines: [FilePreview.Line] = []
    }

    final class Context: @unchecked Sendable {
        let root: URL
        let rustlyn: Rustlyn
        let texts: [URL: String]
        let index: SymbolIndex?
        let datagrams: Set<String>
        /// Сетевые правила расширения: без них граф через сеть не ходит.
        let network: DatagramRules?
        private var models: [URL: SyntaxModel] = [:]
        private var outlines: [URL: RustlynOutline] = [:]

        init(root: URL, rustlyn: Rustlyn, texts: [URL: String], index: SymbolIndex?, network: DatagramRules?) {
            self.root = root
            self.rustlyn = rustlyn
            self.texts = texts
            self.index = index
            self.network = network
            if let index, let network {
                datagrams = Set(PairQueries.datagrams(in: index, rules: network).keys)
            } else {
                datagrams = []
            }
        }

        // MARK: Записи в поле

        func writes(to declaration: ValueGraph.Declaration) -> [Site] {
            guard let model = model(declaration.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: declaration.line, character: declaration.character))
            let references = rustlyn.references(declaration.url, offset: offset, text: texts[declaration.url])
            var sites: [Site] = []
            var reads = 0
            for target in references.targets {
                if target.url == declaration.url, target.line == declaration.line,
                   target.character == declaration.character { continue }
                guard let model = self.model(target.url) else { continue }
                let at = model.offset(at: LSPPosition(line: target.line, character: target.character))
                let access = ValueFlow.access(in: model.units, name: NSRange(location: at, length: target.length))
                guard case .write(let rhs, let compound) = access else { reads += 1; continue }
                let method = enclosingMember(target.url, at: at)
                var site = makeSite(target.url, model: model, at: at, method: method)
                site.note = compound ? L("меняет прежнее значение") : nil
                site.isNetworkRead = (network?.read.contains(method?.name ?? "") ?? false)
                    && method?.container?.split(separator: ".").last.map(String.init) == declaration.typeName
                if let rhs {
                    site.sources = resolve(ValueFlow.sources(in: model.units, range: rhs), url: target.url,
                                           model: model, method: method, via: [], depth: 0)
                }
                sites.append(site)
            }
            let unknown = sites.flatMap(\.sources).filter { if case .unknown = $0.kind { return true }; return false }.count
            NSLog("[graph] %@: упоминаний %d, записей %d, чтений %d, неразрешённых имён %d — %@",
                  declaration.name, references.targets.count, sites.count, reads, unknown,
                  sites.map { "\($0.title):\($0.line + 1)\($0.isNetworkRead ? " (из сети)" : "")" }.joined(separator: ", "))
            return sites
        }

        // MARK: Компонент целиком

        /// `stash.Set(e)`, `.Add(`, `.Remove(` — где компонент появляется и где его убирают.
        func componentChanges(of component: String) -> [Site] {
            guard let index else { return [] }
            let stashType = "Stash<\(component)>"
            var stashes: [(name: String, url: URL)] = []
            for id in 0..<Int32(index.count) {
                let symbol = index[id]
                guard symbol.kind == .field,
                      symbol.typeText?.replacingOccurrences(of: " ", with: "") == stashType else { continue }
                let url = root.appendingPathComponent(index.relPath(id))
                if !stashes.contains(where: { $0.name == symbol.name && $0.url == url }) {
                    stashes.append((symbol.name, url))
                }
            }
            var sites: [Site] = []
            for stash in stashes {
                guard let model = model(stash.url) else { continue }
                for found in ValueFlow.stashCalls(in: model.units, stash: stash.name) {
                    let method = enclosingMember(stash.url, at: found.range.location)
                    var site = makeSite(stash.url, model: model, at: found.range.location, method: method)
                    switch found.call {
                    case .set, .setOrUpdate: site.note = L("Set — компонент появляется или обновляется")
                    case .add: site.note = L("Add — компонент появляется")
                    case .remove: site.note = L("Remove — компонент убирают")
                    }
                    sites.append(site)
                }
            }
            NSLog("[graph] компонент %@: стэшей %d, мест %d", component, stashes.count, sites.count)
            return sites
        }

        // MARK: Отправки датаграммы

        /// Методы, где датаграмму создают и шлют: упоминание типа и вызов
        /// отправки из правил (`.Send(`) рядом.
        func sends(of datagram: String) -> [Site] {
            guard let index, let network, let id = index.typesByName[datagram]?.first else { return [] }
            let url = root.appendingPathComponent(index.relPath(id))
            let symbol = index[id]
            guard let declModel = model(url) else { return [] }
            let offset = declModel.offset(at: LSPPosition(line: Int(symbol.line), character: Int(symbol.column)))
            let references = rustlyn.references(url, offset: offset, text: texts[url])
            var sites: [Site] = []
            var seen: Set<String> = []
            for target in references.targets where target.url != url {
                guard let model = model(target.url) else { continue }
                let at = model.offset(at: LSPPosition(line: target.line, character: target.character))
                guard let method = enclosingMember(target.url, at: at) else { continue }
                let body = ValueFlow.string(model.units, method.fullRange)
                guard let send = network.send.lazy.compactMap({ body.range(of: ".\($0)(") ?? body.range(of: "\($0)(ref") }).first
                else { continue }
                let key = "\(target.url.path)|\(method.fullRange.location)"
                guard seen.insert(key).inserted else { continue }
                let sendOffset = method.fullRange.location + body.utf16.distance(from: body.startIndex, to: send.lowerBound)
                var site = makeSite(target.url, model: model, at: sendOffset, method: method)
                site.note = L("отправка \(datagram)")
                sites.append(site)
            }
            NSLog("[graph] отправки %@: упоминаний %d (%@), методов с Send %d", datagram, references.targets.count,
                  references.targets.map { "\($0.url.lastPathComponent):\($0.line + 1)" }.joined(separator: ", "), sites.count)
            return sites
        }

        // MARK: Вызовы и параметры

        /// Что метод возвращает: каждое `return` — место со своими источниками.
        func returns(of method: ValueGraph.Declaration) -> [Site] {
            guard let model = model(method.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: method.line, character: method.character))
            guard let declaration = enclosingMember(method.url, at: offset) else { return [] }
            return ValueFlow.returnedExpressions(in: model.units, method: declaration.fullRange).map { expression in
                var site = makeSite(method.url, model: model, at: expression.location, method: declaration)
                site.note = L("возвращает")
                site.sources = resolve(ValueFlow.sources(in: model.units, range: expression), url: method.url,
                                       model: model, method: declaration, via: [], depth: 0)
                return site
            }
        }

        /// Аргумент номер `argument` во всех вызовах метода.
        func callers(of method: ValueGraph.Declaration, argument: Int) -> [Site] {
            guard let model = model(method.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: method.line, character: method.character))
            let references = rustlyn.references(method.url, offset: offset, text: texts[method.url])
            var sites: [Site] = []
            for target in references.targets {
                if target.url == method.url, target.line == method.line, target.character == method.character { continue }
                guard let model = self.model(target.url) else { continue }
                let at = model.offset(at: LSPPosition(line: target.line, character: target.character))
                guard let expression = ValueFlow.argument(in: model.units, after: NSRange(location: at, length: target.length),
                                                          index: argument) else { continue }
                let caller = enclosingMember(target.url, at: at)
                var site = makeSite(target.url, model: model, at: at, method: caller)
                site.note = L("вызывает \(method.shortName)")
                site.sources = resolve(ValueFlow.sources(in: model.units, range: expression), url: target.url,
                                       model: model, method: caller, via: [], depth: 0)
                sites.append(site)
            }
            return sites
        }

        // MARK: Имена справа

        /// Во что превращаются имена правой части: поле — узел значения,
        /// локальная — её объявление (рекурсивно), параметр и вызов — узлы,
        /// которые раскрываются дальше.
        private func resolve(_ found: [ValueFlow.Source], url: URL, model: SyntaxModel,
                             method: RustlynDeclaration?, via: [String], depth: Int) -> [Source] {
            let units = model.units
            var result: [Source] = []
            for source in found {
                let name = ValueFlow.string(units, source.range)
                let definition = rustlyn.definition(url, offset: source.range.location, text: texts[url])
                let target = definition.targets.first
                if source.call {
                    let declaration = target.flatMap { [.method, .constructor].contains($0.kind) ? declarationOf($0) : nil }
                    result.append(Source(kind: .call(source.chain, declaration), via: via))
                    continue
                }
                if let target, [.field, .property, .enumMember, .event].contains(target.kind) {
                    result.append(Source(kind: .value(declarationOf(target)), via: via))
                    continue
                }
                // Одиночное имя: локальная переменная или параметр.
                if source.chain == name, let method {
                    if depth < 6, let initializer = ValueFlow.localInitializer(in: units, name: name, within: method.fullRange,
                                                                                before: source.range.location) {
                        result += resolve(ValueFlow.sources(in: units, range: initializer), url: url, model: model,
                                          method: method, via: via + [name], depth: depth + 1)
                        continue
                    }
                    if let index = Self.parameterIndex(name, in: method) {
                        result.append(Source(kind: .parameter(name, declarationOf(method, model: model, url: url), index), via: via))
                        continue
                    }
                }
                // Компилятор не узнал — например, тип переменной цикла по
                // сгенерированному фильтру. Поле с таким именем — по индексу.
                if let guess = byName(name, in: units) {
                    result.append(Source(kind: .value(guess), via: via, byName: true))
                } else {
                    result.append(Source(kind: .unknown(source.chain), via: via))
                }
            }
            return result
        }

        /// Поле или свойство с этим именем: если их несколько — то, чей тип
        /// упомянут в файле рядом.
        private func byName(_ name: String, in units: [UInt16]) -> ValueGraph.Declaration? {
            guard let index else { return nil }
            let candidates = (index.byName[name] ?? []).filter { [.field, .property].contains(index[$0].kind) }
            guard !candidates.isEmpty else { return nil }
            let text = String(utf16CodeUnits: units, count: units.count)
            let preferred = candidates.filter { id in
                guard let owner = index[id].container?.split(separator: ".").last else { return false }
                return text.contains(owner)
            }
            guard let id = preferred.first ?? (candidates.count == 1 ? candidates.first : nil) else { return nil }
            let symbol = index[id]
            return ValueGraph.Declaration(url: root.appendingPathComponent(index.relPath(id)), line: Int(symbol.line),
                                          character: Int(symbol.column), length: Int(symbol.length),
                                          name: [symbol.container, symbol.name].compactMap { $0 }.joined(separator: "."))
        }

        /// `ref T x`, `in T x = 1` — номер параметра по имени.
        static func parameterIndex(_ name: String, in method: RustlynDeclaration) -> Int? {
            method.parameters.firstIndex { parameter in
                let head = parameter.split(separator: "=").first ?? Substring(parameter)
                return head.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) == name
            }
        }

        // MARK: Когда выполняется

        private func trigger(url: URL, model: SyntaxModel, at offset: Int, method: RustlynDeclaration?) -> (Trigger, Int)? {
            guard let method else { return nil }
            let units = model.units
            guard let loop = ValueFlow.enclosingForeach(in: units, range: method.fullRange, containing: offset) else { return nil }
            let expression = ValueFlow.string(units, loop)
            // Фильтр прямо в цикле.
            if expression.contains("With<") || expression.contains("Without<") {
                let parts = ValueFlow.filterComponents(in: units, range: loop)
                return (.filter(name: "", with: parts.with, without: parts.without), model.line(containing: loop.location))
            }
            // Поле: его объявление и присваивание.
            guard expression.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
            let text = String(utf16CodeUnits: units, count: units.count)
            let escaped = NSRegularExpression.escapedPattern(for: expression)
            let ns = text as NSString
            // Цикл по типу-приёмнику из правил (`PacketFilter<T>`): пришла T.
            for receiver in network?.receive ?? [] {
                let pattern = NSRegularExpression.escapedPattern(for: receiver) + #"\s*<\s*([\w.]+)\s*>\s+"# + escaped + #"\b"#
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
                let type = ns.substring(with: match.range(at: 1)).split(separator: ".").last.map(String.init) ?? ""
                return (.network(type, receiver: receiver), model.line(containing: match.range.location))
            }
            let assignment = try! NSRegularExpression(pattern: #"\b"# + escaped + #"\s*=\s*[^;]*Filter[^;]*;"#)
            if let match = assignment.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let parts = ValueFlow.filterComponents(in: units, range: match.range)
                return (.filter(name: expression, with: parts.with, without: parts.without),
                        model.line(containing: match.range.location))
            }
            return nil
        }

        // MARK: Мелочи

        private func makeSite(_ url: URL, model: SyntaxModel, at offset: Int, method: RustlynDeclaration?) -> Site {
            let line = model.line(containing: offset)
            let first = max(0, line - 1)
            let last = min(model.lineCount - 1, line + 2)
            var site = Site(url: url, offset: offset, line: line, title: url.deletingPathExtension().lastPathComponent)
            site.preview = lines(model, first...last)
            if let method {
                let owner = method.container?.split(separator: ".").last.map(String.init)
                site.title = [owner, method.name].compactMap { $0 }.joined(separator: ".")
                let top = model.line(containing: method.fullRange.location)
                let bottom = model.line(containing: max(method.fullRange.location, NSMaxRange(method.fullRange) - 1))
                site.methodLines = lines(model, top...min(bottom, top + FilePreview.linesAfter))
            }
            if let (trigger, filterLine) = trigger(url: url, model: model, at: offset, method: method) {
                site.trigger = trigger
                site.filterLine = filterLine
            }
            return site
        }

        private func declarationOf(_ target: RustlynTarget) -> ValueGraph.Declaration {
            ValueGraph.Declaration(url: target.url, line: target.line, character: target.character,
                                   length: target.length, name: target.name)
        }

        private func declarationOf(_ method: RustlynDeclaration, model: SyntaxModel, url: URL) -> ValueGraph.Declaration {
            let position = model.position(at: method.nameRange.location)
            return ValueGraph.Declaration(url: url, line: position.line, character: position.character,
                                          length: method.nameRange.length,
                                          name: [method.container, method.name].compactMap { $0 }.joined(separator: "."))
        }

        private func enclosingMember(_ url: URL, at offset: Int) -> RustlynDeclaration? {
            let kinds: Set<RustlynDeclarationKind> = [.method, .constructor, .property, .indexer, .operator, .event, .destructor]
            return outline(url).declarations
                .filter { kinds.contains($0.kind) && NSLocationInRange(offset, $0.fullRange) }
                .min { $0.fullRange.length < $1.fullRange.length }
        }

        private func model(_ url: URL) -> SyntaxModel? {
            if let model = models[url] { return model }
            guard let text = texts[url] ?? SymbolIndex.readSource(url) else { return nil }
            // С лексером — ради подсветки кода в карточках; лексит он лениво,
            // только запрошенные строки.
            let model = SyntaxModel(text: text, spec: SymbolIndex.spec(forPath: url.path))
            models[url] = model
            return model
        }

        private func outline(_ url: URL) -> RustlynOutline {
            if let outline = outlines[url] { return outline }
            // Структуру Rustlyn отдаёт по открытому файлу. Не открытый во
            // вкладке — открыть на время разбора и закрыть за собой.
            var found = rustlyn.outline(url)
            if found == nil, rustlyn.open(url) {
                found = rustlyn.outline(url)
                rustlyn.close(url)
            }
            let outline = found ?? RustlynOutline()
            outlines[url] = outline
            return outline
        }

        /// Строки `range` с разметкой лексера: фрагмент превью палитры,
        /// обрезанный до них.
        private func lines(_ model: SyntaxModel, _ range: ClosedRange<Int>) -> [FilePreview.Line] {
            let start = LSPPosition(line: range.lowerBound + FilePreview.linesBefore, character: 0)
            let preview = FilePreview.make(model: model, range: LSPRange(start: start, end: start))
            return preview.lines.filter { range.contains($0.number) }
        }
    }
}
