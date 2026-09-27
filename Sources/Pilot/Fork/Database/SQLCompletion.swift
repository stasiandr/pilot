import Foundation

// MARK: - Схема сервера

/// Что известно о базах сервера — для дополнения имён. Заполняет
/// `DatabaseBrowser` из information_schema, здесь — только данные и поиск.
struct SQLCatalog {
    struct Column: Equatable {
        var name: String
        var type: String
    }

    struct Table: Equatable {
        var name: String
        var isView = false
        /// По порядку в таблице (ORDINAL_POSITION).
        var columns: [Column] = []
    }

    struct Routine: Equatable {
        var name: String
        var isProcedure: Bool
    }

    struct Schema: Equatable {
        var tables: [Table] = []
        var routines: [Routine] = []
    }

    /// Все базы сервера (`SHOW DATABASES`).
    var schemaNames: [String] = []
    /// Базы, чьи таблицы, столбцы и процедуры уже прочитаны.
    var schemas: [String: Schema] = [:]
    /// База по умолчанию (`USE`).
    var current: String?

    /// Имя базы как на сервере: сперва точное совпадение, потом без учёта регистра.
    func schemaName(_ name: String) -> String? {
        if schemaNames.contains(name) || schemas[name] != nil { return name }
        let lower = name.lowercased()
        return schemaNames.first { $0.lowercased() == lower } ?? schemas.keys.first { $0.lowercased() == lower }
    }

    /// Таблица по имени: в базе `schema`, а без неё — в текущей.
    func table(_ name: String, schema: String?) -> (schema: String, table: Table)? {
        guard let resolved = schema.map(schemaName) ?? current, let tables = schemas[resolved]?.tables else {
            return nil
        }
        if let exact = tables.first(where: { $0.name == name }) { return (resolved, exact) }
        let lower = name.lowercased()
        return tables.first { $0.name.lowercased() == lower }.map { (resolved, $0) }
    }

    /// База есть на сервере, но её таблиц ещё не читали: имя — чтобы прочитать.
    func unloaded(_ schema: String?) -> String? {
        guard let name = schema.map(schemaName) ?? current, schemas[name] == nil,
              schemaNames.contains(name) else { return nil }
        return name
    }
}

extension SQLCatalog.Schema {
    /// Из строк information_schema: TABLES (имя, тип), COLUMNS (таблица,
    /// столбец, тип — по порядку столбцов) и ROUTINES (имя, тип).
    init(tableRows: [[String?]], columnRows: [[String?]], routineRows: [[String?]]) {
        var order: [String] = []
        var byName: [String: SQLCatalog.Table] = [:]
        for row in tableRows {
            guard let name = row.first ?? nil else { continue }
            if byName[name] == nil { order.append(name) }
            let type = row.count > 1 ? row[1] ?? "" : ""
            byName[name] = SQLCatalog.Table(name: name, isView: type.contains("VIEW"))
        }
        for row in columnRows {
            guard row.count >= 2, let table = row[0], let column = row[1] else { continue }
            if byName[table] == nil {
                order.append(table)
                byName[table] = SQLCatalog.Table(name: table)
            }
            byName[table]?.columns.append(SQLCatalog.Column(name: column, type: row.count > 2 ? row[2] ?? "" : ""))
        }
        tables = order.compactMap { byName[$0] }
        routines = routineRows.compactMap { row in
            guard let name = row.first ?? nil else { return nil }
            return SQLCatalog.Routine(name: name, isProcedure: (row.count > 1 ? row[1] ?? "" : "") == "PROCEDURE")
        }
    }
}

// MARK: - Лексемы

/// Лексема SQL для разбора запроса. Смещения — в UTF-16, как у NSTextView
/// и `SyntaxModel`.
struct SQLToken: Equatable {
    enum Kind: Equatable {
        /// Имя или ключевое слово.
        case word
        /// `имя` в обратных кавычках.
        case quoted
        /// '…' или "…".
        case string
        case number
        /// @x, @@global.x.
        case variable
        case comment
        /// . , ( ) ; и знаки операций — по одному символу.
        case symbol
    }

    var kind: Kind
    var start: Int
    var end: Int
    /// Как написано; у `quoted` — имя без кавычек, у комментария — его начало (`--`, `#`, `/*`).
    var text: String
    /// Незакрытые строка, имя или блочный комментарий идут до конца текста.
    var closed = true

    /// Слово заглавными — для сравнения с ключевыми словами.
    var key: String { kind == .word ? text.uppercased() : "" }
    var isName: Bool { kind == .word || kind == .quoted }
    func isSymbol(_ s: String) -> Bool { kind == .symbol && text == s }
}

/// Лексер SQL MariaDB. Строки, имена и комментарии понимает так же, как
/// подсветка (`SQLDialect.mariadb`), — дополнение не спорит с цветом.
enum SQLLexer {

    static func tokens(_ text: String) -> [SQLToken] {
        let units = Array(text.utf16)
        return tokens(units, in: 0..<units.count)
    }

