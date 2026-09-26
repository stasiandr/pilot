import Foundation

/// Сетевая структура («датаграмма»): какие у неё поля и что уходит в провод.
/// Какой тип считать датаграммой и как называются её методы записи и
/// чтения, говорит расширение проекта (`DatagramRules`).
///
/// Протокол двух половин пары продублирован: одна и та же структура
/// объявлена в обоих проектах. Поле, переставленное или поменявшее тип на
/// одной стороне, ничего не ломает при сборке — ломает обмен. Поэтому
/// сверяется не текст, а то, что на проводе: поля по порядку и шаги
/// записи и чтения (`Write` и `Read` ниже — для примера).
///
/// `Read` на сторонах пишут по-разному: `Id = reader.Read<EntityId>()`
/// и `Id.Read(ref reader)` — одно и то же. Шаги сводятся к виду значения:
/// `WriteInt` и `ReadInt` — это `Int`, а обобщённый вызов и вложенная
/// структура — `value`.
///
/// Разбор свой, по тексту: сверять нужно и тот проект, что не открыт и не
/// скомпилирован. Без AppKit — проверяется тестами ядра.
struct DatagramShape: Equatable {
    var name: String
    /// Имя структуры в тексте — к нему крепятся замечания о типе в целом.
    var nameRange: NSRange
    var fields: [Field] = []
    var writes: [Step] = []
    var reads: [Step] = []
    var hasWrite = false
    var hasRead = false

    struct Field: Equatable {
        var name: String
        var type: String
        var range: NSRange
    }

    /// Шаг сериализации: вид значения и поле, которое он пишет или читает
    /// (пустое, если это не поле — счётчик цикла, выражение).
    struct Step: Equatable {
        var kind: String
        var field: String
        var range: NSRange

        var display: String { field.isEmpty ? kind : "\(kind) \(field)" }
    }
}

/// Расхождение датаграммы с её двойником, со стороны этого проекта.
struct DatagramIssue: Equatable {
    enum Kind: Equatable { case field, fieldType, order, rename, write, read }
    var kind: Kind
    var message: String
    /// Где в этом файле показать: поле, шаг или имя структуры.
    var range: NSRange
    /// Ломает провод: байты одной стороны другая прочтёт не так. Остальное —
    /// разные имена или типы полей при одинаковом проводе: не ошибка, но
    /// то, что стоит знать, прежде чем править одну сторону.
    var breaksWire: Bool
}

enum DatagramContract {

    // MARK: - Разбор

    /// Структура `name` из текста: поля и шаги методов записи и чтения,
    /// названных в правилах расширения.
    static func shape(named name: String, in text: String, rules: DatagramRules) -> DatagramShape? {
        let scanner = CSharpScanner(text)
        guard let (nameRange, body) = scanner.typeBody(named: name) else { return nil }
        var shape = DatagramShape(name: name, nameRange: nameRange)
        let members = scanner.members(in: body)
        // Сначала все поля: `Write` бывает объявлен выше некоторых из них.
        for case .statement(let range) in members {
            shape.fields += scanner.fields(in: range)
        }
        let fields = Set(shape.fields.map(\.name))
        for case .block(let header, let block) in members {
            guard let method = scanner.method(header) else { continue }
            if method.name == rules.writeMethod {
                shape.hasWrite = true
                shape.writes = scanner.steps(in: block, parameter: method.parameter, prefixes: rules.write, fields: fields)
            } else if method.name == rules.readMethod {
                shape.hasRead = true
                shape.reads = scanner.steps(in: block, parameter: method.parameter, prefixes: rules.read, fields: fields)
            }
        }
        return shape
    }

    // MARK: - Сверка

