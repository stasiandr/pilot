import Foundation

/// Поиск для графа значения — в фоне, на очереди запросов к компилятору
/// проекта. Компилятор (Rustlyn) говорит, где упомянуто имя и что оно
/// значит; `ValueFlow` — запись это или чтение и что стоит справа;
/// `ValueOrigins` — какие из литералов и имён уже источники.
enum ValueGraphAnalysis {

    struct Source {
        enum Kind {
            case value(ValueGraph.Declaration)
            case call(String, ValueGraph.Declaration?)
            case parameter(String, ValueGraph.Declaration?, Int)
            /// Компонент целиком: `_health.Get(e)` без поля.
            case component(String)
            /// Источник: литерал, константа, значение перечисления, время
            /// движка… `at` — объявление, если источник — имя.
            case origin(ValueOrigin, at: ValueGraph.Declaration?)
            /// Имя, дальше которого граф не прошёл: компилятор его не узнал
            /// (`reason` пуст) или это локальная, чьего значения не отследить.
            case unknown(String, reason: String?)
        }
        var kind: Kind
        /// Локальные переменные, через которые значение пришло: `dmg ← mult`.
        var via: [String] = []
        /// Компилятор имя не узнал — нашли поле с таким именем в индексе.
        var byName = false
        /// Имя стоит аргументом вызова метода проекта: этот вызов. Граф сам
        /// такие не раскрывает — значение идёт через return вызова.
        var argumentOf: String?
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
        /// Строка данных — JSON конфига, YAML префаба, — а не код.
        var isData = false
        /// Само объявление: начальное значение, константа, геттер.
        var isDeclaration = false
        /// Проект места, если не тот, чей узел раскрывали: конфиги клиента
        /// лежат у сервера.
        var project: URL?
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
        /// Вторая половина пары и её индекс: конфиги клиента лежат у сервера.
        let partner: URL?
        let partnerIndex: SymbolIndex?
        private var models: [URL: SyntaxModel] = [:]
        private var outlines: [URL: RustlynOutline] = [:]
        private var definitions: [String: RustlynTarget?] = [:]

        init(root: URL, rustlyn: Rustlyn, texts: [URL: String], index: SymbolIndex?, network: DatagramRules?,
             configs: ConfigRules? = nil, partner: URL? = nil, partnerIndex: SymbolIndex? = nil) {
            self.root = root
            self.rustlyn = rustlyn
            self.texts = texts
            self.index = index
            self.network = network
            self.configs = configs
            self.partner = partner
            self.partnerIndex = partnerIndex
            if let index, let network {
                datagrams = Set(PairQueries.datagrams(in: index, rules: network).keys)
            } else {
                datagrams = []
            }
        }

        // MARK: Что под курсором

        /// С чего строить граф для имени под курсором: поле и свойство — кто
        /// их пишет, локальная — её записи в методе, параметр — аргументы
        /// вызовов, метод — что он возвращает, значение перечисления и член
        /// сборки — сразу источник, тип — компонент. nil — это не значение.
        func root(for target: RustlynTarget) -> ValueGraph.Root? {
            let declaration = declarationOf(target)
            // Член сборки или пакета — сразу источник: время, случайное, движок.
            if Self.isLibrary(target.url), [.field, .property, .event, .method].contains(target.kind) {
                let call = target.kind == .method ? "()" : ""
                return .origin(libraryOrigin(type: target.container ?? "", member: target.shortName,
                                             title: declaration.title + call), declaration)
            }
            switch target.kind {
            case .field, .property, .event:
                guard target.kind == .field, let model = model(target.url) else { return .value(declaration) }
                let at = model.offset(at: LSPPosition(line: target.line, character: target.character))
                let name = NSRange(location: at, length: target.length)
                if ValueFlow.isTypeParameter(in: model.units, name: name) { return nil }
                // Локальные и параметры Rustlyn отдаёт как поля: параметр — по месту в скобках метода.
                if let method = enclosingMember(target.url, at: at), !NSLocationInRange(at, method.nameRange),
                   let list = Self.parameters(of: method, in: model.units), NSLocationInRange(at, list),
                   let index = Self.parameterIndex(target.shortName, in: method) {
                    // `out` — значение кладёт сам метод: его записи, как у локальной.
                    // (В `parameters` Rustlyn модификатора не пишет — смотрим текст.)
                    if ValueFlow.isOutArgument(in: model.units, name: name) { return .value(declaration) }
                    return .parameter(method: declarationOf(method, model: model, url: target.url), index: index,
                                      name: target.shortName)
                }
                return .value(declaration)
            case .method:
                return .call(named(declaration))
            case .enumMember:
                return .origin(ValueOrigin(kind: .enumValue, title: declaration.title), declaration)
            case .struct, .class:
                // Тип проекта — как компонент; `string` и `Vector3` — не компоненты.
                return Self.isLibrary(target.url) ? nil : .component(target.shortName)
            default:
                return nil
            }
        }

        /// Член сборки как источник: время, случайное, движок; постоянная; иначе «сборка».
        private func libraryOrigin(type: String, member: String, title: String) -> ValueOrigin {
            switch ValueOrigins.classify(type: type, member: member) {
            case .origin(let kind): return ValueOrigin(kind: kind, title: title)
            case .constant: return ValueOrigin(kind: .constant, title: title)
            case .transform, .unknown: return ValueOrigin(kind: .library, title: title)
            }
        }

        // MARK: Записи в поле

