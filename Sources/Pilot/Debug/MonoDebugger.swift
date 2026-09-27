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
        /// Условие считаем сами: агент Mono условий не знает.
        var condition: String?
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
        /// `slot` — куда записать структуру целиком, если поменяют её поле.
        case valueType(type: Int, fields: [SDBValue], slot: Int?)
    }
    private var handles: [Int: Handle] = [:]
    private var nextHandle = 1

    /// Куда пишется значение: переменная кадра, поле, элемент массива
    /// или поле структуры (тогда переписывается вся структура в её слот).
    private enum Slot {
        case local(thread: Int, frame: Int, position: Int)
        case field(object: Int, field: Int)
        case element(array: Int, index: Int)
        case structField(parent: Int, type: Int, fields: [SDBValue], index: Int)
    }
    private var slots: [Int: (slot: Slot, current: SDBValue)] = [:]
    /// Кадр, чьи переменные показаны: в нём считается набранное значение.
    private var shownFrame: (thread: Int, frame: Int)?
    /// Значения, на которые ссылается вычисляемое выражение.
    private var operands: [Int: SDBValue] = [:]
    private var rootDomain: Int?

    // MARK: Запуск

    func start(breakpoints initial: [URL: [BreakpointSpec]]) async throws {
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
        for (file, specs) in initial {
            let statuses = await placeAll(file: file.path, specs)
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

    func setBreakpoints(file: URL, _ specs: [BreakpointSpec]) async -> [BreakpointStatus] {
        let statuses = await placeAll(file: file.path, specs)
        try? await updateTypeLoadRequest()
        return statuses
    }

    private func placeAll(file: String, _ specs: [BreakpointSpec]) async -> [BreakpointStatus] {
        for placed in (breakpoints[file] ?? [:]).values {
            for request in placed.requests { await clearEvent(.breakpoint, request) }
        }
        breakpoints[file] = [:]
        guard !specs.isEmpty else {
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
            emit(.output(L("Типы для \(file): \(error.localizedDescription)") + "\n", category: "important"))
        }
        var statuses: [BreakpointStatus] = []
        for spec in specs.sorted(by: { $0.line < $1.line }) where breakpoints[file]?[spec.line] == nil {
            var placed = await place(file: file, line: spec.line, types: types)
            placed.condition = spec.condition
            // Ошибку в условии видно сразу, а не на первой остановке.
            if let condition = spec.condition {
                do { _ = try DebugExpression.parse(condition) } catch {
                    placed.status.message = "Условие: \(error.localizedDescription)"
                }
            }
            breakpoints[file, default: [:]][spec.line] = placed
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
                var text: String?
                if let condition = condition(of: event.request) {
                    do {
                        guard try await holds(condition, thread: event.thread) else { continue }
                    } catch {
                        // Не посчиталось — встаём и говорим почему: молча
                        // пропускать точку хуже.
                        text = "условие «\(condition)»: \(error.localizedDescription)"
                    }
                }
                if let step = stepRequest {
                    // Шаг «через» наткнулся на точку — шаг окончен.
                    await clearEvent(.step, step)
                    stepRequest = nil
                }
                stop = (event.thread, "breakpoint", text)
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
        slots = [:]
        operands = [:]
        shownFrame = nil
        nextHandle = 1
    }

    // MARK: Условия

    private func condition(of request: Int32) -> String? {
        for placed in breakpoints.values.lazy.flatMap(\.values) where placed.requests.contains(request) {
            return placed.condition
        }
        return nil
    }

    private func holds(_ condition: String, thread: Int) async throws -> Bool {
        let expression = try DebugExpression.parse(condition)
        defer { operands = [:]; frames = [:] }
        guard let top = try await rawFrames(thread: thread).first else { throw DebugError.message("у потока нет кадров") }
        let value = try await expression.evaluate(in: MonoExpressionContext(debugger: self, thread: thread, frame: top.id))
        guard case .bool(let result) = value else { throw DebugError.message("это не bool, а \(value.description)") }
        return result
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

    /// Кадры потока без имён и строк — это отдельные запросы.
    private func rawFrames(thread: Int) async throws -> [(id: Int, method: Int, offset: Int)] {
        if let cached = frames[thread] { return cached }
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
        return raw
    }

    func stackTrace(thread: Int) async throws -> [DebugFrame] {
        frames[thread] = nil
        let raw = try await rawFrames(thread: thread)
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

    /// `this`, параметры и живые локальные переменные кадра: имена и
    /// позиции для GET/SET_VALUES.
    private func frameLayout(thread: Int, frame: Int) async throws -> (this: SDBValue?, names: [String], positions: [Int]) {
        guard let found = try await rawFrames(thread: thread).first(where: { $0.id == frame }) else {
            throw DebugError.message("Кадр больше недействителен")
        }
        var this: SDBValue?
        if var r = try? await send(.stackFrame, SDB.StackFrame.getThis.rawValue, { w in w.id(thread); w.id(frame) }),
           let value = try? r.value(version), value != .null, value != .void {
            this = value
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
        return (this, names, positions)
    }

    func variables(frame: Int, thread: Int) async throws -> [DebugVariable] {
        let layout = try await frameLayout(thread: thread, frame: frame)
        shownFrame = (thread, frame)
        var result: [DebugVariable] = []
        if let this = layout.this {
            result.append(await describe(this, name: "this", path: "this"))
        }
        let values = await frameValues(thread: thread, frame: frame, positions: layout.positions)
        for (i, name) in layout.names.enumerated() {
            guard let value = values[i] else {
                result.append(DebugVariable(id: name, name: name, value: "недоступно"))
                continue
            }
            let slot = Slot.local(thread: thread, frame: frame, position: layout.positions[i])
            result.append(await describe(value, name: name, path: name, slot: slot))
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
            var result: [DebugVariable] = []
            for (field, value) in try await instanceFields(of: object) {
                let name = SDBNames.field(field.name)
                result.append(await describe(value, name: name, path: parent + "." + name,
                                             slot: .field(object: object, field: field.id)))
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
                result.append(await describe(try vr.value(version), name: "[\(i)]", path: parent + "[\(i)]",
                                             slot: .element(array: array, index: i)))
            }
            if length > shown {
                result.append(DebugVariable(id: parent + "[…]", name: "…", value: "ещё \(length - shown)"))
            }
            return result

        case .valueType(let type, let values, let slot):
            let own = try await fields(ofType: type).filter { !$0.isStatic }
            var result: [DebugVariable] = []
            for (index, (field, value)) in zip(own, values).enumerated() {
                let name = SDBNames.field(field.name)
                let fieldSlot = slot.map { Slot.structField(parent: $0, type: type, fields: values, index: index) }
                result.append(await describe(value, name: name, path: parent + "." + name, slot: fieldSlot))
            }
            return result
        }
    }

    /// Поля объекта по всей цепочке наследования: сначала свои, потом базовые.
    private func instanceFields(of object: Int) async throws -> [(Field, SDBValue)] {
        var r = try await send(.objectRef, SDB.ObjectRef.getType.rawValue) { $0.id(object) }
        var type = try r.id()
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
        return try all.map { ($0, try vr.value(version)) }
    }

    private func handle(for handle: Handle) -> Int {
        let id = nextHandle
        nextHandle += 1
        handles[id] = handle
        return id
    }

    /// Слот значения — номер для правки; без слота править нечего.
    private func register(_ slot: Slot?, _ value: SDBValue) -> Int? {
        guard let slot else { return nil }
        let id = nextHandle
        nextHandle += 1
        slots[id] = (slot, value)
        return id
    }

    private func describe(_ value: SDBValue, name: String, path: String, slot: Slot? = nil) async -> DebugVariable {
        var variable = DebugVariable(id: path, name: name, value: "")
        if let text = value.primitiveText {
            variable.value = text
            variable.type = value.primitiveTypeName ?? ""
            switch value {
            case .void, .pointer: break
            default: variable.editRef = register(slot, value) ?? 0
            }
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
            variable.editRef = register(slot, value) ?? 0
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
                variable.editRef = register(slot, value) ?? 0
            } else {
                // Небольшие структуры из чисел — Vector3, Color — видны сразу.
                let parts = fields.compactMap(\.primitiveText)
                if parts.count == fields.count, (1...4).contains(parts.count) {
                    variable.value = "(" + parts.joined(separator: ", ") + ")"
                } else {
                    variable.value = "{\(info?.name ?? "struct")}"
                }
                if !fields.isEmpty {
                    let own = register(slot, value)
                    variable.children = handle(for: .valueType(type: type, fields: fields, slot: own))
                }
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

    // MARK: Правка значений

    func setVariable(_ variable: DebugVariable, to text: String) async throws {
        guard suspended, let entry = slots[variable.editRef], let shownFrame else {
            throw DebugError.message("Значение больше недействительно — программа ушла дальше")
        }
        defer { operands = [:] }
        // Набранное — выражение в кадре: `42`, `"имя"`, `count + 1`, `other`.
        let expression = try DebugExpression.parse(text)
        let context = MonoExpressionContext(debugger: self, thread: shownFrame.thread, frame: shownFrame.frame)
        let fresh = try await sdbValue(try await expression.evaluate(in: context), like: entry.current)
        try await write(fresh, to: entry.slot)
    }

    private func write(_ value: SDBValue, to slot: Slot) async throws {
        var encoded = SDBWriter()
        try encoded.value(value, version: version)
        let payload = encoded.bytes
        switch slot {
        case .local(let thread, let frame, let position):
            _ = try await send(.stackFrame, SDB.StackFrame.setValues.rawValue) { w in
                w.id(thread); w.id(frame); w.int(1); w.int(position)
                w.raw(payload)
            }
        case .field(let object, let field):
            _ = try await send(.objectRef, SDB.ObjectRef.setValues.rawValue) { w in
                w.id(object); w.int(1); w.id(field)
                w.raw(payload)
            }
        case .element(let array, let index):
            _ = try await send(.arrayRef, SDB.ArrayRef.setValues.rawValue) { w in
                w.id(array); w.int(index); w.int(1)
                w.raw(payload)
            }
        case .structField(let parent, let type, var fields, let index):
            // Структура — значение: меняем поле в копии и кладём её целиком
            // туда, где она лежит (а та, может, сама поле структуры).
            guard let owner = slots[parent] else {
                throw DebugError.message("Структура больше недействительна")
            }
            fields[index] = value
            try await write(.valueType(type: type, isEnum: false, fields: fields), to: owner.slot)
        }
    }

    /// Результат выражения — в значение того же типа, что лежит в слоте:
    /// агент сверяет тип и чужой не примет.
    private func sdbValue(_ operand: DebugOperand, like current: SDBValue) async throws -> SDBValue {
        func mismatch() -> DebugError {
            DebugError.message("Нужно \(Self.expected(current)), а получилось \(operand.description)")
        }
        switch current {
        case .bool:
            guard case .bool(let b) = operand else { throw mismatch() }
            return .bool(b)
        case .char:
            guard let n = operand.integer, (0...Int64(UInt16.max)).contains(n) else { throw mismatch() }
            return .char(UInt16(n))
        case .int(_, let element):
            guard let n = operand.integer else { throw mismatch() }
            let range: ClosedRange<Int64>? = switch element {
            case .i1: Int64(Int8.min)...Int64(Int8.max)
            case .u1: 0...Int64(UInt8.max)
            case .i2: Int64(Int16.min)...Int64(Int16.max)
            case .u2: 0...Int64(UInt16.max)
            case .i4: Int64(Int32.min)...Int64(Int32.max)
            case .u4: 0...Int64(UInt32.max)
            default: nil
            }
            if let range, !range.contains(n) {
                throw DebugError.message("\(n) не влезает в \(current.primitiveTypeName ?? "это число")")
            }
            return .int(n, element)
        case .uint(_, let element):
            guard let n = operand.integer else { throw mismatch() }
            return .uint(UInt64(bitPattern: n), element)
        case .float:
            guard let d = operand.real else { throw mismatch() }
            return .float(d)
        case .double:
            guard let d = operand.real else { throw mismatch() }
            return .double(d)
        case .valueType(let type, true, let fields):
            // Перечисление — его число; имена членов не разрешаем.
            guard let n = operand.integer, let first = fields.first else { throw mismatch() }
            let raw: SDBValue = switch first {
            case .uint(_, let element): .uint(UInt64(bitPattern: n), element)
            case .int(_, let element): .int(n, element)
            default: .int(n, .i4)
            }
            return .valueType(type: type, isEnum: true, fields: [raw])
        case .null, .object:
            switch operand {
            case .null:
                return .null
            case .string(let s):
                return .object(try await createString(s), .string)
            case .object(_, let handle):
                guard let value = operands[handle], case .object = value else { throw mismatch() }
                return value
            default:
                throw mismatch()
            }
        default:
            throw DebugError.message("Такое значение менять не умею")
        }
    }

    private static func expected(_ value: SDBValue) -> String {
        switch value {
        case .object(_, .string): return "строка"
        case .valueType(_, true, _): return "число перечисления"
        case .null, .object: return "объект или null"
        default: return value.primitiveTypeName ?? "значение того же типа"
        }
    }

    private func createString(_ text: String) async throws -> Int {
        if rootDomain == nil {
            var r = try await send(.appDomain, SDB.AppDomain.getRootDomain.rawValue)
            rootDomain = try r.id()
        }
        let domain = rootDomain ?? 0
        var r = try await send(.appDomain, SDB.AppDomain.createString.rawValue) { w in
            w.id(domain); w.string(text)
        }
        return try r.id()
    }

    // MARK: Выражения

    /// Значение Mono — в операнд выражения. Строки читаются сразу,
    /// объекты и структуры остаются ссылкой.
    private func operand(_ value: SDBValue) async throws -> DebugOperand {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .char(let c): return .char(c)
        case .int(let n, _): return .int(n)
        case .uint(let n, _): return .int(Int64(bitPattern: n))
        case .float(let d), .double(let d): return .double(d)
        case .object(let object, .string):
            var r = try await send(.stringRef, SDB.StringRef.getValue.rawValue) { $0.id(object) }
            var utf16 = false
            if version.atLeast(2, 41) { utf16 = try r.byte() == 1 }
            return .string(utf16 ? try r.utf16String() : try r.string())
        case .object(let object, _):
            let handle = nextHandle
            nextHandle += 1
            operands[handle] = value
            return .object(identity: object, handle: handle)
        case .valueType(_, true, let fields):
            guard let first = fields.first else { throw DebugError.message("пустое перечисление") }
            return try await operand(first)
        case .valueType:
            let handle = nextHandle
            nextHandle += 1
            operands[handle] = value
            // У структур ссылки нет — сравнивать их по ссылке нельзя.
            return .object(identity: -handle, handle: handle)
        default:
            throw DebugError.message("такое значение в выражении не читается")
        }
    }

    fileprivate func lookup(_ name: String, thread: Int, frame: Int) async throws -> DebugOperand {
        let layout = try await frameLayout(thread: thread, frame: frame)
        if name == "this" {
            guard let this = layout.this else { throw DebugError.message("в статическом методе нет this") }
            return try await operand(this)
        }
        // Как в C#: последняя объявленная с этим именем — ближайшая.
        if let i = layout.names.lastIndex(of: name) {
            guard let value = await frameValues(thread: thread, frame: frame, positions: [layout.positions[i]]).first ?? nil else {
                throw DebugError.message("\(name) недоступна")
            }
            return try await operand(value)
        }
        if let this = layout.this {
            if let found = try? await member(of: try await operand(this), name) { return found }
        }
        throw DebugError.message("нет переменной \(name)")
    }

    fileprivate func member(of value: DebugOperand, _ name: String) async throws -> DebugOperand {
        guard case .object(_, let handle) = value, let raw = operands[handle] else {
            throw DebugError.message("у \(value.description) нет поля \(name)")
        }
        switch raw {
        case .object(let array, .szArray), .object(let array, .array):
            guard name == "Length" else { throw DebugError.message("у массива нет \(name)") }
            var r = try await send(.arrayRef, SDB.ArrayRef.getLength.rawValue) { $0.id(array) }
            let rank = try r.count()
            var total: Int64 = 1
            for _ in 0..<rank { total *= Int64(try r.int()); _ = try r.int() }
            return .int(total)
        case .object(let object, _):
            for (field, fieldValue) in try await instanceFields(of: object)
                where field.name == name || SDBNames.field(field.name) == name {
                return try await operand(fieldValue)
            }
            throw DebugError.message("нет поля \(name) (свойства без поля не читаются)")
        case .valueType(let type, _, let fields):
            let own = try await self.fields(ofType: type).filter { !$0.isStatic }
            for (field, fieldValue) in zip(own, fields) where field.name == name || SDBNames.field(field.name) == name {
                return try await operand(fieldValue)
            }
            throw DebugError.message("нет поля \(name)")
        default:
            throw DebugError.message("у \(value.description) нет поля \(name)")
        }
    }

    fileprivate func element(of value: DebugOperand, _ index: Int) async throws -> DebugOperand {
        guard case .object(_, let handle) = value, let raw = operands[handle],
              case .object(let array, let kind) = raw, kind == .szArray || kind == .array else {
            throw DebugError.message("индексировать можно только массив (List — нельзя, это вызов)")
        }
        let version = self.version
        do {
            var r = try await send(.arrayRef, SDB.ArrayRef.getValues.rawValue) { w in
                w.id(array); w.int(index); w.int(1)
            }
            return try await operand(try r.value(version))
        } catch let error as SDBError where error.code == 102 {
            throw DebugError.message("индекс \(index) вне массива")
        }
    }
}

/// Имена выражения — в кадре остановленного потока Unity.
private struct MonoExpressionContext: DebugExpressionContext {
    let debugger: MonoDebugger
    let thread: Int
    let frame: Int

    func lookup(_ name: String) async throws -> DebugOperand {
        try await debugger.lookup(name, thread: thread, frame: frame)
    }

    func member(of value: DebugOperand, _ name: String) async throws -> DebugOperand {
        try await debugger.member(of: value, name)
    }

    func element(of value: DebugOperand, _ index: Int) async throws -> DebugOperand {
        try await debugger.element(of: value, index)
    }
}