    static func tokens(_ u: [UInt16], in range: Range<Int>) -> [SQLToken] {
        var out: [SQLToken] = []
        let n = min(range.upperBound, u.count)
        var i = max(0, range.lowerBound)
        func text(_ a: Int, _ b: Int) -> String { String(decoding: u[a..<b], as: UTF16.self) }

        while i < n {
            let c = u[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C { i += 1; continue }
            let start = i

            // -- и # — до конца строки
            if (c == 0x2D && i + 1 < n && u[i + 1] == 0x2D) || c == 0x23 {
                while i < n && u[i] != 0x0A { i += 1 }
                out.append(SQLToken(kind: .comment, start: start, end: i, text: c == 0x23 ? "#" : "--"))
                continue
            }
            // /* … */
            if c == 0x2F && i + 1 < n && u[i + 1] == 0x2A {
                i += 2
                var closed = false
                while i < n {
                    if u[i] == 0x2A && i + 1 < n && u[i + 1] == 0x2F { i += 2; closed = true; break }
                    i += 1
                }
                out.append(SQLToken(kind: .comment, start: start, end: i, text: "/*", closed: closed))
                continue
            }
            // '…' и "…": \ экранирует, сдвоенная кавычка — часть строки
            if c == 0x27 || c == 0x22 {
                i += 1
                var closed = false
                while i < n {
                    if u[i] == 0x5C && i + 1 < n { i += 2; continue }
                    if u[i] == c {
                        if i + 1 < n && u[i + 1] == c { i += 2; continue }
                        i += 1
                        closed = true
                        break
                    }
                    i += 1
                }
                out.append(SQLToken(kind: .string, start: start, end: i, text: "", closed: closed))
                continue
            }
            // `имя`: `` — сама кавычка; на новую строку не переходит, как и в подсветке
            if c == 0x60 {
                i += 1
                var name: [UInt16] = []
                var closed = false
                while i < n && u[i] != 0x0A {
                    if u[i] == 0x60 {
                        if i + 1 < n && u[i + 1] == 0x60 { name.append(0x60); i += 2; continue }
                        i += 1
                        closed = true
                        break
                    }
                    name.append(u[i])
                    i += 1
                }
                out.append(SQLToken(kind: .quoted, start: start, end: i,
                                    text: String(decoding: name, as: UTF16.self), closed: closed))
                continue
            }
            // @переменная, @@global.системная, @'в кавычках'
            if c == 0x40 {
                i += 1
                while i < n && u[i] == 0x40 { i += 1 }
                if i < n, u[i] == 0x27 || u[i] == 0x22 || u[i] == 0x60 {
                    let quote = u[i]
                    i += 1
                    while i < n && u[i] != quote && u[i] != 0x0A { i += 1 }
                    if i < n && u[i] == quote { i += 1 }
                } else {
                    while i < n && (isIdentPart(u[i]) || u[i] == 0x2E) { i += 1 }
                }
                out.append(SQLToken(kind: .variable, start: start, end: i, text: text(start, i)))
                continue
            }
            // Слово или число. Имя в MySQL может начинаться с цифры (`2fa_codes`),
            // поэтому число — только то, что целиком похоже на число.
            if isIdentPart(c) {
                while i < n && isIdentPart(u[i]) { i += 1 }
                if let end = numberEnd(u, start, i, n) {
                    out.append(SQLToken(kind: .number, start: start, end: end, text: text(start, end)))
                    i = end
                } else {
                    out.append(SQLToken(kind: .word, start: start, end: i, text: text(start, i)))
                }
                continue
            }
            out.append(SQLToken(kind: .symbol, start: start, end: i + 1, text: text(start, i + 1)))
            i += 1
        }
        return out
    }

    /// Конец числа, если слово `[start, end)` — число: 42, 1.5, 1e-3, 0x1F, 0b101.
    private static func numberEnd(_ u: [UInt16], _ start: Int, _ end: Int, _ n: Int) -> Int? {
        let run = u[start..<end]
        guard let first = run.first, isDigit(first) else { return nil }
        if run.count > 2, first == 0x30 {
            let marker = run[start + 1]
            let body = run.dropFirst(2)
            if marker == 0x78 || marker == 0x58 { return body.allSatisfy(isHex) ? end : nil }
            if marker == 0x62 || marker == 0x42 { return body.allSatisfy { $0 == 0x30 || $0 == 0x31 } ? end : nil }
        }
        var i = start
        while i < end && isDigit(u[i]) { i += 1 }
        if i == end, end + 1 < n, u[end] == 0x2E, isDigit(u[end + 1]) {
            // дробная часть — уже за словом
            i = end + 1
            while i < n && isDigit(u[i]) { i += 1 }
            return exponentEnd(u, i, n) ?? (i < n && isIdentPart(u[i]) ? nil : i)
        }
        if i == end { return end }
        // 1e5 или 1e-5
        guard u[i] == 0x65 || u[i] == 0x45 else { return nil }
        if i + 1 == end { return exponentEnd(u, i, n) }
        var j = i + 1
        while j < end && isDigit(u[j]) { j += 1 }
        return j == end ? end : nil
    }

    /// `e5`, `E-3` сразу за цифрами.
    private static func exponentEnd(_ u: [UInt16], _ i: Int, _ n: Int) -> Int? {
        guard i < n, u[i] == 0x65 || u[i] == 0x45 else { return nil }
        var j = i + 1
        if j < n, u[j] == 0x2B || u[j] == 0x2D { j += 1 }
        guard j < n, isDigit(u[j]) else { return nil }
        while j < n && isDigit(u[j]) { j += 1 }
        return j
    }

    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) private static func isHex(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
    /// Символ имени MySQL: латиница, цифры, `_`, `$` и всё не-ASCII.
    @inline(__always) static func isIdentPart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || isDigit(c) || c == 0x5F || c == 0x24 || c > 0x7F
    }
}

// MARK: - Разбор запроса

/// Таблица, упомянутая в запросе: `FROM db.users AS u`.
struct SQLTableRef: Equatable {
    var schema: String?
    /// Пусто у подзапроса: `(SELECT …) AS t`.
    var name: String
    var alias: String?
    /// У подзапроса — имена его списка SELECT; `*` и `t.*` раскрываются
    /// по его собственным таблицам (`inner`).
    var derived: [String]? = nil
    var inner: [SQLTableRef] = []
}

enum SQLStatement {

    /// Запросы текста — лексемы без комментариев, по одному массиву на запрос.
    static func split(_ tokens: [SQLToken]) -> [[SQLToken]] {
        var out: [[SQLToken]] = [[]]
        for token in tokens where token.kind != .comment {
            if token.isSymbol(";") { out.append([]) } else { out[out.count - 1].append(token) }
        }
        return out.filter { !$0.isEmpty }
    }

    /// Первое слово каждого запроса (заглавными) и имя за ним: `USE clm` →
    /// ("USE", "clm"). По ним видно, меняет ли текст схему или базу.
    static func heads(_ text: String) -> [(keyword: String, name: String?)] {
        split(SQLLexer.tokens(text)).compactMap { statement in
            guard let first = statement.first, first.kind == .word else { return nil }
            let next = statement.count > 1 && statement[1].isName ? statement[1].text : nil
            return (first.key, next)
        }
    }

    /// Таблицы запроса с псевдонимами: после FROM, JOIN, UPDATE, INTO, TABLE.
    /// Подзапросы тоже: их таблицы видны и во внешнем запросе — лишний
    /// вариант в списке лучше, чем недостающий.
    static func tableRefs(_ t: [SQLToken]) -> [SQLTableRef] {
        let head = t.first?.key ?? ""
        var refs: [SQLTableRef] = []
        // Кто открыл скобку: FROM внутри EXTRACT(… FROM …) — не таблица.
        var owners: [String] = []
        var i = 0
        while i < t.count {
            let token = t[i]
            if token.isSymbol("(") {
                owners.append(i > 0 ? t[i - 1].key : "")
                i += 1
                continue
            }
            if token.isSymbol(")") {
                _ = owners.popLast()
                i += 1
                continue
            }
            guard token.kind == .word else { i += 1; continue }
            var list = false
            switch token.key {
            case "FROM":
                if head == "SHOW" || functionsWithFrom.contains(owners.last ?? "") { i += 1; continue }
                list = true
            case "JOIN", "STRAIGHT_JOIN":
                break
            case "UPDATE", "DESCRIBE", "DESC", "EXPLAIN", "TRUNCATE":
                guard i == 0 else { i += 1; continue }
                list = token.key == "UPDATE"
            case "INTO":
                guard head == "INSERT" || head == "REPLACE" else { i += 1; continue }
            case "TABLE":
                list = true
            case "TABLES":
                guard head == "LOCK" else { i += 1; continue }
                list = true
            default:
                i += 1
                continue
            }
            i += 1
            while i < t.count, ["LOW_PRIORITY", "IGNORE", "IF", "NOT", "EXISTS", "ONLY", "LATERAL", "QUICK",
                                "TABLE"].contains(t[i].key) { i += 1 }
            while let (found, next) = parseRef(t, i) {
                refs += found
                i = next
                guard list, i < t.count, t[i].isSymbol(",") else { break }
                i += 1
            }
        }
        return refs
    }

    /// Имена из `WITH x AS (…), y AS (…)` — ими можно пользоваться как таблицами.
    static func cteNames(_ t: [SQLToken]) -> [String] {
        guard t.first?.key == "WITH" else { return [] }
        var names: [String] = []
        var i = 1
        if i < t.count, t[i].key == "RECURSIVE" { i += 1 }
        while i < t.count, t[i].isName {
            names.append(t[i].text)
            i += 1
            if i < t.count, t[i].isSymbol("(") { i = skipGroup(t, i) }
            guard i < t.count, t[i].key == "AS", i + 1 < t.count, t[i + 1].isSymbol("(") else { break }
            i = skipGroup(t, i + 1)
            guard i < t.count, t[i].isSymbol(",") else { break }
            i += 1
        }
        return names
    }

