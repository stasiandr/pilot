import Foundation

/// Разбор места, где упомянуто поле: пишут в него или читают, и из чего
/// складывается записанное. Только текст — что за имена в правой части,
/// решает компилятор (Rustlyn) по позициям отсюда.
///
/// Ищем то, как в проектах на Morpeh на самом деле меняют значения:
/// `c.Health = x`, `c.Health += x`, `c.Health++`, `new Health { Value = x }`
/// в `stash.Set(entity, …)`, `datagram.Amount = x` перед `Send`.
enum ValueFlow {

    enum Access: Equatable {
        case read
        /// `rhs` — правая часть, если она есть (`=`, `+=`); у `++` её нет.
        /// `compound` — старое значение тоже входит в новое.
        case write(rhs: NSRange?, compound: Bool)
    }

    /// Что делают с именем в `name` (диапазон UTF-16 в `text`). Запись во
    /// вложенное поле (`c.Pos.x = 1` для `Pos`) — тоже запись: структура
    /// меняется, а прежнее значение остальных её полей остаётся.
    static func access(in text: [UInt16], name: NSRange) -> Access {
        let direct = directAccess(in: text, name: name)
        guard direct == .read else { return direct }
        // `Pos.x.y = …` — идём по цепочке до последнего звена.
        var i = skipSpace(text, from: NSMaxRange(name))
        var last: NSRange?
        while i < text.count, text[i] == dot {
            let s = skipSpace(text, from: i + 1)
            var e = s
            while e < text.count, isIdentPart(text[e]) { e += 1 }
            guard e > s, isIdentStart(text[s]) else { break }
            last = NSRange(location: s, length: e - s)
            i = skipSpace(text, from: e)
        }
        guard let last, i >= text.count || text[i] != openParen else { return .read }
        if case .write(let rhs, _) = directAccess(in: text, name: last) {
            return .write(rhs: rhs, compound: true)
        }
        return .read
    }

    private static func directAccess(in text: [UInt16], name: NSRange) -> Access {
        let end = NSMaxRange(name)
        var i = skipSpace(text, from: end)
        if i < text.count {
            let c = text[i]
            let next = i + 1 < text.count ? text[i + 1] : 0
            // `=`, но не `==` и не `=>`.
            if c == eq, next != eq, next != gt {
                return .write(rhs: rhs(in: text, from: i + 1), compound: false)
            }
            // `++`, `--` после имени.
            if (c == plus && next == plus) || (c == minus && next == minus) {
                return .write(rhs: nil, compound: true)
            }
            // Составное: `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `??=`, `<<=`, `>>=`.
            var j = i
            while j < text.count, compoundChars.contains(text[j]) { j += 1 }
            if j > i, j < text.count, text[j] == eq, j + 1 >= text.count || text[j + 1] != eq {
                let op = Array(text[i..<j])
                let known: [[UInt16]] = [[plus], [minus], [star], [slash], [percent], [amp], [bar], [caret],
                                         [question, question], [lt, lt], [gt, gt]]
                if known.contains(op) {
                    return .write(rhs: rhs(in: text, from: j + 1), compound: true)
                }
            }
        }
        // `++`, `--` перед именем — с учётом `x.` перед ним: `++c.Count`.
        var k = name.location
        while k > 0 {
            let c = text[k - 1]
            if isIdentPart(c) || c == dot { k -= 1 } else { break }
        }
        i = skipSpaceBackward(text, from: k)
        if i >= 2, (text[i - 1] == plus && text[i - 2] == plus) || (text[i - 1] == minus && text[i - 2] == minus) {
            return .write(rhs: nil, compound: true)
        }
        // `out x.Field` — метод его заполнит.
        if i >= 3, word(text, endingAt: i) == "out" {
            return .write(rhs: nil, compound: false)
        }
        return .read
    }

