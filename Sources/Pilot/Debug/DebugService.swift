import SwiftUI
import AppKit
import Combine

/// Сессия отладки проекта: точки останова, цели, остановка, стек и
/// переменные. Одна на окно; бэкенд — Mono (Unity) или netcoredbg (.NET).
@MainActor
final class DebugService: ObservableObject {
    enum State: Equatable {
        case idle
        case starting(String)
        case running
        case paused
    }

    @Published private(set) var state: State = .idle
    /// С чем сессия: «Редактор Unity», «Server».
    @Published private(set) var sessionTitle: String?
    @Published private(set) var lastError: String?

    @Published private(set) var breakpoints = BreakpointSet()
    /// Что сказал отладчик про каждую точку: встала ли и куда.
    @Published private(set) var statuses: [URL: [Int: BreakpointStatus]] = [:]

    @Published private(set) var threads: [DebugThread] = []
    @Published private(set) var thread: Int?
    @Published private(set) var frames: [DebugFrame] = []
    @Published private(set) var frameIndex: Int?
    @Published private(set) var stopReason: String?
    @Published private(set) var variables: [DebugVariable] = []
    /// Дети раскрытых узлов, по пути узла.
    @Published private(set) var children: [String: [DebugVariable]] = [:]
    /// Раскрытые узлы переживают шаг: после него дерево раскрыто там же.
    @Published private(set) var expanded: Set<String> = []

    @Published private(set) var targets: [DebugTarget] = []
    @Published private(set) var isDiscovering = false
    @Published var isTargetPickerOpen = false
    /// Панель внизу: открывается с сессией и остаётся после неё — чтобы
    /// было видно, чем кончилось (ошибки сборки, код выхода).
    @Published var isPanelVisible = false
    @Published private(set) var lastTarget: DebugTarget?

    /// Вывод программы и отладчика. Отдельный объект: сервер пишет в лог
    /// сотни строк в секунду, и перерисовывать из-за них всё окно незачем.
    let console = DebugConsole()

    /// Показать место в редакторе: файл и строку с нуля.
    var onShowLocation: ((URL, Int) -> Void)?

    private var root: URL?
    private var backend: DebugBackend?
    private var eventTask: Task<Void, Never>?
    private var variablesTask: Task<Void, Never>?
    private var buildProcess: Process?
    private var generation = 0

    var isActive: Bool { state != .idle }
    var isPaused: Bool { state == .paused }

    /// Где стоит выбранный кадр — туда рисуется стрелка выполнения.
    var executionLocation: (url: URL, line: Int)? {
        guard state == .paused, let frameIndex, frameIndex < frames.count,
              let file = frames[frameIndex].file, let line = frames[frameIndex].line else { return nil }
        return (file.standardizedFileURL, line)
    }

    // MARK: Проект

    func workspaceChanged(to root: URL?) {
        if isActive { stop() }
        self.root = root
        breakpoints = root.map { BreakpointSet.load(root: $0) } ?? BreakpointSet()
        statuses = [:]
        targets = []
        lastTarget = nil
        console.clear()
    }

    private func persist() {
        guard let root else { return }
        breakpoints.save(root: root)
    }

    // MARK: Точки останова

    /// Отладчики понимают только C#: в других файлах клик по номеру
    /// строки остаётся тем, чем был.
    static func canBreak(in url: URL) -> Bool {
        ["cs", "csx"].contains(url.pathExtension.lowercased())
    }

    func toggleBreakpoint(_ file: URL, line: Int) {
        guard Self.canBreak(in: file) else { return }
        breakpoints.toggle(file, line: line)
        persist()
        syncBreakpoints(file)
    }

    func removeAllBreakpoints() {
        let files = Array(breakpoints.lines.keys)
        breakpoints.removeAll()
        persist()
        for file in files { syncBreakpoints(file) }
    }

