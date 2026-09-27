import Foundation

/// Карта правок: где в нынешнем тексте то, что было в прежнем.
///
/// Прежний текст — тот, по которому что-то посчитано заранее: раскраска
/// Rustlyn по файлу, каким тот его прочитал, структура файла по версии чуть
/// постарше. Нынешний — тот, что на экране после набора. Хранятся только
/// правленые куски — по возрастанию и не пересекаясь; всё между ними не
/// менялось, а лишь сдвинулось на сумму разниц длин кусков перед ним. Правки
/// подряд в одном месте сливаются в один кусок, так что кусков столько,
/// сколько мест правили, а не сколько раз нажали клавишу.
struct EditMap: Equatable, Sendable {

    /// Правленый кусок: `old` — где он был в прежнем тексте, `new` — где он
    /// в нынешнем. Пустой `old` — вставка, пустой `new` — удаление.
    struct Change: Equatable, Sendable {
        var old: Range<Int>
        var new: Range<Int>
        var delta: Int { new.count - old.count }
    }

    private(set) var changes: [Change] = []

    var isEmpty: Bool { changes.isEmpty }

    /// Правка нынешнего текста: `range` (в координатах до неё) заменили на
    /// `length` символов.
    mutating func record(_ range: Range<Int>, length: Int) {
        guard !range.isEmpty || length > 0 else { return }
        let delta = length - range.count
        // Куски целиком до правки — только сдвигают её начало в прежнем тексте.
        var i = 0, before = 0
        while i < changes.count, changes[i].new.upperBound < range.lowerBound {
            before += changes[i].delta
            i += 1
        }
        // Куски, которые правка задевает или к которым примыкает, — в один.
        var j = i, inside = 0
        while j < changes.count, changes[j].new.lowerBound <= range.upperBound {
            inside += changes[j].delta
            j += 1
        }
        // Границы слитого куска: концы правки — в нетронутом тексте, если
        // крайний кусок не заходит за них.
        var oldLower = range.lowerBound - before, newLower = range.lowerBound
        var oldUpper = range.upperBound - before - inside, newUpper = range.upperBound
        if i < j, changes[i].new.lowerBound <= range.lowerBound {
            oldLower = changes[i].old.lowerBound
            newLower = changes[i].new.lowerBound
        }
        if i < j, changes[j - 1].new.upperBound >= range.upperBound {
            oldUpper = changes[j - 1].old.upperBound
            newUpper = changes[j - 1].new.upperBound
        }
        let old = oldLower..<oldUpper
        let new = newLower..<(newUpper + delta)
        for k in j..<changes.count {
            changes[k].new = (changes[k].new.lowerBound + delta)..<(changes[k].new.upperBound + delta)
        }
        // Вернули как было (набрали и стёрли) — правки нет.
        if old.isEmpty && new.isEmpty {
            changes.removeSubrange(i..<j)
        } else {
            changes.replaceSubrange(i..<j, with: [Change(old: old, new: new)])
        }
    }

    /// Участок прежнего текста, из которого вышел участок `range` нынешнего.
    /// Правленый кусок на границе берётся целиком.
    func oldRange(covering range: Range<Int>) -> Range<Int> {
        func old(_ offset: Int, upper: Bool) -> Int {
            var shift = 0
            for change in changes {
                if change.new.upperBound <= offset { shift += change.delta; continue }
                if change.new.lowerBound < offset { return upper ? change.old.upperBound : change.old.lowerBound }
                break
            }
            return offset - shift
        }
        let lower = old(range.lowerBound, upper: false)
        return lower..<max(lower, old(range.upperBound, upper: true))
    }

    /// Где в прежнем тексте начало строки `start` нынешнего — если всё до него
    /// не правили. nil — строка начинается внутри правленого куска или сразу
    /// за ним: такого начала в прежнем тексте нет.
    func oldLineStart(_ start: Int) -> Int? {
        var shift = 0
        for change in changes {
            if change.new.upperBound < start { shift += change.delta; continue }
            return change.new.lowerBound < start ? nil : start - shift
        }
        return start - shift
    }

    /// Правленые куски, которые задевают участок нынешнего текста или
    /// примыкают к нему, — в нынешних координатах.
    func newRanges(near range: Range<Int>) -> [Range<Int>] {
        changes.lazy.map(\.new)
            .filter { $0.upperBound >= range.lowerBound && $0.lowerBound <= range.upperBound }
    }

