import Foundation

/// Клиент Debug Adapter Protocol поверх stdio. Кадрирование — то же, что
/// у LSP (`Content-Length`), а сообщения свои: request/response/event
/// с `seq`, `command` и `body`.
final class DAPClient: @unchecked Sendable {
    let executable: URL
    let arguments: [String]

    private var process: Process?
    private var output: FileHandle?
    private var framer = MessageFramer()
    private let lock = NSLock()
    private var nextSeq = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var running = false
    private var stderrTail: [String] = []
    private let writeQueue = DispatchQueue(label: "pilot.dap.write")

    /// Событие адаптера: имя и тело.
    var onEvent: (@Sendable (String, [String: Any]) -> Void)?
    /// Адаптер завершился: код и последние строки stderr.
    var onExit: (@Sendable (Int32, String) -> Void)?

    init(executable: URL, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    func start(environment: [String: String] = [:]) throws {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
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
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), let self else { return }
            self.lock.withLock {
                self.stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
                if self.stderrTail.count > 40 { self.stderrTail.removeFirst(self.stderrTail.count - 40) }
            }
        }
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            let (waiting, tail) = self.lock.withLock { () -> ([CheckedContinuation<[String: Any], Error>], String) in
                self.running = false
                let all = Array(self.pending.values)
                self.pending.removeAll()
                return (all, self.stderrTail.suffix(5).joined(separator: "\n"))
            }
            for continuation in waiting { continuation.resume(throwing: DebugError.message("Отладчик завершился")) }
            self.onExit?(p.terminationStatus, tail)
        }
        try proc.run()
        lock.withLock {
            process = proc
            output = inPipe.fileHandleForWriting
            running = true
        }
    }

    var isRunning: Bool { lock.withLock { running } }

    /// Запрос; ответ с `success: false` — ошибка с текстом адаптера.
    @discardableResult
    func request(_ command: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        guard isRunning else { throw DebugError.message("Отладчик не запущен") }
        let seq = lock.withLock { () -> Int in defer { nextSeq += 1 }; return nextSeq }
        let message: [String: Any] = ["seq": seq, "type": "request", "command": command, "arguments": arguments]

        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.fail(seq, DebugError.message("Отладчик не ответил на \(command)"))
        }
        defer { timer.cancel() }

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            lock.withLock { pending[seq] = continuation }
            send(message)
        }
        guard response["success"] as? Bool == true else {
            let text = (response["body"] as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["format"] as? String }
                ?? response["message"] as? String ?? "ошибка"
            throw DebugError.message("\(command): \(text)")
        }
        return response["body"] as? [String: Any] ?? [:]
    }

    private func fail(_ seq: Int, _ error: Error) {
        let continuation = lock.withLock { pending.removeValue(forKey: seq) }
        continuation?.resume(throwing: error)
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSON.encode(message) else { return }
        let framed = MessageFramer.frame(data)
        writeQueue.async { [weak self] in
            guard let handle = self?.lock.withLock({ self?.output }) else { return }
            do { try handle.write(contentsOf: framed) } catch { }
        }
    }

    private func consume(_ data: Data) {
        let bodies = lock.withLock { framer.feed(data) }
        for body in bodies {
            guard let message = JSON.object(from: body) else { continue }
            switch message["type"] as? String {
            case "response":
                guard let seq = message["request_seq"] as? Int else { continue }
                let continuation = lock.withLock { pending.removeValue(forKey: seq) }
                continuation?.resume(returning: message)
            case "event":
                onEvent?(message["event"] as? String ?? "", message["body"] as? [String: Any] ?? [:])
            case "request":
                // Обратные запросы (runInTerminal) не поддерживаем — честно отвечаем.
                let seq = lock.withLock { () -> Int in defer { nextSeq += 1 }; return nextSeq }
                send(["seq": seq, "type": "response", "request_seq": message["seq"] ?? 0,
                      "command": message["command"] ?? "", "success": false, "message": "не поддерживается"])
            default:
                break
            }
        }
    }

    func terminate() {
        let proc = lock.withLock { process }
        guard let proc, proc.isRunning else { return }
        proc.terminate()
    }
}

/// Отладчик .NET: netcoredbg. Запускает программу сам или подключается
/// к работающему процессу.
final class NetcoredbgDebugger: DebugBackend, @unchecked Sendable {
    enum Mode {
        case launch(program: URL, arguments: [String], directory: URL, environment: [String: String])
        case attach(pid: Int32)
    }

    var onEvent: (@Sendable (DebugEvent) -> Void)?

    private let client: DAPClient
    private let mode: Mode
    private let lock = NSLock()
    /// Номер точки у адаптера → файл и строка, которую просили: адаптер
    /// присылает про точку событие, когда она переразрешилась.
    private var breakpointOwners: [Int: (file: URL, line: Int)] = [:]
    private var statuses: [URL: [Int: BreakpointStatus]] = [:]
    private var lastThread = 0
    private var stopping = false

