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
    private var stdin: FileHandle?
    private var framer = MessageFramer()

    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var openDocuments: Set<String> = []
    private var stderrTail: [String] = []

    private let writeQueue = DispatchQueue(label: "flint.lsp.write")

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

    private func discardPending(_ id: Int) {
        withLock { pending[id] = nil }
    }

    /// Сообщения о прогрессе от сервера ($/progress, window/logMessage).
    var onStatus: (@Sendable (String) -> Void)?
    /// Сервер умер сам по себе.
    var onExit: (@Sendable (String) -> Void)?

    private(set) var capabilities = ServerCapabilities()

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
        self.stdin = inPipe.fileHandleForWriting
    }

    func stop() {
        // Корректное завершение: shutdown -> exit. Если сервер не отвечает,
        // всё равно убиваем процесс — висящий Roslyn ест гигабайт памяти.
        notify("exit", [:])
        writeQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.process?.terminate()
        }
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for (_, continuation) in waiting { continuation.resume(throwing: RPCError.cancelled) }
    }

    private func handleTermination(status: Int32) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        let tail = stderrTail.suffix(5).joined(separator: "\n")
        lock.unlock()

        for (_, continuation) in waiting { continuation.resume(throwing: RPCError.notRunning) }
        if status != 0 {
            onExit?(tail.isEmpty ? "сервер завершился с кодом \(status)" : tail)
        }
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
            "clientInfo": ["name": "Flint", "version": "0.2.0"],
            "rootUri": root.absoluteString,
            "rootPath": root.path,
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
            "capabilities": [
                // Явно фиксируем UTF-16: в этой системе координат уже
                // работает SyntaxModel, поэтому пересчёт смещений не нужен.
                "general": ["positionEncodings": ["utf-16"]],
                "textDocument": [
                    "synchronization": ["dynamicRegistration": false, "didSave": false],
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
        capabilities = ServerCapabilities.parse(result)
        notify("initialized", [:])

        // Roslyn без этого молча не отдаёт ни одного символа:
        // rootUri ему недостаточно, нужен явный solution/open.
        if config.opensSolution, let solution = ServerRegistry.findSolution(root: root) {
            if solution.pathExtension == "csproj" {
                notify("project/open", ["projects": [solution.absoluteString]])
            } else {
                notify("solution/open", ["solution": solution.absoluteString])
            }
        }
    }

    // MARK: - Синхронизация документов

    func didOpen(url: URL, languageId: String, text: String) {
        let uri = url.absoluteString
        lock.lock()
        let alreadyOpen = openDocuments.contains(uri)
        if !alreadyOpen { openDocuments.insert(uri) }
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

    func didClose(url: URL) {
        let uri = url.absoluteString
        lock.lock()
        let wasOpen = openDocuments.remove(uri) != nil
        lock.unlock()
        guard wasOpen else { return }
        notify("textDocument/didClose", ["textDocument": ["uri": uri]])
    }

    // MARK: - Запросы

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 8) async throws -> Any {
        guard process?.isRunning == true else { throw RPCError.notRunning }

        let id = allocateRequestID()
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]

        return try await withThrowingTaskGroup(of: Any.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.storePending(id, continuation)
                    self.send(body)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RPCError.timeout(method: method)
            }
            defer {
                group.cancelAll()
                // Снимаем «повисший» запрос, если победил таймаут.
                self.discardPending(id)
            }
            guard let first = try await group.next() else { throw RPCError.cancelled }
            return first
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ body: [String: Any]) {
        guard let data = try? JSON.encode(body) else { return }
        let framed = MessageFramer.frame(data)
        writeQueue.async { [weak self] in
            guard let handle = self?.stdin else { return }
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
            respondToServerRequest(id: id, method: method)
            return
        }
        // Уведомление от сервера.
        if let method {
            handleNotification(method, message["params"])
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

    private func respondToServerRequest(id: Int, method: String) {
        let result: Any
        switch method {
        case "workspace/configuration":
            result = [NSNull()]           // настроек не даём, но отвечаем
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
                  let type = dict["type"] as? Int, type <= 2,     // Error/Warning
                  let text = dict["message"] as? String else { return }
            recordStderr(text)

        default:
            break
        }
    }
}
