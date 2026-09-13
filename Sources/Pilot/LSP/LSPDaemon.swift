import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Демон языковых серверов.
///
/// Roslyn на Unity-проекте поднимается секунды, а индекс символов строит ещё
/// полминуты — и всё это заново при каждом запуске Pilot. Демон держит серверы
/// между запусками: Pilot подключается к нему по unix-сокету и говорит обычный
/// LSP, а демон отвечает от имени уже прогретого сервера.
///
/// Демон — тот же исполняемый файл Pilot с флагом `--lsp-daemon`. Pilot
/// запускает его сам, если подключиться не к кому, а демон сам выходит, когда
/// держать больше нечего.
///
/// Цена — память: прогретый Roslyn на Unity-проекте занимает 4–6 ГБ. Её не
/// жалеем, но и не раздаём впустую — серверы без клиентов живут по правилам
/// `Policy`: быстрые не держим вовсе (незачем), дорогих держим долго, а
/// пределы по числу и памяти — страховка от утечки, а не экономия.
final class LSPDaemon: @unchecked Sendable {

    static let attachMethod = "pilot/attach"
    /// Демон от другой сборки Pilot: он уходит, клиент поднимает свежий.
    static let staleDaemonCode = -32099
    /// Клиент от старой сборки: пусть работает без демона.
    static let staleClientCode = -32098

    struct Policy {
        /// Сервер, который поднимается быстрее, держать незачем: игрушечный
        /// проект перезапустится раньше, чем его заметишь, а место в
        /// `maxIdleServers` он занял бы у настоящего.
        var keepIfLoadTookAtLeast: TimeInterval = 4
        /// Сколько серверов держим без клиентов; лишние — самые давние — уходят.
        var maxIdleServers = 5
        /// Сервер без клиентов дольше этого останавливается: за двое суток
        /// проект либо снова открыли, либо он больше не нужен.
        var idleTimeout: TimeInterval = 48 * 3600
        /// Суммарная память серверов без клиентов. Не экономия — страховка
        /// от сервера, который течёт.
        var idleMemoryBudget: UInt64 = 32 << 30
        /// Демон без серверов и клиентов выходит через столько.
        var exitWhenEmptyAfter: TimeInterval = 60
        /// Как часто пересматривать, кого держать.
        var sweepInterval: TimeInterval = 60
    }

    let socketPath: String
    let build: String
    let policy: Policy
    /// Исполняемый файл демона: если его пересобрали, демон устарел.
    private let executablePath: String?
    /// Вместо exit(0) — для тестов.
    var onExit: (() -> Void)?

    private let queue = DispatchQueue(label: "pilot.lspd")
    private var listenFD: Int32 = -1
    private var listener: DispatchSourceRead?
    private var sweeper: DispatchSourceTimer?
    private var connections: [Int: Connection] = [:]
    private var servers: [String: Server] = [:]
    private var nextConnectionID = 1
    private var emptySince: Date? = Date()
    private var exiting = false

    init(socketPath: String, build: String, executablePath: String?, policy: Policy = Policy()) {
        self.socketPath = socketPath
        self.build = build
        self.executablePath = executablePath
        self.policy = policy
    }

    // MARK: - Подключение со стороны Pilot

    /// Сокет демона для этого исполняемого файла Pilot. У каждой копии Pilot
    /// (скажем, из разных checkout'ов) свой демон — они не мешают друг другу.
    static func socketPath(executable: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in executable.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent(String(format: "pilot-lspd-%016llx.sock", hash))
    }

