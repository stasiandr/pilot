import AppKit

/// Клавиатура открытой палитры: стрелки, Return, Esc, Tab, ⌃N/⌃P.
///
/// Локальный монитор надёжнее, чем .onKeyPress: поле ввода держит фокус
/// и само съедает стрелки. Он живёт всё время, а не с палитрой: ⌘P и ⇧⇧
/// открывают её синхронно, а SwiftUI вставляет поле только на следующем
/// проходе — на большом проекте это заметная пауза. Буквы, набранные
/// сразу после ⌘P, иначе ушли бы в редактор под палитрой.
@MainActor
final class PaletteKeyMonitor {
    private var monitor: Any?

    init(workspace: Workspace) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak workspace] event in
            guard let workspace, workspace.isPaletteOpen, workspace.owns(event) else { return event }
            return Self.handle(event, workspace)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private static func handle(_ event: NSEvent, _ workspace: Workspace) -> NSEvent? {
        switch event.keyCode {
        case 126: workspace.moveSelection(-1); return nil     // ↑
        case 125: workspace.moveSelection(1);  return nil     // ↓
        case 36, 76: workspace.activateSelection(); return nil // Return
        case 53: workspace.isPaletteOpen = false; return nil   // Esc
        case 48:                                               // Tab — как в fzf
            workspace.moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
            return nil
        default:
            break
        }
        let flags = event.modifierFlags
        // ^N / ^P — привычная навигация для тех, кто из терминала
        if flags.contains(.control), let ch = event.charactersIgnoringModifiers?.lowercased() {
            if ch == "n" { workspace.moveSelection(1); return nil }
            if ch == "p" { workspace.moveSelection(-1); return nil }
        }
        let field = PaletteQueryField.Field.current.flatMap { $0.window === event.window ? $0 : nil }
        // Поля ещё нет. Редактор под палитрой ничего не должен получить —
        // даже ⌘V из меню, — поэтому фокус у него забираем.
        if field == nil { event.window?.makeFirstResponder(nil) }
        // ⌘-сочетания — меню: ⌘F, другой режим палитры и прочее.
        if flags.contains(.command) || flags.contains(.control) { return event }

        if let field {
            // Поле есть, но курсор не в нём — например, забрал редактор,
            // запоздало вернув себе фокус после прошлой палитры. Нажатие
            // достанется полю: окно шлёт его тому, кто в фокусе сейчас.
            if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
            return event
        }

        if event.keyCode == 51 {                               // ⌫
            if !workspace.query.isEmpty { workspace.query.removeLast() }
        } else if let text = typedText(event) {
            workspace.query += text
        }
        return nil
    }

    /// Печатные символы нажатия. Стрелки, Home, F1 и прочие служебные
    /// клавиши AppKit кодирует в зоне U+F700…U+F8FF, управляющие — ниже пробела.
    private static func typedText(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
              })
        else { return nil }
        return chars
    }
}