        func writes(to value: ValueGraph.Declaration, implementing: Bool = true) -> [Site] {
            let declaration = named(value)
            guard let model = model(declaration.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: declaration.line, character: declaration.character))
            // Локальная: её записи — в её методе.
            if let method = localScope(declaration.url, at: offset) {
                let sites = localSites(declaration, at: offset, method: method, model: model)
                // Out-параметр метода интерфейса: тела нет — записи в реализациях.
                if sites.isEmpty, implementing, let list = Self.parameters(of: method, in: model.units),
                   NSLocationInRange(offset, list), let index = Self.parameterIndex(declaration.shortName, in: method) {
                    return implementations(of: declarationOf(method, model: model, url: declaration.url))
                        .compactMap { parameter(of: $0, index: index) }
                        .flatMap { writes(to: $0, implementing: false) }
                }
                return sites
            }
            let references = rustlyn.references(declaration.url, offset: offset, text: texts[declaration.url])
            var sites: [Site] = []
            var reads = 0
            for target in references.targets {
                if target.url == declaration.url, target.line == declaration.line,
                   target.character == declaration.character { continue }
                guard let model = self.model(target.url) else { continue }
                let at = model.offset(at: LSPPosition(line: target.line, character: target.character))
                let access = ValueFlow.access(in: model.units, name: NSRange(location: at, length: target.length))
                guard case .write(let rhs, let compound) = access else {
                    // Запись в элемент коллекции: значение поля — то, что в неё кладут.
                    if let element = ValueFlow.elementWrite(in: model.units, name: NSRange(location: at, length: target.length)) {
                        let method = enclosingMember(target.url, at: at)
                        var site = makeSite(target.url, model: model, at: at, method: method)
                        site.note = L("кладёт в коллекцию: \(element.method)")
                        site.sources = sources(of: element.value, url: target.url, model: model, method: method, via: [], depth: 0)
                        sites.append(site)
                    } else {
                        reads += 1
                    }
                    continue
                }
                let method = enclosingMember(target.url, at: at)
                var site = makeSite(target.url, model: model, at: at, method: method)
                site.note = compound ? L("меняет прежнее значение") : nil
                site.isNetworkRead = (network?.read.contains(method?.name ?? "") ?? false)
                    && method?.container?.split(separator: ".").last.map(String.init) == declaration.typeName
                if let rhs {
                    site.sources = sources(of: rhs, url: target.url, model: model, method: method, via: [], depth: 0)
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
        /// модели конфига или JSON, поле инспектора Unity, член сборки.
        /// nil — не знаем.
        func origin(of value: ValueGraph.Declaration) -> ValueOrigin? {
            if Self.isLibrary(value.url) {
                let type = value.name.split(separator: ".").dropLast().joined(separator: ".")
                return libraryOrigin(type: type, member: value.shortName, title: value.title)
            }
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
            let head = ValueFlow.string(model.units, NSRange(location: member.fullRange.location,
                                                             length: max(0, member.nameRange.location - member.fullRange.location)))
            // Модель строки таблицы: атрибуты или имя (`…DbModel` у Dapper их не ставят).
            let ownerName = owner?.name ?? ""
            if !own.isDisjoint(with: ["Column", "Key", "ForeignKey"]) || ownerAttributes.contains("Table")
                || ["DbModel", "DBModel", "DatabaseModel"].contains(where: ownerName.hasSuffix) {
                return ValueOrigin(kind: .database, title: declaration.title)
            }
            let key = ["JsonProperty", "JsonPropertyName", "DataMember"].lazy
                .compactMap { ConfigLinks.jsonProperty(in: head, attribute: $0) }.first
            if let configs, own.contains(configs.keyAttribute) || ownerAttributes.contains(configs.modelAttribute) {
                return ValueOrigin(kind: .config, title: key ?? declaration.shortName)
            }
            if !own.isDisjoint(with: ["JsonProperty", "JsonPropertyName", "DataMember", "JsonRequired"]) {
                return ValueOrigin(kind: .json, title: key ?? declaration.shortName)
            }
            if !own.isDisjoint(with: ["Injectable", "Inject"]) {
                return ValueOrigin(kind: .injection, title: member.typeText ?? declaration.title)
            }
            let unityObject = (owner?.bases ?? []).contains { base in
                ["MonoBehaviour", "ScriptableObject", "NetworkBehaviour"].contains(SymbolIndex.baseKey(base))
            }
            let isPublicField = member.kind == .field
                && head.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).contains("public")
            if own.contains("SerializeField") || own.contains("SerializeReference") || (unityObject && isPublicField) {
                // Ключ в YAML префаба — имя поля как есть.
                return ValueOrigin(kind: .inspector, title: declaration.shortName)
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
            func add(_ expression: NSRange, note: String, method: RustlynDeclaration?, literal: ValueOrigin.Kind) {
                var site = makeSite(declaration.url, model: model, at: expression.location, method: method)
                site.title = declaration.title
                site.note = note
                site.isDeclaration = true
                site.sources = sources(of: expression, url: declaration.url, model: model, method: method, via: [], depth: 0,
                                       literal: literal)
                sites.append(site)
            }
            switch member.kind {
            case .field:
                if case .write(let value?, _) = ValueFlow.access(in: units, name: member.nameRange) {
                    let head = ValueFlow.string(units, NSRange(location: member.fullRange.location,
                                                               length: max(0, member.nameRange.location - member.fullRange.location)))
                    let isConst = head.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).contains("const")
                    add(value, note: isConst ? L("константа") : L("начальное значение"), method: nil,
                        literal: isConst ? .constant : .initial)
                }
            default:
                for expression in ValueFlow.getterExpressions(in: units, property: member.fullRange, name: member.nameRange) {
                    add(expression, note: L("возвращает геттер"), method: member, literal: .literal)
                }
                if let value = ValueFlow.propertyInitializer(in: units, property: member.fullRange, name: member.nameRange) {
                    add(value, note: L("начальное значение"), method: nil, literal: .initial)
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

        // MARK: Локальные

        /// Метод, в теле которого объявлено имя в `offset`, — если это
        /// локальная (или параметр), а не член типа.
        private func localScope(_ url: URL, at offset: Int) -> RustlynDeclaration? {
            guard let member = enclosingMember(url, at: offset), !NSLocationInRange(offset, member.nameRange)
            else { return nil }
            return member
        }

        /// Записи в локальную местами — как у поля: объявление с начальным
        /// значением, присваивания, `out` в вызове, элемент `foreach`.
        private func localSites(_ declaration: ValueGraph.Declaration, at offset: Int, method: RustlynDeclaration,
                                model: SyntaxModel) -> [Site] {
            let url = declaration.url
            let writes = localWrites(at: offset, length: declaration.length, name: declaration.shortName, method: method,
                                     url: url, model: model, via: [], depth: 0)
            let sites = writes.map { write -> Site in
                var site = makeSite(url, model: model, at: write.offset, method: method)
                site.note = write.note
                site.sources = write.sources
                return site
            }
            NSLog("[graph] локальная %@ в %@: записей %d", declaration.shortName, method.name, sites.count)
            return sites
        }

        /// Запись в локальную: где, пометка и из чего.
        private struct LocalWrite {
            var offset: Int
            var note: String?
            var sources: [Source]
        }

        /// Записи в локальную, объявленную в `at` метода `method`:
        /// присваивания, `out` в вызове, элемент `foreach`, разбор кортежа,
        /// переменная шаблона, параметр локальной функции. `via` — пометка
        /// «через» у источников: у самой локальной-корня она пуста.
        private func localWrites(at: Int, length: Int, name: String, method: RustlynDeclaration, url: URL,
                                 model: SyntaxModel, via: [String], depth: Int) -> [LocalWrite] {
            let units = model.units
            let next = depth + 1
            var result: [LocalWrite] = []
            let references = rustlyn.references(url, offset: at, text: texts[url])
            // Объявление параметра (`out string key` в скобках метода) — не запись.
            let parameters = Self.parameters(of: method, in: units)
            for reference in references.targets where reference.url == url {
                let offset = model.offset(at: LSPPosition(line: reference.line, character: reference.character))
                let range = NSRange(location: offset, length: reference.length)
                if let parameters, NSLocationInRange(offset, parameters) { continue }
                func from(_ expression: NSRange) -> [Source] {
                    sources(of: expression, url: url, model: model, method: method, via: via, depth: next)
                }
                switch ValueFlow.access(in: units, name: range) {
                case .write(let value?, let compound):
                    result.append(LocalWrite(offset: offset, note: compound ? L("меняет прежнее значение") : nil,
                                             sources: from(value)))
                case .write(nil, _), .read:
                    if let element = ValueFlow.elementWrite(in: units, name: range) {
                        result.append(LocalWrite(offset: offset, note: L("кладёт в коллекцию: \(element.method)"),
                                                 sources: from(element.value)))
                    } else if ValueFlow.isOutArgument(in: units, name: range) {
                        result.append(LocalWrite(offset: offset, note: L("out в вызове"),
                                                 sources: outSources(at: offset, local: range, url: url, model: model,
                                                                     method: method, via: via, depth: next)))
                    } else if offset == at, ValueFlow.isLambdaParameter(in: units, name: range),
                              let found = lambdaSources(range, url: url, model: model, method: method, via: via, depth: next) {
                        result.append(LocalWrite(offset: offset, note: L("параметр лямбды"), sources: found))
                    } else if offset == at, let collection = ValueFlow.foreachCollection(in: units, variable: range) {
                        result.append(LocalWrite(offset: offset, note: L("элемент foreach"), sources: from(collection)))
                    } else if offset == at, let value = ValueFlow.deconstruction(in: units, name: range) {
                        result.append(LocalWrite(offset: offset, note: L("разбор кортежа"), sources: from(value)))
                    } else if offset == at, let subject = ValueFlow.patternSubject(in: units, name: range) {
                        result.append(LocalWrite(offset: offset, note: L("проверка is"), sources: from(subject)))
                    } else if offset == at, let parameter = ValueFlow.localFunctionParameter(in: units, name: range) {
                        // Параметр локальной функции — аргументы её вызовов в этом методе.
                        let function = ValueFlow.string(units, parameter.function)
                        let arguments = ValueFlow.calls(of: function, in: units, range: method.fullRange,
                                                        except: parameter.function.location)
                            .compactMap { ValueFlow.argument(in: units, after: $0, index: parameter.index) }
                        result.append(LocalWrite(offset: offset, note: L("параметр \(function)"),
                                                 sources: arguments.flatMap(from)))
                    }
                }
            }
            return result
        }

        /// Лямбду отдали методу библиотеки: её параметр — то, что тот даёт,
        /// элемент `list` у `list.ForEach(x => …)`, строка базы у `QueryAsync`.
        /// nil — метод проекта или не понять.
        private func lambdaSources(_ parameter: NSRange, url: URL, model: SyntaxModel, method: RustlynDeclaration?,
                                   via: [String], depth: Int) -> [Source]? {
            guard let call = ValueFlow.lambdaCall(in: model.units, parameter: parameter),
                  libraryKind(of: call, url: url, model: model) != nil else { return nil }
            let found = resolve([call], url: url, model: model, method: method, via: via, depth: depth)
            return found.isEmpty ? nil : found
        }

        /// `out x` в вызове: значение кладёт вызов. Вызов сборки —
        /// преобразование (`int.TryParse(s, out x)`, `map.TryGetValue(k, out x)`):
        /// тогда оно из получателя и остальных аргументов.
        private func outSources(at offset: Int, local: NSRange, url: URL, model: SyntaxModel,
                                method: RustlynDeclaration?, via: [String], depth: Int) -> [Source] {
            let units = model.units
            guard let call = ValueFlow.enclosingCall(in: units, at: offset) else { return [] }
            // Метод проекта кладёт значение в свой out-параметр — его записи, а не return.
            if let target = definition(url, at: call.range.location), target.kind == .method, !Self.isLibrary(target.url),
               let index = (0..<16).first(where: { k in
                   ValueFlow.argument(in: units, after: call.range, index: k).map { NSLocationInRange(local.location, $0) } ?? false
               }) {
                let callee = named(declarationOf(target))
                // `x.M(out y)` у расширения: `x` — параметр `this`, номера сдвинуты.
                let shift = isExtensionCall(memberDeclaration(callee), name: call.range, units: units) ? 1 : 0
                if let parameter = parameter(of: callee, index: index + shift) {
                    return [Source(kind: .value(parameter), via: via)]
                }
            }
            var result = resolve([call], url: url, model: model, method: method, via: via, depth: depth)
            if let kind = libraryKind(of: call, url: url, model: model), kind == .transform || kind == .unknown,
               let arguments = ValueFlow.parameterList(in: units, after: call.range) {
                let others = ValueFlow.sources(in: units, range: arguments)
                    .filter { NSIntersectionRange($0.range, local).length == 0 }
                result += resolve(others, url: url, model: model, method: method, via: via, depth: depth)
            }
            return result
        }

        /// Параметр номер `index` метода — объявлением, как локальная: его
        /// записи в теле метода — то, что метод кладёт в `out`.
        private func parameter(of method: ValueGraph.Declaration, index: Int) -> ValueGraph.Declaration? {
            guard let model = model(method.url) else { return nil }
            let units = model.units
            let offset = model.offset(at: LSPPosition(line: method.line, character: method.character))
            guard let text = ValueFlow.argument(in: units, after: NSRange(location: offset, length: method.length), index: index)
            else { return nil }
            // Имя — последнее слово до `=`: `out string key`, `int n = 5`.
            var end = NSMaxRange(text)
            if let equals = ValueFlow.string(units, text).firstIndex(of: "=") {
                end = text.location + ValueFlow.string(units, text)[..<equals].utf16.count
            }
            while end > text.location, !ValueFlow.isIdentPart(units[end - 1]) { end -= 1 }
            var start = end
            while start > text.location, ValueFlow.isIdentPart(units[start - 1]) { start -= 1 }
            guard start < end else { return nil }
            let position = model.position(at: start)
            return ValueGraph.Declaration(url: method.url, line: position.line, character: position.character,
                                          length: end - start, name: method.name + "." + ValueFlow.string(units, NSRange(location: start, length: end - start)))
        }

        /// Объявление члена в структуре его файла.
        private func memberDeclaration(_ declaration: ValueGraph.Declaration) -> RustlynDeclaration? {
            guard let model = model(declaration.url) else { return nil }
            let offset = model.offset(at: LSPPosition(line: declaration.line, character: declaration.character))
            return outline(declaration.url).declarations.first { NSLocationInRange(offset, $0.nameRange) }
        }

        /// Метод-расширение, вызванный у получателя (`x.M(a)`): `x` — его
        /// параметр `this`, и номера аргументов сдвинуты на один.
        /// `Ext.M(x, a)` — обычный статический вызов.
        private func isExtensionCall(_ method: RustlynDeclaration?, name: NSRange, units: [UInt16]) -> Bool {
            guard let method, method.isExtensionMethod || method.parameters.first?.hasPrefix("this ") == true,
                  ValueFlow.receiverExpression(in: units, before: name) != nil else { return false }
            let chain = ValueFlow.chain(in: units, endingWith: name).split(separator: ".")
            let owner = method.container?.split(separator: ".").last.map(String.init)
            return !(chain.count >= 2 && String(chain[chain.count - 2]) == owner)
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
                        site.sources = sources(of: rhs, url: stash.url, model: model, method: method, via: [], depth: 0)
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
                if let target = definition(url, at: offset), target.shortName == symbol.name {
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
                site.sources = sources(of: expression, url: method.url, model: model, method: declaration, via: [], depth: 0)
                return site
            }
            // Метод интерфейса или абстрактный: тела нет — return в реализациях.
            guard sites.isEmpty, implementing else { return sites }
            return implementations(of: method).flatMap { returns(of: $0, implementing: false) }
        }

        /// Реализации и переопределения члена в проекте (не больше восьми:
        /// у интерфейса на всё подряд их бывают сотни). Компилятор их не
        /// знает — по индексу: типы, которые называют владельца базовым.
        private func implementations(of member: ValueGraph.Declaration) -> [ValueGraph.Declaration] {
            guard !Self.isAssembly(member.url), let model = model(member.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: member.line, character: member.character))
            let found = rustlyn.implementations(member.url, offset: offset).targets
                .filter { !Self.isLibrary($0.url) && !($0.url == member.url && $0.line == member.line) }
                .prefix(8)
                .map { named(declarationOf($0)) }
            guard found.isEmpty, let index, let owner = member.typeName,
                  let declared = memberDeclaration(member) else { return found }
            var result: [ValueGraph.Declaration] = []
            var queue = [owner]
            var seen: Set<String> = []
            while !queue.isEmpty, result.count < 8 {
                let base = queue.removeFirst()
                guard seen.insert(base).inserted, seen.count < 32 else { continue }
                for type in index.derivedByBase[base] ?? [] {
                    let name = index[type].name
                    // Члены — по структуре файла типа от компилятора: явную
                    // реализацию (`Entity IElementService.CreateEntity(…)`)
                    // индекс не видит, а компилятор видит.
                    let url = root.appendingPathComponent(index.relPath(type))
                    let own = outline(url).declarations.filter {
                        ($0.name == declared.name || $0.name.hasSuffix("." + declared.name)) && $0.kind == declared.kind
                            && $0.parameters.count == declared.parameters.count
                            && $0.container?.split(separator: ".").last.map(String.init) == name
                    }
                    if let typeModel = self.model(url) {
                        result += own.map { named(declarationOf($0, model: typeModel, url: url)) }
                    }
                    // Абстрактный посредник без своей реализации — дальше вниз.
                    if own.isEmpty { queue.append(name) }
                }
            }
            return Array(result.prefix(8))
        }

        /// Аргумент номер `argument` во всех вызовах метода. Вызовов нет, а
        /// метод переопределяет или реализует чужой (`override Run` команды) —
        /// вызовы того: их зовут через базовый тип.
        func callers(of declared: ValueGraph.Declaration, argument: Int, dispatch: Bool = true) -> [Site] {
            let found = directCallers(of: declared, argument: argument)
            guard found.isEmpty, dispatch else { return found }
            return baseMembers(of: named(declared)).flatMap { base in
                directCallers(of: base, argument: argument).map { site in
                    var site = site
                    site.note = [site.note, L("через \(base.title)")].compactMap { $0 }.joined(separator: " · ")
                    return site
                }
            }
        }

        /// Один вид члена для индекса и компилятора: метод Unity — метод, поле инспектора — поле.
        static func sameKind(_ a: OutlineKind, _ b: OutlineKind) -> Bool {
            func base(_ kind: OutlineKind) -> OutlineKind {
                switch kind {
                case .unityMessage: return .method
                case .serializedField: return .field
                default: return kind
                }
            }
            return base(a) == base(b)
        }

        /// Откуда параметр, которого код не передаёт: вызовов нет, потому что
        /// метод зовёт движок или кодогенератор. `deltaTime` у `OnUpdate`
        /// системы Morpeh — время кадра, параметр сообщения Unity
        /// (`OnTriggerEnter(Collider other)`) — движок. nil — не знаем.
        func parameterOrigin(of declared: ValueGraph.Declaration, argument: Int) -> ValueOrigin? {
            let method = named(declared)
            guard let member = memberDeclaration(method), argument < member.parameters.count else { return nil }
            let name = member.parameters[argument].split(separator: " ").last.map(String.init) ?? ""
            if ["deltaTime", "dt", "fixedDeltaTime", "deltaSeconds"].contains(name) {
                return ValueOrigin(kind: .time, title: "\(member.name)(\(name))")
            }
            let isMessage = (index?.byName[member.name] ?? []).contains {
                index?[$0].kind == .unityMessage && index?[$0].container?.split(separator: ".").last.map(String.init) == method.typeName
            }
            return isMessage ? ValueOrigin(kind: .engine, title: "\(member.name)(\(name))") : nil
        }

        /// Члены базовых типов и интерфейсов с тем же именем и числом
        /// параметров, что у `method`, — ближайшие, не больше четырёх.
        private func baseMembers(of method: ValueGraph.Declaration) -> [ValueGraph.Declaration] {
            guard let index, let model = model(method.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: method.line, character: method.character))
            let declarations = outline(method.url).declarations
            guard let member = declarations.first(where: { NSLocationInRange(offset, $0.nameRange) }),
                  let owner = declarations.filter({ $0.kind.isType && NSLocationInRange(member.fullRange.location, $0.fullRange) })
                    .min(by: { $0.fullRange.length < $1.fullRange.length }) else { return [] }
            var result: [ValueGraph.Declaration] = []
            var queue = owner.bases.map(SymbolIndex.baseKey)
            var seen: Set<String> = []
            while !queue.isEmpty, result.count < 4 {
                let base = queue.removeFirst()
                guard seen.insert(base).inserted, seen.count < 16 else { continue }
                var found = false
                for id in index.membersByOwner[base] ?? [] where index[id].name == member.name
                    && index[id].kind == .method && index[id].parameters.count == member.parameters.count {
                    if let declaration = canonical(id) { result.append(declaration); found = true }
                }
                // Ближайший базовый с таким методом — дальше вверх не идём.
                if !found { for id in index.typesByName[base] ?? [] { queue += index[id].bases.map(SymbolIndex.baseKey) } }
            }
            return result
        }

        private func directCallers(of declared: ValueGraph.Declaration, argument: Int) -> [Site] {
            let method = named(declared)
            guard let model = model(method.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: method.line, character: method.character))
            let references = rustlyn.references(method.url, offset: offset, text: texts[method.url])
            let callee = memberDeclaration(method)
            var sites: [Site] = []
            var omitted = 0
            for target in references.targets {
                if target.url == method.url, target.line == method.line, target.character == method.character { continue }
                guard let model = self.model(target.url) else { continue }
                let at = model.offset(at: LSPPosition(line: target.line, character: target.character))
                let name = NSRange(location: at, length: target.length)
                // `x.M(a)` у расширения: `x` — параметр `this`, остальные сдвинуты.
                var index = argument
                if isExtensionCall(callee, name: name, units: model.units) {
                    index -= 1
                    if index < 0, let receiver = ValueFlow.receiverExpression(in: model.units, before: name) {
                        let caller = enclosingMember(target.url, at: at)
                        var site = makeSite(target.url, model: model, at: at, method: caller)
                        site.note = L("вызывает \(method.shortName)")
                        site.sources = sources(of: receiver, url: target.url, model: model, method: caller, via: [], depth: 0)
                        sites.append(site)
                        continue
                    }
                }
                guard index >= 0, let expression = ValueFlow.argument(in: model.units, after: name, index: index) else {
                    // Вызов без этого аргумента: значение по умолчанию.
                    if ValueFlow.parameterList(in: model.units, after: name) != nil { omitted += 1 }
                    continue
                }
                let caller = enclosingMember(target.url, at: at)
                var site = makeSite(target.url, model: model, at: at, method: caller)
                site.note = L("вызывает \(method.shortName)")
                site.sources = sources(of: expression, url: target.url, model: model, method: caller, via: [], depth: 0)
                sites.append(site)
            }
            // `M(int a, List<T> b = null)` — те, кто `b` не передал, получают умолчание.
            if omitted > 0, let parameter = ValueFlow.argument(in: model.units, after: NSRange(location: offset, length: method.length),
                                                               index: argument),
               let value = ValueFlow.defaultValue(in: model.units, parameter: parameter) {
                let declaration = enclosingMember(method.url, at: offset)
                var site = makeSite(method.url, model: model, at: value.location, method: declaration)
                site.note = L("по умолчанию — вызовов без аргумента: \(omitted)")
                site.sources = sources(of: value, url: method.url, model: model, method: nil, via: [], depth: 0,
                                       literal: .defaultValue)
                sites.append(site)
            }
            return sites
        }

        // MARK: Имена справа

        /// Источники выражения: литералы, которыми оно может оказаться
        /// (`0`, ветки `?:`), и имена в нём. `literal` — чем считать литерал:
        /// в объявлении константы это константа, у поля — начальное значение.
        private func sources(of expression: NSRange, url: URL, model: SyntaxModel, method: RustlynDeclaration?,
                             via: [String], depth: Int, literal: ValueOrigin.Kind = .literal) -> [Source] {
            let units = model.units
            var result: [Source] = ValueFlow.literalAlternatives(in: units, range: expression).map { range in
                let text = ValueFlow.string(units, range)
                let kind: ValueOrigin.Kind = literal == .literal && ValueFlow.isDefaultLiteral(text) ? .defaultValue : literal
                return Source(kind: .origin(ValueOrigin(kind: kind, title: Self.clip(text)), at: nil), via: via)
            }
            result += resolve(ValueFlow.sources(in: units, range: expression), url: url, model: model, method: method,
                              via: via, depth: depth)
            return result
        }

        /// Во что превращаются имена правой части: поле — узел значения,
        /// локальная — её объявление (рекурсивно), параметр и вызов — узлы,
        /// которые раскрываются дальше, значение перечисления и член сборки —
        /// источники. Имя, которое стоит только аргументом вызова метода
        /// проекта (`entity` в `GetMax(entity)`), — слабое: его видно, но граф
        /// сам туда не идёт — значение вызова и так раскроется через его return.
        private func resolve(_ found: [ValueFlow.Source], url: URL, model: SyntaxModel,
                             method: RustlynDeclaration?, via: [String], depth: Int) -> [Source] {
            var result: [Source] = []
            for source in found {
                let resolved = resolveOne(source, url: url, model: model, method: method, via: via, depth: depth)
                guard !resolved.isEmpty else { continue }
                if let call = argumentOf(source, url: url, model: model, method: method) {
                    result += resolved.map { found in
                        var weak = found
                        if weak.argumentOf == nil { weak.argumentOf = call }
                        return weak
                    }
                } else {
                    result += resolved
                }
            }
            return result
        }

        private func resolveOne(_ source: ValueFlow.Source, url: URL, model: SyntaxModel,
                                method: RustlynDeclaration?, via: [String], depth: Int) -> [Source] {
            let units = model.units
            let name = ValueFlow.string(units, source.range)
            // `value` в сеттере — то, что свойству присваивают.
            if source.chain == "value", let method, [.property, .indexer, .event].contains(method.kind),
               let setter = ValueFlow.setter(in: units, property: method.fullRange, name: method.nameRange),
               NSLocationInRange(source.range.location, setter) {
                return [Source(kind: .value(declarationOf(method, model: model, url: url)), via: via)]
            }
            // `new T(…)` — объект из аргументов, а они — свои источники.
            if source.constructs { return [] }
            let target = definition(url, at: source.range.location)
            if source.call {
                // Стэш компонента — `_health.Get(e)`, `.Has(e)` — это компонент, а не
                // внутренности Morpeh, даже если компилятор видит сам стэш.
                if !source.member, let component = stashCall(source.chain, url: url, method: method) {
                    return [Source(kind: .component(component), via: via)]
                }
                let declaration = target.flatMap { [.method, .constructor].contains($0.kind) ? declarationOf($0) : nil }
                // Метод сборки или пакета: время, случайное число — источник; `Math.Max` — нет.
                if let declaration, let target, Self.isLibrary(declaration.url) {
                    return library(source, type: target.container ?? "", member: target.shortName, at: declaration,
                                   url: url, model: model, method: method, via: via, depth: depth)
                }
                if declaration == nil, !source.member {
                    // `c.Value.ToObject<T>()` у ref-локальной из стэша — из поля `Value`.
                    if let typed = stashMember(source, name: name, url: url, model: model, method: method) {
                        return [Source(kind: .value(typed), via: via)]
                    }
                    // Вызов у локальной, чьего типа компилятор не знает, — из того, что в ней.
                    if let local = headLocal(source, url: url, model: model, method: method, via: via, depth: depth) {
                        return local
                    }
                }
                // Компилятор метода не знает, но он из известной библиотеки: `Math.Min` на net8.0.
                if declaration == nil, let known = libraryByName(source, url: url, model: model) {
                    return library(source, type: known.type, member: known.member, at: nil, url: url, model: model,
                                   method: method, via: via, depth: depth)
                }
                // `Config.Get<T>(ConfigAliases.Levels)` — конфиг целиком, а не код загрузчика.
                if let alias = configAlias(in: source, units: units) {
                    return [Source(kind: .origin(ValueOrigin(kind: .config, title: alias), at: nil), via: via)]
                }
                return [Source(kind: .call(source.chain, declaration), via: via)]
            }
            if let target {
                // Тип в приведении `(Vector3)x`, пространство имён и группа
                // методов (`Callback` без скобок) — не источники значения.
                if target.kind.isType || [.namespace, .method, .constructor, .operator].contains(target.kind) { return [] }
                if [.field, .property, .enumMember, .event].contains(target.kind) {
                    // Параметр типа Rustlyn тоже отдаёт как поле.
                    if target.kind == .field, isTypeParameter(target) { return [] }
                    // Локальные и параметры Rustlyn отдаёт как поля — отличает их
                    // место: поле внутри метода не объявить.
                    if source.chain == name, !source.member, let method,
                       let local = local(target, name: name, method: method, url: url, model: model,
                                         via: via, depth: depth) {
                        return local
                    }
                    let declaration = declarationOf(target)
                    if target.kind == .enumMember {
                        return [Source(kind: .origin(ValueOrigin(kind: .enumValue, title: declaration.title),
                                                     at: declaration), via: via)]
                    }
                    if Self.isLibrary(target.url) {
                        return library(source, type: target.container ?? "", member: target.shortName, at: declaration,
                                       url: url, model: model, method: method, via: via, depth: depth)
                    }
                    return [Source(kind: .value(declaration), via: via)]
                }
            }
            // Поле компонента через стэш, которого компилятор не видит.
            if let typed = stashMember(source, name: name, url: url, model: model, method: method) {
                return [Source(kind: .value(typed), via: via)]
            }
            // Хвоста цепочки компилятор не узнал (`v.x` у `var v = …` без
            // известного типа) — значение всё равно из её головы: локальной
            // или параметра.
            if !source.member, let local = headLocal(source, url: url, model: model, method: method, via: via, depth: depth) {
                return local
            }
            // Одиночное имя, которого компилятор не узнал: локальная переменная или параметр.
            if source.chain == name, !source.member, let method {
                if depth < 6, let initializer = ValueFlow.localInitializer(in: units, name: name, within: method.fullRange,
                                                                            before: source.range.location) {
                    return sources(of: initializer, url: url, model: model, method: method, via: via + [name],
                                   depth: depth + 1)
                }
                if let index = Self.parameterIndex(name, in: method) {
                    return [Source(kind: .parameter(name, declarationOf(method, model: model, url: url), index), via: via)]
                }
            }
            // Имя из известной библиотеки, которой компилятор не знает: `Stopwatch.Frequency`.
            if let known = libraryByName(source, url: url, model: model) {
                return library(source, type: known.type, member: known.member, at: nil, url: url, model: model,
                               method: method, via: via, depth: depth)
            }
            // Компилятор не узнал — например, тип переменной цикла по
            // сгенерированному фильтру. Поле с таким именем — по индексу.
            if let guess = byName(name, in: units) {
                return [Source(kind: .value(guess), via: via, byName: true)]
            }
            return [Source(kind: .unknown(source.chain, reason: nil), via: via)]
        }

        /// Константа класса алиасов конфигов среди аргументов вызова:
        /// `ConfigAliases.Levels` у `Config.Get<LevelsModel>(ConfigAliases.Levels)`.
        private func configAlias(in call: ValueFlow.Source, units: [UInt16]) -> String? {
            guard let configs, let arguments = ValueFlow.parameterList(in: units, after: call.range) else { return nil }
            let prefix = configs.aliases + "."
            return ValueFlow.sources(in: units, range: arguments).first { $0.chain.hasPrefix(prefix) && !$0.call }?.chain
        }

        /// Вызов метода проекта, аргументом которого стоит имя, — имя этого
        /// метода; nil — имя само значение (или аргумент библиотечного
        /// преобразования вроде `Mathf.Clamp`, тогда оно источник). Аргумент
        /// стэша (`_hp.Get(entity)`) — ключ, а не значение: тоже слабый.
        private func argumentOf(_ source: ValueFlow.Source, url: URL, model: SyntaxModel,
                                method: RustlynDeclaration?) -> String? {
            // Ключ `data[index]`: значение — из `data`.
            if source.isIndexKey { return "[]" }
            for call in source.calls.reversed() {
                let chain = ValueFlow.chain(in: model.units, endingWith: call)
                if stashCall(chain, url: url, method: method) != nil { return chain }
                if let target = definition(url, at: call.location) {
                    if Self.isLibrary(target.url) { continue }
                    if [.method, .constructor].contains(target.kind) { return chain }
                    continue
                }
                var probe = ValueFlow.Source(range: call, chain: chain, call: true)
                probe.links = ValueFlow.chainLinks(in: model.units, endingWith: call)
                probe.head = probe.links.first
                if libraryByName(probe, url: url, model: model) != nil { continue }
                return chain
            }
            return nil
        }

        /// `definition` с запоминанием: одно и то же имя граф спрашивает
        /// несколько раз — как источник и как вызов вокруг аргумента.
        private func definition(_ url: URL, at offset: Int) -> RustlynTarget? {
            let key = "\(url.path)|\(offset)"
            if let cached = definitions[key] { return cached }
            let found = rustlyn.definition(url, offset: offset, text: texts[url]).targets.first
            definitions[key] = .some(found)
            return found
        }

        // MARK: Библиотеки

        /// Член сборки. Время, случайное число, ввод, движок — источник;
        /// постоянная (`Vector3.zero`) — источник-константа; преобразование
        /// (`Math.Max`, `list.Count`, `ToString()`) — не источник: значение из
        /// получателя, а аргументы и так свои источники. Неизвестный член —
        /// из получателя, если тот в проекте, а иначе источник «сборка».
        private func library(_ source: ValueFlow.Source, type: String, member: String, at: ValueGraph.Declaration?,
                             url: URL, model: SyntaxModel, method: RustlynDeclaration?, via: [String],
                             depth: Int) -> [Source] {
            let title = source.chain + (source.call ? "()" : "")
            // `Mathf.Clamp`, `Math.Min` — член типа, а не значения: получателя нет.
            let typeName = ValueOrigins.cleanType(type).split(separator: ".").last.map(String.init)
            let isStatic = source.receiverChain.map { $0.chain.split(separator: ".").last.map(String.init) == typeName } ?? false
            func received() -> [Source] {
                isStatic ? [] : receiverSources(source, url: url, model: model, method: method, via: via, depth: depth)
            }
            switch ValueOrigins.classify(type: type, member: member) {
            case .origin(let kind):
                return [Source(kind: .origin(ValueOrigin(kind: kind, title: title), at: at), via: via)]
            case .constant:
                return [Source(kind: .origin(ValueOrigin(kind: .constant, title: title), at: at), via: via)]
            case .transform:
                return received()
            case .unknown:
                let found = received()
                return found.isEmpty ? [Source(kind: .origin(ValueOrigin(kind: .library, title: title), at: at), via: via)]
                    : found
            }
        }

        /// То, у чего берут член: `stats` у `stats.Count`, вызов у `Get(e).Value`.
        /// Тип (`Mathf` у `Mathf.Clamp`) — не источник: пусто.
        private func receiverSources(_ source: ValueFlow.Source, url: URL, model: SyntaxModel,
                                     method: RustlynDeclaration?, via: [String], depth: Int) -> [Source] {
            guard depth < 8 else { return [] }
            if let receiver = source.receiverChain {
                // Имя с большой буквы, которого компилятор не знает, — скорее тип, чем значение.
                return resolve([receiver], url: url, model: model, method: method, via: via, depth: depth + 1).filter {
                    guard case .unknown(let chain, nil) = $0.kind else { return true }
                    return chain.first?.isUppercase != true
                }
            }
            if source.member, let chain = source.receiver, let name = source.receiverLinks.last {
                var call = ValueFlow.Source(range: name, chain: chain, call: true)
                call.links = source.receiverLinks
                call.head = source.receiverLinks.first
                return resolve([call], url: url, model: model, method: method, via: via, depth: depth + 1)
            }
            return []
        }

        /// Что за член сборки вызов `call`: nil — не сборки.
        private func libraryKind(of call: ValueFlow.Source, url: URL, model: SyntaxModel) -> ValueOrigins.Library? {
            if let target = definition(url, at: call.range.location) {
                guard Self.isLibrary(target.url) else { return nil }
                return ValueOrigins.classify(type: target.container ?? "", member: target.shortName)
            }
            return libraryByName(call, url: url, model: model).map { ValueOrigins.classify(type: $0.type, member: $0.member) }
        }

        /// Имя, которого компилятор не знает, но оно из известной
        /// библиотеки: `Math.Min`, `MathF.Round`, `Stopwatch.Frequency`
        /// (rustlyn-ide на net8.0 этих типов не видит), `_random.Next()` у
        /// поля типа `Random`, `x.ToString()`. Тип и член — или nil.
        private func libraryByName(_ source: ValueFlow.Source, url: URL, model: SyntaxModel) -> (type: String, member: String)? {
            let words = source.chain.split(separator: ".").map(String.init)
            guard let member = words.last else { return nil }
            // Члены любого значения, строк и коллекций: компилятор не знает типа
            // получателя, но это преобразование того, у чего их берут.
            if Self.universalMembers.contains(member), source.call || member == "Length" {
                return ("object", member)
            }
            guard words.count >= 2 else { return nil }
            let owner = words[words.count - 2]
            // `Math.Min`: тип — предпоследнее звено с большой буквы.
            if owner.first?.isUppercase == true, ValueOrigins.classify(type: owner, member: member) != .unknown {
                return (owner, member)
            }
            // `_random.Next()`: тип поля — из его объявления.
            if words.count == 2, let head = source.head,
               let target = definition(url, at: head.location),
               [.field, .property].contains(target.kind), !Self.isLibrary(target.url),
               let type = declaredType(of: target), ValueOrigins.classify(type: type, member: member) != .unknown {
                return (type, member)
            }
            return nil
        }

        /// Методы, которые у любого значения, строки или коллекции (LINQ), —
        /// чтобы узнать их, когда компилятор не знает типа получателя.
        static let universalMembers: Set<String> = [
            "ToString", "GetHashCode", "Equals", "GetType", "CompareTo", "Substring", "Trim", "TrimStart", "TrimEnd",
            "Split", "Replace", "ToLower", "ToUpper", "ToLowerInvariant", "ToUpperInvariant", "Contains", "StartsWith",
            "EndsWith", "IndexOf", "LastIndexOf", "PadLeft", "PadRight", "ToList", "ToArray", "ToDictionary", "ToHashSet",
            "First", "FirstOrDefault", "Last", "LastOrDefault", "Single", "SingleOrDefault", "Where", "Select",
            "SelectMany", "Any", "All", "Sum", "Min", "Max", "Average", "OrderBy", "OrderByDescending", "ThenBy",
            "Skip", "Take", "Distinct", "Concat", "Aggregate", "ElementAt", "ElementAtOrDefault", "GetValueOrDefault",
            "Length", "ToUniversalTime", "ToLocalTime", "AddSeconds", "AddMinutes", "AddHours", "AddDays",
            "AddMilliseconds", "Subtract",
        ]

        /// Тип поля или свойства, как он записан в объявлении.
        private func declaredType(of target: RustlynTarget) -> String? {
            guard let model = model(target.url) else { return nil }
            let at = model.offset(at: LSPPosition(line: target.line, character: target.character))
            return outline(target.url).declarations.first { NSLocationInRange(at, $0.nameRange) }?.typeText
        }

        /// Голова цепочки `a.b.c`, если это локальная или параметр: то, откуда они.
        private func headLocal(_ source: ValueFlow.Source, url: URL, model: SyntaxModel, method: RustlynDeclaration?,
                               via: [String], depth: Int) -> [Source]? {
            guard let method, let head = source.head, head != source.range,
                  let target = definition(url, at: head.location),
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
            if let list = Self.parameters(of: method, in: units), NSLocationInRange(at, list) {
                guard let index = Self.parameterIndex(name, in: method) else { return [] }
                return [Source(kind: .parameter(name, declarationOf(method, model: model, url: url), index), via: via)]
            }
            let declared = NSRange(location: at, length: target.length)
            if ValueFlow.isTypeParameter(in: units, name: declared) { return [] }
            if ValueFlow.isLambdaParameter(in: units, name: declared) {
                if depth < 6, let found = lambdaSources(declared, url: url, model: model, method: method,
                                                        via: via + [name], depth: depth + 1) {
                    return found
                }
                return [Source(kind: .unknown(name, reason: L("параметр лямбды")), via: via)]
            }
            // Круг (`a = b; b = a;`) или слишком длинная цепочка.
            guard depth < 6, !via.contains(name) else { return [] }
            let writes = localWrites(at: at, length: target.length, name: name, method: method, url: url, model: model,
                                     via: via + [name], depth: depth)
            if writes.isEmpty {
                return [Source(kind: .unknown(name, reason: L("локальная — откуда значение, не понять")), via: via)]
            }
            return writes.flatMap(\.sources)
        }

        static func isAssembly(_ url: URL) -> Bool { ["dll", "exe"].contains(url.pathExtension.lowercased()) }

        /// Чужой код: сборка или пакет Unity из `Library/PackageCache` — у
        /// Morpeh там исходники, но это не код проекта, и граф в него не идёт.
        static func isLibrary(_ url: URL) -> Bool { isAssembly(url) || url.path.contains("/Library/PackageCache/") }

        /// Имя сборки или пакета: `UnityEngine.CoreModule`, `com.scellecs.morpeh`.
        static func libraryName(_ url: URL) -> String? {
            if isAssembly(url) { return url.deletingPathExtension().lastPathComponent }
            let parts = url.pathComponents
            guard let at = parts.firstIndex(of: "PackageCache"), at + 1 < parts.count else { return nil }
            return parts[at + 1].split(separator: "@").first.map(String.init)
        }

        /// Литерал для подписи: длинную строку — обрезать.
        static func clip(_ text: String) -> String {
            let single = text.replacingOccurrences(of: "\n", with: " ")
            return single.count > 48 ? String(single.prefix(47)) + "…" : single
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

        /// Скобки параметров члена: `(…)` метода и `[…]` индексатора `this[int i]`.
        static func parameters(of member: RustlynDeclaration, in units: [UInt16]) -> NSRange? {
            if let list = ValueFlow.parameterList(in: units, after: member.nameRange) { return list }
            guard member.kind == .indexer else { return nil }
            var i = NSMaxRange(member.nameRange)
            while i < units.count, units[i] == 0x20 || units[i] == 0x09 { i += 1 }
            guard i < units.count, units[i] == 0x5B else { return nil }
            let close = ValueFlow.matching(units, open: i)
            return close > i ? NSRange(location: i + 1, length: close - i - 1) : nil
        }

        /// `ref T x`, `in T x = 1` — номер параметра по имени.
        static func parameterIndex(_ name: String, in method: RustlynDeclaration) -> Int? {
            method.parameters.firstIndex { parameter in
                let head = parameter.split(separator: "=").first ?? Substring(parameter)
                return head.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) == name
            }
        }

        // MARK: Где задано: конфиги

        /// Строки JSON конфигов, где задан ключ поля модели. Файлы — по
        /// алиасам модели (`[JsonType(typeof(M))]` у константы класса
        /// алиасов и реестр `meta.json`); не нашлось алиасов — все конфиги с
        /// этим ключом. Конфиги ищутся в обеих половинах пары: у клиента
        /// своих нет, они приходят с сервера.
        func configValues(of value: ValueGraph.Declaration) -> [Site] {
            guard let configs else { return [] }
            let declaration = named(value)
            guard let model = model(declaration.url) else { return [] }
            let offset = model.offset(at: LSPPosition(line: declaration.line, character: declaration.character))
            let member = outline(declaration.url).declarations.first { NSLocationInRange(offset, $0.nameRange) }
            let head = member.map {
                ValueFlow.string(model.units, NSRange(location: $0.fullRange.location,
                                                      length: max(0, $0.nameRange.location - $0.fullRange.location)))
            } ?? ""
            let key = ConfigLinks.jsonProperty(in: head, attribute: configs.keyAttribute) ?? declaration.shortName
            let folders = [root, partner].compactMap { $0 }.compactMap { project -> (project: URL, folder: URL)? in
                let folder = project.appendingPathComponent(configs.folder)
                return FileManager.default.fileExists(atPath: folder.appendingPathComponent(configs.registry).path)
                    ? (project, folder) : nil
            }
            guard !folders.isEmpty else { return [] }
            let aliases = declaration.typeName.map { configAliases(of: $0, rules: configs) } ?? []
            var files: [(url: URL, project: URL, alias: String?)] = []
            for (project, folder) in folders {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(configs.registry)) else { continue }
                for (path, alias) in ConfigLinks.aliases(meta: data).sorted(by: { $0.key < $1.key }) where aliases.contains(alias) {
                    files.append((folder.appendingPathComponent(path), project, alias))
                }
            }
            // Модель не нашлась среди алиасов — по ключу во всех конфигах.
            let byKey = files.isEmpty
            if byKey {
                for (project, folder) in folders {
                    files += Self.jsonFiles(in: folder, containing: "\"\(key)\"", limit: 40).map { ($0, project, nil) }
                }
            }
            var sites: [Site] = []
            for file in files {
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for found in ConfigLinks.jsonValues(ofKey: key, in: text).prefix(3) {
                    var site = dataSite(file.url, lines: lines, line: found.line)
                    site.title = file.url.lastPathComponent
                    site.project = file.project
                    site.note = [file.alias.map { L("конфиг \($0)") }, byKey ? L("по ключу — может быть неточно") : nil]
                        .compactMap { $0 }.joined(separator: " · ")
                    sites.append(site)
                }
            }
            NSLog("[graph] конфиг %@ (%@): алиасов %d, файлов %d, строк %d%@", key, declaration.typeName ?? "",
                  aliases.count, files.count, sites.count, byKey ? " — по ключу" : "")
            return sites
        }