    /// Правая часть присваивания от `start` до конца выражения: `;` или
    /// запятая и скобка инициализатора `{ A = 1, B = 2 }` на своём уровне.
    static func rhs(in text: [UInt16], from start: Int) -> NSRange {
        var depth = 0
        var i = start
        while i < text.count {
            let c = text[i]
            if c == quote || c == apostrophe {
                i = skipLiteral(text, from: i)
                continue
            }
            if c == slash, i + 1 < text.count, text[i + 1] == slash {
                while i < text.count, text[i] != newline { i += 1 }
                continue
            }
            if c == openParen || c == openBracket || c == openBrace { depth += 1 }
            if c == closeParen || c == closeBracket || c == closeBrace {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0, c == semicolon || c == comma { break }
            i += 1
        }
        var from = skipSpace(text, from: start)
        var to = i
        while to > from, isSpace(text[to - 1]) { to -= 1 }
        from = min(from, to)
        return NSRange(location: from, length: to - from)
    }

    /// Имя в правой части, от которого зависит значение. У цепочки
    /// `stats.Damage` — последнее звено (`Damage`): им и спрашиваем
    /// компилятор. `call` — это вызов метода.
    struct Source: Equatable {
        var range: NSRange
        var chain: String
        var call: Bool
    }

    static func sources(in text: [UInt16], range: NSRange) -> [Source] {
        var result: [Source] = []
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            let c = text[i]
            if c == quote || c == apostrophe {
                i = skipLiteral(text, from: i)
                continue
            }
            // Интерполированная строка `$"…{x}…"` — выражения в фигурных
            // скобках тоже источники, но их разбор здесь не нужен: хватит
            // пропустить строку целиком.
            if c == dollar, i + 1 < end, text[i + 1] == quote {
                i = skipLiteral(text, from: i + 1)
                continue
            }
            guard isIdentStart(c), i == 0 || !isIdentPart(text[i - 1]) else { i += 1; continue }
            // Цепочка `a.b.c` (с `?.` и пробелами вокруг точек).
            var parts: [NSRange] = []
            var j = i
            while j < end, isIdentStart(text[j]) {
                let s = j
                while j < end, isIdentPart(text[j]) { j += 1 }
                parts.append(NSRange(location: s, length: j - s))
                var k = skipSpace(text, from: j)
                if k < end, text[k] == question { k += 1 }
                guard k < end, text[k] == dot else { break }
                k = skipSpace(text, from: k + 1)
                guard k < end, isIdentStart(text[k]) else { break }
                j = k
            }
            let words = parts.map { string(text, $0) }
            let after = skipSpace(text, from: j)
            let call = after < end && (text[after] == openParen || text[after] == lt && looksGeneric(text, from: after, end: end))
            if let first = words.first, !keywords.contains(first) {
                result.append(Source(range: parts.last!, chain: words.joined(separator: "."), call: call))
            }
            i = j
        }
        return result
    }

    /// `var x = …` / `T x = …` внутри метода до позиции `before`: правая
    /// часть объявления локальной переменной, если её так объявили.
    static func localInitializer(in text: [UInt16], name: String, within method: NSRange, before: Int) -> NSRange? {
        let target = Array(name.utf16)
        var best: NSRange?
        var i = method.location
        let limit = min(before, NSMaxRange(method))
        while i + target.count <= limit {
            if text[i] == target[0], Array(text[i..<(i + target.count)]) == target,
               i == 0 || !isIdentPart(text[i - 1]),
               i + target.count >= text.count || !isIdentPart(text[i + target.count]) {
                // Перед именем — тип или `var`, а не точка: `x.name = …` — не объявление.
                let back = skipSpaceBackward(text, from: i)
                if back > 0, isIdentPart(text[back - 1]) || text[back - 1] == gt || text[back - 1] == closeBracket {
                    if case .write(let rhs?, false) = access(in: text, name: NSRange(location: i, length: target.count)) {
                        best = rhs
                    }
                }
            }
            i += 1
        }
        return best
    }

