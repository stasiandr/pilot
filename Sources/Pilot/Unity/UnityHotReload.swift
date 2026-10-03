import AppKit
import SwiftUI
import Foundation

/// Горячая перезагрузка Unity из Pilot: сохранили C# — изменённые методы
/// подменяются в запущенном редакторе, без перекомпиляции и перезагрузки
/// домена.
///
/// Всё считает компиляция, которая у Pilot и так есть: Rustlyn знает каждое
/// дерево проекта, и сохранение — это одно дерево заново и сравнение с тем,
/// на чём редактор сейчас. Заплатку (маленькую сборку) берёт проба в самом
/// редакторе — `Assets/PilotProbe/Editor/PilotProbe.cs`: команды ей пишутся в
/// `Temp/PilotProbe/cmd.txt`, ответы она пишет в `log.txt`. Что произошло,
/// видно в окне Unity `Window → Pilot Hot Reload` (`hud.jsonl`).
///
/// Правку, которую заплатка не несёт (новый тип, сменилась сериализация),
/// несёт только сборка целиком: тогда редактор перезагружается на ней.
@MainActor
final class UnityHotReload: ObservableObject {
    enum State: Equatable {
        case off
        case starting(String)
        case on
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// Что вышло из последнего сохранения — для строки состояния Pilot.
    @Published private(set) var lastResult: String?

    var isOn: Bool { state == .on }
    var isRunning: Bool { if case .off = state { false } else if case .failed = state { false } else { true } }

    private var project: URL?
    private var rustlyn: Rustlyn?
    private var tools: UnityHotReloadTools.Built?
    /// Сохранения ждут по одному кругу: пока идёт круг, новые копятся здесь
    /// и уходят следующим одним кругом.
    private var pending: [String: (before: String, after: String)] = [:]
    private var busy = false
    /// Идёт круг: он сам компилирует проект, и компиляции Pilot незачем
    /// идти рядом и делить с ним ядра — она подождёт и найдёт всё готовым.
    var isBusy: Bool { busy }
    /// Круг закончился: отложенной компиляции пора.
    var onRoundFinished: (() -> Void)?
    private let work = DispatchQueue(label: "pilot.unity.hot-reload", qos: .userInitiated)
    /// Методы, которые заплатки заменили с последней перезагрузки: новое среди
    /// них — то, что поменяло это сохранение.
    private var patched: Set<String> = []

    // MARK: - Вкл/выкл

    func toggle(project info: UnityProjectInfo?, rustlyn: Rustlyn?) {
        if isRunning {
            if let root = project ?? waitingRoot { Self.remember(root, on: false) }
            stop()
        } else if let info, let rustlyn {
            Self.remember(info.root, on: true)
            start(project: info, rustlyn: rustlyn)
        }
    }

    private var editorWait: Timer?
    /// The project waited for, until the editor opens it.
    private var waitingRoot: URL?

