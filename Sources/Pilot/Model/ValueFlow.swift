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
        /// Цепочка взята у выражения, а не у имени: `f().x`, `a[i].x`.
        var member = false
        /// Вызов, у результата которого она взята: `_stash.Get(e).x` → `_stash.Get`.
        var receiver: String?
        /// Первое звено цепочки: `a` у `a.b.c`.
        var head: NSRange?
        /// `new T(…)`: объект строится здесь же, из аргументов.
        var constructs = false
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
            // `=>`: лямбда — её параметры и тело не то, из чего складывается
            // значение; ветка `switch`-выражения — да, а шаблон перед ней нет.
            if c == eq, i + 1 < end, text[i + 1] == gt {
                let arrow = i
                i = skipSpace(text, from: i + 2)
                if let arm = switchArmStart(text, before: arrow, from: range.location) {
                    result.removeAll { $0.range.location >= arm && $0.range.location < arrow }
                    continue
                }
                let back = skipSpaceBackward(text, from: arrow)
                var parameters = back
                if back > 0, text[back - 1] == closeParen, let open = matchingBackward(text, close: back - 1) {
                    parameters = open
                } else {
                    while parameters > 0, isIdentPart(text[parameters - 1]) { parameters -= 1 }
                }
                result.removeAll { $0.range.location >= parameters && $0.range.location < arrow }
                i = lambdaBodyEnd(text, from: i, limit: end)
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
            var words = parts.map { string(text, $0) }
            let after = skipSpace(text, from: j)
            // Цель присваивания (`{ A = x }` в инициализаторе) и имя аргумента
            // или элемента кортежа (`M(radius: r)`) — не источники.
            if after + 1 < end, text[after] == eq, text[after + 1] != eq, text[after + 1] != gt {
                i = j
                continue
            }
            if parts.count == 1, after < end, text[after] == colon, after + 1 >= end || text[after + 1] != colon {
                let before = skipSpaceBackward(text, from: i)
                if before > 0, text[before - 1] == openParen || text[before - 1] == comma {
                    i = j
                    continue
                }
            }
            let call = after < end && (text[after] == openParen || text[after] == lt && looksGeneric(text, from: after, end: end))
            // `this.x` — это `x`.
            if words.count > 1, words[0] == "this" || words[0] == "base" { words.removeFirst() }
            if let first = words.first, !keywords.contains(first) {
                var source = Source(range: parts.last!, chain: words.joined(separator: "."), call: call)
                source.head = parts[parts.count - words.count]
                source.constructs = call && word(text, endingAt: skipSpaceBackward(text, from: i)) == "new"
                // `…).x`, `…].x` — член того, что вернуло выражение слева.
                let back = skipSpaceBackward(text, from: i)
                if back > 0, text[back - 1] == dot {
                    source.member = true
                    let close = skipSpaceBackward(text, from: back - 1)
                    if close > 0, text[close - 1] == closeParen,
                       let open = matchingBackward(text, close: close - 1),
                       let callee = enclosingCall(in: text, at: open + 1) {
                        source.receiver = callee.chain
                        // Сам вызов — не источник: из его результата берут только этот член.
                        if let index = result.lastIndex(where: { $0.call && $0.range == callee.range }) {
                            result.remove(at: index)
                        }
                    }
                }
                result.append(source)
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

    // MARK: - Локальные и параметры

    /// Скобки параметров после имени метода (`M<T>(int a, ref B b)`): диапазон
    /// между ними. У свойства их нет.
    static func parameterList(in text: [UInt16], after name: NSRange) -> NSRange? {
        var i = skipSpace(text, from: NSMaxRange(name))
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
        return NSRange(location: i + 1, length: close - i - 1)
    }

    /// Переменная цикла `foreach (var x in items)` в `name`: диапазон `items`.
    /// И элемент разбора `foreach (var (key, x) in items)`.
    static func foreachCollection(in text: [UInt16], variable name: NSRange) -> NSRange? {
        if let direct = foreachSource(in: text, variable: name) { return direct }
        // В скобках разбора: `(key, x)` — как одна переменная цикла.
        var depth = 0
        var i = name.location - 1
        while i >= 0 {
            let c = text[i]
            if c == closeParen { depth += 1 } else if c == openParen {
                if depth == 0 { break }
                depth -= 1
            } else if c == semicolon || c == openBrace || c == closeBrace { return nil }
            i -= 1
        }
        guard i > 0 else { return nil }
        let close = matching(text, open: i)
        guard close > name.location else { return nil }
        return foreachSource(in: text, variable: NSRange(location: i, length: close - i + 1))
    }

    private static func foreachSource(in text: [UInt16], variable name: NSRange) -> NSRange? {
        let after = skipSpace(text, from: NSMaxRange(name))
        guard after + 2 < text.count, text[after] == 0x69, text[after + 1] == 0x6E, isSpace(text[after + 2]) else { return nil }
        guard let open = typeStart(text, before: name.location).flatMap({ openParenBefore(text, $0) }),
              word(text, endingAt: skipSpaceBackward(text, from: open)) == "foreach" else { return nil }
        let close = matching(text, open: open)
        guard close > after else { return nil }
        let start = skipSpace(text, from: after + 2)
        var end = close
        while end > start, isSpace(text[end - 1]) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Переменная шаблона: `x is T name`, `x is not T name` — диапазон `x`.
    static func patternSubject(in text: [UInt16], name: NSRange) -> NSRange? {
        guard let type = typeStart(text, before: name.location) else { return nil }
        var i = skipSpaceBackward(text, from: type)
        if word(text, endingAt: i) == "not" { i = skipSpaceBackward(text, from: i - 3) }
        guard word(text, endingAt: i) == "is" else { return nil }
        let end = skipSpaceBackward(text, from: i - 2)
        // Начало выражения слева от `is`: до скобки, запятой, `=`, `&&`, `||`, `!` своего уровня.
        var start = end
        var depth = 0
        while start > 0 {
            let c = text[start - 1]
            if c == closeParen || c == closeBracket { depth += 1 } else if c == openParen || c == openBracket {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0, c == comma || c == eq || c == amp || c == bar || c == semicolon || c == openBrace
                        || c == question || c == colon || (c == 0x21 && (start >= text.count || text[start] != eq)) {
                break
            }
            start -= 1
        }
        start = skipSpace(text, from: start)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Параметр локальной функции `void Process(T a, U b) { … }` в `name`:
    /// имя функции и номер параметра.
    static func localFunctionParameter(in text: [UInt16], name: NSRange) -> (function: NSRange, index: Int)? {
        var depth = 0
        var commas = 0
        var i = name.location - 1
        while i >= 0 {
            let c = text[i]
            if c == closeParen || c == closeBracket || c == gt { depth += 1 } else if c == openParen || c == openBracket || c == lt {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0, c == comma {
                commas += 1
            } else if c == semicolon || c == openBrace || c == closeBrace || c == eq {
                return nil
            }
            i -= 1
        }
        guard i > 0, text[i] == openParen else { return nil }
        let close = matching(text, open: i)
        guard close > name.location else { return nil }
        // После скобок — тело: `{`, `=>` или ограничения дженериков.
        let after = skipSpace(text, from: close + 1)
        guard after + 1 < text.count, text[after] == openBrace || (text[after] == eq && text[after + 1] == gt)
                || word(text, endingAt: min(text.count, after + 5)) == "where" else { return nil }
        // Перед скобкой — имя, а перед ним тип: это объявление, а не вызов.
        let nameEnd = skipSpaceBackward(text, from: i)
        var nameStart = nameEnd
        while nameStart > 0, isIdentPart(text[nameStart - 1]) { nameStart -= 1 }
        guard nameStart < nameEnd else { return nil }
        let typeEnd = skipSpaceBackward(text, from: nameStart)
        guard typeEnd > 0 else { return nil }
        let before = text[typeEnd - 1]
        let typeWord = word(text, endingAt: typeEnd)
        guard before == gt || before == closeBracket || before == question
                || (isIdentPart(before) && !["return", "await", "new", "else", "in", "is", "as", "case", "throw", "yield"].contains(typeWord))
        else { return nil }
        return (NSRange(location: nameStart, length: nameEnd - nameStart), commas)
    }

    /// Вызовы функции `function` в `range`, кроме её объявления: диапазоны имени.
    static func calls(of function: String, in text: [UInt16], range: NSRange, except declaration: Int) -> [NSRange] {
        let target = Array(function.utf16)
        var result: [NSRange] = []
        var i = range.location
        let end = min(NSMaxRange(range), text.count)
        while i + target.count < end {
            if text[i] == quote || text[i] == apostrophe { i = skipLiteral(text, from: i); continue }
            guard text[i] == target[0], Array(text[i..<(i + target.count)]) == target,
                  i == 0 || (!isIdentPart(text[i - 1]) && text[i - 1] != dot),
                  !isIdentPart(text[i + target.count]), i != declaration else { i += 1; continue }
            let open = skipSpace(text, from: i + target.count)
            if open < end, text[open] == openParen { result.append(NSRange(location: i, length: target.count)) }
            i += target.count
        }
        return result
    }

    /// `out var x`, `out int x`, `out x`: значение в `name` положит вызов.
    static func isOutArgument(in text: [UInt16], name: NSRange) -> Bool {
        var i = skipSpaceBackward(text, from: name.location)
        if word(text, endingAt: i) == "out" { return true }
        // Объявление прямо в аргументе: перед именем — тип.
        guard let start = typeStart(text, before: name.location), start < name.location else { return false }
        i = skipSpaceBackward(text, from: start)
        return word(text, endingAt: i) == "out"
    }

    /// Параметр лямбды: `x => …`, `(a, b) => …`, `(int a) => …`.
    static func isLambdaParameter(in text: [UInt16], name: NSRange) -> Bool {
        var i = skipSpace(text, from: NSMaxRange(name))
        if i + 1 < text.count, text[i] == eq, text[i + 1] == gt { return true }
        guard i < text.count, text[i] == comma || text[i] == closeParen else { return false }
        // До закрывающей скобки списка, за ней — `=>`.
        var depth = 0
        while i < text.count {
            let c = text[i]
            if c == openParen { depth += 1 } else if c == closeParen {
                if depth == 0 { break }
                depth -= 1
            } else if c == semicolon || c == openBrace { return false }
            i += 1
        }
        let arrow = skipSpace(text, from: i + 1)
        return arrow + 1 < text.count && text[arrow] == eq && text[arrow + 1] == gt
    }

    /// Вызов, в скобках которого стоит `offset`: `_stash.Get(e, out x)` —
    /// источник `_stash.Get` с диапазоном имени `Get`.
    static func enclosingCall(in text: [UInt16], at offset: Int) -> Source? {
        guard let name = calledName(in: text, at: offset) else { return nil }
        var words = [string(text, name)]
        var start = name.location
        while true {
            let dotAt = skipSpaceBackward(text, from: start)
            guard dotAt > 0, text[dotAt - 1] == dot else { break }
            let end = skipSpaceBackward(text, from: dotAt - 1)
            var begin = end
            while begin > 0, isIdentPart(text[begin - 1]) { begin -= 1 }
            guard begin < end, isIdentStart(text[begin]) else { break }
            words.insert(string(text, NSRange(location: begin, length: end - begin)), at: 0)
            start = begin
        }
        if words.count > 1, words[0] == "this" || words[0] == "base" { words.removeFirst() }
        return Source(range: name, chain: words.joined(separator: "."), call: true)
    }

    private static func calledName(in text: [UInt16], at offset: Int) -> NSRange? {
        var depth = 0
        var i = offset - 1
        while i >= 0 {
            let c = text[i]
            if c == closeParen || c == closeBracket { depth += 1 } else if c == openParen || c == openBracket {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0, c == semicolon || c == openBrace || c == closeBrace { return nil }
            i -= 1
        }
        guard i > 0, text[i] == openParen else { return nil }
        var end = skipSpaceBackward(text, from: i)
        // `M<T>(…)` — имя перед дженериком.
        if end > 0, text[end - 1] == gt {
            var angle = 0
            var k = end - 1
            while k >= 0 {
                if text[k] == gt { angle += 1 } else if text[k] == lt { angle -= 1; if angle == 0 { break } }
                k -= 1
            }
            end = skipSpaceBackward(text, from: max(k, 0))
        }
        var start = end
        while start > 0, isIdentPart(text[start - 1]) { start -= 1 }
        guard start < end, isIdentStart(text[start]) else { return nil }
        let name = string(text, NSRange(location: start, length: end - start))
        return keywords.contains(name) || ["if", "while", "for", "foreach", "switch", "using", "lock", "catch"].contains(name)
            ? nil : NSRange(location: start, length: end - start)
    }

    /// Что возвращает геттер свойства `property` (его объявление целиком):
    /// `T P => x;`, `get => x;`, `get { return x; }`.
    static func getterExpressions(in text: [UInt16], property: NSRange, name: NSRange) -> [NSRange] {
        let end = NSMaxRange(property)
        var i = skipSpace(text, from: NSMaxRange(name))
        // Индексатор: `this[int i]`.
        if i < end, text[i] == openBracket {
            let close = matching(text, open: i)
            guard close > i else { return [] }
            i = skipSpace(text, from: close + 1)
        }
        guard i + 1 < end else { return [] }
        if text[i] == eq, text[i + 1] == gt {
            let body = rhs(in: text, from: i + 2)
            return body.length > 0 ? [body] : []
        }
        guard text[i] == openBrace else { return [] }
        let close = matching(text, open: i)
        guard close > i else { return [] }
        let accessors = NSRange(location: i + 1, length: close - i - 1)
        guard let get = keyword("get", in: text, range: accessors) else { return [] }
        let after = skipSpace(text, from: NSMaxRange(get))
        if after + 1 < end, text[after] == eq, text[after + 1] == gt {
            let body = rhs(in: text, from: after + 2)
            return body.length > 0 ? [body] : []
        }
        guard after < end, text[after] == openBrace else { return [] }
        let bodyEnd = matching(text, open: after)
        guard bodyEnd > after else { return [] }
        return returnedExpressions(in: text, method: NSRange(location: after, length: bodyEnd - after + 1))
    }

    /// Сеттер свойства (`set` или `init`) целиком: внутри него `value` —
    /// то, что свойству присваивают.
    static func setter(in text: [UInt16], property: NSRange, name: NSRange) -> NSRange? {
        let end = NSMaxRange(property)
        var i = skipSpace(text, from: NSMaxRange(name))
        if i < end, text[i] == openBracket {
            let close = matching(text, open: i)
            guard close > i else { return nil }
            i = skipSpace(text, from: close + 1)
        }
        guard i < end, text[i] == openBrace else { return nil }
        let close = matching(text, open: i)
        guard close > i else { return nil }
        let accessors = NSRange(location: i + 1, length: close - i - 1)
        guard let set = keyword("set", in: text, range: accessors) ?? keyword("init", in: text, range: accessors)
        else { return nil }
        let after = skipSpace(text, from: NSMaxRange(set))
        if after < close, text[after] == openBrace {
            let bodyEnd = matching(text, open: after)
            return bodyEnd > after ? NSRange(location: set.location, length: bodyEnd - set.location + 1) : nil
        }
        guard after + 1 < close, text[after] == eq, text[after + 1] == gt else { return nil }
        let body = rhs(in: text, from: after + 2)
        return NSRange(location: set.location, length: NSMaxRange(body) - set.location)
    }

    /// `{ get; set; } = x;` — начальное значение автосвойства.
    static func propertyInitializer(in text: [UInt16], property: NSRange, name: NSRange) -> NSRange? {
        let i = skipSpace(text, from: NSMaxRange(name))
        guard i < NSMaxRange(property), text[i] == openBrace else { return nil }
        let close = matching(text, open: i)
        guard close > i else { return nil }
        let eqAt = skipSpace(text, from: close + 1)
        guard eqAt + 1 < text.count, text[eqAt] == eq, text[eqAt + 1] != eq, text[eqAt + 1] != gt else { return nil }
        let value = rhs(in: text, from: eqAt + 1)
        return value.length > 0 ? value : nil
    }

    /// Первое слово `word` в `range` на верхнем уровне скобок.
    private static func keyword(_ keyword: String, in text: [UInt16], range: NSRange) -> NSRange? {
        let target = Array(keyword.utf16)
        var i = range.location
        var depth = 0
        while i + target.count <= NSMaxRange(range) {
            let c = text[i]
            if c == quote || c == apostrophe { i = skipLiteral(text, from: i); continue }
            if c == openBrace || c == openParen { depth += 1 } else if c == closeBrace || c == closeParen { depth -= 1 }
            if depth == 0, c == target[0], Array(text[i..<(i + target.count)]) == target,
               i == 0 || !isIdentPart(text[i - 1]),
               i + target.count >= text.count || !isIdentPart(text[i + target.count]) {
                return NSRange(location: i, length: target.count)
            }
            i += 1
        }
        return nil
    }

    /// Начало типа, стоящего перед именем объявления: `var x`, `ref Foo<int> x`,
    /// `List<int>[] x`. nil — если перед именем не тип.
    private static func typeStart(_ text: [UInt16], before position: Int) -> Int? {
        var i = skipSpaceBackward(text, from: position)
        guard i > 0 else { return nil }
        let end = i
        var angle = 0
        while i > 0 {
            let c = text[i - 1]
            if c == gt { angle += 1 } else if c == lt {
                guard angle > 0 else { break }
                angle -= 1
            } else if !(isIdentPart(c) || c == dot || c == question || c == openBracket || c == closeBracket
                        || (angle > 0 && (c == comma || isSpace(c)))) {
                break
            }
            i -= 1
        }
        return i < end && isIdentStart(text[i]) ? i : nil
    }

    /// Открывающая скобка прямо перед `position` (через пробелы и `ref`/`var`).
    private static func openParenBefore(_ text: [UInt16], _ position: Int) -> Int? {
        var i = skipSpaceBackward(text, from: position)
        if ["ref", "await"].contains(word(text, endingAt: i)) {
            i = skipSpaceBackward(text, from: i - word(text, endingAt: i).utf16.count)
        }
        return i > 0 && text[i - 1] == openParen ? i - 1 : nil
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

    /// Запись в поле компонента через стэш.
    struct StashWrite {
        /// Имя поля в месте записи.
        var name: NSRange
        var rhs: NSRange?
        var compound: Bool
    }

    /// Записи в поле `field` компонента через стэш `stash` — прямо в то, что
    /// вернул `Get`/`Add` (`stash.Get(e).field = x`), и через ref-локальную
    /// (`ref var c = ref stash.Get(e); … c.field = x`) до конца её метода:
    /// `scope` даёт метод по позиции.
    static func stashFieldWrites(in text: [UInt16], stash: String, field: String,
                                 scope: (Int) -> NSRange?) -> [StashWrite] {
        var result: [StashWrite] = []
        func check(_ name: NSRange) {
            guard string(text, name) == field, case .write(let rhs, let compound) = access(in: text, name: name) else { return }
            result.append(StashWrite(name: name, rhs: rhs, compound: compound))
        }
        for call in stashReferences(in: text, stash: stash) {
            // Прямо в результат: `stash.Get(e).field = x`.
            if let member = member(in: text, after: call.close) { check(member) }
            // Через ref-локальную: `ref var c = ref stash.Get(e)`.
            guard let local = refLocal(in: text, before: call.start), let method = scope(call.start) else { continue }
            for member in members(of: local, in: text, range: NSRange(location: call.close, length: max(0, NSMaxRange(method) - call.close))) {
                check(member)
            }
        }
        return result
    }

    /// Стэш, из которого взята ref-локальная `local`, — если её объявили в
    /// `method` до `before`: `ref var c = ref _health.Get(e)` → `_health`.
    static func stashOfLocal(in text: [UInt16], local: String, method: NSRange, before: Int) -> String? {
        let target = Array(local.utf16)
        var found: String?
        var i = method.location
        let limit = min(before, NSMaxRange(method))
        while i + target.count <= limit {
            guard text[i] == target[0], Array(text[i..<(i + target.count)]) == target,
                  i == 0 || !isIdentPart(text[i - 1]),
                  i + target.count < text.count, !isIdentPart(text[i + target.count]) else { i += 1; continue }
            // `c = ref _stash.Get(`
            var j = skipSpace(text, from: i + target.count)
            guard j + 1 < text.count, text[j] == eq, text[j + 1] != eq else { i += 1; continue }
            j = skipSpace(text, from: j + 1)
            guard j + 3 < text.count, string(text, NSRange(location: j, length: 3)) == "ref", !isIdentPart(text[j + 3]) else {
                i += 1; continue
            }
            j = skipSpace(text, from: j + 3)
            var e = j
            while e < text.count, isIdentPart(text[e]) { e += 1 }
            let stash = string(text, NSRange(location: j, length: e - j))
            if !stash.isEmpty, let call = stashReferences(in: text, stash: stash, from: j, limit: e + 1).first, call.start == j {
                found = stash
            }
            i += target.count
        }
        return found
    }

    /// Ref-возвраты стэша: `stash.Get(`, `stash.Add(` — где начинается имя
    /// стэша и где закрывается скобка вызова.
    private static func stashReferences(in text: [UInt16], stash: String, from: Int = 0,
                                        limit: Int? = nil) -> [(start: Int, close: Int)] {
        let target = Array(stash.utf16)
        guard !target.isEmpty else { return [] }
        var result: [(Int, Int)] = []
        var i = from
        let end = min(limit ?? text.count, text.count)
        while i + target.count < end {
            guard text[i] == target[0], Array(text[i..<(i + target.count)]) == target,
                  i == 0 || (!isIdentPart(text[i - 1]) && text[i - 1] != dot),
                  !isIdentPart(text[i + target.count]) else { i += 1; continue }
            var j = skipSpace(text, from: i + target.count)
            guard j < text.count, text[j] == dot else { i += 1; continue }
            j = skipSpace(text, from: j + 1)
            var e = j
            while e < text.count, isIdentPart(text[e]) { e += 1 }
            let method = string(text, NSRange(location: j, length: e - j))
            let open = skipSpace(text, from: e)
            guard method == "Get" || method == "Add", open < text.count, text[open] == openParen else { i = e; continue }
            let close = matching(text, open: open)
            guard close > open else { i = e; continue }
            result.append((i, close))
            i = e
        }
        return result
    }

    /// `ref var c = ref ` (или `c = ref `) прямо перед `position`: имя `c`.
    private static func refLocal(in text: [UInt16], before position: Int) -> String? {
        var i = skipSpaceBackward(text, from: position)
        guard word(text, endingAt: i) == "ref" else { return nil }
        i = skipSpaceBackward(text, from: i - 3)
        guard i > 1, text[i - 1] == eq, !Array("=!<>+-*/%&|^?".utf16).contains(text[i - 2]) else { return nil }
        i = skipSpaceBackward(text, from: i - 1)
        let name = word(text, endingAt: i)
        guard let first = name.utf16.first, isIdentStart(first), !keywords.contains(name) else { return nil }
        return name
    }

    /// `.member` сразу за позицией `close` (закрывающей скобкой вызова).
    private static func member(in text: [UInt16], after close: Int) -> NSRange? {
        let dotAt = skipSpace(text, from: close + 1)
        guard dotAt < text.count, text[dotAt] == dot else { return nil }
        let start = skipSpace(text, from: dotAt + 1)
        var end = start
        while end < text.count, isIdentPart(text[end]) { end += 1 }
        return end > start && isIdentStart(text[start]) ? NSRange(location: start, length: end - start) : nil
    }

    /// Члены, взятые у `local` в `range`: `local.member` → диапазон `member`.
    private static func members(of local: String, in text: [UInt16], range: NSRange) -> [NSRange] {
        let target = Array(local.utf16)
        var result: [NSRange] = []
        var i = range.location
        let end = min(NSMaxRange(range), text.count)
        while i + target.count < end {
            if text[i] == quote || text[i] == apostrophe { i = skipLiteral(text, from: i); continue }
            guard text[i] == target[0], Array(text[i..<(i + target.count)]) == target,
                  i == 0 || (!isIdentPart(text[i - 1]) && text[i - 1] != dot),
                  !isIdentPart(text[i + target.count]) else { i += 1; continue }
            if let name = member(in: text, after: i + target.count - 1) { result.append(name) }
            i += target.count
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

    /// Начало ветки `switch`-выражения, если `=>` в `arrow` — её стрелка:
    /// после ближайшей незакрытой `{` (перед которой `switch`) или запятой в ней.
    private static func switchArmStart(_ text: [UInt16], before arrow: Int, from start: Int) -> Int? {
        var depth = 0
        var i = arrow - 1
        var arm: Int?
        while i >= start {
            let c = text[i]
            if c == closeBrace || c == closeParen || c == closeBracket { depth += 1 } else if c == openParen || c == openBracket {
                if depth == 0 { return nil }
                depth -= 1
            } else if c == openBrace {
                if depth == 0 {
                    guard word(text, endingAt: skipSpaceBackward(text, from: i)) == "switch" else { return nil }
                    return arm ?? i + 1
                }
                depth -= 1
            } else if c == comma, depth == 0, arm == nil {
                arm = i + 1
            } else if c == semicolon, depth == 0 {
                return nil
            }
            i -= 1
        }
        return nil
    }

    /// Конец тела лямбды, начатого в `start`: блок в фигурных скобках или
    /// выражение до запятой, скобки или `;` своего уровня.
    private static func lambdaBodyEnd(_ text: [UInt16], from start: Int, limit: Int) -> Int {
        if start < limit, text[start] == openBrace {
            let close = matching(text, open: start)
            return close > start ? close + 1 : limit
        }
        var depth = 0
        var i = start
        while i < limit {
            let c = text[i]
            if c == quote || c == apostrophe { i = skipLiteral(text, from: i); continue }
            if c == openParen || c == openBracket || c == openBrace { depth += 1 } else if c == closeParen || c == closeBracket || c == closeBrace {
                if depth == 0 { return i }
                depth -= 1
            } else if depth == 0, c == comma || c == semicolon {
                return i
            }
            i += 1
        }
        return limit
    }

    /// Параметр типа: `T` в `class Box<T>` или `void M<in T, U>()`.
    static func isTypeParameter(in text: [UInt16], name: NSRange) -> Bool {
        var before = skipSpaceBackward(text, from: name.location)
        if ["in", "out"].contains(word(text, endingAt: before)) {
            before = skipSpaceBackward(text, from: before - 2 - (word(text, endingAt: before) == "out" ? 1 : 0))
        }
        let after = skipSpace(text, from: NSMaxRange(name))
        guard before > 0, after < text.count, text[before - 1] == lt || text[before - 1] == comma,
              text[after] == gt || text[after] == comma else { return false }
        // Список открывается после имени типа или метода.
        var i = before - 1
        while i > 0, text[i] != lt {
            guard isIdentPart(text[i]) || isSpace(text[i]) || text[i] == comma else { return false }
            i -= 1
        }
        return i > 0 && isIdentPart(text[skipSpaceBackward(text, from: i) - 1])
    }

    /// `var (a, b) = F()`, `(var a, var b) = F()`: для имени в скобках —
    /// правая часть разбора.
    static func deconstruction(in text: [UInt16], name: NSRange) -> NSRange? {
        var depth = 0
        var i = name.location - 1
        while i >= 0 {
            let c = text[i]
            if c == closeParen { depth += 1 } else if c == openParen {
                if depth == 0 { break }
                depth -= 1
            } else if c == semicolon || c == openBrace || c == closeBrace || c == eq { return nil }
            i -= 1
        }
        guard i >= 0 else { return nil }
        // Перед скобкой — `var` или начало инструкции, а не имя метода.
        let before = skipSpaceBackward(text, from: i)
        let head = word(text, endingAt: before)
        guard head == "var" || head.isEmpty else { return nil }
        let close = matching(text, open: i)
        let eqAt = skipSpace(text, from: close + 1)
        guard close > i, eqAt + 1 < text.count, text[eqAt] == eq, text[eqAt + 1] != eq, text[eqAt + 1] != gt else { return nil }
        let value = rhs(in: text, from: eqAt + 1)
        return value.length > 0 ? value : nil
    }

    /// Открывающая круглая скобка к закрывающей в `close`.
    static func matchingBackward(_ text: [UInt16], close: Int) -> Int? {
        var depth = 0
        var i = close
        while i >= 0 {
            if text[i] == closeParen { depth += 1 } else if text[i] == openParen {
                depth -= 1
                if depth == 0 { return i }
            }
            i -= 1
        }
        return nil
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
        "ulong", "ushort", "sbyte", "char", "decimal", "object", "void", "nint", "nuint", "dynamic",
        // Инструкции и модификаторы — в правую часть они попадают из тел лямбд
        // и локальных функций.
        "if", "else", "for", "foreach", "while", "do", "return", "break", "continue", "goto", "throw", "try",
        "catch", "finally", "lock", "using", "fixed", "yield", "case", "static", "async", "const", "readonly",
        "unsafe", "delegate", "params", "scoped",
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
    private static let newline: UInt16 = 0x0A, colon: UInt16 = 0x3A
    private static let openParen: UInt16 = 0x28, closeParen: UInt16 = 0x29
    private static let openBracket: UInt16 = 0x5B, closeBracket: UInt16 = 0x5D
    private static let openBrace: UInt16 = 0x7B, closeBrace: UInt16 = 0x7D
    private static let compoundChars: Set<UInt16> = [0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x26, 0x7C, 0x5E, 0x3F, 0x3C, 0x3E]
}
