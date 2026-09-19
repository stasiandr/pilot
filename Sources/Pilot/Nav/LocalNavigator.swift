import Foundation

/// Документ, из которого пришёл запрос. Без AppKit — чтобы навигатор попадал в тесты ядра.
struct NavDocument {
    let url: URL
    /// Путь от корня проекта; nil — файл лежит вне проекта.
    let relPath: String?
    let model: SyntaxModel
    let outline: [OutlineItem]
}

/// Найденное объявление: куда прыгать и как показать в списке выбора.
struct FoundDeclaration: Equatable {
    var target: NavTarget
    var name: String
    var kind: OutlineKind
    var container: String?
    var path: String
}

/// Использование, найденное поиском по тексту проекта.
struct FoundReference: Equatable {
    var target: NavTarget
    var path: String
    var line: Int
}

/// Быстрый навигатор: ⌘B, ⌘T и ⌘R без языкового сервера.
///
/// Работает с первой секунды по индексу объявлений и заменяется Roslyn, как
/// только тот прогреется. Семантики нет, есть приближение к ней:
///
///   * `a.b.c` разбирается по объявленным типам — поля, свойства, параметра,
///     локальной переменной (`Foo x`, `var x = new Foo()`, `var x = Make()`),
///     возвращаемого типа метода; члены ищутся и в базовых классах;
///   * из одноимённых типов выбирается тот, чей namespace подключён в файле;
///   * перегрузка выбирается по числу аргументов в вызове, а метод-расширение
///     ищется по таблице «расширяемый тип → методы»;
///   * если тип выяснить не удалось — объявления с таким именем по всему
///     проекту, ближние вперёд, и выбор остаётся за человеком.
///
/// Чего нет: сверки типов аргументов, вывода типов из лямбд и LINQ, расширений
/// и сборок без исходников. Там отвечает Roslyn, когда готов.
struct LocalNavigator {
    let index: SymbolIndex?
    let document: NavDocument
    /// Namespace и using текущего файла — берём из самого документа,
    /// а не из индекса: файл мог измениться после индексации.
    let fileInfo: SourceFileInfo

    init(index: SymbolIndex?, document: NavDocument) {
        self.index = index
        self.document = document
        var info = SourceFileInfo(path: document.relPath ?? document.url.lastPathComponent)
        info.namespaces = document.outline.filter { $0.kind == .namespace }.map(\.name)
        if document.model.spec?.outline == .cFamily { SymbolIndex.readUsings(document.model, into: &info) }
        self.fileInfo = info
    }

    /// Ответ на ⌘B. `isExact` — тип цели установлен, можно прыгать сразу;
    /// иначе это кандидаты по имени, ближние первыми.
    struct Answer: Equatable {
        var declarations: [FoundDeclaration]
        var isExact: Bool
        static let none = Answer(declarations: [], isExact: false)
    }

    // MARK: - Переход к объявлению

    func definition(at offset: Int) -> Answer {
        // Сначала Rustlyn: он разрешает имя областью видимости на месте
        // обращения, а этот разбор — по индексу объявлений, и на двух
        // одноимённых типах из разных namespace ошибается молча.
        // `nil` — Rustlyn не ответил (нет сессии, файл правят, имя не из
        // проекта), и дальше как раньше.
        if let answer = rustlynDefinition(at: offset) { return answer }

        let model = document.model
        guard let identifier = Occurrences.identifier(in: model, at: offset) else { return .none }
        let tokens = tokensAround(identifier.range.location)
        guard let k = tokens.firstIndex(where: { Int($0.start) == identifier.range.location }),
              isWord(tokens[k]) else { return .none }   // внутри строки или комментария
        let name = identifier.text

        // Курсор на самом объявлении — идти некуда.
        if document.outline.contains(where: { $0.range.location == identifier.range.location }) {
            return .none
        }

        // `receiver.name`
        if let dot = precedingDot(tokens, k) {
            if let segments = chainBackward(tokens, endingAt: dot), !segments.isEmpty,
               let value = evaluate(segments, at: identifier.range.location) {
                guard let owner = typeOf(value) else { return .none }   // тип не из проекта
                let found = members(named: name, of: owner)
                if !found.isEmpty { return answer(overloads: found, at: identifier.range.location) }
                if let nested = nestedType(named: name, in: owner) {
                    return Answer(declarations: [declaration(nested)], isExact: true)
                }
                // Член унаследован от MonoBehaviour или другого внешнего предка.
                if hasExternalAncestor(owner) { return .none }
                // Тип известен, а члена в нём нет: одноимённое в другом типе —
                // только подсказка, прыгать туда без спроса нельзя.
                return fallback(name, preferMembers: true, at: identifier.range.location, allowJump: false)
            }
            return fallback(name, preferMembers: true, at: identifier.range.location)
        }

        // Голое имя: локальная переменная, член текущего типа, тип.
        let typePosition = looksLikeTypePosition(tokens, k)
        if !typePosition, let local = localDeclaration(of: name, before: identifier.range.location),
           local.location != identifier.range.location {
            return Answer(declarations: [declaration(local: local, name: name)], isExact: true)
        }
        let current = currentType(at: identifier.range.location)
        if !typePosition, let current {
            let found = members(named: name, of: current)
            if !found.isEmpty { return answer(overloads: found, at: identifier.range.location) }
        }
        if let type = resolveType(name, context: fileInfo) {
            return Answer(declarations: [declaration(primaryDeclaration(of: type.id))], isExact: true)
        }
        // Индекса ещё нет или файл новый — хотя бы структура самого файла.
        if let item = document.outline.first(where: { $0.name == name && $0.kind != .namespace }) {
            return Answer(declarations: [declaration(item: item)], isExact: true)
        }
        // `Destroy(…)`, `transform` внутри наследника MonoBehaviour — члены
        // внешнего предка; одноимённое из проекта было бы подсказкой не туда.
        if !typePosition, let current, hasExternalAncestor(current) { return .none }
        if typePosition || name.first?.isUppercase == true, index?.byName[name] == nil { return .none }
        return fallback(name, preferMembers: !typePosition, at: identifier.range.location)
    }