    /// Ждёт, пока проект откроют в Unity, — раз в пять секунд, пока
    /// перезагрузку не выключили.
    private func waitForEditor(project info: UnityProjectInfo, rustlyn: Rustlyn) {
        waitingRoot = info.root
        editorWait?.invalidate()
        editorWait = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, case .starting = self.state, self.project == nil else {
                    timer.invalidate()
                    return
                }
                guard Probe.editorRunning(on: info.root) else { return }
                timer.invalidate()
                self.editorWait = nil
                self.waitingRoot = nil
                self.start(project: info, rustlyn: rustlyn)
            }
        }
    }

    // MARK: - Запомнить на следующий запуск

    /// Проекты, где горячую перезагрузку включили и не выключали: при
    /// следующем открытии она включается сама. Пишется только по клику —
    /// запись в UserDefaults будит всё окно.
    private static let rememberedKey = "pilot.unityHotReload.projects"

    static func remembered(_ project: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: rememberedKey) ?? []).contains(project.standardizedFileURL.path)
    }

    private static func remember(_ project: URL, on: Bool) {
        let path = project.standardizedFileURL.path
        var all = UserDefaults.standard.stringArray(forKey: rememberedKey) ?? []
        guard all.contains(path) != on else { return }
        if on { all.append(path) } else { all.removeAll { $0 == path } }
        UserDefaults.standard.set(all, forKey: rememberedKey)
    }

    /// Окно Pilot Hot Reload в редакторе — открыть или вывести вперёд.
    func showEditorWindow() {
        guard let project else { return }
        Probe.command(project, "hud")
        Probe.activateEditor(on: project)
    }

    func stop() {
        if isRunning {
            NSLog("[hot] выключено")
            if let project { Probe.command(project, "hold off") }
        }
        state = .off
        project = nil
        rustlyn = nil
        editorWait?.invalidate()
        editorWait = nil
        waitingRoot = nil
        pending.removeAll()
        patched.removeAll()
        seen.removeAll()
        madeHere.removeAll()
        deleted = false
        bulk = false
        editorTimer?.invalidate()
        editorTimer = nil
        foreign = false
        playing = false
    }

    // MARK: - Что делает редактор сам

    private var editorTimer: Timer?
    private var editorLogOffset: UInt64 = 0
    /// Редактор перезагрузился не по нашей просьбе — сам скомпилировал при
    /// входе в Play Mode или его перезапустили: заплаток в нём больше нет,
    /// и мерить новые не от чего, пока он снова не на нашей сборке.
    private var foreign = false
    private var playing = false

    /// Следит за журналом пробы: перезагрузки и Play Mode.
    private func watchEditor(_ root: URL) {
        let log = Probe.folder(root).appendingPathComponent("log.txt")
        editorLogOffset = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
        editorTimer?.invalidate()
        editorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readEditorLog(log) }
        }
    }

    private var heartbeatTick = 0

    private func readEditorLog(_ log: URL) {
        heartbeatTick += 1
        if heartbeatTick % 10 == 0, let project { Probe.touchHeartbeat(project) }
        guard let handle = try? FileHandle(forReadingFrom: log) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < editorLogOffset { editorLogOffset = 0 }
        guard size > editorLogOffset else { return }
        try? handle.seek(toOffset: editorLogOffset)
        let data = handle.readDataToEndOfFile()
        editorLogOffset += UInt64(data.count)
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.contains(" started assembly=") {
                // Свои строки «reloaded» пишет проба после нашей просьбы;
                // «started» — всё остальное.
                foreign = true
                NSLog("[hot] редактор перезагрузился сам: %@", String(line))
            } else if line.contains(" play state EnteredPlayMode") {
                playing = true
            } else if line.contains(" play state EnteredEditMode") {
                playing = false
            }
        }
        if foreign, !playing, !busy { resync() }
    }

    /// Редактор снова на сборке Pilot: целиком, со всем, что сохранено.
    /// `why` — what the editor's window says brought the whole build.
    private func resync(_ why: String = "Unity reloaded on its own build") {
        guard let project, let rustlyn, let runtime = tools?.runtime.path else { return }
        foreign = false
        busy = true
        pending.removeAll()
        let started = Date()
        work.async { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Hot reload: whole build")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            // Play Mode starts after the reload that compiling for it made:
            // asked of the editor itself, not of what the log said so far.
            let state = Probe.ask(project, "state", answers: ["state"], timeout: 30) ?? ""
            if state.contains("playing=True") || state.contains("compiling=True") {
                Task { @MainActor in
                    guard let self else { return }
                    self.busy = false
                    self.foreign = true
                    self.playing = state.contains("playing=True")
                    self.onRoundFinished?()
                }
                return
            }
            Probe.event(project, kind: "reload", title: why,
                        detail: "Pilot's build goes back in, with everything saved")
            let built = rustlyn.hotRebuild()
            var reloaded = false
            if built["ok"] as? Bool == true, let assembly = built["assembly"] as? String,
               let answer = Probe.ask(project, "reload \(assembly)", answers: ["reloaded", "failed"], timeout: 1800),
               answer.hasPrefix("reloaded") {
                Probe.touchHeartbeat(project)
                // A restarted editor has neither the runtime nor the hold.
                if !Probe.restored(answer) {
                    _ = Probe.ask(project, "load \(runtime)", answers: ["loaded", "failed"], timeout: 60)
                    _ = Probe.ask(project, "hold on", answers: ["hold"], timeout: 30)
                }
                reloaded = true
                Probe.event(project, kind: "reload", title: "Back on Pilot's build",
                            detail: "hot reload goes on", seconds: Date().timeIntervalSince(started))
            } else {
                Probe.event(project, kind: "failed", title: "Pilot's build did not go back in",
                            detail: (built["error"] as? String) ?? Probe.lastAnswer ?? "no answer",
                            seconds: Date().timeIntervalSince(started))
            }
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if reloaded {
                    self.patched.removeAll()
                    self.madeHere.removeAll()
                    self.deleted = false
                    self.startedAt = started
                    // Своё «reloaded» уже прочитано или будет: не «started».
                }
                self.onRoundFinished?()
                self.next()
            }
        }
    }

    private func start(project info: UnityProjectInfo, rustlyn: Rustlyn) {
        let root = info.root
        guard info.workspacePrefix.isEmpty else {
            state = .failed(L("Откройте в Pilot саму папку Unity-проекта"))
            return
        }
        guard let contents = info.editorContents else {
            state = .failed(L("Не найден редактор Unity \(info.editorVersion ?? "")"))
            return
        }
        guard Probe.editorRunning(on: root) else {
            // Pilot opened before Unity: start once the editor is there.
            state = .starting(L("ждёт Unity…"))
            waitForEditor(project: info, rustlyn: rustlyn)
            return
        }
        project = root
        self.rustlyn = rustlyn
        state = .starting(L("Готовлю инструменты…"))
        // Объект живёт, пока живёт окно: держать его здесь можно.
        work.async { [self] in
            // Включают и ждут — даже из Unity, когда Pilot позади (см. круг).
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Hot reload: starting")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let started = Date()
            let say: @Sendable (String) -> Void = { text in
                Task { @MainActor in
                    guard case .starting = self.state, self.project == root else { return }
                    self.state = .starting(text)
                }
            }
            let failed: @Sendable (String) -> Void = { why in
                NSLog("[hot] не запустилось: %@", why)
                Probe.event(root, kind: "failed", title: "Hot reload did not start", detail: why)
                Task { @MainActor in
                    guard self.project == root else { return }
                    self.state = .failed(why)
                }
            }
            let tools: UnityHotReloadTools.Built
            switch UnityHotReloadTools.prepare(contents: contents, progress: say) {
            case .success(let built): tools = built
            case .failure(let failure): return failed(failure.message)
            }
            // Проба — в проекте и та же, что в этом Pilot; новую Unity
            // компилирует сама и отвечает уже ею.
            let hadProbe = Probe.isInstalled(in: root)
            switch UnityHotReloadTools.installProbe(project: root, built: tools) {
            case .failure(let failure): return failed(failure.message)
            case .success(let installed) where !installed.scripts:
                // Only the library: imported on a refresh, nothing to compile.
                if installed.plugin, hadProbe {
                    _ = Probe.ask(root, "refresh", answers: ["refreshed"], timeout: 300)
                }
            case .success:
                say(L("Unity компилирует пробу — переключитесь на Unity"))
                let log = Probe.folder(root).appendingPathComponent("log.txt")
                let at = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
                if hadProbe {
                    Probe.command(root, "hold off")
                    Probe.command(root, "refresh")
                }
                Probe.activateEditor(on: root)
                guard Probe.wait(for: " started assembly=", in: log, after: at, timeout: 900) else {
                    return failed(L("Unity не скомпилировала пробу: переключитесь на Unity и включите снова"))
                }
            }
            say(L("Генераторы и сборка целиком…"))
            Probe.note(root, "⟳ Pilot: building the project for hot reload…")
            let answer = rustlyn.hotStart(tools: tools.json)
            guard answer["ok"] as? Bool == true, let assembly = answer["assembly"] as? String else {
                return failed(answer["error"] as? String ?? "no answer")
            }
            say(L("Unity перезагружается на сборке Pilot…"))
            Probe.activateEditor(on: root)
            guard let reloaded = Probe.ask(root, "reload \(assembly)", answers: ["reloaded", "failed"], timeout: 600),
                  reloaded.hasPrefix("reloaded") else {
                return failed("Unity: " + (Probe.lastAnswer ?? "no answer"))
            }
            guard let loaded = Probe.ask(root, "load \(tools.runtime.path)", answers: ["loaded", "failed"], timeout: 60),
                  loaded.hasPrefix("loaded") else {
                return failed("Unity: " + (Probe.lastAnswer ?? "no answer"))
            }
            // Собственные компиляции Unity больше не перезагружают её: сборка,
            // от которой меряются заплатки, и сами заплатки остаются.
            Probe.touchHeartbeat(root)
            _ = Probe.ask(root, "hold on", answers: ["hold"], timeout: 30)
            let seconds = Date().timeIntervalSince(started)
            NSLog("[hot] включено за %.1f с", seconds)
            Probe.event(root, kind: "reload", title: "Hot reload from Pilot is on",
                        detail: "save a C# file in Pilot", seconds: seconds)
            Task { @MainActor in
                guard self.project == root else { return }
                self.tools = tools
                self.lastScan = Date()
                self.startedAt = started
                self.state = .on
                self.patched.removeAll()
                self.madeHere.removeAll()
                self.watchEditor(root)
                self.next()
            }
        }
    }

    // MARK: - Сохранение

    /// Pilot сохранил файл: `before` — каким он был на диске до записи.
    func saved(_ url: URL, before: String?, after: String) {
        guard let project, isRunning, url.pathExtension == "cs",
              url.path.hasPrefix(project.path + "/Assets/") else { return }
        // С диска, а не из буфера: BOM и концы строк — как их прочтёт
        // событие ФС, которое придёт следом.
        seen[url.path] = (try? String(contentsOfFile: url.path, encoding: .utf8)) ?? after
        let known = pending[url.path]?.before
        pending[url.path] = (known ?? before ?? after, after)
        if isOn { next() }
    }

    /// Текст каждого файла, каким его последний раз отдали в круг: по нему
    /// событие ФС после сохранения в Pilot узнаётся как то же сохранение.
    private var seen: [String: String] = [:]
    /// More files changed at once than patches carry.
    private var bulk = false
    /// A file was deleted since the editor's build: reloading in place is
    /// no longer safe, only a restart of the editor is.
    private var deleted = false

    /// Пачка событий ФС. Папка вместо файлов — система не успела и просит
    /// пересмотреть её (или кто-то создал папку): тогда смотрим, какие `.cs`
    /// в ней поменялись с прошлого раза, иначе такое сохранение пропало бы.
    func changedOnDisk(events: [FileEvent]) {
        guard let project, isRunning else { return }
        let assets = project.path + "/Assets"
        let folders = events.filter { event in
            event.structural && !event.path.hasSuffix(".cs")
                && (assets.hasPrefix(event.path) || event.path.hasPrefix(assets + "/"))
        }.map { assets.hasPrefix($0.path) ? assets : $0.path }
        changedOnDisk(events.map(\.path))
        guard !folders.isEmpty else { return }
        let since = lastScan.addingTimeInterval(-2)
        lastScan = Date()
        work.async { [weak self] in
            let fm = FileManager.default
            var found: [String] = []
            for folder in Set(folders) {
                guard let walk = fm.enumerator(at: URL(fileURLWithPath: folder),
                                               includingPropertiesForKeys: [.contentModificationDateKey],
                                               options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in walk where url.pathExtension == "cs" {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if let date, date > since { found.append(url.path) }
                }
            }
            guard !found.isEmpty else { return }
            Task { @MainActor in
                NSLog("[hot] пересмотр папки: %d файлов поменялись", found.count)
                self?.changedOnDisk(found)
            }
        }
    }

    /// Файлы, появившиеся при включённой перезагрузке и ещё не
    /// импортированные Unity (без `.meta`).
    private var madeHere: Set<String> = []
    /// С какого времени пересмотр папки ищет изменённые файлы.
    private var lastScan = Date()
    /// Когда сборка, на которой редактор, взяла файлы с диска: что
    /// записано раньше, в ней уже есть.
    private var startedAt = Date()

    /// Файлы поменялись мимо Pilot: другой редактор, скрипт. Переключение
    /// ветки — сотни файлов — заплатками не возят: такое пропускаем.
    func changedOnDisk(_ paths: [String]) {
        guard let project, isRunning else { return }
        let sources = paths.filter { $0.hasSuffix(".cs") && $0.hasPrefix(project.path + "/Assets/") }
        guard !sources.isEmpty else { return }
        // A branch switched, a replace over the project: no patch carries
        // that, and reading every file to find out is time thrown away —
        // the build goes in whole.
        if sources.count > 50 {
            bulk = true
            if isOn { next() }
            return
        }
        let fm = FileManager.default
        // Удалён файл проекта, а не временный, через который другой редактор
        // сохраняет атомарно (`.!123!Name.cs`, `Name.cs~`): у файла Unity
        // остаётся `.meta` (без автообновления её никто не убирает), или
        // Pilot его уже видел.
        let missing = Set(sources).filter { !fm.fileExists(atPath: $0) }
        // Made and taken away while hot reload ran: the editor's build never
        // had its types, nor anything Unity serialized of them.
        for path in missing where madeHere.contains(path) {
            madeHere.remove(path)
            seen[path] = nil
            pending[path] = nil
        }
        let gone = missing.filter { path in
            !(path as NSString).lastPathComponent.hasPrefix(".")
                && (fm.fileExists(atPath: path + ".meta") || seen[path] != nil)
        }.sorted()
        if !gone.isEmpty {
            // The editor's build still has the file's types, and reloading
            // in place on a build without them leaves what it serialized
            // unreadable: only a fresh start of the editor is safe.
            let names = gone.map { ($0 as NSString).lastPathComponent }
            Probe.event(project, kind: "deleted", file: names.count == 1 ? names[0] : "\(names.count) files",
                        title: "A file was deleted: restart Unity",
                        detail: names.joined(separator: ", ") + " — its types stay in the running editor until it starts again")
            for path in gone { seen[path] = nil; pending[path] = nil }
            deleted = true
        }
        for path in Set(sources) {
            // A file not seen yet is news only if its text was written since
            // hot reload started: cloning the folder, a `touch`, new
            // permissions send events and leave the content date alone.
            if seen[path] == nil, pending[path] == nil,
               let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               date < startedAt {
                continue
            }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8), text != seen[path] else { continue }
            // A file Unity has not imported yet — no `.meta` beside it — was
            // nothing before. Its creation date says nothing: an atomic save
            // makes the file anew.
            let imported = fm.fileExists(atPath: path + ".meta")
            if !imported, seen[path] == nil { madeHere.insert(path) }
            let unseen = imported ? text : ""
            let before = pending[path]?.before ?? seen[path] ?? unseen
            seen[path] = text
            pending[path] = (before, text)
        }
        if isOn { next() }
    }

    private func next() {
        if foreign {
            // Заплатки мерить не от чего, пока редактор не на нашей сборке.
            if !playing && !busy { resync() }
            if playing, !pending.isEmpty, let project {
                let names = pending.keys.map { ($0 as NSString).lastPathComponent }.sorted()
                pending.removeAll()
                Probe.event(project, kind: "reload", file: names.count == 1 ? names[0] : "\(names.count) files",
                            title: "Waits for Play Mode to stop",
                            detail: "Unity compiled its own build entering Play Mode; Pilot's goes back in when it stops")
            }
            return
        }
        guard !busy, !pending.isEmpty || bulk, let project, let rustlyn else { return }
        // Many files at once — a branch switched, a replace over the
        // project — is no patch: the build goes in whole.
        if bulk || pending.count > 50 {
            NSLog("[hot] много файлов разом: сборка целиком")
            Probe.event(project, kind: "reload", file: bulk ? "many files" : "\(pending.count) files",
                        title: "Many files changed at once", detail: "Pilot builds the project whole and reloads")
            bulk = false
            pending.removeAll()
            resync("Pilot builds the project whole")
            return
        }
        let round = pending
        pending.removeAll()
        busy = true
        let runtime = tools?.runtime.path ?? ""
        let known = patched
        let restartOnly = deleted
        // Сохранили из другого редактора или Unity впереди: Pilot не активен,
        // и App Nap отдаёт его потоки эффективным ядрам — круг втрое дольше.
        // Круг ждут, как ждут нажатия.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Hot reload round")
        work.async { [weak self] in
            let outcome = Self.round(round, project: project, rustlyn: rustlyn, runtime: runtime, patched: known,
                                     restartOnly: restartOnly)
            ProcessInfo.processInfo.endActivity(activity)
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                defer { if !self.busy { self.onRoundFinished?() } }
                guard self.project == project else { return }
                if outcome.reloaded { self.patched.removeAll(); self.madeHere.removeAll() }
                if outcome.resync { self.foreign = true }
                if let summary = outcome.summary { self.lastResult = summary }
                self.patched.formUnion(outcome.patched)
                self.next()
            }
        }
    }

    /// Whether the editor put in every method the patch carries — `hotpatched
    /// N`, and those it skipped on purpose (their type does not initialize in
    /// the editor). Fewer means a method it could not find: the editor would
    /// go on running the old code without a word.
    nonisolated static func appliedAll(_ applied: String, of count: Int) -> Bool {
        let words = applied.split(separator: " ")
        guard words.count > 1, let done = Int(words[1]) else { return false }
        let skipped = applied.range(of: "skipped, their type does not initialize in the editor: ")
            .map { applied[$0.upperBound...].components(separatedBy: ", ").count } ?? 0
        return done + skipped >= count
    }

    private struct Outcome: Sendable {
        var patched: [String] = []
        var reloaded = false
        /// Заплатка не легла: в каждой следующей были бы те же методы, и
        /// легли бы так же. Только сборка целиком.
        var resync = false
        /// Одной строкой для строки состояния: «✓ Метод · 1.1 с».
        var summary: String?
    }

    /// Один круг: заплатка на все сохранения разом, и редактор её берёт.
    /// Nothing that runs changed: spacing and comments — or a new type or
    /// member nothing calls yet, which goes in with the first save that uses it.
    nonisolated private static func nothingRuns(project: URL, file: String, diff: [String], seconds: TimeInterval) {
        let added = HotDiff.declarations(diff).filter { $0.hasPrefix("Added ") }
        Probe.event(project, kind: "same", file: file,
                    title: added.isEmpty ? "Nothing that runs changed" : added.prefix(3).joined(separator: ", "),
                    detail: added.isEmpty ? "spacing or comments" : "nothing uses it yet: it goes in with the code that does",
                    seconds: seconds, diff: diff)
    }

    nonisolated private static func round(_ round: [String: (before: String, after: String)], project: URL,
                                          rustlyn: Rustlyn, runtime: String, patched: Set<String>,
                                          restartOnly: Bool) -> Outcome {
        let started = Date()
        let files = round.keys.sorted()
        let name = files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files"
        // Правка мимо Pilot файла, которого он ещё не видел: прежний текст —
        // тот, из которого собран редактор.
        let diff = files.flatMap { path -> [String] in
            let (before, after) = round[path]!
            let known = before != after ? before : rustlyn.hotBaseText(path) ?? before
            return HotDiff.lines(before: known, after: after)
        }
        let answer = rustlyn.hotSave(files)
        let kind = answer["kind"] as? String ?? "error"
        let reason = String((answer["reason"] as? String ?? "").replacingOccurrences(of: project.path + "/", with: "").prefix(240))
        let took = { Date().timeIntervalSince(started) }
        NSLog("[hot] %@: %@ за %d мс %@", name, kind, answer["milliseconds"] as? Int ?? 0, reason)
        var outcome = Outcome()
        switch kind {
        case "patch":
            guard let assembly = answer["assembly"] as? String, !assembly.isEmpty else {
                Self.nothingRuns(project: project, file: name, diff: diff, seconds: took())
                break
            }
            let applied = Probe.ask(project, "hotpatch \(assembly)", answers: ["hotpatched", "failed hotpatch"], timeout: 60)
            let methods = answer["methods"] as? [String] ?? []
            if let applied, applied.hasPrefix("hotpatched"), Self.appliedAll(applied, of: methods.count) {
                outcome.patched = methods
                let title = HotDiff.title(file: files.count == 1 ? files[0] : nil, methods: methods, patched: patched, diff: diff)
                let serialized = HotDiff.serializedFields(diff)
                Probe.event(project, kind: "patch", file: name, title: title,
                            detail: "patched into the running editor — no reload"
                                + (serialized.isEmpty ? "" : "; the Inspector shows \(serialized.joined(separator: ", ")) after a reload"),
                            seconds: took(), diff: diff)
                outcome.summary = "✓ \(title) · " + L("\(String(format: "%.1f", took())) с")
            } else {
                Probe.event(project, kind: "failed", file: name, title: "The patch did not apply",
                            detail: String((applied ?? "no answer").prefix(240)), seconds: took(), diff: diff)
                outcome.summary = "✗ " + L("\(name): заплатка не легла")
                outcome.resync = true
            }
        case "unchanged":
            Self.nothingRuns(project: project, file: name, diff: diff, seconds: took())
            outcome.summary = "· " + L("\(name): ничего не поменялось")
        case "broken":
            Probe.event(project, kind: "broken", file: name, title: "Does not compile yet",
                        detail: reason, seconds: took(), diff: diff)
            outcome.summary = "✗ " + L("\(name) не компилируется")
        case "reload" where restartOnly:
            Probe.event(project, kind: "deleted", file: name, title: "Needs a restart of Unity",
                        detail: "a file was deleted, so the editor cannot reload in place — " + reason,
                        seconds: took(), diff: diff)
        case "reload":
            Probe.event(project, kind: "reload", file: name, title: "Reloading…", detail: reason, diff: diff)
            let built = rustlyn.hotRebuild()
            guard built["ok"] as? Bool == true, let assembly = built["assembly"] as? String else {
                Probe.event(project, kind: "failed", file: name, title: "The build failed",
                            detail: String((built["error"] as? String ?? "").prefix(240)), seconds: took())
                break
            }
            Probe.note(project, "⟳ switch to Unity: it reloads once it is in front")
            if let reloaded = Probe.ask(project, "reload \(assembly)", answers: ["reloaded", "failed"], timeout: 1800),
               reloaded.hasPrefix("reloaded") {
                if !Probe.restored(reloaded) {
                    _ = Probe.ask(project, "load \(runtime)", answers: ["loaded", "failed"], timeout: 60)
                }
                outcome.reloaded = true
                Probe.event(project, kind: "reload", file: name, title: "Reloaded on the new build",
                            detail: reason, seconds: took())
                outcome.summary = "⟳ " + L("\(name): перезагрузка · \(String(format: "%.0f", took())) с")
            } else {
                Probe.event(project, kind: "failed", file: name, title: "Unity did not reload",
                            detail: Probe.lastAnswer ?? "no answer", seconds: took())
            }
        case "outside":
            // A file of another assembly — an asmdef's, an Editor folder's:
            // Unity compiles it itself, and saying nothing would look like
            // hot reload missing it. The probe's own files are Pilot's to
            // write and say nothing of.
            if files.allSatisfy({ $0.contains("/Assets/PilotProbe/") }) { break }
            Probe.event(project, kind: "same", file: name, title: "Not in Assembly-CSharp",
                        detail: "another assembly's file: Unity compiles it, and it runs once Unity reloads (Play, or hot reload off)", seconds: took(), diff: diff)
            outcome.summary = "· " + L("\(name): не Assembly-CSharp — компилирует Unity")
        default:
            Probe.event(project, kind: "failed", file: name, title: "Hot reload failed", detail: reason, seconds: took(), diff: diff)
        }
        return outcome
    }
}

