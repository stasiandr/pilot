import AppKit

/// Ловит ⇧⇧ в окне Pilot и зовёт обработчик.
///
/// Монитор локальный: пока Pilot не активен, двойной Shift принадлежит
/// другим приложениям. События он только подсматривает и никогда не
/// съедает — поле ввода и палитра получают всё как обычно.
@MainActor
final class DoubleShiftMonitor {
    private var monitor: Any?
    private var detector = DoubleShiftDetector()

    /// `workspace` — чьё окно слушать: у каждого окна проекта свой монитор.
    init(workspace: Workspace, onDoubleShift: @escaping () -> Void) {
        // И отпускание клавиши: нажатие Tab или стрелки съедает монитор
        // палитры, а порядок мониторов AppKit не гарантирует — сюда оно может
        // не дойти, и два быстрых ⇧Tab в поиске сошли бы за ⇧⇧. Отпускание
        // не съедает никто.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown]
        ) { [weak self, weak workspace] event in
            guard let self, let workspace, workspace.owns(event) else { return event }
            switch event.type {
            case .flagsChanged:
                // Caps Lock и прочие служебные флаги не в счёт.
                let flags = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
                if self.detector.modifiersChanged(shiftOnly: flags == .shift,
                                                  none: flags.isEmpty,
                                                  at: event.timestamp) {
                    onDoubleShift()
                }
            default:
                // Shift+буква, Shift+клик — это не вызов поиска.
                self.detector.keyPressed()
            }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
