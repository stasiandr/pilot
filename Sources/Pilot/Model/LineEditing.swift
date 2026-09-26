import Foundation

/// Правки целыми строками: дублировать, удалить, переставить. Всё над
/// текстом и выделением, без AppKit, — редактор только применяет результат
/// одной правкой, одним шагом ⌘Z.
enum LineEditing {

    /// Что заменить, на что, и где потом оставить выделение.
    struct Edit: Equatable {
        var range: NSRange
        var text: String
        var selection: NSRange
    }

    /// Строки, которые задевает выделение, вместе с переводом последней.
    /// Выделение, кончающееся в начале строки, эту строку не захватывает.
    static func lineBlock(_ text: NSString, selection: NSRange) -> NSRange {
        var selection = selection
        if selection.length > 0, isNewline(text.character(at: NSMaxRange(selection) - 1)) {
            selection.length -= 1
        }
        return text.lineRange(for: selection)
    }

    /// ⌘D. Без выделения — строка (или строки) ещё раз под собой, курсор
    /// в копии на том же месте; с выделением — выделенное ещё раз сразу за
    /// собой, выделена копия.
    static func duplicate(_ text: NSString, selection: NSRange) -> Edit {
        if selection.length > 0 && !spansLines(text, selection) {
            let copy = text.substring(with: selection)
            return Edit(range: NSRange(location: NSMaxRange(selection), length: 0), text: copy,
                        selection: NSRange(location: NSMaxRange(selection), length: selection.length))
        }
        let block = lineBlock(text, selection: selection)
        var copy = text.substring(with: block)
        var insertAt = NSMaxRange(block)
        var shift = block.length
        if !endsWithNewline(copy) {
            // Последняя строка файла без перевода: копия встаёт после
            // перевода, который добавляем сами.
            let newline = separator(in: text)
            copy = newline + copy
            shift = (copy as NSString).length
            insertAt = NSMaxRange(block)
        }
        return Edit(range: NSRange(location: insertAt, length: 0), text: copy,
                    selection: NSRange(location: selection.location + shift, length: selection.length))
    }

    /// ⌘⌫ — строки выделения целиком. Курсор — в начало строки, что встала
    /// на их место.
    static func deleteLines(_ text: NSString, selection: NSRange) -> Edit {
        var block = lineBlock(text, selection: selection)
        // Последняя строка без перевода: забираем перевод перед ней, иначе
        // в конце файла осталась бы пустая строка.
        if NSMaxRange(block) == text.length, block.location > 0,
           !endsWithNewline(text.substring(with: block)) {
            var start = block.location - 1
            if start > 0, text.character(at: start) == 0x0A, text.character(at: start - 1) == 0x0D { start -= 1 }
            block = NSRange(location: start, length: NSMaxRange(block) - start)
            let previous = text.lineRange(for: NSRange(location: start, length: 0))
            return Edit(range: block, text: "", selection: NSRange(location: previous.location, length: 0))
        }
        return Edit(range: block, text: "", selection: NSRange(location: block.location, length: 0))
    }

    /// ⌥⇧↑ / ⌥⇧↓ — строки выделения на одну вверх или вниз, выделение едет
    /// с ними. `nil` — двигать некуда.
    static func moveLines(_ text: NSString, selection: NSRange, up: Bool) -> Edit? {
        let block = lineBlock(text, selection: selection)
        let newline = separator(in: text)
        let neighbour: NSRange
        if up {
            guard block.location > 0 else { return nil }
            neighbour = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
        } else {
            guard NSMaxRange(block) < text.length else { return nil }
            neighbour = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        }
        let region = NSUnionRange(block, neighbour)
        let finalNewline = endsWithNewline(text.substring(with: region))
        let moving = lines(text.substring(with: block))
        let other = lines(text.substring(with: neighbour))
        let reordered = up ? moving + other : other + moving
        let replacement = reordered.joined(separator: newline) + (finalNewline ? newline : "")
        let blockStart = up
            ? region.location
            : region.location + (other.joined(separator: newline) as NSString).length + (newline as NSString).length
        return Edit(range: region, text: replacement,
                    selection: NSRange(location: blockStart + (selection.location - block.location),
                                       length: selection.length))
    }

