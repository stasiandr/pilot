// Лаунчер Pilot: открывает Pilot, собранный из того, что сейчас на диске.
//
// Его, а не Pilot.app, открывают hop, Dock и Finder. Он сравнивает отпечаток
// исходников (bin/source-stamp) с тем, что build.sh записал в бандл:
// совпал — сразу открывает Pilot, нет — показывает окно с ходом сборки,
// собирает и открывает свежий. Папки и файлы, которые ему передали, уходят
// в Pilot как есть.
//
// Pilot уже запущен — лаунчер его только активирует: пересобрать значило бы
// закрыть открытый проект посреди работы. Свежая сборка подхватится при
// следующем запуске.
//
// Собирается build-launcher.sh; путь к репозиторию он кладёт в Info.plist.

import AppKit

let pilotBundleID = "dev.local.pilot"

final class Launcher: NSObject, NSApplicationDelegate {

    let repo: URL
    var pilotApp: URL { repo.appendingPathComponent("Pilot.app") }
    var log: URL { repo.appendingPathComponent(".build/launcher-build.log") }

    /// Что передали открыть: папки, файлы, pilot://-ссылки.
    var pending: [URL] = []
    var opened = false

    var build: Process?
    var started = Date()
    var lastLine = ""
    var output = ""

    var window: NSWindow?
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let primary = NSButton()
    let secondary = NSButton()
    var timer: Timer?

    override init() {
        let path = Bundle.main.object(forInfoDictionaryKey: "PilotRepo") as? String ?? ""
        repo = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        super.init()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if opened {
            open(urls)
        } else {
            pending.append(contentsOf: urls)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Документы, с которыми запустили, приходят сразу после запуска —
        // решаем со следующего оборота цикла, когда они уже здесь.
        DispatchQueue.main.async { self.decide() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        build?.terminate()
    }

    // MARK: - Решение

    func decide() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: pilotBundleID)
            .contains { $0.bundleURL?.resolvingSymlinksInPath().path == pilotApp.resolvingSymlinksInPath().path }
        if running {
            launchPilot()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let current = self.currentStamp()
            let built = (try? String(contentsOf: self.pilotApp.appendingPathComponent("Contents/Resources/SourceStamp"),
                                     encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if let current, current == built, FileManager.default.fileExists(atPath: self.pilotApp.path) {
                    self.launchPilot()
                } else {
                    self.startBuild(reason: built == nil ? "Pilot ещё не собран" : "Код изменился")
                }
            }
        }
    }

    func currentStamp() -> String? {
        let process = Process()
        process.executableURL = repo.appendingPathComponent("bin/source-stamp")
        process.arguments = ["release"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Сборка

    /// Сколько обычно идёт сборка — по прошлым, для полосы. Первая — наугад.
    var estimate: TimeInterval {
        let saved = UserDefaults.standard.double(forKey: "buildSeconds")
        return saved > 0 ? saved : 180
    }

    func startBuild(reason: String) {
        showWindow()
        title.stringValue = "\(reason) — собираю свежий Pilot"
        detail.stringValue = "Запускаю build.sh…"
        bar.isIndeterminate = false
        bar.doubleValue = 0
        primary.isHidden = true
        secondary.title = "Отмена"
        secondary.action = #selector(cancel)

        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: log)

        let process = Process()
        // Login-шелл — за PATH пользователя. Из Finder и hop приложение
        // получает голый /usr/bin:/bin, а .zshrc неинтерактивный шелл не
        // читает — поэтому cargo build-rust.sh ищет ещё и сам, а JDK берётся
        // по абсолютному пути.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec ./build.sh release"]
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            logHandle?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self.consume(text) }
        }
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? logHandle?.close()
                self.finished(status: process.terminationStatus, reason: process.terminationReason)
            }
        }
        started = Date()
        build = process
        do {
            try process.run()
        } catch {
            failed("Не запустился build.sh: \(error.localizedDescription)")
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func consume(_ text: String) {
        output += text
        if output.count > 200_000 { output = String(output.suffix(100_000)) }
        // Последняя непустая строка; прогресс cargo/swift перерисовывается через \r.
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let last = lines.last { lastLine = last }
        tick()
    }

    func tick() {
        let elapsed = Date().timeIntervalSince(started)
        // До оценки — линейно, дальше — медленно подползает к краю, не упираясь.
        let fraction = elapsed < estimate * 0.9
            ? elapsed / estimate
            : 0.9 + 0.09 * (1 - exp(-(elapsed - estimate * 0.9) / estimate))
        bar.doubleValue = fraction * 100
        let line = lastLine.count > 70 ? String(lastLine.prefix(70)) + "…" : lastLine
        detail.stringValue = "\(clock(elapsed)) из ~\(clock(estimate))   \(line)"
    }

    func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func finished(status: Int32, reason: Process.TerminationReason) {
        timer?.invalidate()
        build = nil
        if reason == .uncaughtSignal { return }  // Отмена.
        guard status == 0 else {
            let errors = output.split(separator: "\n")
                .filter { $0.contains("error:") || $0.contains("error[") || $0.contains("не найден") }
                .suffix(6)
                .joined(separator: "\n")
            failed(errors.isEmpty ? String(output.suffix(600)) : errors)
            return
        }
        // Среднее с прошлым: одна долгая сборка (cargo с нуля) не портит оценку.
        let took = Date().timeIntervalSince(started)
        let saved = UserDefaults.standard.double(forKey: "buildSeconds")
        UserDefaults.standard.set(saved > 0 ? (saved + took) / 2 : took, forKey: "buildSeconds")
        bar.doubleValue = 100
        launchPilot()
    }

    func failed(_ message: String) {
        showWindow()
        title.stringValue = "Pilot не собрался"
        detail.stringValue = message
        detail.maximumNumberOfLines = 8
        detail.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.isSelectable = true
        bar.isHidden = true
        primary.isHidden = false
        primary.title = "Открыть лог"
        primary.action = #selector(openLog)
        if FileManager.default.fileExists(atPath: pilotApp.appendingPathComponent("Contents/MacOS/Pilot").path) {
            secondary.title = "Открыть прежнюю сборку"
            secondary.action = #selector(openOld)
        } else {
            secondary.title = "Закрыть"
            secondary.action = #selector(cancel)
        }
        window?.setContentSize(NSSize(width: 520, height: 240))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func cancel() {
        build?.terminate()
        NSApp.terminate(nil)
    }

    @objc func openLog() {
        NSWorkspace.shared.open(log)
    }

    @objc func openOld() {
        launchPilot()
    }

    // MARK: - Открыть Pilot

    func launchPilot() {
        opened = true
        let urls = pending
        pending = []
        open(urls) { NSApp.terminate(nil) }
    }

    func open(_ urls: [URL], then done: (() -> Void)? = nil) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let finish: (NSRunningApplication?, Error?) -> Void = { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.failed("Pilot не открылся: \(error.localizedDescription)")
                } else {
                    done?()
                }
            }
        }
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: pilotApp, configuration: configuration, completionHandler: finish)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: pilotApp, configuration: configuration, completionHandler: finish)
        }
    }

    // MARK: - Окно

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 132),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pilot"
        window.isReleasedWhenClosed = false

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        for button in [primary, secondary] {
            button.bezelStyle = .rounded
            button.target = self
        }
        secondary.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [NSView(), primary, secondary])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, bar, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        for view in [bar, detail, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let launcher = Launcher()
app.delegate = launcher
app.setActivationPolicy(.accessory)
app.run()
