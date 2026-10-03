import Foundation

// MARK: - Что поменялось, словами

enum HotDiff {
    /// Строки правки для окна в редакторе: `+`/`-`/` ` и `⋯` между кусками,
    /// без общего отступа.
    static func lines(before: String, after: String, limit: Int = 14) -> [String] {
        let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
        let changes = LineDiff.changes(old: before, new: after)
        var out: [String] = []
        for change in changes {
            if !out.isEmpty { out.append("⋯") }
            if change.lines.lowerBound > 0, change.lines.lowerBound - 1 < new.count {
                out.append(" " + new[change.lines.lowerBound - 1])
            }
            out += change.oldLines.filter { $0 < old.count }.map { "-" + old[$0] }
            out += change.lines.filter { $0 < new.count }.map { "+" + new[$0] }
            if change.lines.upperBound < new.count { out.append(" " + new[change.lines.upperBound]) }
        }
        out = out.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let bodies = out.filter { $0 != "⋯" }.map { $0.dropFirst() }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indent = bodies.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        out = out.map { $0 == "⋯" ? $0 : String($0.prefix(1)) + String($0.dropFirst().dropFirst(min(indent, max(0, $0.count - 1)))) }
        return Array(out.prefix(limit)) + (out.count > limit ? ["⋯"] : [])
    }

    /// `dev.A.B::M, dev.A.C::get_P` как `B.M, C.P`.
    static func shortMembers(_ methods: [String]) -> [String] {
        methods.map { item in
            let parts = item.components(separatedBy: "::")
            let owner = parts[0].split(separator: ".").last.map(String.init) ?? parts[0]
            var member = parts.count > 1 ? parts[1] : ""
            if member.hasPrefix("get_") || member.hasPrefix("set_") { member = String(member.dropFirst(4)) }
            member = [".ctor": "constructor", ".cctor": "static constructor"][member] ?? member
            return member.isEmpty ? owner : "\(owner).\(member)"
        }
    }

    private static let keywords: Set<String> = [
        "if", "for", "foreach", "while", "switch", "catch", "using", "return", "new", "lock", "fixed",
        "nameof", "typeof", "sizeof", "default", "base", "this", "await", "throw", "else", "get", "set",
    ]

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// Какие объявления правка добавила или убрала, по её строкам.
    static func declarations(_ diff: [String]) -> [String] {
        var found: [String] = []
        for line in diff {
            let sign = line.prefix(1), text = withoutAttributes(line.dropFirst().trimmingCharacters(in: .whitespaces))
            guard sign == "+" || sign == "-", !text.isEmpty, !text.hasPrefix("//"), !text.hasPrefix("[") else { continue }
            let verb = sign == "+" ? "Added" : "Removed"
            // Объявление — то, что до тела: тело в той же строке (`{ … ; }`)
            // методом его не делает и не перестаёт.
            let head = text.range(of: "{").map { String(text[..<$0.lowerBound]) } ?? text
            if let kind = match(#"\b(class|struct|interface|enum|record)\s+(\w+(?:<[^>]*>)?)"#, text) {
                found.append("\(verb) \(kind[1]) \(kind[2])")
            } else if let method = match(#"^(?:(?:public|private|protected|internal|static|virtual|override|async|abstract|sealed|partial|unsafe|extern|new)\s+)*[\w<>\[\],.?]+\s+(\w+)\s*(?:<[^>]*>)?\s*\([^;]*$"#, head),
                      !keywords.contains(method[1]), !text.hasPrefix("return"), !text.hasPrefix("var "), !text.hasPrefix("await") {
                found.append("\(verb) method \(method[1])")
            } else if let member = match(#"^(?:public|private|protected|internal|static|readonly|const|volatile)\b[^(=]*?\b(\w+)\s*(=|;|\{|=>)"#, text),
                      !keywords.contains(member[1]) {
                found.append("\(verb) \(member[2] == "{" || member[2] == "=>" ? "property" : "field") \(member[1])")
            }
        }
        // Убранное и добавленное с тем же именем — правка его, не два
        // объявления.
        let both = Set(found.filter { $0.hasPrefix("Added ") }.map { $0.dropFirst(6) })
            .intersection(found.filter { $0.hasPrefix("Removed ") }.map { $0.dropFirst(8) })
        var seen = Set<String>()
        return found.filter { item in
            !both.contains(item.hasPrefix("Added ") ? item.dropFirst(6) : item.dropFirst(8)) && seen.insert(item).inserted
        }
    }

    /// Строка без атрибутов в начале: `[SerializeField] private int n;` —
    /// объявление поля, а не строка атрибута.
    static func withoutAttributes(_ text: String) -> String {
        var rest = Substring(text)
        while rest.hasPrefix("[") {
            // `]` внутри строки (`[Tooltip("a ] b")]`) атрибут не закрывает.
            var depth = 0, quoted = false, escaped = false
            guard let end = rest.firstIndex(where: { character in
                if quoted {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
                    return false
                }
                if character == "\"" { quoted = true } else if character == "[" { depth += 1 } else if character == "]" { depth -= 1 }
                return depth == 0
            }) else { break }
            rest = rest[rest.index(after: end)...].drop { $0 == " " || $0 == "\t" }
        }
        return String(rest)
    }

    /// Поля, которые правка добавила с `[SerializeField]`: их Inspector
    /// увидит только после перезагрузки, на сборке, где они есть.
    static func serializedFields(_ diff: [String]) -> [String] {
        diff.compactMap { line -> String? in
            guard line.hasPrefix("+"), line.contains("SerializeField") else { return nil }
            let text = withoutAttributes(line.dropFirst().trimmingCharacters(in: .whitespaces))
            return match(#"^(?:public|private|protected|internal|readonly|\s)*[\w<>\[\],.?]+\s+(\w+)\s*(?:=|;)"#, text)?[1]
        }
    }

    /// Что поменяло сохранение, в несколько слов: добавленные или убранные
    /// объявления, иначе методы, которых у заплаток ещё не было, иначе —
    /// методы самого файла.
    static func title(file: String?, methods: [String], patched: Set<String>, diff: [String]) -> String {
        let members = shortMembers(methods)
        let earlier = Set(shortMembers(Array(patched)))
        let new = members.filter { !earlier.contains($0) }
        let stem = file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        let own = stem.map { stem in members.filter { $0.split(separator: ".").first.map(String.init) == stem } } ?? []
        let declared = declarations(diff)
        let shown = !declared.isEmpty ? declared : !new.isEmpty ? new : own
        guard !shown.isEmpty else { return stem.map { "Edited \($0)" } ?? "Edited" }
        return shown.prefix(3).joined(separator: ", ") + (shown.count > 3 ? " and \(shown.count - 3) more" : "")
    }
}
