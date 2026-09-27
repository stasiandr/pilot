import Foundation

/// Прогоны генераторов Unity одного окна: по одному за раз, по кнопке и заранее.
///
/// Прогон `Assembly-CSharp` — почти минута, поэтому кнопка его не ждёт:
/// показывает то, что уже лежит на диске, а обновление идёт следом. Заранее —
/// после открытия проекта, после каждой компиляции Unity и когда Unity,
/// закрываясь, стёрла `Temp` — обновляются сборки открытых файлов, фоном
/// (`PRIO_DARWIN_BG`): ни Pilot, ни Unity они не теснят. Попросит человек ту
/// же сборку — прогон переходит на обычный приоритет; другую — фоновый
/// уступает место и встаёт в очередь заново.
@MainActor
final class UnityGeneratorRuns {
    enum Priority: Int, Comparable {
        /// Заранее: никто не ждёт.
        case background
        /// По кнопке, пока в палитре прежний вывод.
        case refresh
        /// По кнопке, и показать пока нечего.
        case waiting

        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    typealias Outcome = Result<UnityGenerators.Output, UnityGenerators.Failure>
    typealias Completion = (Outcome) -> Void

    private struct Job {
        let rsp: URL
        var priority: Priority
        var completions: [Completion]
    }

    private struct Current {
        let rsp: URL
        var priority: Priority
        let run: UnityGenerators.Run
        var completions: [Completion]
    }

    /// Что сейчас в палитре «Сгенерированный код». Номер — чтобы ответ,
    /// пришедший поздно, не лёг в палитру, открытую уже для другого файла.
    struct Shown {
        let id: Int
        let types: Set<String>
        var rsp: URL?
        /// Что показано: не обновится — остаётся оно, а не пустота.
        var snapshot: UnityGenerators.Snapshot?
        var files: [String] = []
    }
    var shown: Shown?
    private var shownCounter = 0

    /// Фон ждёт, пока в `Library/Bee` столько секунд тихо: Unity докомпилировала.
    static let quiet: TimeInterval = 20
    /// Через сколько проверить снова, если занят сам Pilot.
    static let retry: TimeInterval = 10
    /// Сколько сборок обновлять заранее за раз: большая — минута процессора.
    static let limit = 4

    private(set) var project: UnityProjectInfo?
    private var jobs: [Job] = []
    private var current: Current?
    /// Он же — для `deinit`: окно закрыли, компилятор больше не нужен.
    nonisolated(unsafe) private var running: UnityGenerators.Run?
    private var generation = 0
    private let queue = DispatchQueue(label: "pilot.generators", qos: .utility)

    /// Последнее событие в `Library/Bee`: пока они идут, Unity компилирует.
    private var lastBee: Date?
    /// Сборки, о которых спрашивали по кнопке, — последние первыми.
    private var asked: [URL] = []
    private var planTimer: DispatchWorkItem?
    private var startTimer: DispatchWorkItem?

    /// Компилирует ли сам Pilot: индексы, Rustlyn. Фон тогда ждёт.
    var isBusy: () -> Bool = { false }
    /// Файлы C#, с которыми работают: открытый и остальные вкладки.
    var workedIn: () -> [URL] = { [] }

    deinit { running?.cancel() }

    // MARK: - Проект

    func workspaceChanged(to project: UnityProjectInfo?) {
        generation += 1
        current?.run.cancel()
        current = nil
        running = nil
        jobs = []
        asked = []
        shown = nil
        lastBee = nil
        planTimer?.cancel()
        startTimer?.cancel()
        self.project = project
        // Первое обновление — после открытия: `plan` подождёт, пока Pilot
        // проиндексирует проект и Rustlyn его скомпилирует.
        if project != nil { planPrecompute(after: Self.quiet) }
    }

    func beginShowing(types: Set<String>) -> Int {
        shownCounter += 1
        shown = Shown(id: shownCounter, types: types)
        return shownCounter
    }

    // MARK: - Очередь

    /// Обновить вывод сборки из `rsp`. Такой прогон уже идёт или ждёт —
    /// `completion` дождётся его же, а приоритет у него станет не ниже `priority`.
    func request(_ rsp: URL, priority: Priority, completion: Completion? = nil) {
        guard project != nil else {
            completion?(.failure(UnityGenerators.Failure(message: L("Сгенерированный код есть только у Unity-проекта"))))
            return
        }
        if priority > .background {
            asked.removeAll { $0 == rsp }
            asked.insert(rsp, at: 0)
        }
        if var running = current, running.rsp == rsp {
            if let completion { running.completions.append(completion) }
            if priority > running.priority {
                running.priority = priority
                running.run.hurry()
            }
            current = running
            return
        }
        if let index = jobs.firstIndex(where: { $0.rsp == rsp }) {
            jobs[index].priority = max(jobs[index].priority, priority)
            if let completion { jobs[index].completions.append(completion) }
        } else {
            jobs.append(Job(rsp: rsp, priority: priority, completions: completion.map { [$0] } ?? []))
        }
        // Человек ждёт другую сборку — фоновый прогон уступает место. Когда
        // остановится, вернётся в очередь (`finished`).
        if priority > .background, let current, current.priority == .background {
            current.run.cancel()
        }
        startNext()
    }