    /// Токены прежнего текста — в нынешний. Токены отсортированы по началу
    /// и могут вкладываться (escape внутри строки).
    ///
    /// `kept` — не тронутые правками, уже на новых местах. `cut` — задетые:
    /// правка внутри или через границу; у них — место, которое они занимают
    /// теперь вместе с правкой, и прежний вид. Вставка вплотную к токену его
    /// не задевает: набранное перед словом или после него — не само слово.
    func carry(_ tokens: [Token]) -> (kept: [Token], cut: [Token]) {
        guard !changes.isEmpty else { return (tokens, []) }
        var kept: [Token] = []
        kept.reserveCapacity(tokens.count)
        var cut: [Token] = []
        var k = 0, shift = 0
        for token in tokens {
            let start = Int(token.start), end = start + Int(token.length)
            // Куски, кончившиеся до начала токена, — и вставка прямо перед ним.
            while k < changes.count, changes[k].old.upperBound <= start {
                shift += changes[k].delta
                k += 1
            }
            guard k < changes.count, changes[k].old.lowerBound < end else {
                kept.append(Token(start: Int32(start + shift), length: token.length, kind: token.kind))
                continue
            }
            var m = k, through = shift
            while m < changes.count, changes[m].old.lowerBound < end {
                through += changes[m].delta
                m += 1
            }
            let lower = min(start + shift, changes[k].new.lowerBound)
            let upper = max(end + through, changes[m - 1].new.upperBound)
            cut.append(Token(start: Int32(lower), length: Int32(upper - lower), kind: token.kind))
        }
        return (kept, cut)
    }

    /// То же для одного участка: nil — правка его задела.
    func carry(_ range: NSRange) -> NSRange? {
        let token = Token(start: Int32(range.location), length: Int32(range.length), kind: .plain)
        return carry([token]).kept.first.map { NSRange(location: Int($0.start), length: Int($0.length)) }
    }
}

/// Раскраска правленого текста из двух: той, что посчитана по прежнему
/// тексту и перенесена правками (`EditMap.carry`), и своего лексера по
/// нынешнему — только там, где правка что-то поменяла.
///
/// «Поменяла» решает лексер. Пробел между словами не попадает ни в один его
/// токен — и не меняется ничего. Буква внутри слова меняет слово, и оно
/// берёт цвет лексера. Правка внутри строки или комментария остаётся их
/// частью, если лексер видит их границы на прежних местах: строка остаётся
/// строкой разбора со всеми её escape и дырами интерполяции, а не
/// перекрашивается целиком. Набрали `"` или `*/` — границы у лексера уже
/// другие, и изменённое красит он.
enum CarriedColors {

    /// Токены окна `window` нынешнего текста.
    ///
    /// - `kept`, `cut` — перенесённая раскраска (см. `EditMap.carry`);
    /// - `changes` — правленые куски у окна, в нынешних координатах;
    /// - `stale` — строки, куда лексер входит не в том состоянии, что прежде
    ///   (выше открыли комментарий): их красит лексер, если их не покрывает
    ///   контейнер, границы которого лексер подтвердил;
    /// - `lexed` — токены своего лексера по строкам окна, по порядку;
    /// - `units` — нынешний текст.
    static func merge(kept: [Token], cut: [Token], changes: [Range<Int>], stale: [Range<Int>],
                      lexed: [Token], units: [UInt16], window: Range<Int>) -> [Token] {
        let merger = Merger(kept: kept, cut: cut, lexed: lexed, units: units)
        var fills: [Token] = []
        var dirty: [Range<Int>] = []
        func clip(_ range: Range<Int>) -> Range<Int>? {
            let lower = max(range.lowerBound, window.lowerBound)
            let upper = min(range.upperBound, window.upperBound)
            return lower <= upper ? lower..<upper : nil
        }
        func seed(_ range: Range<Int>, _ container: Token?, own: Bool = false) {
            guard let range = clip(range) else { return }
            // Мёртвую ветку `#if` лексер не различает: она остаётся серой, пока
            // её не разберут заново, — своим цветом только набранная директива.
            if let container, (own && container.kind == .disabled) || merger.absorbs(range, container.kind) {
                if !range.isEmpty {
                    fills.append(Token(start: Int32(range.lowerBound), length: Int32(range.count), kind: container.kind))
                }
                return
            }
            dirty.append(range)
            // Правка у строки или комментария, которую лексер в них не видит,
            // может менять и их: `"` перед строкой. В строках самой правки —
            // ниже решит состояние лексера на входе в строку (`stale`).
            guard let container, !own, container.kind != .disabled else { return }
            var lower = range.lowerBound, upper = range.upperBound
            while lower > 0, units[lower - 1] != 0x0A { lower -= 1 }
            while upper < units.count, units[upper] != 0x0A { upper += 1 }
            let part = max(container.lower, lower)..<max(max(container.lower, lower), min(container.upper, upper))
            if let part = clip(part), !part.isEmpty, part != range, !merger.absorbs(part, container.kind) {
                dirty.append(part)
            }
        }
        for token in cut where token.length > 0 {
            if Merger.isContainer(token.kind) {
                seed(token.span, token, own: true)
            } else {
                seed(token.span, merger.container(around: token.span))
            }
        }
        for change in changes {
            seed(change, merger.container(around: change))
            // Правка меняет разбор и правее себя, до конца строки: перевод
            // строки посреди `"…"` делает остаток кодом. Строки и комментарии
            // разбора там остаются, только если лексер видит их такими же.
            var end = change.upperBound
            while end < min(units.count, window.upperBound), units[end] != 0x0A { end += 1 }
            for token in merger.containersStarting(in: change.upperBound..<end)
            where !merger.agrees(token, lineEnd: end) {
                if let range = clip(token.span) { dirty.append(range) }
            }
        }
        let stale = stale.filter { !merger.covered($0, by: fills) }
        guard !dirty.isEmpty || !stale.isEmpty else { return sorted(kept + fills) }

        // Изменённое берёт токены лексера, которые его задевают, целиком. Кроме
        // строки, где разбор видит больше лексера: `$"…{x}…"` у лексера одна
        // строка, у разбора — с дырами. Набранное в дыре остаётся без цвета,
        // а строка вокруг — такой, как была.
        var painted: [Token] = []
        var holes = dirty + stale
        for token in lexed {
            let inStale = stale.contains { overlaps($0, token) }
            guard inStale || dirty.contains(where: { overlaps($0, token) }) else { continue }
            if !inStale && merger.isCoarser(token) { continue }
            painted.append(token)
            holes.append(token.span)
        }
        return sorted(trim(kept + fills, by: normalized(holes)) + painted)
    }

