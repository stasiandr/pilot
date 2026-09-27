import SwiftUI
import AppKit

/// Вывод запущенной цели. Не @Published: сервер пишет тысячи строк,
/// и перерисовывать ради каждой всё окно незачем — консоль подписана
/// сама и дописывает в текст только новое.
@MainActor
final class RunLog {
    /// Больше не держим: старое начало уходит, как в Xcode.
    static let limit = 2_000_000

    private(set) var text = ""
    /// Дописан кусок в конец.
    var onAppend: ((String) -> Void)?
    /// Текст заменён целиком: очистили или обрезали начало.
    var onReset: (() -> Void)?

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        if text.utf16.count > Self.limit {
            // Обрезаем с запасом и по началу строки, чтобы не делать этого на каждом куске.
            var cut = text.index(text.endIndex, offsetBy: -Self.limit * 3 / 4)
            if let newline = text[cut...].firstIndex(of: "\n") { cut = text.index(after: newline) }
            text = String(text[cut...])
            onReset?()
        } else {
            onAppend?(chunk)
        }
    }

    func clear() {
        text = ""
        onReset?()
    }
}

/// Тот же вывод, разобранный на события лога сервера (см. `ServerLogParser`):
/// консоль показывает их списком с фильтрами, если сервер пишет через Serilog.
@MainActor
final class ServerLogStore: ObservableObject {
    /// Больше не держим: старое уходит пачкой, чтобы не резать на каждом событии.
    static let limit = 50_000

    @Published private(set) var entries: [ServerLogEntry] = []
    /// В выводе были события лога, а не только текст процесса. Переживает
    /// очистку и перезапуск той же цели — иначе пока идёт `dotnet build`,
    /// консоль прыгала бы на сырой вывод и обратно.
    @Published private(set) var isStructured = false
    /// Вызовы логгера в коде проекта — куда ведёт двойной клик по событию.
    /// Собираются заново при каждом запуске: код между запусками меняется.
    @Published private(set) var sites = LogSites([])
    private var sitesGeneration = 0

    func scanSites(root: URL) {
        sitesGeneration += 1
        let generation = sitesGeneration
        Task.detached(priority: .utility) {
            let found = LogSites.scan(root: root)
            await MainActor.run { [weak self] in
                guard let self, self.sitesGeneration == generation else { return }
                self.sites = found
            }
        }
    }

    func add(_ new: [ServerLogEntry]) {
        guard !new.isEmpty else { return }
        var list = entries
        for entry in new {
            // Текстовое событие дополнилось стеком — приходит ещё раз с тем же номером.
            if list.last?.id == entry.id { list[list.count - 1] = entry } else { list.append(entry) }
        }
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit * 3 / 4) }
        entries = list
        if !isStructured, new.contains(where: { $0.level != .output }) { isStructured = true }
    }

    func clear() {
        entries = []
    }

    /// Запускаем другую цель: что она пишет, ещё неизвестно.
    func reset() {
        entries = []
        isStructured = false
    }
}

/// Вывод запущенной программы: текст как есть (`RunLog`) и он же событиями
/// лога (`ServerLogStore`). Свой у ▶ и у отладки, а разбор и вид
/// (`ProgramOutputView`) — одни: под отладчиком лог выглядит так же.
@MainActor
final class ProgramOutput {
    let log = RunLog()
    let serverLog = ServerLogStore()

    private var decoder = ConsoleDecoder()
    private var parser = ServerLogParser()
    /// Что запускали последним — перезапуск того же не сбрасывает вид.
    private var target: String?
    /// Запуск идёт, итога ещё не было.
    private var isOpen = false

    /// Вывод копится в фоне и уходит на главный поток пачками: при
    /// сотне строк в секунду по одной задаче на кусок интерфейс бы встал.
    private let lock = NSLock()
    nonisolated(unsafe) private var queue: [Data] = []
    nonisolated(unsafe) private var flushScheduled = false

    /// Новый запуск: прежний вывод уходит, первой строкой — команда.
    /// У той же цели события очищаются, но консоль остаётся логом, а не
    /// прыгает на сырой вывод, пока идёт сборка (см. `ServerLogStore`).
    func begin(_ target: String, command: String, root: URL) {
        if target != self.target { serverLog.reset() } else { serverLog.clear() }
        self.target = target
        lock.withLock { queue = [] }
        decoder = ConsoleDecoder()
        parser = ServerLogParser()
        serverLog.scanSites(root: root)
        log.clear()
        log.append("▶ \(command)\n\n")
        isOpen = true
    }