        /// Алиасы конфигов, в которых лежит модель `owner`: она сама или тип,
        /// который держит её полем (`JobCompany` в `JobData.Companies`), — до
        /// трёх уровней вверх. Класс алиасов — в обеих половинах пары.
        private func configAliases(of owner: String, rules: ConfigRules) -> Set<String> {
            let indexes = [(index, root), (partnerIndex, partner)].compactMap { pair -> (SymbolIndex, URL)? in
                guard let index = pair.0, let root = pair.1 else { return nil }
                return (index, root)
            }
            let holders = indexes.map { ConfigCache.shared.holders(in: $0.0) }
            var models: Set<String> = [owner]
            var frontier: Set<String> = [owner]
            for _ in 0..<3 where !frontier.isEmpty {
                var next: Set<String> = []
                for map in holders {
                    for type in frontier { next.formUnion(map[type] ?? []) }
                }
                next.subtract(models)
                models.formUnion(next)
                frontier = next
            }
            var aliases: Set<String> = []
            for (index, root) in indexes {
                for id in index.typesByName[rules.aliases] ?? [] {
                    let url = root.appendingPathComponent(index.relPath(id))
                    guard let text = texts[url] ?? SymbolIndex.readSource(url) else { continue }
                    for entry in ConfigLinks.aliasModels(in: text) where !Set(entry.models).isDisjoint(with: models) {
                        aliases.insert(entry.alias)
                    }
                }
            }
            return aliases
        }

