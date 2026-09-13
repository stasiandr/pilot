import AppKit

/// Unity на macOS открывает скрипт, запуская редактор заново — каждый раз
/// новым процессом, с файлом в аргументах (как `open -n --args`). Такой
/// процесс отдаёт файл уже открытому Pilot и сразу выходит: одно окно,
/// с вкладками и прогретым индексом.
enum LaunchForwarding {
    /// true — запрос отдан, этому процессу пора выйти. Без запроса — тоже:
    /// Unity присылает и пути, которых нет на диске (из стектрейсов самой
    /// Unity), и тогда открытое окно просто выходит вперёд, а не рядом
    /// появляется второе.
    ///
    /// Адрес уходит Apple Event'ом прямо в процесс: через LaunchServices
    /// (`NSWorkspace.open`, `open -a`) он попадает самому отправителю —
    /// у двух процессов один бандл.
    static func forward(_ request: OpenRequest?) -> Bool {
        guard let running = runningInstance() else { return false }
        guard let request else {
            running.activate()
            return true
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: running.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: request.url.absoluteString), forKeyword: keyDirectObject)
        do {
            try event.sendEvent(options: [.noReply, .init(rawValue: UInt(kAEDoNotPromptForUserConsent))], timeout: 3)
        } catch {
            FileHandle.standardError.write("pilot: не передать файл запущенному Pilot: \(error)\n".data(using: .utf8)!)
            return false
        }
        running.activate()
        return true
    }

    /// Только этот же бандл: сборки из соседних worktree с тем же
    /// идентификатором — чужие окна, в них не пересылаем.
    private static func runningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let own = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            $0.processIdentifier != getpid() && !$0.isTerminated
                && $0.activationPolicy == .regular
                && $0.bundleURL?.resolvingSymlinksInPath() == own
        }
    }
}
