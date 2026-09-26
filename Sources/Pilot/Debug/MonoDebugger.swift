import Foundation

/// Отладчик Unity: редактор в Play Mode (Mono) и Development-сборки
/// со Script Debugging (IL2CPP несёт порт того же агента и говорит тем же
/// протоколом). Подключаемся к уже работающему процессу, поэтому «стоп» —
/// всегда отключение: редактор Unity никто убивать не просил.
actor MonoDebugger: DebugBackend {
    nonisolated(unsafe) var onEvent: (@Sendable (DebugEvent) -> Void)?

    let host: String
    let port: Int
    /// Корень проекта: Unity пишет в PDB пути от него.
    let root: URL

    private let connection = SDBConnection()
    private var version: SDBVersion { connection.version }

    init(host: String = "127.0.0.1", port: Int, root: URL) {
        self.host = host
        self.port = port
        self.root = root
    }

    // MARK: Состояние

    private struct Placed {
        var requests: [Int32] = []
        /// Где уже стоит: метод и смещение. Тип грузится заново после
        /// перекомпиляции скриптов — тогда у метода новый id и точка
        /// ставится ещё раз; тот же метод второй раз не нужен.
        var spots: Set<String> = []
        var status: BreakpointStatus
    }
    /// Точки по файлам (путь на диске) и строкам с нуля.
    private var breakpoints: [String: [Int: Placed]] = [:]
    private var typeLoadRequest: Int32?
    private var stepRequest: Int32?
    private var suspended = false
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<(SDB.SuspendPolicy, [SDBEvent])>.Continuation?

    // Кэши на время сессии: идентификаторы методов и типов у Mono живут,
    // пока не выгружен домен, а спрашивать их по сети на каждом шаге дорого.
    private var debugInfo: [Int: SDBDebugInfo] = [:]
    private var methodNames: [Int: String] = [:]
    private var methodTypes: [Int: Int] = [:]
    private var typeInfo: [Int: TypeInfo] = [:]
    private var typeMethods: [Int: [Int]] = [:]
    private var typeFields: [Int: [Field]] = [:]

    private struct TypeInfo {
        var namespace: String
        var name: String
        var fullName: String
        var baseType: Int
    }

    private struct Field {
        var id: Int
        var name: String
        var isStatic: Bool
    }

    /// Кадры остановленного потока: номер кадра у Mono, метод, смещение IL.
    private var frames: [Int: [(id: Int, method: Int, offset: Int)]] = [:]

    /// Что лежит за узлом дерева переменных. Живёт до следующего шага.
    private enum Handle {
        case object(Int)
        case array(Int)
        case valueType(type: Int, fields: [SDBValue])
    }
    private var handles: [Int: Handle] = [:]
    private var nextHandle = 1

    // MARK: Запуск

    func start(breakpoints initial: [URL: [Int]]) async throws {
        connection.onEvents = { [weak self] policy, events in
            guard let self else { return }
            Task { await self.enqueue(policy, events) }
        }
        connection.onClose = { [weak self] in
            guard let self else { return }
            Task { await self.connectionClosed() }
        }
        let (stream, continuation) = AsyncStream<(SDB.SuspendPolicy, [SDBEvent])>.makeStream()
        eventContinuation = continuation
        // События разбираются строго по одному: загрузка типа ставит точки,
        // и следующее событие должно видеть их уже поставленными.
        eventTask = Task { [weak self] in
            for await (policy, events) in stream {
                await self?.handle(policy, events)
            }
        }

        try await connection.connect(host: host, port: port)
        emit(.output("Подключён к \(connection.runtimeName), протокол \(connection.runtimeVersion) (работаем на \(version))\n",
                     category: "console"))
        for (file, lines) in initial {
            let statuses = await placeAll(file: file.path, lines: lines)
            emit(.breakpoints(file: file, statuses))
        }
        try? await updateTypeLoadRequest()
    }

    private func enqueue(_ policy: SDB.SuspendPolicy, _ events: [SDBEvent]) {
        eventContinuation?.yield((policy, events))
    }

    private func connectionClosed() {
        eventContinuation?.finish()
        emit(.terminated("Unity закрыл соединение"))
    }

    private nonisolated func emit(_ event: DebugEvent) { onEvent?(event) }

    // MARK: Команды

    private func send(_ set: SDB.CommandSet, _ command: UInt8, _ build: (inout SDBWriter) -> Void = { _ in }) async throws -> SDBReader {
        var w = SDBWriter()
        build(&w)
        return SDBReader(try await connection.send(set, command, w))
    }

    private func enableEvent(_ kind: SDB.EventKind, policy: SDB.SuspendPolicy, _ modifiers: [SDB.Modifier]) async throws -> Int32 {
        let version = self.version
        var r = try await send(.eventRequest, SDB.EventRequest.set.rawValue) { w in
            w.byte(kind.rawValue)
            w.byte(policy.rawValue)
            w.byte(UInt8(modifiers.count))
            for modifier in modifiers { w.modifier(modifier, version: version) }
        }
        return try r.int()
    }

    private func clearEvent(_ kind: SDB.EventKind, _ request: Int32) async {
        _ = try? await send(.eventRequest, SDB.EventRequest.clear.rawValue) { w in
            w.byte(kind.rawValue)
            w.int(request)
        }
    }

    private func vmResume() async throws {
        suspended = false
        do {
            _ = try await send(.vm, SDB.VM.resume.rawValue)
        } catch let error as SDBError where error.code == 101 {
            // Уже бежит — так и надо.
        }
    }

    // MARK: Метаданные

    private func info(ofMethod method: Int) async throws -> SDBDebugInfo {
        if let cached = debugInfo[method] { return cached }
        var r = try await send(.method, SDB.Method.getDebugInfo.rawValue) { $0.id(method) }
        let parsed = try SDBDebugInfo.parse(&r, version: version)
        debugInfo[method] = parsed
        return parsed
    }

    private func methods(ofType type: Int) async throws -> [Int] {
        if let cached = typeMethods[type] { return cached }
        var r = try await send(.type, SDB.TypeCmd.getMethods.rawValue) { $0.id(type) }
        let n = try r.count()
        var ids: [Int] = []
        for _ in 0..<n {
            ids.append(try r.id())
            if version.atLeast(2, 59) { _ = try r.int() }               // токен
        }
        typeMethods[type] = ids
        return ids
    }

    private func info(ofType type: Int) async throws -> TypeInfo {
        if let cached = typeInfo[type] { return cached }
        let version = self.version
        var r = try await send(.type, SDB.TypeCmd.getInfo.rawValue) { w in
            w.id(type)
            if version.atLeast(2, 61) { w.int(2) }                      // полное имя
        }
        let ns = try r.string()
        let name = try r.string()
        let full = try r.string()
        _ = try r.id(); _ = try r.id()                                  // сборка, модуль
        let base = try r.id()
        let parsed = TypeInfo(namespace: ns, name: SDBNames.pretty(name), fullName: SDBNames.pretty(full), baseType: base)
        typeInfo[type] = parsed
        return parsed
    }

    private func fields(ofType type: Int) async throws -> [Field] {
        if let cached = typeFields[type] { return cached }
        var r = try await send(.type, SDB.TypeCmd.getFields.rawValue) { $0.id(type) }
        let n = try r.count()
        var result: [Field] = []
        for _ in 0..<n {
            let id = try r.id()
            let name = try r.string()
            _ = try r.id()
            let attrs = try r.int()
            if version.atLeast(2, 61) { _ = try r.int() }
            result.append(Field(id: id, name: name, isStatic: attrs & 0x10 != 0))
        }
        typeFields[type] = result
        return result
    }

    private func sourceFiles(ofType type: Int) async throws -> [String] {
        var r = try await send(.type, SDB.TypeCmd.getSourceFiles2.rawValue) { $0.id(type) }
        let n = try r.count()
        return try (0..<n).map { _ in try r.string() }
    }

    private func name(ofMethod method: Int) async -> String {
        if let cached = methodNames[method] { return cached }
        var name = "?"
        if var r = try? await send(.method, SDB.Method.getName.rawValue, { $0.id(method) }), let n = try? r.string() {
            name = n
        }
        if var r = try? await send(.method, SDB.Method.getDeclaringType.rawValue, { $0.id(method) }),
           let type = try? r.id(), let info = try? await info(ofType: type) {
            methodTypes[method] = type
            name = "\(info.name).\(name)"
        }
        methodNames[method] = name
        return name
    }

    /// Путь из PDB → файл на диске. Unity пишет то полный путь, то от корня.
    private func url(forSource path: String) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let url = normalized.hasPrefix("/") ? URL(fileURLWithPath: normalized)
                                            : root.appendingPathComponent(normalized)
        return FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
    }

    // MARK: Точки останова

    func setBreakpoints(file: URL, lines: [Int]) async -> [BreakpointStatus] {
        let statuses = await placeAll(file: file.path, lines: lines)
        try? await updateTypeLoadRequest()
        return statuses
    }

    private func placeAll(file: String, lines: [Int]) async -> [BreakpointStatus] {
        for placed in (breakpoints[file] ?? [:]).values {
            for request in placed.requests { await clearEvent(.breakpoint, request) }
        }
        breakpoints[file] = [:]
        guard !lines.isEmpty else {
            breakpoints[file] = nil
            return []
        }
        var types: [Int] = []
        do {
            let basename = (file as NSString).lastPathComponent
            var r = try await send(.vm, SDB.VM.getTypesForSourceFile.rawValue) { w in
                w.string(basename)
                w.bool(true)
            }
            let n = try r.count()
            types = try (0..<n).map { _ in try r.id() }
        } catch {
            emit(.output("Типы для \(file): \(error.localizedDescription)\n", category: "stderr"))
        }
        var statuses: [BreakpointStatus] = []
        for line in Set(lines).sorted() {
            let placed = await place(file: file, line: line, types: types)
            breakpoints[file, default: [:]][line] = placed
            statuses.append(placed.status)
        }
        return statuses
    }

    /// Поставить точку по типам, где встречается файл. Ничего не нашлось —
    /// тип ещё не загружен: точка встанет при его загрузке.
    private func place(file: String, line: Int, types: [Int], skipping placed: Set<String> = []) async -> Placed {
        var candidates: [SDBLineResolver.Candidate] = []
        for type in types {
            guard let methods = try? await methods(ofType: type) else { continue }
            for method in methods {
                guard let info = try? await info(ofMethod: method),
                      info.files.contains(where: { SDBLineResolver.pdbPath($0, matches: file) }) else { continue }
                candidates.append(.init(method: method, info: info))
            }
        }
        let spots = SDBLineResolver.resolve(line: line + 1, in: candidates) {
            SDBLineResolver.pdbPath($0, matches: file)
        }
        var result = Placed(status: BreakpointStatus(line: line, verified: false,
                                                     message: "Код этой строки ещё не загружен"))
        for spot in spots {
            let key = "\(spot.method):\(spot.offset)"
            if placed.contains(key) { continue }
            do {
                let request = try await enableEvent(.breakpoint, policy: .all,
                                                    [.location(method: spot.method, offset: Int64(spot.offset))])
                result.requests.append(request)
                result.spots.insert(key)
                result.status = BreakpointStatus(line: line, verified: true, actualLine: spot.line - 1)
            } catch {
                result.status.message = error.localizedDescription
            }
        }
        if spots.isEmpty, !candidates.isEmpty {
            result.status.message = "На этой строке нет кода"
        }
        return result
    }

    /// Загрузка типа из файла с точками останова останавливает всё: точки
    /// должны встать раньше, чем код типа успеет выполниться.
    private func updateTypeLoadRequest() async throws {
        if let old = typeLoadRequest {
            await clearEvent(.typeLoad, old)
            typeLoadRequest = nil
        }
        let files = breakpoints.keys.sorted()
        guard !files.isEmpty else { return }
        // Агент сравнивает то полный путь, то имя файла — даём оба.
        let names = Array(Set(files + files.map { ($0 as NSString).lastPathComponent })).sorted()
        typeLoadRequest = try await enableEvent(.typeLoad, policy: .all, [.sourceFiles(names)])
    }

    private func typeLoaded(_ type: Int) async {
        guard let sources = try? await sourceFiles(ofType: type) else { return }
        for (file, placed) in breakpoints {
            guard sources.contains(where: { SDBLineResolver.pdbPath($0, matches: file) }) else { continue }
            var changed = false
            for (line, old) in placed {
                let fresh = await place(file: file, line: line, types: [type], skipping: old.spots)
                guard !fresh.requests.isEmpty else { continue }
                var merged = old
                merged.requests += fresh.requests
                merged.spots.formUnion(fresh.spots)
                merged.status = fresh.status
                breakpoints[file]?[line] = merged
                changed = true
            }
            if changed {
                let statuses = (breakpoints[file] ?? [:]).values.map(\.status).sorted { $0.line < $1.line }
                emit(.breakpoints(file: URL(fileURLWithPath: file), statuses))
            }
        }
    }

    // MARK: События

    private func handle(_ policy: SDB.SuspendPolicy, _ events: [SDBEvent]) async {
        var stop: (thread: Int, reason: String, text: String?)?
        for event in events {
            switch event.kind {
            case .typeLoad:
                await typeLoaded(event.id)
            case .breakpoint:
                if let step = stepRequest {
                    // Шаг «через» наткнулся на точку — шаг окончен.
                    await clearEvent(.step, step)
                    stepRequest = nil
                }
                stop = (event.thread, "breakpoint", nil)
            case .step:
                if let step = stepRequest {
                    await clearEvent(.step, step)
                    stepRequest = nil
                }
                if stop == nil { stop = (event.thread, "step", nil) }
            case .userBreak:
                stop = (event.thread, "pause", "Debugger.Break()")
            case .vmDeath:
                emit(.terminated("Программа завершилась (код \(event.exitCode))"))
                connection.shutdown()
                return
            case .crash:
                emit(.terminated("Рантайм упал: \(event.message ?? "")"))
                return
            default:
                break
            }
        }
        guard policy != .none else { return }
        if let stop {
            suspended = true
            invalidateStop()
            emit(.stopped(thread: stop.thread, reason: stop.reason, text: stop.text))
        } else {
            // Остановились ради загрузки типа или старта — дальше.
            try? await vmResume()
        }
    }

    private func invalidateStop() {
        frames = [:]
        handles = [:]
        nextHandle = 1
    }

    // MARK: Управление

    func resume() async throws {
        invalidateStop()
        try await vmResume()
        emit(.resumed)
    }

    func pause() async throws {
        _ = try await send(.vm, SDB.VM.suspend.rawValue)
        suspended = true
        invalidateStop()
        // Какой поток показать: тот, где на стеке есть наш код. Главный
        // поток Unity почти всегда такой.
        let all = try await threads()
        var chosen = all.first?.id ?? 0
        search: for thread in all {
            for frame in (try? await stackTrace(thread: thread.id)) ?? [] where frame.file != nil {
                chosen = thread.id
                break search
            }
        }
        emit(.stopped(thread: chosen, reason: "pause", text: nil))
    }

    func step(_ kind: StepKind, thread: Int) async throws {
        if let old = stepRequest { await clearEvent(.step, old) }
        let depth: SDB.StepDepth = switch kind {
        case .over: .over
        case .into: .into
        case .out: .out
        }
        stepRequest = try await enableEvent(.step, policy: .all, [.step(thread: thread, size: .line, depth: depth)])
        invalidateStop()
        try await vmResume()
        emit(.resumed)
    }

    func stop(terminate: Bool) async {
        eventContinuation?.finish()
        if !connection.isClosed {
            _ = try? await send(.eventRequest, SDB.EventRequest.clearAllBreakpoints.rawValue)
            if let request = typeLoadRequest { await clearEvent(.typeLoad, request) }
            if let request = stepRequest { await clearEvent(.step, request) }
            if suspended { try? await vmResume() }
            // DISPOSE — отключение: агент снимает наши запросы и отпускает
            // всё, что держал. EXIT закрыл бы редактор, его не шлём никогда.
            _ = try? await send(.vm, SDB.VM.dispose.rawValue)
        }
        connection.onClose = nil
        connection.shutdown()
        eventTask?.cancel()
    }

    // MARK: Потоки и стек

    func threads() async throws -> [DebugThread] {
        var r = try await send(.vm, SDB.VM.allThreads.rawValue)
        let n = try r.count()
        let ids = try (0..<n).map { _ in try r.id() }
        var result: [DebugThread] = []
        for id in ids {
            var name = ""
            if var nr = try? await send(.thread, SDB.Thread.getName.rawValue, { $0.id(id) }) {
                name = (try? nr.string()) ?? ""
            }
            result.append(DebugThread(id: id, name: name.isEmpty ? "Поток \(id)" : name))
        }
        return result
    }

    func stackTrace(thread: Int) async throws -> [DebugFrame] {
        var r = try await send(.thread, SDB.Thread.getFrameInfo.rawValue) { w in
            w.id(thread); w.int(0); w.int(-1)
        }
        let n = try r.count()
        var raw: [(id: Int, method: Int, offset: Int)] = []
        for _ in 0..<n {
            let id = Int(try r.int())
            let method = try r.id()
            let offset = Int(try r.int())
            _ = try r.byte()
            raw.append((id, method, offset))
        }
        frames[thread] = raw
        var result: [DebugFrame] = []
        for frame in raw {
            let name = await name(ofMethod: frame.method)
            var file: URL?
            var line: Int?
            if let info = try? await info(ofMethod: frame.method), let place = info.location(at: frame.offset) {
                file = place.file.flatMap(url(forSource:))
                line = place.line - 1
            }
            result.append(DebugFrame(id: frame.id, name: name, file: file, line: line))
        }
        return result
    }

    // MARK: Переменные

    func variables(frame: Int, thread: Int) async throws -> [DebugVariable] {
        if frames[thread] == nil { _ = try await stackTrace(thread: thread) }
        guard let found = frames[thread]?.first(where: { $0.id == frame }) else {
            throw DebugError.message("Кадр больше недействителен")
        }
        var result: [DebugVariable] = []

        if var r = try? await send(.stackFrame, SDB.StackFrame.getThis.rawValue, { w in w.id(thread); w.id(frame) }),
           let value = try? r.value(version), value != .null, value != .void {
            result.append(await describe(value, name: "this", path: "this"))
        }

        // Параметры: номера позиций у Mono отрицательные.
        var paramNames: [String] = []
        if var r = try? await send(.method, SDB.Method.getParamInfo.rawValue, { $0.id(found.method) }) {
            _ = try r.int()                                              // соглашение о вызове
            let count = try r.count()
            _ = try r.int()                                              // обобщённых параметров
            _ = try r.id()                                               // тип результата
            for _ in 0..<count { _ = try r.id() }
            paramNames = try (0..<count).map { _ in try r.string() }
        }

        var localNames: [(name: String, position: Int)] = []
        if var r = try? await send(.method, SDB.Method.getLocalsInfo.rawValue, { $0.id(found.method) }) {
            if version.atLeast(2, 43) {
                let scopes = try r.count()
                for _ in 0..<scopes { _ = try r.int(); _ = try r.int() }
            }
            let count = try r.count()
            for _ in 0..<count { _ = try r.id() }
            let names = try (0..<count).map { _ in try r.string() }
            var live: [(Int, Int)] = []
            for _ in 0..<count { live.append((Int(try r.int()), Int(try r.int()))) }
            var indexes = Array(0..<count)
            if version.atLeast(2, 65), r.hasMore {
                indexes = try (0..<count).map { _ in Int(try r.int()) }
            }
            for i in 0..<count {
                let name = names[i]
                // Служебные переменные компилятора и те, что ещё не родились
                // или уже умерли в этой точке метода.
                guard !name.isEmpty, !name.hasPrefix("CS$"), !name.hasPrefix("<") else { continue }
                guard found.offset >= live[i].0, found.offset <= live[i].1 else { continue }
                localNames.append((name, indexes[i]))
            }
        }

        let positions = paramNames.indices.map { -$0 - 1 } + localNames.map(\.position)
        let names = paramNames + localNames.map(\.name)
        let values = await frameValues(thread: thread, frame: frame, positions: positions)
        for (i, name) in names.enumerated() {
            guard let value = values[i] else {
                result.append(DebugVariable(id: name, name: name, value: "недоступно"))
                continue
            }
            result.append(await describe(value, name: name, path: name))
        }
        return result
    }

    /// Все значения кадра одним запросом; если какое-то не читается,
    /// рантайм отвергает весь запрос — тогда по одному.
    private func frameValues(thread: Int, frame: Int, positions: [Int]) async -> [SDBValue?] {
        guard !positions.isEmpty else { return [] }
        let version = self.version
        func fetch(_ ps: [Int]) async -> [SDBValue]? {
            guard var r = try? await send(.stackFrame, SDB.StackFrame.getValues.rawValue, { w in
                w.id(thread); w.id(frame); w.int(ps.count)
                for p in ps { w.int(p) }
            }) else { return nil }
            return try? ps.map { _ in try r.value(version) }
        }
        if let all = await fetch(positions) { return all }
        var result: [SDBValue?] = []
        for p in positions { result.append(await fetch([p])?.first) }
        return result
    }

    func children(of reference: Int, parent: String) async throws -> [DebugVariable] {
        guard let handle = handles[reference] else {
            throw DebugError.message("Значение больше недействительно — программа ушла дальше")
        }
        switch handle {
        case .object(let object):
            var r = try await send(.objectRef, SDB.ObjectRef.getType.rawValue) { $0.id(object) }
            var type = try r.id()
            // Поля всей цепочки наследования: сначала свои, потом базовые.
            var all: [Field] = []
            var guardDepth = 0
            while type != 0, guardDepth < 32 {
                let info = try await info(ofType: type)
                if info.fullName == "object" || info.fullName == "UnityEngine.Object" && !all.isEmpty { break }
                all += try await fields(ofType: type).filter { !$0.isStatic }
                type = info.baseType
                guardDepth += 1
            }
            guard !all.isEmpty else { return [] }
            let version = self.version
            var vr = try await send(.objectRef, SDB.ObjectRef.getValues.rawValue) { w in
                w.id(object); w.int(all.count)
                for field in all { w.id(field.id) }
            }
            var result: [DebugVariable] = []
            for field in all {
                let value = try vr.value(version)
                let name = SDBNames.field(field.name)
                result.append(await describe(value, name: name, path: parent + "." + name))
            }
            return result

        case .array(let array):
            var lr = try await send(.arrayRef, SDB.ArrayRef.getLength.rawValue) { $0.id(array) }
            let rank = try lr.count()
            var length = 1
            for _ in 0..<rank { length *= Int(try lr.int()); _ = try lr.int() }
            let shown = min(length, 1000)
            guard shown > 0 else { return [] }
            let version = self.version
            var vr = try await send(.arrayRef, SDB.ArrayRef.getValues.rawValue) { w in
                w.id(array); w.int(0); w.int(shown)
            }
            var result: [DebugVariable] = []
            for i in 0..<shown {
                result.append(await describe(try vr.value(version), name: "[\(i)]", path: parent + "[\(i)]"))
            }
            if length > shown {
                result.append(DebugVariable(id: parent + "[…]", name: "…", value: "ещё \(length - shown)"))
            }
            return result

        case .valueType(let type, let values):
            let own = try await fields(ofType: type).filter { !$0.isStatic }
            var result: [DebugVariable] = []
            for (field, value) in zip(own, values) {
                let name = SDBNames.field(field.name)
                result.append(await describe(value, name: name, path: parent + "." + name))
            }
            return result
        }
    }

    private func handle(for handle: Handle) -> Int {
        let id = nextHandle
        nextHandle += 1
        handles[id] = handle
        return id
    }

    private func describe(_ value: SDBValue, name: String, path: String) async -> DebugVariable {
        var variable = DebugVariable(id: path, name: name, value: "")
        if let text = value.primitiveText {
            variable.value = text
            variable.type = value.primitiveTypeName ?? ""
            return variable
        }
        switch value {
        case .object(let object, .string):
            variable.type = "string"
            if var r = try? await send(.stringRef, SDB.StringRef.getValue.rawValue, { $0.id(object) }) {
                let utf16 = version.atLeast(2, 41) ? ((try? r.byte()) ?? 0) == 1 : false
                let text = (utf16 ? try? r.utf16String() : try? r.string()) ?? "?"
                variable.value = SDBNames.quote(text)
            }
        case .object(let object, let kind):
            var typeName = "object"
            if var r = try? await send(.objectRef, SDB.ObjectRef.getType.rawValue, { $0.id(object) }),
               let type = try? r.id(), let info = try? await info(ofType: type) {
                typeName = SDBNames.short(info.fullName)
                variable.type = info.fullName
            }
            if kind == .szArray || kind == .array {
                var count = "?"
                if var lr = try? await send(.arrayRef, SDB.ArrayRef.getLength.rawValue, { $0.id(object) }),
                   let rank = try? lr.count() {
                    var total = 1
                    for _ in 0..<rank { total *= Int((try? lr.int()) ?? 0); _ = try? lr.int() }
                    count = String(total)
                }
                variable.value = typeName.hasSuffix("[]") ? "\(typeName.dropLast(2))[\(count)]" : "\(typeName) [\(count)]"
                variable.children = handle(for: .array(object))
            } else {
                variable.value = "{\(typeName)}"
                variable.children = handle(for: .object(object))
            }
        case .valueType(let type, let isEnum, let fields):
            let info = try? await info(ofType: type)
            variable.type = info?.fullName ?? ""
            if isEnum {
                variable.value = fields.first?.primitiveText ?? "?"
                if let name = info?.name { variable.value += " (\(name))" }
            } else {
                // Небольшие структуры из чисел — Vector3, Color — видны сразу.
                let parts = fields.compactMap(\.primitiveText)
                if parts.count == fields.count, (1...4).contains(parts.count) {
                    variable.value = "(" + parts.joined(separator: ", ") + ")"
                } else {
                    variable.value = "{\(info?.name ?? "struct")}"
                }
                if !fields.isEmpty { variable.children = handle(for: .valueType(type: type, fields: fields)) }
            }
        case .fixedArray(let items):
            variable.value = "[" + items.compactMap(\.primitiveText).joined(separator: ", ") + "]"
        case .typeRef:
            variable.value = "{тип}"
        default:
            variable.value = "?"
        }
        return variable
    }
}