    // MARK: - Вычисление цепочки `a.b().c`

    struct Segment: Equatable {
        var name: String
        var isCall = false
        var isIndexer = false
        var isNew = false
        var genericArgs: [String] = []
    }

    /// Тип с подстановкой дженериков: `Stash<Health>` → id `Stash`, `T → Health`.
    struct ResolvedType: Equatable {
        var id: Int32
        var args: [String: String] = [:]
    }

    /// Тип, записанный текстом, и файл, в котором он записан (его using).
    struct TypedText {
        var text: String
        var context: SourceFileInfo
    }

    enum Value {
        case instance(TypedText)
        case typeInstance(ResolvedType)   // this
        case staticType(ResolvedType)     // Foo.Bar — обращение через имя типа
        /// Тип известен, но его исходников в проекте нет: `StringBuilder`,
        /// `Quaternion`, `MonoBehaviour`. Искать дальше незачем — честнее
        /// ответить «не нашлось», чем показать одноимённое чужое.
        case external
    }

    func typeOf(_ value: Value) -> ResolvedType? {
        switch value {
        case .instance(let typed):     return resolveType(typed.text, context: typed.context)
        case .typeInstance(let type):  return type
        case .staticType(let type):    return type
        case .external:                return nil
        }
    }

    func evaluate(_ segments: [Segment], at offset: Int, depth: Int = 0) -> Value? {
        guard depth < 4, let first = segments.first else { return nil }
        var value: Value?
        var start = 0

        if first.isNew {
            value = .instance(TypedText(text: first.name, context: fileInfo))
        } else if first.name == "this" {
            value = currentType(at: offset).map { .typeInstance($0) }
        } else if first.name == "base" {
            if let current = currentType(at: offset) {
                value = baseTypes(of: current).first.map { .typeInstance($0) }
            }
        } else if !first.isCall, let local = localDeclaration(of: first.name, before: offset),
                  let typed = localType(of: local, depth: depth) {
            value = .instance(typed)
            if first.isIndexer { value = .instance(TypedText(text: elementType(typed.text), context: typed.context)) }
        } else if let current = currentType(at: offset), let member = members(named: first.name, of: current).first {
            value = valueOf(member: member, segment: first)
        } else if let type = resolveType(first.name, context: fileInfo) {
            value = .staticType(type)
        } else {
            // `Acme.Billing.Invoice.Create()` — первые звенья оказались namespace.
            for k in 1..<segments.count where !segments[k - 1].isCall {
                if let type = resolveType(segments[k].name, context: fileInfo) {
                    value = .staticType(type)
                    start = k
                    break
                }
            }
            // `Quaternion.Euler`, `string.Empty`, `GUILayout.Space` — имя типа,
            // которого в исходниках нет. Строчное имя — скорее параметр лямбды
            // или `out var`, его тип просто неизвестен.
            if value == nil, first.name.first?.isUppercase == true || Self.builtinTypes.contains(first.name) {
                return .external
            }
        }

        guard var current = value else { return nil }
        for segment in segments.dropFirst(start + 1) {
            guard let owner = typeOf(current) else {
                if case .instance = current { return .external }   // тип записан, но он не наш
                return current
            }
            if let member = members(named: segment.name, of: owner).first {
                guard let next = valueOf(member: member, segment: segment) else { return nil }
                current = next
            } else if let nested = nestedType(named: segment.name, in: owner) {
                current = .staticType(ResolvedType(id: nested))
            } else {
                return hasExternalAncestor(owner) ? .external : nil
            }
        }
        return current
    }

    /// Во что превращается обращение к члену: тип поля, свойства, результата метода.
    private func valueOf(member: (id: Int32, owner: ResolvedType), segment: Segment) -> Value? {
        guard let index else { return nil }
        let symbol = index[member.id]
        let context = index.fileInfo(member.id)
        if symbol.kind == .enumCase {
            return .instance(TypedText(text: index[member.owner.id].name, context: context))
        }
        guard var text = symbol.typeText, !Self.opaqueTypes.contains(text) else { return nil }
        text = substitute(text, member.owner.args)
        if !segment.genericArgs.isEmpty { text = substituteMethodGenerics(text, segment.genericArgs) }
        if segment.isIndexer { text = elementType(text) }
        return .instance(TypedText(text: text, context: context))
    }

    // MARK: - Типы

    /// Тип, по которому ничего нельзя сказать о членах.
    static let opaqueTypes: Set<String> = ["dynamic", "object", "var"]

    static let builtinTypes: Set<String> = [
        "bool", "byte", "char", "decimal", "double", "dynamic", "float", "int", "long", "nint", "nuint",
        "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "void", "var",
    ]