    // MARK: - Условия и вызовы

    /// `foreach (… in X)`, внутри тела которого `offset`: диапазон X.
    /// Ближайший к месту — внутренний цикл.
    static func enclosingForeach(in text: [UInt16], range: NSRange, containing offset: Int) -> NSRange? {
        let keyword = Array("foreach".utf16)
        var best: NSRange?
        var i = range.location
        let end = min(NSMaxRange(range), offset)
        while i + keyword.count < end {
            guard text[i] == keyword[0], Array(text[i..<(i + keyword.count)]) == keyword,
                  i == 0 || !isIdentPart(text[i - 1]), !isIdentPart(text[i + keyword.count]) else { i += 1; continue }
            var j = skipSpace(text, from: i + keyword.count)
            guard j < text.count, text[j] == openParen else { i += 1; continue }
            let close = matching(text, open: j)
            guard close > j else { i += 1; continue }
            // `in` на верхнем уровне скобок.
            var k = j + 1
            var source: NSRange?
            while k < close {
                if text[k] == 0x69, k + 1 < close, text[k + 1] == 0x6E,
                   isSpace(text[k - 1]), k + 2 < close, isSpace(text[k + 2]) {
                    let s = skipSpace(text, from: k + 2)
                    var e = close
                    while e > s, isSpace(text[e - 1]) { e -= 1 }
                    source = NSRange(location: s, length: e - s)
                    break
                }
                k += 1
            }
            // Тело: блок в фигурных скобках или одна инструкция.
            j = skipSpace(text, from: close + 1)
            let bodyEnd: Int
            if j < text.count, text[j] == openBrace {
                bodyEnd = matching(text, open: j)
            } else {
                var e = j
                while e < text.count, text[e] != semicolon { e += 1 }
                bodyEnd = e
            }
            if let source, offset > close, offset <= bodyEnd { best = source }
            i = close
        }
        return best
    }