    /// Что в `own` не так, как в `other`. `label` — имя второй половины
    /// пары для текста (`server`, `client`).
    ///
    /// Главное — провод: виды шагов `Write` и `Read` по порядку. Имена полей
    /// на провод не попадают, поэтому `itemId` против `ItemId` при одинаковых
    /// шагах — переименование, а не поломка. Если `Write` или `Read` нет на
    /// одной из сторон, провод сверить не по чему, и тогда поля сверяются
    /// строго: по ним и видно, что разъехалось.
    static func compare(_ own: DatagramShape, with other: DatagramShape, label: String,
                        rules: DatagramRules) -> [DatagramIssue] {
        var issues: [DatagramIssue] = []
        // Сверяется `Write` с `Write` и `Read` с `Read`: их на сторонах
        // пишут одинаково, а `Write` одной с `Read` другой — нет (массив
        // пишут циклом, а читают одним `ReadArray`). Пустой метод — «эта
        // сторона так не делает»: сервер не пишет то, что шлёт клиент.
        let writes = !own.writes.isEmpty && !other.writes.isEmpty
            ? stepIssue(own.writes, other.writes, method: rules.writeMethod, write: true, label: label, own: own) : nil
        let reads = !own.reads.isEmpty && !other.reads.isEmpty
            ? stepIssue(own.reads, other.reads, method: rules.readMethod, write: false, label: label, own: own) : nil
        let wireChecked = (!own.writes.isEmpty && !other.writes.isEmpty) || (!own.reads.isEmpty && !other.reads.isEmpty)
        // Поля ломают провод, только когда его не с чем сверить.
        let strict = !wireChecked

        let theirs = Dictionary(other.fields.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let ourNames = Set(own.fields.map(\.name))
        let onlyHere = own.fields.filter { theirs[$0.name] == nil }
        let onlyThere = other.fields.filter { !ourNames.contains($0.name) }

        // Одинаковое число лишних с обеих сторон и те же типы по порядку —
        // это переименования: `itemId` → `ItemId`.
        let renamed = onlyHere.count == onlyThere.count && !onlyHere.isEmpty
            && zip(onlyHere, onlyThere).allSatisfy { normalizedType($0.type) == normalizedType($1.type) }
        if renamed {
            for (field, twin) in zip(onlyHere, onlyThere) {
                issues.append(DatagramIssue(kind: .rename, message: "В \(label) это поле называется \(twin.name)",
                                            range: field.range, breaksWire: false))
            }
        } else {
            for field in onlyHere {
                issues.append(DatagramIssue(kind: .field, message: "В \(label) нет поля \(field.name)",
                                            range: field.range, breaksWire: strict))
            }
            if !onlyThere.isEmpty {
                issues.append(DatagramIssue(kind: .field,
                                            message: "Только в \(label): " + onlyThere.map(\.name).joined(separator: ", "),
                                            range: own.nameRange, breaksWire: strict))
            }
        }
        for field in own.fields {
            guard let twin = theirs[field.name], normalizedType(field.type) != normalizedType(twin.type) else { continue }
            issues.append(DatagramIssue(kind: .fieldType,
                                        message: "В \(label) \(field.name) — \(twin.type), здесь \(field.type)",
                                        range: field.range, breaksWire: strict))
        }

        // Порядок — среди общих полей: лишнее уже названо выше.
        let common = ourNames.intersection(other.fields.map(\.name))
        let ownOrder = own.fields.map(\.name).filter(common.contains)
        let otherOrder = other.fields.map(\.name).filter(common.contains)
        if ownOrder != otherOrder,
           let index = ownOrder.indices.first(where: { $0 < otherOrder.count && ownOrder[$0] != otherOrder[$0] }),
           let field = own.fields.first(where: { $0.name == ownOrder[index] }) {
            issues.append(DatagramIssue(kind: .order,
                                        message: "В \(label) поля в другом порядке: " + otherOrder.joined(separator: ", "),
                                        range: field.range, breaksWire: strict))
        }

        if let writes { issues.append(writes) }
        if let reads { issues.append(reads) }
        return issues
    }

    /// Шаги сверяются по видам значений: имя поля — подпись, а не провод.
    private static func stepIssue(_ ours: [DatagramShape.Step], _ theirs: [DatagramShape.Step], method: String,
                                  write: Bool, label: String, own: DatagramShape) -> DatagramIssue? {
        let key = { (step: DatagramShape.Step) in step.kind.lowercased() }
        guard ours.map(key) != theirs.map(key) else { return nil }
        let index = ours.indices.first { $0 < theirs.count && key(ours[$0]) != key(theirs[$0]) }
            ?? min(ours.count, theirs.count)
        let range = index < ours.count ? ours[index].range : (ours.last?.range ?? own.nameRange)
        let message: String
        if index < ours.count, index < theirs.count {
            message = "\(method) расходится с \(label), шаг \(index + 1): здесь \(ours[index].display), там \(theirs[index].display)"
        } else if index < ours.count {
            message = "\(method): в \(label) нет шагов с \(index + 1) — " + ours[index...].map { $0.display }.joined(separator: ", ")
        } else {
            message = "\(method): в \(label) дальше ещё " + theirs[index...].map { $0.display }.joined(separator: ", ")
        }
        return DatagramIssue(kind: write ? .write : .read, message: message, range: range, breaksWire: true)
    }

    /// Тип без пространств имён и пробелов: `Server.Models.EntityIdModel` и
    /// `EntityIdModel` — один тип, объявленный в двух проектах.
    static func normalizedType(_ type: String) -> String {
        var result = ""
        var word = ""
        func flush() {
            result += word
            word = ""
        }
        for ch in type.replacingOccurrences(of: "global::", with: "") {
            if ch.isLetter || ch.isNumber || ch == "_" {
                word.append(ch)
            } else if ch == "." {
                word = ""
            } else if ch == " " {
                continue
            } else {
                flush()
                result.append(ch)
            }
        }
        flush()
        return aliases[result] ?? result
    }

    private static let aliases: [String: String] = [
        "Int32": "int", "Int64": "long", "Int16": "short", "UInt32": "uint", "UInt64": "ulong",
        "UInt16": "ushort", "Byte": "byte", "SByte": "sbyte", "Single": "float", "Double": "double",
        "Boolean": "bool", "String": "string", "Char": "char",
    ]

    // MARK: - Кто шлёт и кто принимает

    enum Usage: Equatable { case sends, receives }

    /// Что делает строка с датаграммой: создаёт её для отправки или ловит.
    /// nil — просто упоминает. Кроме общих примет (`Handler<T>`, `ref T`,
    /// `new T`) — вызовы и типы из правил расширения.
    static func usage(of line: String, type name: String, rules: DatagramRules) -> Usage? {
        let text = line.replacingOccurrences(of: " ", with: "")
        if text.contains("<\(name)>") {
            let receivers = ["Filter<", "Handler", "Receive", "Subscribe", "Listen", "Register"]
                + rules.receive.map { $0 + "<" }
            if receivers.contains(where: { text.contains($0) }) { return .receives }
        }
        if line.range(of: "ref \(name) ") != nil || line.range(of: "in \(name) ") != nil { return .receives }
        if text.contains("new\(name)") || line.range(of: "new \(name)") != nil { return .sends }
        if rules.send.contains(where: { text.contains("\($0)<\(name)>") }) { return .sends }
        return nil
    }
}

// MARK: - Сканер C#

/// Ровно столько C#, сколько нужно датаграмме: где тело типа, какие в нём
/// поля и методы, какие вызовы в методе. Строки и комментарии заменяются
/// пробелами — позиции остаются теми же, что в исходном тексте.
private struct CSharpScanner {
    let units: [UInt16]
    let text: String

