import AppKit
import Combine

/// Замеры в настоящем окне — `PILOT_PERF=ui`, их запускает `bin/pilot-perf`.
///
/// Pilot под своим идентификатором бандла, скрытый и не активный (клавиши
/// и окно пользователя он не трогает), открывает проект и по очереди
/// проходит сценарии из файла `PILOT_PERF_CONFIG`:
///
/// * `open` — открытие проекта с кэшами: когда готов каждый индекс, когда
///   откомпилировано, сколько за это время занят главный поток и как надолго
///   он застревал;
/// * `idle` — окно просто открыто: сколько раз в секунду просыпается главный
///   поток и сколько процессора уходит впустую;
/// * `palette` — ⌘P и набор по букве: работа главного потока на букву,
///   сколько раз будили всё окно (`Workspace.objectWillChange`) и сколько раз
///   писали в UserDefaults — и то и другое перерисовывает всё приложение;
/// * `editor` — набор в C#-файле, то же на букву;
/// * `files` — переходы по файлам: первое открытие и возврат на вкладку;
/// * `stability` — как CLS в вебе: сколько после первого кадра файл
///   сдвигался и перекрашивался, и не осталась ли подсветка неверной
///   (см. EditorStability).
///
/// Строка JSON на сценарий — в `PILOT_PERF_OUT` (см. PerfReport). Скрытое окно
/// не рисуется, поэтому числа меньше того, что видит пользователь:
/// сравнивать сборки, а не абсолютные значения.
@MainActor
enum PerfUI {
    static var isRequested: Bool { PerfConfig.mode == "ui" }

    static func start() {
        guard let config = PerfConfig.load() else { exit(2) }
        MainThreadMonitor.shared.install()
        // Скрытое приложение macOS усыпляет (App Nap: таймеры реже,
        // приоритет ниже) и может закрыть само — а мерить надо как у
        // приложения, с которым работают.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Pilot perf")
        ProcessInfo.processInfo.disableAutomaticTermination("Pilot perf")
        Task { @MainActor in
            let code = await run(config)
            withExtendedLifetime(activity) {}
            exit(code)
        }
    }

    private static let monitor = MainThreadMonitor.shared

    private static func run(_ config: PerfConfig) async -> Int32 {
        guard let workspace = await open(config) else { return 1 }
        if PerfConfig.wants("idle") { await idle(config) }
        if PerfConfig.wants("palette"), let palette = config.palette {
            guard await typeInPalette(palette, workspace: workspace) else { return 1 }
        }
        if PerfConfig.wants("editor"), let editor = config.editor {
            guard await typeInEditor(editor, config: config, workspace: workspace) else { return 1 }
        }
        if PerfConfig.wants("files"), let files = config.files, !files.isEmpty {
            guard await switchFiles(files, config: config, workspace: workspace) else { return 1 }
        }
        if PerfConfig.wants("stability"), let files = config.stability, !files.isEmpty {
            guard await stability(files, config: config, workspace: workspace) else { return 1 }
        }
        return 0
    }

    // MARK: - Открытие