    /// Что знает слияние: перенесённое, лексер и текст.
    private struct Merger {
        let kept: [Token]
        let lexed: [Token]
        let units: [UInt16]
        /// Строки, комментарии и мёртвые ветки разбора — целые и задетые.
        let containers: [Token]

        init(kept: [Token], cut: [Token], lexed: [Token], units: [UInt16]) {
            self.kept = kept
            self.lexed = lexed
            self.units = units
            containers = (kept + cut).filter { Self.isContainer($0.kind) && $0.length > 0 }
        }

        /// Вид «контейнера»: внутри него правка не меняет разбора вокруг.
        enum Family { case comment, string, disabled }

        static func family(_ kind: TokenKind) -> Family? {
            switch kind {
            case .comment, .docComment: return .comment
            case .string, .escape: return .string
            case .disabled: return .disabled
            default: return nil
            }
        }

        /// Escape — часть строки, а не своя строка.
        static func isContainer(_ kind: TokenKind) -> Bool {
            kind != .escape && family(kind) != nil
        }

        /// Контейнер, в котором лежит участок, — самый тесный; или тот, к
        /// которому участок примыкает: набранное перед закрывающей кавычкой
        /// интерполяции — ещё строка.
        func container(around range: Range<Int>) -> Token? {
            var best: Token?
            for token in containers where token.lower <= range.lowerBound && range.upperBound <= token.upper {
                if best.map({ token.length < $0.length }) ?? true { best = token }
            }
            return best ?? containers.first { $0.lower == range.upperBound || $0.upper == range.lowerBound }
        }

        /// Остаётся ли участок частью контейнера `kind`: лексер видит там
        /// контейнер того же вида и с теми же границами, что у разбора.
        func absorbs(_ range: Range<Int>, _ kind: TokenKind) -> Bool {
            let over = lexed.filter { overlaps(range, $0) }
            let wanted = Self.family(kind)
            if wanted == .disabled {
                // Мёртвую ветку `#if` лексер не различает; меняет её только директива.
                return !over.contains { $0.kind == .preprocessor }
            }
            for token in over {
                guard Self.family(token.kind) == wanted,
                      confirmed(token.lower, wanted, start: true),
                      confirmed(token.upper, wanted, start: false) else { return false }
            }
            // Всё, кроме пробелов, — внутри того, что лексер считает тем же.
            var index = range.lowerBound
            for token in over {
                while index < min(token.lower, range.upperBound) {
                    guard isSpace(units[index]) else { return false }
                    index += 1
                }
                index = max(index, token.upper)
            }
            while index < range.upperBound {
                guard isSpace(units[index]) else { return false }
                index += 1
            }
            return true
        }

        /// Граница токена лексера — граница контейнера разбора, или лексер
        /// режет контейнер по строкам, а разбор его не режет: между границей
        /// и краем строки внутри контейнера одни пробелы (отступ перед `///`).
        func confirmed(_ position: Int, _ wanted: Family?, start: Bool) -> Bool {
            containers.contains { token in
                guard Self.family(token.kind) == wanted else { return false }
                if position == (start ? token.lower : token.upper) { return true }
                guard token.lower < position, position < token.upper else { return false }
                var index = position
                if start {
                    while index > token.lower, units[index - 1] != 0x0A {
                        guard isSpace(units[index - 1]) else { return false }
                        index -= 1
                    }
                    return index > token.lower
                }
                while index < token.upper, units[index] != 0x0A {
                    guard isSpace(units[index]) else { return false }
                    index += 1
                }
                return index < token.upper
            }
        }

