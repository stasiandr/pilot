import Foundation
import AppKit

/// Один контейнер MariaDB в Docker — локальная база для clm-server.
/// Всё — через CLI `docker`: поднять, остановить, пересоздать, залить дамп,
/// посмотреть логи. Если Docker не отвечает, а стоит Colima, её можно
/// запустить отсюда же.
@MainActor
final class MariaDBContainer: ObservableObject {
    static let shared = MariaDBContainer()

    struct Settings: Codable, Equatable {
        var name = "onestate-mariadb"
        var image = "mariadb:11.4"
        var port = 3306
        var password = "onestate"
        var database = "clm"

        var volume: String { name + "-data" }
    }

    enum State: Equatable {
        case unknown
        /// Нет ни docker, ни colima на диске.
        case noDocker
        /// CLI есть, демон не отвечает.
        case daemonDown(String)
        case absent
        /// `health` — starting / healthy / unhealthy, если проверка есть.
        case running(health: String)
        case stopped(String)
    }

    struct Details: Equatable {
        var image = ""
        var id = ""
        var startedAt = ""
        var ports = ""
    }

    @Published var settings: Settings {
        didSet { save() }
    }
    @Published private(set) var state = State.unknown
    @Published private(set) var details = Details()
    /// Что делается сейчас: «Запуск…», «Загрузка дампа…» — кнопки ждут.
    @Published private(set) var busy: String?
    @Published private(set) var followsLogs = false
    let log = RunLog()

    private var polling: Task<Void, Never>?
    private var logProcess: Process?
    private var viewers = 0
    private static let defaultsKey = "pilot.mariadb.container"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Параметры подключения к этому контейнеру — для обозревателя.
    var connectionOptions: MySQLConnection.Options {
        MySQLConnection.Options(host: "127.0.0.1", port: settings.port, user: "root",
                                password: settings.password, database: settings.database)
    }

    /// Переменные окружения clm-server (`StartUp.cs`) для этой базы:
    /// пользователь и база — из `~/nrpm/.env`, если он там заведён.
    var serverEnvironment: String {
        let env = ServerEnvFile.read()
        let user = env["MYSQL_USER"].flatMap { $0.isEmpty ? nil : $0 }
        return """
        MYSQL_HOST=127.0.0.1
        MYSQL_PORT=\(settings.port)
        MYSQL_USER=\(user ?? "root")
        MYSQL_PASSWORD=\(user != nil ? env["MYSQL_PASSWORD"] ?? "" : settings.password)
        MYSQL_DATABASE=\(env["MYSQL_DATABASE"].flatMap { $0.isEmpty ? nil : $0 } ?? settings.database)
        """
    }

    // MARK: - Окно открыто — следим

    func appear() {
        viewers += 1
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func disappear() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        polling?.cancel()
        polling = nil
        stopLogs()
    }

