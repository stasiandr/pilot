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

    let log = RunLog()

    private var root: URL?
    private var process: RunProcess?
    /// ▶ во время работы — перезапуск: сначала дождаться выхода старого.
    private var restartPending = false
    private var decoder = ConsoleDecoder()
    private var scanGeneration = 0

    /// Вывод копится в фоне и уходит на главный поток пачками: при
    /// сотне строк в секунду по одной задаче на кусок интерфейс бы встал.
    private let outputLock = NSLock()
    nonisolated(unsafe) private var outputQueue: [Data] = []
    nonisolated(unsafe) private var flushScheduled = false

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
        decoder = ConsoleDecoder()
        log.clear()
        let directory = target.directory.isEmpty ? root : root.appendingPathComponent(target.directory)
        log.append("▶ \(target.command)\n\n")
        do {
            process = try RunProcess.start(
                command: target.command, directory: directory, environment: target.environment,
                onOutput: { [weak self] data in self?.enqueue(data) },
                onExit: { [weak self] code in
                    Task { @MainActor in self?.exited(code) }
                })
            state = .running
        } catch {
            process = nil
            state = .failed(error.localizedDescription)
            log.append("Не запустилось: \(error.localizedDescription)\n")
        }
    }

    private func exited(_ code: Int32) {
        flush()
        process = nil
        let wasStopped = state == .stopping
        state = .exited(code)
        let note: String
        if wasStopped {
            note = "Остановлено"
        } else if code == 0 {
            note = "Завершилось"
        } else if code > 128 {
            note = "Завершилось сигналом \(code - 128)"
        } else {
            note = "Завершилось с кодом \(code)"
        }
        log.append("\n■ \(note)\n")
        if restartPending {
            restartPending = false
            launch()
        }
    }

    // MARK: - Вывод

    nonisolated private func enqueue(_ data: Data) {
        outputLock.lock()
        outputQueue.append(data)
        let schedule = !flushScheduled
        flushScheduled = true
        outputLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        outputLock.lock()
        let chunks = outputQueue
        outputQueue = []
        flushScheduled = false
        outputLock.unlock()
        guard !chunks.isEmpty else { return }
        var data = Data()
        chunks.forEach { data.append($0) }
        log.append(decoder.feed(data))
    }
}
