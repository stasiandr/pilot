import Foundation

/// Ключи перевода, которые код на самом деле спрашивает: литералы в `L(…)`
/// и русские формы в `count(n, "файл", "файла", "файлов")`. Разбор —
/// ровно настолько, насколько нужен: строки с интерполяцией (в том числе
/// вложенные строки в ней), комментарии, сырые и многострочные строки.
enum LocalizationAudit {
    struct Keys {
        /// Ключ → где встретился (`Файл.swift:строка`).
        var strings: [String: String] = [:]
        var plurals: [String: String] = [:]
    }

    static func keys(in directory: String) -> Keys {
        var keys = Keys()
        guard let files = FileManager.default.enumerator(atPath: directory) else { return keys }
        for case let path as String in files where path.hasSuffix(".swift") && !path.hasPrefix("Localization/") {
            guard let text = try? String(contentsOfFile: directory + "/" + path, encoding: .utf8) else { continue }
            collect(Array(text.unicodeScalars), file: (path as NSString).lastPathComponent, into: &keys)
        }
        return keys
    }

    private struct Literal {
        var start: Int
        var end: Int
        var key: String
    }

    private static func collect(_ s: [Unicode.Scalar], file: String, into keys: inout Keys) {
        var literals: [Literal] = []
        var i = 0
        while i < s.count {
            if starts(s, i, "//") {
                while i < s.count && s[i] != "\n" { i += 1 }
            } else if starts(s, i, "/*") {
                var depth = 1
                i += 2
                while i < s.count && depth > 0 {
                    if starts(s, i, "/*") { depth += 1; i += 2 }
                    else if starts(s, i, "*/") { depth -= 1; i += 2 }
                    else { i += 1 }
                }
            } else if starts(s, i, "\"\"\"") {
                i += 3
                while i < s.count && !starts(s, i, "\"\"\"") { i += 1 }
                i += 3
            } else if starts(s, i, "#\"") {
                i += 2
                while i < s.count && !starts(s, i, "\"#") { i += 1 }
                i += 2
            } else if s[i] == "\"" {
                let (end, key) = string(s, i)
                literals.append(Literal(start: i, end: end, key: key))
                i = end
            } else {
                i += 1
            }
        }

        func line(_ offset: Int) -> Int { s[..<offset].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) } }
        func before(_ offset: Int) -> Int {
            var k = offset - 1
            while k >= 0 && (s[k] == " " || s[k] == "\t" || s[k] == "\n") { k -= 1 }
            return k
        }
        /// Между двумя литералами — одна запятая: это соседние аргументы.
        func onlyComma(_ from: Int, _ to: Int) -> Bool {
            let between = s[from..<to].filter { $0 != " " && $0 != "\t" && $0 != "\n" }
            return between.count == 1 && between.first == ","
        }
        func identifier(endingAt k: Int) -> String {
            var a = k
            while a >= 0 && (s[a].properties.isAlphabetic || s[a] == "_" || ("0"..."9").contains(s[a])) { a -= 1 }
            return a == k ? "" : String(String.UnicodeScalarView(s[(a + 1)...k]))
        }

        for (n, literal) in literals.enumerated() {
            let k = before(literal.start)
            guard k >= 0 else { continue }
            if s[k] == "(" && identifier(endingAt: k - 1) == "L" {
                keys.strings[literal.key] = keys.strings[literal.key] ?? "\(file):\(line(literal.start))"
            }
            // count(n, "файл", "файла", "файлов") и word(for: n, …): три
            // русские формы подряд.
            if s[k] == ",", n + 2 < literals.count,
               literal.key.unicodeScalars.contains(where: { ("а"..."я").contains($0) || ("А"..."Я").contains($0) }) {
                let second = literals[n + 1], third = literals[n + 2]
                guard onlyComma(literal.end, second.start), onlyComma(second.end, third.start) else { continue }
                // Три формы — аргументы одного вызова, который зовётся count или word.
                var open = before(literal.start)
                var depth = 0
                while open >= 0 {
                    if s[open] == ")" { depth += 1 }
                    if s[open] == "(" { if depth == 0 { break }; depth -= 1 }
                    open -= 1
                }
                guard open > 0 else { continue }
                let callee = identifier(endingAt: open - 1)
                guard callee == "count" || callee == "word" else { continue }
                let after = third.end
                var j = after
                while j < s.count && (s[j] == " " || s[j] == "\n") { j += 1 }
                guard j < s.count, s[j] == ")" || s[j] == "," else { continue }
                let key = literal.key + "|" + second.key + "|" + third.key
                keys.plurals[key] = keys.plurals[key] ?? "\(file):\(line(literal.start))"
            }
        }
    }

    private static func starts(_ s: [Unicode.Scalar], _ i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix.unicodeScalars)
        return i + p.count <= s.count && Array(s[i..<(i + p.count)]) == p
    }

    /// Строка с `s[i] == "\""`: где кончается и какой у неё ключ —
    /// интерполяция становится `%@`, знак процента — `%%`.
    private static func string(_ s: [Unicode.Scalar], _ start: Int) -> (Int, String) {
        var key = ""
        var i = start + 1
        while i < s.count {
            let c = s[i]
            if c == "\\" && i + 1 < s.count {
                let d = s[i + 1]
                if d == "(" {
                    i = interpolationEnd(s, i + 2)
                    key += "%@"
                    continue
                }
                switch d {
                case "n": key += "\n"
                case "t": key += "\t"
                case "0": key += "\0"
                default: key.unicodeScalars.append(d)
                }
                i += 2
                continue
            }
            if c == "\"" { return (i + 1, key) }
            if c == "\n" { return (i, key) }
            if c == "%" { key += "%%" } else { key.unicodeScalars.append(c) }
            i += 1
        }
        return (i, key)
    }

    private static func interpolationEnd(_ s: [Unicode.Scalar], _ from: Int) -> Int {
        var depth = 1
        var i = from
        while i < s.count && depth > 0 {
            if s[i] == "\"" { i = string(s, i).0; continue }
            if s[i] == "(" { depth += 1 }
            if s[i] == ")" { depth -= 1 }
            i += 1
        }
        return i
    }
}