    /// Функции, внутри которых FROM — часть синтаксиса, а не таблица.
    static let functionsWithFrom: Set<String> = ["EXTRACT", "TRIM", "SUBSTRING", "SUBSTR", "POSITION", "OVERLAY"]

    /// Слова, которые после имени таблицы — продолжение запроса, а не псевдоним.
    private static let notAliases: Set<String> = [
        "ADD", "ALGORITHM", "AUTO_INCREMENT", "CHARSET", "CHECKSUM", "COMMENT", "DATA", "DISABLE",
        "DISCARD", "ENABLE", "ENGINE", "FULL", "IMPORT", "LOCAL", "LOCKED", "MAX_ROWS", "MIN_ROWS",
        "MODIFY", "NOWAIT", "PACK_KEYS", "ROW_FORMAT", "SKIP", "TABLESPACE", "TYPE", "VALUE", "WAIT",
    ]

    /// Одна таблица с `i`: `имя`, `база.имя`, `(подзапрос)`, дальше псевдоним
    /// и подсказки индексов. У подзапроса — ещё и его собственные таблицы.
    /// nil — здесь не таблица.
    private static func parseRef(_ t: [SQLToken], _ start: Int) -> ([SQLTableRef], Int)? {
        var i = start
        guard i < t.count else { return nil }
        var ref: SQLTableRef
        var inner: [SQLTableRef] = []
        if t[i].isSymbol("(") {
            let end = skipGroup(t, i)
            let body = Array(t[(i + 1)..<max(i + 1, end - 1)])
            inner = tableRefs(body)
            i = end
            ref = SQLTableRef(schema: nil, name: "", alias: nil, derived: selectNames(body), inner: inner)
        } else {
            guard t[i].kind == .quoted || (t[i].kind == .word && !SQLDialect.isReserved(t[i].text)) else { return nil }
            ref = SQLTableRef(schema: nil, name: t[i].text, alias: nil)
            i += 1
            if i + 1 < t.count, t[i].isSymbol("."), t[i + 1].isName {
                ref.schema = ref.name
                ref.name = t[i + 1].text
                i += 2
            }
        }
        if i + 1 < t.count, t[i].key == "PARTITION", t[i + 1].isSymbol("(") { i = skipGroup(t, i + 1) }
        if i + 1 < t.count, t[i].key == "AS", t[i + 1].isName {
            ref.alias = t[i + 1].text
            i += 2
        } else if i < t.count, t[i].kind == .quoted
                    || (t[i].kind == .word && !SQLDialect.isReserved(t[i].text) && !notAliases.contains(t[i].key)) {
            ref.alias = t[i].text
            i += 1
        }
        // USE INDEX (…), FORCE KEY FOR JOIN (…)
        while i + 1 < t.count, ["USE", "FORCE", "IGNORE"].contains(t[i].key), ["INDEX", "KEY"].contains(t[i + 1].key) {
            i += 2
            while i < t.count, !t[i].isSymbol("(") && t[i].kind == .word { i += 1 }
            if i < t.count, t[i].isSymbol("(") { i = skipGroup(t, i) }
        }
        if ref.name.isEmpty && ref.alias == nil { return inner.isEmpty ? nil : (inner, i) }
        return (inner + [ref], i)
    }

    /// Имена столбцов, которые отдаёт `SELECT …`: `a`, `t.b` → `b`,
    /// `expr AS c` и `expr c` → `c`; `*` и `t.*` — как есть. Выражение без
    /// имени (`COUNT(*)`) пропускается: сослаться на него по имени нельзя.
    static func selectNames(_ t: [SQLToken]) -> [String] {
        guard t.first?.key == "SELECT" else { return [] }
        let ends: Set<String> = ["FROM", "INTO", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "UNION", "WINDOW", "FOR"]
        var items: [[SQLToken]] = [[]]
        var depth = 0
        for token in t.dropFirst() {
            if depth == 0, ends.contains(token.key) { break }
            if token.isSymbol("(") { depth += 1 } else if token.isSymbol(")") { depth -= 1 }
            if depth == 0, token.isSymbol(",") { items.append([]); continue }
            items[items.count - 1].append(token)
        }
        let modifiers: Set<String> = ["DISTINCT", "DISTINCTROW", "ALL", "HIGH_PRIORITY", "STRAIGHT_JOIN",
                                      "SQL_CALC_FOUND_ROWS", "SQL_NO_CACHE", "SQL_CACHE"]
        var names: [String] = []
        for var item in items {
            while let first = item.first, modifiers.contains(first.key) { item.removeFirst() }
            guard let last = item.last else { continue }
            if last.isSymbol("*") {
                // `*` или `t.*`
                names.append(item.count >= 3 && item[item.count - 2].isSymbol(".") ? item[item.count - 3].text + ".*" : "*")
                continue
            }
            guard last.isName, !(last.kind == .word && SQLDialect.isReserved(last.text)) else { continue }
            if item.count == 1 { names.append(last.text); continue }
            let before = item[item.count - 2]
            // `t.col`, `expr AS c`, `expr c` — но не `a + b`: там имя стоит за знаком операции.
            if before.isSymbol(".") || before.key == "AS" || before.isName || before.isSymbol(")")
                || before.kind == .string || before.kind == .number {
                names.append(last.text)
            }
        }
        return names
    }

