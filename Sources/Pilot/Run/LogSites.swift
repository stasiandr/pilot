import Foundation

/// Место в коде, где пишется лог: `Log.Error("[{SystemName}] Boom {Id}", …)`.
struct LogSite: Hashable {
    /// От корня проекта.
    var path: String
    /// С единицы — строка с именем метода.
    var line: Int
    var level: ServerLogEntry.Level
    /// Текст шаблона, как его получит Serilog. У `$"…"` дырки — `{}`:
    /// что туда подставится, заранее неизвестно.
    var template: String
    var isInterpolated: Bool
    /// Аргументы вызова как написаны — различить одинаковые шаблоны по
    /// `nameof(Punishment)` и прочему, что попало в свойства.
    var call: String
}

/// Вызовы логгера в исходниках C#: по ним событие лога находит строку,
/// которая его написала. Serilog пишет в `@i` хеш шаблона — по нему
/// находится точно; где хеша нет (текстовый вывод, `$"…"`) — по тому,
/// какой шаблон подходит к тексту сообщения.
struct LogSites {
    private(set) var sites: [LogSite] = []
    private var byHash: [UInt32: [Int]] = [:]

    init(_ sites: [LogSite]) {
        self.sites = sites
        for (i, site) in sites.enumerated() where !site.isInterpolated {
            byHash[Self.eventID(site.template), default: []].append(i)
        }
    }

    static let skippedDirectories: Set<String> = RunTargets.skippedDirectories.union(["TestResults", "Generated"])

