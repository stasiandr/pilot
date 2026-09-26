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
            /// Компонент целиком: `_health.Get(e)` без поля.
            case component(String)
            /// Имя, дальше которого граф не прошёл: компилятор его не узнал
            /// (`reason` пуст) или это локальная, чьего значения не отследить.
            case unknown(String, reason: String?)
        }
        var kind: Kind
        /// Локальные переменные, через которые значение пришло: `dmg ← mult`.
        var via: [String] = []
        /// Компилятор имя не узнал — нашли поле с таким именем в индексе.
        var byName = false
        /// Дальше идти некуда, и это не потеря: значение перечисления, член сборки.
        var terminal: String?
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
        /// Правила конфигов: чем помечены их модели — значения таких полей из JSON.
        let configs: ConfigRules?
        private var models: [URL: SyntaxModel] = [:]
        private var outlines: [URL: RustlynOutline] = [:]

        init(root: URL, rustlyn: Rustlyn, texts: [URL: String], index: SymbolIndex?, network: DatagramRules?,
             configs: ConfigRules? = nil) {
            self.root = root
            self.rustlyn = rustlyn
            self.texts = texts
            self.index = index
            self.network = network
            self.configs = configs
            if let index, let network {
                datagrams = Set(PairQueries.datagrams(in: index, rules: network).keys)
            } else {
                datagrams = []
            }
        }

        // MARK: Записи в поле

        func writes(to value: ValueGraph.Declaration, implementing: Bool = true) -> [Site] {
            let declaration = named(value)
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
            sites += declared(declaration, model: model)
            sites += stashWrites(to: declaration, skipping: Set(sites.map { "\($0.url.path)|\($0.offset)" }))
            // Свойство интерфейса: значение дают реализации.
            if sites.isEmpty, implementing {
                sites = implementations(of: declaration).flatMap { writes(to: $0, implementing: false) }
            }
            let unknown = sites.flatMap(\.sources).filter { if case .unknown = $0.kind { return true }; return false }.count
            NSLog("[graph] %@: упоминаний %d, записей %d, чтений %d, неразрешённых имён %d — %@",
                  declaration.name, references.targets.count, sites.count, reads, unknown,
                  sites.map { "\($0.title):\($0.line + 1)\($0.isNetworkRead ? " (из сети)" : "")" }.joined(separator: ", "))
            return sites
        }

        /// Откуда значение, которое код не пишет: колонка таблицы, поле
        /// модели конфига или JSON, поле инспектора Unity. nil — не знаем.
        func origin(of value: ValueGraph.Declaration) -> String? {
            let declaration = named(value)
            guard let model = model(declaration.url) else { return nil }
            let offset = model.offset(at: LSPPosition(line: declaration.line, character: declaration.character))
            let declarations = outline(declaration.url).declarations
            guard let member = declarations.first(where: {
                NSLocationInRange(offset, $0.nameRange) && [.field, .property].contains($0.kind)
            }) else { return nil }
            let owner = declarations.filter { $0.kind.isType && NSLocationInRange(member.fullRange.location, $0.fullRange) }
                .min { $0.fullRange.length < $1.fullRange.length }
            let own = Set(member.attributes.map { $0.split(separator: ".").last.map(String.init) ?? $0 })
            let ownerAttributes = Set((owner?.attributes ?? []).map { $0.split(separator: ".").last.map(String.init) ?? $0 })
            if !own.isDisjoint(with: ["Column", "Key", "ForeignKey"]) || ownerAttributes.contains("Table") {
                return L("из базы данных")
            }
            if let configs, own.contains(configs.keyAttribute) || ownerAttributes.contains(configs.modelAttribute) {
                return L("из конфига")
            }
            if !own.isDisjoint(with: ["JsonProperty", "JsonPropertyName", "DataMember", "JsonRequired"]) {
                return L("из JSON")
            }
            let unityObject = (owner?.bases ?? []).contains { base in
                ["MonoBehaviour", "ScriptableObject", "NetworkBehaviour"].contains(SymbolIndex.baseKey(base))
            }
            let isPublicField = member.kind == .field
                && ValueFlow.string(model.units, NSRange(location: member.fullRange.location,
                                                         length: max(0, member.nameRange.location - member.fullRange.location)))
                    .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).contains("public")
            if own.contains("SerializeField") || own.contains("SerializeReference") || (unityObject && isPublicField) {
                return L("из инспектора Unity")
            }
            return nil
        }

        /// Что даёт само объявление: начальное значение поля, константа,
        /// начальное значение автосвойства, то, что возвращает геттер.
        private func declared(_ declaration: ValueGraph.Declaration, model: SyntaxModel) -> [Site] {
            let units = model.units
            let offset = model.offset(at: LSPPosition(line: declaration.line, character: declaration.character))
            guard let member = outline(declaration.url).declarations.first(where: {
                NSLocationInRange(offset, $0.nameRange) && [.field, .property, .indexer].contains($0.kind)
            }) else { return [] }
            var sites: [Site] = []
            func add(_ expression: NSRange, note: String, method: RustlynDeclaration?) {
                var site = makeSite(declaration.url, model: model, at: expression.location, method: method)
                site.title = declaration.title
                site.note = note
                site.sources = resolve(ValueFlow.sources(in: units, range: expression), url: declaration.url,
                                       model: model, method: method, via: [], depth: 0)
                sites.append(site)
            }
            switch member.kind {
            case .field:
                if case .write(let value?, _) = ValueFlow.access(in: units, name: member.nameRange) {
                    let head = ValueFlow.string(units, NSRange(location: member.fullRange.location,
                                                               length: max(0, member.nameRange.location - member.fullRange.location)))
                    let isConst = head.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).contains("const")
                    add(value, note: isConst ? L("константа") : L("начальное значение"), method: nil)
                }
            default:
                for expression in ValueFlow.getterExpressions(in: units, property: member.fullRange, name: member.nameRange) {
                    add(expression, note: L("возвращает геттер"), method: member)
                }
                if let value = ValueFlow.propertyInitializer(in: units, property: member.fullRange, name: member.nameRange) {
                    add(value, note: L("начальное значение"), method: nil)
                }
            }
            return sites
        }

        /// Объявление с позицией на имени. Свойство и метод Rustlyn отдаёт
        /// началом объявления (атрибуты, `public`), а ссылки на них он ищет
        /// только от имени — от `public` не находилось ни одной записи.
        private func named(_ declaration: ValueGraph.Declaration) -> ValueGraph.Declaration {
            guard !Self.isAssembly(declaration.url), let model = model(declaration.url) else { return declaration }
            let offset = model.offset(at: LSPPosition(line: declaration.line, character: declaration.character))
            let name = declaration.shortName
            let units = model.units
            if offset + name.utf16.count <= units.count,
               ValueFlow.string(units, NSRange(location: offset, length: name.utf16.count)) == name { return declaration }
            guard let member = outline(declaration.url).declarations
                .filter({ $0.name == name && NSLocationInRange(offset, $0.fullRange) && $0.nameRange.location >= offset })
                .min(by: { $0.fullRange.length < $1.fullRange.length }) else { return declaration }
            var fixed = declaration
            let position = model.position(at: member.nameRange.location)
            fixed.line = position.line
            fixed.character = position.character
            fixed.length = member.nameRange.length
            return fixed
        }

        // MARK: Стэши Morpeh

        /// Записи в поле компонента через стэш, которых компилятор не видит:
        /// поля `[IncludeStash]` дописывает кодогенератор Morpeh, и без его
        /// кода `ref var c = ref _stash.Get(e); c.Field = x` для Rustlyn — не
        /// ссылка на поле. Стэши компонента — по индексу (там они дописаны
        /// по правилу генератора), записи — по коду. `known` — уже найденные.
        private func stashWrites(to declaration: ValueGraph.Declaration, skipping known: Set<String>) -> [Site] {
            guard let component = declaration.typeName else { return [] }
            var sites: [Site] = []
            var seen = known
            for stash in stashes(of: component) {
                guard let model = model(stash.url) else { continue }
                let units = model.units
                let writes = ValueFlow.stashFieldWrites(in: units, stash: stash.name, field: declaration.shortName) {
                    self.enclosingMember(stash.url, at: $0)?.fullRange
                }
                for write in writes where seen.insert("\(stash.url.path)|\(write.name.location)").inserted {
                    let method = enclosingMember(stash.url, at: write.name.location)
                    var site = makeSite(stash.url, model: model, at: write.name.location, method: method)
                    site.note = write.compound ? L("меняет прежнее значение") : nil
                    if let rhs = write.rhs {
                        site.sources = resolve(ValueFlow.sources(in: units, range: rhs), url: stash.url, model: model,
                                               method: method, via: [], depth: 0)
                    }
                    sites.append(site)
                }
            }
            return sites
        }

        /// Поля-стэши компонента: объявленные и дописанные генератором.
        private func stashes(of component: String) -> [(name: String, url: URL)] {
            guard let index else { return [] }
            var found: [(name: String, url: URL)] = []
            for id in index.stashesByComponent[component] ?? [] {
                let url = root.appendingPathComponent(index.relPath(id))
                if !found.contains(where: { $0.name == index[id].name && $0.url == url }) { found.append((index[id].name, url)) }
            }
            return found
        }

        /// Поле компонента, взятое через стэш, которого компилятор не видит:
        /// `c.Field` у `ref var c = ref _stash.Get(e)` и `_stash.Get(e).Field`.
        private func stashMember(_ source: ValueFlow.Source, name: String, url: URL, model: SyntaxModel,
                                 method: RustlynDeclaration?) -> ValueGraph.Declaration? {
            var stash: String?
            if let receiver = source.receiver {
                let parts = receiver.split(separator: ".")
                if parts.count == 2, parts[1] == "Get" || parts[1] == "Add" { stash = String(parts[0]) }
            } else if !source.member, let method {
                let parts = source.chain.split(separator: ".")
                if parts.count >= 2 {
                    stash = ValueFlow.stashOfLocal(in: model.units, local: String(parts[0]), method: method.fullRange,
                                                   before: source.range.location)
                }
            }
            guard let stash, let index, let component = component(ofStash: stash, url: url, method: method) else { return nil }
            // Поле компонента — первое звено после стэша или ref-локальной:
            // у `c.Position.Value` это `Position`.
            let field = source.receiver != nil
                ? String(source.chain.split(separator: ".").first ?? Substring(name))
                : String(source.chain.split(separator: ".").dropFirst().first ?? Substring(name))
            guard let id = (index.membersByOwner[component] ?? []).first(where: {
                index[$0].name == field && [.field, .property].contains(index[$0].kind)
            }) else { return nil }
            return canonical(id)
        }

        /// Вызов у стэша, которого компилятор не видит (`_health.Get`,
        /// `_health.Has`): компонент этого стэша.
        private func stashCall(_ chain: String, url: URL, method: RustlynDeclaration?) -> String? {
            let parts = chain.split(separator: ".")
            guard parts.count == 2 else { return nil }
            return component(ofStash: String(parts[0]), url: url, method: method)
        }

        /// Компонент стэша `name`: стэш этого файла, а если его нет —
        /// одноимённый у того же класса.
        private func component(ofStash name: String, url: URL, method: RustlynDeclaration?) -> String? {
            guard let index else { return nil }
            let path = String(url.path.dropFirst(root.path.count + 1))
            let owner = method?.container?.split(separator: ".").last.map(String.init)
            var component: String?
            for id in index.byName[name] ?? [] where index[id].kind == .field {
                guard let found = index[id].typeText.flatMap(SymbolIndex.stashComponent)
                else { continue }
                if index.relPath(id) == path { return found }
                if let owner, index[id].container?.split(separator: ".").last.map(String.init) == owner { component = found }
            }
            return component
        }

        /// `T` в `class Box<T>`: Rustlyn отдаёт параметр типа как поле.
        private func isTypeParameter(_ target: RustlynTarget) -> Bool {
            guard let model = model(target.url) else { return false }
            let at = model.offset(at: LSPPosition(line: target.line, character: target.character))
            return ValueFlow.isTypeParameter(in: model.units, name: NSRange(location: at, length: target.length))
        }

        /// Объявление из индекса — с именем, которое даёт ему компилятор: у
        /// одного поля должен быть один узел, откуда бы граф к нему ни пришёл.
        private func canonical(_ id: Int32) -> ValueGraph.Declaration? {
            guard let index else { return nil }
            let symbol = index[id]
            let url = root.appendingPathComponent(index.relPath(id))
            var declaration = ValueGraph.Declaration(url: url, line: Int(symbol.line), character: Int(symbol.column),
                                                     length: Int(symbol.length),
                                                     name: [symbol.container, symbol.name].compactMap { $0 }.joined(separator: "."))
            if let model = model(url) {
                let offset = model.offset(at: LSPPosition(line: declaration.line, character: declaration.character))
                if let target = rustlyn.definition(url, offset: offset, text: texts[url]).targets.first,
                   target.shortName == symbol.name {
                    declaration = declarationOf(target)
                }
            }
            return declaration
        }

        // MARK: Компонент целиком

        /// `stash.Set(e)`, `.Add(`, `.Remove(` — где компонент появляется и где его убирают.
        func componentChanges(of component: String) -> [Site] {
            let stashes = stashes(of: component)
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
        func returns(of declared: ValueGraph.Declaration, implementing: Bool = true) -> [Site] {
            let method = named(declared)
            guard let model = model(method.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: method.line, character: method.character))
            guard let declaration = enclosingMember(method.url, at: offset) else { return [] }
            let sites = ValueFlow.returnedExpressions(in: model.units, method: declaration.fullRange).map { expression in
                var site = makeSite(method.url, model: model, at: expression.location, method: declaration)
                site.note = L("возвращает")
                site.sources = resolve(ValueFlow.sources(in: model.units, range: expression), url: method.url,
                                       model: model, method: declaration, via: [], depth: 0)
                return site
            }
            // Метод интерфейса или абстрактный: тела нет — return в реализациях.
            guard sites.isEmpty, implementing else { return sites }
            return implementations(of: method).flatMap { returns(of: $0, implementing: false) }
        }

        /// Реализации и переопределения члена в проекте (не больше восьми:
        /// у интерфейса на всё подряд их бывают сотни).
        private func implementations(of member: ValueGraph.Declaration) -> [ValueGraph.Declaration] {
            guard !Self.isAssembly(member.url), let model = model(member.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: member.line, character: member.character))
            return rustlyn.implementations(member.url, offset: offset).targets
                .filter { !Self.isAssembly($0.url) && !($0.url == member.url && $0.line == member.line) }
                .prefix(8)
                .map { named(declarationOf($0)) }
        }

        /// Аргумент номер `argument` во всех вызовах метода.
        func callers(of declared: ValueGraph.Declaration, argument: Int) -> [Site] {
            let method = named(declared)
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
                // `value` в сеттере — то, что свойству присваивают.
                if source.chain == "value", let method, [.property, .indexer, .event].contains(method.kind),
                   let setter = ValueFlow.setter(in: units, property: method.fullRange, name: method.nameRange),
                   NSLocationInRange(source.range.location, setter) {
                    result.append(Source(kind: .value(declarationOf(method, model: model, url: url)), via: via))
                    continue
                }
                // `new T(…)` — объект из аргументов, а они — свои источники.
                if source.constructs { continue }
                let definition = rustlyn.definition(url, offset: source.range.location, text: texts[url])
                let target = definition.targets.first
                if source.call {
                    let declaration = target.flatMap { [.method, .constructor].contains($0.kind) ? declarationOf($0) : nil }
                    if declaration == nil, !source.member {
                        // Стэш, которого компилятор не видит: `_health.Get(e)`, `.Has(e)` — это компонент.
                        if let component = stashCall(source.chain, url: url, method: method) {
                            result.append(Source(kind: .component(component), via: via))
                            continue
                        }
                        // `c.Value.ToObject<T>()` у ref-локальной из стэша — из поля `Value`.
                        if let typed = stashMember(source, name: name, url: url, model: model, method: method) {
                            result.append(Source(kind: .value(typed), via: via))
                            continue
                        }
                        // Вызов у локальной, чьего типа компилятор не знает, — из того, что в ней.
                        if let local = headLocal(source, url: url, model: model, method: method, via: via, depth: depth) {
                            result += local
                            continue
                        }
                    }
                    var call = Source(kind: .call(source.chain, declaration), via: via)
                    if let declaration, Self.isAssembly(declaration.url) { call.terminal = Self.assemblyNote(declaration.url) }
                    result.append(call)
                    continue
                }
                if let target {
                    // Тип в приведении `(Vector3)x`, пространство имён и группа
                    // методов (`Callback` без скобок) — не источники значения.
                    if target.kind.isType || [.namespace, .method, .constructor, .operator].contains(target.kind) { continue }
                    if [.field, .property, .enumMember, .event].contains(target.kind) {
                        // Параметр типа Rustlyn тоже отдаёт как поле.
                        if target.kind == .field, isTypeParameter(target) { continue }
                        // Локальные и параметры Rustlyn отдаёт как поля — отличает их
                        // место: поле внутри метода не объявить.
                        if source.chain == name, !source.member, let method,
                           let local = local(target, name: name, method: method, url: url, model: model,
                                             via: via, depth: depth) {
                            result += local
                            continue
                        }
                        var value = Source(kind: .value(declarationOf(target)), via: via)
                        if target.kind == .enumMember {
                            value.terminal = L("значение перечисления")
                        } else if Self.isAssembly(target.url) {
                            value.terminal = Self.assemblyNote(target.url)
                        }
                        result.append(value)
                        continue
                    }
                }
                // Поле компонента через стэш, которого компилятор не видит.
                if let typed = stashMember(source, name: name, url: url, model: model, method: method) {
                    result.append(Source(kind: .value(typed), via: via))
                    continue
                }
                // Хвоста цепочки компилятор не узнал (`v.x` у `var v = …` без
                // известного типа) — значение всё равно из её головы: локальной
                // или параметра.
                if !source.member, let local = headLocal(source, url: url, model: model, method: method, via: via, depth: depth) {
                    result += local
                    continue
                }
                // Одиночное имя, которого компилятор не узнал: локальная переменная или параметр.
                if source.chain == name, !source.member, let method {
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
                    result.append(Source(kind: .unknown(source.chain, reason: nil), via: via))
                }
            }
            return result
        }

        /// Голова цепочки `a.b.c`, если это локальная или параметр: то, откуда они.
        private func headLocal(_ source: ValueFlow.Source, url: URL, model: SyntaxModel, method: RustlynDeclaration?,
                               via: [String], depth: Int) -> [Source]? {
            guard let method, let head = source.head, head != source.range,
                  let target = rustlyn.definition(url, offset: head.location, text: texts[url]).targets.first,
                  target.kind == .field else { return nil }
            return local(target, name: ValueFlow.string(model.units, head), method: method, url: url, model: model,
                         via: via, depth: depth)
        }

        /// Локальная переменная или параметр `target` — если его объявление
        /// внутри `method`. Параметр — узел, который раскрывается в аргументы
        /// вызовов; локальная — то, что в неё записывают в этом методе:
        /// присваивания, `out` в вызове, элемент коллекции `foreach`.
        /// nil — это не они.
        private func local(_ target: RustlynTarget, name: String, method: RustlynDeclaration, url: URL,
                           model: SyntaxModel, via: [String], depth: Int) -> [Source]? {
            guard target.url == url else { return nil }
            let units = model.units
            let at = model.offset(at: LSPPosition(line: target.line, character: target.character))
            guard NSLocationInRange(at, method.fullRange) else { return nil }
            if let list = ValueFlow.parameterList(in: units, after: method.nameRange), NSLocationInRange(at, list) {
                guard let index = Self.parameterIndex(name, in: method) else { return [] }
                return [Source(kind: .parameter(name, declarationOf(method, model: model, url: url), index), via: via)]
            }
            let declared = NSRange(location: at, length: target.length)
            if ValueFlow.isTypeParameter(in: units, name: declared) { return [] }
            if ValueFlow.isLambdaParameter(in: units, name: declared) {
                return [Source(kind: .unknown(name, reason: L("параметр лямбды")), via: via)]
            }
            // Круг (`a = b; b = a;`) или слишком длинная цепочка.
            guard depth < 6, !via.contains(name) else { return [] }
            var result: [Source] = []
            var writes = 0
            let references = rustlyn.references(url, offset: at, text: texts[url])
            for reference in references.targets where reference.url == url {
                let offset = model.offset(at: LSPPosition(line: reference.line, character: reference.character))
                let range = NSRange(location: offset, length: reference.length)
                var found: [ValueFlow.Source]?
                switch ValueFlow.access(in: units, name: range) {
                case .write(let value?, _):
                    found = ValueFlow.sources(in: units, range: value)
                case .write(nil, _), .read:
                    if ValueFlow.isOutArgument(in: units, name: range) {
                        found = ValueFlow.enclosingCall(in: units, at: offset).map { [$0] } ?? []
                    } else if offset == at, let collection = ValueFlow.foreachCollection(in: units, variable: range) {
                        found = ValueFlow.sources(in: units, range: collection)
                    } else if offset == at, let value = ValueFlow.deconstruction(in: units, name: range) {
                        found = ValueFlow.sources(in: units, range: value)
                    } else if offset == at, let subject = ValueFlow.patternSubject(in: units, name: range) {
                        found = ValueFlow.sources(in: units, range: subject)
                    } else if offset == at, let parameter = ValueFlow.localFunctionParameter(in: units, name: range) {
                        // Параметр локальной функции — аргументы её вызовов в этом методе.
                        let function = ValueFlow.string(units, parameter.function)
                        found = ValueFlow.calls(of: function, in: units, range: method.fullRange,
                                                except: parameter.function.location)
                            .compactMap { ValueFlow.argument(in: units, after: $0, index: parameter.index) }
                            .flatMap { ValueFlow.sources(in: units, range: $0) }
                    }
                }
                guard let found else { continue }
                writes += 1
                result += resolve(found, url: url, model: model, method: method, via: via + [name], depth: depth + 1)
            }
            // Записи есть, а имён в них нет — литералы: их видно в коде места.
            if writes == 0 {
                result.append(Source(kind: .unknown(name, reason: L("локальная — откуда значение, не понять")), via: via))
            }
            return result
        }

        static func isAssembly(_ url: URL) -> Bool { ["dll", "exe"].contains(url.pathExtension.lowercased()) }

        static func assemblyNote(_ url: URL) -> String {
            L("из сборки \(url.deletingPathExtension().lastPathComponent)")
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