        /// JSON в папке (и глубже), где есть `needle`, — не больше `limit`.
        static func jsonFiles(in folder: URL, containing needle: String, limit: Int) -> [URL] {
            let bytes = Data(needle.utf8)
            var found: [URL] = []
            for url in ConfigCache.shared.jsonFiles(in: folder) {
                guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.range(of: bytes) != nil else { continue }
                found.append(url)
                if found.count >= limit { break }
            }
            return found
        }

        // MARK: Где задано: инспектор Unity

        /// Строки префабов, сцен и ассетов, где задано сериализованное поле
        /// скрипта: объекты с `m_Script` его GUID и строка `  поле: значение`
        /// в их блоке. Это чтение всех ассетов проекта — секунды, поэтому
        /// только по кнопке (или `--assets` без окна).
        func inspectorValues(of value: ValueGraph.Declaration) -> [Site] {
            let declaration = named(value)
            guard let unity = UnityProjectInfo.find(inWorkspace: root),
                  let assets = Self.unityAssets(unity.root),
                  declaration.url.path.hasPrefix(unity.root.path + "/") else { return [] }
            let script = String(declaration.url.path.dropFirst(unity.root.path.count + 1))
            guard let guid = assets.guid(forAsset: script) else { return [] }
            let paths = Self.unityDataFiles(workspace: root, unity: unity)
            let started = Date()
            let hits = UnityUsages.find(guid: guid, root: unity.root, paths: paths,
                                        resolve: { assets.displayName(for: $0) })
            var sites: [Site] = []
            for hit in hits.prefix(60) {
                let url = unity.root.appendingPathComponent(hit.relPath)
                // Сцена бывает на сотню мегабайт — читаем только блок объекта.
                guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
                let window = Self.lines(of: data, from: hit.line, limit: 4000)
                guard let found = UnityYAMLFile.serializedField(declaration.shortName, afterLine: 0, lines: window.lines)
                else { continue }
                var site = dataSite(url, lines: window.lines, line: found.line, shift: hit.line)
                site.title = hit.context.map { "\(url.lastPathComponent) › \($0)" } ?? url.lastPathComponent
                sites.append(site)
            }
            NSLog("[graph] инспектор %@: файлов %d, объектов %d, строк %d за %.1f с", declaration.title, paths.count,
                  hits.count, sites.count, Date().timeIntervalSince(started))
            return sites
        }