    /// Пометки для гаттера открытого файла.
    func marks(for file: URL) -> [Int: BreakpointMark] {
        let key = file.standardizedFileURL
        let lines = breakpoints.lines(in: key)
        guard !lines.isEmpty else { return [:] }
        let known = statuses[key] ?? [:]
        var result: [Int: BreakpointMark] = [:]
        for line in lines {
            let status = known[line]
            // Пока сессии нет, точка просто стоит; в сессии — как решил отладчик.
            result[line] = BreakpointMark(verified: !isActive || status?.verified == true,
                                          message: isActive ? status?.message : nil)
        }
        return result
    }

    /// Правка в файле: точки едут вместе со строками. Отладчику новые
    /// строки уйдут, когда файл сохранят — код он видит скомпилированный.
    func textEdited(_ file: URL, start: (line: Int, character: Int), endLine: Int, text: String) {
        let key = file.standardizedFileURL
        let lines = breakpoints.lines(in: key)
        guard !lines.isEmpty else { return }
        let inserted = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let shifted = BreakpointSet.shift(lines, start: start, endLine: endLine, inserted: inserted)
        guard shifted != lines else { return }
        breakpoints.set(key, shifted)
        persist()
    }

    func fileSaved(_ file: URL) {
        let key = file.standardizedFileURL
        guard isActive, breakpoints.lines(in: key) != Set((statuses[key] ?? [:]).keys) else { return }
        syncBreakpoints(key)
    }

    private func syncBreakpoints(_ file: URL) {
        guard let backend, isActive else { return }
        let key = file.standardizedFileURL
        let lines = Array(breakpoints.lines(in: key))
        Task { [weak self] in
            let result = await backend.setBreakpoints(file: key, lines: lines)
            self?.applyStatuses(key, result)
        }
    }

