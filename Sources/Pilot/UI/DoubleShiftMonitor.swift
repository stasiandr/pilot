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

    init(onDoubleShift: @escaping () -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
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