        /// Строка или комментарий лексера, у которых разбор видит те же
        /// границы, а внутри — код: дыры интерполяции.
        func isCoarser(_ token: Token) -> Bool {
            guard let wanted = Self.family(token.kind), wanted != .disabled,
                  confirmed(token.lower, wanted, start: true),
                  confirmed(token.upper, wanted, start: false) else { return false }
            // `kept` — по возрастанию начала: первый, что начинается не раньше токена.
            var lo = 0, hi = kept.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if kept[mid].lower < token.lower { lo = mid + 1 } else { hi = mid }
            }
            while lo < kept.count, kept[lo].lower < token.upper {
                if Self.family(kept[lo].kind) == nil, kept[lo].upper <= token.upper { return true }
                lo += 1
            }
            return false
        }

        /// Нетронутые правками строки и комментарии разбора, начинающиеся в участке.
        func containersStarting(in range: Range<Int>) -> [Token] {
            guard !range.isEmpty else { return [] }
            var lo = 0, hi = kept.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if kept[mid].lower < range.lowerBound { lo = mid + 1 } else { hi = mid }
            }
            var result: [Token] = []
            while lo < kept.count, kept[lo].lower < range.upperBound {
                if Self.isContainer(kept[lo].kind), kept[lo].kind != .disabled { result.append(kept[lo]) }
                lo += 1
            }
            return result
        }

        /// Видит ли лексер контейнер разбора тем же: его часть в этой строке,
        /// без пробелов по краям, — внутри токена лексера того же вида, и
        /// границы этого токена у разбора тоже есть. Закрывающая кавычка,
        /// с которой после правки начинается новая строка до конца строки, —
        /// уже не та кавычка.
        func agrees(_ token: Token, lineEnd: Int) -> Bool {
            var lower = token.lower, upper = min(token.upper, lineEnd)
            while lower < upper, isSpace(units[lower]) { lower += 1 }
            while upper > lower, isSpace(units[upper - 1]) { upper -= 1 }
            guard lower < upper else { return true }
            let wanted = Self.family(token.kind)
            return lexed.contains {
                Self.family($0.kind) == wanted && $0.lower <= lower && upper <= $0.upper
                    && confirmed($0.lower, wanted, start: true) && confirmed($0.upper, wanted, start: false)
            }
        }

        /// Всё, кроме пробелов, в участке покрыто заливками.
        func covered(_ range: Range<Int>, by fills: [Token]) -> Bool {
            let inside = fills.filter { overlaps(range, $0) }
            guard !inside.isEmpty else { return false }
            return range.allSatisfy { index in
                isSpace(units[index]) || inside.contains { $0.lower <= index && index < $0.upper }
            }
        }
    }

    // MARK: - Участки

    /// По возрастанию, слитые; пустые не нужны.
    private static func normalized(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Токены без того, что попало в дыры. Дыры — по возрастанию и не пересекаясь.
    private static func trim(_ tokens: [Token], by holes: [Range<Int>]) -> [Token] {
        guard !holes.isEmpty else { return tokens }
        var result: [Token] = []
        result.reserveCapacity(tokens.count)
        for token in tokens {
            var lower = token.lower
            let upper = token.upper
            var lo = 0, hi = holes.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if holes[mid].upperBound <= lower { lo = mid + 1 } else { hi = mid }
            }
            while lo < holes.count, holes[lo].lowerBound < upper {
                if holes[lo].lowerBound > lower {
                    result.append(Token(start: Int32(lower), length: Int32(holes[lo].lowerBound - lower), kind: token.kind))
                }
                lower = max(lower, holes[lo].upperBound)
                lo += 1
            }
            if lower < upper {
                result.append(Token(start: Int32(lower), length: Int32(upper - lower), kind: token.kind))
            }
        }
        return result
    }

    /// По началу; из начинающихся вместе — длинный раньше: строка, потом её escape.
    private static func sorted(_ tokens: [Token]) -> [Token] {
        tokens.sorted { $0.start != $1.start ? $0.start < $1.start : $0.length > $1.length }
    }
}

/// Задевает ли токен участок. Пустой участок — точка: её задевает токен,
/// в котором она строго внутри (стёрли пробел между словами — слово одно).
private func overlaps(_ range: Range<Int>, _ token: Token) -> Bool {
    token.lower < range.upperBound && range.lowerBound < token.upper
}

@inline(__always)
private func isSpace(_ unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
}

private extension Token {
    var lower: Int { Int(start) }
    var upper: Int { Int(start) + Int(length) }
    var span: Range<Int> { lower..<upper }
}
