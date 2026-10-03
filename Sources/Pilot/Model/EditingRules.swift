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

    // MARK: - Начало строки

    /// ⌘←: куда встать в строке `line` (без перевода строки), если курсор
    /// на `column`. Сперва к первому непробельному символу, оттуда —
    /// в самое начало, как Home в Rider и Xcode.
    static func smartLineStart(_ line: String, column: Int) -> Int {
        let indent = line.utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
        return column == indent ? 0 : indent
    }

    // MARK: - Вставка

    /// Вставка нескольких строк встаёт на отступ места вставки, сохраняя
    /// отступы строк друг относительно друга, — как «Reformat on paste:
    /// indent block» в Rider. Строка с отступом, вставленная после отступа,
    /// свой теряет. `text` — с переводами строк `\n`; `linePrefix` и
    /// `lineSuffix` — строка вокруг вставки; `previousLine` — ближайшая
    /// непустая строка выше; `firstLineIndent` — отступ (в колонках) строки,
    /// с которой скопирована первая, если Pilot его запомнил при копировании.
    /// `nil` — вставлять как есть.
    static func pasteReindented(_ text: String, linePrefix: String, lineSuffix: String,
                                previousLine: String?, indentUnit: String,
                                colonOpensBlock: Bool, firstLineIndent: Int? = nil) -> String? {
        let lines = text.components(separatedBy: "\n")
        let head = lines[0].drop { $0 == " " || $0 == "\t" }
        let isBlank = { (s: Substring) in s.allSatisfy { $0 == " " || $0 == "\t" } }
        let tabWidth = indentUnit == "\t" ? 4 : max(1, indentUnit.count)
        let width = { (s: Substring) in s.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? tabWidth : 1) } }

        // После кода в строке первая строка остаётся как есть.
        let afterCode = !isBlank(linePrefix[...])
        if lines.count == 1 {
            guard !afterCode else { return nil }
            if !linePrefix.isEmpty || !isBlank(lineSuffix[...]) {
                return head.count == lines[0].count ? nil : String(head)
            }
        }

        // Отступ, на который встаёт вставка.
        let target: String
        if afterCode {
            target = String(linePrefix.prefix { $0 == " " || $0 == "\t" })
        } else if !linePrefix.isEmpty {
            target = linePrefix
        } else {
            var indent = previousLine.map { String($0.prefix { $0 == " " || $0 == "\t" }) } ?? ""
            let last = previousLine?.trimmingCharacters(in: .whitespaces).last
            if last == "{" || last == "(" || last == "[" || (colonOpensBlock && last == ":") { indent += indentUnit }
            if let first = head.first, first == "}" || first == ")" || first == "]" {
                indent = String(indent.dropLast(dedentBeforeClosing(linePrefix: indent, indentUnit: indentUnit)))
            }
            target = indent
        }
        if lines.count == 1 { return target + head == text ? nil : target + head }

        // Отступ блока в источнике: самый малый у строк после первой. Первая
        // строка без отступа взята с середины строки, и её отступ неизвестен,
        // если его не запомнили при копировании; если она открывает скобку, а
        // закрывающей на этом отступе нет, остальные строки — на уровень
        // глубже неё.
        let rest = lines.dropFirst().filter { !isBlank($0[...]) }
        var base = rest.map { width($0[...]) }.min() ?? 0
        if head.count != lines[0].count, !head.isEmpty {
            base = min(base, width(lines[0][...]))
        } else if let firstLineIndent, !head.isEmpty {
            base = min(base, firstLineIndent)
        } else if let last = head.trimmingCharacters(in: .whitespaces).last, "{([".contains(last),
                  !rest.contains(where: { width($0[...]) == base && "})]".contains($0.trimmingCharacters(in: .whitespaces).first ?? " ") }) {
            base = max(0, base - tabWidth)
        }

        let render = { (columns: Int) -> String in
            indentUnit == "\t"
                ? String(repeating: "\t", count: columns / tabWidth) + String(repeating: " ", count: columns % tabWidth)
                : String(repeating: " ", count: columns)
        }
        var out = [(afterCode ? lines[0] : (linePrefix.isEmpty ? target : "") + head)]
        for (i, line) in lines.enumerated().dropFirst() {
            if isBlank(line[...]) {
                // Последняя пустая — отступ для того, что в строке после вставки.
                let followed = i == lines.count - 1 && !(lineSuffix.first.map { $0 == " " || $0 == "\t" } ?? true)
                out.append(followed ? target : "")
            } else {
                out.append(target + render(max(0, width(line[...]) - base)) + line.drop { $0 == " " || $0 == "\t" })
            }
        }
        let result = out.joined(separator: "\n")
        return result == text ? nil : result
    }

    /// Правка форматтера меняет только отступ: пробелы и табы в начале
    /// строки (с переводами строк перед ним — без изменения их числа).
    /// Пробелы между словами, перенос скобок и хвосты строк — мимо: при
    /// вставке Rider по умолчанию правит одни отступы.
    static func isIndentEdit(in text: NSString, range: NSRange, replacement: String) -> Bool {
        guard NSMaxRange(range) <= text.length else { return false }
        let old = text.substring(with: range)
        let isSpace = { (c: Character) in c == " " || c == "\t" || c == "\n" || c == "\r" }
        guard old.allSatisfy(isSpace), replacement.allSatisfy(isSpace),
              old.filter({ $0 == "\n" }).count == replacement.filter({ $0 == "\n" }).count else { return false }
        // Кончается правка перед текстом строки, а не перед её концом.
        let end = NSMaxRange(range)
        guard end < text.length, ![0x0A, 0x0D, 0x20, 0x09].contains(text.character(at: end)) else { return false }
        if old.contains("\n") { return true }
        // Без перевода строки — от начала строки до правки одни пробелы.
        var i = range.location
        while i > 0 {
            let c = text.character(at: i - 1)
            if c == 0x0A { break }
            if c != 0x20 && c != 0x09 { return false }
            i -= 1
        }
        return true
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
