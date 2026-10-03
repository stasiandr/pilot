import Foundation

/// Курсор с выделением: `anchor` — где выделение начато, `head` — где
/// курсор сейчас. Позиции — в UTF-16, как у NSString.
struct Caret: Equatable {
    var anchor: Int
    var head: Int

    init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    init(_ range: NSRange) {
        self.init(anchor: range.location, head: NSMaxRange(range))
    }

    init(at position: Int) {
        self.init(anchor: position, head: position)
    }

    var range: NSRange { NSRange(location: min(anchor, head), length: abs(head - anchor)) }
    var isEmpty: Bool { anchor == head }
}

/// Несколько курсоров, как в Rider: правила без AppKit — что сливается,
/// куда уезжает при правке, какое вхождение следующее.
enum MultiCaret {

    /// По порядку в тексте; совпавшие и пересекающиеся сливаются в один.
    /// `primary` — индекс основного курсора (добавленного последним); слитый
    /// с ним остаётся основным.
    static func merged(_ carets: [Caret], primary: Int) -> (carets: [Caret], primary: Int) {
        guard !carets.isEmpty else { return ([], 0) }
        let order = carets.indices.sorted {
            let a = carets[$0].range, b = carets[$1].range
            return a.location != b.location ? a.location < b.location : a.length < b.length
        }
        var result: [Caret] = []
        var resultPrimary = 0
        for index in order {
            let caret = carets[index]
            if let last = result.last {
                let a = last.range, b = caret.range
                let touches = b.location < NSMaxRange(a)
                    || (b.location == NSMaxRange(a) && (a.length == 0 || b.length == 0))
                if touches {
                    let union = NSUnionRange(a, b)
                    // Направление — как у того, кто тянет выделение дальше.
                    let backward = (index == primary ? caret : last).head < (index == primary ? caret : last).anchor
                    result[result.count - 1] = backward
                        ? Caret(anchor: NSMaxRange(union), head: union.location)
                        : Caret(anchor: union.location, head: NSMaxRange(union))
                    if index == primary { resultPrimary = result.count - 1 }
                    continue
                }
            }
            result.append(caret)
            if index == primary { resultPrimary = result.count - 1 }
        }
        return (result, resultPrimary)
    }

    /// Куда уезжает позиция после правки: на месте `location` было `from`
    /// символов, стало `to`. Позиция внутри заменённого — к концу вставки.
    static func shift(_ position: Int, byEditAt location: Int, from: Int, to: Int) -> Int {
        if position < location { return position }
        if position >= location + from { return position + to - from }
        return location + min(position - location, to)
    }

    static func shift(_ caret: Caret, byEditAt location: Int, from: Int, to: Int) -> Caret {
        Caret(anchor: shift(caret.anchor, byEditAt: location, from: from, to: to),
              head: shift(caret.head, byEditAt: location, from: from, to: to))
    }

    // MARK: - Вхождения

    static func isWordUnit(_ u: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return false }
        return u == 0x5F || CharacterSet.alphanumerics.contains(scalar)
    }

    /// Слово (имя) под курсором или прямо перед ним.
    static func word(in text: NSString, at position: Int) -> NSRange? {
        var start = min(position, text.length), end = start
        while start > 0, isWordUnit(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWordUnit(text.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        (range.location == 0 || !isWordUnit(text.character(at: range.location - 1)))
            && (NSMaxRange(range) >= text.length || !isWordUnit(text.character(at: NSMaxRange(range))))
    }

    /// Все вхождения `needle` с учётом регистра; `wholeWord` — только целым словом.
    static func occurrences(of needle: String, in text: NSString, wholeWord: Bool) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var result: [NSRange] = []
        var from = 0
        while from < text.length {
            let found = text.range(of: needle, options: .literal, range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { break }
            if !wholeWord || isWholeWord(found, in: text) { result.append(found) }
            from = found.location + max(1, found.length)
        }
        return result
    }

    /// Следующее за `after` вхождение, которого ещё нет среди `taken`; за
    /// концом файла — с начала. `nil` — все уже выделены.
    static func nextOccurrence(of needle: String, in text: NSString, after: Int,
                               wholeWord: Bool, taken: [NSRange]) -> NSRange? {
        let all = occurrences(of: needle, in: text, wholeWord: wholeWord).filter { !taken.contains($0) }
        return all.first { $0.location >= after } ?? all.first
    }

    // MARK: - Строки

    /// Курсор в конце каждой строки выделения (⌥⇧G в Rider). Строка, в
    /// начале которой выделение кончается, не считается.
    static func lineEnds(in text: NSString, selection: NSRange) -> [Caret] {
        var end = NSMaxRange(selection)
        if selection.length > 0, end > 0, text.character(at: end - 1) == 0x0A { end -= 1 }
        var result: [Caret] = []
        var position = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        repeat {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            result.append(Caret(at: contentEnd(of: line, in: text)))
            position = NSMaxRange(line)
        } while position < end
        return result
    }

    static func contentEnd(of line: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    /// Курсор на строку выше или ниже `caret` в той же колонке (короче —
    /// в конец строки). `nil` — выше или ниже строк нет.
    static func cloned(_ caret: Caret, in text: NSString, up: Bool) -> Caret? {
        let line = text.lineRange(for: NSRange(location: caret.head, length: 0))
        let column = caret.head - line.location
        let target: NSRange
        if up {
            guard line.location > 0 else { return nil }
            target = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
        } else {
            guard NSMaxRange(line) < text.length
                    || (NSMaxRange(line) == text.length && NSMaxRange(line) > line.location
                        && text.character(at: NSMaxRange(line) - 1) == 0x0A) else { return nil }
            target = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        }
        return Caret(at: min(target.location + column, contentEnd(of: target, in: text)))
    }

    // MARK: - Буфер обмена

    /// Вставка, когда курсоров несколько: строк в буфере столько же, сколько
    /// курсоров, — каждому по строке, иначе всем весь текст (`nil`).
    static func pieces(_ text: String, count: Int) -> [String]? {
        guard count > 1 else { return nil }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count == count + 1, lines.last == "" { lines.removeLast() }
        return lines.count == count ? lines : nil
    }
}