        /// Индекс GUID Unity из кэша — один на процесс: это десятки мегабайт.
        private static func unityAssets(_ root: URL) -> UnityAssetIndex? {
            UnityCache.shared.assets(root)
        }

        /// Префабы, сцены и ассеты проекта — пути от корня Unity-проекта.
        private static func unityDataFiles(workspace: URL, unity: UnityProjectInfo) -> [String] {
            UnityCache.shared.dataFiles(workspace: workspace, unity: unity)
        }

        /// Место в строке данных: превью — сами строки, без лексера: файл
        /// может быть сценой на сотню мегабайт. `lines` — строки файла с
        /// `shift`-й, `line` — номер среди них.
        private func dataSite(_ url: URL, lines: [Substring], line: Int, shift: Int = 0) -> Site {
            var site = Site(url: url, offset: line + shift, line: line + shift, title: url.lastPathComponent)
            site.isData = true
            let first = max(0, line - 1)
            let last = min(lines.count - 1, line + 1)
            if first <= last {
                site.preview = (first...last).map { number in
                    let text = String(lines[number].prefix(FilePreview.maxLineLength)).replacingOccurrences(of: "\r", with: "")
                    return FilePreview.Line(number: number + shift, segments: Self.dataSegments(text))
                }
            }
            return site
        }