    static func scan(root: URL) -> LogSites {
        var found: [LogSite] = []
        let fm = FileManager.default
        func walk(_ relative: String) {
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = relative.isEmpty ? name : relative + "/" + name
                if name.hasSuffix(".cs") {
                    if let text = try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8) {
                        found += sites(in: text, path: path)
                    }
                    continue
                }
                guard !skippedDirectories.contains(name) else { continue }
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    walk(path)
                }
            }
        }
        walk("")
        return LogSites(found)
    }

    /// Как Serilog считает `@i`: Jenkins one-at-a-time по UTF-16 шаблона.
    static func eventID(_ template: String) -> UInt32 {
        var hash: UInt32 = 0
        for unit in template.utf16 {
            hash &+= UInt32(unit)
            hash &+= hash << 10
            hash ^= hash >> 6
        }
        hash &+= hash << 3
        hash ^= hash >> 11
        hash &+= hash << 15
        return hash
    }

    // MARK: - Поиск

    /// Откуда событие. Нет ни хеша, ни подходящего шаблона — nil.
    func site(for entry: ServerLogEntry) -> LogSite? {
        guard entry.level != .output else { return nil }
        let id = entry.template.map(Self.eventID) ?? entry.eventID
        if let id, let indices = byHash[id], !indices.isEmpty {
            return best(indices.map { sites[$0] }, for: entry)
        }
        // По тексту: шаблон, у которого совпало больше всего букв вне дырок.
        var bestScore = 0
        var candidates: [LogSite] = []
        let message = entry.title
        for site in sites {
            guard let score = Self.match(template: site.template, message: message) else { continue }
            if score > bestScore { bestScore = score; candidates = [site] } else if score == bestScore { candidates.append(site) }
        }
        return bestScore > 0 ? best(candidates, for: entry) : nil
    }

    /// Одинаковых шаблонов бывает несколько: сначала тот же уровень, потом
    /// тот, в чьих аргументах или пути видны значения свойств события.
    private func best(_ candidates: [LogSite], for entry: ServerLogEntry) -> LogSite? {
        guard candidates.count > 1 else { return candidates.first }
        let values = entry.properties.map(\.value).filter { $0.count >= 3 && $0.count <= 80 }
        return candidates.max { a, b in score(a, entry, values) < score(b, entry, values) }
    }

    private func score(_ site: LogSite, _ entry: ServerLogEntry, _ values: [String]) -> Int {
        var score = site.level == entry.level ? 100 : 0
        for value in values where site.call.contains(value) || site.path.contains(value) { score += 1 }
        return score
    }

    /// Подходит ли шаблон к сообщению: куски между дырками — по порядку,
    /// первый — в начале, последний — в конце. Сколько букв совпало; nil — не подходит.
    /// Шаблоны почти без текста (`{Message}`) подходят ко всему — их не считаем.
    static func match(template: String, message: String) -> Int? {
        let parts = literalParts(template)
        let score = parts.reduce(0) { $0 + $1.count }
        if parts.count == 1 { return template == message && !message.isEmpty ? score : nil }
        guard score >= 6, message.hasPrefix(parts[0]), message.hasSuffix(parts[parts.count - 1]) else { return nil }
        var from = message.index(message.startIndex, offsetBy: parts[0].count)
        let end = message.index(message.endIndex, offsetBy: -parts[parts.count - 1].count)
        guard from <= end else { return nil }
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = message.range(of: part, range: from..<end) else { return nil }
            from = range.upperBound
        }
        return score
    }

    /// Текст шаблона между дырками `{…}`; `{{` и `}}` — сами скобки.
    static func literalParts(_ template: String) -> [String] {
        var parts: [String] = [""]
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            let next = template.index(after: i)
            if (c == "{" || c == "}"), next < template.endIndex, template[next] == c {
                parts[parts.count - 1].append(c)
                i = template.index(after: next)
            } else if c == "{", let close = template[next...].firstIndex(of: "}") {
                parts.append("")
                i = template.index(after: close)
            } else {
                parts[parts.count - 1].append(c)
                i = next
            }
        }
        return parts
    }

    // MARK: - Разбор C#

    private static let levels: [String: ServerLogEntry.Level] = [
        "Verbose": .verbose, "Debug": .debug, "Information": .info,
        "Warning": .warning, "Error": .error, "Fatal": .fatal,
    ]

    /// `.Error(` / `.Information<T>(`, дальше — шаблон первым аргументом или
    /// вторым, после исключения. Шаблон — строковый литерал, в том числе
    /// `@"…"`, `$"…"` и склеенный через `+`; иначе (`e.ToString()`) места нет.
    static func sites(in text: String, path: String) -> [LogSite] {
        guard levels.keys.contains(where: { text.contains("." + $0) }) else { return [] }
        let s = Array(text.unicodeScalars)
        var result: [LogSite] = []
        var line = 1
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\n" { line += 1; i += 1; continue }
            // Комментарии и строки пропускаем, чтобы не найти вызов внутри них.
            if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { if s[i] == "\n" { line += 1 }; i += 1 }
                i += 2
                continue
            }
            if c == "\"" || ((c == "@" || c == "$") && i + 1 < s.count && (s[i + 1] == "\"" || s[i + 1] == "@" || s[i + 1] == "$")) {
                if let literal = stringLiteral(s, i) {
                    line += literal.newlines
                    i = literal.end
                    continue
                }
            }
            if c == ".", let (level, open) = levelCall(s, i + 1),
               let site = template(s, afterParen: open, path: path, line: line, level: level) {
                result.append(site)
            }
            i += 1
        }
        return result
    }

    /// `Error(` или `Error<T>(` с позиции `i` — уровень и индекс `(`.
    private static func levelCall(_ s: [Unicode.Scalar], _ i: Int) -> (ServerLogEntry.Level, Int)? {
        var j = i
        while j < s.count, CharacterSet.letters.contains(s[j]) { j += 1 }
        guard j > i, j - i <= 11, let level = levels[String(String.UnicodeScalarView(s[i..<j]))] else { return nil }
        if j < s.count, s[j] == "<" {
            while j < s.count, s[j] != ">", s[j] != "\n", s[j] != "(" { j += 1 }
            guard j < s.count, s[j] == ">" else { return nil }
            j += 1
        }
        guard j < s.count, s[j] == "(" else { return nil }
        return (level, j)
    }

    private static func template(_ s: [Unicode.Scalar], afterParen open: Int, path: String, line: Int,
                                 level: ServerLogEntry.Level) -> LogSite? {
        let close = closingParen(s, open) ?? min(s.count, open + 400)
        let call = String(String.UnicodeScalarView(s[(open + 1)..<min(close, open + 400)]))
        var j = skipSpace(s, open + 1)
        if !isLiteralStart(s, j) {
            // Первым — исключение: пропускаем до запятой верхнего уровня.
            guard let comma = topLevelComma(s, j, limit: close) else { return nil }
            j = skipSpace(s, comma + 1)
        }
        guard isLiteralStart(s, j), var literal = stringLiteral(s, j) else { return nil }
        var text = literal.text
        var interpolated = literal.interpolated
        // `"a" + "b"` — один шаблон.
        while true {
            let plus = skipSpace(s, literal.end)
            guard plus < s.count, s[plus] == "+" else { break }
            let next = skipSpace(s, plus + 1)
            guard isLiteralStart(s, next), let more = stringLiteral(s, next) else { break }
            text += more.text
            interpolated = interpolated || more.interpolated
            literal = more
        }
        return LogSite(path: path, line: line, level: level, template: text, isInterpolated: interpolated, call: call)
    }

    private static func skipSpace(_ s: [Unicode.Scalar], _ i: Int) -> Int {
        var j = i
        while j < s.count, CharacterSet.whitespacesAndNewlines.contains(s[j]) { j += 1 }
        return j
    }

    private static func isLiteralStart(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        guard i < s.count else { return false }
        if s[i] == "\"" { return true }
        guard s[i] == "@" || s[i] == "$", i + 1 < s.count else { return false }
        return s[i + 1] == "\"" || ((s[i + 1] == "@" || s[i + 1] == "$") && i + 2 < s.count && s[i + 2] == "\"")
    }

    private static func closingParen(_ s: [Unicode.Scalar], _ open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < s.count {
            if isLiteralStart(s, i), let literal = stringLiteral(s, i) { i = literal.end; continue }
            if s[i] == "(" { depth += 1 } else if s[i] == ")" { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    private static func topLevelComma(_ s: [Unicode.Scalar], _ from: Int, limit: Int) -> Int? {
        var depth = 0
        var i = from
        while i < limit {
            if isLiteralStart(s, i), let literal = stringLiteral(s, i) { i = literal.end; continue }
            switch s[i] {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case "," where depth == 0: return i
            default: break
            }
            i += 1
        }
        return nil
    }

    /// Строковый литерал C# с позиции `i`: текст как в рантайме (у `$"…"`
    /// дырки — `{}`), индекс за ним и сколько переводов строк внутри.
    private static func stringLiteral(_ s: [Unicode.Scalar], _ i: Int)
        -> (text: String, interpolated: Bool, end: Int, newlines: Int)? {
        var j = i
        var verbatim = false, interpolated = false
        while j < s.count, s[j] == "@" || s[j] == "$" {
            if s[j] == "@" { verbatim = true } else { interpolated = true }
            j += 1
        }
        guard j < s.count, s[j] == "\"" else { return nil }
        // `"""сырые"""` — редкость в логах; пропускаем целиком, шаблоном не считаем.
        if j + 2 < s.count, s[j + 1] == "\"", s[j + 2] == "\"" {
            var k = j + 3
            var newlines = 0
            while k + 2 < s.count, !(s[k] == "\"" && s[k + 1] == "\"" && s[k + 2] == "\"") {
                if s[k] == "\n" { newlines += 1 }
                k += 1
            }
            return ("", interpolated, min(s.count, k + 3), newlines)
        }
        j += 1
        var out = String.UnicodeScalarView()
        var newlines = 0
        while j < s.count {
            let c = s[j]
            if c == "\n" {
                newlines += 1
                if !verbatim { return (String(out), interpolated, j, newlines - 1) }
            }
            if c == "\"" {
                if verbatim, j + 1 < s.count, s[j + 1] == "\"" { out.append("\""); j += 2; continue }
                return (String(out), interpolated, j + 1, newlines)
            }
            if c == "\\", !verbatim, j + 1 < s.count {
                let e = s[j + 1]
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case "u" where j + 5 < s.count:
                    if let v = UInt32(String(String.UnicodeScalarView(s[(j + 2)...(j + 5)])), radix: 16),
                       let scalar = Unicode.Scalar(v) {
                        out.append(scalar)
                        j += 6
                        continue
                    }
                    out.append(e)
                default: out.append(e)
                }
                j += 2
                continue
            }
            if interpolated, c == "{" {
                if j + 1 < s.count, s[j + 1] == "{" { out.append("{"); out.append("{"); j += 2; continue }
                // Дырка: до парной `}`, мимо вложенных скобок и строк.
                var depth = 1
                j += 1
                while j < s.count, depth > 0 {
                    if isLiteralStart(s, j), let inner = stringLiteral(s, j) { j = inner.end; newlines += inner.newlines; continue }
                    if s[j] == "{" { depth += 1 } else if s[j] == "}" { depth -= 1 } else if s[j] == "\n" { newlines += 1 }
                    j += 1
                }
                out.append("{"); out.append("}")
                continue
            }
            if interpolated, c == "}", j + 1 < s.count, s[j + 1] == "}" { out.append("}"); out.append("}"); j += 2; continue }
            out.append(c)
            j += 1
        }
        return nil
    }
}
