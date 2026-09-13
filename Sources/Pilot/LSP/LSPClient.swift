import Foundation

enum LSPState: Equatable {
    case stopped
    case starting(String)      // текст для статус-строки
    case ready
    case failed(String)
}

/// Клиент одного языкового сервера: процесс, кадрирование, сопоставление
/// запросов и ответов.
///
/// Весь класс построен вокруг одного требования: **ни один вызов не должен
/// блокировать интерфейс**. Всё асинхронно, у всего есть таймаут, а падение
/// сервера переводит клиент в .failed, но никак не задевает просмотр файлов.
final class LSPClient: @unchecked Sendable {

    let config: ServerConfig
    let root: URL

    private var process: Process?
    /// Сокет демона, если сервер не свой, а общий (см. LSPDaemon).
    private var daemonSocket: FileHandle?
    /// Куда писать: stdin своего процесса или сокет демона.
    private var output: FileHandle?
    private var framer = MessageFramer()

    private let lock = NSLock()
    private var connected = false
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var openDocuments: Set<String> = []
    /// Версия каждого открытого документа: растёт с каждой правкой.
    private var versions: [String: Int] = [:]
    private var stderrTail: [String] = []

    private let writeQueue = DispatchQueue(label: "pilot.lsp.write")

    // NSLock нельзя держать через await: между lock и unlock задача может
    // переехать на другой поток. Поэтому любой доступ к общему состоянию
    // завёрнут в синхронный метод.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func allocateRequestID() -> Int {
        withLock { let id = nextID; nextID += 1; return id }
    }

    private func storePending(_ id: Int, _ continuation: CheckedContinuation<Any, Error>) {
        withLock { pending[id] = continuation }
    }

    /// Снимает запрос с ошибкой. Продолжение забирается из `pending` под
    /// замком, поэтому ответ, таймаут и отмена не могут возобновить его дважды:
    /// кто первый забрал, тот и закрыл. false — запрос уже закрыт.
    @discardableResult
    private func failPending(_ id: Int, _ error: Error) -> Bool {
        guard let continuation = withLock({ pending.removeValue(forKey: id) }) else { return false }
        continuation.resume(throwing: error)
        return true
    }

    private func failAllPending(_ error: Error) {
        let waiting = withLock { () -> [Int: CheckedContinuation<Any, Error>] in
            let all = pending
            pending.removeAll()
            return all
        }
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }

    var isConnected: Bool { withLock { connected } }
    private func setConnected(_ value: Bool) { withLock { connected = value } }

    /// Сообщения о прогрессе от сервера ($/progress, window/logMessage).
    var onStatus: (@Sendable (String) -> Void)?
    /// Сервер умер сам по себе.
    var onExit: (@Sendable (String) -> Void)?
    /// Загружен ещё один проект — для счётчика в статус-строке.
    var onProjectLoaded: (@Sendable () -> Void)?
    /// Загружены все проекты: с этого момента у сервера есть семантика.
    var onProjectsLoaded: (@Sendable () -> Void)?
    /// Любое уведомление от сервера, как есть. Нужно демону: он пересылает
    /// уведомления подключённым к нему Pilot.
    var onNotification: (@Sendable (String, Any?) -> Void)?

    /// PID процесса сервера — чтобы следить за его памятью.
    var processIdentifier: Int32? { process?.processIdentifier }

    private(set) var capabilities = ServerCapabilities()
    /// Ответ на initialize как есть — демон отдаёт его следующим клиентам.
    private(set) var initializeResult: Any?
    /// Сколько проектов сервер начал грузить после initialize. nil — ждать
    /// нечего, сервер готов сразу; 0 — ждать надо, но сколько, неизвестно.
    private(set) var projectsToLoad: Int?

    init(config: ServerConfig, root: URL) {
        self.config = config
        self.root = root
    }

    // MARK: - Жизненный цикл

    func start() throws {
        guard let executable = config.resolvedExecutable() else {
            throw RPCError.malformed("не найден исполняемый файл \(config.command[0])")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = Array(config.command.dropFirst())
        proc.currentDirectoryURL = root

        var env = ProcessInfo.processInfo.environment
        env.merge(config.environment) { _, new in new }
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.recordStderr(text)
        }
        proc.terminationHandler = { [weak self] p in
            self?.handleTermination(status: p.terminationStatus)
        }

        try proc.run()
        self.process = proc
        self.output = inPipe.fileHandleForWriting
        setConnected(true)
    }

    /// Вместо своего процесса — уже открытый сокет демона. Дальше по нему
    /// идёт обычный LSP, только первым запросом — `attach`.
    func connect(daemonSocket fd: Int32) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil        // EOF: демон закрыл соединение
                self?.handleDisconnect()
                return
            }
            self?.consume(data)
        }
        daemonSocket = handle
        output = handle
        setConnected(true)
    }

    /// Просит демона подключить нас к серверу для этого проекта — уже
    /// работающему или новому. true — сервер уже был запущен.
    func attach(build: String) async throws -> Bool {
        let result = try await request(LSPDaemon.attachMethod,
                                       ["build": build, "root": root.path, "config": config.json],
                                       timeout: 15)
        return (result as? [String: Any])?["reused"] as? Bool ?? false
    }

    func stop() {
        if let daemonSocket {
            // Сервер принадлежит демону: просто отключаемся, а жить ли
            // серверу дальше, демон решает сам.
            setConnected(false)
            daemonSocket.readabilityHandler = nil
            try? daemonSocket.close()
            self.daemonSocket = nil
            output = nil
            framer = MessageFramer()
            failAllPending(RPCError.cancelled)
            return
        }
        // Корректное завершение: shutdown -> exit. Если сервер не отвечает,
        // всё равно убиваем процесс — висящий Roslyn ест гигабайт памяти.
        notify("exit", [:])
        writeQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.process?.terminate()
        }
        failAllPending(RPCError.cancelled)
    }

    private func handleTermination(status: Int32) {
        setConnected(false)
        let tail = withLock { stderrTail.suffix(5).joined(separator: "\n") }
        failAllPending(RPCError.notRunning)
        if status != 0 {
            onExit?(tail.isEmpty ? "сервер завершился с кодом \(status)" : tail)
        }
    }

    private func handleDisconnect() {
        guard isConnected else { return }                 // сами и отключились
        setConnected(false)
        failAllPending(RPCError.notRunning)
        onExit?("демон языковых серверов закрыл соединение")
    }

    private func recordStderr(_ text: String) {
        lock.lock()
        stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
        if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
        lock.unlock()
    }

    // MARK: - Инициализация

    func initialize() async throws {
        var params: [String: Any] = [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "clientInfo": ["name": "Pilot", "version": "0.2.0"],
            "rootUri": root.absoluteString,
            "rootPath": root.path,
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
            "capabilities": [
                // Явно фиксируем UTF-16: в этой системе координат уже
                // работает SyntaxModel, поэтому пересчёт смещений не нужен.
                "general": ["positionEncodings": ["utf-16"]],
                "textDocument": [
                    "synchronization": ["dynamicRegistration": false, "didSave": true],
                    // Сниппеты раскрываем сами (Snippet.expand): так сервер
                    // присылает заглушки параметров, а не голое имя метода.
                    "completion": [
                        "dynamicRegistration": false,
                        "contextSupport": true,
                        "completionItem": [
                            "snippetSupport": true,
                            "insertReplaceSupport": true,
                            "labelDetailsSupport": true,
                            "documentationFormat": ["plaintext"],
                        ],
                        "completionList": ["itemDefaults": ["editRange", "insertTextFormat", "data"]],
                    ],
                    "definition": ["linkSupport": true],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "references": ["dynamicRegistration": false],
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": false],
                ],
                "workspace": [
                    "workspaceFolders": true,
                    "configuration": true,
                    "symbol": ["dynamicRegistration": false],
                ],
                "window": ["workDoneProgress": true],
            ],
        ]
        if let options = config.initializationOptions {
            params["initializationOptions"] = options
        }

        let result = try await request("initialize", params, timeout: 120)
        initializeResult = result
        capabilities = ServerCapabilities.parse(result)
        notify("initialized", [:])

        // Roslyn без этого молча не отдаёт ни одного символа:
        // rootUri ему недостаточно, нужен явный solution/open.
        if config.opensSolution, let solution = ServerRegistry.findSolution(root: root) {
            if config.projectsLoadedNotification != nil {
                projectsToLoad = ServerRegistry.projectCount(solution: solution) ?? 0
            }
            if solution.pathExtension == "csproj" {
                notify("project/open", ["projects": [solution.absoluteString]])
            } else {
                notify("solution/open", ["solution": solution.absoluteString])
            }
        }
    }

    /// Первые два `workspace/symbol` на большом solution дорогие: Roslyn строит
    /// индекс в две стадии, и каждую запускает очередной запрос (на Unity-проекте
    /// из 134 csproj — 35 с и 22 с), а дальше запросы идут доли секунды.
    /// Прогреваем обе запросами, которые ни с чем не совпадают: нужен сам
    /// индекс, а не результаты.
    func warmUpSymbolIndex() async {
        guard capabilities.workspaceSymbol else { return }
        for query in ["PilotWarmUpFirstPass", "PilotWarmUpSecondPass"] {
            guard (try? await request("workspace/symbol", ["query": query], timeout: 300)) != nil else { return }
        }
    }

    // MARK: - Синхронизация документов

    func didOpen(url: URL, languageId: String, text: String) {
        let uri = url.absoluteString
        lock.lock()
        let alreadyOpen = openDocuments.contains(uri)
        if !alreadyOpen { openDocuments.insert(uri); versions[uri] = 1 }
        lock.unlock()
        guard !alreadyOpen else { return }

        notify("textDocument/didOpen", [
            "textDocument": [
                "uri": uri,
                "languageId": languageId,
                "version": 1,
                "text": text,
            ]
        ])
    }

    /// Правки документа. Без `range` — полный текст (TextDocumentSyncKind.Full).
    /// Документ, которого сервер ещё не видел, пропускаем: при открытии он
    /// всё равно получит текст целиком.
    func didChange(url: URL, changes: [[String: Any]]) {
        let uri = url.absoluteString
        lock.lock()
        let isOpen = openDocuments.contains(uri)
        let version = (versions[uri] ?? 1) + 1
        if isOpen { versions[uri] = version }
        lock.unlock()
        guard isOpen else { return }
        notify("textDocument/didChange", [
            "textDocument": ["uri": uri, "version": version],
            "contentChanges": changes,
        ])
    }

    func isOpen(_ url: URL) -> Bool {
        withLock { openDocuments.contains(url.absoluteString) }
    }

    func didSave(url: URL) {
        guard isOpen(url) else { return }
        notify("textDocument/didSave", ["textDocument": ["uri": url.absoluteString]])
    }

    func didClose(url: URL) {
        let uri = url.absoluteString
        lock.lock()
        let wasOpen = openDocuments.remove(uri) != nil
        versions[uri] = nil
        lock.unlock()
        guard wasOpen else { return }
        notify("textDocument/didClose", ["textDocument": ["uri": uri]])
    }

    // MARK: - Запросы

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 8) async throws -> Any {
        guard isConnected else { throw RPCError.notRunning }

        let id = allocateRequestID()
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]

        // Таймаут и отмена обязаны именно возобновить продолжение с ошибкой.
        // Просто выкинуть его из `pending` нельзя: тот, кто ждёт ответа,
        // так и остался бы висеть навсегда.
        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // Ждать мы перестали — пусть и сервер бросит работу.
            if self?.failPending(id, RPCError.timeout(method: method)) == true {
                self?.notify("$/cancelRequest", ["id": id])
            }
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: RPCError.cancelled)
                    return
                }
                self.storePending(id, continuation)
                self.send(body)
            }
        } onCancel: {
            // Ответ больше никому не нужен — пусть и сервер бросит работу.
            self.failPending(id, RPCError.cancelled)
            self.notify("$/cancelRequest", ["id": id])
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ body: [String: Any]) {
        guard let data = try? JSON.encode(body) else { return }
        let framed = MessageFramer.frame(data)
        writeQueue.async { [weak self] in
            guard let handle = self?.output else { return }
            // Сервер мог умереть между проверкой и записью — write бросит
            // SIGPIPE-исключение, которое здесь не должно ронять приложение.
            do { try handle.write(contentsOf: framed) } catch { }
        }
    }

    // MARK: - Приём

    private func consume(_ data: Data) {
        let messages = framer.feed(data)
        for body in messages {
            guard let message = JSON.object(from: body) else { continue }
            route(message)
        }
    }

    private func route(_ message: [String: Any]) {
        let id = message["id"] as? Int
        let method = message["method"] as? String

        // Запрос ОТ сервера. На него обязательно нужно ответить:
        // Roslyn ждёт ответа на workspace/configuration и без него
        // не завершает инициализацию.
        if let id, let method {
            respondToServerRequest(id: id, method: method, params: message["params"])
            return
        }
        // Уведомление от сервера.
        if let method {
            handleNotification(method, message["params"])
            onNotification?(method, message["params"])
            return
        }
        // Ответ на наш запрос.
        guard let id else { return }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }

        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: RPCError.serverError(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "неизвестная ошибка"))
        } else {
            continuation.resume(returning: message["result"] ?? NSNull())
        }
    }

    private func respondToServerRequest(id: Int, method: String, params: Any?) {
        let result: Any
        switch method {
        case "workspace/configuration":
            result = config.configurationResponse(params)
        case "client/registerCapability", "client/unregisterCapability",
             "window/workDoneProgress/create":
            result = NSNull()
        case "workspace/workspaceFolders":
            result = [["uri": root.absoluteString, "name": root.lastPathComponent]]
        default:
            result = NSNull()
        }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func handleNotification(_ method: String, _ params: Any?) {
        if method == config.projectsLoadedNotification {
            onProjectsLoaded?()
            return
        }
        switch method {
        case "$/progress":
            // Именно отсюда Roslyn сообщает «загружаю solution» —
            // единственный честный источник прогресса для статус-строки.
            guard let dict = params as? [String: Any],
                  let value = dict["value"] as? [String: Any] else { return }
            let title = value["title"] as? String
            let message = value["message"] as? String
            if let text = message ?? title, !text.isEmpty { onStatus?(text) }

        case "window/logMessage", "window/showMessage":
            guard let dict = params as? [String: Any],
                  let type = dict["type"] as? Int,
                  let text = dict["message"] as? String else { return }
            if type <= 2 {                                        // Error/Warning
                recordStderr(text)
            } else if let marker = config.projectLoadedMessage, text.contains(marker) {
                onProjectLoaded?()
            }

        default:
            break
        }
    }
}
