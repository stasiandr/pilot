import Foundation

/// Расширение выделения (⌥↑) для языков, которые Rustlyn не разбирает:
/// слово, содержимое кавычек, сами кавычки, содержимое скобок, скобки,
/// строка без отступа, строка, всё. Для C# шаги даёт синтаксическое дерево
/// Rustlyn — они точнее, — а это запасной путь по тексту.
enum SelectionSteps {

    /// Всё, что строго шире `selection`, от меньшего к большему.
    static func around(_ text: NSString, selection: NSRange) -> [NSRange] {
        var steps: [NSRange] = []
        let length = text.length
        guard length > 0 else { return [] }

        // Слово под курсором или слева от него.
        let isWord: (unichar) -> Bool = { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
        }
        var start = selection.location, end = NSMaxRange(selection)
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < length, isWord(text.character(at: end)) { end += 1 }
        steps.append(NSRange(location: start, length: end - start))

        // Кавычки и скобки вокруг, изнутри наружу.
        let line = text.lineRange(for: selection)
        for quote in [unichar(0x22), 0x27, 0x60] {
            if let inner = quoted(text, selection: selection, quote: quote, within: line) {
                steps.append(inner)
                steps.append(NSRange(location: inner.location - 1, length: inner.length + 2))
            }
        }
        var from = selection
        while let pair = enclosingBrackets(text, around: from) {
            steps.append(trimmed(text, NSRange(location: pair.location + 1, length: pair.length - 2)))
            steps.append(pair)
            from = pair
        }

        // Строка без отступа и перевода, строка целиком, весь текст.
        let lines = text.lineRange(for: selection)
        steps.append(trimmed(text, lines))
        steps.append(lines)
        steps.append(NSRange(location: 0, length: length))

        let unique = Set(steps.filter { contains($0, selection) && $0.length > selection.length }
            .map { [$0.location, $0.length] })
        return unique.map { NSRange(location: $0[0], length: $0[1]) }
            .sorted { $0.length != $1.length ? $0.length < $1.length : $0.location < $1.location }
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        outer.location <= inner.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// Содержимое кавычек на той же строке, что выделение.
    private static func quoted(_ text: NSString, selection: NSRange, quote: unichar, within line: NSRange) -> NSRange? {
        var open: Int?
        var i = line.location
        while i < NSMaxRange(line) {
            let c = text.character(at: i)
            if c == 0x5C { i += 2; continue }   // \" внутри строки
            if c == quote {
                if let start = open {
                    let inner = NSRange(location: start + 1, length: i - start - 1)
                    if contains(NSRange(location: start, length: i - start + 1), selection),
                       contains(inner, selection) || inner.length == 0 {
                        return inner.length > 0 ? inner : nil
                    }
                    open = nil
                } else {
                    open = i
                }
            }
            i += 1
        }
        return nil
    }

    /// Ближайшая пара скобок, строго охватывающая `range`.
    private static func enclosingBrackets(_ text: NSString, around range: NSRange) -> NSRange? {
        let opens: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
        let closes: [unichar: unichar] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
        // Назад до непарной открывающей.
        var depth: [unichar] = []
        var i = range.location - 1
        var open: (offset: Int, char: unichar)?
        while i >= 0 {
            let c = text.character(at: i)
            if let partner = closes[c] {
                depth.append(partner)
            } else if opens[c] != nil {
                if depth.last == c { depth.removeLast() } else { open = (i, c); break }
            }
            i -= 1
        }
        guard let open, let closing = opens[open.char] else { return nil }
        // Вперёд до парной закрывающей.
        var level = 0
        var j = NSMaxRange(range)
        while j < text.length {
            let c = text.character(at: j)
            if c == open.char {
                level += 1
            } else if c == closing {
                if level == 0 { return NSRange(location: open.offset, length: j - open.offset + 1) }
                level -= 1
            }
            j += 1
        }
        return nil
    }

    private static func trimmed(_ text: NSString, _ range: NSRange) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        let blank: (unichar) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        while start < end, blank(text.character(at: start)) { start += 1 }
        while end > start, blank(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
}