    func refresh() async {
        guard DockerCLI.docker != nil else {
            state = .noDocker
            return
        }
        let r = await DockerCLI.run(["inspect", "--format",
                                     "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Config.Image}}|{{.Id}}|{{.State.StartedAt}}|{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostPort}}→{{$p}} {{end}}{{end}}",
                                     settings.name])
        if r.status == 0 {
            let f = r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { return }
            // Порт привязан и к IPv4, и к IPv6 — одинаковые пары показываем раз.
            var ports: [String] = []
            for p in f[5].split(separator: " ").map(String.init) where !ports.contains(p) { ports.append(p) }
            details = Details(image: f[2], id: String(f[3].prefix(12)), startedAt: f[4], ports: ports.joined(separator: " "))
            state = f[0] == "running" ? .running(health: f[1]) : .stopped(f[0])
        } else if r.err.localizedCaseInsensitiveContains("no such") {
            details = Details()
            state = .absent
        } else {
            details = Details()
            state = .daemonDown(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Действия

    var canStartColima: Bool { DockerCLI.colima != nil }

    func startColima() {
        perform(L("Запуск Colima…"), tool: DockerCLI.colima, ["start"])
    }

    /// Новый контейнер с томом для данных: пересоздание контейнера базу не теряет.
    /// Создать, дождаться базы и завести в ней пользователя clm-server.
    func create() {
        launch { _ in }
    }

    private var createArguments: [String] {
        let s = settings
        return ["run", "-d",
            "--name", s.name,
            "-p", "\(s.port):3306",
            "-e", "MARIADB_ROOT_PASSWORD=\(s.password)",
            "-e", "MARIADB_ROOT_HOST=%",
            "-e", "MARIADB_DATABASE=\(s.database)",
            "-v", "\(s.volume):/var/lib/mysql",
            "--health-cmd", "healthcheck.sh --connect --innodb_initialized",
            "--health-interval", "3s", "--health-retries", "40",
            "--restart", "unless-stopped",
            s.image]
    }

    func start() { perform(L("Запуск…"), ["start", settings.name]) }

    /// Поднять базу, в каком бы состоянии она ни была — Docker лежит,
    /// контейнера нет, он остановлен, — и дождаться, пока она примет
    /// подключения. `ready(false)` — не вышло: что случилось, есть в логе.
    func launch(ready: @escaping @MainActor (Bool) -> Void) {
        guard busy == nil else { return }
        busy = L("Проверка…")
        Task {
            await refresh()
            var ok = true
            var created = false
            if case .daemonDown = state {
                ok = await step(L("Запуск Colima…"), DockerCLI.colima, ["start"])
                if ok { await refresh() }
            }
            if ok {
                switch state {
                case .absent:
                    ok = await step(L("Создание контейнера…"), DockerCLI.docker, createArguments)
                    created = ok
                case .stopped: ok = await step(L("Запуск…"), DockerCLI.docker, ["start", settings.name])
                case .running: break
                case .unknown, .noDocker, .daemonDown: ok = false
                }
            }
            if ok { ok = await waitUntilHealthy() }
            if ok && created { ok = await provisionServerUser() }
            busy = nil
            await refresh()
            ready(ok)
        }
    }

    /// Завести пользователя из `.env` в работающем контейнере — для
    /// контейнера, созданного раньше, чем Pilot научился делать это сам.
    func createServerUser() {
        guard busy == nil else { return }
        busy = L("Создание пользователя…")
        Task {
            _ = await provisionServerUser()
            busy = nil
        }
    }

    /// clm-server ходит в базу пользователем из `~/nrpm/.env`, а не root:
    /// на свежем контейнере его нет, и сервер не стартовал. Заводим его,
    /// его базу и права на всё — база локальная, а регионы сервер создаёт
    /// сам. Повторный запуск безвреден: пароль просто выставится заново.
    ///
    /// Пароли — через окружение и stdin, не аргументами: те видны в `ps`.
    private func provisionServerUser() async -> Bool {
        let env = ServerEnvFile.read()
        guard let user = env["MYSQL_USER"], !user.isEmpty, user != "root" else {
            log.append(L("В \(ServerEnvFile.displayPath) нет MYSQL_USER — пользователь не создан") + "\n\n")
            return true
        }
        guard let docker = DockerCLI.docker else { return false }
        busy = L("Создание пользователя…")
        let account = "'\(Self.sqlString(user))'@'%'"
        let password = Self.sqlString(env["MYSQL_PASSWORD"] ?? "")
        var sql = ""
        if let database = env["MYSQL_DATABASE"], !database.isEmpty {
            sql += "CREATE DATABASE IF NOT EXISTS `\(database.replacingOccurrences(of: "`", with: "``"))`;\n"
        }
        sql += """
        CREATE USER IF NOT EXISTS \(account) IDENTIFIED BY '\(password)';
        ALTER USER \(account) IDENTIFIED BY '\(password)';
        GRANT ALL PRIVILEGES ON *.* TO \(account) WITH GRANT OPTION;
        FLUSH PRIVILEGES;
        """
        log.append("$ mariadb: CREATE USER \(account) (\(ServerEnvFile.displayPath))\n")
        let ok = await stream(URL(fileURLWithPath: "/bin/bash"),
                              ["-c", "printf '%s' \"$PILOT_SQL\" | \"$1\" exec -i -e MYSQL_PWD \"$2\" mariadb -uroot",
                               "bash", docker.path, settings.name],
                              environment: ["PILOT_SQL": sql, "MYSQL_PWD": settings.password],
                              echo: false)
        log.append(ok ? L("Готово") + "\n\n" : "\n")
        return ok
    }

    /// Строка для SQL в одинарных кавычках.
    private static func sqlString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// Одна команда запуска: её название — в `busy`, вывод — в лог.
    private func step(_ title: String, _ tool: URL?, _ args: [String]) async -> Bool {
        busy = title
        let ok = await stream(tool, args)
        log.append(ok ? L("Готово") + "\n\n" : "\n")
        return ok
    }

    /// Контейнер запущен — но MariaDB в нём ещё минуту может разворачивать
    /// базу, а подключение до этого получит отказ. Ждём проверку здоровья.
    private func waitUntilHealthy() async -> Bool {
        busy = L("База готовится…")
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            await refresh()
            switch state {
            case .running(let health) where health == "healthy" || health.isEmpty:
                return true
            case .running(let health) where health == "unhealthy":
                return false
            case .running:
                break
            default:
                return false
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
    func stop() { perform(L("Остановка…"), ["stop", settings.name]) }
    func restart() { perform(L("Перезапуск…"), ["restart", settings.name]) }

    /// Удаляет контейнер; с `data` — и том с базой.
    func remove(data: Bool) {
        let name = settings.name, volume = settings.volume
        run(L("Удаление…")) {
            var ok = await self.stream(DockerCLI.docker, ["rm", "-f", name])
            if ok && data { ok = await self.stream(DockerCLI.docker, ["volume", "rm", volume]) }
            return ok
        }
    }

    /// Заливает дамп `.sql` или `.sql.gz` в базу контейнера — как в инструкции
    /// к плейтестам, только без ручного `pv | mariadb`.
    func importDump(_ url: URL) {
        guard let docker = DockerCLI.docker else { return }
        let s = settings
        let script = """
        set -o pipefail
        case "$1" in *.gz) gunzip -c "$1" ;; *) cat "$1" ;; esac | "$2" exec -i "$3" mariadb -uroot -p"$4" "$5"
        """
        log.append("$ mariadb \(s.database) < \(url.path)\n")
        run(L("Загрузка дампа…")) {
            await self.stream(URL(fileURLWithPath: "/bin/bash"),
                              ["-c", script, "bash", url.path, docker.path, s.name, s.password, s.database],
                              echo: false)
        }
    }

    func chooseDump() {
        let panel = NSOpenPanel()
        panel.title = L("Дамп базы (.sql или .sql.gz)")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importDump(url)
    }

    // MARK: - Логи

    func toggleLogs() {
        if followsLogs { stopLogs() } else { followLogs() }
    }

    private func followLogs() {
        guard let docker = DockerCLI.docker else { return }
        stopLogs()
        log.append("$ docker logs -f --tail 200 \(settings.name)\n")
        logProcess = DockerCLI.spawn(docker, ["logs", "-f", "--tail", "200", settings.name]) { [weak self] chunk in
            self?.log.append(chunk)
        } exit: { [weak self] _ in
            self?.followsLogs = false
            self?.logProcess = nil
        }
        followsLogs = logProcess != nil
    }

    private func stopLogs() {
        logProcess?.terminate()
        logProcess = nil
        followsLogs = false
    }

    // MARK: - Запуск команд

    private func perform(_ title: String, tool: URL? = DockerCLI.docker, _ args: [String]) {
        run(title) { await self.stream(tool, args) }
    }

    private func run(_ title: String, _ body: @escaping () async -> Bool) {
        guard busy == nil else { return }
        busy = title
        Task {
            let ok = await body()
            log.append(ok ? L("Готово") + "\n\n" : "\n")
            busy = nil
            await refresh()
        }
    }

    /// Команда с выводом в лог окна; `true` — вышла с нулём.
    private func stream(_ tool: URL?, _ args: [String], environment: [String: String] = [:],
                        echo: Bool = true) async -> Bool {
        guard let tool else { return false }
        if echo { log.append("$ \(tool.lastPathComponent) \(args.joined(separator: " "))\n") }
        return await withCheckedContinuation { continuation in
            let process = DockerCLI.spawn(tool, args, environment: environment) { [weak self] chunk in
                self?.log.append(chunk)
            } exit: { [weak self] status in
                if status != 0 { self?.log.append(L("Код выхода \(String(status))") + "\n") }
                continuation.resume(returning: status == 0)
            }
            if process == nil { continuation.resume(returning: false) }
        }
    }
}

/// Где лежат `docker` и `colima` и как их звать из приложения, у которого
/// PATH не тот, что в терминале.
enum DockerCLI {
    static let searchPath = [
        "/opt/homebrew/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.orbstack/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
        "/usr/bin", "/bin",
    ]

    static let docker = find("docker")
    static let colima = find("colima")

    private static func find(_ name: String) -> URL? {
        searchPath.map { $0 + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"].map { searchPath.joined(separator: ":") + ":" + $0 } ?? searchPath.joined(separator: ":")
        env["PATH"] = path
        return env
    }

    struct Output {
        var status: Int32
        var out: String
        var err: String
    }

    /// Короткая команда целиком: код выхода и оба вывода.
    static func run(_ args: [String]) async -> Output {
        guard let docker else { return Output(status: -1, out: "", err: "docker not found") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = docker
                process.arguments = args
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    continuation.resume(returning: Output(status: -1, out: "", err: error.localizedDescription))
                    return
                }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus,
                                                      out: String(decoding: o, as: UTF8.self),
                                                      err: String(decoding: e, as: UTF8.self)))
            }
        }
    }

    /// Долгая команда: вывод (оба потока) приходит кусками на главном потоке.
    @MainActor
    static func spawn(_ tool: URL, _ args: [String], environment extra: [String: String] = [:],
                      output: @escaping @MainActor (String) -> Void,
                      exit: @escaping @MainActor (Int32) -> Void) -> Process? {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.environment = environment.merging(extra) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in output(text) }
        }
        process.terminationHandler = { p in
            let status = p.terminationStatus
            // Хвост вывода мог ещё не дочитаться — пусть сперва дойдёт он.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { exit(status) }
            }
        }
        do {
            try process.run()
            return process
        } catch {
            output(error.localizedDescription + "\n")
            return nil
        }
    }
}

/// `~/nrpm/.env` — окружение, с которым запускается clm-server. Отсюда
/// берётся пользователь базы, которого надо завести в контейнере.
enum ServerEnvFile {
    static let path = NSHomeDirectory() + "/nrpm/.env"
    static let displayPath = "~/nrpm/.env"

    /// `KEY=VALUE` построчно; комментарии, пустые строки и `export` — мимо,
    /// кавычки вокруг значения снимаются.
    static func read() -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}
