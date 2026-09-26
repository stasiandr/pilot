import AppKit
import Security

/// Самообновление. Новая версия — релиз на GitHub, который выкладывает
/// `./dist.sh --publish`: тег `vX.Y.Z` и zip с подписанным и нотаризованным
/// бандлом. Pilot раз в несколько часов спрашивает последний релиз и, если он
/// новее, показывает плашку над редактором; «Обновить» скачивает архив,
/// сверяет подпись и кладёт новый бандл на место текущего.
///
/// Подпись — главная проверка: новый бандл должен быть подписан тем же
/// Developer ID, что и запущенный. Сборка из исходников (ad-hoc, без команды)
/// так проверить не может, поэтому ставить себя сама не берётся — плашка
/// ведёт на страницу релиза.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repository = "stasiandr/pilot"
    private static let automaticKey = "pilot.update.automatic"
    private static let skippedKey = "pilot.update.skipped"
    private static let interval: TimeInterval = 6 * 60 * 60

    enum State: Equatable {
        case idle
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Double)
        case installing(ReleaseInfo)
        /// Новый бандл на месте, работает ещё старый — ждёт перезапуска.
        case installed(ReleaseInfo)
        case failed(ReleaseInfo, String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isChecking = false

    @Published var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Self.automaticKey)
            schedule()
        }
    }

    let current: AppVersion
    private var timer: Timer?
    private var relaunchOnQuit = false

    private init() {
        UserDefaults.standard.register(defaults: [Self.automaticKey: true])
        checksAutomatically = UserDefaults.standard.bool(forKey: Self.automaticKey)
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        current = short.flatMap(AppVersion.init) ?? AppVersion("0")!
    }

    /// Первая проверка — через несколько секунд после запуска: окну и
    /// индексу сеть сейчас нужнее.
    func start() {
        schedule()
        guard checksAutomatically else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { await self?.check(manual: false) }
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard checksAutomatically else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(manual: false) }
        }
    }

    /// Из меню и настроек: здесь и «у вас последняя версия», и ошибка сети —
    /// окном. Фоновая проверка молчит обо всём, кроме новой версии.
    func checkNow() {
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        switch state {
        case .downloading, .installing, .installed: return
        default: break
        }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let release: ReleaseInfo?
        do {
            release = try await Self.latestRelease()
        } catch {
            if manual { alert(L("Не удалось проверить обновления"), error.localizedDescription) }
            return
        }
        guard let release, release.version > current else {
            state = .idle
            if manual { alert(L("Обновлений нет"), L("Pilot \(current.description) — последняя версия.")) }
            return
        }
        // Отложенную версию фоновая проверка не предлагает, а ручная — да:
        // раз спросили, значит, передумали.
        if !manual, UserDefaults.standard.string(forKey: Self.skippedKey) == release.version.description {
            return
        }
        state = .available(release)
    }

    /// Откуда брать последний релиз. `PILOT_UPDATE_FEED` подменяет адрес —
    /// можно и `file://` с сохранённым ответом API: так плашку и установку
    /// проверяют, не выпуская настоящий релиз.
    private static var feed: URL {
        ProcessInfo.processInfo.environment["PILOT_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    private static func latestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        // 404 — релизов ещё нет: обновляться не на что, это не ошибка.
        if status == 404 { return nil }
        guard status == 200 else { throw Failure.http(status) }
        return ReleaseInfo.parse(data)
    }

    /// Не напоминать об этой версии — до следующей.
    func skip() {
        switch state {
        case .available(let release), .failed(let release, _):
            UserDefaults.standard.set(release.version.description, forKey: Self.skippedKey)
        default: break
        }
        state = .idle
    }

    func openReleasePage() {
        switch state {
        case .available(let r), .downloading(let r, _), .installing(let r), .installed(let r), .failed(let r, _):
            NSWorkspace.shared.open(r.page)
        case .idle:
            NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repository)/releases/latest")!)
        }
    }

    // MARK: - Установка

    /// Почему поставить обновление на место нельзя; `nil` — можно.
    var installBlocker: String? {
        let bundle = Bundle.main.bundleURL
        if Self.teamIdentifier(of: bundle) == nil {
            return L("Это сборка из исходников — новую версию скачайте со страницы релиза")
        }
        // Запущенное прямо из «Загрузок» macOS держит в копии только для
        // чтения (App Translocation) — заменять там нечего.
        if bundle.path.contains("/AppTranslocation/") {
            return L("Перенесите Pilot в «Программы» — оттуда он сможет обновляться сам")
        }
        if !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return L("Нет прав на запись в папку, где лежит Pilot")
        }
        return nil
    }

    func install() {
        switch state {
        case .available(let release), .failed(let release, _): begin(release)
        default: break
        }
    }

    private func begin(_ release: ReleaseInfo) {
        guard let archive = release.archive, installBlocker == nil else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .downloading(release, 0)
        Task {
            do {
                let zip = try await Self.download(archive) { fraction in
                    guard case .downloading(let r, _) = self.state, r == release else { return }
                    self.state = .downloading(release, fraction)
                }
                state = .installing(release)
                try await Self.replaceBundle(with: zip, expecting: release.version)
                state = .installed(release)
            } catch {
                state = .failed(release, error.localizedDescription)
            }
        }
    }

    /// Выйти и открыть уже новый бандл. Выход могут отменить (несохранённые
    /// правки) — тогда `terminate` вернётся, и перезапуск не нужен.
    func relaunch() {
        relaunchOnQuit = true
        NSApp.terminate(nil)
        relaunchOnQuit = false
    }

    /// Из `applicationWillTerminate`: маленький sh дожидается, пока этот
    /// процесс завершится, и открывает бандл заново — уже новую версию.
    func relaunchIfRequested() {
        guard relaunchOnQuit else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundlePath]
        try? process.run()
    }

    enum Failure: LocalizedError {
        case http(Int)
        case download(String)
        case unpack
        case signature
        case version(String)

        var errorDescription: String? {
            switch self {
            case .http(let status): return L("GitHub ответил \(status)")
            case .download(let why): return L("Не удалось скачать обновление: \(why)")
            case .unpack: return L("Не удалось распаковать обновление")
            case .signature: return L("Подпись обновления не совпала с подписью Pilot — не устанавливаю")
            case .version(let found): return L("В архиве не та версия: \(found)")
            }
        }
    }

    private static func download(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress: progress)
        let (file, response): (URL, URLResponse)
        do {
            (file, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: file)
            throw Failure.download("HTTP \(http.statusCode)")
        }
        return file
    }

    /// Распаковать рядом с текущим бандлом (тот же том — замена атомарная),
    /// проверить подпись и версию и поменять бандлы местами.
    private static func replaceBundle(with zip: URL, expecting version: AppVersion) async throws {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        defer { try? fm.removeItem(at: zip) }
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: staging) }

        try await Task.detached {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, staging.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw Failure.unpack }
        }.value

        guard let app = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else { throw Failure.unpack }

        let found = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard found.flatMap(AppVersion.init) == version else { throw Failure.version(found ?? "?") }

        guard let team = teamIdentifier(of: target),
              let identifier = Bundle.main.bundleIdentifier else { throw Failure.signature }
        let valid = await Task.detached { isSigned(app, team: team, identifier: identifier) }.value
        guard valid else { throw Failure.signature }

        _ = try fm.replaceItemAt(target, withItemAt: app, backupItemName: nil, options: [])
    }

    /// Команда Developer ID, которой подписан бандл; у ad-hoc подписи её нет.
    nonisolated static func teamIdentifier(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Подпись цела (со всеми ресурсами), выдана Apple этой же команде и на
    /// этот же идентификатор бандла.
    nonisolated private static func isSigned(_ bundle: URL, team: String, identifier: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @MainActor (Double) -> Void
        init(progress: @escaping @MainActor (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let report = progress
            Task { @MainActor in report(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }
}