    /// Компоненты фильтра Morpeh: `Filter.With<A>().With<B>().Without<C>()`.
    static func filterComponents(in text: [UInt16], range: NSRange) -> (with: [String], without: [String]) {
        var with: [String] = [], without: [String] = []
        let expression = string(text, range) as NSString
        let pattern = try! NSRegularExpression(pattern: #"\.(With|Without)\s*<\s*([A-Za-z_][\w.]*)\s*>"#)
        for match in pattern.matches(in: expression as String, range: NSRange(location: 0, length: expression.length)) {
            let kind = expression.substring(with: match.range(at: 1))
            let name = expression.substring(with: match.range(at: 2)).split(separator: ".").last.map(String.init) ?? ""
            if kind == "With" { with.append(name) } else { without.append(name) }
        }
        return (with, without)
    }

    /// Аргумент вызова номер `index` после имени метода в `name`: `M(a, ref b, c: d)`.
    static func argument(in text: [UInt16], after name: NSRange, index: Int) -> NSRange? {
        var i = skipSpace(text, from: NSMaxRange(name))
        // Явные дженерики: `M<T>(…)`.
        if i < text.count, text[i] == lt {
            var depth = 0
            while i < text.count {
                if text[i] == lt { depth += 1 } else if text[i] == gt { depth -= 1; if depth == 0 { i += 1; break } }
                i += 1
            }
            i = skipSpace(text, from: i)
        }
        guard i < text.count, text[i] == openParen else { return nil }
        let close = matching(text, open: i)
        guard close > i else { return nil }
        var arguments: [NSRange] = []
        var start = i + 1
        var depth = 0
        var k = i + 1
        while k <= close {
            let c = text[k]
            if c == quote || c == apostrophe { k = skipLiteral(text, from: k); continue }
            if k == close || (depth == 0 && c == comma) {
                arguments.append(NSRange(location: start, length: k - start))
                start = k + 1
            } else if c == openParen || c == openBracket || c == openBrace || c == lt {
                depth += 1
            } else if c == closeParen || c == closeBracket || c == closeBrace || c == gt {
                depth = max(0, depth - 1)
            }
            k += 1
        }
        guard index < arguments.count else { return nil }
        var argument = arguments[index]
        // Без `ref`/`out`/`in` и имени `name:`.
        var s = skipSpace(text, from: argument.location)
        for modifier in ["ref", "out", "in"] {
            let m = Array(modifier.utf16)
            if s + m.count < NSMaxRange(argument), Array(text[s..<(s + m.count)]) == m, isSpace(text[s + m.count]) {
                s = skipSpace(text, from: s + m.count)
            }
        }
        var n = s
        while n < NSMaxRange(argument), isIdentPart(text[n]) { n += 1 }
        let colon = skipSpace(text, from: n)
        if n > s, colon < NSMaxRange(argument), text[colon] == 0x3A, colon + 1 < text.count, text[colon + 1] != 0x3A {
            s = skipSpace(text, from: colon + 1)
        }
        var e = NSMaxRange(argument)
        while e > s, isSpace(text[e - 1]) { e -= 1 }
        argument = NSRange(location: s, length: max(0, e - s))
        return argument.length > 0 ? argument : nil
    }

    /// Выражения `return …;` в теле метода и тело-выражение `=> …;`.
    static func returnedExpressions(in text: [UInt16], method: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        let keyword = Array("return".utf16)
        var i = method.location
        let end = NSMaxRange(method)
        var sawBrace = false
        while i < end {
            let c = text[i]
            if c == quote || c == apostrophe { i = skipLiteral(text, from: i); continue }
            if c == openBrace { sawBrace = true }
            // `=> выражение;` до первой фигурной скобки — тело-выражение.
            if !sawBrace, c == eq, i + 1 < end, text[i + 1] == gt {
                let rhs = rhs(in: text, from: i + 2)
                if rhs.length > 0 { result.append(rhs) }
                return result
            }
            if c == keyword[0], i + keyword.count < end, Array(text[i..<(i + keyword.count)]) == keyword,
               i == 0 || !isIdentPart(text[i - 1]), !isIdentPart(text[i + keyword.count]) {
                let rhs = rhs(in: text, from: i + keyword.count)
                if rhs.length > 0 { result.append(rhs) }
                i = NSMaxRange(rhs)
                continue
            }
            i += 1
        }
        return result
    }

    /// Что делают с компонентом через стэш: `name.Set(`, `.Add(`, `.Remove(`.
    enum StashCall: String { case set = "Set", add = "Add", remove = "Remove", setOrUpdate = "SetOrUpdate" }

    static func stashCalls(in text: [UInt16], stash: String) -> [(range: NSRange, call: StashCall)] {
        var result: [(NSRange, StashCall)] = []
        let target = Array(stash.utf16)
        guard !target.isEmpty else { return [] }
        var i = 0
        while i + target.count < text.count {
            guard text[i] == target[0], Array(text[i..<(i + target.count)]) == target,
                  i == 0 || !isIdentPart(text[i - 1]),
                  !isIdentPart(text[i + target.count]) else { i += 1; continue }
            var j = skipSpace(text, from: i + target.count)
            guard j < text.count, text[j] == dot else { i += 1; continue }
            j = skipSpace(text, from: j + 1)
            var e = j
            while e < text.count, isIdentPart(text[e]) { e += 1 }
            let method = string(text, NSRange(location: j, length: e - j))
            if let call = StashCall(rawValue: method), skipSpace(text, from: e) < text.count,
               text[skipSpace(text, from: e)] == openParen {
                result.append((NSRange(location: j, length: e - j), call))
            }
            i = e
        }
        return result
    }

    /// Закрывающая скобка к открывающей в `open` (круглой или фигурной).
    static func matching(_ text: [UInt16], open: Int) -> Int {
        let o = text[open]
        let c: UInt16 = o == openParen ? closeParen : o == openBrace ? closeBrace : closeBracket
        var depth = 0
        var i = open
        while i < text.count {
            let ch = text[i]
            if ch == quote || ch == apostrophe { i = skipLiteral(text, from: i); continue }
            if ch == slash, i + 1 < text.count, text[i + 1] == slash {
                while i < text.count, text[i] != newline { i += 1 }
                continue
            }
            if ch == o { depth += 1 } else if ch == c { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return -1
    }

    // MARK: - Мелочи

    private static let keywords: Set<String> = [
        "new", "true", "false", "null", "this", "base", "var", "ref", "out", "in", "typeof", "nameof",
        "default", "is", "as", "await", "sizeof", "stackalloc", "checked", "unchecked", "when", "and", "or", "not",
        "switch", "with", "int", "float", "double", "bool", "string", "long", "short", "byte", "uint",
        "ulong", "ushort", "sbyte", "char", "decimal", "object", "void",
    ]

    private static func looksGeneric(_ text: [UInt16], from: Int, end: Int) -> Bool {
        var depth = 0
        var i = from
        while i < end {
            let c = text[i]
            if c == lt { depth += 1 } else if c == gt {
                depth -= 1
                if depth == 0 { return i + 1 < end && text[skipSpace(text, from: i + 1)] == openParen }
            } else if !(isIdentPart(c) || c == dot || c == comma || isSpace(c)) {
                return false
            }
            i += 1
        }
        return false
    }

    private static func word(_ text: [UInt16], endingAt end: Int) -> String {
        var s = end
        while s > 0, isIdentPart(text[s - 1]) { s -= 1 }
        return string(text, NSRange(location: s, length: end - s))
    }

    static func string(_ text: [UInt16], _ range: NSRange) -> String {
        String(utf16CodeUnits: Array(text[range.location..<NSMaxRange(range)]), count: range.length)
    }

    private static func skipLiteral(_ text: [UInt16], from start: Int) -> Int {
        let q = text[start]
        var i = start + 1
        while i < text.count, text[i] != q {
            if text[i] == backslash { i += 1 }
            if text[i] == newline { break }
            i += 1
        }
        return min(i + 1, text.count)
    }

    private static func skipSpace(_ text: [UInt16], from start: Int) -> Int {
        var i = start
        while i < text.count, isSpace(text[i]) { i += 1 }
        return i
    }

    private static func skipSpaceBackward(_ text: [UInt16], from start: Int) -> Int {
        var i = start
        while i > 0, isSpace(text[i - 1]) { i -= 1 }
        return i
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
    static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x40 || c > 0x7F
    }
    static func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) }

    private static let eq: UInt16 = 0x3D, gt: UInt16 = 0x3E, lt: UInt16 = 0x3C
    private static let plus: UInt16 = 0x2B, minus: UInt16 = 0x2D, star: UInt16 = 0x2A, slash: UInt16 = 0x2F
    private static let percent: UInt16 = 0x25, amp: UInt16 = 0x26, bar: UInt16 = 0x7C, caret: UInt16 = 0x5E
    private static let question: UInt16 = 0x3F, dot: UInt16 = 0x2E, comma: UInt16 = 0x2C, semicolon: UInt16 = 0x3B
    private static let quote: UInt16 = 0x22, apostrophe: UInt16 = 0x27, backslash: UInt16 = 0x5C, dollar: UInt16 = 0x24
    private static let newline: UInt16 = 0x0A
    private static let openParen: UInt16 = 0x28, closeParen: UInt16 = 0x29
    private static let openBracket: UInt16 = 0x5B, closeBracket: UInt16 = 0x5D
    private static let openBrace: UInt16 = 0x7B, closeBrace: UInt16 = 0x7D
    private static let compoundChars: Set<UInt16> = [0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x26, 0x7C, 0x5E, 0x3F, 0x3C, 0x3E]
}
