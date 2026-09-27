import AppKit

/// Окно NuGet открывается само, когда пакеты не восстановлены и компиляция
/// их не видит (см. NuGetRestore). Один раз за запуск Pilot на проект и не
/// поверх работы: не посреди набора, не над модальным окном или палитрой.
extension Workspace {
    /// Отчёт о пакетах поменялся или окно проекта вышло вперёд: не пора ли.
    func offerNuGet() {
        guard nugetOffer == nil, nuget.wantsAutoOpen else { return }
        nugetOffer = Task { @MainActor [weak self] in
            var first = true
            while true {
                if !first { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                first = false
                guard let self, !Task.isCancelled else { return }
                if self.tryOpeningNuGet() {
                    self.nugetOffer = nil
                    return
                }
            }
        }
    }

    /// true — ждать больше нечего: окно открыто, уже не нужно или проект не
    /// впереди (тогда позовёт `didBecomeKey`). false — попробовать чуть позже.
    private func tryOpeningNuGet() -> Bool {
        guard nuget.wantsAutoOpen else { return true }
        guard NSApp.isActive, let window, window.isKeyWindow else { return true }
        if NSApp.modalWindow != nil || window.attachedSheet != nil || isPaletteOpen
            || KeyboardIdle.seconds < 3 { return false }
        nuget.markNoticed()
        openNuGet()
        return true
    }
}

/// Сколько секунд в окнах Pilot не нажимали клавиш. Свои события приложение
/// видит без всяких разрешений — на чужие смотреть незачем.
@MainActor
enum KeyboardIdle {
    private static var monitor: Any?
    private static var lastKeyDown: TimeInterval = 0

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { lastKeyDown = ProcessInfo.processInfo.systemUptime }
            return event
        }
    }

    static var seconds: TimeInterval { ProcessInfo.processInfo.systemUptime - lastKeyDown }
}