    /// Сборка = путь к исполняемому файлу и время его изменения. Pilot
    /// пересобрали — сменилась и сборка, старый демон уступает место новому.
    static func buildID(executable: String) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: executable))?[.modificationDate] as? Date
        return "\(executable)@\(Int((modified?.timeIntervalSince1970 ?? 0) * 1000))"
    }

    /// Уведомление «остановись»: демона выключили в настройках, держать
    /// серверы больше незачем.
    static let quitMethod = "pilot/quit"

    /// Просит живого демона остановить серверы и выйти. Если демона нет — ничего.
    static func requestQuit(socketPath: String) {
        guard let fd = UnixSocket.connectTo(socketPath),
              let body = try? JSON.encode(["jsonrpc": "2.0", "method": quitMethod, "params": [String: Any]()])
        else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? handle.write(contentsOf: MessageFramer.frame(body))
        try? handle.close()
    }

    static var logURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("Pilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lspd.log")
    }

    /// Сокет к живому демону; если демона нет — запускает его и ждёт.
    /// Блокирует до пары секунд — вызывать вне главного потока.
    static func connectOrLaunch(executable: String, socketPath: String) -> Int32? {
        if let fd = UnixSocket.connectTo(socketPath) { return fd }
        guard launch(executable: executable, socketPath: socketPath) else { return nil }
        for _ in 0..<60 {
            usleep(50_000)
            if let fd = UnixSocket.connectTo(socketPath) { return fd }
        }
        return nil
    }

    /// Ждёт, пока устаревший демон освободит сокет.
    static func waitUntilGone(socketPath: String) {
        for _ in 0..<40 {
            guard let fd = UnixSocket.connectTo(socketPath) else { return }
            close(fd)
            usleep(50_000)
        }
    }

    /// Демон — в своей группе процессов: Ctrl-C в терминале, из которого
    /// запущен Pilot, не должен его задевать. Вывод — в лог.
    private static func launch(executable: String, socketPath: String) -> Bool {
        let arguments = [executable, "--lsp-daemon", socketPath]
        #if os(macOS)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, &argv, environ) == 0 else { return false }
        // Демон — наш ребёнок, пока Pilot жив: забираем код выхода, чтобы не висел зомби.
        let reaper = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)
        reaper.setEventHandler { waitpid(pid, nil, WNOHANG); reaper.cancel() }
        reaper.resume()
        return true
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        if let log = try? FileHandle(forWritingTo: logURL) {
            log.seekToEndOfFile()
            process.standardOutput = log
            process.standardError = log
        }
        return (try? process.run()) != nil
        #endif
    }

    // MARK: - Точка входа демона

    /// Аргумент `--lsp-daemon <сокет>`, если процесс запущен демоном.
    static func socketArgument(_ arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "--lsp-daemon"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func run(socketPath: String) -> Never {
        // Пишем в сокеты и пайпы, которые могут закрыться в любой момент;
        // сигналы терминала демону не адресованы.
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let daemon = LSPDaemon(socketPath: socketPath, build: buildID(executable: executable),
                               executablePath: executable)
        do {
            try daemon.start()
        } catch {
            log("не стартовал: \(error)")
            exit(0)
        }
        // `kill` — штатный способ остановить демона руками: серверы получают
        // `exit`, сокет убирается.
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: daemon.queue)
        terminate.setEventHandler { daemon.shutdown("SIGTERM") }
        terminate.resume()
        log("запущен, pid \(getpid()), сокет \(socketPath)")
        withExtendedLifetime(terminate) { dispatchMain() }
    }

    static func log(_ text: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withFullTime])
        print("[\(stamp)] \(text)")
        fflush(stdout)
    }

    // MARK: - Жизненный цикл

    func start() throws {
        listenFD = try UnixSocket.serve(socketPath)
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        listener = source

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + policy.sweepInterval, repeating: policy.sweepInterval)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweeper = timer
    }

    /// Всё останавливает и выходит. Синхронно на очереди демона.
    private func shutdown(_ reason: String) {
        guard !exiting else { return }
        exiting = true
        Self.log("выхожу: \(reason)")
        listener?.cancel()
        sweeper?.cancel()
        close(listenFD)
        unlink(socketPath)
        for server in servers.values { server.client.stop() }
        servers.removeAll()
        for connection in connections.values { connection.close() }
        connections.removeAll()
        // Дать уйти последним ответам и `exit` серверам.
        queue.asyncAfter(deadline: .now() + 0.7) { [onExit] in
            if let onExit { onExit() } else { exit(0) }
        }
    }

    /// Для тестов и отладки: сколько серверов живо и сколько клиентов подключено.
    func snapshot() -> (servers: Int, connections: Int, idle: Int) {
        queue.sync {
            (servers.count, connections.count, servers.values.filter { $0.connections.isEmpty }.count)
        }
    }

    /// Для тестов: пересмотреть серверы прямо сейчас.
    func sweepNow() { queue.sync { sweep() } }

    // MARK: - Соединения

    /// Как и Server, трогается только на очереди демона.
    private final class Connection: @unchecked Sendable {
        let id: Int
        let handle: FileHandle
        private let writeQueue: DispatchQueue
        var framer = MessageFramer()
        var serverKey: String?
        /// Ответ на initialize отдан: с этого момента пересылаем уведомления.
        var initialized = false
        var openDocuments: Set<String> = []
        var inflight: [Int: Task<Void, Never>] = [:]

        init(id: Int, handle: FileHandle) {
            self.id = id
            self.handle = handle
            self.writeQueue = DispatchQueue(label: "pilot.lspd.write.\(id)")
        }

        func send(_ body: [String: Any]) {
            guard let data = try? JSON.encode(body) else { return }
            let framed = MessageFramer.frame(data)
            writeQueue.async { [handle] in try? handle.write(contentsOf: framed) }
        }

        func reply(_ id: Int, _ result: Any) {
            send(["jsonrpc": "2.0", "id": id, "result": result])
        }

        func fail(_ id: Int, code: Int, _ message: String) {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }

        func notify(_ method: String, _ params: Any?) {
            send(["jsonrpc": "2.0", "method": method, "params": params ?? [String: Any]()])
        }

        func close() {
            handle.readabilityHandler = nil
            writeQueue.async { [handle] in try? handle.close() }
        }
    }

    private func acceptPending() {
        while let fd = UnixSocket.acceptClient(listenFD) {
            let id = nextConnectionID
            nextConnectionID += 1
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            connections[id] = Connection(id: id, handle: handle)
            emptySince = nil
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.queue.async { self?.disconnect(id) }
                } else {
                    self?.queue.async { self?.receive(data, from: id) }
                }
            }
        }
    }

    private func receive(_ data: Data, from id: Int) {
        guard let connection = connections[id] else { return }
        for body in connection.framer.feed(data) {
            guard let message = JSON.object(from: body), let method = message["method"] as? String
            else { continue }   // ответов от клиентов не бывает: демон их ни о чём не спрашивает
            if let requestID = message["id"] as? Int {
                handleRequest(method, id: requestID, params: message["params"], from: connection)
            } else {
                handleNotification(method, message["params"], from: connection)
            }
        }
    }

    private func disconnect(_ id: Int) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.inflight.values.forEach { $0.cancel() }
        connection.close()
        if let key = connection.serverKey, let server = servers[key] {
            // Документы, которые открывал только этот клиент, закрываем: иначе
            // Roslyn так и держал бы их текст вместо файла на диске.
            for uri in connection.openDocuments { release(uri, in: server) }
            server.connections.remove(id)
            server.initWaiters.removeAll { $0.connection == id }
            if server.connections.isEmpty {
                server.idleSince = Date()
                Self.log("\(server.name): клиентов не осталось")
            }
        }
        sweep()
    }

    // MARK: - Серверы

    /// Всё состояние — только на очереди демона; колбэки с других потоков
    /// сначала перепрыгивают на неё.
    private final class Server: @unchecked Sendable {
        let key: String
        let name: String
        let client: LSPClient
        let fingerprint: Data
        let startedAt = Date()
        var connections: Set<Int> = []
        var documentRefs: [String: Int] = [:]
        var initializeResult: Any?
        var initializeError: String?
        var initWaiters: [(connection: Int, request: Int)] = []
        var projectsLoaded = false
        var projectMarkers = 0
        var loadDuration: TimeInterval?
        var idleSince: Date?

        init(key: String, name: String, client: LSPClient, fingerprint: Data) {
            self.key = key
            self.name = name
            self.client = client
            self.fingerprint = fingerprint
        }
    }

    private static func fingerprint(_ config: ServerConfig) -> Data {
        (try? JSONSerialization.data(withJSONObject: config.json, options: [.sortedKeys])) ?? Data()
    }

    private func server(for connection: Connection) -> Server? {
        connection.serverKey.flatMap { servers[$0] }
    }

    private func attach(_ params: Any?, id: Int, from connection: Connection) {
        guard let dict = params as? [String: Any],
              let clientBuild = dict["build"] as? String,
              let rootPath = dict["root"] as? String,
              let configJSON = dict["config"] as? [String: Any],
              let config = ServerConfig(json: configJSON) else {
            connection.fail(id, code: -32602, "некорректный attach")
            return
        }
        guard clientBuild == build else {
            // Кто из нас свежее, видно по файлу на диске: если пересобрали
            // демона — уходит он, иначе без демона работает старый клиент.
            if let executablePath, Self.buildID(executable: executablePath) != build {
                connection.fail(id, code: Self.staleDaemonCode, "демон от прошлой сборки Pilot")
                shutdown("Pilot пересобран")
            } else {
                connection.fail(id, code: Self.staleClientCode, "Pilot старше демона")
            }
            return
        }
        guard connection.serverKey == nil else {
            connection.fail(id, code: -32600, "соединение уже подключено к серверу")
            return
        }

        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let key = "\(config.id)|\(root.path)"
        let fingerprint = Self.fingerprint(config)
        // Настройки сервера поменялись (servers.json, новая версия Roslyn):
        // старый, если он никому не нужен, уступает место новому.
        if let existing = servers[key], existing.fingerprint != fingerprint, existing.connections.isEmpty {
            stop(existing, "сменилась конфигурация")
        }

        let server: Server
        let reused: Bool
        if let existing = servers[key] {
            server = existing
            reused = true
        } else {
            do {
                server = try launch(config, root: root, key: key, fingerprint: fingerprint)
                reused = false
            } catch {
                connection.fail(id, code: -32603, "сервер не запустился: \(error.localizedDescription)")
                return
            }
        }
        server.connections.insert(connection.id)
        server.idleSince = nil
        connection.serverKey = key
        Self.log("\(server.name): клиент #\(connection.id) подключён\(reused ? " к работающему серверу" : "")")
        connection.reply(id, ["reused": reused, "pid": Int(getpid())])
    }

    private func launch(_ config: ServerConfig, root: URL, key: String, fingerprint: Data) throws -> Server {
        let client = LSPClient(config: config, root: root)
        let server = Server(key: key, name: "\(config.displayName) · \(root.lastPathComponent)",
                            client: client, fingerprint: fingerprint)

        // Колбэки приходят с потока чтения; `servers[key] === server` отсекает
        // сообщения от сервера, который уже остановлен и заменён.
        client.onNotification = { [weak self, weak server] method, params in
            self?.queue.async {
                guard let self, let server, self.servers[key] === server else { return }
                self.broadcast(method, params, from: server)
            }
        }
        client.onProjectLoaded = { [weak self, weak server] in
            self?.queue.async { server?.projectMarkers += 1 }
        }
        client.onProjectsLoaded = { [weak self, weak server] in
            self?.queue.async {
                guard let self, let server, self.servers[key] === server else { return }
                self.projectsFinished(server)
            }
        }
        client.onExit = { [weak self, weak server] reason in
            self?.queue.async {
                guard let self, let server, self.servers[key] === server else { return }
                self.died(server, reason)
            }
        }

        try client.start()
        servers[key] = server
        Self.log("\(server.name): запускаю сервер")

        Task { [weak self] in
            do {
                try await client.initialize()
                self?.queue.async { self?.initialized(server) }
            } catch {
                self?.queue.async { self?.initializationFailed(server, error) }
            }
        }
        return server
    }

    private func initialized(_ server: Server) {
        guard servers[server.key] === server else { return }
        server.initializeResult = server.client.initializeResult ?? NSNull()
        // Сервер без загрузки проектов готов сразу после initialize.
        if server.client.projectsToLoad == nil { projectsFinished(server) }
        let waiters = server.initWaiters
        server.initWaiters.removeAll()
        for waiter in waiters {
            guard let connection = connections[waiter.connection] else { continue }
            answerInitialize(waiter.request, server: server, connection: connection)
        }
    }

    private func initializationFailed(_ server: Server, _ error: Error) {
        guard servers[server.key] === server else { return }
        server.initializeError = error.localizedDescription
        for waiter in server.initWaiters {
            connections[waiter.connection]?.fail(waiter.request, code: -32603, error.localizedDescription)
        }
        server.initWaiters.removeAll()
        died(server, "initialize не прошёл: \(error.localizedDescription)")
    }

    private func projectsFinished(_ server: Server) {
        guard !server.projectsLoaded else { return }
        server.projectsLoaded = true
        server.loadDuration = Date().timeIntervalSince(server.startedAt)
        Self.log(String(format: "%@: проекты загружены за %.1f с", server.name, server.loadDuration ?? 0))
        // Индекс символов прогреваем здесь, а не в Pilot: он переживёт и
        // закрытие окна посреди прогрева.
        let client = server.client
        let name = server.name
        Task {
            let started = Date()
            await client.warmUpSymbolIndex()
            Self.log(String(format: "%@: индекс символов прогрет за %.1f с", name, Date().timeIntervalSince(started)))
        }
        sweep()
    }

    private func died(_ server: Server, _ reason: String) {
        Self.log("\(server.name): сервер умер — \(reason)")
        servers[server.key] = nil
        // Клиенты увидят закрытое соединение и покажут, что сервер упал.
        for id in server.connections {
            connections.removeValue(forKey: id)?.close()
        }
    }

    private func stop(_ server: Server, _ reason: String) {
        Self.log("\(server.name): останавливаю — \(reason)")
        servers[server.key] = nil
        server.client.stop()
    }

    // MARK: - Запросы и уведомления клиентов

    private func handleRequest(_ method: String, id: Int, params: Any?, from connection: Connection) {
        if method == Self.attachMethod {
            attach(params, id: id, from: connection)
            return
        }
        guard let server = server(for: connection) else {
            connection.fail(id, code: -32002, "сначала \(Self.attachMethod)")
            return
        }
        switch method {
        case "initialize":
            if server.initializeResult != nil {
                answerInitialize(id, server: server, connection: connection)
            } else if let error = server.initializeError {
                connection.fail(id, code: -32603, error)
            } else {
                server.initWaiters.append((connection.id, id))
            }
        case "shutdown":
            // Сервер общий: клиент уходит, а сервер остаётся.
            connection.reply(id, NSNull())
        default:
            forward(method, id: id, params: params, to: server, from: connection)
        }
    }

    /// Ответ на initialize — сохранённый от первого клиента, и сразу то, что
    /// новый клиент пропустил: сколько проектов уже загружено и загружены ли все.
    private func answerInitialize(_ id: Int, server: Server, connection: Connection) {
        connection.reply(id, server.initializeResult ?? NSNull())
        connection.initialized = true
        let config = server.client.config
        if let marker = config.projectLoadedMessage {
            for _ in 0..<server.projectMarkers {
                connection.notify("window/logMessage", ["type": 3, "message": marker])
            }
        }
        if server.projectsLoaded, let notification = config.projectsLoadedNotification {
            connection.notify(notification, nil)
        }
    }

    private func forward(_ method: String, id: Int, params: Any?, to server: Server, from connection: Connection) {
        let client = server.client
        let arguments = params as? [String: Any] ?? [:]
        let connectionID = connection.id
        // Таймаут — забота клиента: не дождётся, пришлёт $/cancelRequest.
        let task = Task { [weak self] in
            var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
            do {
                response["result"] = try await client.request(method, arguments, timeout: 600)
            } catch RPCError.serverError(let code, let message) {
                response["error"] = ["code": code, "message": message]
            } catch {
                response["error"] = ["code": -32800, "message": error.localizedDescription]
            }
            self?.queue.async {
                guard let connection = self?.connections[connectionID] else { return }
                connection.inflight[id] = nil
                connection.send(response)
            }
        }
        connection.inflight[id] = task
    }

    private func handleNotification(_ method: String, _ params: Any?, from connection: Connection) {
        if method == Self.quitMethod {
            shutdown("попросили выйти")
            return
        }
        guard let server = server(for: connection) else { return }
        let dict = params as? [String: Any] ?? [:]
        switch method {
        case "initialized", "exit", "solution/open", "project/open":
            // Сервер уже инициализирован и solution открыт — это сделал демон.
            break
        case "$/cancelRequest":
            if let id = dict["id"] as? Int { connection.inflight.removeValue(forKey: id)?.cancel() }
        case "textDocument/didOpen":
            guard let uri = (dict["textDocument"] as? [String: Any])?["uri"] as? String,
                  connection.openDocuments.insert(uri).inserted else { return }
            server.documentRefs[uri, default: 0] += 1
            if server.documentRefs[uri] == 1 { server.client.notify(method, dict) }
        case "textDocument/didClose":
            guard let uri = (dict["textDocument"] as? [String: Any])?["uri"] as? String,
                  connection.openDocuments.remove(uri) != nil else { return }
            release(uri, in: server)
        default:
            server.client.notify(method, dict)
        }
    }

    /// Документ закрывается на сервере, когда его закрыл последний клиент.
    private func release(_ uri: String, in server: Server) {
        let left = (server.documentRefs[uri] ?? 1) - 1
        if left > 0 {
            server.documentRefs[uri] = left
        } else {
            server.documentRefs[uri] = nil
            server.client.notify("textDocument/didClose", ["textDocument": ["uri": uri]])
        }
    }

    private func broadcast(_ method: String, _ params: Any?, from server: Server) {
        for id in server.connections {
            guard let connection = connections[id], connection.initialized else { continue }
            connection.notify(method, params)
        }
    }

    // MARK: - Кого держать

    private func sweep() {
        guard !exiting else { return }
        let now = Date()

        for server in idleServers() {
            if let load = server.loadDuration, load < policy.keepIfLoadTookAtLeast {
                stop(server, String(format: "поднимается за %.1f с, держать незачем", load))
            } else if let since = server.idleSince, now.timeIntervalSince(since) > policy.idleTimeout {
                stop(server, "без клиентов дольше \(Int(policy.idleTimeout / 3600)) ч")
            }
        }

        // Сначала уходят те, кем дольше всех не пользовались.
        var idle = idleServers().sorted { ($0.idleSince ?? now) < ($1.idleSince ?? now) }
        while idle.count > policy.maxIdleServers {
            stop(idle.removeFirst(), "без клиентов держим не больше \(policy.maxIdleServers)")
        }
        var sizes = idle.map { server -> UInt64 in
            server.client.processIdentifier.flatMap(ProcessMemory.footprint) ?? 0
        }
        while sizes.reduce(0, +) > policy.idleMemoryBudget, !idle.isEmpty {
            let gigabytes = Double(sizes.reduce(0, +)) / Double(1 << 30)
            stop(idle.removeFirst(), String(format: "серверы без клиентов занимают %.1f ГБ", gigabytes))
            sizes.removeFirst()
        }

        if servers.isEmpty && connections.isEmpty {
            let since = emptySince ?? now
            emptySince = since
            if now.timeIntervalSince(since) >= policy.exitWhenEmptyAfter { shutdown("держать нечего") }
        } else {
            emptySince = nil
        }
    }

    private func idleServers() -> [Server] {
        servers.values.filter { $0.connections.isEmpty }
    }
}

/// Сколько памяти занимает процесс — та же цифра, что «Память» в Мониторе
/// системы (phys_footprint), а не RSS с разделяемыми страницами.
enum ProcessMemory {
    static func footprint(_ pid: Int32) -> UInt64? {
        #if os(macOS)
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
        #else
        return nil
        #endif
    }
}
