import Foundation

/// Парные скобки и кавычки при наборе, как в Rider и VS Code:
/// `(` ставит и `)`, курсор между ними; набранная `)` перед такой же
/// просто перешагивает её; Backspace в пустой паре `(|)` стирает обе;
/// скобка или кавычка поверх выделения оборачивает его.
///
/// Без AppKit: редактор спрашивает, что сделать с набранным, и применяет
/// ответ одной правкой. nil — обычный ввод.
enum AutoPairs {
    static let brackets: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    static let closers: Set<Character> = [")", "]", "}"]

    /// Кавычки языка — строки, которые открывает и закрывает один и тот же
    /// символ: `"`, `'` (кроме Rust, где это ещё и время жизни), `` ` ``.
    static func quotes(for spec: LanguageSpec?) -> Set<Character> {
        guard let spec else { return [] }
        var out: Set<Character> = []
        for string in spec.strings where string.open.count == 1 && string.open == string.close {
            out.insert(Character(Unicode.Scalar(string.open[0])))
        }
        return out
    }

    /// Что сделать с набранным `typed` при выделении `selection`.
    static func typing(_ typed: String, in text: NSString, selection: NSRange,
                       quotes: Set<Character>) -> LineEditing.Edit? {
        guard typed.count == 1, let c = typed.first else { return nil }
        let isQuote = quotes.contains(c)
        let closing = brackets[c] ?? (isQuote ? c : nil)

        // Поверх выделения — обернуть и оставить выделенным то же самое.
        if selection.length > 0 {
            guard let closing else { return nil }
            let inner = text.substring(with: selection)
            return LineEditing.Edit(range: selection, text: String(c) + inner + String(closing),
                                    selection: NSRange(location: selection.location + 1, length: selection.length))
        }

        let next = character(in: text, at: selection.location)
        let previous = character(in: text, at: selection.location - 1)
        let caretAfter = NSRange(location: selection.location + 1, length: 0)

        // Закрывающая перед такой же — перешагнуть, а не удвоить.
        if closers.contains(c) || isQuote, next == c {
            return LineEditing.Edit(range: NSRange(location: selection.location, length: 1), text: String(c),
                                    selection: caretAfter)
        }

        guard let closing else { return nil }
        // Пару ставим, только если за курсором ничего, что стало бы
        // содержимым: пробел, конец строки, закрывающая, разделитель.
        guard next.map(allowsPairBefore) ?? true else { return nil }
        if isQuote {
            // `don't`, `a"` — кавычка закрывает или стоит внутри слова;
            // `""|` → `"""` — начало сырой строки C# и Python, пара не нужна.
            if let previous, previous.isLetter || previous.isNumber || previous == "_" || previous == c
                || previous == "\\" { return nil }
        }
        return LineEditing.Edit(range: selection, text: String(c) + String(closing), selection: caretAfter)
    }

    /// Backspace в пустой паре — стереть обе половины. nil — обычный Backspace.
    static func deletingBackward(in text: NSString, selection: NSRange, quotes: Set<Character>) -> LineEditing.Edit? {
        guard selection.length == 0, selection.location > 0,
              let previous = character(in: text, at: selection.location - 1),
              let next = character(in: text, at: selection.location) else { return nil }
        let closing = brackets[previous] ?? (quotes.contains(previous) ? previous : nil)
        guard let closing, next == closing else { return nil }
        return LineEditing.Edit(range: NSRange(location: selection.location - 1, length: 2), text: "",
                                selection: NSRange(location: selection.location - 1, length: 0))
    }

    private static func allowsPairBefore(_ next: Character) -> Bool {
        next.isWhitespace || closers.contains(next) || next == "," || next == ";" || next == ":"
    }

    /// Один UTF-16 символ; суррогатные пары и конец текста — nil.
    private static func character(in text: NSString, at index: Int) -> Character? {
        guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else { return nil }
        return Character(scalar)
    }
}
