import AppKit

/// ⌃Tab — на вкладку, где был перед этой. Держишь ⌃ и жмёшь Tab ещё —
/// дальше в прошлое, с ⇧ — обратно; отпустил ⌃ — выбор сделан. Так
/// переключаются между двумя файлами одним движением, как в JetBrains.
///
/// Меню так не умеет — ему нужен отпущенный модификатор, — поэтому
/// монитор. Съедает только сам ⌃Tab.
@MainActor
final class TabSwitchMonitor {
    private var monitor: Any?
    private var resignObserver: Any?
    /// Порядок недавних на момент первого ⌃Tab; пока ⌃ держат, он не меняется.
    private var order: [TextBuffer] = []
    private var position = 0
    private var start: TextBuffer?

    init(workspace: Workspace) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self, weak workspace] event in
            guard let self, let workspace else { return event }
            switch event.type {
            case .keyDown:
                let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
                // 48 — Tab.
                guard event.keyCode == 48, flags == .control || flags == [.control, .shift],
                      !workspace.isPaletteOpen else { return event }
                self.step(workspace, backwards: flags.contains(.shift))
                return nil
            case .flagsChanged:
                if !self.order.isEmpty, !event.modifierFlags.contains(.control) {
                    self.finish(workspace)
                }
                return event
            default:
                return event
            }
        }
        // Ушли в другое приложение, не отпустив ⌃ здесь, — выбор сделан.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self, weak workspace] _ in
            MainActor.assumeIsolated {
                guard let self, let workspace, !self.order.isEmpty else { return }
                self.finish(workspace)
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    private func step(_ workspace: Workspace, backwards: Bool) {
        if order.isEmpty {
            start = workspace.buffer
            order = workspace.beginTabSwitch()
            position = 0
        }
        guard order.count > 1 else { return }
        position = (position + (backwards ? -1 : 1) + order.count) % order.count
        workspace.showTabWhileSwitching(order[position])
    }

    private func finish(_ workspace: Workspace) {
        workspace.endTabSwitch(startedAt: start)
        order = []
        start = nil
    }
}