    private static func open(_ config: PerfConfig) async -> Workspace? {
        guard await wait("первое окно", timeout: 60, {
            ProjectWindows.shared.workspaces.contains { $0.window != nil }
        }) else { return nil }
        // Запуск отработал своё — теперь только проект.
        await sleep(1000)

        monitor.resetLongest()
        let start = monitor.mark()
        let began = PerfCounters.now()
        var reached: [String: Double] = [:]
        func mark(_ milestone: String) {
            if reached[milestone] == nil { reached[milestone] = Double(PerfCounters.now() - began) / 1e6 }
        }

        // Как «Открыть папку…» в пустом окне, только без `bringToFront`.
        guard let workspace = ProjectWindows.shared.workspaces.first(where: { $0.root == nil && $0.window != nil }) else {
            PerfReport.log("нет пустого окна, чтобы открыть \(config.project)")
            return nil
        }
        workspace.open(root: config.root)
        // Всё, что публикует воркспейс, — в момент публикации, без опроса.
        var watching: [AnyCancellable] = []
        var compiling = false
        watching.append(workspace.$fileCount.sink { if $0 > 0 { mark("files") } })
        watching.append(workspace.$isIndexing.sink { if !$0 { mark("index") } })
        watching.append(workspace.$symbolIndex.sink { if $0 != nil { mark("symbols") } })
        watching.append(workspace.$isTypeIndexing.sink { if !$0 { mark("types") } })
        watching.append(workspace.$compiler.sink { state in
            switch state {
            case .compiling: compiling = true
            case .ready:
                mark("compiler")
                if compiling { mark("compiled") }
            case .idle: break
            }
        })
        let unity = workspace.unity.project != nil
        watching.append(workspace.unity.$isIndexingAssets.sink { indexing in
            if !indexing, workspace.unity.assets != nil { mark("unity") }
        })
        let needed = ["files", "index", "symbols", "types", "compiled"] + (unity ? ["unity"] : [])
        let ready = await wait("индексы и компиляция", timeout: 600) {
            needed.allSatisfy { reached[$0] != nil }
        }
        // Затих — значит, всё, что открытие запустило, отработало.
        let settled = await quiet(window: 1000, share: 0.1, timeout: 240).map { Double($0 - began) / 1e6 }
        withExtendedLifetime(watching) {}
        let span = monitor.since(start)

        var metrics: [String: Double] = [
            "open.main.busy.ms": span.busyMs,
            "open.main.minstr": span.mainInstructions,
            "open.main.longest.ms": span.longestMs,
            "open.main.stalls.n": Double(span.stalls),
            "open.minstr": span.instructions,
            "open.cpu.ms": span.cpuMs,
            "open.peak.mb": .mb(span.peakFootprint),
            "open.written.mb": .mb(span.bytesWritten),
        ]
        for (milestone, ms) in reached { metrics["open.\(milestone).ms"] = ms }
        if let settled { metrics["open.settled.ms"] = settled }
        PerfReport.emit("open", metrics, info: [
            "files": "\(workspace.fileCount)", "types": "\(workspace.typeCount)",
            "symbols": "\(workspace.symbolIndex?.count ?? 0)", "ready": "\(ready)",
            "longest.at.ms": String(format: "%.0f", span.longestAtMs),
            "compiled": {
                if case .ready(let compiled) = workspace.compiler { return "\(compiled.files) files" }
                return "no"
            }(),
        ])
        return ready ? workspace : nil
    }

    // MARK: - Простой

    /// Кусками по 3 с, в отчёт — медиана куска: всплеск от чужой активности
    /// (события ФС от Unity, git) задевает кусок-другой и в медиану не
    /// попадает, а всё, что повторяется чаще раза в 3 с, — попадает.
    private static func idle(_ config: PerfConfig) async {
        let seconds = config.idleSeconds ?? 24
        let piece = 3.0
        var wakeups: [Double] = [], main: [Double] = [], busy: [Double] = [], all: [Double] = [], cpu: [Double] = []
        for _ in 0..<max(1, Int(seconds / piece)) {
            let start = monitor.mark()
            await sleep(piece * 1000)
            let span = monitor.since(start)
            wakeups.append(Double(span.iterations))
            main.append(span.mainInstructions)
            busy.append(span.busyMs)
            all.append(span.instructions)
            cpu.append(span.cpuMs)
        }
        PerfReport.emit("idle", [
            "idle.main.wakeups.n": PerfReport.median(wakeups),
            "idle.main.busy.ms": PerfReport.median(busy),
            "idle.main.minstr": PerfReport.median(main),
            "idle.minstr": PerfReport.median(all),
            "idle.cpu.ms": PerfReport.median(cpu),
        ], info: ["seconds": "\(seconds)", "piece": "\(piece)"])
    }

    /// Процесс затих после действия: за последние `window` мс он занимал
    /// меньше `share` одного ядра. Всё, что действие запустило следом
    /// (компиляция, диагностика, подсветка, вхождения), к этому времени
    /// отработало, сколько бы оно ни шло, — замер не зависит от того,
    /// успело ли оно за фиксированную паузу. Возвращает, когда началась
    /// тихая полоса; nil — так и не затих.
    @discardableResult
    private static func quiet(window: Double = 300, share: Double = 0.2, timeout: Double = 15) async -> UInt64? {
        let deadline = PerfCounters.now() + UInt64(timeout * 1e9)
        let span = UInt64(window * 1e6)
        var samples: [(time: UInt64, cpu: UInt64)] = []
        while PerfCounters.now() < deadline {
            let now = PerfCounters.now()
            samples.append((now, PerfCounters.process().cpu))
            samples.removeAll { now - $0.time > span + span / 5 }
            if let first = samples.first, now - first.time >= span,
               Double(samples.last!.cpu - first.cpu) < share * Double(now - first.time) {
                return first.time
            }
            await sleep(min(100, window / 10))
        }
        PerfReport.log("процесс не затих за \(Int(timeout)) с")
        return nil
    }