// MARK: - Проба в редакторе

/// Разговор с `PilotProbe.cs`: команда строкой в `cmd.txt`, ответ — первая
/// строка `log.txt` после неё, начинающаяся с одного из ожидаемых слов.
enum Probe {
    nonisolated(unsafe) static var lastAnswer: String?

    static func folder(_ project: URL) -> URL { project.appendingPathComponent("Temp/PilotProbe") }

    static func isInstalled(in project: URL) -> Bool {
        FileManager.default.fileExists(atPath: project.appendingPathComponent("Assets/PilotProbe/Editor/PilotProbe.cs").path)
    }

    /// Процессы Unity, открытые на этом проекте.
    static func editors(on project: URL) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "Unity.app/Contents/MacOS/Unity .*-projectPath \(project.path)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    static func editorRunning(on project: URL) -> Bool { !editors(on: project).isEmpty }

    /// Редактор в фоне перезагружается, только когда выйдет вперёд.
    static func activateEditor(on project: URL) {
        for pid in editors(on: project) {
            DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate() }
        }
    }

    private static func append(_ line: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Ждёт строки журнала пробы, написанной после `offset` (журнал
    /// Unity пишет заново, когда стирает `Temp`).
    static func wait(for text: String, in log: URL, after offset: Int, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        var from = offset
        while Date() < end {
            if let data = try? Data(contentsOf: log) {
                if data.count < from { from = 0 }
                if String(decoding: data[(data.startIndex + from)...], as: UTF8.self).contains(text) { return true }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    static func ask(_ project: URL, _ command: String, answers: [String], timeout: TimeInterval) -> String? {
        let log = folder(project).appendingPathComponent("log.txt")
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        append(command, to: folder(project).appendingPathComponent("cmd.txt"))
        let end = Date().addingTimeInterval(timeout)
        lastAnswer = nil
        while Date() < end {
            if let data = try? Data(contentsOf: log), data.count > size {
                let text = String(decoding: data[(data.startIndex + min(size, data.count))...], as: UTF8.self)
                for line in text.split(whereSeparator: \.isNewline) {
                    // «16:20:01.123 reloaded …» — время и ответ.
                    let said = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    if answers.contains(where: { said.hasPrefix($0) }) {
                        lastAnswer = said
                        return said
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return nil
    }

    /// Проба после своей перезагрузки сама загрузила то, что в неё
    /// загружали, и снова держит: каждая команда редактору в фоне ждёт его
    /// обновления, а это секунды.
    static func restored(_ reloaded: String) -> Bool {
        let loads = match(#" loads=(\d+)"#, reloaded).flatMap { Int($0) } ?? 0
        return loads > 0 && reloaded.contains(" holding=True")
    }

    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(found.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Команда, ответа на которую не ждут.
    static func command(_ project: URL, _ line: String) {
        append(line, to: folder(project).appendingPathComponent("cmd.txt"))
    }

    /// Pilot жив: проба держит перезагрузки, пока файл свежий.
    static func touchHeartbeat(_ project: URL) {
        let url = folder(project).appendingPathComponent("hold")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } else {
            try? FileManager.default.createDirectory(at: folder(project), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
    }

    /// Строка поверх сцены в редакторе; ответа на неё нет.
    static func note(_ project: URL, _ text: String) {
        append("note " + text.replacingOccurrences(of: "\n", with: " "), to: folder(project).appendingPathComponent("cmd.txt"))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Событие для окна Pilot Hot Reload в редакторе (`PilotHud.cs`).
    static func event(_ project: URL, kind: String, file: String = "", title: String, detail: String = "",
                      seconds: TimeInterval = 0, diff: [String] = []) {
        let entry: [String: Any] = [
            "time": clock.string(from: Date()), "kind": kind, "file": file, "title": title,
            "detail": detail, "seconds": NSDecimalNumber(string: String(format: "%.2f", seconds)), "diff": diff,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.withoutEscapingSlashes]) else { return }
        append(String(decoding: data, as: UTF8.self), to: folder(project).appendingPathComponent("hud.jsonl"))
    }
}

// MARK: - Что поменялось, словами

enum HotDiff {
    /// Строки правки для окна в редакторе: `+`/`-`/` ` и `⋯` между кусками,
    /// без общего отступа.
    static func lines(before: String, after: String, limit: Int = 14) -> [String] {
        let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
        let changes = LineDiff.changes(old: before, new: after)
        var out: [String] = []
        for change in changes {
            if !out.isEmpty { out.append("⋯") }
            if change.lines.lowerBound > 0, change.lines.lowerBound - 1 < new.count {
                out.append(" " + new[change.lines.lowerBound - 1])
            }
            out += change.oldLines.filter { $0 < old.count }.map { "-" + old[$0] }
            out += change.lines.filter { $0 < new.count }.map { "+" + new[$0] }
            if change.lines.upperBound < new.count { out.append(" " + new[change.lines.upperBound]) }
        }
        out = out.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let bodies = out.filter { $0 != "⋯" }.map { $0.dropFirst() }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indent = bodies.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        out = out.map { $0 == "⋯" ? $0 : String($0.prefix(1)) + String($0.dropFirst().dropFirst(min(indent, max(0, $0.count - 1)))) }
        return Array(out.prefix(limit)) + (out.count > limit ? ["⋯"] : [])
    }

    /// `dev.A.B::M, dev.A.C::get_P` как `B.M, C.P`.
    static func shortMembers(_ methods: [String]) -> [String] {
        methods.map { item in
            let parts = item.components(separatedBy: "::")
            let owner = parts[0].split(separator: ".").last.map(String.init) ?? parts[0]
            var member = parts.count > 1 ? parts[1] : ""
            if member.hasPrefix("get_") || member.hasPrefix("set_") { member = String(member.dropFirst(4)) }
            member = [".ctor": "constructor", ".cctor": "static constructor"][member] ?? member
            return member.isEmpty ? owner : "\(owner).\(member)"
        }
    }

    private static let keywords: Set<String> = [
        "if", "for", "foreach", "while", "switch", "catch", "using", "return", "new", "lock", "fixed",
        "nameof", "typeof", "sizeof", "default", "base", "this", "await", "throw", "else", "get", "set",
    ]

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// Какие объявления правка добавила или убрала, по её строкам.
    static func declarations(_ diff: [String]) -> [String] {
        var found: [String] = []
        for line in diff {
            let sign = line.prefix(1), text = withoutAttributes(line.dropFirst().trimmingCharacters(in: .whitespaces))
            guard sign == "+" || sign == "-", !text.isEmpty, !text.hasPrefix("//"), !text.hasPrefix("[") else { continue }
            let verb = sign == "+" ? "Added" : "Removed"
            // Объявление — то, что до тела: тело в той же строке (`{ … ; }`)
            // методом его не делает и не перестаёт.
            let head = text.range(of: "{").map { String(text[..<$0.lowerBound]) } ?? text
            if let kind = match(#"\b(class|struct|interface|enum|record)\s+(\w+(?:<[^>]*>)?)"#, text) {
                found.append("\(verb) \(kind[1]) \(kind[2])")
            } else if let method = match(#"^(?:(?:public|private|protected|internal|static|virtual|override|async|abstract|sealed|partial|unsafe|extern|new)\s+)*[\w<>\[\],.?]+\s+(\w+)\s*(?:<[^>]*>)?\s*\([^;]*$"#, head),
                      !keywords.contains(method[1]), !text.hasPrefix("return"), !text.hasPrefix("var "), !text.hasPrefix("await") {
                found.append("\(verb) method \(method[1])")
            } else if let member = match(#"^(?:public|private|protected|internal|static|readonly|const|volatile)\b[^(=]*?\b(\w+)\s*(=|;|\{|=>)"#, text),
                      !keywords.contains(member[1]) {
                found.append("\(verb) \(member[2] == "{" || member[2] == "=>" ? "property" : "field") \(member[1])")
            }
        }
        // Убранное и добавленное с тем же именем — правка его, не два
        // объявления.
        let both = Set(found.filter { $0.hasPrefix("Added ") }.map { $0.dropFirst(6) })
            .intersection(found.filter { $0.hasPrefix("Removed ") }.map { $0.dropFirst(8) })
        var seen = Set<String>()
        return found.filter { item in
            !both.contains(item.hasPrefix("Added ") ? item.dropFirst(6) : item.dropFirst(8)) && seen.insert(item).inserted
        }
    }

    /// Строка без атрибутов в начале: `[SerializeField] private int n;` —
    /// объявление поля, а не строка атрибута.
    static func withoutAttributes(_ text: String) -> String {
        var rest = Substring(text)
        while rest.hasPrefix("[") {
            var depth = 0
            guard let end = rest.firstIndex(where: { character in
                if character == "[" { depth += 1 } else if character == "]" { depth -= 1 }
                return depth == 0
            }) else { break }
            rest = rest[rest.index(after: end)...].drop { $0 == " " || $0 == "\t" }
        }
        return String(rest)
    }

    /// Поля, которые правка добавила с `[SerializeField]`: их Inspector
    /// увидит только после перезагрузки, на сборке, где они есть.
    static func serializedFields(_ diff: [String]) -> [String] {
        diff.compactMap { line -> String? in
            guard line.hasPrefix("+"), line.contains("SerializeField") else { return nil }
            let text = withoutAttributes(line.dropFirst().trimmingCharacters(in: .whitespaces))
            return match(#"^(?:public|private|protected|internal|readonly|\s)*[\w<>\[\],.?]+\s+(\w+)\s*(?:=|;)"#, text)?[1]
        }
    }

    /// Что поменяло сохранение, в несколько слов: добавленные или убранные
    /// объявления, иначе методы, которых у заплаток ещё не было, иначе —
    /// методы самого файла.
    static func title(file: String?, methods: [String], patched: Set<String>, diff: [String]) -> String {
        let members = shortMembers(methods)
        let earlier = Set(shortMembers(Array(patched)))
        let new = members.filter { !earlier.contains($0) }
        let stem = file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        let own = stem.map { stem in members.filter { $0.split(separator: ".").first.map(String.init) == stem } } ?? []
        let declared = declarations(diff)
        let shown = !declared.isEmpty ? declared : !new.isEmpty ? new : own
        guard !shown.isEmpty else { return stem.map { "Edited \($0)" } ?? "Edited" }
        return shown.prefix(3).joined(separator: ", ") + (shown.count > 3 ? " and \(shown.count - 3) more" : "")
    }
}

/// Пункт меню Unity: подписан на состояние сам, чтобы не будить всё меню.
struct HotReloadMenuItem: View {
    @ObservedObject var hotReload: UnityHotReload
    let action: () -> Void

    var body: some View {
        Button(label, action: action)
        Button(L("Окно горячей перезагрузки в Unity")) { hotReload.showEditorWindow() }
            .disabled(!hotReload.isOn)
    }

    private var label: String {
        switch hotReload.state {
        case .off: L("Горячая перезагрузка: включить")
        case .starting(let step): L("Горячая перезагрузка: \(step) (выключить)")
        case .on: L("Горячая перезагрузка: выключить")
        case .failed(let why): L("Горячая перезагрузка: включить (\(why))")
        }
    }
}
