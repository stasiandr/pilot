import AppKit

/// Назад и вперёд тем, чем привыкли: боковыми кнопками мыши и `⌃-` / `⌃⇧-`,
/// как в VS Code. Основные сочетания (⌘[ и ⌘]) — в меню; у пункта меню
/// одно сочетание, и кнопок мыши у него нет вовсе, поэтому остальное — здесь.
@MainActor
final class NavigationKeyMonitor {
    private var monitor: Any?

    init(workspace: Workspace) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown]) { [weak workspace] event in
            guard let workspace, !workspace.isPaletteOpen, workspace.owns(event) else { return event }
            switch event.type {
            case .otherMouseDown:
                // 3 и 4 — боковые кнопки: «назад» и «вперёд».
                switch event.buttonNumber {
                case 3: workspace.goBack(); return nil
                case 4: workspace.goForward(); return nil
                default: return event
                }
            case .keyDown:
                let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
                // 27 — клавиша «-».
                guard event.keyCode == 27 else { return event }
                if flags == .control { workspace.goBack(); return nil }
                if flags == [.control, .shift] { workspace.goForward(); return nil }
                return event
            default:
                return event
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