    /// ⌃⇧J, как в Rider. Без выделения — следующая строка приклеивается
    /// к текущей; с выделением на несколько строк — все его строки в одну.
    /// Отступ приклеенной строки уходит, между ними — один пробел (его нет,
    /// если приклеилась пустая строка или закрывающая скобка к открывающей).
    /// Курсор — в месте последней склейки. nil — клеить не с чем.
    static func joinLines(_ text: NSString, selection: NSRange) -> Edit? {
        var block = lineBlock(text, selection: selection)
        if !spansLines(text, NSRange(location: block.location, length: max(0, block.length - 1))) {
            // Одна строка: берём и следующую.
            guard NSMaxRange(block) < text.length else { return nil }
            block = NSUnionRange(block, text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0)))
        }
        let body = text.substring(with: block)
        let finalNewline = endsWithNewline(body)
        let parts = lines(body)
        guard parts.count > 1 else { return nil }
        var joined = parts[0]
        var caret = 0
        for part in parts.dropFirst() {
            let trimmed = String(part.drop { $0 == " " || $0 == "\t" })
            while joined.hasSuffix(" ") || joined.hasSuffix("\t") { joined.removeLast() }
            caret = (joined as NSString).length
            let hugs = joined.last.map { "([{".contains($0) } == true && trimmed.first.map { ")]}".contains($0) } == true
            let glue = trimmed.isEmpty || joined.isEmpty || hugs ? "" : " "
            joined += glue + trimmed
        }
        let newline = finalNewline ? (body.hasSuffix("\r\n") ? "\r\n" : "\n") : ""
        return Edit(range: block, text: joined + newline,
                    selection: NSRange(location: block.location + caret, length: 0))
    }

    /// ⌘⇧U: есть строчные — всё заглавными, иначе строчными. Без
    /// выделения — слово под курсором. Выделение остаётся на изменённом.
    static func toggleCase(_ text: NSString, selection: NSRange) -> Edit? {
        let range = selection.length > 0 ? selection : word(in: text, at: selection.location)
        guard let range, range.length > 0 else { return nil }
        let original = text.substring(with: range)
        let changed = original.contains(where: \.isLowercase) ? original.uppercased() : original.lowercased()
        guard changed != original else { return nil }
        // Длина может измениться (`ß` → `SS`) — выделение по новому тексту.
        return Edit(range: range, text: changed,
                    selection: NSRange(location: range.location, length: (changed as NSString).length))
    }

    /// Слово (буквы, цифры, `_`) вокруг позиции: курсор внутри или сразу после.
    static func word(in text: NSString, at location: Int) -> NSRange? {
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        var start = location, end = location
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// ⌘L: `42`, `42:7`, `42,7`, `:42` — строка и столбец с единицы.
    /// Вернёт с нуля; столбец не указан — nil. Не число — nil целиком.
    static func lineTarget(_ input: String) -> (line: Int, column: Int?)? {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(":") { s.removeFirst() }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "," || $0 == " " }).map(String.init)
        guard let first = parts.first, let line = Int(first), line > 0, parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard let column = Int(parts[1]), column > 0 else { return nil }
            return (line - 1, column - 1)
        }
        return (line - 1, nil)
    }

    // MARK: - Внутреннее

    private static func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    /// По UTF-16, а не по символам: `\r\n` для Swift — один символ, и
    /// `hasSuffix("\n")` его не видит.
    private static func endsWithNewline(_ s: String) -> Bool {
        s.utf16.last.map(isNewline) ?? false
    }

    private static func spansLines(_ text: NSString, _ selection: NSRange) -> Bool {
        text.rangeOfCharacter(from: .newlines, options: [], range: selection).location != NSNotFound
    }

    /// Перевод строки файла: какой уже есть, по первому.
    private static func separator(in text: NSString) -> String {
        let at = text.range(of: "\n", options: .literal)
        guard at.location != NSNotFound else { return "\n" }
        return at.location > 0 && text.character(at: at.location - 1) == 0x0D ? "\r\n" : "\n"
    }

    /// Строки без переводов.
    private static func lines(_ block: String) -> [String] {
        var units = Array(block.utf16)
        if units.last == 0x0A { units.removeLast() }
        if units.last == 0x0D { units.removeLast() }
        let body = String(decoding: units, as: UTF16.self) as NSString
        let crlf = body.range(of: "\r\n", options: .literal).location != NSNotFound
        return body.components(separatedBy: crlf ? "\r\n" : "\n")
    }
}
