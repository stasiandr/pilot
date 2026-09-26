import Foundation

/// Выражения C# для условий точек останова и правки переменных у Unity.
/// Агент Mono выражений не считает — это делает клиент (у Rider и VS
/// Code — целый вычислитель поверх Roslyn). Здесь — то, что пишут в
/// условиях на деле: имена, поля через точку, индексы, литералы,
/// сравнения, арифметика и логика. Вызовов методов и свойств нет: чтобы
/// их вызвать, пришлось бы гонять программу, стоящую на точке.
indirect enum DebugExpression: Equatable {
    case literal(DebugOperand)
    case name(String)
    case member(DebugExpression, String)
    case index(DebugExpression, DebugExpression)
    case unary(String, DebugExpression)
    case binary(String, DebugExpression, DebugExpression)

    // MARK: Разбор

    static func parse(_ text: String) throws -> DebugExpression {
        var parser = Parser(tokens: try tokenize(text))
        let expression = try parser.expression()
        guard parser.atEnd else { throw DebugError.message("лишнее после выражения: «\(parser.peek.text)»") }
        return expression
    }

    enum TokenKind: Equatable { case number, string, char, identifier, symbol, end }

    struct Token: Equatable {
        var kind: TokenKind
        var text: String
        /// Разобранный литерал — у чисел, строк и символов.
        var value: DebugOperand?
    }

    static func tokenize(_ text: String) throws -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var i = 0
        let symbols = ["&&", "||", "==", "!=", "<=", ">=", "<", ">", "+", "-", "*", "/", "%",
                       "!", "(", ")", "[", "]", "."]
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                var word = ""
                if c == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
                    j += 2
                    while j < chars.count, chars[j].isHexDigit || chars[j] == "_" { if chars[j] != "_" { word.append(chars[j]) }; j += 1 }
                    guard let value = UInt64(word, radix: 16) else { throw DebugError.message("не число: 0x\(word)") }
                    while j < chars.count, "uUlL".contains(chars[j]) { j += 1 }
                    tokens.append(Token(kind: .number, text: String(chars[i..<j]), value: .int(Int64(bitPattern: value))))
                    i = j
                    continue
                }
                var isReal = false
                while j < chars.count, chars[j].isNumber || chars[j] == "_" || chars[j] == "."
                        || ((chars[j] == "e" || chars[j] == "E") && !word.isEmpty)
                        || ((chars[j] == "+" || chars[j] == "-") && (word.last == "e" || word.last == "E")) {
                    // Точка — дробная часть, только если за ней цифра: `a.b` у числа не бывает.
                    if chars[j] == "." {
                        guard !isReal, j + 1 < chars.count, chars[j + 1].isNumber else { break }
                        isReal = true
                    }
                    if chars[j] == "e" || chars[j] == "E" { isReal = true }
                    if chars[j] != "_" { word.append(chars[j]) }
                    j += 1
                }
                var suffix = ""
                while j < chars.count, "fFdDmMuUlL".contains(chars[j]) { suffix.append(chars[j]); j += 1 }
                let real = isReal || suffix.lowercased().contains(where: { "fdm".contains($0) })
                let value: DebugOperand
                if real {
                    guard let d = Double(word) else { throw DebugError.message("не число: \(word)") }
                    value = .double(d)
                } else {
                    guard let n = Int64(word) ?? UInt64(word).map({ Int64(bitPattern: $0) }) else {
                        throw DebugError.message("не число: \(word)")
                    }
                    value = .int(n)
                }
                tokens.append(Token(kind: .number, text: String(chars[i..<j]), value: value))
                i = j
                continue
            }
            if c == "\"" || c == "'" || (c == "@" && i + 1 < chars.count && chars[i + 1] == "\"") {
                let verbatim = c == "@"
                let quote: Character = verbatim ? "\"" : c
                var j = i + (verbatim ? 2 : 1)
                var body = ""
                var closed = false
                while j < chars.count {
                    let ch = chars[j]
                    if ch == quote {
                        if verbatim, j + 1 < chars.count, chars[j + 1] == "\"" { body.append("\""); j += 2; continue }
                        closed = true
                        j += 1
                        break
                    }
                    if ch == "\\", !verbatim, j + 1 < chars.count {
                        let next = chars[j + 1]
                        switch next {
                        case "n": body.append("\n")
                        case "t": body.append("\t")
                        case "r": body.append("\r")
                        case "0": body.append("\0")
                        case "\\", "\"", "'": body.append(next)
                        case "u" where j + 5 < chars.count:
                            let hex = String(chars[(j + 2)...(j + 5)])
                            guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                                throw DebugError.message("неверный \\u\(hex)")
                            }
                            body.unicodeScalars.append(scalar)
                            j += 4
                        default: throw DebugError.message("неизвестная escape-последовательность \\\(next)")
                        }
                        j += 2
                        continue
                    }
                    body.append(ch)
                    j += 1
                }
                guard closed else { throw DebugError.message("не закрыта кавычка") }
                if quote == "'" {
                    let units = Array(body.utf16)
                    guard units.count == 1 else { throw DebugError.message("в символе должен быть один знак") }
                    tokens.append(Token(kind: .char, text: String(chars[i..<j]), value: .char(units[0])))
                } else {
                    tokens.append(Token(kind: .string, text: String(chars[i..<j]), value: .string(body)))
                }
                i = j
                continue
            }
            if c.isLetter || c == "_" || c == "@" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                var word = String(chars[i..<j])
                if word.hasPrefix("@") { word.removeFirst() }
                tokens.append(Token(kind: .identifier, text: word))
                i = j
                continue
            }
            guard let symbol = symbols.first(where: { s in
                i + s.count <= chars.count && String(chars[i..<(i + s.count)]) == s
            }) else {
                throw DebugError.message("непонятный знак «\(c)»")
            }
            tokens.append(Token(kind: .symbol, text: symbol))
            i += symbol.count
        }
        tokens.append(Token(kind: .end, text: ""))
        return tokens
    }

    private struct Parser {
        var tokens: [Token]
        var position = 0

        var peek: Token { tokens[position] }
        var atEnd: Bool { peek.kind == .end }

        mutating func take() -> Token {
            defer { if position < tokens.count - 1 { position += 1 } }
            return tokens[position]
        }

        mutating func accept(_ symbol: String) -> Bool {
            guard peek.kind == .symbol, peek.text == symbol else { return false }
            position += 1
            return true
        }

        mutating func expect(_ symbol: String) throws {
            guard accept(symbol) else {
                throw DebugError.message(atEnd ? "не хватает «\(symbol)»" : "ждал «\(symbol)», а тут «\(peek.text)»")
            }
        }

        /// Уровни приоритета — как в C#, от слабого к сильному.
        static let levels: [[String]] = [["||"], ["&&"], ["==", "!="], ["<", ">", "<=", ">="], ["+", "-"], ["*", "/", "%"]]

        mutating func expression() throws -> DebugExpression { try binary(0) }

        mutating func binary(_ level: Int) throws -> DebugExpression {
            guard level < Self.levels.count else { return try unary() }
            var left = try binary(level + 1)
            while peek.kind == .symbol, Self.levels[level].contains(peek.text) {
                let op = take().text
                left = .binary(op, left, try binary(level + 1))
            }
            return left
        }

        mutating func unary() throws -> DebugExpression {
            if accept("!") { return .unary("!", try unary()) }
            if accept("-") { return .unary("-", try unary()) }
            if accept("+") { return try unary() }
            return try postfix()
        }

        mutating func postfix() throws -> DebugExpression {
            var result = try primary()
            while true {
                if accept(".") {
                    let name = take()
                    guard name.kind == .identifier else { throw DebugError.message("после точки нужно имя") }
                    result = .member(result, name.text)
                } else if accept("[") {
                    let index = try expression()
                    try expect("]")
                    result = .index(result, index)
                } else {
                    return result
                }
            }
        }

        mutating func primary() throws -> DebugExpression {
            let token = take()
            switch token.kind {
            case .number, .string, .char:
                return .literal(token.value ?? .null)
            case .identifier:
                switch token.text {
                case "true": return .literal(.bool(true))
                case "false": return .literal(.bool(false))
                case "null": return .literal(.null)
                default: return .name(token.text)
                }
            case .symbol where token.text == "(":
                let inner = try expression()
                try expect(")")
                return inner
            case .end:
                throw DebugError.message("выражение оборвалось")
            default:
                throw DebugError.message("не ждал «\(token.text)»")
            }
        }
    }

    // MARK: Вычисление

    /// Имена и поля выражению даёт отладчик — по сети, поэтому асинхронно.
    func evaluate(in context: DebugExpressionContext) async throws -> DebugOperand {
        switch self {
        case .literal(let value):
            return value
        case .name(let name):
            return try await context.lookup(name)
        case .member(let base, let name):
            let value = try await base.evaluate(in: context)
            if case .string(let s) = value, name == "Length" { return .int(Int64(s.utf16.count)) }
            if value == .null { throw DebugError.message("null.\(name)") }
            return try await context.member(of: value, name)
        case .index(let base, let index):
            let value = try await base.evaluate(in: context)
            guard case .int(let i) = try await index.evaluate(in: context) else {
                throw DebugError.message("индекс должен быть целым")
            }
            if case .string(let s) = value {
                let units = Array(s.utf16)
                guard i >= 0, i < units.count else { throw DebugError.message("индекс \(i) вне строки") }
                return .char(units[Int(i)])
            }
            if value == .null { throw DebugError.message("null[\(i)]") }
            return try await context.element(of: value, Int(i))
        case .unary(let op, let operand):
            let value = try await operand.evaluate(in: context)
            switch (op, value) {
            case ("!", .bool(let b)): return .bool(!b)
            case ("-", .int(let n)): return .int(-n)
            case ("-", .double(let d)): return .double(-d)
            case ("-", .char(let c)): return .int(-Int64(c))
            default: throw DebugError.message("«\(op)» не применим к \(value.description)")
            }
        case .binary("&&", let a, let b):
            guard case .bool(let left) = try await a.evaluate(in: context) else { throw DebugError.message("«&&» — только для bool") }
            guard left else { return .bool(false) }
            guard case .bool(let right) = try await b.evaluate(in: context) else { throw DebugError.message("«&&» — только для bool") }
            return .bool(right)
        case .binary("||", let a, let b):
            guard case .bool(let left) = try await a.evaluate(in: context) else { throw DebugError.message("«||» — только для bool") }
            guard !left else { return .bool(true) }
            guard case .bool(let right) = try await b.evaluate(in: context) else { throw DebugError.message("«||» — только для bool") }
            return .bool(right)
        case .binary(let op, let a, let b):
            return try Self.apply(op, try await a.evaluate(in: context), try await b.evaluate(in: context))
        }
    }

    static func apply(_ op: String, _ a: DebugOperand, _ b: DebugOperand) throws -> DebugOperand {
        switch op {
        case "==": return .bool(try equal(a, b))
        case "!=": return .bool(!(try equal(a, b)))
        default: break
        }
        if op == "+", case .string(let s) = a { return .string(s + b.concatenated) }
        if op == "+", case .string(let s) = b { return .string(a.concatenated + s) }
        if let x = a.integer, let y = b.integer {
            switch op {
            case "<": return .bool(x < y)
            case ">": return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            case "+": return .int(x &+ y)
            case "-": return .int(x &- y)
            case "*": return .int(x &* y)
            case "/", "%":
                guard y != 0 else { throw DebugError.message("деление на ноль") }
                return .int(op == "/" ? x / y : x % y)
            default: break
            }
        }
        if let x = a.real, let y = b.real {
            switch op {
            case "<": return .bool(x < y)
            case ">": return .bool(x > y)
            case "<=": return .bool(x <= y)
            case ">=": return .bool(x >= y)
            case "+": return .double(x + y)
            case "-": return .double(x - y)
            case "*": return .double(x * y)
            case "/": return .double(x / y)
            case "%": return .double(x.truncatingRemainder(dividingBy: y))
            default: break
            }
        }
        throw DebugError.message("«\(op)» не применим к \(a.description) и \(b.description)")
    }

    private static func equal(_ a: DebugOperand, _ b: DebugOperand) throws -> Bool {
        if let x = a.integer, let y = b.integer { return x == y }
        if let x = a.real, let y = b.real { return x == y }
        switch (a, b) {
        case (.null, .null): return true
        case (.null, _), (_, .null): return false
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.object(let x, _), .object(let y, _)): return x == y
        default: throw DebugError.message("нельзя сравнить \(a.description) и \(b.description)")
        }
    }
}

