import Foundation

/// Конфиги и код, который их читает, — по правилам `ConfigRules` из
/// расширения проекта.
///
/// Данные — JSON в папке конфигов; что лежит в каком файле, говорит реестр в
/// ней: путь файла → его alias. Alias — константа в классе алиасов (в обеих
/// половинах пары), рядом может стоять модель:
/// `[ModelAttribute(typeof(LevelsModel))] public const string Levels = "Levels";`.
/// По модели так же находятся её alias'ы, а с ними и конфиги (`ConfigModels`).
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

    /// Объявление alias'а в классе алиасов и типы из `typeof(…)` в его
    /// атрибутах — на той же строке или строками выше. Атрибутов бывает
    /// несколько, и у половин пары они свои:
    ///
    /// ```csharp
    /// [JsonType(typeof(LevelsModel))] public const string Levels = "Levels";
    /// [ConfigPrewarm(typeof(PositionsItemModel))]
    /// [ConfigPrewarm(typeof(DirectedPositionsItemModel))]
    /// public const string TradePoints = "TradeVehiclePoints";
    /// ```
    struct AliasDeclaration: Equatable, Sendable {
        var alias: String
        var constant: String
        /// Строка константы и колонка её имени (UTF-16), с нуля.
        var line: Int
        var column: Int
        /// Тексты внутри `typeof(…)` как написаны, по порядку.
        var types: [String]
    }

    /// Все объявления alias'ов в тексте класса алиасов.
    static func declarations(in text: String) -> [AliasDeclaration] {
        var result: [AliasDeclaration] = []
        // Типы из атрибутов, которые ещё не дошли до своей константы.
        var pending: [String] = []
        for (number, raw) in lines(of: text).enumerated() {
            let line = code(of: raw)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Пустая строка, `#region` — атрибуты над ними всё ещё относятся
            // к следующему объявлению. Комментарий сюда тоже попадает: от
            // него остаётся пустая строка.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let types = typeofTexts(in: line)
            if let constant = ConfigCatalog.constant(in: line),
               String(decoding: line.utf16.prefix(constant.column), as: UTF16.self)
                   .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).contains("const") {
                result.append(AliasDeclaration(alias: constant.value, constant: constant.name, line: number,
                                               column: constant.column, types: pending + types))
                pending = []
            } else if isAttributeLine(trimmed) {
                pending += types
            } else {
                pending = []
            }
        }
        return result
    }

    /// Строка — одни атрибуты, `[A(…)]` или `[A][B]`, без объявления после них.
    private static func isAttributeLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    }

    /// Строка `line` и атрибуты прямо над ней — там, где у константы стоит
    /// атрибут модели (по тем же правилам, что у `declarations`).
    static func attributeLines(endingAt line: Int, in lines: [Substring]) -> [String] {
        guard line >= 0, line < lines.count else { return [] }
        var result = [String(lines[line])]
        var above = line - 1
        while above >= 0 {
            let trimmed = code(of: lines[above]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                guard isAttributeLine(trimmed) else { break }
                result.append(String(lines[above]))
            }
            above -= 1
        }
        return result
    }

    /// Все алиасы класса алиасов с моделями: `typeof(…)` в атрибутах той же
    /// строки (`[JsonType(typeof(M))] public const string A = "A";`) или
    /// строк над ней (`[ConfigPrewarm(typeof(M))]` отдельной строкой).
    struct AliasModel: Equatable {
        var constant: String
        var alias: String
        var models: [String]
    }

    static func aliasModels(in text: String) -> [AliasModel] {
        var result: [AliasModel] = []
        var pending: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.isEmpty { continue }
            var models = typeofModels(in: line)
            if let alias = alias(declaredIn: line), let equals = line.range(of: "=") {
                let head = line[..<equals.lowerBound]
                let words = head.split { !($0.isLetter || $0.isNumber || $0 == "_") }
                if let constant = words.last {
                    models = pending + models
                    result.append(AliasModel(constant: String(constant), alias: alias, models: models))
                }
                pending = []
            } else if line.hasPrefix("[") {
                // Атрибут отдельной строкой — к следующей константе.
                pending += models
            } else {
                pending = []
            }
        }
        return result
    }

    /// Имена типов во всех `typeof(…)` строки — короткие, и аргументы
    /// обобщений тоже: у `typeof(Dictionary<string, JobReward[]>)` модель —
    /// и `Dictionary`, и `JobReward`.
    static func typeofModels(in line: String) -> [String] {
        var result: [String] = []
        var rest = Substring(line)
        while let start = rest.range(of: "typeof(") {
            var depth = 1
            var word = ""
            var index = start.upperBound
            func flush() {
                if !word.isEmpty, word.first?.isNumber == false { result.append(word) }
                word = ""
            }
            while index < rest.endIndex, depth > 0 {
                let c = rest[index]
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                if c.isLetter || c.isNumber || c == "_" {
                    word.append(c)
                } else if c == "." {
                    word = ""
                } else {
                    flush()
                }
                index = rest.index(after: index)
            }
            flush()
            rest = rest[index...]
        }
        return result
    }

    /// Значения ключа `key` в тексте JSON: строка (с нуля) и то, что стоит
    /// после двоеточия, — число, строка в кавычках; объект и массив,
    /// открытые и не закрытые на этой строке, — `{…}` и `[…]`.
    static func jsonValues(ofKey key: String, in text: String) -> [(line: Int, value: String)] {
        let needle = "\"\(key)\""
        guard text.contains(needle) else { return [] }
        var result: [(Int, String)] = []
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var rest = line[...]
            while let found = rest.range(of: needle) {
                var after = found.upperBound
                while after < rest.endIndex, rest[after] == " " || rest[after] == "\t" { after = rest.index(after: after) }
                guard after < rest.endIndex, rest[after] == ":" else {
                    rest = rest[found.upperBound...]
                    continue
                }
                var value = rest[rest.index(after: after)...].trimmingCharacters(in: .whitespaces)
                value = jsonScalar(value)
                result.append((number, value))
                break
            }
        }
        return result
    }

    /// Значение до конца своего уровня: `25,` → `25`, `"a,b"` → `"a,b"`,
    /// `{ "x": 1 }` → как есть, `{` без пары на строке → `{…}`.
    private static func jsonScalar(_ text: String) -> String {
        guard let first = text.first else { return "" }
        if first == "\"" {
            var escaped = false
            var index = text.index(after: text.startIndex)
            while index < text.endIndex {
                let c = text[index]
                if c == "\"", !escaped { return String(text[...index]) }
                escaped = c == "\\" && !escaped
                index = text.index(after: index)
            }
            return text
        }
        if first == "{" || first == "[" {
            let close: Character = first == "{" ? "}" : "]"
            var depth = 0
            for (offset, c) in text.enumerated() {
                if c == first { depth += 1 } else if c == close {
                    depth -= 1
                    if depth == 0 { return String(text.prefix(offset + 1)) }
                }
            }
            return first == "{" ? "{…}" : "[…]"
        }
        let end = text.firstIndex { $0 == "," || $0 == "}" || $0 == "]" } ?? text.endIndex
        return text[..<end].trimmingCharacters(in: .whitespaces)
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

    /// Тексты внутри всех `typeof(…)` строки; скобки внутри — парные.
    static func typeofTexts(in line: String) -> [String] {
        var result: [String] = []
        var rest = Substring(line)
        while let start = rest.range(of: "typeof(") {
            // `typeof` — отдельное слово, а не хвост другого имени.
            if start.lowerBound > rest.startIndex {
                let before = rest[rest.index(before: start.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" {
                    rest = rest[start.upperBound...]
                    continue
                }
            }
            var depth = 1
            var end = start.upperBound
            while end < rest.endIndex {
                if rest[end] == "(" { depth += 1 }
                if rest[end] == ")" { depth -= 1; if depth == 0 { break } }
                end = rest.index(after: end)
            }
            guard end < rest.endIndex else { break }
            let text = rest[start.upperBound..<end].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(text) }
            rest = rest[rest.index(after: end)...]
        }
        return result
    }

    /// Встроенные типы C#: моделью конфига они не бывают.
    static let builtinTypes: Set<String> = [
        "bool", "byte", "sbyte", "char", "decimal", "double", "float", "int", "uint", "nint", "nuint",
        "long", "ulong", "short", "ushort", "object", "string", "dynamic", "void",
    ]

    /// Имена типов в тексте `typeof(…)`, последнее — первым, как у
    /// `ConfigCatalog.typeNames`, но без пространств имён и внешних типов —
    /// `Server.Models.LevelsModel` это `LevelsModel` — и без встроенных.
    static func typeNames(inTypeof text: String) -> [String] {
        let characters = Array(text)
        var names: [String] = []
        var current = ""
        for (i, c) in characters.enumerated() {
            if c.isLetter || c.isNumber || c == "_" {
                current.append(c)
                guard i + 1 == characters.count else { continue }
            }
            guard !current.isEmpty else { continue }
            // За именем точка или `::` — это пространство имён или тип, в
            // который вложен следующий.
            var next = i
            while next < characters.count, characters[next] == " " { next += 1 }
            let qualifier = next < characters.count && (characters[next] == "." || characters[next] == ":")
            if !qualifier, !builtinTypes.contains(current) { names.append(current) }
            current = ""
        }
        return names.reversed()
    }

    /// Модель в тексте `typeof(…)` — та, к которой ведёт «Модель конфига»:
    /// последнее имя, которое — тип проекта (`isType`). У
    /// `Dictionary<ElementModel, ItemModel>` это `ItemModel`, у
    /// `List<JobData>` — `JobData`, у `Dictionary<string, string[]>` модели нет.
    static func model(inTypeof text: String, isType: (String) -> Bool) -> String? {
        typeNames(inTypeof: text).first(where: isType)
    }

    /// Строки текста: `\r\n` — тоже один перевод строки (для Swift это
    /// одна буква, и по `\n` такой текст не делится).
    static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
    }

    /// Строка без комментария `// …` — если он не внутри строкового литерала.
    static func code(of line: Substring) -> String {
        var inString = false
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if c == "\"", previous != "\\" { inString.toggle() }
            if !inString, c == "/", previous == "/" { return String(line[..<line.index(before: index)]) }
            previous = c
            index = line.index(after: index)
        }
        return String(line)
    }

    /// В строке JSON есть ключ `"key":`, а не только такое значение.
    static func isKey(_ key: String, in line: String) -> Bool {
        let quoted = "\"\(key)\""
        var rest = Substring(line)
        while let found = rest.range(of: quoted) {
            rest = rest[found.upperBound...]
            if rest.drop(while: { $0 == " " || $0 == "\t" }).first == ":" { return true }
        }
        return false
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

/// Модели конфигов: какой alias какую модель читает — по классу алиасов
/// (файлам `<aliases>.cs` проекта). Тип — модель alias'а, если к нему ведёт
/// «Модель конфига» этого alias'а (`ConfigLinks.model`): ключ словаря и
/// обёртка вроде `List<…>` моделью не считаются. Так модель, как и сам
/// alias, умеет открыть свой конфиг.
struct ConfigModels: Sendable {
    /// Объявление alias'а и файл, где оно стоит.
    struct Use: Equatable, Sendable {
        /// Класс алиасов — путь от корня проекта.
        var file: String
        var declaration: ConfigLinks.AliasDeclaration

        var alias: String { declaration.alias }

        /// Имя константы alias'а — туда ведёт «Алиас в коде».
        func target(root: URL) -> NavTarget {
            let start = LSPPosition(line: declaration.line, character: declaration.column)
            let end = LSPPosition(line: declaration.line,
                                  character: declaration.column + declaration.constant.utf16.count)
            return NavTarget(url: root.appendingPathComponent(file), range: LSPRange(start: start, end: end))
        }
    }

    /// Все объявления alias'ов, по файлам и строкам.
    let uses: [Use]
    /// Имя из `typeof(…)` → номера в `uses`.
    private let byName: [String: [Int]]

    init(files: [(path: String, text: String)]) {
        var uses: [Use] = []
        var byName: [String: [Int]] = [:]
        for file in files {
            for declaration in ConfigLinks.declarations(in: file.text) {
                for name in Set(declaration.types.flatMap(ConfigLinks.typeNames(inTypeof:))) {
                    byName[name, default: []].append(uses.count)
                }
                uses.append(Use(file: file.path, declaration: declaration))
            }
        }
        self.uses = uses
        self.byName = byName
    }

    /// Объявления alias'ов, чья модель — тип `name`, по порядку. `isType` —
    /// объявлен ли в проекте тип с таким именем; про сам `name` спрашивающий
    /// уже знает, что да (он под курсором или в индексе).
    func uses(ofModel name: String, isType: (String) -> Bool) -> [Use] {
        (byName[name] ?? []).map { uses[$0] }.filter { use in
            use.declaration.types.contains { text in
                ConfigLinks.model(inTypeof: text, isType: { $0 == name || isType($0) }) == name
            }
        }
    }

    /// Объявления этого alias'а (в классе алиасов — обычно одно).
    func uses(ofAlias alias: String) -> [Use] {
        uses.filter { $0.alias == alias }
    }
}
