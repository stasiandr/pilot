import Foundation

/// SQL MariaDB/MySQL: как его красить и какие слова в нём есть.
///
/// Подсветку делает общий лексер редактора (`SyntaxModel`) по этому
/// описанию; дополнение (`SQLCompletion`) берёт отсюда же ключевые слова,
/// функции и правила кавычек. Без AppKit — проверяется тестами ядра.
enum SQLDialect {

    // MARK: - Подсветка

    /// Язык окна базы. Отличия от общего `Languages.sql` — те, что есть
    /// у MariaDB: комментарии `#`, `имена` в обратных кавычках, строки
    /// с `\` и на несколько строк, переменные `@x` и `@@global.x`.
    static let mariadb: LanguageSpec = {
        var l = LanguageSpec(name: "MariaDB SQL")
        // `--` без пробела MySQL комментарием не считает, но так пишут
        // редко, а строка из одних `--` — часто: красим как комментарий.
        l.lineComments = [LanguageSpec.s("--"), LanguageSpec.s("#")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: true),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: true),
            // Имя, а не строка: цвет обычного текста, но слова внутри — не ключевые.
            StringSpec(open: LanguageSpec.s("`"), close: LanguageSpec.s("`"), escapes: false, multiline: false,
                       kind: .plain),
        ]
        l.attributePrefix = 0x40   // @переменная, @@системная
        l.caseInsensitiveKeywords = true
        l.keywords = highlightKeywords
        l.typeKeywords = typeNames
        l.constants = ["null", "true", "false", "unknown"]
        l.capitalizedIsType = false
        return l
    }()

    /// Зарезервированные слова MariaDB (кроме типов и констант) и частые
    /// слова запросов, которые почти не бывают именами столбцов. Непохожие
    /// на них `status`, `name`, `type`, `value` не красим: лексер не знает,
    /// где имя столбца, и `SELECT name, status` пестрел бы ключевыми словами.
    static let highlightKeywords: Set<String> = [
        "accessible", "add", "all", "alter", "analyze", "and", "as", "asc", "asensitive", "before",
        "between", "both", "by", "call", "cascade", "case", "change", "check", "collate", "column",
        "condition", "constraint", "continue", "convert", "create", "cross", "current_date",
        "current_role", "current_time", "current_timestamp", "current_user", "cursor", "database",
        "databases", "day_hour", "day_microsecond", "day_minute", "day_second", "declare", "default",
        "delayed", "delete", "desc", "describe", "deterministic", "distinct", "distinctrow", "div",
        "drop", "dual", "each", "else", "elseif", "enclosed", "escaped", "except", "exists", "exit",
        "explain", "fetch", "for", "force", "foreign", "from", "fulltext", "grant", "group", "having",
        "high_priority", "hour_microsecond", "hour_minute", "hour_second", "if", "ignore", "in", "index",
        "infile", "inner", "inout", "insensitive", "insert", "intersect", "interval", "into", "is",
        "iterate", "join", "key", "keys", "kill", "leading", "leave", "left", "like", "limit", "linear",
        "lines", "load", "localtime", "localtimestamp", "lock", "loop", "low_priority", "match",
        "maxvalue", "minute_microsecond", "minute_second", "mod", "modifies", "natural", "not",
        "no_write_to_binlog", "offset", "on", "optimize", "option", "optionally", "or", "order", "out",
        "outer", "outfile", "over", "partition", "precision", "primary", "procedure", "purge", "range",
        "read", "reads", "read_write", "recursive", "references", "regexp", "release", "rename",
        "repeat", "replace", "require", "resignal", "restrict", "return", "returning", "revoke", "right",
        "rlike", "rows", "schema", "schemas", "second_microsecond", "select", "sensitive", "separator",
        "set", "show", "signal", "spatial", "specific", "sql", "sqlexception", "sqlstate", "sqlwarning",
        "sql_big_result", "sql_calc_found_rows", "sql_small_result", "ssl", "starting", "straight_join",
        "table", "terminated", "then", "to", "trailing", "trigger", "undo", "union", "unique", "unlock",
        "unsigned", "update", "usage", "use", "using", "utc_date", "utc_time", "utc_timestamp", "values",
        "varying", "when", "where", "while", "window", "with", "write", "xor", "year_month", "zerofill",
        // Не зарезервированы, но это слова команд, а не имена.
        "after", "algorithm", "any", "auto_increment", "begin", "charset", "columns", "commit",
        "deallocate", "definer", "duplicate", "end", "engine", "escape", "execute", "fields", "flush",
        "function", "global", "grants", "indexes", "modify", "names", "nowait", "prepare", "privileges",
        "processlist", "returns", "rollback", "rollup", "savepoint", "session", "some", "start", "tables",
        "temporary", "transaction", "triggers", "truncate", "variables", "view",
    ]

    /// Типы столбцов — цветом типа: в `CREATE TABLE` их видно сразу.
    /// UUID сюда не входит: так чаще называют столбец, чем пишут тип.
    static let typeNames: Set<String> = [
        "bigint", "binary", "bit", "blob", "bool", "boolean", "char", "date", "datetime", "dec", "decimal",
        "double", "enum", "fixed", "float", "float4", "float8", "inet4", "inet6", "int", "int1", "int2",
        "int3", "int4", "int8", "integer", "json", "longblob", "longtext", "mediumblob", "mediumint",
        "mediumtext", "middleint", "nchar", "numeric", "nvarchar", "real", "serial", "signed", "smallint",
        "text", "time", "timestamp", "tinyblob", "tinyint", "tinytext", "varbinary", "varchar",
        "varcharacter", "year",
    ]

    // MARK: - Слова для дополнения

    /// Всё, что дополнение предлагает как ключевое слово, — заглавными.
    /// Шире подсветки: здесь лишнее не мешает, варианты — только по началу слова.
    static let keywords: [String] = {
        let extra: [String] = [
            "ACTION", "AGAINST", "AGGREGATE", "ALWAYS", "AT", "AUTO_INCREMENT", "AVG_ROW_LENGTH", "BTREE",
            "CASCADED", "CHAIN", "CHARACTER", "CHECKSUM", "CLOSE", "COLUMN_FORMAT", "COMMENT", "COMMITTED",
            "COMPACT", "COMPRESSED", "CONCURRENT", "CONNECTION", "CONSISTENT", "CONTAINS", "CURRENT", "DATA",
            "DAY", "DELAY_KEY_WRITE", "DIRECTORY", "DISABLE", "DISCARD", "DO", "DUMPFILE", "DYNAMIC", "ENABLE",
            "ENDS", "ENGINES", "ERRORS", "EVENT", "EVENTS", "EVERY", "EXCHANGE", "EXCLUSIVE", "EXTENDED",
            "FAST", "FIRST", "FOLLOWING", "FORMAT", "FULL", "GENERATED", "HANDLER", "HASH", "HELP", "HOSTS",
            "HOUR", "IDENTIFIED", "INPLACE", "INSTANT", "INVISIBLE", "INVOKER", "ISOLATION", "KEY_BLOCK_SIZE",
            "LAST", "LATERAL", "LESS", "LEVEL", "LIST", "LOCAL", "LOCKED", "LOGS", "MASTER", "MAX_ROWS",
            "MEMORY", "MERGE", "MICROSECOND", "MINUTE", "MIN_ROWS", "MODE", "MONTH", "NAME", "NEXT", "NO",
            "NONE", "OFF", "ONE", "ONLY", "OPEN", "OPTIONS", "OWNER", "PACK_KEYS", "PAGE", "PARSER", "PARTIAL",
            "PARTITIONS", "PASSWORD", "PERSISTENT", "PLUGINS", "PRECEDING", "PRESERVE", "PROCESS", "PROFILE",
            "PROFILES", "QUARTER", "QUERY", "QUICK", "REBUILD", "REDUNDANT", "RELAY", "RELOAD", "REMOVE",
            "REORGANIZE", "REPAIR", "REPEATABLE", "REPLICA", "REPLICATION", "RESET", "RESTORE", "RESUME",
            "ROLE", "ROUTINE", "ROW", "ROW_FORMAT", "SCHEDULE", "SECOND", "SECURITY", "SEQUENCE",
            "SERIALIZABLE", "SERVER", "SHARE", "SHARED", "SHUTDOWN", "SIMPLE", "SKIP", "SLAVE", "SNAPSHOT",
            "SOUNDS", "SQL_BUFFER_RESULT", "SQL_CACHE", "SQL_NO_CACHE", "STARTS", "STATEMENT", "STATUS",
            "STOP", "STORAGE", "STORED", "SUBPARTITION", "SUPER", "SUSPEND", "SYSTEM", "SYSTEM_TIME",
            "TABLESPACE", "TEMPTABLE", "THAN", "TIES", "TYPE", "UNBOUNDED", "UNCOMMITTED", "UNDEFINED",
            "UNTIL", "UPGRADE", "USER", "VALIDATION", "VALUE", "VERSIONING", "VIRTUAL", "VISIBLE", "WAIT",
            "WARNINGS", "WEEK", "WITHOUT", "WORK", "XA", "XML",
        ]
        let all = Set(highlightKeywords.map { $0.uppercased() })
            .union(typeNames.map { $0.uppercased() })
            .union(["NULL", "TRUE", "FALSE", "UNKNOWN"])
            .union(extra)
        return all.sorted()
    }()

    /// Чем начинается запрос: в начале предлагаются только они.
    static let statementKeywords: [String] = [
        "ALTER", "ANALYZE", "BEGIN", "CALL", "CHECK", "CHECKSUM", "COMMIT", "CREATE", "DEALLOCATE",
        "DELETE", "DESC", "DESCRIBE", "DO", "DROP", "EXECUTE", "EXPLAIN", "FLUSH", "GRANT", "HANDLER",
        "HELP", "INSERT", "KILL", "LOAD", "LOCK", "OPTIMIZE", "PREPARE", "PURGE", "RELEASE", "RENAME",
        "REPAIR", "REPLACE", "RESET", "REVOKE", "ROLLBACK", "SAVEPOINT", "SELECT", "SET", "SHOW", "START",
        "STOP", "TRUNCATE", "UNLOCK", "UPDATE", "USE", "VALUES", "WITH", "XA",
    ]

    /// Встроенные функции MariaDB.
    static let functions: [String] = [
        // Агрегатные и оконные
        "AVG", "BIT_AND", "BIT_OR", "BIT_XOR", "COUNT", "GROUP_CONCAT", "JSON_ARRAYAGG", "JSON_OBJECTAGG",
        "MAX", "MIN", "STD", "STDDEV", "STDDEV_POP", "STDDEV_SAMP", "SUM", "VAR_POP", "VAR_SAMP", "VARIANCE",
        "ROW_NUMBER", "RANK", "DENSE_RANK", "PERCENT_RANK", "CUME_DIST", "NTILE", "LAG", "LEAD",
        "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE", "MEDIAN", "PERCENTILE_CONT", "PERCENTILE_DISC",
        // Условия
        "IF", "IFNULL", "NULLIF", "COALESCE", "NVL", "NVL2", "GREATEST", "LEAST", "ISNULL", "DECODE",
        // Строки
        "ASCII", "BIN", "BIT_LENGTH", "CHAR", "CHAR_LENGTH", "CHARACTER_LENGTH", "CHR", "CONCAT", "CONCAT_WS",
        "ELT", "EXPORT_SET", "EXTRACTVALUE", "FIELD", "FIND_IN_SET", "FORMAT", "FROM_BASE64", "HEX", "INSERT",
        "INSTR", "LCASE", "LEFT", "LENGTH", "LENGTHB", "LOAD_FILE", "LOCATE", "LOWER", "LPAD", "LTRIM",
        "MAKE_SET", "MID", "NATURAL_SORT_KEY", "OCT", "OCTET_LENGTH", "ORD", "POSITION", "QUOTE",
        "REGEXP_INSTR", "REGEXP_REPLACE", "REGEXP_SUBSTR", "REPEAT", "REPLACE", "REVERSE", "RIGHT", "RPAD",
        "RTRIM", "SFORMAT", "SOUNDEX", "SPACE", "STRCMP", "SUBSTR", "SUBSTRING", "SUBSTRING_INDEX",
        "TO_BASE64", "TO_CHAR", "TRIM", "UCASE", "UNHEX", "UPDATEXML", "UPPER", "WEIGHT_STRING",
        // Числа
        "ABS", "ACOS", "ASIN", "ATAN", "ATAN2", "CEIL", "CEILING", "CONV", "COS", "COT", "CRC32", "CRC32C",
        "DEGREES", "EXP", "FLOOR", "LN", "LOG", "LOG10", "LOG2", "MOD", "PI", "POW", "POWER", "RADIANS",
        "RAND", "ROUND", "SIGN", "SIN", "SQRT", "TAN", "TRUNCATE",
        // Дата и время
        "ADDDATE", "ADDTIME", "CONVERT_TZ", "CURDATE", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
        "CURTIME", "DATE", "DATEDIFF", "DATE_ADD", "DATE_FORMAT", "DATE_SUB", "DAY", "DAYNAME", "DAYOFMONTH",
        "DAYOFWEEK", "DAYOFYEAR", "EXTRACT", "FROM_DAYS", "FROM_UNIXTIME", "GET_FORMAT", "HOUR", "LAST_DAY",
        "LOCALTIME", "LOCALTIMESTAMP", "MAKEDATE", "MAKETIME", "MICROSECOND", "MINUTE", "MONTH", "MONTHNAME",
        "NOW", "PERIOD_ADD", "PERIOD_DIFF", "QUARTER", "SECOND", "SEC_TO_TIME", "STR_TO_DATE", "SUBDATE",
        "SUBTIME", "SYSDATE", "TIME", "TIMEDIFF", "TIMESTAMP", "TIMESTAMPADD", "TIMESTAMPDIFF", "TIME_FORMAT",
        "TIME_TO_SEC", "TO_DAYS", "TO_SECONDS", "UNIX_TIMESTAMP", "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP",
        "WEEK", "WEEKDAY", "WEEKOFYEAR", "YEAR", "YEARWEEK",
        // JSON
        "JSON_ARRAY", "JSON_ARRAY_APPEND", "JSON_ARRAY_INSERT", "JSON_COMPACT", "JSON_CONTAINS",
        "JSON_CONTAINS_PATH", "JSON_DEPTH", "JSON_DETAILED", "JSON_EQUALS", "JSON_EXISTS", "JSON_EXTRACT",
        "JSON_INSERT", "JSON_KEYS", "JSON_LENGTH", "JSON_LOOSE", "JSON_MERGE", "JSON_MERGE_PATCH",
        "JSON_MERGE_PRESERVE", "JSON_NORMALIZE", "JSON_OBJECT", "JSON_OVERLAPS", "JSON_PRETTY", "JSON_QUERY",
        "JSON_QUOTE", "JSON_REMOVE", "JSON_REPLACE", "JSON_SEARCH", "JSON_SET", "JSON_TABLE", "JSON_TYPE",
        "JSON_UNQUOTE", "JSON_VALID", "JSON_VALUE",
        // Сведения о сервере и сессии
        "BENCHMARK", "CHARSET", "COERCIBILITY", "COLLATION", "CONNECTION_ID", "CURRENT_ROLE", "CURRENT_USER",
        "DATABASE", "DEFAULT", "FOUND_ROWS", "LAST_INSERT_ID", "ROW_COUNT", "SCHEMA", "SESSION_USER",
        "SYSTEM_USER", "USER", "VERSION",
        // Прочее
        "AES_DECRYPT", "AES_ENCRYPT", "CAST", "COMPRESS", "CONVERT", "GET_LOCK", "INET6_ATON", "INET6_NTOA",
        "INET_ATON", "INET_NTOA", "IS_FREE_LOCK", "IS_IPV4", "IS_IPV6", "IS_USED_LOCK", "LASTVAL", "MD5",
        "NEXTVAL", "RANDOM_BYTES", "RELEASE_ALL_LOCKS", "RELEASE_LOCK", "SETVAL", "SHA1", "SHA2", "SLEEP",
        "SYS_GUID", "UNCOMPRESS", "UNCOMPRESSED_LENGTH", "UUID", "UUID_SHORT", "VALUES",
    ]

    static let functionSet = Set(functions)

    /// Самые ходовые функции — в списке раньше остальных, в этом порядке.
    static let commonFunctions = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "CONCAT", "COALESCE", "IFNULL", "IF", "NOW", "DATE", "DATE_FORMAT",
        "LOWER", "UPPER", "LENGTH", "SUBSTRING", "TRIM", "REPLACE", "ROUND", "CAST", "GROUP_CONCAT", "JSON_EXTRACT",
        "JSON_UNQUOTE", "CURDATE", "UNIX_TIMESTAMP", "FROM_UNIXTIME", "DATEDIFF", "TIMESTAMPDIFF", "DATE_ADD",
        "DATE_SUB", "STR_TO_DATE", "YEAR", "MONTH", "DAY", "HOUR", "LEFT", "RIGHT", "ABS", "FLOOR", "CEIL", "RAND",
        "MD5", "UUID", "LAST_INSERT_ID", "FIND_IN_SET", "LOCATE", "INSTR", "LPAD", "CONVERT", "NULLIF",
        "CHAR_LENGTH", "JSON_OBJECT", "JSON_ARRAY", "ROW_NUMBER", "RANK", "LAG", "LEAD",
    ]

    static let commonFunctionRank: [String: Int] = {
        Dictionary(commonFunctions.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// `DATE_FORMAT` → `Date_Format`: заглавные — только в начале частей имени.
    static func titleCase(_ word: String) -> String {
        word.split(separator: "_", omittingEmptySubsequences: false)
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: "_")
    }

    /// Функции без аргументов: вставляются со скобками, курсор — за ними.
    static let niladicFunctions: Set<String> = [
        "CONNECTION_ID", "CUME_DIST", "CURDATE", "CURRENT_ROLE", "CURRENT_USER", "CURTIME", "DATABASE",
        "DENSE_RANK", "FOUND_ROWS", "LAST_INSERT_ID", "NOW", "PERCENT_RANK", "PI", "RAND", "RANK",
        "RELEASE_ALL_LOCKS", "ROW_COUNT", "ROW_NUMBER", "SCHEMA", "SESSION_USER", "SYS_GUID", "SYSDATE",
        "SYSTEM_USER", "USER", "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP", "UUID", "UUID_SHORT", "VERSION",
    ]

    /// Слово — ключевое (любой регистр): для разбора запроса.
    static func isKeyword(_ word: String) -> Bool { keywordSet.contains(word.uppercased()) }

    /// Зарезервированное слово: именем его можно написать только в кавычках.
    static func isReserved(_ word: String) -> Bool { reserved.contains(word.lowercased()) }

    private static let keywordSet = Set(keywords)

    /// Зарезервированные слова MariaDB целиком, включая типы и константы.
    private static let reserved: Set<String> = {
        let words = highlightKeywords.subtracting([
            "after", "algorithm", "any", "auto_increment", "begin", "charset", "columns", "commit",
            "deallocate", "definer", "duplicate", "end", "engine", "escape", "execute", "fields", "flush",
            "function", "global", "grants", "indexes", "modify", "names", "nowait", "prepare", "privileges",
            "processlist", "returns", "rollback", "rollup", "savepoint", "session", "some", "start", "tables",
            "temporary", "transaction", "triggers", "truncate", "variables", "view",
        ])
        return words.union([
            "bigint", "binary", "blob", "char", "character", "dec", "decimal", "double", "float", "float4",
            "float8", "int", "int1", "int2", "int3", "int4", "int8", "integer", "long", "longblob", "longtext",
            "mediumblob", "mediumint", "mediumtext", "middleint", "numeric", "real", "smallint", "tinyblob",
            "tinyint", "tinytext", "varbinary", "varchar", "varcharacter", "null", "true", "false",
        ])
    }()

    // MARK: - Кавычки

    /// Имя, как его вставить в запрос: в обратных кавычках, если без них
    /// оно не имя — зарезервированное слово, пробел, дефис, цифра впереди.
    static func quoted(_ name: String) -> String {
        needsQuotes(name) ? "`" + name.replacingOccurrences(of: "`", with: "``") + "`" : name
    }

    static func needsQuotes(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return true }
        if ("0"..."9").contains(first) { return true }
        for c in name.unicodeScalars {
            let plain = ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c)
                || c == "_" || c == "$" || c.value > 0x7F
            if !plain { return true }
        }
        return isReserved(name)
    }
}
