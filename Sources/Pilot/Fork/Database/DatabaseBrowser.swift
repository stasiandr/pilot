import Foundation

/// Обозреватель базы — маленький DBeaver: слева базы и таблицы сервера,
/// справа SQL и таблица результата. Любой запрос уходит как есть.
@MainActor
final class DatabaseBrowser: ObservableObject {
    static let shared = DatabaseBrowser()

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(String)
        case failed(String)
    }

    struct Table: Identifiable, Hashable {
        var schema: String
        var name: String
        var isView: Bool
        var rows: Int?
        var id: String { schema + "." + name }
    }

    struct Schema: Identifiable, Hashable {
        var name: String
        /// `nil` — ещё не спрашивали.
        var tables: [Table]?
        var id: String { name }
    }

    /// Итог выполнения: ответы по запросам или ошибка.
    struct Outcome {
        var results: [MySQLConnection.Result] = []
        var error: String?
        var elapsed: TimeInterval = 0
        var sql = ""
    }

    @Published var options: MySQLConnection.Options {
        didSet { save() }
    }
    @Published private(set) var state = ConnectionState.disconnected
    @Published private(set) var schemas: [Schema] = []
    /// База по умолчанию для запросов (`USE`).
    @Published private(set) var currentSchema: String?
    @Published var sql: String {
        didSet { UserDefaults.standard.set(sql, forKey: Self.sqlKey) }
    }
    @Published private(set) var outcome: Outcome?
    @Published var selectedResult = 0
    @Published private(set) var isRunning = false

    private var session: MySQLSession?
    private static let optionsKey = "pilot.database.options"
    private static let sqlKey = "pilot.database.sql"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.optionsKey),
           let saved = try? JSONDecoder().decode(MySQLConnection.Options.self, from: data) {
            options = saved
        } else {
            options = MariaDBContainer.shared.connectionOptions
        }
        sql = UserDefaults.standard.string(forKey: Self.sqlKey) ?? "SELECT VERSION();"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: Self.optionsKey)
        }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Не своя машина — стоит помнить, что запросы идут на чужой сервер.
    var isRemote: Bool {
        !["127.0.0.1", "localhost", "::1", ""].contains(options.host.trimmingCharacters(in: .whitespaces).lowercased())
    }

    // MARK: - Подключение

    func connect() {
        disconnect()
        state = .connecting
        let session = MySQLSession(options: options)
        self.session = session
        Task {
            do {
                try await session.connect()
                guard self.session === session else { return }
                state = .connected(session.serverVersion)
                currentSchema = options.database.isEmpty ? nil : options.database
                await loadSchemas()
            } catch {
                guard self.session === session else { return }
                self.session = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    func connect(to options: MySQLConnection.Options) {
        self.options = options
        connect()
    }

    func disconnect() {
        session?.close()
        session = nil
        state = .disconnected
        schemas = []
        currentSchema = nil
        isRunning = false
    }

    func refresh() {
        Task { await loadSchemas() }
    }

    private func loadSchemas() async {
        guard let session else { return }
        let opened = Set(schemas.filter { $0.tables != nil }.map(\.name))
        do {
            let rows = try await session.query("SHOW DATABASES").first?.rows ?? []
            schemas = rows.compactMap { $0.first ?? nil }.map { Schema(name: $0) }
            for name in opened.union(currentSchema.map { [$0] } ?? []) {
                await loadTables(name)
            }
        } catch {
            fail(error)
        }
    }

    func loadTables(_ schema: String) async {
        guard let session else { return }
        let sql = """
        SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = \(Self.literal(schema)) ORDER BY TABLE_NAME
        """
        do {
            let rows = try await session.query(sql).first?.rows ?? []
            let tables = rows.map { row in
                Table(schema: schema, name: row[0] ?? "", isView: (row[1] ?? "").contains("VIEW"),
                      rows: row[2].flatMap { Int($0) })
            }
            if let i = schemas.firstIndex(where: { $0.name == schema }) { schemas[i].tables = tables }
        } catch {
            fail(error)
        }
    }

    /// Разорвалось соединение — дальше без него; ошибку запроса покажет результат.
    private func fail(_ error: Error) {
        if error is MySQLConnection.ProtocolError {
            session?.close()
            session = nil
            state = .failed(error.localizedDescription)
        }
    }

    func use(_ schema: String) {
        guard let session, schema != currentSchema else { return }
        Task {
            do {
                _ = try await session.query("USE " + Self.identifier(schema))
                currentSchema = schema
                if schemas.first(where: { $0.name == schema })?.tables == nil { await loadTables(schema) }
            } catch {
                fail(error)
                outcome = Outcome(error: error.localizedDescription, sql: "USE " + schema)
            }
        }
    }

    // MARK: - Запросы

    /// Первые строки таблицы — как двойной щелчок в DBeaver.
    func openData(_ table: Table) {
        sql = "SELECT * FROM \(Self.identifier(table.schema)).\(Self.identifier(table.name)) LIMIT 1000;"
        execute(sql)
    }

    func openStructure(_ table: Table) {
        sql = "SHOW FULL COLUMNS FROM \(Self.identifier(table.schema)).\(Self.identifier(table.name));"
        execute(sql)
    }

    func openDDL(_ table: Table) {
        let kind = table.isView ? "VIEW" : "TABLE"
        sql = "SHOW CREATE \(kind) \(Self.identifier(table.schema)).\(Self.identifier(table.name));"
        execute(sql)
    }

    func execute(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !text.isEmpty, !isRunning else { return }
        isRunning = true
        let started = Date()
        Task {
            var outcome = Outcome(sql: text)
            do {
                outcome.results = try await session.query(text)
            } catch {
                outcome.error = error.localizedDescription
                fail(error)
            }
            outcome.elapsed = Date().timeIntervalSince(started)
            guard self.session === session else { return }
            isRunning = false
            // Первым показываем последнюю выборку: обычно ради неё и писали.
            selectedResult = outcome.results.lastIndex(where: \.isResultSet) ?? max(0, outcome.results.count - 1)
            self.outcome = outcome
            // Сменили базу или создали/удалили таблицу — дерево должно это видеть.
            let upper = text.uppercased()
            if ["CREATE", "DROP", "ALTER", "RENAME", "USE "].contains(where: upper.contains) {
                if upper.hasPrefix("USE "), outcome.error == nil {
                    currentSchema = text.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " `;\n"))
                }
                await loadSchemas()
            }
        }
    }

    func cancel() {
        session?.cancelQuery()
    }

    // MARK: - Кавычки

    static func identifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }
}
