import Foundation

/// Правила редактирования, которым не нужен AppKit: что вставить по Return,
/// как сдвинуть и закомментировать строки. Отдельно — чтобы их проверяли
/// тесты, а не руки.
enum EditingRules {

    // MARK: - Свойства файла

    /// Единица отступа файла. Таб, если отступы в файле табами; иначе самый
    /// частый шаг отступа в пробелах. Смотрим первые пару тысяч строк —
    /// дальше картина не меняется.
    static func indentUnit(in units: [UInt16], sampleLines: Int = 2000) -> String {
        var tabs = 0, spaced = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var i = 0, line = 0
        let n = units.count
        while i < n, line < sampleLines {
            var spaces = 0
            let first = units[i]
            while i < n, units[i] == 0x20 { spaces += 1; i += 1 }
            let blank = i >= n || units[i] == 0x0A || units[i] == 0x0D
            if !blank {
                if first == 0x09 { tabs += 1 }
                else if spaces > 0 {
                    spaced += 1
                    let step = abs(spaces - previous)
                    if step >= 2 && step <= 8 { steps[step, default: 0] += 1 }
                }
                if first != 0x09 { previous = spaces }
            }
            while i < n, units[i] != 0x0A { i += 1 }
            i += 1
            line += 1
        }
        if tabs > spaced { return "\t" }
        let width = steps.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? 4
        return String(repeating: " ", count: width)
    }

    /// Перевод строки файла: CRLF, если им кончается первая же строка.
    static func lineEnding(in units: [UInt16]) -> String {
        guard let lf = units.firstIndex(of: 0x0A) else { return "\n" }
        return lf > 0 && units[lf - 1] == 0x0D ? "\r\n" : "\n"
    }

    // MARK: - Return

    struct Insertion: Equatable {
        var text: String
        /// Куда поставить курсор — смещение внутри `text` в UTF-16.
        var caret: Int
    }

    /// Что вставить по Return. Отступ — как у текущей строки; после
    /// открывающей скобки (в Python — после «:») — на уровень глубже.
    /// Если курсор стоит между `{` и `}`, скобка уезжает на свою строку:
    /// `{|}` → `{`, строка с курсором, `}`.
    static func newline(linePrefix: String, lineSuffix: String,
                        indentUnit: String, lineEnding: String,
                        colonOpensBlock: Bool) -> Insertion {
        let indent = String(linePrefix.prefix { $0 == " " || $0 == "\t" })
        let before = linePrefix.trimmingCharacters(in: .whitespaces)
        let after = lineSuffix.trimmingCharacters(in: .whitespaces)
        let last = before.last

        var opens = last == "{" || last == "(" || last == "["
        if colonOpensBlock && last == ":" { opens = true }
        guard opens else {
            let text = lineEnding + indent
            return Insertion(text: text, caret: text.utf16.count)
        }

        let inner = lineEnding + indent + indentUnit
        let closes = after.first.map { pairs[last!] == $0 } ?? false
        if closes {
            return Insertion(text: inner + lineEnding + indent, caret: inner.utf16.count)
        }
        return Insertion(text: inner, caret: inner.utf16.count)
    }

    private static let pairs: [Character: Character] = ["{": "}", "(": ")", "[": "]"]

    /// Отступ для `}`, набранной в пустой строке: как у строки с парной `{`.
    /// Скобки ищем простым счётом назад (строки и комментарии не различаем —
    /// для выравнивания этого хватает); не нашли за разумное расстояние — nil.
    static func closingBraceIndent(in units: [UInt16], before caret: Int, scanLimit: Int = 200_000) -> String? {
        var depth = 0
        var i = min(caret, units.count) - 1
        let stop = max(0, caret - scanLimit)
        while i >= stop {
            let c = units[i]
            if c == 0x7D { depth += 1 }
            else if c == 0x7B {
                if depth == 0 {
                    var lineStart = i
                    while lineStart > 0, units[lineStart - 1] != 0x0A { lineStart -= 1 }
                    var end = lineStart
                    while end < i, units[end] == 0x20 || units[end] == 0x09 { end += 1 }
                    return String(decoding: units[lineStart..<end], as: UTF16.self)
                }
                depth -= 1
            }
            i -= 1
        }
        return nil
    }

    /// Сколько символов отступа снять перед закрывающей скобкой, набранной
    /// в начале строки: `    }` внутри блока встаёт на уровень блока.
    /// Запасной вариант, когда парная скобка не нашлась.
    static func dedentBeforeClosing(linePrefix: String, indentUnit: String) -> Int {
        guard !linePrefix.isEmpty, linePrefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { return 0 }
        if linePrefix.hasSuffix("\t") { return 1 }
        let spaces = linePrefix.reversed().prefix { $0 == " " }.count
        let unit = max(1, indentUnit == "\t" ? 4 : indentUnit.count)
        return min(spaces, unit)
    }

    /// Backspace в отступе из пробелов стирает до предыдущей позиции
    /// табуляции, а не по одному пробелу.
    static func backspaceWidth(linePrefix: String, indentUnit: String) -> Int {
        guard indentUnit != "\t", !linePrefix.isEmpty, linePrefix.allSatisfy({ $0 == " " }) else { return 1 }
        let unit = indentUnit.count
        let remainder = linePrefix.count % unit
        return remainder == 0 ? unit : remainder
    }

    // MARK: - Строки целиком

    /// Сдвиг вправо: единица отступа в начало каждой непустой строки.
    static func indent(_ lines: [String], unit: String) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : unit + $0 }
    }

    /// Сдвиг влево: снять до одной единицы отступа (таб или пробелы).
    static func outdent(_ lines: [String], unit: String) -> [String] {
        let width = unit == "\t" ? 4 : unit.count
        return lines.map { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(spaces, width)))
        }
    }

    /// ⌘/: если все непустые строки уже закомментированы — раскомментировать,
    /// иначе закомментировать все на общем минимальном отступе, как в Xcode.
    static func toggleComment(_ lines: [String], token: String) -> [String] {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return lines }

        let allCommented = content.allSatisfy {
            $0.drop { $0 == " " || $0 == "\t" }.hasPrefix(token)
        }
        if allCommented {
            return lines.map { line in
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                var rest = line.dropFirst(indent.count)
                guard rest.hasPrefix(token) else { return line }
                rest = rest.dropFirst(token.count)
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                return String(indent) + rest
            }
        }

        let minIndent = content.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            let head = line.prefix(minIndent)
            return head + token + " " + line.dropFirst(minIndent)
        }
    }
}
