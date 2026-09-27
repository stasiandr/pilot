import Foundation

/// Общий язык отладчиков Pilot: Unity (Mono и IL2CPP — протокол Mono)
/// и .NET (netcoredbg по DAP). Строки здесь — с нуля, как в редакторе;
/// переводом в единицы протоколов занимаются бэкенды.

struct DebugThread: Identifiable, Equatable, Sendable {
    var id: Int
    var name: String
}

struct DebugFrame: Identifiable, Equatable, Sendable {
    var id: Int
    var name: String
    /// Файл на диске — если отладчик знает исходник и он нашёлся.
    var file: URL?
    /// Строка с нуля; nil — у кадра нет исходника (движок, рантайм).
    var line: Int?
    var column: Int = 0
}

struct DebugVariable: Identifiable, Equatable, Sendable {
    /// Путь от кадра: у раскрытых узлов он переживает шаг, и дерево
    /// после шага остаётся раскрытым там же.
    var id: String
    var name: String
    var value: String
    var type: String = ""
    /// Больше нуля — у узла есть дети, их спрашивают по этому номеру.
    var children: Int = 0
    /// Больше нуля — значение можно поменять: бэкенд по этому номеру
    /// знает, куда его записать. Ноль — только смотреть.
    var editRef: Int = 0

    var isEditable: Bool { editRef > 0 }
}

/// Точка останова, как её отдают отладчику: строка с нуля и условие на C#.
struct BreakpointSpec: Equatable, Sendable {
    var line: Int
    var condition: String?
}

/// Что стало с точкой останова у отладчика.
struct BreakpointStatus: Equatable, Sendable {
    /// Строка, которую просили (с нуля).
    var line: Int
    /// Нашлось место в коде — точка встанет.
    var verified: Bool
    /// Куда встала на самом деле: пустая строка переносит её на следующую с кодом.
    var actualLine: Int?
    var message: String?
}

enum StepKind: Sendable {
    case over, into, out
}

enum DebugEvent: Sendable {
    /// Остановка: точка останова, шаг, пауза, исключение.
    case stopped(thread: Int, reason: String, text: String?)
    case resumed
    /// Сообщение самого отладчика: подключение, ошибки, `Debug.WriteLine`.
    /// Категория — как в DAP: `console`, `important` (ошибка) и прочие.
    case output(String, category: String)
    /// stdout и stderr программы, которую отладчик запустил сам, — тот же
    /// вывод, что у ▶, и разбирается он так же (`ProgramOutput`).
    case programOutput(String)
    /// Программа завершилась с этим кодом; сессия ещё может сказать своё.
    case exited(Int32)
    /// Точки останова переразрешились: загрузился тип, перекомпилировался код.
    case breakpoints(file: URL, [BreakpointStatus])
    /// Сессия кончилась: программа вышла, редактор закрыли, связь оборвалась.
    case terminated(String?)
}

/// Чей текст в событии DAP `output`. netcoredbg отдаёт stdout и stderr
/// запущенной им программы категориями `stdout` и `stderr`, а
/// `Debug.WriteLine` (`Debugger.Log`) — тоже `stdout`, но с местом вызова
/// в `source`: это уже не вывод процесса — при ▶ его не видно вовсе.
enum DebugOutputSource: Equatable, Sendable {
    /// Вывод процесса — в лог программы, как у ▶.
    case program
    /// Сообщение отладчика, со своей категорией.
    case debugger(category: String)
    /// Телеметрия адаптера — не показывается.
    case ignored

    init(dapOutput body: [String: Any]) {
        let category = body["category"] as? String ?? "console"
        switch category {
        case "telemetry": self = .ignored
        case "stdout", "stderr": self = body["source"] == nil ? .program : .debugger(category: category)
        default: self = .debugger(category: category)
        }
    }
}

/// Бэкенд отладчика. Все вызовы асинхронные и не блокируют интерфейс:
/// Unity, остановленный на точке, отвечает быстро, а вот IL2CPP-плеер
/// на телефоне — с задержкой сети.
protocol DebugBackend: AnyObject, Sendable {
    /// Куда отдавать события. Ставится до `start`.
    var onEvent: (@Sendable (DebugEvent) -> Void)? { get set }

    /// Подключиться или запустить. Точки останова приходят сюда же:
    /// их надо поставить до того, как программа побежит дальше.
    func start(breakpoints: [URL: [BreakpointSpec]]) async throws

    func setBreakpoints(file: URL, _ breakpoints: [BreakpointSpec]) async -> [BreakpointStatus]

    func threads() async throws -> [DebugThread]
    func stackTrace(thread: Int) async throws -> [DebugFrame]
    func variables(frame: Int, thread: Int) async throws -> [DebugVariable]
    func children(of reference: Int, parent: String) async throws -> [DebugVariable]
    /// Записать в переменную значение, набранное человеком как литерал C#.
    /// Программа должна стоять.
    func setVariable(_ variable: DebugVariable, to value: String) async throws

    func resume() async throws
    func pause() async throws
    func step(_ kind: StepKind, thread: Int) async throws

    /// Отключиться. `terminate` — убить программу, если мы её запускали;
    /// к чужому процессу (редактору Unity) это не относится никогда.
    func stop(terminate: Bool) async
}

enum DebugError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