    /// Кусок вывода — с любого потока.
    nonisolated func enqueue(_ data: Data) {
        lock.lock()
        queue.append(data)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let chunks = queue
        queue = []
        flushScheduled = false
        lock.unlock()
        guard !chunks.isEmpty else { return }
        var data = Data()
        chunks.forEach { data.append($0) }
        let text = decoder.feed(data)
        log.append(text)
        serverLog.add(parser.feed(text))
    }

    /// Программа кончилась: недописанное — наружу, последней строкой — итог.
    /// Итог у запуска один: второй раз ничего не пишет.
    func end(_ note: String) {
        guard isOpen else { return }
        isOpen = false
        flush()
        serverLog.add(parser.finish())
        log.append("\n■ \(note)\n")
    }

    /// 🗑: и текст, и события.
    func clear() {
        log.clear()
        serverLog.clear()
    }

    /// Итог по коду выхода; для убитого сигналом код — 128 + сигнал, как у shell.
    static func exitNote(_ code: Int32) -> String {
        if code == 0 { return L("Завершилось") }
        if code > 128 { return L("Завершилось сигналом \(code - 128)") }
        return L("Завершилось с кодом \(code)")
    }
}

/// Кнопка ▶: что в проекте можно запустить, что запущено сейчас и его вывод.
@MainActor
final class RunService: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case stopping
        /// Код выхода; для убитого сигналом — 128 + сигнал.
        case exited(Int32)
        case failed(String)
    }

    @Published private(set) var targets: [RunTarget] = []
    @Published private(set) var selected: RunTarget?
    @Published private(set) var state: State = .idle
    /// Что запущено или запускалось последним — консоль подписана им.
    @Published private(set) var current: RunTarget?
    @Published var showsConsole = false

    /// Вывод цели: текст и события лога.
    let output = ProgramOutput()

    private var root: URL?
    private var process: RunProcess?
    /// ▶ во время работы — перезапуск: сначала дождаться выхода старого.
    private var restartPending = false
    private var scanGeneration = 0

    var isRunning: Bool { state == .running || state == .stopping }

    private static let selectionKey = "pilot.run.selected"

    // MARK: - Проект

    func workspaceChanged(to root: URL?) {
        if let process, process.isRunning {
            restartPending = false
            process.stop()
        }
        self.root = root
        targets = []
        selected = nil
        refresh()
    }

    /// Список целей заново: открыли проект, поменяли .csproj или run.json.
    func refresh() {
        scanGeneration += 1
        let generation = scanGeneration
        guard let root else { return }
        Task.detached(priority: .utility) {
            let found = RunTargets.discover(root: root)
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.targets = found
                let remembered = self.rememberedSelection()
                self.selected = found.first { $0.name == (self.selected?.name ?? remembered) } ?? found.first
            }
        }
    }

    func select(_ target: RunTarget) {
        selected = target
        guard let root else { return }
        var saved = UserDefaults.standard.dictionary(forKey: Self.selectionKey) as? [String: String] ?? [:]
        saved[root.path] = target.name
        UserDefaults.standard.set(saved, forKey: Self.selectionKey)
    }

    private func rememberedSelection() -> String? {
        guard let root else { return nil }
        return (UserDefaults.standard.dictionary(forKey: Self.selectionKey) as? [String: String])?[root.path]
    }

    // MARK: - Запуск

    /// ▶: запустить выбранное; если что-то уже работает — перезапустить.
    func run() {
        guard selected != nil, root != nil else { return }
        showsConsole = true
        if let process, process.isRunning {
            restartPending = true
            state = .stopping
            process.stop()
            return
        }
        launch()
    }

    func stop() {
        restartPending = false
        guard let process, process.isRunning else { return }
        state = .stopping
        process.stop()
    }

    private func launch() {
        guard let target = selected, let root else { return }
        current = target
        output.begin(target.name, command: target.command, root: root)
        let directory = target.directory.isEmpty ? root : root.appendingPathComponent(target.directory)
        let output = self.output
        do {
            process = try RunProcess.start(
                command: target.command, directory: directory, environment: target.environment,
                onOutput: { data in output.enqueue(data) },
                onExit: { [weak self] code in
                    Task { @MainActor in self?.exited(code) }
                })
            state = .running
        } catch {
            process = nil
            state = .failed(error.localizedDescription)
            output.end(L("Не запустилось: \(error.localizedDescription)"))
        }
    }

    private func exited(_ code: Int32) {
        process = nil
        let wasStopped = state == .stopping
        state = .exited(code)
        output.end(wasStopped ? L("Остановлено") : ProgramOutput.exitNote(code))
        if restartPending {
            restartPending = false
            launch()
        }
    }

    /// 🗑 в консоли: и текст, и события.
    func clearOutput() {
        output.clear()
    }
}