    init(_ text: String) {
        self.text = text
        units = Self.blanked(Array(text.utf16))
    }

    // MARK: Строки и комментарии

    private static func blanked(_ source: [UInt16]) -> [UInt16] {
        var out = source
        let n = source.count
        let quote: UInt16 = 0x22, apostrophe: UInt16 = 0x27, slash: UInt16 = 0x2F, star: UInt16 = 0x2A
        let backslash: UInt16 = 0x5C, newline: UInt16 = 0x0A, at: UInt16 = 0x40, space: UInt16 = 0x20
        func blank(_ i: Int) { if out[i] != newline { out[i] = space } }
        var i = 0
        while i < n {
            let c = source[i]
            if c == slash, i + 1 < n, source[i + 1] == slash {
                while i < n, source[i] != newline { blank(i); i += 1 }
            } else if c == slash, i + 1 < n, source[i + 1] == star {
                blank(i); blank(i + 1); i += 2
                while i < n, !(source[i] == star && i + 1 < n && source[i + 1] == slash) { blank(i); i += 1 }
                if i < n { blank(i); blank(i + 1); i += 2 }
            } else if c == quote {
                let verbatim = i > 0 && (source[i - 1] == at || (i > 1 && source[i - 2] == at))
                // Кавычки остаются: по ним видно, что здесь было значение.
                i += 1
                while i < n {
                    if source[i] == quote {
                        if verbatim, i + 1 < n, source[i + 1] == quote { blank(i); blank(i + 1); i += 2; continue }
                        break
                    }
                    if !verbatim, source[i] == backslash, i + 1 < n { blank(i); blank(i + 1); i += 2; continue }
                    if source[i] == newline, !verbatim { break }
                    blank(i); i += 1
                }
                i += 1
            } else if c == apostrophe {
                i += 1
                while i < n, source[i] != apostrophe, source[i] != newline {
                    if source[i] == backslash, i + 1 < n { blank(i); blank(i + 1); i += 2; continue }
                    blank(i); i += 1
                }
                i += 1
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: Лексемы

    struct Token {
        var text: String
        var range: NSRange
        var isIdentifier: Bool
    }

    static func isIdentifierUnit(_ u: UInt16) -> Bool {
        (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F || u >= 0x80
    }

    func tokens(in range: NSRange) -> [Token] {
        var result: [Token] = []
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            let u = units[i]
            if u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D {
                i += 1
            } else if Self.isIdentifierUnit(u) {
                let start = i
                while i < end, Self.isIdentifierUnit(units[i]) { i += 1 }
                result.append(Token(text: String(utf16CodeUnits: Array(units[start..<i]), count: i - start),
                                    range: NSRange(location: start, length: i - start), isIdentifier: true))
            } else {
                // `=>`, `==` — одной лексемой: иначе `=` в них принимался бы за присваивание.
                var length = 1
                if i + 1 < end, (u == 0x3D || u == 0x21 || u == 0x3C || u == 0x3E),
                   units[i + 1] == 0x3D || (u == 0x3D && units[i + 1] == 0x3E) { length = 2 }
                result.append(Token(text: String(utf16CodeUnits: Array(units[i..<i + length]), count: length),
                                    range: NSRange(location: i, length: length), isIdentifier: false))
                i += length
            }
        }
        return result
    }

    // MARK: Тип

    /// Имя типа и его тело между фигурными скобками (без них).
    func typeBody(named name: String) -> (NSRange, NSRange)? {
        let all = tokens(in: NSRange(location: 0, length: units.count))
        for (index, token) in all.enumerated()
        where token.isIdentifier && ["struct", "class", "record"].contains(token.text) {
            var next = index + 1
            if next < all.count, all[next].text == "struct" || all[next].text == "class" { next += 1 }
            guard next < all.count, all[next].text == name else { continue }
            guard let open = all[(next + 1)...].first(where: { $0.text == "{" || $0.text == ";" }),
                  open.text == "{", let close = matching(from: open.range.location) else { continue }
            let start = open.range.location + 1
            return (all[next].range, NSRange(location: start, length: close - start))
        }
        return nil
    }

    /// Закрывающая скобка к открывающей в `start`.
    func matching(from start: Int) -> Int? {
        let open = units[start]
        let close: UInt16 = open == 0x7B ? 0x7D : open == 0x28 ? 0x29 : 0x5D
        var depth = 0
        var i = start
        while i < units.count {
            if units[i] == open { depth += 1 }
            else if units[i] == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    enum Member {
        /// Объявление, которое кончается `;`: поле, константа, событие.
        case statement(NSRange)
        /// Объявление с телом: метод, свойство, вложенный тип.
        case block(header: NSRange, body: NSRange)
    }

    func members(in body: NSRange) -> [Member] {
        var result: [Member] = []
        var start = body.location
        var i = body.location
        let end = NSMaxRange(body)
        var parens = 0
        while i < end {
            switch units[i] {
            case 0x28, 0x5B: parens += 1
            case 0x29, 0x5D: parens -= 1
            case 0x3B where parens == 0:                                   // ;
                result.append(.statement(NSRange(location: start, length: i - start)))
                start = i + 1
            case 0x7B where parens == 0:                                   // {
                guard let close = matching(from: i) else { return result }
                result.append(.block(header: NSRange(location: start, length: i - start),
                                     body: NSRange(location: i + 1, length: close - i - 1)))
                i = close
                // `{ get; } = value;` у свойства — хвост до `;` тоже его.
                var j = close + 1
                while j < end, units[j] == 0x20 || units[j] == 0x09 || units[j] == 0x0A || units[j] == 0x0D { j += 1 }
                if j < end, units[j] == 0x3D, let semicolon = (j..<end).first(where: { units[$0] == 0x3B }) {
                    i = semicolon
                }
                start = i + 1
            default:
                break
            }
            i += 1
        }
        return result
    }

    // MARK: Поля

    private static let modifiers: Set<String> = [
        "public", "private", "protected", "internal", "readonly", "volatile", "new", "unsafe",
        "required", "fixed",
    ]

    func fields(in statement: NSRange) -> [DatagramShape.Field] {
        var tokens = tokens(in: statement)
        // Атрибуты впереди: `[SerializeField]`, `[JsonProperty("x")]`.
        while tokens.first?.text == "[" {
            var depth = 0
            var cut = 0
            for (index, token) in tokens.enumerated() {
                if token.text == "[" { depth += 1 }
                if token.text == "]" { depth -= 1; if depth == 0 { cut = index + 1; break } }
            }
            guard cut > 0 else { return [] }
            tokens.removeFirst(cut)
        }
        // Инициализатор — не часть объявления.
        if let assign = tokens.firstIndex(where: { $0.text == "=" }) { tokens.removeSubrange(assign...) }
        guard !tokens.isEmpty, !tokens.contains(where: { ["(", "=>", "static", "const", "event", "using", "delegate"].contains($0.text) })
        else { return [] }
        while let first = tokens.first, Self.modifiers.contains(first.text) { tokens.removeFirst() }

        // `int A, B;` — несколько имён одного типа.
        var groups: [[Token]] = [[]]
        var depth = 0
        for token in tokens {
            if token.text == "<" || token.text == "[" || token.text == "(" { depth += 1 }
            if token.text == ">" || token.text == "]" || token.text == ")" { depth -= 1 }
            if token.text == ",", depth == 0 { groups.append([]); continue }
            groups[groups.count - 1].append(token)
        }
        guard let first = groups.first, first.count >= 2, let nameToken = first.last, nameToken.isIdentifier
        else { return [] }
        let typeTokens = first.dropLast()
        let typeStart = typeTokens.first!.range.location
        let typeEnd = NSMaxRange(typeTokens.last!.range)
        let type = (text as NSString).substring(with: NSRange(location: typeStart, length: typeEnd - typeStart))
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        var result = [DatagramShape.Field(name: nameToken.text, type: type, range: nameToken.range)]
        for group in groups.dropFirst() {
            if let token = group.first, token.isIdentifier {
                result.append(DatagramShape.Field(name: token.text, type: type, range: token.range))
            }
        }
        return result
    }

    // MARK: Методы

    /// Имя метода и имя его первого параметра: `void Write(PacketWriter writer)`.
    func method(_ header: NSRange) -> (name: String, parameter: String)? {
        let tokens = tokens(in: header)
        guard let open = tokens.firstIndex(where: { $0.text == "(" }), open > 0, tokens[open - 1].isIdentifier,
              let close = tokens.lastIndex(where: { $0.text == ")" }), close > open else { return nil }
        let inside = tokens[(open + 1)..<close]
        let firstParameter = inside.prefix { $0.text != "," }
        guard let parameter = firstParameter.last(where: \.isIdentifier) else { return nil }
        return (tokens[open - 1].text, parameter.text)
    }

    /// Шаги сериализации в теле метода по порядку.
    /// Шаги записи или чтения. `prefixes` — имена вызовов из правил: первое —
    /// сам метод (`Write`), остальные — другие имена того же (`Serialize`).
    func steps(in body: NSRange, parameter: String, prefixes: [String], fields: Set<String>) -> [DatagramShape.Step] {
        let prefix = prefixes.first ?? "" 
        let tokens = tokens(in: body)
        var result: [DatagramShape.Step] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            // `writer.WriteInt(…)`, `reader.Read<T>()`.
            if token.text == parameter, index + 2 < tokens.count, tokens[index + 1].text == ".",
               tokens[index + 2].isIdentifier {
                let method = tokens[index + 2]
                let open = callOpen(tokens, after: index + 2)
                let arguments = open.flatMap { callArguments(tokens, open: $0) } ?? []
                let field = assignedField(tokens, before: index, fields: fields)
                    ?? arguments.first(where: { $0.isIdentifier && fields.contains($0.text) })?.text ?? ""
                result.append(DatagramShape.Step(kind: kind(method.text, prefix: prefix), field: field,
                                                 range: method.range))
                index = (open.flatMap { tokens.indices.contains($0) ? $0 : nil } ?? index) + 1
                continue
            }
            // `Id.Write(writer)`, `Id.Read(ref reader)` — вложенная структура.
            if token.isIdentifier, token.text != parameter, index + 3 < tokens.count, tokens[index + 1].text == ".",
               tokens[index + 2].isIdentifier, tokens[index + 3].text == "(",
               prefixes.contains(where: { tokens[index + 2].text.hasPrefix($0) }),
               (index == 0 || tokens[index - 1].text != "."),
               let arguments = callArguments(tokens, open: index + 3),
               arguments.contains(where: { $0.text == parameter }) {
                result.append(DatagramShape.Step(kind: "value", field: fields.contains(token.text) ? token.text : "",
                                                 range: tokens[index + 2].range))
                index += 4
                continue
            }
            index += 1
        }
        return result
    }

    /// `(` вызова после имени метода, пропуская `<T>`.
    private func callOpen(_ tokens: [Token], after index: Int) -> Int? {
        var i = index + 1
        if i < tokens.count, tokens[i].text == "<" {
            var depth = 0
            while i < tokens.count {
                if tokens[i].text == "<" { depth += 1 }
                if tokens[i].text == ">" { depth -= 1; if depth == 0 { break } }
                i += 1
            }
            i += 1
        }
        return i < tokens.count && tokens[i].text == "(" ? i : nil
    }

    private func callArguments(_ tokens: [Token], open: Int) -> [Token]? {
        var depth = 0
        var i = open
        while i < tokens.count {
            if tokens[i].text == "(" { depth += 1 }
            if tokens[i].text == ")" {
                depth -= 1
                if depth == 0 { return Array(tokens[(open + 1)..<i]) }
            }
            i += 1
        }
        return nil
    }

    /// Поле слева от `=` в том же операторе: `Status = (Kind)reader.ReadInt();`.
    private func assignedField(_ tokens: [Token], before index: Int, fields: Set<String>) -> String? {
        var i = index - 1
        var assignment: Int?
        while i >= 0, ![";", "{", "}"].contains(tokens[i].text) {
            if tokens[i].text == "=" { assignment = i }
            i -= 1
        }
        guard let assignment else { return nil }
        let left = tokens[(i + 1)..<assignment]
        return left.first(where: { $0.isIdentifier && $0.text != "this" && fields.contains($0.text) })?.text
    }

    private func kind(_ method: String, prefix: String) -> String {
        if method == prefix { return "value" }
        guard method.hasPrefix(prefix) else { return method }
        let rest = String(method.dropFirst(prefix.count))
        return ["Int32": "Int", "Single": "Float", "Boolean": "Bool", "Int64": "Long", "Int16": "Short"][rest] ?? rest
    }
}
