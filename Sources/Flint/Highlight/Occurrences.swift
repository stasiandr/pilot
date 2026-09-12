import Foundation

/// Поиск вхождений идентификатора в файле — без языкового сервера.
///
/// Сначала быстрый побайтовый проход по всему документу с проверкой границ
/// слова, затем уточнение: строки с попаданиями (их всегда мало) лексятся,
/// и совпадения внутри строк и комментариев отбрасываются. Так мы не платим
/// за лексацию всего файла, но и не подсвечиваем слово в комментарии.
enum Occurrences {

    static let limit = 4000

    /// Идентификатор под указанным смещением.
    static func identifier(in model: SyntaxModel, at offset: Int) -> (text: String, range: NSRange)? {
        let units = model.units
        guard !units.isEmpty else { return nil }
        var index = max(0, min(offset, units.count - 1))

        // Курсор мог встать сразу ЗА словом — тогда берём слово слева.
        if !isIdentifierPart(units[index]) {
            guard index > 0, isIdentifierPart(units[index - 1]) else { return nil }
            index -= 1
        }
        var start = index
        while start > 0, isIdentifierPart(units[start - 1]) { start -= 1 }
        var end = index
        while end + 1 < units.count, isIdentifierPart(units[end + 1]) { end += 1 }

        guard isIdentifierStart(units[start]) else { return nil }
        let text = String(decoding: units[start...end], as: UTF16.self)
        return (text, NSRange(location: start, length: end - start + 1))
    }

    /// Все вхождения слова как самостоятельного идентификатора.
    static func find(_ word: String, in model: SyntaxModel) -> [NSRange] {
        let needle = Array(word.utf16)
        guard !needle.isEmpty else { return [] }
        let units = model.units
        guard units.count >= needle.count else { return [] }

        // 1. Быстрый проход: совпадение по содержимому + границы слова.
        var raw: [Int] = []
        let first = needle[0]
        let lastIndex = units.count - needle.count
        var i = 0
        while i <= lastIndex {
            if units[i] == first {
                var k = 1
                while k < needle.count, units[i + k] == needle[k] { k += 1 }
                if k == needle.count {
                    let beforeOK = i == 0 || !isIdentifierPart(units[i - 1])
                    let afterIndex = i + needle.count
                    let afterOK = afterIndex >= units.count || !isIdentifierPart(units[afterIndex])
                    if beforeOK && afterOK {
                        raw.append(i)
                        if raw.count >= limit { break }
                        i = afterIndex
                        continue
                    }
                }
            }
            i += 1
        }
        guard !raw.isEmpty else { return [] }
        guard model.spec != nil else {
            return raw.map { NSRange(location: $0, length: needle.count) }
        }

        // 2. Уточнение: лексим только строки, где что-то нашлось.
        var result: [NSRange] = []
        result.reserveCapacity(raw.count)
        var position = 0
        while position < raw.count {
            let line = model.line(containing: raw[position])
            var upper = position
            while upper < raw.count, model.line(containing: raw[upper]) == line { upper += 1 }

            let tokens = model.tokens(fromLine: line, toLine: line)
            for hit in raw[position..<upper] {
                if let token = tokens.first(where: { Int($0.start) == hit }),
                   Int(token.length) == needle.count,
                   isCodeToken(token.kind) {
                    result.append(NSRange(location: hit, length: needle.count))
                }
            }
            position = upper
        }
        return result
    }

    /// Похоже ли вхождение на объявление: слева стоит тип или вводное слово.
    ///
    /// Это эвристика для локальных переменных и параметров — там, где
    /// структуры файла недостаточно, а языкового сервера может не быть.
    static func looksLikeDeclaration(_ range: NSRange, in model: SyntaxModel) -> Bool {
        let line = model.line(containing: range.location)
        let tokens = model.tokens(fromLine: line, toLine: line)
        guard let index = tokens.firstIndex(where: { Int($0.start) == range.location }) else {
            return false
        }
        guard index > 0 else { return false }

        let previous = tokens[index - 1]
        let text = String(decoding: model.units[Int(previous.start)..<Int(previous.start + previous.length)],
                          as: UTF16.self)

        // Вводные слова объявлений в разных языках.
        if ["var", "let", "val", "const", "in", "out", "ref", "params",
            "foreach", "for", "using", "catch", "as", "def", "fn", "func"].contains(text) {
            return true
        }
        // `Тип имя` — слева тип или закрытый дженерик/массив.
        if previous.kind == .type { return true }
        if previous.length == 1 {
            let ch = model.units[Int(previous.start)]
            if ch == 0x3E || ch == 0x5D { return true }   // > ]
        }
        return false
    }

    @inline(__always)
    private static func isCodeToken(_ kind: TokenKind) -> Bool {
        switch kind {
        case .comment, .docComment, .string, .number: return false
        default: return true
        }
    }

    @inline(__always)
    private static func isIdentifierPart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x24 || c > 0x7F
    }

    @inline(__always)
    private static func isIdentifierStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F
    }
}