/// Значение в выражении. Объект — ссылкой: его поля спрашивают у отладчика.
enum DebugOperand: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case char(UInt16)
    case string(String)
    /// `identity` — сравнение по ссылке, `handle` — по нему отладчик
    /// находит сам объект (или структуру) для полей и элементов.
    case object(identity: Int, handle: Int)

    var integer: Int64? {
        switch self {
        case .int(let n): return n
        case .char(let c): return Int64(c)
        default: return nil
        }
    }

    var real: Double? {
        switch self {
        case .double(let d): return d
        default: return integer.map(Double.init)
        }
    }

    /// Как значение пристёгивается к строке через `+`.
    var concatenated: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "True" : "False"
        case .int(let n): return String(n)
        case .double(let d): return String(d)
        case .char(let c): return Unicode.Scalar(c).map { String(Character($0)) } ?? ""
        case .string(let s): return s
        case .object: return "{объект}"
        }
    }

    var description: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "целое"
        case .double: return "дробное"
        case .char: return "char"
        case .string: return "string"
        case .object: return "объект"
        }
    }
}

protocol DebugExpressionContext {
    /// Локальная переменная, параметр, поле `this` или сам `this`.
    func lookup(_ name: String) async throws -> DebugOperand
    func member(of value: DebugOperand, _ name: String) async throws -> DebugOperand
    func element(of value: DebugOperand, _ index: Int) async throws -> DebugOperand
}