        /// Строки файла с номера `from` (с нуля), не больше `limit`: перевод
        /// строки ищет `memchr`, и до нужного места файл не декодируется.
        static func lines(of data: Data, from: Int, limit: Int) -> (lines: [Substring], first: Int) {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (lines: [Substring], first: Int) in
                guard let base = raw.baseAddress else { return ([], from) }
                var offset = 0
                var line = 0
                while line < from, offset < raw.count {
                    guard let found = memchr(base + offset, 0x0A, raw.count - offset) else { return ([], from) }
                    offset = base.distance(to: UnsafeRawPointer(found)) + 1
                    line += 1
                }
                var end = offset
                var taken = 0
                while taken < limit, end < raw.count {
                    guard let found = memchr(base + end, 0x0A, raw.count - end) else { end = raw.count; break }
                    end = base.distance(to: UnsafeRawPointer(found)) + 1
                    taken += 1
                }
                let text = String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<end]), as: UTF8.self)
                return (text.split(separator: "\n", omittingEmptySubsequences: false), from)
            }
        }

        /// `"key": value` и `key: value` — ключ и значение разными цветами.
        static func dataSegments(_ text: String) -> [FilePreview.Segment] {
            guard let colon = text.range(of: ": ") ?? (text.hasSuffix(":") ? text.range(of: ":", options: .backwards) : nil)
            else { return [FilePreview.Segment(text: text, kind: .plain, focused: false)] }
            let key = String(text[..<colon.lowerBound])
            let value = String(text[colon.upperBound...])
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let kind: TokenKind = trimmed.hasPrefix("\"") ? .string
                : (trimmed.first.map { $0.isNumber || $0 == "-" } ?? false) ? .number
                : ["true", "false", "null"].contains(where: trimmed.hasPrefix) ? .keyword : .plain
            return [FilePreview.Segment(text: key, kind: key.contains("\"") ? .string : .attribute, focused: false),
                    FilePreview.Segment(text: String(text[colon]), kind: .punctuation, focused: false),
                    FilePreview.Segment(text: value, kind: kind, focused: false)]
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

/// Что граф конфигов спрашивает много раз: какие типы держат тип полем
/// (по индексу проекта) и какие JSON лежат в папке конфигов. Индекс
/// неизменяем, и карта для него строится один раз.
final class ConfigCache: @unchecked Sendable {
    static let shared = ConfigCache()
    private let lock = NSLock()
    /// Корень индекса → сам индекс и слово типа → типы с полем или свойством такого типа.
    private var holders: [String: (index: ObjectIdentifier, map: [String: Set<String>])] = [:]
    private var jsonFileLists: [String: [URL]] = [:]

    func holders(in index: SymbolIndex) -> [String: Set<String>] {
        lock.lock(); defer { lock.unlock() }
        if let cached = holders[index.root.path], cached.index == ObjectIdentifier(index) { return cached.map }
        var map: [String: Set<String>] = [:]
        for id in 0..<Int32(index.count) {
            let symbol = index[id]
            guard symbol.kind == .field || symbol.kind == .property, let type = symbol.typeText,
                  let container = symbol.container?.split(separator: ".").last.map(String.init) else { continue }
            for word in type.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }) {
                map[String(word), default: []].insert(container)
            }
        }
        holders[index.root.path] = (ObjectIdentifier(index), map)
        return map
    }

    /// JSON папки конфигов по порядку путей. Список — на процесс: файлы
    /// конфигов добавляют редко, а обход — тысячи файлов.
    func jsonFiles(in folder: URL) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        if let cached = jsonFileLists[folder.path] { return cached }
        var found: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" { found.append(url) }
        }
        found.sort { $0.path < $1.path }
        jsonFileLists[folder.path] = found
        return found
    }
}

/// Индекс GUID Unity и список префабов, сцен и ассетов — из кэша Pilot,
/// один раз на процесс: граф ищет по ним значения полей инспектора.
final class UnityCache: @unchecked Sendable {
    static let shared = UnityCache()
    private let lock = NSLock()
    private var assetIndexes: [String: UnityAssetIndex] = [:]
    private var files: [String: [String]] = [:]

    func assets(_ root: URL) -> UnityAssetIndex? {
        lock.lock(); defer { lock.unlock() }
        if let index = assetIndexes[root.path] { return index }
        guard let index = IndexCache.loadAssets(root: root)?.index else { return nil }
        assetIndexes[root.path] = index
        return index
    }

    func dataFiles(workspace: URL, unity: UnityProjectInfo) -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let cached = files[workspace.path] { return cached }
        let extensions: Set<String> = ["prefab", "unity", "asset"]
        let all = IndexCache.load(root: workspace)?.display ?? []
        let found = all.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .compactMap(unity.projectPath(fromWorkspace:))
        files[workspace.path] = found
        return found
    }
}