    private func applyStatuses(_ file: URL, _ list: [BreakpointStatus]) {
        let key = file.standardizedFileURL
        statuses[key] = Dictionary(list.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
        // Пустая строка: отладчик перенёс точку на следующую с кодом — так
        // и рисуем, чтобы не было двух разных «правд».
        var lines = breakpoints.lines(in: key)
        var moved = false
        for status in list {
            if let actual = status.actualLine, actual != status.line, lines.contains(status.line) {
                lines.remove(status.line)
                lines.insert(actual)
                statuses[key]?[status.line] = nil
                var fixed = status
                fixed.line = actual
                statuses[key]?[actual] = fixed
                moved = true
            }
        }
        if moved {
            breakpoints.set(key, lines)
            persist()
        }
    }

    // MARK: Цели

    func openTargetPicker() {
        guard root != nil else { return }
        isTargetPickerOpen = true
        discoverTargets()
    }

    func discoverTargets() {
        guard let root, !isDiscovering else { return }
        isDiscovering = true
        let isUnity = FileManager.default.fileExists(atPath: root.appendingPathComponent("ProjectSettings/ProjectVersion.txt").path)
        Task { [weak self] in
            let local = await Task.detached { () -> [DebugTarget] in
                let processes = DebugTargets.processes()
                if isUnity { return DebugTargets.unityEditors(root: root, in: processes) }
                return DebugTargets.dotnetProjects(root: root).map { DebugTarget.dotnetLaunch(project: $0) }
                    + DebugTargets.dotnetProcesses(root: root, in: processes)
            }.value
            guard let self, self.root == root else { return }
            self.targets = local
            guard isUnity else {
                self.isDiscovering = false
                return
            }
            // Сборки объявляют о себе раз в секунду — дослушиваем после
            // того, как редактор уже в списке.
            let players = await DebugTargets.unityPlayers()
            guard self.root == root else { return }
            self.targets = local + players
            self.isDiscovering = false
        }
    }

    var isUnityProject: Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("ProjectSettings/ProjectVersion.txt").path)
    }

    // MARK: Сессия

    func start(_ target: DebugTarget) {
        guard let root else { return }
        if isActive { stop() }
        isTargetPickerOpen = false
        generation += 1
        let session = generation
        lastTarget = target
        lastError = nil
        sessionTitle = target.title
        console.clear()
        clearStop()
        isPanelVisible = true
        state = .starting(target.isUnity ? "Подключаюсь…" : "Запускаю…")

        Task { [weak self] in
            guard let self else { return }
            do {
                let backend = try await self.makeBackend(for: target, root: root, session: session)
                guard self.generation == session else {
                    await backend.stop(terminate: true)
                    return
                }
                self.attach(backend, session: session)
                var initial: [URL: [Int]] = [:]
                for (file, lines) in self.breakpoints.lines { initial[file] = Array(lines) }
                self.state = .starting(target.isUnity ? "Подключаюсь…" : "Запускаю под отладчиком…")
                try await backend.start(breakpoints: initial)
                guard self.generation == session else { return }
                if self.state != .paused { self.state = .running }
            } catch {
                guard self.generation == session else { return }
                self.fail(Self.explain(error, target: target))
            }
        }
    }

    /// Ошибку подключения — в то, что с ней делать.
    private static func explain(_ error: Error, target: DebugTarget) -> String {
        let text = error.localizedDescription
        switch target {
        case .unityEditor:
            if text.contains("не отвечает") || text.contains("не ответил") {
                return "Редактор Unity не принимает отладчик. Включи Debug Mode (жук в правом нижнем углу редактора) и проверь Preferences → External Tools → Editor Attaching."
            }
        case .unityPlayer, .unityRemote:
            if text.contains("не отвечает") || text.contains("не ответил") {
                return "Сборка не принимает отладчик: нужна Development Build с включённым Script Debugging."
            }
        default:
            break
        }
        return text
    }

    private func makeBackend(for target: DebugTarget, root: URL, session: Int) async throws -> DebugBackend {
        switch target {
        case .unityEditor(_, let port):
            return MonoDebugger(port: port, root: root)
        case .unityPlayer(_, let host, let port), .unityRemote(let host, let port):
            return MonoDebugger(host: host, port: port, root: root)
        case .dotnetAttach(let pid, _):
            guard let adapter = NetcoredbgDebugger.locateAdapter() else { throw Self.noAdapter }
            return NetcoredbgDebugger(adapter: adapter, mode: .attach(pid: pid))
        case .dotnetLaunch(let project):
            guard let adapter = NetcoredbgDebugger.locateAdapter() else { throw Self.noAdapter }
            guard let dotnet = NetcoredbgDebugger.locateDotnet() else {
                throw DebugError.message("Не найден dotnet — установи .NET SDK")
            }
            state = .starting("Собираю \(project.deletingPathExtension().lastPathComponent)…")
            let dll = try await build(project, dotnet: dotnet, session: session)
            // Программа под net8, а стоит только рантайм поновее — пусть
            // едет на нём: так же поступает Rider с «Use latest runtime».
            let environment = ["DOTNET_ROLL_FORWARD": "Major"]
            return NetcoredbgDebugger(adapter: adapter, mode: .launch(program: dotnet, arguments: [dll.path],
                                                                      directory: root, environment: environment))
        }
    }

    private static let noAdapter = DebugError.message(
        "Нет netcoredbg — отладчика .NET. Его ставит ./build.sh (fetch-netcoredbg.sh).")

    /// `dotnet build` с выводом в консоль панели и путь к собранной сборке.
    private func build(_ project: URL, dotnet: URL, session: Int) async throws -> URL {
        console.append("$ dotnet build \(project.lastPathComponent) -c Debug\n", category: "console")
        let status = try await run(dotnet, ["build", project.path, "-c", "Debug", "-nologo", "-clp:NoSummary"],
                                   directory: project.deletingLastPathComponent(), echo: true)
        guard generation == session else { throw CancellationError() }
        guard status == 0 else { throw DebugError.message("Сборка не удалась — ошибки в выводе ниже") }
        var captured = ""
        _ = try await run(dotnet, ["msbuild", project.path, "-getProperty:TargetPath", "-p:Configuration=Debug"],
                          directory: project.deletingLastPathComponent(), echo: false) { captured += $0 }
        let path = captured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw DebugError.message("Не нашлась собранная сборка \(project.deletingPathExtension().lastPathComponent).dll")
        }
        return URL(fileURLWithPath: path)
    }

    private func run(_ executable: URL, _ arguments: [String], directory: URL, echo: Bool,
                     collect: ((String) -> Void)? = nil) async throws -> Int32 {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        env["DOTNET_NOLOGO"] = "1"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let console = self.console
        let collected = collect
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                if echo { console.append(text, category: "stdout") }
                collected?(text)
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            proc.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Хвост вывода, не успевший уйти в обработчик.
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                let status = p.terminationStatus
                Task { @MainActor in
                    if !rest.isEmpty {
                        let text = String(decoding: rest, as: UTF8.self)
                        if echo { console.append(text, category: "stdout") }
                        collected?(text)
                    }
                    continuation.resume(returning: status)
                }
            }
            do {
                try proc.run()
                self.buildProcess = proc
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func attach(_ backend: DebugBackend, session: Int) {
        self.backend = backend
        let (stream, continuation) = AsyncStream<DebugEvent>.makeStream()
        backend.onEvent = { continuation.yield($0) }
        // Порядок событий важен (остановка, потом «побежали»), поэтому
        // одна очередь, а не по задаче на событие.
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.generation == session else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: DebugEvent) {
        switch event {
        case .stopped(let thread, let reason, let text):
            state = .paused
            stopReason = Self.describe(reason: reason, text: text)
            loadStop(thread: thread, activate: reason != "step")
        case .resumed:
            if state == .paused { state = .running }
            clearStop()
        case .output(let text, let category):
            console.append(text, category: category)
        case .breakpoints(let file, let list):
            applyStatuses(file, list)
        case .terminated(let message):
            finish(message)
        }
    }

    private static func describe(reason: String, text: String?) -> String {
        switch reason {
        case "breakpoint", "function breakpoint": return "Точка останова"
        case "step": return "Шаг"
        case "pause": return text ?? "Пауза"
        case "exception": return "Исключение" + (text.map { ": \($0)" } ?? "")
        case "entry": return "Вход в программу"
        default: return reason
        }
    }

    func stop() {
        guard isActive else { return }
        let backend = self.backend
        let terminate: Bool
        if case .dotnetLaunch = lastTarget { terminate = true } else { terminate = false }
        buildProcess.map { if $0.isRunning { $0.terminate() } }
        generation += 1
        finish(nil)
        if let backend { Task { await backend.stop(terminate: terminate) } }
    }

    private func finish(_ message: String?) {
        eventTask?.cancel()
        eventTask = nil
        backend = nil
        buildProcess = nil
        state = .idle
        statuses = [:]
        clearStop()
        if let message { console.append(message + "\n", category: "console") }
    }

    private func fail(_ message: String) {
        let backend = self.backend
        finish(nil)
        lastError = message
        console.append(message + "\n", category: "stderr")
        if let backend { Task { await backend.stop(terminate: true) } }
    }

    func dismissError() { lastError = nil }

    // MARK: Управление

    func resume() {
        guard isPaused, let backend else { return }
        clearStop()
        state = .running
        Task { [weak self] in
            do { try await backend.resume() } catch { self?.report(error) }
        }
    }

    func pause() {
        guard state == .running, let backend else { return }
        Task { [weak self] in
            do { try await backend.pause() } catch { self?.report(error) }
        }
    }

    func step(_ kind: StepKind) {
        guard isPaused, let backend, let thread else { return }
        clearStop()
        state = .running
        Task { [weak self] in
            do { try await backend.step(kind, thread: thread) } catch { self?.report(error) }
        }
    }

    private func report(_ error: Error) {
        console.append(error.localizedDescription + "\n", category: "stderr")
    }

    // MARK: Остановка: стек и переменные

    private func clearStop() {
        variablesTask?.cancel()
        threads = []
        thread = nil
        frames = []
        frameIndex = nil
        variables = []
        children = [:]
        stopReason = nil
    }

    private func loadStop(thread: Int, activate: Bool) {
        guard let backend else { return }
        self.thread = thread
        let session = generation
        Task { [weak self] in
            let frames = (try? await backend.stackTrace(thread: thread)) ?? []
            let threads = (try? await backend.threads()) ?? []
            guard let self, self.generation == session, self.state == .paused, self.thread == thread else { return }
            self.frames = frames
            self.threads = threads
            // Верхние кадры без исходника (Thread.Sleep, движок) пропускаем:
            // человеку нужен его код.
            let first = frames.firstIndex { $0.file != nil } ?? (frames.isEmpty ? nil : 0)
            if let first { self.selectFrame(first) }
            if activate { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    func selectThread(_ id: Int) {
        guard isPaused, id != thread else { return }
        loadStop(thread: id, activate: false)
    }

    func selectFrame(_ index: Int) {
        guard index >= 0, index < frames.count, let backend, let thread else { return }
        frameIndex = index
        let frame = frames[index]
        if let file = frame.file, let line = frame.line { onShowLocation?(file, line) }
        variablesTask?.cancel()
        let expanded = self.expanded
        variablesTask = Task { [weak self] in
            let top: [DebugVariable]
            do {
                top = try await backend.variables(frame: frame.id, thread: thread)
            } catch {
                self?.variables = [DebugVariable(id: "error", name: "", value: error.localizedDescription)]
                return
            }
            // Что было раскрыто до шага — раскрываем снова, уже с новыми ссылками.
            var loaded: [String: [DebugVariable]] = [:]
            var queue = top.filter { $0.children > 0 && expanded.contains($0.id) }
            while !queue.isEmpty, loaded.count < 200 {
                let node = queue.removeFirst()
                guard let kids = try? await backend.children(of: node.children, parent: node.id) else { continue }
                loaded[node.id] = kids
                queue += kids.filter { $0.children > 0 && expanded.contains($0.id) }
            }
            guard let self, !Task.isCancelled, self.frameIndex == index else { return }
            self.variables = top
            self.children = loaded
        }
    }

    func toggleExpanded(_ variable: DebugVariable) {
        if expanded.contains(variable.id) {
            expanded.remove(variable.id)
            return
        }
        expanded.insert(variable.id)
        guard children[variable.id] == nil, variable.children > 0, let backend else { return }
        Task { [weak self] in
            let kids: [DebugVariable]
            do {
                kids = try await backend.children(of: variable.children, parent: variable.id)
            } catch {
                kids = [DebugVariable(id: variable.id + ".error", name: "", value: error.localizedDescription)]
            }
            self?.children[variable.id] = kids
        }
    }
}

/// Точка в гаттере: встала ли у отладчика и почему нет.
struct BreakpointMark: Equatable {
    var verified: Bool
    var message: String?
}

/// Вывод сессии. Копится и отдаётся интерфейсу не чаще раза в кадр:
/// лог сервера в сотни строк в секунду не должен вешать окно.
@MainActor
final class DebugConsole: ObservableObject {
    struct Line: Identifiable, Equatable {
        var id: Int
        var text: String
        var isError: Bool
    }

    @Published private(set) var lines: [Line] = []
    private var pending: [Line] = []
    private var partial = ""
    private var partialIsError = false
    private var nextID = 0
    private var flushScheduled = false
    static let limit = 5000

    func append(_ text: String, category: String) {
        let isError = category == "stderr" || category == "important"
        var chunk = partial + text
        partial = ""
        if !chunk.hasSuffix("\n") {
            // Неполную строку придерживаем до перевода строки.
            if let cut = chunk.lastIndex(of: "\n") {
                partial = String(chunk[chunk.index(after: cut)...])
                chunk = String(chunk[...cut])
            } else {
                partial = chunk
                partialIsError = isError
                scheduleFlush()
                return
            }
        }
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            pending.append(Line(id: nextID, text: String(line), isError: isError || partialIsError))
            nextID += 1
            partialIsError = false
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            var fresh = self.pending
            self.pending = []
            if !self.partial.isEmpty, fresh.isEmpty, self.lines.last?.text != self.partial {
                // Строка без перевода висит долго — покажем как есть.
                fresh.append(Line(id: self.nextID, text: self.partial, isError: self.partialIsError))
                self.nextID += 1
                self.partial = ""
            }
            guard !fresh.isEmpty else { return }
            var all = self.lines + fresh
            if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
            self.lines = all
        }
    }

    func clear() {
        lines = []
        pending = []
        partial = ""
    }

    var text: String { lines.map(\.text).joined(separator: "\n") }
}