    /// Тип по имени, как он написан в файле `context`: с дженериками,
    /// с namespace впереди, через псевдоним `using`.
    func resolveType(_ raw: String, context: SourceFileInfo, depth: Int = 0) -> ResolvedType? {
        guard let index, depth < 4 else { return nil }
        var text = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["ref ", "readonly ", "in ", "out ", "this ", "params "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        while text.hasSuffix("?") { text.removeLast() }
        guard !text.isEmpty, !text.hasSuffix("]") else { return nil }   // массивы — не наши типы

        var base = text
        var args: [String] = []
        if let lt = text.firstIndex(of: "<"), text.hasSuffix(">") {
            base = String(text[..<lt])
            args = Self.splitTopLevel(String(text[text.index(after: lt)..<text.index(before: text.endIndex)]))
        }
        var qualifier: String?
        if let dot = base.lastIndex(of: ".") {
            qualifier = String(base[..<dot])
            base = String(base[base.index(after: dot)...])
        }
        if qualifier == nil, let alias = context.aliases[base] {
            return resolveType(alias, context: context, depth: depth + 1)
        }
        guard !Self.builtinTypes.contains(base),
              let candidates = index.typesByName[base], !candidates.isEmpty else { return nil }

        let best = candidates.max { rankType($0, context: context, qualifier: qualifier)
                                    < rankType($1, context: context, qualifier: qualifier) }!
        // Параметры дженерика записаны только у одной из partial-частей.
        let params = candidates.lazy.map { index[$0].genericParams }.first { !$0.isEmpty } ?? []
        var map: [String: String] = [:]
        for (param, arg) in zip(params, args) { map[param] = arg }
        return ResolvedType(id: best, args: map)
    }

    /// Чем ближе объявление к месту использования, тем выше.
    private func rankType(_ id: Int32, context: SourceFileInfo, qualifier: String?) -> Int {
        guard let index else { return 0 }
        let symbol = index[id]
        let info = index.fileInfo(id)
        var score = 0
        if info.path == context.path { score += 100 }
        let namespaces = info.namespaces
        for ns in namespaces {
            if context.namespaces.contains(where: { $0 == ns || $0.hasPrefix(ns + ".") }) { score += 50 }
            if context.usings.contains(ns) { score += 40 }
        }
        if namespaces.isEmpty && context.namespaces.isEmpty { score += 20 }
        if let qualifier, let container = symbol.container ?? namespaces.first,
           container == qualifier || container.hasSuffix("." + qualifier) { score += 60 }
        let stem = ((info.path as NSString).lastPathComponent as NSString).deletingPathExtension
        if stem == symbol.name { score += 5 }
        return score
    }

    /// Члены типа с таким именем — в нём самом или выше по иерархии.
    /// Обход в ширину с общим списком посещённых: у ромбовидных иерархий
    /// рекурсия по каждому пути отдельно разрастается экспоненциально.
    func members(named name: String, of type: ResolvedType) -> [(id: Int32, owner: ResolvedType)] {
        guard index != nil else { return [] }
        var queue = [type]
        var visited: Set<Int32> = []
        var head = 0
        while head < queue.count, visited.count < 16 {
            let current = queue[head]
            head += 1
            guard visited.insert(current.id).inserted else { continue }
            let own = ownMembers(named: name, of: current.id)
            if !own.isEmpty { return own.map { ($0, current) } }
            // Свой член важнее расширения — как и в самом C#.
            let extended = extensionMembers(named: name, of: current)
            if !extended.isEmpty { return extended }
            queue.append(contentsOf: baseTypes(of: current).filter { !visited.contains($0.id) })
        }
        return []
    }

    /// Методы-расширения типа: `static void Say(this Player p)` объявлен
    /// в постороннем static-классе, а зовётся как член Player, и через
    /// `membersByOwner` его не найти. Получателя проверяем резолвом —
    /// одноимённый Player из чужого namespace расширяет не наш тип.
    private func extensionMembers(named name: String,
                                  of type: ResolvedType) -> [(id: Int32, owner: ResolvedType)] {
        guard let index else { return [] }
        let parts = Set(partialParts(of: type.id))
        let found = (index.extensionsByReceiver[index[type.id].name] ?? []).filter { id in
            let symbol = index[id]
            guard symbol.name == name, let first = symbol.parameters.first,
                  first.hasPrefix(SymbolIndex.extensionMarker),
                  let receiver = resolveType(String(first.dropFirst(SymbolIndex.extensionMarker.count)),
                                             context: index.fileInfo(id)) else { return false }
            return parts.contains(receiver.id)
        }
        return found.map { ($0, type) }
    }

    private func ownMembers(named name: String, of typeID: Int32) -> [Int32] {
        guard let index else { return [] }
        let owner = index[typeID]
        let ownerNamespaces = index.fileInfo(typeID).namespaces
        return (index.membersByOwner[owner.name] ?? []).filter { id in
            guard index[id].name == name else { return false }
            return Self.sameNamespace(ownerNamespaces, index.fileInfo(id).namespaces)
        }
    }

    /// Файлы без namespace считаем совместимыми с любыми: так пишут и глобальные
    /// типы, и Unity-скрипты по умолчанию.
    private static func sameNamespace(_ a: [String], _ b: [String]) -> Bool {
        a.isEmpty || b.isEmpty || a.contains(where: b.contains)
    }

    /// Части того же самого типа: partial-классы в разных файлах. Одноимённые
    /// типы из других namespace сюда не входят — у популярных имён их сотни.
    private func partialParts(of typeID: Int32) -> [Int32] {
        guard let index else { return [typeID] }
        let symbol = index[typeID]
        let namespaces = index.fileInfo(typeID).namespaces
        let parts = (index.typesByName[symbol.name] ?? []).filter { part in
            index[part].container == symbol.container
                && Self.sameNamespace(namespaces, index.fileInfo(part).namespaces)
        }
        return parts.isEmpty ? [typeID] : parts
    }

    /// Базовые типы со всех partial-частей, с подставленными дженериками.
    func baseTypes(of type: ResolvedType) -> [ResolvedType] {
        guard let index else { return [] }
        var result: [ResolvedType] = []
        for part in partialParts(of: type.id) {
            for base in index[part].bases {
                if let resolved = resolveType(substitute(base, type.args), context: index.fileInfo(part)),
                   resolved.id != type.id, !result.contains(resolved) {
                    result.append(resolved)
                }
            }
        }
        return result
    }

    /// Есть ли в иерархии предок, которого нет в исходниках (MonoBehaviour,
    /// Exception…). Тогда ненайденный член, скорее всего, объявлен там.
    private func hasExternalAncestor(_ type: ResolvedType) -> Bool {
        guard let index else { return false }
        var queue = [type]
        var visited: Set<Int32> = []
        var head = 0
        while head < queue.count, visited.count < 16 {
            let current = queue[head]
            head += 1
            guard visited.insert(current.id).inserted else { continue }
            for part in partialParts(of: current.id) {
                for base in index[part].bases {
                    if let resolved = resolveType(substitute(base, current.args), context: index.fileInfo(part)) {
                        queue.append(resolved)
                    } else if !Self.looksLikeInterface(base) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// `IDisposable`, `IEquatable<T>` — интерфейсы без исходников не дают членов,
    /// которые искали бы через них: реализация всё равно в самом типе.
    private static func looksLikeInterface(_ name: String) -> Bool {
        let base = name.split(separator: ".").last.map(String.init) ?? name
        guard base.count > 1, base.first == "I" else { return false }
        return base[base.index(after: base.startIndex)].isUppercase
    }

    private func nestedType(named name: String, in owner: ResolvedType) -> Int32? {
        guard let index else { return nil }
        let ownerName = index[owner.id].name
        return index.typesByName[name]?.first { index[$0].container == ownerName }
    }

    /// Из partial-частей — та, что лежит в одноимённом файле: обычно это «главная».
    private func primaryDeclaration(of id: Int32) -> Int32 {
        guard let index else { return id }
        let symbol = index[id]
        let parts = (index.typesByName[symbol.name] ?? []).filter { index[$0].container == symbol.container }
        return parts.first { part in
            let path = index.relPath(part)
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension == symbol.name
        } ?? id
    }

    /// Тип, внутри которого стоит курсор: ближайшее объявление выше — либо сам
    /// тип, либо член, чей контейнер и есть этот тип.
    func currentType(at offset: Int) -> ResolvedType? {
        guard let nearest = document.outline.last(where: {
            $0.range.location <= offset && $0.kind != .namespace
        }) else { return nil }
        let name = nearest.kind == .type ? nearest.name : nearest.container
        guard let name, let index else { return nil }
        // Предпочитаем объявление из этого же файла.
        if let own = index.typesByName[name]?.first(where: { index.fileInfo($0).path == fileInfo.path }) {
            let params = index[own].genericParams
            return ResolvedType(id: own, args: Dictionary(uniqueKeysWithValues: params.map { ($0, $0) }))
        }
        return resolveType(name, context: fileInfo)
    }

    /// Из одноимённых членов оставляем те, у кого столько же параметров,
    /// сколько аргументов в вызове под курсором. Если после отбора не осталось
    /// ничего — значит, в ход пошли `params` или значения по умолчанию, и
    /// честнее показать все. Один кандидат — прыгаем, несколько — список:
    /// наугад выбранная перегрузка уводит не туда молча.
    private func answer(overloads found: [(id: Int32, owner: ResolvedType)], at offset: Int) -> Answer {
        var ids = found.map(\.id)
        if let index, ids.count > 1, let arguments = argumentCount(at: offset) {
            let exact = ids.filter { Self.arity(index[$0]) == arguments }
            if !exact.isEmpty { ids = exact }
        }
        return Answer(declarations: ids.map { declaration($0) }, isExact: ids.count == 1)
    }

    /// Сколько аргументов ждёт член на месте вызова. У метода-расширения
    /// первый параметр — сам получатель, и его там не пишут.
    private static func arity(_ symbol: Symbol) -> Int {
        let count = symbol.parameters.count
        return SymbolIndex.extensionReceiver(symbol) != nil ? count - 1 : count
    }

    /// Сколько аргументов в вызове под курсором: `Foo(a, b)` → 2, `Foo()` → 0.
    /// nil — за именем нет скобки (это не вызов) или она не закрылась поблизости.
    func argumentCount(at offset: Int) -> Int? {
        let model = document.model
        guard model.lineCount > 0 else { return nil }
        let line = model.line(containing: offset)
        let tokens = model.tokens(fromLine: line, toLine: min(model.lineCount - 1, line + 8))
        guard var j = tokens.firstIndex(where: { Int($0.start) == offset }) else { return nil }
        j += 1
        // `Get<T>(…)` — между именем и скобкой дженерик.
        if j < tokens.count, char(tokens[j]) == 0x3C,
           let close = matchForward(tokens, from: j, open: 0x3C, close: 0x3E) { j = close + 1 }
        guard j < tokens.count, char(tokens[j]) == 0x28 else { return nil }

        var parens = 0, angle = 0, commas = 0
        var sawArgument = false
        var k = j
        while k < tokens.count {
            switch char(tokens[k]) {
            case 0x28, 0x5B: parens += 1                                  // ( [
            case 0x5D: parens -= 1                                        // ]
            case 0x29:                                                    // )
                parens -= 1
                if parens == 0 { return sawArgument ? commas + 1 : 0 }
            case 0x3C: angle += 1                                         // <
            case 0x3E: angle = max(0, angle - 1)                          // >
            case 0x2C where parens == 1 && angle == 0: commas += 1        // ,
            default:
                if parens >= 1, tokens[k].kind != .comment, tokens[k].kind != .docComment { sawArgument = true }
            }
            k += 1
        }
        return nil
    }

    // MARK: - Иерархия вниз: наследники и переопределения

    /// Ответ на ⌥⌘B. На типе — кто его наследует или реализует; на методе,
    /// свойстве, поле — их переопределения в наследниках. Считается по
    /// `derivedByBase`: это обратная сторона того же `bases`, по которому
    /// ⌘B поднимается вверх, так что второго обхода проекта не нужно.
    func implementations(at offset: Int) -> Answer {
        if let answer = rustlynImplementations(at: offset) { return answer }

        guard index != nil else { return .none }
        let model = document.model
        guard let identifier = Occurrences.identifier(in: model, at: offset) else { return .none }
        let tokens = tokensAround(identifier.range.location)
        guard let k = tokens.firstIndex(where: { Int($0.start) == identifier.range.location }),
              isWord(tokens[k]) else { return .none }   // внутри строки или комментария
        let name = identifier.text
        let position = model.position(at: identifier.range.location)

        // Курсор на самом объявлении — что под ним, известно точно.
        if let item = document.outline.first(where: { $0.range.location == identifier.range.location }) {
            if item.kind == .type {
                guard let type = resolveType(name, context: fileInfo) else { return .none }
                return answer(derivedTypes(of: type).map(\.id), excluding: position)
            }
            guard SymbolIndex.isMember(item.kind), let owner = currentType(at: offset) else { return .none }
            return answer(overrides(named: name, of: owner), excluding: position)
        }

        // `receiver.Member` — владельца даёт та же цепочка, что и у ⌘B.
        if let dot = precedingDot(tokens, k) {
            guard let segments = chainBackward(tokens, endingAt: dot), !segments.isEmpty,
                  let value = evaluate(segments, at: identifier.range.location),
                  let owner = typeOf(value) else { return .none }
            if !members(named: name, of: owner).isEmpty {
                return answer(overrides(named: name, of: owner), excluding: position)
            }
            guard let nested = nestedType(named: name, in: owner) else { return .none }
            return answer(derivedTypes(of: ResolvedType(id: nested)).map(\.id), excluding: position)
        }

        // Голое имя: член текущего типа либо тип.
        if !looksLikeTypePosition(tokens, k), let current = currentType(at: offset),
           !members(named: name, of: current).isEmpty {
            return answer(overrides(named: name, of: current), excluding: position)
        }
        guard let type = resolveType(name, context: fileInfo) else { return .none }
        return answer(derivedTypes(of: type).map(\.id), excluding: position)
    }

    /// Все, кто наследует или реализует тип, — напрямую и через промежуточные
    /// звенья. Сам тип в ответ не входит. Обход в ширину с общим списком
    /// посещённых: у ромбовидных иерархий рекурсия разрасталась бы впустую.
    func derivedTypes(of type: ResolvedType, limit: Int = 500) -> [ResolvedType] {
        guard let index else { return [] }
        var result: [ResolvedType] = []
        var queue = partialParts(of: type.id)
        var visited = Set(queue)
        var head = 0
        while head < queue.count, result.count < limit {
            let current = queue[head]
            head += 1
            for candidate in index.derivedByBase[index[current].name] ?? [] {
                guard !visited.contains(candidate), inherits(candidate, from: current) else { continue }
                for part in partialParts(of: candidate) where visited.insert(part).inserted {
                    queue.append(part)
                }
                result.append(ResolvedType(id: candidate))
            }
        }
        return result
    }

    /// Ведёт ли `: Base` кандидата именно к этому типу, а не к одноимённому
    /// из чужого namespace: ключ в `derivedByBase` — короткое имя, и `Base`
    /// из двух разных namespace лежит там вместе.
    private func inherits(_ candidate: Int32, from ownerID: Int32) -> Bool {
        guard let index else { return false }
        let parts = Set(partialParts(of: ownerID))
        let context = index.fileInfo(candidate)
        for base in index[candidate].bases where SymbolIndex.baseKey(base) == index[ownerID].name {
            if let resolved = resolveType(base, context: context), parts.contains(resolved.id) { return true }
        }
        return false
    }

    /// Одноимённые члены в наследниках того типа, где член объявлен впервые.
    /// `PlayerSystem.OnAwake` — сам override, и его реализации общие с
    /// `BaseSystem.OnAwake`: искать среди наследников одного PlayerSystem
    /// значило бы не найти ничего.
    private func overrides(named name: String, of type: ResolvedType) -> [Int32] {
        var root = type
        var visited: Set<Int32> = []
        while visited.insert(root.id).inserted, visited.count < 16 {
            guard let above = baseTypes(of: root).first(where: { !ownMembers(named: name, of: $0.id).isEmpty })
            else { break }
            root = above
        }
        return derivedTypes(of: root).flatMap { ownMembers(named: name, of: $0.id) }
    }

    /// Ответ списком: сначала этот файл, дальше по алфавиту. Объявление под
    /// самим курсором отбрасывается — ⌥⌘B показывает другие реализации,
    /// а не ту, на которой стоишь. Сверяем позицию целиком, а не строку:
    /// в `class Armor : IDamageable` тип и его база стоят на одной строке.
    private func answer(_ ids: [Int32], excluding position: LSPPosition) -> Answer {
        guard let index else { return .none }
        var seen: Set<Int32> = []
        let unique = ids.filter { seen.insert($0).inserted }
            .filter { !(index.relPath($0) == fileInfo.path && Int(index[$0].line) == position.line
                        && Int(index[$0].column) == position.character) }
        guard !unique.isEmpty else { return .none }
        let sorted = unique.sorted {
            let a = index.relPath($0), b = index.relPath($1)
            if a != b {
                if a == fileInfo.path { return true }
                if b == fileInfo.path { return false }
                return a < b
            }
            return index[$0].line < index[$1].line
        }
        return Answer(declarations: sorted.prefix(500).map { declaration($0) }, isExact: sorted.count == 1)
    }

    // MARK: - Локальные переменные

    /// Ближайшее объявление выше курсора, но не выше начала текущего метода.
    func localDeclaration(of name: String, before offset: Int) -> NSRange? {
        let model = document.model
        let scopeStart = document.outline.last(where: {
            $0.range.location < offset && ($0.kind == .method || $0.kind == .property
                                           || $0.kind == .initializer || $0.kind == .function)
        })?.range.location ?? 0
        let declarations = Occurrences.find(name, in: model).filter {
            $0.location >= scopeStart && $0.location <= offset
                && Occurrences.looksLikeDeclaration($0, in: model)
        }
        return declarations.last
    }

    /// Тип локальной переменной или параметра по их объявлению.
    func localType(of declaration: NSRange, depth: Int) -> TypedText? {
        guard let spec = document.model.spec else { return nil }
        let units = document.model.units
        let tokens = tokensAround(declaration.location, after: 3)
        guard let n = tokens.firstIndex(where: { Int($0.start) == declaration.location }) else { return nil }

        if let text = OutlineBuilder.typeTextBefore(tokens: tokens, index: n, units: units, spec: spec),
           text != "var" {
            // `dynamic` и `object` — не внешний тип, а «тип неизвестен».
            return Self.opaqueTypes.contains(text) ? nil : TypedText(text: text, context: fileInfo)
        }
        // `foreach (var x in items)` — тип элемента коллекции.
        if n >= 3, text(tokens[n - 2]) == "(", text(tokens[n - 3]) == "foreach",
           n + 1 < tokens.count, text(tokens[n + 1]) == "in",
           let segments = chainForward(tokens, from: n + 2), !segments.isEmpty,
           case .instance(let typed)? = evaluate(segments, at: declaration.location, depth: depth + 1) {
            return elementTypeOf(typed)
        }
        // `var x = new Foo()`, `var x = Make()`, `var x = y as Foo`.
        guard n + 2 < tokens.count, char(tokens[n + 1]) == 0x3D, char(tokens[n + 2]) != 0x3D else { return nil }
        if let cast = trailingAs(tokens, from: n + 2) { return TypedText(text: cast, context: fileInfo) }
        guard let segments = chainForward(tokens, from: n + 2), !segments.isEmpty,
              let value = evaluate(segments, at: declaration.location, depth: depth + 1) else { return nil }
        switch value {
        case .instance(let typed):    return typed
        case .typeInstance(let type), .staticType(let type):
            guard let index else { return nil }
            return TypedText(text: index[type.id].name, context: fileInfo)
        case .external:
            return nil
        }
    }

    /// `… as Foo;` в конце инициализатора.
    private func trailingAs(_ tokens: [Token], from start: Int) -> String? {
        var j = start
        var depth = 0
        while j < tokens.count {
            let c = char(tokens[j])
            if c == 0x28 || c == 0x5B { depth += 1 }
            else if c == 0x29 || c == 0x5D { depth -= 1 }
            else if depth == 0 && (c == 0x3B || c == 0x2C) { return nil }
            else if depth == 0, text(tokens[j]) == "as", j + 1 < tokens.count, isWord(tokens[j + 1]) {
                return text(tokens[j + 1])
            }
            j += 1
        }
        return nil
    }

    // MARK: - Разбор цепочек по токенам

    /// Токены вокруг позиции: цепочка вызовов часто переносится на новые строки.
    private func tokensAround(_ offset: Int, before: Int = 6, after: Int = 1) -> [Token] {
        let model = document.model
        guard model.lineCount > 0 else { return [] }
        let line = model.line(containing: offset)
        return model.tokens(fromLine: max(0, line - before), toLine: min(model.lineCount - 1, line + after))
    }

    private func text(_ token: Token) -> String {
        let units = document.model.units
        return String(decoding: units[Int(token.start)..<Int(token.start + token.length)], as: UTF16.self)
    }

    private func char(_ token: Token) -> UInt16 {
        token.length == 1 ? document.model.units[Int(token.start)] : 0
    }

    private func isWord(_ token: Token) -> Bool {
        switch token.kind {
        case .plain, .type, .function, .constant: return true
        case .keyword:
            let word = text(token)
            return word == "this" || word == "base"
                || (document.model.spec?.contextualKeywords.contains(word) ?? false)
        default: return false
        }
    }

    /// Индекс точки перед именем: `a.b`, `a?.b`, `a!.b`.
    private func precedingDot(_ tokens: [Token], _ k: Int) -> Int? {
        guard k > 0, char(tokens[k - 1]) == 0x2E else { return nil }
        // `..` — диапазон, а не обращение к члену.
        if k > 1, char(tokens[k - 2]) == 0x2E { return nil }
        return k - 1
    }

    /// Не тип ли это в объявлении: `Foo x`, `new Foo`, `is Foo`, `<Foo>`.
    private func looksLikeTypePosition(_ tokens: [Token], _ k: Int) -> Bool {
        if k + 1 < tokens.count {
            let next = tokens[k + 1]
            if next.kind == .plain || next.kind == .type { return true }
        }
        if k > 0 {
            let previous = text(tokens[k - 1])
            if ["new", "is", "as", "typeof", "<", ":"].contains(previous) { return true }
        }
        return false
    }

    private func matchBackward(_ tokens: [Token], from j: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var i = j
        while i >= 0, j - i < 400 {
            let c = char(tokens[i])
            if c == close { depth += 1 }
            else if c == open { depth -= 1; if depth == 0 { return i } }
            i -= 1
        }
        return nil
    }

    private func matchForward(_ tokens: [Token], from j: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var i = j
        while i < tokens.count, i - j < 400 {
            let c = char(tokens[i])
            if c == open { depth += 1 }
            else if c == close { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    private func genericArgs(_ tokens: [Token], _ range: Range<Int>) -> [String] {
        Self.splitTopLevel(range.map { text(tokens[$0]) }.joined())
    }

    /// Цепочка, которая заканчивается точкой `dot`: `a.b(x).c<T>()[0]` → звенья слева направо.
    func chainBackward(_ tokens: [Token], endingAt dot: Int) -> [Segment]? {
        var segments: [Segment] = []
        var j = dot - 1
        if j >= 0, char(tokens[j]) == 0x3F || char(tokens[j]) == 0x21 { j -= 1 }   // ?. !.
        while j >= 0 {
            var segment = Segment(name: "")
            // Хвост звена: вызовы и индексаторы, в любом порядке — `a()[0]`.
            while j >= 0 {
                let c = char(tokens[j])
                if c == 0x29 {                                            // )
                    guard let open = matchBackward(tokens, from: j, open: 0x28, close: 0x29) else { return nil }
                    segment.isCall = true
                    j = open - 1
                } else if c == 0x5D {                                     // ]
                    guard let open = matchBackward(tokens, from: j, open: 0x5B, close: 0x5D) else { return nil }
                    segment.isIndexer = true
                    j = open - 1
                } else {
                    break
                }
            }
            if j >= 0, char(tokens[j]) == 0x3E {                          // >
                guard let open = matchBackward(tokens, from: j, open: 0x3C, close: 0x3E) else { return nil }
                segment.genericArgs = genericArgs(tokens, (open + 1)..<j)
                j = open - 1
            }
            guard j >= 0, isWord(tokens[j]) else { return nil }
            segment.name = text(tokens[j])
            j -= 1
            if j >= 0, tokens[j].kind == .keyword, text(tokens[j]) == "new" {
                segment.isNew = true
                segments.append(segment)
                break
            }
            segments.append(segment)
            guard j >= 0, char(tokens[j]) == 0x2E else { break }
            j -= 1
            if j >= 0, char(tokens[j]) == 0x3F || char(tokens[j]) == 0x21 { j -= 1 }
        }
        return segments.reversed()
    }

    /// Цепочка, которая начинается с `start`: инициализатор `var x = …`.
    func chainForward(_ tokens: [Token], from start: Int) -> [Segment]? {
        var segments: [Segment] = []
        var j = start
        while j < tokens.count, ["await", "ref"].contains(text(tokens[j])) { j += 1 }

        // Приведение `(Foo)expr` — тип известен сразу.
        if j + 2 < tokens.count, char(tokens[j]) == 0x28, isWord(tokens[j + 1]), char(tokens[j + 2]) == 0x29 {
            return [Segment(name: text(tokens[j + 1]), isNew: true)]
        }
        while j < tokens.count {
            var segment = Segment(name: "")
            if text(tokens[j]) == "new" {
                segment.isNew = true
                j += 1
                // `new Foo.Bar<T>(…)` — имя типа целиком.
                var typeText = ""
                while j < tokens.count {
                    let c = char(tokens[j])
                    if isWord(tokens[j]) || c == 0x2E { typeText += text(tokens[j]); j += 1; continue }
                    if c == 0x3C, let close = matchForward(tokens, from: j, open: 0x3C, close: 0x3E) {
                        typeText += (j...close).map { text(tokens[$0]) }.joined()
                        j = close + 1
                    }
                    break
                }
                guard !typeText.isEmpty else { return nil }
                segment.name = typeText
            } else {
                guard isWord(tokens[j]) else { break }
                segment.name = text(tokens[j])
                j += 1
                if j < tokens.count, char(tokens[j]) == 0x3C,
                   let close = matchForward(tokens, from: j, open: 0x3C, close: 0x3E),
                   close + 1 < tokens.count, char(tokens[close + 1]) == 0x28 {
                    segment.genericArgs = genericArgs(tokens, (j + 1)..<close)
                    j = close + 1
                }
            }
            while j < tokens.count {
                let c = char(tokens[j])
                if c == 0x28, let close = matchForward(tokens, from: j, open: 0x28, close: 0x29) {
                    segment.isCall = true
                    j = close + 1
                } else if c == 0x5B, let close = matchForward(tokens, from: j, open: 0x5B, close: 0x5D) {
                    segment.isIndexer = true
                    j = close + 1
                } else {
                    break
                }
            }
            segments.append(segment)
            if j < tokens.count, char(tokens[j]) == 0x3F || char(tokens[j]) == 0x21 { j += 1 }
            guard j < tokens.count, char(tokens[j]) == 0x2E else { break }
            j += 1
        }
        return segments
    }

    // MARK: - Текстовые операции над типами

    /// Разбивает по запятым верхнего уровня: `A, B<C, D>` → `["A", "B<C,D>"]`.
    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for ch in text {
            if ch == "<" || ch == "(" || ch == "[" { depth += 1 }
            if ch == ">" || ch == ")" || ch == "]" { depth -= 1 }
            if ch == "," && depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    /// Подставляет аргументы дженерика по целым словам: `List<T>` с `T → Foo` → `List<Foo>`.
    func substitute(_ text: String, _ map: [String: String]) -> String {
        guard !map.isEmpty else { return text }
        var result = ""
        var word = ""
        func flush() {
            if !word.isEmpty { result += map[word].flatMap { $0 == word ? nil : $0 } ?? word }
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" { word.append(ch) } else { flush(); result.append(ch) }
        }
        flush()
        return result
    }

    /// У метода `Get<T>()` параметры дженерика в индексе не записаны; угадываем:
    /// слово вида `T` или `TComponent`, которое не является известным типом.
    func substituteMethodGenerics(_ text: String, _ args: [String]) -> String {
        var map: [String: String] = [:]
        var next = 0
        var word = ""
        func consider() {
            defer { word = "" }
            guard next < args.count, map[word] == nil, Self.looksLikeGenericParameter(word),
                  index?.typesByName[word] == nil else { return }
            map[word] = args[next]
            next += 1
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" { word.append(ch) } else { consider() }
        }
        consider()
        return substitute(text, map)
    }

    static func looksLikeGenericParameter(_ word: String) -> Bool {
        guard let first = word.first, first == "T" else { return false }
        if word.count == 1 { return true }
        let second = word[word.index(after: word.startIndex)]
        return second.isUppercase
    }

    /// Тип элемента для `foreach`. Коллекции с дженериком и массивы — по записи
    /// типа; свои перечислимые типы (`Filter` в Morpeh) — как у компилятора,
    /// через `GetEnumerator().Current`.
    func elementTypeOf(_ typed: TypedText) -> TypedText? {
        let text = typed.text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("[]") || text.hasSuffix(">") {
            return TypedText(text: elementType(text), context: typed.context)
        }
        guard let index, let collection = resolveType(text, context: typed.context),
              let enumerator = members(named: "GetEnumerator", of: collection).first,
              case .instance(let enumeratorType)? = valueOf(member: enumerator, segment: Segment(name: "GetEnumerator", isCall: true)),
              let resolved = resolveType(enumeratorType.text, context: enumeratorType.context),
              let current = members(named: "Current", of: resolved).first,
              let currentText = index[current.id].typeText else { return nil }
        return TypedText(text: substitute(currentText, resolved.args), context: index.fileInfo(current.id))
    }

    /// Тип элемента: `Foo[]` → `Foo`, `List<Foo>` → `Foo`, `Dictionary<K, V>` → `V`.
    func elementType(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("?") { t.removeLast() }
        if t.hasSuffix("[]") { return String(t.dropLast(2)) }
        if let lt = t.firstIndex(of: "<"), t.hasSuffix(">") {
            let inner = String(t[t.index(after: lt)..<t.index(before: t.endIndex)])
            return Self.splitTopLevel(inner).last ?? t
        }
        return t
    }

    // MARK: - Кандидаты по имени

    /// Тип выяснить не удалось: все объявления с таким именем, ближние вперёд.
    /// «Точным» ответ считается, только если кандидат один.
    private func fallback(_ name: String, preferMembers: Bool, at offset: Int, allowJump: Bool = true) -> Answer {
        guard let index, let ids = index.byName[name], !ids.isEmpty else { return .none }
        let currentTypeName = currentType(at: offset).map { index[$0.id].name }
        func score(_ id: Int32) -> Int {
            let symbol = index[id]
            let info = index.fileInfo(id)
            var s = 0
            if info.path == fileInfo.path { s += 100 }
            if let currentTypeName, symbol.container == currentTypeName { s += 50 }
            if info.namespaces.contains(where: fileInfo.namespaces.contains) { s += 20 }
            if info.namespaces.contains(where: fileInfo.usings.contains) { s += 10 }
            if SymbolIndex.isMember(symbol.kind) == preferMembers { s += 5 }
            return s
        }
        let ranked = ids.map { ($0, score($0)) }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return index.relPath($0.0) < index.relPath($1.0)
        }
        let top = ranked.prefix(100).map { declaration($0.0) }
        return Answer(declarations: top, isExact: allowJump && top.count == 1)
    }

    // MARK: - Сборка ответа

    private func declaration(_ id: Int32) -> FoundDeclaration {
        let index = self.index!
        let symbol = index[id]
        return FoundDeclaration(target: index.target(id), name: symbol.name, kind: symbol.kind,
                                container: symbol.container, path: index.relPath(id))
    }

    private func declaration(item: OutlineItem) -> FoundDeclaration {
        let model = document.model
        let range = LSPRange(start: model.position(at: item.range.location),
                             end: model.position(at: item.range.location + item.range.length))
        return FoundDeclaration(target: NavTarget(url: document.url, range: range), name: item.name,
                                kind: item.kind, container: item.container, path: fileInfo.path)
    }

    private func declaration(local: NSRange, name: String) -> FoundDeclaration {
        let model = document.model
        let range = LSPRange(start: model.position(at: local.location),
                             end: model.position(at: local.location + local.length))
        return FoundDeclaration(target: NavTarget(url: document.url, range: range), name: name,
                                kind: .variable, container: nil, path: fileInfo.path)
    }

    // MARK: - Использования (⌘R)

    /// Вхождения слова в исходниках того же языка, без строк и комментариев.
    ///
    /// Сначала побайтовый поиск с границами слова по всем файлам на всех ядрах,
    /// потом лексер только для файлов с попаданиями. Для локальной переменной
    /// ищем лишь в текущем файле — за его пределами её не видно.
    func references(at offset: Int, root: URL, files: [String], limit: Int = 5000,
                    shouldStop: @escaping () -> Bool) -> [FoundReference] {
        let model = document.model
        guard let identifier = Occurrences.identifier(in: model, at: offset) else { return [] }
        let word = identifier.text

        let isLocal = localDeclaration(of: word, before: identifier.range.location) != nil
            && !document.outline.contains(where: { $0.name == word })
        if isLocal || document.relPath == nil {
            return Occurrences.find(word, in: model).map { range in
                FoundReference(target: NavTarget(url: document.url, range: lspRange(range, in: model)),
                               path: fileInfo.path, line: model.line(containing: range.location))
            }
        }

        let languageName = model.spec?.name
        var specs: [String: LanguageSpec?] = [:]
        var candidates: [(path: String, spec: LanguageSpec)] = []
        for path in files {
            let ext = (path as NSString).pathExtension.lowercased()
            if specs[ext] == nil { specs[ext] = .some(Languages.detect(filename: (path as NSString).lastPathComponent)) }
            if let spec = specs[ext] ?? nil, spec.name == languageName { candidates.append((path, spec)) }
        }

        let needle = Array(word.utf8)
        let lock = NSLock()
        var next = 0
        var found: [FoundReference] = []
        let workers = max(1, min(candidates.count, ProcessInfo.processInfo.activeProcessorCount))

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var local: [FoundReference] = []
            while !shouldStop() {
                lock.lock()
                let i = next
                next += 1
                let full = found.count >= limit
                lock.unlock()
                guard i < candidates.count, !full else { break }

                let (path, spec) = candidates[i]
                drainingAutoreleased {
                    let url = root.appendingPathComponent(path)
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                          data.count <= SymbolIndex.maxFileBytes,
                          Self.containsWord(data, needle),
                          let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
                    else { return }
                    let fileModel = SyntaxModel(text: text, spec: spec)
                    for range in Occurrences.find(word, in: fileModel) {
                        local.append(FoundReference(
                            target: NavTarget(url: url, range: lspRange(range, in: fileModel)),
                            path: path, line: fileModel.line(containing: range.location)))
                    }
                }
            }
            lock.lock()
            found.append(contentsOf: local)
            lock.unlock()
        }
        if shouldStop() { return [] }

        let current = fileInfo.path
        found.sort {
            if ($0.path == current) != ($1.path == current) { return $0.path == current }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.line < $1.line
        }
        if found.count > limit { found.removeSubrange(limit...) }
        return found
    }

    private func lspRange(_ range: NSRange, in model: SyntaxModel) -> LSPRange {
        LSPRange(start: model.position(at: range.location),
                 end: model.position(at: range.location + range.length))
    }

    /// Есть ли в файле слово целиком — до всякого лексера. Байты не-ASCII
    /// считаются частью идентификатора, как и в Occurrences.
    static func containsWord(_ data: Data, _ needle: [UInt8]) -> Bool {
        guard let first = needle.first, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count, m = needle.count
            var i = 0
            while i <= n - m {
                if bytes[i] == first {
                    var k = 1
                    while k < m, bytes[i + k] == needle[k] { k += 1 }
                    if k == m {
                        let beforeOK = i == 0 || !isIdentifierByte(bytes[i - 1])
                        let afterOK = i + m >= n || !isIdentifierByte(bytes[i + m])
                        if beforeOK && afterOK { return true }
                    }
                }
                i += 1
            }
            return false
        }
    }

    @inline(__always) private static func isIdentifierByte(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
            || b == 0x5F || b == 0x24 || b >= 0x80
    }
}