    // MARK: - Набор

    /// Кто будит всё окно, пока печатают. UserDefaults сообщает о записи
    /// на том потоке, который писал, — поэтому счётчики под замком.
    private final class Wakes: @unchecked Sendable {
        private let lock = NSLock()
        private var counts = (workspace: 0, defaults: 0)
        private var watching: [Any] = []

        var workspace: Int { lock.withLock { counts.workspace } }
        var defaults: Int { lock.withLock { counts.defaults } }

        @MainActor
        init(_ ws: Workspace) {
            watching.append(ws.objectWillChange.sink { [unowned self] _ in
                self.lock.withLock { self.counts.workspace += 1 }
            })
            watching.append(NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: nil
            ) { [unowned self] _ in
                self.lock.withLock { self.counts.defaults += 1 }
            })
        }

        @MainActor
        func stop() {
            for item in watching where !(item is AnyCancellable) { NotificationCenter.default.removeObserver(item) }
            watching = []
        }
    }

    /// Итог набора: по букве — среднее, по раунду — медиана.
    private struct Typing {
        var keyInstructions: [Double] = []
        var keyBusy: [Double] = []
        var roundMaxBusy: [Double] = []
        var roundInstructions: [Double] = []
        var roundDone: [Double] = []
        var wakes: [Double] = []
        var writes: [Double] = []

        func metrics(_ prefix: String) -> [String: Double] {
            var result: [String: Double] = [
                "\(prefix).key.main.minstr": PerfReport.mean(keyInstructions),
                "\(prefix).key.busy.ms": PerfReport.mean(keyBusy),
                "\(prefix).key.max.ms": PerfReport.median(roundMaxBusy),
                "\(prefix).round.minstr": PerfReport.median(roundInstructions),
                "\(prefix).wakes.n": PerfReport.median(wakes),
                "\(prefix).defaults.n": PerfReport.median(writes),
            ]
            if !roundDone.isEmpty { result["\(prefix).done.ms"] = PerfReport.median(roundDone) }
            return result
        }
    }

    /// Буква за буквой с паузой `interval`; `current` — что сейчас в поле,
    /// по нему видно, дошла ли буква.
    private static func type(_ text: String, into window: NSWindow, interval: Double, typing: inout Typing,
                             current: () -> String) async -> Bool {
        var maxBusy = 0.0
        var viaApp = true
        for character in text {
            let s = String(character)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: s, charactersIgnoringModifiers: s,
                                               isARepeat: false, keyCode: 0) else { return false }
            let before = current()
            let key = monitor.mark()
            if viaApp {
                NSApp.sendEvent(event)
                // Неактивному приложению AppKit клавишу может не отдать —
                // тогда дальше прямо окну.
                if current() == before { viaApp = false }
            }
            if !viaApp {
                _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
                window.sendEvent(event)
            }
            if current() == before {
                PerfReport.log("буква «\(s)» не дошла до поля")
                return false
            }
            await sleep(interval)
            let span = monitor.since(key)
            typing.keyInstructions.append(span.mainInstructions)
            typing.keyBusy.append(span.busyMs)
            maxBusy = max(maxBusy, span.busyMs)
        }
        typing.roundMaxBusy.append(maxBusy)
        return true
    }

    private static func typeInPalette(_ palette: PerfConfig.Palette, workspace: Workspace) async -> Bool {
        var typing = Typing()
        for _ in 1...(palette.rounds ?? 3) {
            workspace.isPaletteOpen = false
            await sleep(400)
            workspace.openSearch(.everything)
            guard await wait("поле палитры", timeout: 10, { PaletteQueryField.Field.current?.window != nil }),
                  let field = PaletteQueryField.Field.current, let window = field.window else { return false }
            window.makeFirstResponder(field)
            await sleep(400)
            let wakes = Wakes(workspace)
            let round = monitor.mark()
            guard await type(palette.text, into: window, interval: palette.intervalMs ?? 150, typing: &typing,
                             current: { field.stringValue }) else { return false }
            let typed = PerfCounters.now()
            // Выдача готова: все источники ответили на последний запрос.
            _ = await wait("выдача палитры", timeout: 20, pollMs: 10) {
                workspace.palette.query == palette.text && !workspace.palette.busy
            }
            typing.roundDone.append(Double(PerfCounters.now() - typed) / 1e6)
            await sleep(300)
            typing.roundInstructions.append(monitor.since(round).instructions)
            wakes.stop()
            typing.wakes.append(Double(wakes.workspace))
            typing.writes.append(Double(wakes.defaults))
        }
        workspace.isPaletteOpen = false
        await sleep(400)
        PerfReport.emit("palette", typing.metrics("palette"), info: [
            "text": palette.text, "items": "\(workspace.items.count)",
        ])
        return true
    }

    private static func typeInEditor(_ editor: PerfConfig.Editor, config: PerfConfig,
                                     workspace: Workspace) async -> Bool {
        let url = config.url(editor.file)
        let place = LSPPosition(line: editor.line - 1, character: editor.column - 1)
        workspace.navigate(to: NavTarget(url: url, range: LSPRange(start: place, end: place)))
        guard await wait("файл в редакторе", timeout: 30, { workspace.buffer?.url.path == url.path }),
              let buffer = workspace.buffer else { return false }
        // Подсветка, структура, диагностика открытого файла.
        await sleep(2000)
        guard let window = workspace.window,
              let textView = codeTextView(in: window.contentView, storage: buffer.storage) else {
            PerfReport.log("не нашёл редактор с \(editor.file)")
            return false
        }
        let original = buffer.storage.string
        var typing = Typing()
        for _ in 1...(editor.rounds ?? 2) {
            window.makeFirstResponder(textView)
            let offset = buffer.model.offset(at: place)
            textView.setSelectedRange(NSRange(location: offset, length: 0))
            await sleep(300)
            let wakes = Wakes(workspace)
            let round = monitor.mark()
            guard await type(editor.text, into: window, interval: editor.intervalMs ?? 120, typing: &typing,
                             current: { textView.string }) else { return false }
            // То, что Pilot делает после набора: диагностика, подсказки в строках.
            await sleep(500)
            await quiet()
            typing.roundInstructions.append(monitor.since(round).instructions)
            wakes.stop()
            typing.wakes.append(Double(wakes.workspace))
            typing.writes.append(Double(wakes.defaults))
            // Набранное — обратно, вне замера: следующий раунд с того же текста.
            let typed = NSRange(location: offset, length: (editor.text as NSString).length)
            if textView.shouldChangeText(in: typed, replacementString: "") {
                textView.replaceCharacters(in: typed, with: "")
                textView.didChangeText()
            }
            await sleep(1000)
        }
        if buffer.storage.string != original {
            PerfReport.log("текст \(editor.file) после набора не вернулся к исходному")
        }
        PerfReport.emit("editor", typing.metrics("editor"), info: [
            "file": editor.file, "text": editor.text, "lines": "\(buffer.model.lineCount)",
        ])
        return true
    }

    private static func codeTextView(in view: NSView?, storage: NSTextStorage) -> CodeTextView? {
        guard let view else { return nil }
        if let text = view as? CodeTextView, text.textStorage === storage { return text }
        for sub in view.subviews {
            if let found = codeTextView(in: sub, storage: storage) { return found }
        }
        return nil
    }

    // MARK: - Переходы по файлам

    private static func switchFiles(_ files: [String], config: PerfConfig, workspace: Workspace) async -> Bool {
        var metrics: [String: Double] = [:]
        // Первый проход открывает файлы, второй — возвращается на вкладки.
        for pass in ["open", "tab"] {
            var shown: [Double] = [], main: [Double] = [], all: [Double] = [], longest: [Double] = []
            for relative in files {
                let url = config.url(relative)
                monitor.resetLongest()
                let start = monitor.mark()
                workspace.navigate(to: NavTarget(url: url, range: nil))
                guard await wait("вкладка \(relative)", timeout: 20, pollMs: 5, {
                    workspace.buffer?.url.path == url.path
                }) else { return false }
                shown.append(monitor.since(start).wallMs)
                // Подсветка, вхождения, свёртки, диагностика — то, что приходит следом.
                await sleep(200)
                await quiet()
                let span = monitor.since(start)
                main.append(span.mainInstructions)
                all.append(span.instructions)
                longest.append(span.longestMs)
            }
            metrics["files.\(pass).ms"] = PerfReport.mean(shown)
            metrics["files.\(pass).main.minstr"] = PerfReport.mean(main)
            metrics["files.\(pass).minstr"] = PerfReport.mean(all)
            metrics["files.\(pass).longest.ms"] = longest.max() ?? 0
        }
        PerfReport.emit("files", metrics, info: ["files": "\(files.count)"])
        return true
    }

    // MARK: - Стабильность открытия

    private static func stability(_ files: [String], config: PerfConfig, workspace: Workspace) async -> Bool {
        guard let probe = EditorStability.shared else { return false }
        probe.isArmed = true
        defer { probe.isArmed = false }
        var metrics: [String: Double] = [:]
        var info: [String: String] = [:]
        // Первый проход открывает файлы, второй — возвращается на вкладки.
        for pass in ["open", "tab"] {
            var reports: [EditorStability.Report] = []
            for entry in files {
                var relative = entry
                var range: LSPRange?
                if let colon = entry.lastIndex(of: ":"), let line = Int(entry[entry.index(after: colon)...]) {
                    relative = String(entry[..<colon])
                    let place = LSPPosition(line: line - 1, character: 0)
                    if pass == "open" { range = LSPRange(start: place, end: place) }
                }
                let url = config.url(relative)
                workspace.navigate(to: NavTarget(url: url, range: range))
                guard await wait("вкладка \(relative)", timeout: 20, pollMs: 5, {
                    workspace.buffer?.url.path == url.path && probe.quietMs != nil
                }) else { return false }
                // Всё, что открытие запустило следом, — диагностика, подсказки,
                // счётчики с поиском по проекту, — должно дойти до экрана.
                _ = await wait("экран \(relative) успокоился", timeout: 30, pollMs: 50) { (probe.quietMs ?? 0) > 1500 }
                await quiet(window: 500, share: 0.2, timeout: 30)
                _ = await wait("экран \(relative) успокоился", timeout: 30, pollMs: 50) { (probe.quietMs ?? 0) > 1500 }
                let report = probe.finish()
                PerfReport.log("[\(pass)] " + report.summary)
                reports.append(report)
            }
            func total(_ value: (EditorStability.Report) -> Double) -> Double { reports.reduce(0) { $0 + value($1) } }
            metrics["stability.\(pass).shift.score"] = total(\.shiftScore)
            metrics["stability.\(pass).shifts.n"] = total { Double($0.shifts) }
            metrics["stability.\(pass).recolored.n"] = total { Double($0.recoloredChars) }
            metrics["stability.\(pass).lens.n"] = total { Double($0.lensChanges) }
            metrics["stability.\(pass).wrong.n"] = total { Double($0.wrongChars) }
            metrics["stability.\(pass).first.ms"] = PerfReport.mean(reports.map(\.firstMs))
            metrics["stability.\(pass).settled.ms"] = PerfReport.mean(reports.map(\.settledMs))
            info["\(pass).chars"] = "\(Int(total { Double($0.chars) }))"
        }
        PerfReport.emit("stability", metrics, info: info.merging(["files": "\(files.count)"]) { a, _ in a })
        return true
    }

    // MARK: - Ожидание

    private static func sleep(_ ms: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
    }

    private static func wait(_ what: String, timeout: Double, pollMs: Double = 20,
                             _ ready: () -> Bool) async -> Bool {
        let deadline = PerfCounters.now() + UInt64(timeout * 1e9)
        while !ready() {
            if PerfCounters.now() > deadline {
                PerfReport.log("не дождался: \(what) (\(Int(timeout)) с)")
                return false
            }
            await sleep(pollMs)
        }
        return true
    }
}
