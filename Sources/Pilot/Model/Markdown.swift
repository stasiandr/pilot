import Foundation

/// Markdown → HTML для просмотра README и документации.
///
/// CommonMark с расширениями GitHub, которые реально встречаются в
/// репозиториях: таблицы, списки задач, зачёркивание, голые ссылки,
/// плашки `> [!NOTE]`, front matter. Не полный CommonMark: вложенность
/// выделения и ленивые продолжения разобраны попроще — документация
/// так не пишется.
///
/// У каждого блока — `data-line` с номером строки исходника (с нуля):
/// по нему просмотр прокручивается к месту из структуры файла, а двойной
/// клик открывает исходник на этой строке.
enum Markdown {

    static func html(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n").enumerated().map { number, text in
            Line(text: expandTabs(text.hasSuffix("\r") ? String(text.dropLast()) : text), number: number)
        }
        var renderer = Renderer()
        var out = ""
        if let (frontMatter, rest) = splitFrontMatter(lines) {
            out += "<pre class=\"front-matter\" data-line=\"0\"><code>"
                + highlight(frontMatter.map(\.text).joined(separator: "\n"), language: "yaml")
                + "</code></pre>\n"
            lines = rest
        }
        lines = renderer.collectReferences(lines)
        out += renderer.blocks(lines[...], tight: false)
        return out
    }

    /// Заголовки для структуры файла: уровень, текст, строка.
    static func headings(_ source: String) -> [(level: Int, title: String, line: Int)] {
        var result: [(Int, String, Int)] = []
        var fence: (char: Character, count: Int)?
        var previous: (text: String, line: Int)?
        for (number, raw) in source.components(separatedBy: "\n").enumerated() {
            let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let f = fence {
                if let close = fenceOpening(text), close.char == f.char, close.count >= f.count, close.info.isEmpty {
                    fence = nil
                }
                previous = nil
                continue
            }
            if let open = fenceOpening(text) {
                fence = (open.char, open.count)
                previous = nil
                continue
            }
            if let heading = atxHeading(text) {
                result.append((heading.level, plainText(heading.text), number))
                previous = nil
            } else if let prev = previous, let level = setextLevel(text) {
                result.append((level, plainText(prev.text), prev.line))
                previous = nil
            } else {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                previous = trimmed.isEmpty || indent(of: text) >= 4 ? nil : (trimmed, number)
            }
        }
        return result
    }

    // MARK: - Строки

    struct Line {
        var text: String
        var number: Int
    }

    static func expandTabs(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        var out = ""
        var column = 0
        for c in s {
            if c == "\t" {
                let spaces = 4 - column % 4
                out += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                out.append(c)
                column += 1
            }
        }
        return out
    }

    static func indent(of s: String) -> Int {
        var n = 0
        for c in s { if c == " " { n += 1 } else { break } }
        return n
    }

    static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " } }

    private static func dropIndent(_ s: String, _ count: Int) -> String {
        String(s.dropFirst(min(count, indent(of: s))))
    }

    static func splitFrontMatter(_ lines: [Line]) -> ([Line], [Line])? {
        guard lines.first?.text == "---" else { return nil }
        guard let end = lines.dropFirst().firstIndex(where: { $0.text == "---" || $0.text == "..." }),
              end > 1 else { return nil }
        return (Array(lines[1..<end]), Array(lines[(end + 1)...]))
    }

    // MARK: - Распознавание блоков

    static func fenceOpening(_ s: String) -> (char: Character, count: Int, indent: Int, info: String)? {
        let ind = indent(of: s)
        guard ind <= 3 else { return nil }
        let rest = s.dropFirst(ind)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let count = rest.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        return (first, count, ind, info)
    }

    static func atxHeading(_ s: String) -> (level: Int, text: String)? {
        let ind = indent(of: s)
        guard ind <= 3 else { return nil }
        let rest = s.dropFirst(ind)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        var body = rest.dropFirst(level)
        guard body.isEmpty || body.first == " " else { return nil }
        body = body.drop { $0 == " " }
        var text = String(body).trimmingCharacters(in: .whitespaces)
        // Закрывающие `#` — только отделённые пробелом.
        if let hashes = text.lastIndex(where: { $0 != "#" }) {
            let tail = text[text.index(after: hashes)...]
            if !tail.isEmpty, text[hashes] == " " {
                text = String(text[..<hashes]).trimmingCharacters(in: .whitespaces)
            }
        } else {
            text = ""
        }
        return (level, text)
    }

    static func setextLevel(_ s: String) -> Int? {
        guard indent(of: s) <= 3 else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, first == "=" || first == "-", t.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    static func isThematicBreak(_ s: String) -> Bool {
        guard indent(of: s) <= 3 else { return false }
        let t = s.filter { $0 != " " }
        guard t.count >= 3, let first = t.first, "-*_".contains(first) else { return false }
        return t.allSatisfy { $0 == first }
    }

    struct ListMarker {
        var ordered: Bool
        var delimiter: Character    // `-`, `*`, `+` или `.`/`)` у нумерованного
        var start: Int
        var contentIndent: Int
        var content: String
    }

    static func listMarker(_ s: String) -> ListMarker? {
        let ind = indent(of: s)
        let rest = Array(s.dropFirst(ind))
        guard let first = rest.first else { return nil }
        var markerLength: Int
        var ordered = false
        var delimiter = first
        var start = 1
        if "-*+".contains(first) {
            markerLength = 1
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9, digits.count < rest.count else { return nil }
            let d = rest[digits.count]
            guard d == "." || d == ")" else { return nil }
            ordered = true
            delimiter = d
            start = Int(String(digits)) ?? 1
            markerLength = digits.count + 1
        } else {
            return nil
        }
        let after = rest.dropFirst(markerLength)
        guard after.isEmpty || after.first == " " else { return nil }
        var spaces = after.prefix { $0 == " " }.count
        if after.count == spaces { spaces = 1 }        // пустой пункт
        else if spaces > 4 { spaces = 1 }              // дальше — код внутри пункта
        let content = after.isEmpty ? "" : String(after.dropFirst(spaces))
        return ListMarker(ordered: ordered, delimiter: delimiter, start: start,
                          contentIndent: ind + markerLength + spaces, content: content)
    }

    static func isHTMLBlockStart(_ s: String) -> Bool {
        guard indent(of: s) <= 3 else { return false }
        let t = s.drop { $0 == " " }
        guard t.first == "<" else { return false }
        let rest = t.dropFirst()
        if rest.hasPrefix("!--") { return true }
        let name = rest.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        guard let first = name.first, first.isLetter else { return false }
        return blockTags.contains(name.lowercased())
    }

    static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "div", "dl", "dd", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
        "hr", "img", "li", "main", "nav", "ol", "p", "picture", "pre", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "tr", "ul", "video", "br", "a", "sup", "sub", "kbd",
    ]

    static func tableCells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for c in t {
            if escaped {
                if c != "|" { current.append("\\") }
                current.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "`" {
                inCode.toggle()
                current.append(c)
            } else if c == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Строка-разделитель таблицы: `| --- | :-: |`. Возвращает выравнивания.
    static func tableAlignments(_ s: String) -> [String?]? {
        guard s.contains("-"), indent(of: s) <= 3 else { return nil }
        let cells = tableCells(s)
        var result: [String?] = []
        for cell in cells {
            guard !cell.isEmpty, cell.allSatisfy({ "-: ".contains($0) }), cell.contains("-") else { return nil }
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            result.append(left && right ? "center" : right ? "right" : left ? "left" : nil)
        }
        return result
    }

    // MARK: - Сборка

    struct Renderer {
        var references: [String: (url: String, title: String?)] = [:]
        var usedIDs: [String: Int] = [:]

        /// `[label]: url "title"` — определения ссылок убираются из текста.
        mutating func collectReferences(_ lines: [Line]) -> [Line] {
            var kept: [Line] = []
            var fence: (char: Character, count: Int)?
            var previousBlank = true
            for line in lines {
                if let f = fence {
                    if let close = Markdown.fenceOpening(line.text), close.char == f.char,
                       close.count >= f.count, close.info.isEmpty { fence = nil }
                    kept.append(line)
                    continue
                }
                if let open = Markdown.fenceOpening(line.text) {
                    fence = (open.char, open.count)
                } else if previousBlank, let (label, url, title) = Self.referenceDefinition(line.text) {
                    let key = label.lowercased()
                    if references[key] == nil { references[key] = (url, title) }
                    continue
                }
                previousBlank = Markdown.isBlank(line.text)
                kept.append(line)
            }
            return kept
        }

        static func referenceDefinition(_ s: String) -> (String, String, String?)? {
            guard Markdown.indent(of: s) <= 3 else { return nil }
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), !t.hasPrefix("[^"), let close = t.range(of: "]:") else { return nil }
            let label = String(t[t.index(after: t.startIndex)..<close.lowerBound])
            guard !label.isEmpty, !label.contains("]") else { return nil }
            var rest = t[close.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            var url: String
            if rest.hasPrefix("<"), let end = rest.firstIndex(of: ">") {
                url = String(rest[rest.index(after: rest.startIndex)..<end])
                rest = String(rest[rest.index(after: end)...])
            } else {
                let end = rest.firstIndex(of: " ") ?? rest.endIndex
                url = String(rest[..<end])
                rest = String(rest[end...])
            }
            rest = rest.trimmingCharacters(in: .whitespaces)
            var title: String?
            if let q = rest.first, "\"'(".contains(q), rest.count >= 2 {
                title = String(rest.dropFirst().dropLast())
            } else if !rest.isEmpty {
                return nil
            }
            return (label, url, title)
        }

        mutating func blocks(_ lines: ArraySlice<Line>, tight: Bool) -> String {
            var out = ""
            var i = lines.startIndex
            while i < lines.endIndex {
                let line = lines[i]
                let text = line.text
                if Markdown.isBlank(text) { i += 1; continue }

                if let fence = Markdown.fenceOpening(text) {
                    var body: [String] = []
                    var j = i + 1
                    while j < lines.endIndex {
                        if let close = Markdown.fenceOpening(lines[j].text), close.char == fence.char,
                           close.count >= fence.count, close.info.isEmpty { break }
                        body.append(Markdown.dropIndent(lines[j].text, fence.indent))
                        j += 1
                    }
                    let language = fence.info.split(separator: " ").first.map(String.init) ?? ""
                    out += codeBlock(body.joined(separator: "\n"), language: language, line: line.number)
                    i = min(j + 1, lines.endIndex)
                    continue
                }

                if Markdown.indent(of: text) >= 4 {
                    var body: [String] = []
                    var j = i
                    while j < lines.endIndex, Markdown.isBlank(lines[j].text) || Markdown.indent(of: lines[j].text) >= 4 {
                        body.append(Markdown.dropIndent(lines[j].text, 4))
                        j += 1
                    }
                    while body.last.map(Markdown.isBlank) == true { body.removeLast() }
                    out += codeBlock(body.joined(separator: "\n"), language: "", line: line.number)
                    i = j
                    continue
                }

                if let heading = Markdown.atxHeading(text) {
                    out += headingHTML(heading.level, heading.text, line: line.number)
                    i += 1
                    continue
                }

                if Markdown.isThematicBreak(text) {
                    out += "<hr data-line=\"\(line.number)\">\n"
                    i += 1
                    continue
                }

                if text.drop(while: { $0 == " " }).first == ">", Markdown.indent(of: text) <= 3 {
                    var inner: [Line] = []
                    var j = i
                    while j < lines.endIndex {
                        let t = lines[j].text
                        let stripped = t.drop { $0 == " " }
                        if stripped.first == ">" {
                            var content = stripped.dropFirst()
                            if content.first == " " { content = content.dropFirst() }
                            inner.append(Line(text: String(content), number: lines[j].number))
                        } else if !Markdown.isBlank(t), let last = inner.last, !Markdown.isBlank(last.text),
                                  !startsBlock(t) {
                            inner.append(Line(text: t, number: lines[j].number))   // ленивое продолжение
                        } else {
                            break
                        }
                        j += 1
                    }
                    out += blockquote(inner, line: line.number)
                    i = j
                    continue
                }

                if let marker = Markdown.listMarker(text), Markdown.indent(of: text) <= 3 {
                    let (html, next) = list(lines, from: i, marker: marker)
                    out += html
                    i = next
                    continue
                }

                if Markdown.isHTMLBlockStart(text) {
                    var body: [String] = []
                    var j = i
                    while j < lines.endIndex, !Markdown.isBlank(lines[j].text) {
                        body.append(lines[j].text)
                        j += 1
                    }
                    out += "<div class=\"html\" data-line=\"\(line.number)\">" + Markdown.sanitize(body.joined(separator: "\n")) + "</div>\n"
                    i = j
                    continue
                }

                if i + 1 < lines.endIndex, text.contains("|"),
                   let alignments = Markdown.tableAlignments(lines[i + 1].text),
                   Markdown.tableCells(text).count == alignments.count {
                    var j = i + 2
                    var rows: [[String]] = []
                    while j < lines.endIndex, !Markdown.isBlank(lines[j].text), lines[j].text.contains("|") {
                        rows.append(Markdown.tableCells(lines[j].text))
                        j += 1
                    }
                    out += table(header: Markdown.tableCells(text), alignments: alignments, rows: rows, line: line.number)
                    i = j
                    continue
                }

                // Абзац: до пустой строки или начала другого блока.
                var paragraph = [String(text.drop { $0 == " " })]
                var j = i + 1
                var setext: Int?
                while j < lines.endIndex {
                    let t = lines[j].text
                    if Markdown.isBlank(t) { break }
                    if let level = Markdown.setextLevel(t) {
                        // `---` под абзацем — заголовок, а не разделитель.
                        setext = level
                        j += 1
                        break
                    }
                    if startsBlock(t) { break }
                    paragraph.append(String(t.drop { $0 == " " }))
                    j += 1
                }
                let content = paragraph.joined(separator: "\n")
                if let setext {
                    out += headingHTML(setext, content, line: line.number)
                } else if tight {
                    out += inline(content) + "\n"
                } else {
                    out += "<p data-line=\"\(line.number)\">" + inline(content) + "</p>\n"
                }
                i = j
            }
            return out
        }

        /// Прерывает ли строка абзац.
        func startsBlock(_ t: String) -> Bool {
            if Markdown.fenceOpening(t) != nil || Markdown.atxHeading(t) != nil || Markdown.isThematicBreak(t) { return true }
            if Markdown.indent(of: t) <= 3, t.drop(while: { $0 == " " }).first == ">" { return true }
            if Markdown.indent(of: t) <= 3, let m = Markdown.listMarker(t), !m.content.isEmpty,
               !m.ordered || m.start == 1 { return true }
            return Markdown.isHTMLBlockStart(t)
        }

        mutating func list(_ lines: ArraySlice<Line>, from start: Int, marker first: ListMarker) -> (String, Int) {
            var items: [(lines: [Line], line: Int)] = []
            var loose = false
            var current: [Line] = [Line(text: first.content, number: lines[start].number)]
            var contentIndent = first.contentIndent
            var itemLine = lines[start].number
            var pendingBlank = false
            var j = start + 1
            while j < lines.endIndex {
                let t = lines[j].text
                if Markdown.isBlank(t) {
                    pendingBlank = true
                    current.append(Line(text: "", number: lines[j].number))
                    j += 1
                    continue
                }
                let ind = Markdown.indent(of: t)
                if ind >= contentIndent {
                    if pendingBlank { loose = loose || current.contains { !Markdown.isBlank($0.text) } }
                    current.append(Line(text: Markdown.dropIndent(t, contentIndent), number: lines[j].number))
                    pendingBlank = false
                } else if let m = Markdown.listMarker(t), ind <= 3 || ind < contentIndent,
                          m.ordered == first.ordered, m.delimiter == first.delimiter {
                    if pendingBlank { loose = true }
                    items.append((current, itemLine))
                    current = [Line(text: m.content, number: lines[j].number)]
                    contentIndent = m.contentIndent
                    itemLine = lines[j].number
                    pendingBlank = false
                } else if !pendingBlank, !startsBlock(t) {
                    current.append(Line(text: String(t.drop { $0 == " " }), number: lines[j].number))
                } else {
                    break
                }
                j += 1
            }
            items.append((current, itemLine))

            // Пустые строки в хвосте последнего пункта принадлежат уже не списку.
            var end = j
            while end > start + 1, Markdown.isBlank(lines[end - 1].text) { end -= 1 }

            let tag = first.ordered ? "ol" : "ul"
            let startAttr = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
            var out = "<\(tag)\(startAttr) data-line=\"\(lines[start].number)\">\n"
            for item in items {
                var itemLines = item.lines
                while itemLines.last.map({ Markdown.isBlank($0.text) }) == true { itemLines.removeLast() }
                var taskAttr = ""
                if let firstLine = itemLines.first {
                    let t = firstLine.text
                    if t.hasPrefix("[ ] ") || t == "[ ]" || t.lowercased().hasPrefix("[x] ") || t.lowercased() == "[x]" {
                        let checked = t.lowercased().hasPrefix("[x]")
                        itemLines[0].text = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        taskAttr = " class=\"task\""
                        itemLines[0].text = "\u{0}TASK\(checked ? 1 : 0)\u{0}" + itemLines[0].text
                    }
                }
                var body = blocks(itemLines[...], tight: !loose)
                body = body.replacingOccurrences(of: "\u{0}TASK1\u{0}", with: "<input type=\"checkbox\" checked disabled> ")
                body = body.replacingOccurrences(of: "\u{0}TASK0\u{0}", with: "<input type=\"checkbox\" disabled> ")
                out += "<li\(taskAttr) data-line=\"\(item.line)\">" + body + "</li>\n"
            }
            out += "</\(tag)>\n"
            return (out, end)
        }

        mutating func blockquote(_ inner: [Line], line: Int) -> String {
            var inner = inner
            // Плашки GitHub: `> [!NOTE]` первой строкой.
            if let first = inner.first {
                let t = first.text.trimmingCharacters(in: .whitespaces).uppercased()
                for kind in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] where t == "[!\(kind)]" {
                    inner.removeFirst()
                    let titles = ["NOTE": L("Заметка"), "TIP": L("Совет"), "IMPORTANT": L("Важно"),
                                  "WARNING": L("Внимание"), "CAUTION": L("Осторожно")]
                    return "<div class=\"alert alert-\(kind.lowercased())\" data-line=\"\(line)\">"
                        + "<p class=\"alert-title\">\(titles[kind]!)</p>"
                        + blocks(inner[...], tight: false) + "</div>\n"
                }
            }
            return "<blockquote data-line=\"\(line)\">\n" + blocks(inner[...], tight: false) + "</blockquote>\n"
        }

        mutating func headingHTML(_ level: Int, _ text: String, line: Int) -> String {
            var id = Markdown.slug(Markdown.plainText(text))
            if let n = usedIDs[id] {
                usedIDs[id] = n + 1
                id += "-\(n + 1)"
            } else {
                usedIDs[id] = 0
            }
            return "<h\(level) id=\"\(Markdown.escape(id))\" data-line=\"\(line)\">" + inline(text) + "</h\(level)>\n"
        }

        func codeBlock(_ code: String, language: String, line: Int) -> String {
            let lang = language.isEmpty ? "" : " data-lang=\"\(Markdown.escape(language))\""
            return "<pre data-line=\"\(line)\"\(lang)><code>" + Markdown.highlight(code, language: language) + "</code></pre>\n"
        }

        func table(header: [String], alignments: [String?], rows: [[String]], line: Int) -> String {
            func cell(_ tag: String, _ content: String, _ index: Int) -> String {
                let align = index < alignments.count ? alignments[index].map { " style=\"text-align:\($0)\"" } ?? "" : ""
                return "<\(tag)\(align)>" + inline(content) + "</\(tag)>"
            }
            var out = "<table data-line=\"\(line)\"><thead><tr>"
            for (k, h) in header.enumerated() { out += cell("th", h, k) }
            out += "</tr></thead><tbody>\n"
            for row in rows {
                out += "<tr>"
                for k in 0..<header.count { out += cell("td", k < row.count ? row[k] : "", k) }
                out += "</tr>\n"
            }
            return out + "</tbody></table>\n"
        }

        func inline(_ text: String) -> String {
            Markdown.Inline(chars: Array(text), references: references).render()
        }
    }

    // MARK: - Внутри строки

    struct Inline {
        let chars: [Character]
        let references: [String: (url: String, title: String?)]

        func render() -> String { render(0, chars.count) }

        func render(_ from: Int, _ to: Int) -> String {
            var out = ""
            var i = from
            while i < to {
                let c = chars[i]
                switch c {
                case "\\":
                    if i + 1 < to, chars[i + 1] == "\n" {
                        out += "<br>\n"
                        i += 2
                    } else if i + 1 < to, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                        out += Markdown.escape(String(chars[i + 1]))
                        i += 2
                    } else {
                        out += "\\"
                        i += 1
                    }
                case "`":
                    let run = count(of: "`", at: i, limit: to)
                    if let close = findRun("`", length: run, from: i + run, to: to) {
                        var code = String(chars[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                        if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                            code = String(code.dropFirst().dropLast())
                        }
                        out += "<code>" + Markdown.escape(code) + "</code>"
                        i = close + run
                    } else {
                        out += String(repeating: "`", count: run)
                        i += run
                    }
                case "!" where i + 1 < to && chars[i + 1] == "[":
                    if let link = link(at: i + 1, to: to) {
                        let alt = Markdown.plainText(String(chars[(i + 2)..<link.textEnd]))
                        out += "<img src=\"\(Markdown.escape(link.url))\" alt=\"\(Markdown.escape(alt))\""
                            + (link.title.map { " title=\"\(Markdown.escape($0))\"" } ?? "") + ">"
                        i = link.end
                    } else {
                        out += "!"
                        i += 1
                    }
                case "[":
                    if let link = link(at: i, to: to) {
                        out += "<a href=\"\(Markdown.escape(link.url))\""
                            + (link.title.map { " title=\"\(Markdown.escape($0))\"" } ?? "") + ">"
                            + render(i + 1, link.textEnd) + "</a>"
                        i = link.end
                    } else {
                        out += "["
                        i += 1
                    }
                case "<":
                    if let (html, end) = angle(at: i, to: to) {
                        out += html
                        i = end
                    } else {
                        out += "&lt;"
                        i += 1
                    }
                case "*", "_":
                    if let (html, end) = emphasis(at: i, to: to) {
                        out += html
                        i = end
                    } else {
                        let run = count(of: c, at: i, limit: to)
                        out += String(repeating: c, count: run)
                        i += run
                    }
                case "~" where i + 1 < to && chars[i + 1] == "~":
                    if let close = findDelimiter("~~", from: i + 2, to: to), close > i + 2 {
                        out += "<del>" + render(i + 2, close) + "</del>"
                        i = close + 2
                    } else {
                        out += "~~"
                        i += 2
                    }
                case "h":
                    if let (html, end) = bareURL(at: i, to: to) {
                        out += html
                        i = end
                    } else {
                        out += "h"
                        i += 1
                    }
                case "\n":
                    // Два пробела в конце строки — жёсткий перенос.
                    if out.hasSuffix("  ") {
                        while out.hasSuffix(" ") { out.removeLast() }
                        out += "<br>\n"
                    } else {
                        out += "\n"
                    }
                    i += 1
                case "&":
                    let entity = chars[i..<min(to, i + 12)].prefix { $0 != ";" }
                    if entity.count > 1, entity.count < 11, i + entity.count < to, chars[i + entity.count] == ";",
                       entity.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "#" }) {
                        out += String(entity) + ";"
                        i += entity.count + 1
                    } else {
                        out += "&amp;"
                        i += 1
                    }
                default:
                    out += Markdown.escape(String(c))
                    i += 1
                }
            }
            return out
        }

        private func count(of c: Character, at i: Int, limit: Int) -> Int {
            var n = 0
            while i + n < limit, chars[i + n] == c { n += 1 }
            return n
        }

        private func findRun(_ c: Character, length: Int, from: Int, to: Int) -> Int? {
            var j = from
            while j < to {
                if chars[j] == c {
                    let run = count(of: c, at: j, limit: to)
                    if run == length { return j }
                    j += run
                } else {
                    j += 1
                }
            }
            return nil
        }

        /// Закрывающий разделитель, пропуская код в обратных кавычках.
        private func findDelimiter(_ delimiter: String, from: Int, to: Int) -> Int? {
            let d = Array(delimiter)
            var j = from
            while j + d.count <= to {
                if chars[j] == "`" {
                    let run = count(of: "`", at: j, limit: to)
                    if let close = findRun("`", length: run, from: j + run, to: to) { j = close + run; continue }
                    j += run
                    continue
                }
                if chars[j] == "\\" { j += 2; continue }
                if Array(chars[j..<(j + d.count)]) == d { return j }
                j += 1
            }
            return nil
        }

        private func emphasis(at i: Int, to: Int) -> (String, Int)? {
            let c = chars[i]
            let run = count(of: c, at: i, limit: to)
            let after = i + run
            guard after < to, !chars[after].isWhitespace else { return nil }
            // `snake_case_name` — не выделение.
            if c == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { return nil }
            for length in Set([min(run, 3), min(run, 2), 1]).sorted(by: >) {
                let open = i + run - length
                let d = String(repeating: c, count: length)
                var search = open + length
                while let close = findDelimiter(d, from: search, to: to) {
                    let closeRun = count(of: c, at: close, limit: to)
                    let valid = close > open + length && !chars[close - 1].isWhitespace
                        && (c != "_" || close + closeRun >= to || !(chars[close + closeRun].isLetter || chars[close + closeRun].isNumber))
                    // Одиночный `*` не закрывается половинкой `**`: это чужое выделение внутри.
                    if valid, closeRun == length || length >= 2 || closeRun >= 3 {
                        let inner = render(open + length, close)
                        let wrapped = length == 3 ? "<em><strong>\(inner)</strong></em>"
                            : length == 2 ? "<strong>\(inner)</strong>" : "<em>\(inner)</em>"
                        return (String(repeating: c, count: run - length) + wrapped, close + length)
                    }
                    search = close + max(closeRun, 1)
                }
            }
            return nil
        }

        private struct Link {
            var url: String
            var title: String?
            var textEnd: Int
            var end: Int
        }

        /// `[текст](адрес "заголовок")`, `[текст][метка]`, `[метка]`.
        private func link(at open: Int, to: Int) -> Link? {
            var depth = 0
            var j = open
            var close: Int?
            while j < to {
                switch chars[j] {
                case "\\": j += 1
                case "`":
                    let run = count(of: "`", at: j, limit: to)
                    if let end = findRun("`", length: run, from: j + run, to: to) { j = end + run - 1 } else { j += run - 1 }
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { close = j }
                default: break
                }
                if close != nil { break }
                j += 1
            }
            guard let close else { return nil }
            let label = String(chars[(open + 1)..<close])

            if close + 1 < to, chars[close + 1] == "(" {
                var k = close + 2
                while k < to, chars[k] == " " { k += 1 }
                var url = ""
                if k < to, chars[k] == "<" {
                    guard let end = chars[k..<to].firstIndex(of: ">") else { return nil }
                    url = String(chars[(k + 1)..<end])
                    k = end + 1
                } else {
                    var parens = 0
                    while k < to, !chars[k].isWhitespace {
                        if chars[k] == "(" { parens += 1 }
                        if chars[k] == ")" { if parens == 0 { break }; parens -= 1 }
                        url.append(chars[k])
                        k += 1
                    }
                }
                while k < to, chars[k] == " " { k += 1 }
                var title: String?
                if k < to, chars[k] == "\"" || chars[k] == "'" {
                    let quote = chars[k]
                    guard let end = chars[(k + 1)..<to].firstIndex(of: quote) else { return nil }
                    title = String(chars[(k + 1)..<end])
                    k = end + 1
                    while k < to, chars[k] == " " { k += 1 }
                }
                guard k < to, chars[k] == ")" else { return nil }
                return Link(url: url, title: title, textEnd: close, end: k + 1)
            }
            if close + 1 < to, chars[close + 1] == "[",
               let end = chars[(close + 2)..<to].firstIndex(of: "]") {
                let ref = String(chars[(close + 2)..<end])
                let key = (ref.isEmpty ? label : ref).lowercased()
                guard let target = references[key] else { return nil }
                return Link(url: target.url, title: target.title, textEnd: close, end: end + 1)
            }
            if let target = references[label.lowercased()] {
                return Link(url: target.url, title: target.title, textEnd: close, end: close + 1)
            }
            return nil
        }

        /// `<https://…>`, `<a@b.c>` и HTML-теги внутри текста.
        private func angle(at i: Int, to: Int) -> (String, Int)? {
            guard let end = chars[(i + 1)..<to].firstIndex(of: ">") else { return nil }
            let inner = String(chars[(i + 1)..<end])
            if inner.hasPrefix("http://") || inner.hasPrefix("https://"), !inner.contains(" ") {
                return ("<a href=\"\(Markdown.escape(inner))\">\(Markdown.escape(inner))</a>", end + 1)
            }
            if inner.contains("@"), !inner.contains(" "), !inner.contains("/") {
                return ("<a href=\"mailto:\(Markdown.escape(inner))\">\(Markdown.escape(inner))</a>", end + 1)
            }
            let name = inner.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }
            if inner.hasPrefix("!--") || (!name.isEmpty && name.first!.isLetter) {
                return (Markdown.sanitize("<" + inner + ">"), end + 1)
            }
            return nil
        }

        private func bareURL(at i: Int, to: Int) -> (String, Int)? {
            let prefixes = ["https://", "http://"]
            guard i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "\"" || chars[i - 1] == "=") else { return nil }
            let head = String(chars[i..<min(to, i + 8)])
            guard prefixes.contains(where: { head.hasPrefix($0) }) else { return nil }
            var j = i
            while j < to, !chars[j].isWhitespace, chars[j] != "<" { j += 1 }
            // Точка или скобка в конце — чаще пунктуация фразы, чем часть адреса.
            while j > i, ".,:;!?\"'".contains(chars[j - 1]) { j -= 1 }
            var url = String(chars[i..<j])
            if url.hasSuffix(")"), url.filter({ $0 == "(" }).count < url.filter({ $0 == ")" }).count {
                url.removeLast()
                j -= 1
            }
            guard url.count > 8 else { return nil }
            return ("<a href=\"\(Markdown.escape(url))\">\(Markdown.escape(url))</a>", j)
        }
    }

    // MARK: - Общее

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Сырой HTML из документа показываем, но без скриптов и обработчиков:
    /// README из чужого пакета не должен ничего исполнять.
    static func sanitize(_ html: String) -> String {
        var s = html
        for pattern in ["<script[\\s\\S]*?</script\\s*>", "<script[^>]*>", "<iframe[\\s\\S]*?>",
                        "\\son[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", "javascript:"] {
            s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s
    }

    /// Текст без разметки — для якорей и структуры файла.
    static func plainText(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "!" , s.index(after: i) < s.endIndex, s[s.index(after: i)] == "[" {
                i = s.index(after: i)
                continue
            }
            if c == "]", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "(",
               let close = s[i...].firstIndex(of: ")") {
                i = s.index(after: close)
                continue
            }
            if !"*_`[]~\\".contains(c) { out.append(c) }
            i = s.index(after: i)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Якорь заголовка, как у GitHub: нижний регистр, пробелы — дефисы,
    /// знаки препинания выбрасываются, буквы любых алфавитов остаются.
    static func slug(_ s: String) -> String {
        var out = ""
        for c in s.lowercased() {
            if c.isLetter || c.isNumber || c == "-" || c == "_" { out.append(c) }
            else if c == " " { out.append("-") }
        }
        return out
    }

    // MARK: - Подсветка кода

    static func highlight(_ code: String, language: String) -> String {
        guard let spec = spec(forLanguage: language), !code.isEmpty else { return escape(code) }
        let model = SyntaxModel(text: code, spec: spec)
        let tokens = model.tokens(fromLine: 0, toLine: model.lineCount - 1)
        let units = model.units
        var out = ""
        var position = 0
        for token in tokens {
            let start = Int(token.start), end = start + Int(token.length)
            guard start >= position, end <= units.count else { continue }
            if start > position { out += escape(String(decoding: units[position..<start], as: UTF16.self)) }
            let text = escape(String(decoding: units[start..<end], as: UTF16.self))
            out += token.kind == .plain ? text : "<span class=\"t-\(token.kind)\">\(text)</span>"
            position = end
        }
        if position < units.count { out += escape(String(decoding: units[position...], as: UTF16.self)) }
        return out
    }

    static func spec(forLanguage language: String) -> LanguageSpec? {
        let name = language.lowercased()
        guard !name.isEmpty else { return nil }
        let aliases = [
            "csharp": "cs", "c#": "cs", "javascript": "js", "typescript": "ts", "python": "py",
            "shell": "sh", "console": "sh", "terminal": "sh", "rust": "rs", "golang": "go",
            "kotlin": "kt", "ruby": "rb", "c++": "cpp", "objc": "m", "objective-c": "m",
            "html": "html", "yml": "yaml", "shaderlab": "shader", "jsonc": "json", "text": "",
        ]
        let ext = aliases[name] ?? name
        guard !ext.isEmpty else { return nil }
        return Languages.detect(filename: "x." + ext)
    }
}
