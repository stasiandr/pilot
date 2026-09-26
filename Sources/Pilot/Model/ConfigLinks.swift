import Foundation

/// Конфиги и код, который их читает, — по правилам `ConfigRules` из
/// расширения проекта.
///
/// Данные — JSON в папке конфигов; что лежит в каком файле, говорит реестр в
/// ней: путь файла → его alias. Alias — константа в классе алиасов (в обеих
/// половинах пары), рядом может стоять модель:
/// `[ModelAttribute(typeof(LevelsModel))] public const string Levels = "Levels";`.
/// Ключи JSON связаны с полями моделей атрибутом ключа: `[JsonProperty("key")]`.
///
/// Здесь только разбор этих текстов; поиск по проектам — у воркспейса.
/// Без AppKit — проверяется тестами ядра.
enum ConfigLinks {


    /// Реестр: путь файла от папки конфигов → alias.
    static func aliases(meta data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var result: [String: String] = [:]
        func walk(_ value: Any) {
            if let entry = value as? [String: Any], let path = entry["path"] as? String,
               let alias = entry["alias"] as? String {
                result[path] = alias
            } else if let dictionary = value as? [String: Any] {
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(object)
        return result
    }

    /// Строка класса алиасов с этим alias: имя константы и модель из
    /// `[ConfigModel(typeof(…))]`, если она указана.
    struct AliasDeclaration: Equatable {
        var constant: String
        var model: String?
        /// Строка с нуля.
        var line: Int
    }

    static func declaration(of alias: String, in text: String) -> AliasDeclaration? {
        let quoted = "\"\(alias)\""
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.contains(quoted) && line.contains("const") {
            guard let equals = line.range(of: "=") else { continue }
            let head = line[..<equals.lowerBound]
            let words = head.split { !($0.isLetter || $0.isNumber || $0 == "_") }
            guard let constant = words.last else { continue }
            return AliasDeclaration(constant: String(constant), model: typeofModel(in: String(line)), line: number)
        }
        return nil
    }

    /// Alias, объявленный в строке класса алиасов: `… = "Levels";`.
    static func alias(declaredIn line: String) -> String? {
        guard line.contains("const"), line.contains("string"),
              let equals = line.range(of: "="),
              let open = line[equals.upperBound...].firstIndex(of: "\"") else { return nil }
        let rest = line[line.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let alias = String(rest[..<close])
        return alias.isEmpty ? nil : alias
    }

    /// Модель из `typeof(Имя)`: `Dictionary<string, string[]>` — это не
    /// модель, а только её короткое имя без обобщений.
    static func typeofModel(in line: String) -> String? {
        guard let start = line.range(of: "typeof(") else { return nil }
        var name = ""
        for ch in line[start.upperBound...] {
            if ch.isLetter || ch.isNumber || ch == "_" { name.append(ch) }
            else if ch == "." { name = "" }
            else { break }
        }
        return name.isEmpty ? nil : name
    }

    /// Ключ из `[JsonProperty("key")]` или `[JsonProperty(PropertyName = "key")]`;
    /// `attribute` — имя атрибута ключа из правил.
    static func jsonProperty(in line: String, attribute: String) -> String? {
        guard let start = line.range(of: attribute + "(") else { return nil }
        let rest = line[start.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        let tail = rest[rest.index(after: open)...]
        guard let close = tail.firstIndex(of: "\"") else { return nil }
        let key = String(tail[..<close])
        return key.isEmpty ? nil : key
    }

    /// Ключ JSON под курсором: строка в кавычках, за которой идёт `:`.
    /// `offset` — в UTF-16.
    static func jsonKey(at offset: Int, in text: String) -> String? {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return nil }
        let quote: UInt16 = 0x22, backslash: UInt16 = 0x5C, newline: UInt16 = 0x0A
        // Строки файла по порядку: кавычки, найденные с начала строки, — иначе
        // не понять, открывающая перед курсором кавычка или закрывающая.
        var lineStart = min(offset, units.count - 1)
        while lineStart > 0, units[lineStart - 1] != newline { lineStart -= 1 }
        var i = lineStart
        while i < units.count, units[i] != newline {
            guard units[i] == quote else { i += 1; continue }
            let open = i
            i += 1
            while i < units.count, units[i] != quote, units[i] != newline {
                i += units[i] == backslash ? 2 : 1
            }
            guard i < units.count, units[i] == quote else { return nil }
            let close = i
            i += 1
            guard offset >= open, offset <= close + 1 else { continue }
            var after = i
            while after < units.count, units[after] == 0x20 || units[after] == 0x09 { after += 1 }
            guard after < units.count, units[after] == 0x3A else { return nil }   // :
            return String(utf16CodeUnits: Array(units[(open + 1)..<close]), count: close - open - 1)
        }
        return nil
    }

    /// Папка конфигов над файлом — та, где лежит реестр `registry`.
    static func configsRoot(of file: URL, registry: String, exists: (String) -> Bool) -> URL? {
        var directory = file.deletingLastPathComponent()
        while directory.path != "/" {
            if exists(directory.appendingPathComponent(registry).path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