    private func startNext() {
        startTimer?.cancel()
        guard current == nil, let project, !jobs.isEmpty else { return }
        // Самый срочный; среди равных — кто раньше встал в очередь.
        var index = 0
        for candidate in jobs.indices where jobs[candidate].priority > jobs[index].priority { index = candidate }
        let job = jobs[index]
        if job.priority == .background,
           let delay = UnityGenerators.backgroundDelay(now: Date(), lastBee: lastBee, busy: isBusy() || Self.constrained,
                                                       quiet: Self.quiet, retry: Self.retry) {
            startTimer = schedule(after: delay) { [weak self] in self?.startNext() }
            return
        }
        jobs.remove(at: index)
        guard let editor = project.editorContents else {
            let failure = UnityGenerators.Failure(message: L("Не найден редактор Unity \(project.editorVersion ?? "")"))
            job.completions.forEach { $0(.failure(failure)) }
            startNext()
            return
        }
        let run = UnityGenerators.Run(background: job.priority == .background)
        current = Current(rsp: job.rsp, priority: job.priority, run: run, completions: job.completions)
        running = run
        let root = project.root
        let rsp = job.rsp
        let generation = self.generation
        queue.async { [weak self] in
            let started = Date()
            var cancelled = false
            let outcome: Outcome
            do {
                outcome = .success(try UnityGenerators.refresh(rsp: rsp, project: root, editor: editor, run: run))
            } catch is UnityGenerators.Cancelled {
                cancelled = true
                outcome = .failure(UnityGenerators.Failure(message: ""))
            } catch let failure as UnityGenerators.Failure {
                outcome = .failure(failure)
            } catch {
                outcome = .failure(UnityGenerators.Failure(message: error.localizedDescription))
            }
            if case .success(let output) = outcome {
                NSLog("[generators] %@: %.1f с, изменилось файлов: %d",
                      output.assembly, Date().timeIntervalSince(started), output.changed)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finished(rsp, outcome, cancelled: cancelled, generation: generation)
                }
            }
        }
    }

    private func finished(_ rsp: URL, _ outcome: Outcome, cancelled: Bool, generation: Int) {
        guard generation == self.generation, let done = current, done.rsp == rsp else { return }
        current = nil
        running = nil
        if cancelled {
            // Уступил место прогону по кнопке — снова в очередь.
            if let index = jobs.firstIndex(where: { $0.rsp == rsp }) {
                jobs[index].priority = max(jobs[index].priority, done.priority)
                jobs[index].completions += done.completions
            } else {
                jobs.append(Job(rsp: rsp, priority: done.priority, completions: done.completions))
            }
        } else {
            done.completions.forEach { $0(outcome) }
        }
        startNext()
    }

    /// Машине и так тяжело: греется или бережёт батарею. Фон тогда ждёт.
    private static var constrained: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return item
    }

    // MARK: - Заранее

    /// События ФС: Unity компилировала сборку (её `.dll` или `.rsp` в графе
    /// Bee) или стёрла вывод (закрываясь, она удаляет `Temp`) — пора решить,
    /// что обновить. Сам Pilot папку сборки не удаляет никогда, только файлы
    /// в ней, так что от своих же записей это не сработает.
    func noticed(_ events: [FileEvent]) {
        guard let project else { return }
        var bee = false
        var compiled = false
        var touched = Set<String>()
        for event in events {
            if event.path.contains("/Library/Bee/") {
                bee = true
                if !compiled, UnityGenerators.recompiledAssembly(event.path) != nil { compiled = true }
            } else if event.structural, let assembly = UnityGenerators.outputAssembly(event.path) {
                touched.insert(assembly)
            }
        }
        if bee { lastBee = Date() }
        let wiped = touched.contains {
            !FileManager.default.fileExists(atPath: UnityGenerators.outputFolder(assembly: $0, project: project.root).path)
        }
        if compiled || wiped { planPrecompute(after: Self.quiet) }
    }

    /// Через `delay` решить, какие сборки обновить заранее.
    func planPrecompute(after delay: TimeInterval) {
        planTimer?.cancel()
        planTimer = schedule(after: delay) { [weak self] in self?.plan() }
    }

    /// Сборки, о которых спрашивали, и сборки открытых файлов (без них —
    /// `Assembly-CSharp`): чей вывод устарел или которого нет — в очередь,
    /// фоном. Пока компилирует Pilot или Unity, решение откладывается.
    private func plan() {
        guard let project else { return }
        if let delay = UnityGenerators.backgroundDelay(now: Date(), lastBee: lastBee, busy: isBusy() || Self.constrained,
                                                       quiet: Self.quiet, retry: Self.retry) {
            planPrecompute(after: delay)
            return
        }
        let root = project.root
        let files = workedIn()
        let asked = self.asked
        let limit = Self.limit
        let generation = self.generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let prefix = root.standardizedFileURL.path + "/"
            let relPaths = files.map(\.standardizedFileURL.path)
                .filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
            let found = UnityGenerators.responseFiles(for: relPaths, project: root)
            var candidates = asked + relPaths.compactMap { found[$0] }
            if candidates.isEmpty,
               let main = UnityGenerators.responseFile(assembly: "Assembly-CSharp", project: root) {
                candidates = [main]
            }
            let stale = UnityGenerators.precomputeOrder(candidates, limit: limit).filter {
                UnityGenerators.snapshot(rsp: $0, project: root).freshness != .fresh
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    for rsp in stale { self.request(rsp, priority: .background) }
                }
            }
        }
    }
}