    /// Позиция за скобкой, парной к открывающей `open`.
    static func skipGroup(_ t: [SQLToken], _ open: Int) -> Int {
        var depth = 0
        var i = open
        while i < t.count {
            if t[i].isSymbol("(") { depth += 1 }
            if t[i].isSymbol(")") {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return i
    }
}

// MARK: - Дополнение

/// Варианты дополнения в SQL-редакторе, как в DataGrip: после FROM и JOIN —
/// таблицы, после `u.` — столбцы таблицы с псевдонимом `u`, в SELECT и
/// WHERE — сперва столбцы таблиц этого запроса, потом функции и ключевые
/// слова.
enum SQLCompletion {

    /// Что может стоять в месте курсора.
    enum Position: Equatable {
        /// Ничего не предлагаем: новое имя, число после LIMIT.
        case nothing
        /// Начало запроса.
        case statementStart
        /// После готового операнда — только ключевые слова (AS, FROM, JOIN…).
        case keywords
        case table
        case database
        /// Выражение: столбцы, функции, ключевые слова.
        case expression
        /// Внутри VALUES (…): столбцы здесь ни к чему.
        case values
        /// Только столбцы этой таблицы: `INSERT INTO t (…)`, `ALTER TABLE t MODIFY …`.
        case columns(SQLTableRef, keywords: Bool)
        case routine
        /// После EXPLAIN — и таблица, и запрос.
        case tableOrStatement
    }

    struct Result {
        var items: [CompletionItem] = []
        /// Базы, чьи таблицы нужны здесь, но ещё не прочитаны.
        var missingSchemas: [String] = []
    }

    /// Сколько текста вокруг курсора разбирать. В редактор бывает вставлен
    /// дамп на мегабайты, а запрос — это несколько строк.
    static let window = 64 * 1024

    static func complete(_ text: String, caret: Int, catalog: SQLCatalog) -> Result {
        complete(SyntaxModel(text: text, spec: SQLDialect.mariadb), caret: caret, catalog: catalog)
    }

    /// `model` — модель редактора с `SQLDialect.mariadb`: по её состояниям
    /// строк видно, откуда начинать разбор, не заходя внутрь строки или комментария.
    static func complete(_ model: SyntaxModel, caret rawCaret: Int, catalog: SQLCatalog) -> Result {
        let u = model.units
        let caret = max(0, min(rawCaret, u.count))
        let all = SQLLexer.tokens(u, in: scanRange(model, caret: caret))

        // Внутри строки, комментария, числа, переменной — дополнять нечего;
        // в `имени` — дополняем без кавычек.
        var quoted: SQLToken?
        for token in all where token.start < caret && caret <= token.end {
            switch token.kind {
            case .comment:
                if caret < token.end || !token.closed || token.text != "/*" { return Result() }
            case .string:
                if caret < token.end || !token.closed { return Result() }
            case .number, .variable:
                return Result()
            case .quoted:
                if caret < token.end || !token.closed { quoted = token }
            case .word, .symbol:
                break
            }
        }
        // Слово до курсора — так же, как его видит редактор: его и заменит вариант.
        var wordStart = caret
        while wordStart > 0, WordCompletion.isIdentPart(u[wordStart - 1]) { wordStart -= 1 }
        let prefix = String(decoding: u[wordStart..<caret], as: UTF16.self)
        let nameStart = quoted?.start ?? wordStart

        let code = all.filter { $0.kind != .comment }
        var first = 0, last = code.count
        for (k, token) in code.enumerated() where token.isSymbol(";") {
            if token.end <= nameStart { first = k + 1 } else if token.start >= caret { last = k; break }
        }
        let statement = first < last ? Array(code[first..<last]) : []
        let before = statement.filter { $0.end <= nameStart }

        // `a.b.|` — имя с точками: что перед ним и кто стоит слева.
        var qualifier: [String] = []
        var head = before.count
        while head >= 2, before[head - 1].isSymbol("."), before[head - 2].isName {
            qualifier.insert(before[head - 2].text, at: 0)
            head -= 2
        }
        if qualifier.isEmpty, before.last?.isSymbol(".") == true { return Result() }
        if qualifier.count > 2 { return Result() }

        let leading = Array(before[..<head])
        let position = classify(leading, statement: statement)
        var context = Context(catalog: catalog, statement: statement, prefix: prefix,
                              inQuotes: quoted != nil,
                              lowercase: prefersLowercase(code, typing: wordStart..<caret),
                              nextIsParen: caret < u.count && u[caret] == 0x28,
                              likely: likely(leading, statement: statement, position: position))
        context.build(position, qualifier: qualifier)
        return Result(items: context.items, missingSchemas: context.missing)
    }

    /// Откуда и докуда разбирать: не больше `window` в обе стороны от курсора,
    /// с начала строки, на входе в которую лексер подсветки не внутри строки
    /// или комментария. Лексеры согласованы, так что там начинает и этот.
    static func scanRange(_ model: SyntaxModel, caret: Int) -> Range<Int> {
        let n = model.units.count
        guard n > window * 2, model.lineCount > 1 else { return 0..<n }
        let caretLine = model.line(containing: min(caret, n - 1))
        var line = model.line(containing: max(0, caret - window))
        while line < caretLine && !LexState(packed: model.lineStates[line]).isNormal { line += 1 }
        let start = LexState(packed: model.lineStates[line]).isNormal ? Int(model.lineStarts[line]) : 0
        return start..<min(n, caret + window)
    }

    /// Ключевые слова вставляются тем регистром, каким уже написан текст:
    /// строчными, только если строчных ключевых слов в нём больше.
    static func prefersLowercase(_ tokens: [SQLToken], typing: Range<Int>) -> Bool {
        var lower = 0, upper = 0
        for token in tokens where token.kind == .word && !(token.start < typing.upperBound && token.end > typing.lowerBound) {
            // Только несомненные ключевые слова: `name` и `status` — чаще столбцы.
            guard SQLDialect.highlightKeywords.contains(token.text.lowercased()) else { continue }
            if token.text == token.text.lowercased() { lower += 1 } else if token.text == token.text.uppercased() { upper += 1 }
        }
        return lower > upper
    }

    // MARK: Что ждёт это место

    /// Слова, которые задают, что дальше: FROM — таблицы, WHERE — выражение.
    private static let clauseWords: Set<String> = [
        "SELECT", "FROM", "JOIN", "STRAIGHT_JOIN", "WHERE", "ON", "USING", "BY", "HAVING", "LIMIT", "OFFSET",
        "SET", "VALUES", "VALUE", "INTO", "UPDATE", "TABLE", "TABLES", "RETURNING", "WINDOW",
    ]

    /// После них начинается выражение.
    private static let expressionWords: Set<String> = [
        "ALL", "AND", "ANY", "BETWEEN", "BINARY", "CASE", "DEFAULT", "DISTINCT", "DISTINCTROW", "DIV", "ELSE",
        "ELSEIF", "EXISTS", "HAVING", "HIGH_PRIORITY", "IF", "IN", "INTERVAL", "IS", "LIKE", "MOD", "NOT", "ON",
        "OR", "REGEXP", "RETURN", "RETURNING", "RLIKE", "SELECT", "SEPARATOR", "SOME", "SQL_BIG_RESULT",
        "SQL_BUFFER_RESULT", "SQL_CACHE", "SQL_CALC_FOUND_ROWS", "SQL_NO_CACHE", "SQL_SMALL_RESULT", "THEN",
        "UNTIL", "USING", "WHEN", "WHERE", "WHILE", "XOR",
    ]

    /// Ближайшее слово-раздел на уровне курсора — или открытая скобка,
    /// если внутри неё раздела нет.
    private static func scope(_ tokens: [SQLToken]) -> (clause: String?, open: Int?) {
        var depth = 0
        for k in stride(from: tokens.count - 1, through: 0, by: -1) {
            let t = tokens[k]
            if t.isSymbol(")") { depth += 1; continue }
            if t.isSymbol("(") {
                if depth == 0 { return (nil, k) }
                depth -= 1
                continue
            }
            if depth == 0, t.kind == .word, clauseWords.contains(t.key) { return (t.key, nil) }
        }
        return (nil, nil)
    }

    /// Что может стоять за лексемами `tokens` — началом запроса до места курсора.
    static func classify(_ tokens: [SQLToken], statement: [SQLToken]) -> Position {
        guard let last = tokens.last else { return .statementStart }
        let n = tokens.count
        let head = statement.first?.key ?? ""
        func word(_ k: Int) -> String? { k >= 0 && k < n && tokens[k].kind == .word ? tokens[k].key : nil }
        let (clause, open) = scope(tokens)
        let owner = enclosingParen(tokens, before: n - 1).flatMap { word($0 - 1) }

        if last.kind == .word, SQLDialect.isKeyword(last.text) {
            let w = last.key
            // ALTER TABLE t MODIFY | и прочие — столбцы изменяемой таблицы.
            if head == "ALTER", n > 1, let table = SQLStatement.tableRefs(statement).first {
                switch w {
                case "COLUMN": return word(n - 2) == "ADD" ? .nothing : .columns(table, keywords: false)
                case "MODIFY", "CHANGE", "DROP", "ALTER": return .columns(table, keywords: true)
                case "AFTER": return .columns(table, keywords: false)
                default: break
                }
            }
            switch w {
            case "FROM" where head == "SHOW", "IN" where head == "SHOW":
                let columns = statement.contains { ["COLUMNS", "FIELDS", "INDEX", "INDEXES", "KEYS"].contains($0.key) }
                return columns ? .table : .database
            case "FROM":
                if SQLStatement.functionsWithFrom.contains(owner ?? "") { return .expression }
                return .table
            case "JOIN", "STRAIGHT_JOIN":
                return .table
            case "NOT" where head == "CREATE" && open != nil:
                return .keywords   // CREATE TABLE t (id INT NOT | — NULL, а не выражение
            case "INTO":
                return head == "INSERT" || head == "REPLACE" ? .table : .keywords
            case "UPDATE":
                if n == 1 { return .table }
                return word(n - 2) == "KEY" ? .expression : .keywords   // ON DUPLICATE KEY UPDATE
            case "LOW_PRIORITY" where head == "UPDATE" && n == 2, "IGNORE" where head == "UPDATE" && n == 2:
                return .table
            case "TABLE":
                return head == "CREATE" ? .nothing : .table
            case "TABLES":
                return head == "LOCK" || head == "FLUSH" ? .table : .keywords
            case "EXISTS":
                // DROP TABLE IF EXISTS |, CREATE TABLE IF NOT EXISTS |; иначе — EXISTS (подзапрос).
                let object = word(n - 2) == "IF" ? word(n - 3) : word(n - 2) == "NOT" && word(n - 3) == "IF" ? word(n - 4) : nil
                guard let object else { return .expression }
                if head == "CREATE" { return .nothing }
                return object == "DATABASE" || object == "SCHEMA" ? .database : .table
            case "TRUNCATE":
                return n == 1 ? .table : .keywords
            case "DESCRIBE", "DESC", "EXPLAIN":
                guard n == 1 else { return .keywords }   // ORDER BY x DESC |
                return w == "EXPLAIN" ? .tableOrStatement : .table
            case "USE":
                return n == 1 ? .database : .keywords
            case "DATABASE", "SCHEMA":
                return head == "CREATE" ? .nothing : .database
            case "CALL":
                return .routine
            case "AS":
                if owner == "CAST" || owner == "CONVERT" { return .keywords }   // CAST(x AS тип)
                // Псевдоним — новое имя; CREATE VIEW … AS и WITH x AS — дальше запрос.
                return ["SELECT", "FROM", "JOIN", "STRAIGHT_JOIN", "UPDATE", "INTO", "TABLE"].contains(clause ?? "")
                    ? .nothing : .keywords
            case "LIMIT", "OFFSET":
                return .nothing
            case "SET":
                return head == "SET" && n == 1 ? .keywords : .expression
            case "VALUES", "VALUE":
                return .keywords
            case "BY":
                return ["GROUP", "ORDER", "PARTITION"].contains(word(n - 2) ?? "") ? .expression : .keywords
            default:
                if expressionWords.contains(w) { return inValues(tokens, clause: clause, open: open) ? .values : .expression }
                return .keywords
            }
        }

        if last.kind == .symbol {
            switch last.text {
            case "(":
                return parenPosition(tokens, open: n - 1, head: head)
            case ",":
                if let clause {
                    switch clause {
                    case "FROM": return .table                          // FROM a, |
                    case "TABLE", "TABLES": return head == "CREATE" ? .nothing : .table
                    case "UPDATE": return .table                        // UPDATE a, b SET …
                    case "VALUES", "VALUE": return .values
                    case "LIMIT", "INTO": return .nothing
                    default: return .expression                         // SELECT a, |, GROUP BY a, |
                    }
                }
                if let open { return parenPosition(tokens, open: open, head: head) }
                return .expression
            case ")":
                return .keywords
            case "*":
                // SELECT * | и t.* | — операнд; a * | — умножение.
                if n >= 2, tokens[n - 2].isSymbol(",") || tokens[n - 2].isSymbol(".") || tokens[n - 2].isSymbol("(")
                    || word(n - 2) == "SELECT" { return .keywords }
                return .expression
            case ".":
                return .nothing
            default:
                return inValues(tokens, clause: clause, open: open) ? .values : .expression
            }
        }
        // Имя, строка, число — операнд: дальше AS, FROM, AND, JOIN и прочие слова.
        return .keywords
    }

    // MARK: Вероятные слова

    /// Ключевые слова, которые здесь вероятнее прочих, — по порядку: они
    /// встают в начало списка. После таблицы — WHERE, JOIN, LEFT; после
    /// ORDER — BY; в начале запроса — SELECT раньше SET и SHOW.
    static func likely(_ tokens: [SQLToken], statement: [SQLToken], position: Position) -> [String] {
        switch position {
        case .statementStart, .tableOrStatement: return likelyAtStart
        case .expression, .values: return likelyInExpression
        case .columns(_, keywords: true): return ["COLUMN", "INDEX", "PRIMARY", "FOREIGN", "CONSTRAINT"]
        case .keywords: break
        default: return []
        }
        guard let last = tokens.last else { return likelyAtStart }
        if last.kind == .word, let next = likelyAfterWord[last.key] { return next }
        let head = statement.first?.key ?? ""
        let place = scope(tokens)
        // Определение столбца: CREATE TABLE t (id |, ALTER TABLE t ADD c |. В начале
        // элемента — ограничения таблицы, за именем — тип, за типом — ограничения столбца.
        if (head == "CREATE" && place.open != nil)
            || (head == "ALTER" && tokens.contains { ["ADD", "MODIFY", "CHANGE", "COLUMN"].contains($0.key) }) {
            if last.isSymbol("(") || last.isSymbol(",") { return likelyTableConstraint }
            let lower = last.text.lowercased()
            let isName = last.kind == .quoted || (last.kind == .word && !SQLDialect.highlightKeywords.contains(lower)
                && !SQLDialect.typeNames.contains(lower) && !SQLDialect.mariadb.constants.contains(lower))
            return isName ? likelyColumnType : likelyColumnConstraint
        }
        // CREATE TABLE t (…) | — параметры таблицы.
        if head == "CREATE" && place.clause == "TABLE" {
            return ["ENGINE", "DEFAULT", "CHARSET", "COLLATE", "COMMENT", "AUTO_INCREMENT", "AS"]
        }
        // За служебным словом без своих продолжений — по алфавиту. Слова,
        // которые бывают именами (`status`, `name`), и NULL, END — операнды.
        if last.kind == .word, SQLDialect.highlightKeywords.contains(last.text.lowercased()),
           !operandWords.contains(last.key) {
            return []
        }
        // После операнда — по разделу, в котором он стоит.
        return likelyAfterOperand[place.clause ?? ""] ?? likelyAfterOperand[""] ?? []
    }

    /// Служебные слова, которые сами — значение: за ними идёт то же, что за именем.
    private static let operandWords: Set<String> = [
        "END", "ASC", "DESC", "DUAL", "MAXVALUE", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
        "CURRENT_USER", "CURRENT_ROLE", "LOCALTIME", "LOCALTIMESTAMP", "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP",
    ]

    private static let likelyTableConstraint = ["PRIMARY", "KEY", "INDEX", "UNIQUE", "CONSTRAINT", "FOREIGN", "CHECK"]

    private static let likelyColumnType = [
        "INT", "BIGINT", "VARCHAR", "TEXT", "DATETIME", "TIMESTAMP", "DATE", "DECIMAL", "TINYINT", "SMALLINT",
        "BOOLEAN", "CHAR", "DOUBLE", "FLOAT", "JSON", "ENUM", "BLOB", "LONGTEXT", "MEDIUMTEXT", "BIT", "TIME", "YEAR",
    ]

    private static let likelyColumnConstraint = [
        "NOT", "NULL", "DEFAULT", "AUTO_INCREMENT", "PRIMARY", "UNIQUE", "UNSIGNED", "COMMENT", "REFERENCES",
        "CHARACTER", "COLLATE", "AFTER", "FIRST", "KEY", "CHECK",
    ]

    private static let likelyAtStart = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "SHOW", "CREATE", "ALTER", "DROP", "USE", "WITH", "DESCRIBE",
        "EXPLAIN", "CALL", "TRUNCATE", "SET", "REPLACE", "BEGIN", "START", "COMMIT", "ROLLBACK",
    ]

    private static let likelyInExpression = [
        "NOT", "NULL", "AND", "OR", "IN", "IS", "LIKE", "BETWEEN", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END",
        "DISTINCT", "TRUE", "FALSE", "INTERVAL", "SELECT", "AS",
    ]

    /// Что обычно идёт за этим словом.
    private static let likelyAfterWord: [String: [String]] = [
        "ORDER": ["BY"], "GROUP": ["BY"], "PARTITION": ["BY"],
        "LEFT": ["JOIN", "OUTER"], "RIGHT": ["JOIN", "OUTER"], "INNER": ["JOIN"], "CROSS": ["JOIN"],
        "OUTER": ["JOIN"], "NATURAL": ["JOIN", "LEFT", "RIGHT"],
        "INSERT": ["INTO", "IGNORE"], "REPLACE": ["INTO"], "IGNORE": ["INTO"], "DELETE": ["FROM"],
        "CREATE": ["TABLE", "VIEW", "INDEX", "DATABASE", "UNIQUE", "PROCEDURE", "FUNCTION", "TRIGGER", "EVENT",
                   "TEMPORARY", "OR", "USER"],
        "DROP": ["TABLE", "VIEW", "INDEX", "DATABASE", "PROCEDURE", "FUNCTION", "TRIGGER", "EVENT", "USER"],
        "ALTER": ["TABLE", "VIEW", "DATABASE", "USER", "EVENT"],
        "SHOW": ["TABLES", "DATABASES", "COLUMNS", "CREATE", "FULL", "INDEX", "PROCESSLIST", "VARIABLES", "STATUS",
                 "GRANTS", "WARNINGS", "ERRORS", "TRIGGERS", "ENGINE", "TABLE"],
        "FULL": ["PROCESSLIST", "COLUMNS", "TABLES"],
        "TABLES": ["FROM", "IN", "LIKE", "WHERE"], "DATABASES": ["LIKE", "WHERE"], "COLUMNS": ["FROM", "IN"],
        "IS": ["NULL", "NOT", "TRUE", "FALSE"], "NOT": ["NULL", "IN", "LIKE", "EXISTS", "BETWEEN", "REGEXP"],
        "PRIMARY": ["KEY"], "FOREIGN": ["KEY"], "UNIQUE": ["KEY", "INDEX"], "IF": ["EXISTS", "NOT"],
        "DUPLICATE": ["KEY"], "UNION": ["ALL", "SELECT", "DISTINCT"], "START": ["TRANSACTION"],
        "CHARACTER": ["SET"], "TEMPORARY": ["TABLE"], "OR": ["REPLACE"], "WITH": ["ROLLUP", "RECURSIVE"],
        "FOR": ["UPDATE", "SHARE"], "LOCK": ["TABLES", "IN"], "UNLOCK": ["TABLES"], "TRUNCATE": ["TABLE"],
        "ADD": ["COLUMN", "INDEX", "PRIMARY", "UNIQUE", "FOREIGN", "CONSTRAINT", "KEY"],
        "RENAME": ["TO", "COLUMN", "TABLE", "INDEX"],
        "DEFAULT": ["NULL", "CURRENT_TIMESTAMP", "CHARSET", "CHARACTER", "COLLATE"],
        "SET": ["GLOBAL", "SESSION", "NAMES", "CHARACTER", "TRANSACTION", "PASSWORD"],
    ]

    /// Что обычно идёт за готовым операндом — по разделу, где он стоит.
    private static let likelyAfterOperand: [String: [String]] = [
        "": ["AS", "FROM", "WHERE", "AND", "OR"],
        "SELECT": ["FROM", "AS"],
        "FROM": ["WHERE", "JOIN", "LEFT", "INNER", "RIGHT", "CROSS", "NATURAL", "STRAIGHT_JOIN", "AS", "GROUP",
                 "ORDER", "LIMIT", "UNION"],
        "JOIN": ["ON", "USING", "AS", "WHERE", "JOIN", "LEFT", "INNER", "GROUP", "ORDER", "LIMIT"],
        "STRAIGHT_JOIN": ["ON", "USING", "AS", "WHERE", "JOIN", "LEFT", "INNER", "GROUP", "ORDER", "LIMIT"],
        "WHERE": ["AND", "OR", "IS", "IN", "NOT", "LIKE", "BETWEEN", "REGEXP", "GROUP", "ORDER", "LIMIT", "UNION"],
        "ON": ["AND", "OR", "IS", "IN", "NOT", "LIKE", "BETWEEN", "WHERE", "JOIN", "LEFT", "INNER", "GROUP", "ORDER",
               "LIMIT"],
        "USING": ["WHERE", "JOIN", "LEFT", "INNER", "GROUP", "ORDER", "LIMIT"],
        "HAVING": ["AND", "OR", "IS", "IN", "NOT", "LIKE", "ORDER", "LIMIT"],
        "BY": ["ASC", "DESC", "LIMIT", "HAVING", "ORDER", "WITH", "UNION"],
        "SET": ["WHERE", "ORDER", "LIMIT"],
        "UPDATE": ["SET"],
        "INTO": ["VALUES", "SELECT", "SET", "VALUE"],
        "TABLE": ["ADD", "DROP", "MODIFY", "CHANGE", "RENAME", "ALTER", "ENGINE", "AUTO_INCREMENT", "CONVERT"],
        "TABLES": ["READ", "WRITE"],
        "LIMIT": ["OFFSET", "UNION", "FOR"],
        "OFFSET": ["UNION", "FOR"],
        "VALUES": ["ON"],
    ]

    /// Ширина, до которой добиты имена ключевых слов и функций для сравнения
    /// с набранным (см. `languageFilter`).
    static let filterWidth = 64

    /// Выражение внутри VALUES (…): открытая скобка — после VALUES или
    /// после `),` следующей строки значений.
    private static func inValues(_ tokens: [SQLToken], clause: String?, open: Int?) -> Bool {
        if clause == "VALUES" || clause == "VALUE" { return true }
        guard clause == nil, let open else { return false }
        var k = open - 1
        while k >= 0 {
            if tokens[k].isSymbol(")") { k = matchingOpen(tokens, k) - 1; continue }
            if tokens[k].isSymbol(",") { k -= 1; continue }
            return tokens[k].key == "VALUES" || tokens[k].key == "VALUE"
        }
        return false
    }

    /// Сразу после `(` или внутри скобок без своего раздела.
    private static func parenPosition(_ tokens: [SQLToken], open: Int, head: String) -> Position {
        guard open > 0 else { return .statementStart }   // (SELECT …) UNION …
        let owner = tokens[open - 1]
        guard owner.isName else {
            return inValues(tokens, clause: nil, open: open) ? .values : .expression
        }
        switch owner.key {
        case "VALUES", "VALUE":
            return .values
        case "FROM", "JOIN", "AS", "UNION", "EXCEPT", "INTERSECT":
            return .statementStart   // подзапрос: FROM (|, WITH x AS (|
        case "OVER", "WINDOW":
            return .keywords
        case let w where expressionWords.contains(w):
            return .expression        // IN (|, EXISTS (|, USING (|, IF(|
        default:
            break
        }
        // INSERT INTO t (…), REFERENCES t (…), CREATE INDEX i ON t (…) — столбцы t.
        var ref = SQLTableRef(schema: nil, name: owner.text, alias: nil)
        var k = open - 1
        if k >= 2, tokens[k - 1].isSymbol("."), tokens[k - 2].isName {
            ref.schema = tokens[k - 2].text
            k -= 2
        }
        let introducer = k >= 1 ? tokens[k - 1].key : ""
        if introducer == "INTO" || introducer == "REFERENCES" || (introducer == "ON" && head == "CREATE") {
            return .columns(ref, keywords: false)
        }
        // CREATE TABLE t (…): новые столбцы, их типы и ключи.
        if head == "CREATE" && (owner.kind == .quoted || !SQLDialect.functionSet.contains(owner.key)) {
            return .keywords
        }
        return .expression   // вызов функции
    }

    /// Открывающая скобка, внутри которой стоит лексема `index`.
    private static func enclosingParen(_ tokens: [SQLToken], before index: Int) -> Int? {
        var depth = 0
        var k = index
        while k >= 0 {
            if tokens[k].isSymbol(")") { depth += 1 }
            if tokens[k].isSymbol("(") {
                if depth == 0 { return k }
                depth -= 1
            }
            k -= 1
        }
        return nil
    }

    private static func matchingOpen(_ tokens: [SQLToken], _ close: Int) -> Int {
        var depth = 0
        var k = close
        while k >= 0 {
            if tokens[k].isSymbol(")") { depth += 1 }
            if tokens[k].isSymbol("(") {
                depth -= 1
                if depth == 0 { return k }
            }
            k -= 1
        }
        return 0
    }

    // MARK: Варианты

    /// Сборка вариантов для одного места.
    private struct Context {
        let catalog: SQLCatalog
        let statement: [SQLToken]
        let prefix: String
        /// Курсор внутри `имени`: кавычки уже стоят.
        let inQuotes: Bool
        let lowercase: Bool
        /// Сразу за курсором `(`: функции — без своих скобок.
        let nextIsParen: Bool
        /// Ключевые слова, которые здесь вероятнее прочих, — по порядку.
        let likely: [String]
        var items: [CompletionItem] = []
        var missing: [String] = []

        mutating func build(_ position: Position, qualifier: [String]) {
            if !qualifier.isEmpty {
                member(qualifier, tablePosition: position == .table || position == .tableOrStatement,
                       routinePosition: position == .routine)
                return
            }
            switch position {
            case .nothing:
                break
            case .statementStart:
                keywords(SQLDialect.statementKeywords)
            case .keywords:
                keywords(SQLDialect.keywords)
            case .table:
                tablesHere()
            case .tableOrStatement:
                tablesHere()
                keywords(SQLDialect.statementKeywords)
            case .database:
                databases(sort: "1")
            case .routine:
                routines(of: catalog.current)
                databases(sort: "5")
            case .columns(let ref, let withKeywords):
                if let table = resolve(ref) { columns(of: [table], sort: "0") }
                if withKeywords { keywords(SQLDialect.keywords) }
            case .values:
                functions()
                keywords(SQLDialect.keywords)
            case .expression:
                expression()
            }
        }

        // MARK: Места

        /// После FROM, JOIN, UPDATE: таблицы текущей базы, имена из WITH и базы — для `база.таблица`.
        private mutating func tablesHere() {
            tables(of: catalog.current, sort: "1")
            for name in SQLStatement.cteNames(statement) {
                items.append(CompletionItem(label: name, kind: 25, detail: "WITH", sortText: "0" + name,
                                            insertText: insert(name)))
            }
            databases(sort: "5")
        }

        /// Выражение: столбцы таблиц запроса, их псевдонимы, функции и ключевые слова.
        /// Таблиц у запроса ещё нет (`SELECT |` без FROM) — столбцы и таблицы всей текущей базы.
        private mutating func expression() {
            let refs = SQLStatement.tableRefs(statement)
            var tables: [(schema: String, table: SQLCatalog.Table)] = []
            for ref in refs where !ref.name.isEmpty || ref.derived != nil {
                guard let found = resolve(ref) else { continue }
                if !tables.contains(where: { $0.schema == found.schema && $0.table.name == found.table.name }) {
                    tables.append(found)
                }
            }
            if tables.isEmpty && refs.isEmpty {
                allColumns()
                self.tables(of: catalog.current, sort: "2b")
            } else {
                columns(of: tables, sort: "0")
                var seen = Set<String>()
                for ref in refs {
                    let name = ref.alias ?? ref.name
                    guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                    items.append(CompletionItem(label: name, kind: 25, detail: ref.alias != nil && !ref.name.isEmpty ? ref.name : nil,
                                                sortText: "1" + name, insertText: insert(name)))
                }
            }
            functions()
            keywords(SQLDialect.keywords)
        }

        /// `x.|`: столбцы таблицы или псевдонима `x`, таблицы базы `x`;
        /// `база.таблица.|` — столбцы.
        private mutating func member(_ qualifier: [String], tablePosition: Bool, routinePosition: Bool) {
            if qualifier.count == 2 {
                guard !tablePosition, !routinePosition else { return }
                if let found = resolve(SQLTableRef(schema: qualifier[0], name: qualifier[1], alias: nil)) {
                    columns(of: [found], sort: "0")
                }
                return
            }
            let name = qualifier[0]
            if tablePosition { tables(of: name, sort: "1"); return }
            if routinePosition { routines(of: name); return }
            let refs = SQLStatement.tableRefs(statement)
            let lower = name.lowercased()
            let ref = refs.first { $0.alias == name } ?? refs.first { $0.alias?.lowercased() == lower }
                ?? refs.first { $0.alias == nil && $0.name == name } ?? refs.first { $0.name.lowercased() == lower }
            if let ref {
                if let found = resolve(ref) { columns(of: [found], sort: "0") }
            } else if !SQLStatement.cteNames(statement).contains(where: { $0.lowercased() == lower }),
                      let found = resolve(SQLTableRef(schema: nil, name: name, alias: nil)) {
                columns(of: [found], sort: "0")
            }
            // `база.` — ещё и её таблицы: `clm.users.id`.
            if catalog.schemaName(name) != nil { tables(of: name, sort: "2") }
        }

        // MARK: Кирпичики

        /// Таблица по ссылке из запроса; её базы нет в памяти — запомнить, что прочитать.
        /// Подзапрос — таблица из имён его списка SELECT, `*` раскрыт по его таблицам.
        private mutating func resolve(_ ref: SQLTableRef) -> (schema: String, table: SQLCatalog.Table)? {
            if let derived = ref.derived {
                guard let alias = ref.alias else { return nil }
                var columns: [SQLCatalog.Column] = []
                for name in derived {
                    if name == "*" || name.hasSuffix(".*") {
                        let owner = name == "*" ? nil : String(name.dropLast(2)).lowercased()
                        for inner in ref.inner where owner == nil || (inner.alias ?? inner.name).lowercased() == owner {
                            columns += resolve(inner)?.table.columns ?? []
                        }
                    } else {
                        columns.append(SQLCatalog.Column(name: name, type: ""))
                    }
                }
                return ("", SQLCatalog.Table(name: alias, columns: columns))
            }
            if let schema = catalog.unloaded(ref.schema), !missing.contains(schema) { missing.append(schema) }
            return catalog.table(ref.name, schema: ref.schema)
        }

        private mutating func tables(of schema: String?, sort: String) {
            if let name = catalog.unloaded(schema), !missing.contains(name) { missing.append(name) }
            guard let resolved = schema.map({ catalog.schemaName($0) ?? $0 }) ?? catalog.current,
                  let tables = catalog.schemas[resolved]?.tables else { return }
            for table in tables {
                items.append(CompletionItem(label: table.name, kind: 25,
                                            detail: table.isView ? L("представление") : nil,
                                            sortText: sort + table.name, insertText: insert(table.name)))
            }
        }

        private mutating func databases(sort: String) {
            for name in catalog.schemaNames {
                items.append(CompletionItem(label: name, kind: 9, sortText: sort + name, insertText: insert(name)))
            }
        }

        private mutating func routines(of schema: String?) {
            if let name = catalog.unloaded(schema), !missing.contains(name) { missing.append(name) }
            guard let resolved = schema.map({ catalog.schemaName($0) ?? $0 }) ?? catalog.current,
                  let routines = catalog.schemas[resolved]?.routines else { return }
            for routine in routines {
                items.append(CompletionItem(label: routine.name, kind: routine.isProcedure ? 2 : 3,
                                            detail: routine.isProcedure ? L("процедура") : L("функция"),
                                            sortText: (routine.isProcedure ? "0" : "1") + routine.name,
                                            insertText: insert(routine.name)))
            }
        }

        /// Столбцы таблиц по порядку в таблице; у нескольких таблиц — с именем таблицы.
        private mutating func columns(of tables: [(schema: String, table: SQLCatalog.Table)], sort: String) {
            for (index, found) in tables.enumerated() {
                for (ordinal, column) in found.table.columns.enumerated() {
                    let detail = [column.type, tables.count > 1 ? found.table.name : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    items.append(CompletionItem(label: column.name, kind: 5, detail: detail.isEmpty ? nil : detail,
                                                sortText: sort + String(format: "%03d%05d", index, ordinal),
                                                insertText: insert(column.name)))
                }
            }
        }

        /// Все столбцы текущей базы — по одному на имя, с первой таблицей,
        /// где он есть, и числом остальных: `int · users +12`.
        private mutating func allColumns() {
            if let name = catalog.unloaded(nil), !missing.contains(name) { missing.append(name) }
            guard let current = catalog.current, let tables = catalog.schemas[current]?.tables else { return }
            var order: [String] = []
            var found: [String: (column: SQLCatalog.Column, table: String, count: Int)] = [:]
            for table in tables {
                for column in table.columns {
                    if found[column.name] != nil {
                        found[column.name]?.count += 1
                        continue
                    }
                    order.append(column.name)
                    found[column.name] = (column, table.name, 1)
                }
            }
            for name in order {
                guard let entry = found[name] else { continue }
                var detail = [entry.column.type, entry.table].filter { !$0.isEmpty }.joined(separator: " · ")
                if entry.count > 1 { detail += " +\(entry.count - 1)" }
                items.append(CompletionItem(label: name, kind: 5, detail: detail, sortText: "2a" + name,
                                            insertText: insert(name)))
            }
        }

        private mutating func functions() {
            guard !inQuotes else { return }
            for name in SQLDialect.functions {
                let cased = lowercase ? name.lowercased() : name
                let rank = SQLDialect.commonFunctionRank[name].map { String(format: "%03d", $0) } ?? "999"
                var item = CompletionItem(label: cased, kind: 3, sortText: "31" + rank + name)
                item.filterText = languageFilter(name)
                if nextIsParen {
                    item.insertText = cased
                } else if SQLDialect.niladicFunctions.contains(name) {
                    item.insertText = cased + "()"
                } else {
                    item.insertText = cased + "($0)"
                    item.isSnippet = true
                }
                items.append(item)
            }
            // Хранимые функции текущей базы.
            if let current = catalog.current, let routines = catalog.schemas[current]?.routines {
                for routine in routines where !routine.isProcedure {
                    var item = CompletionItem(label: routine.name, kind: 3, detail: L("функция"),
                                              sortText: "2c" + routine.name)
                    let name = insert(routine.name)
                    // В сниппете `$` и `\` — разметка: в имени их экранируем.
                    let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "$", with: "\\$")
                    item.insertText = nextIsParen ? name : escaped + "($0)"
                    item.isSnippet = !nextIsParen
                    items.append(item)
                }
            }
        }

        /// Ключевые слова — только начинающиеся с набранного: иначе список
        /// выскакивал бы на каждый псевдоним (`ua` — это не UPDATE).
        /// Вероятные здесь — первыми и по порядку, остальные — по алфавиту.
        private mutating func keywords(_ words: [String]) {
            guard !inQuotes else { return }
            let typed = prefix.uppercased()
            for word in words where word.hasPrefix(typed) {
                let cased = lowercase ? word.lowercased() : word
                let rank = likely.firstIndex(of: word).map { "0" + String(format: "%03d", $0) } ?? "2"
                var item = CompletionItem(label: cased, kind: 14, sortText: "3" + rank + word, insertText: cased)
                item.filterText = languageFilter(word)
                items.append(item)
            }
        }

        /// По чему сравнивать набранное с ключевым словом или функцией.
        ///
        /// Общий ранжир ставит выше совпадения короче, и WAIT обгонял бы WHERE,
        /// а SET — SELECT. Поэтому слова языка сравниваются по имени одной
        /// длины (добитому пробелами до `filterWidth`): с набранным они совпадают
        /// одинаково, и порядок задаёт `sortText` — вероятные здесь первыми.
        /// Заглавная — только в начале частей (`Date_Format`): у имени из одних
        /// заглавных «горбом» считается каждая буква, и `na` находил бы CONCAT.
        /// Слово набрано целиком — совпадение точное: оно первое, а если
        /// единственное, список закроется сам, и Return переведёт строку.
        private func languageFilter(_ word: String) -> String {
            if !prefix.isEmpty, word.caseInsensitiveCompare(prefix) == .orderedSame { return prefix }
            let title = SQLDialect.titleCase(word)
            return title + String(repeating: " ", count: max(0, SQLCompletion.filterWidth - title.count))
        }

        /// Имя для вставки: в кавычках, если без них нельзя; внутри `…` — как есть.
        private func insert(_ name: String) -> String {
            inQuotes ? name.replacingOccurrences(of: "`", with: "``") : SQLDialect.quoted(name)
        }
    }
}