    init(adapter: URL, mode: Mode) {
        self.client = DAPClient(executable: adapter, arguments: ["--interpreter=vscode"])
        self.mode = mode
    }

    /// Где лежит netcoredbg: в бандле, рядом в .build (сборка из исходников),
    /// или установленный самим человеком.
    static func locateAdapter() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("netcoredbg/netcoredbg"))
        }
        // Pilot.app лежит в корне репозитория — .build рядом с ним.
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".build/netcoredbg/netcoredbg"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".local/bin/netcoredbg"))
        candidates += ["/opt/homebrew/bin/netcoredbg", "/usr/local/bin/netcoredbg"].map(URL.init(fileURLWithPath:))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `dotnet` — у приложения из Finder PATH урезан, поэтому смотрим
    /// и в стандартные места установки.
    static func locateDotnet() -> URL? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/usr/local/share/dotnet", "/opt/homebrew/bin", "/usr/local/bin",
                 FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dotnet").path]
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent("dotnet")
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath()
            }
        }
        return nil
    }

    private func emit(_ event: DebugEvent) { onEvent?(event) }

    // MARK: Запуск

    func start(breakpoints: [URL: [Int]]) async throws {
        client.onEvent = { [weak self] name, body in self?.handle(event: name, body) }
        client.onExit = { [weak self] status, tail in
            guard let self, !self.lock.withLock({ self.stopping }) else { return }
            self.emit(.terminated(status == 0 ? nil : "netcoredbg завершился (\(status)): \(tail)"))
        }
        let initialized = AsyncStream<Void>.makeStream()
        initializedSignal = initialized.continuation
        try client.start()

        _ = try await client.request("initialize", [
            "clientID": "pilot", "clientName": "Pilot", "adapterID": "coreclr",
            "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
            "supportsVariableType": true, "supportsRunInTerminalRequest": false,
        ])

        // Ответ на launch у адаптеров приходит и до, и после configurationDone —
        // поэтому ждём его параллельно, а конфигурацию шлём по «initialized».
        let begin: Task<[String: Any], Error>
        switch mode {
        case .launch(let program, let arguments, let directory, let environment):
            begin = Task { [client] in
                try await client.request("launch", [
                    "program": program.path, "args": arguments, "cwd": directory.path,
                    "env": environment, "stopAtEntry": false, "justMyCode": true,
                ], timeout: 60)
            }
        case .attach(let pid):
            begin = Task { [client] in
                try await client.request("attach", ["processId": Int(pid), "justMyCode": true], timeout: 60)
            }
        }

        let waited = Task {
            for await _ in initialized.stream { return true }
            return false
        }
        let timeout = Task { try await Task.sleep(nanoseconds: 30_000_000_000); waited.cancel() }
        let gotInitialized = await waited.value
        timeout.cancel()
        guard gotInitialized else {
            _ = try await begin.value            // пусть ошибка запуска скажет, что не так
            throw DebugError.message("netcoredbg не дождался инициализации")
        }

        for (file, lines) in breakpoints where !lines.isEmpty {
            let result = await setBreakpoints(file: file, lines: lines)
            emit(.breakpoints(file: file, result))
        }
        _ = try? await client.request("setExceptionBreakpoints", ["filters": []])
        _ = try await client.request("configurationDone")
        _ = try await begin.value
    }

    private var initializedSignal: AsyncStream<Void>.Continuation?

    // MARK: События

    private func handle(event name: String, _ body: [String: Any]) {
        switch name {
        case "initialized":
            initializedSignal?.yield()
            initializedSignal?.finish()
        case "stopped":
            let thread = body["threadId"] as? Int ?? 0
            lock.withLock { lastThread = thread }
            let reason = body["reason"] as? String ?? "pause"
            let text = body["text"] as? String ?? body["description"] as? String
            emit(.stopped(thread: thread, reason: reason, text: reason == "exception" ? text : nil))
        case "continued":
            emit(.resumed)
        case "output":
            let category = body["category"] as? String ?? "console"
            if let text = body["output"] as? String, category != "telemetry" {
                emit(.output(text, category: category))
            }
        case "breakpoint":
            guard let bp = body["breakpoint"] as? [String: Any], let id = bp["id"] as? Int else { return }
            let update = lock.withLock { () -> (URL, [BreakpointStatus])? in
                guard let owner = breakpointOwners[id] else { return nil }
                statuses[owner.file, default: [:]][owner.line] = Self.status(bp, requested: owner.line)
                return (owner.file, statuses[owner.file]!.values.sorted { $0.line < $1.line })
            }
            if let (file, list) = update { emit(.breakpoints(file: file, list)) }
        case "exited":
            let code = body["exitCode"] as? Int ?? 0
            emit(.output("Программа завершилась с кодом \(code)\n", category: "console"))
        case "terminated":
            emit(.terminated(nil))
        default:
            break
        }
    }

    private static func status(_ bp: [String: Any], requested line: Int) -> BreakpointStatus {
        let verified = bp["verified"] as? Bool ?? false
        let actual = (bp["line"] as? Int).map { $0 - 1 }
        return BreakpointStatus(line: line, verified: verified, actualLine: verified ? actual : nil,
                                message: bp["message"] as? String)
    }

    // MARK: Точки останова

    func setBreakpoints(file: URL, lines: [Int]) async -> [BreakpointStatus] {
        let sorted = Array(Set(lines)).sorted()
        do {
            let body = try await client.request("setBreakpoints", [
                "source": ["path": file.path, "name": file.lastPathComponent],
                "breakpoints": sorted.map { ["line": $0 + 1] },
                "lines": sorted.map { $0 + 1 },
            ])
            let list = body["breakpoints"] as? [[String: Any]] ?? []
            var result: [BreakpointStatus] = []
            lock.withLock {
                breakpointOwners = breakpointOwners.filter { $0.value.file != file }
                statuses[file] = [:]
                for (line, bp) in zip(sorted, list) {
                    if let id = bp["id"] as? Int { breakpointOwners[id] = (file, line) }
                    let status = Self.status(bp, requested: line)
                    statuses[file]?[line] = status
                    result.append(status)
                }
            }
            return result
        } catch {
            return sorted.map { BreakpointStatus(line: $0, verified: false, message: error.localizedDescription) }
        }
    }

    // MARK: Потоки, стек, переменные

    func threads() async throws -> [DebugThread] {
        let body = try await client.request("threads")
        return (body["threads"] as? [[String: Any]] ?? []).compactMap { t in
            guard let id = t["id"] as? Int else { return nil }
            return DebugThread(id: id, name: t["name"] as? String ?? "Поток \(id)")
        }
    }

    func stackTrace(thread: Int) async throws -> [DebugFrame] {
        let body = try await client.request("stackTrace", ["threadId": thread, "startFrame": 0, "levels": 200])
        return (body["stackFrames"] as? [[String: Any]] ?? []).compactMap { f in
            guard let id = f["id"] as? Int else { return nil }
            let path = (f["source"] as? [String: Any])?["path"] as? String
            let file = path.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
            let line = (f["line"] as? Int).flatMap { $0 > 0 && file != nil ? $0 - 1 : nil }
            return DebugFrame(id: id, name: f["name"] as? String ?? "?", file: file, line: line,
                              column: max(0, (f["column"] as? Int ?? 1) - 1))
        }
    }

    func variables(frame: Int, thread: Int) async throws -> [DebugVariable] {
        let body = try await client.request("scopes", ["frameId": frame])
        let scopes = body["scopes"] as? [[String: Any]] ?? []
        // Одна область — сразу её переменные, без лишнего уровня.
        if scopes.count == 1, let reference = scopes[0]["variablesReference"] as? Int {
            return try await children(of: reference, parent: "")
        }
        return scopes.map { scope in
            let name = scope["name"] as? String ?? "?"
            return DebugVariable(id: name, name: name, value: "", children: scope["variablesReference"] as? Int ?? 0)
        }
    }

    func children(of reference: Int, parent: String) async throws -> [DebugVariable] {
        let body = try await client.request("variables", ["variablesReference": reference])
        return (body["variables"] as? [[String: Any]] ?? []).map { v in
            let name = v["name"] as? String ?? "?"
            return DebugVariable(id: parent.isEmpty ? name : parent + "." + name, name: name,
                                 value: v["value"] as? String ?? "", type: v["type"] as? String ?? "",
                                 children: v["variablesReference"] as? Int ?? 0)
        }
    }

    // MARK: Управление

    func resume() async throws {
        let thread = lock.withLock { lastThread }
        _ = try await client.request("continue", ["threadId": thread])
        emit(.resumed)
    }

    func pause() async throws {
        var thread = lock.withLock { lastThread }
        if thread == 0 { thread = try await threads().first?.id ?? 0 }
        _ = try await client.request("pause", ["threadId": thread])
    }

    func step(_ kind: StepKind, thread: Int) async throws {
        let command = switch kind {
        case .over: "next"
        case .into: "stepIn"
        case .out: "stepOut"
        }
        _ = try await client.request(command, ["threadId": thread])
        emit(.resumed)
    }

    func stop(terminate: Bool) async {
        lock.withLock { stopping = true }
        if client.isRunning {
            _ = try? await client.request("disconnect", ["terminateDebuggee": terminate], timeout: 5)
        }
        client.terminate()
    }
}
