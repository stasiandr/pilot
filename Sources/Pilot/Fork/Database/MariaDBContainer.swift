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

    /// Переменные окружения clm-server (`StartUp.cs`) для этой базы.
    var serverEnvironment: String {
        """
        MYSQL_HOST=127.0.0.1
        MYSQL_PORT=\(settings.port)
        MYSQL_USER=root
        MYSQL_PASSWORD=\(settings.password)
        MYSQL_DATABASE=\(settings.database)
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
    func create() {
        let s = settings
        perform(L("Создание контейнера…"), ["run", "-d",
            "--name", s.name,
            "-p", "\(s.port):3306",
            "-e", "MARIADB_ROOT_PASSWORD=\(s.password)",
            "-e", "MARIADB_ROOT_HOST=%",
            "-e", "MARIADB_DATABASE=\(s.database)",
            "-v", "\(s.volume):/var/lib/mysql",
            "--health-cmd", "healthcheck.sh --connect --innodb_initialized",
            "--health-interval", "3s", "--health-retries", "40",
            "--restart", "unless-stopped",
            s.image])
    }

    func start() { perform(L("Запуск…"), ["start", settings.name]) }
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
    private func stream(_ tool: URL?, _ args: [String], echo: Bool = true) async -> Bool {
        guard let tool else { return false }
        if echo { log.append("$ \(tool.lastPathComponent) \(args.joined(separator: " "))\n") }
        return await withCheckedContinuation { continuation in
            let process = DockerCLI.spawn(tool, args) { [weak self] chunk in
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
    static func spawn(_ tool: URL, _ args: [String],
                      output: @escaping @MainActor (String) -> Void,
                      exit: @escaping @MainActor (Int32) -> Void) -> Process? {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.environment = environment
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
