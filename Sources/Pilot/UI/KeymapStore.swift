import AppKit
import SwiftUI

/// Сочетания клавиш Pilot: что по умолчанию, что поменяли, где это лежит.
///
/// Файл — `~/Library/Application Support/Pilot/keybindings.json`, в нём
/// только поменянное. Его можно править руками и носить между машинами;
/// Pilot перечитывает его при запуске и при каждом открытии настроек.
@MainActor
final class KeymapStore: ObservableObject {
    static let shared = KeymapStore()

    @Published private(set) var keymap = Keymap()

    let fileURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Pilot", isDirectory: true)
        .appendingPathComponent("keybindings.json")

    private init() { reload() }

    func reload() {
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let parsed = Keymap.parse(text)
        if parsed != keymap { keymap = parsed }
    }

    func set(_ shortcut: Shortcut?, for command: EditorCommand) {
        keymap.set(shortcut, for: command)
        save()
    }

    func reset(_ command: EditorCommand) {
        keymap.reset(command)
        save()
    }

    func resetAll() {
        keymap.resetAll()
        save()
    }

    /// Раскладка целиком — после импорта из Rider.
    func replace(with keymap: Keymap) {
        self.keymap = keymap
        save()
    }

    /// Файл, который можно показать в Finder: если его ещё нет — пустой.
    func revealableFile() -> URL? {
        guard let fileURL else { return nil }
        if !FileManager.default.fileExists(atPath: fileURL.path) { save() }
        return fileURL
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? keymap.serialized().write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Для меню и подсказок

    /// Сочетание пункта меню SwiftUI; `nil` — без сочетания.
    func keyboardShortcut(_ command: EditorCommand) -> KeyboardShortcut? {
        keymap.shortcut(for: command).flatMap(Self.keyboardShortcut)
    }

    /// Подпись справа в меню ⌘. — то же сочетание в виде AppKit.
    func menuShortcut(_ command: EditorCommand) -> KeyShortcut? {
        guard let shortcut = keymap.shortcut(for: command) else { return nil }
        return KeyShortcut(Self.keyEquivalent(shortcut), Self.modifierFlags(shortcut))
    }

    /// `⌘B` — для подсказок; пусто, если сочетания нет.
    func display(_ command: EditorCommand) -> String {
        keymap.shortcut(for: command)?.display ?? ""
    }

    /// «Назад (⌘[)» — подпись с сочетанием, если оно есть.
    func help(_ text: String, _ command: EditorCommand) -> String {
        let keys = display(command)
        return keys.isEmpty ? text : "\(text) (\(keys))"
    }

    // MARK: - Перевод

    static func keyboardShortcut(_ shortcut: Shortcut) -> KeyboardShortcut? {
        let key: KeyEquivalent
        switch shortcut.key {
        case "up": key = .upArrow
        case "down": key = .downArrow
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        case "delete": key = .delete
        case "forwardDelete": key = .deleteForward
        case "escape": key = .escape
        case "space": key = .space
        case "return": key = .return
        case "tab": key = .tab
        case "home": key = .home
        case "end": key = .end
        case "pageUp": key = .pageUp
        case "pageDown": key = .pageDown
        default:
            if let n = shortcut.functionNumber,
               let scalar = UnicodeScalar(UInt32(NSF1FunctionKey + n - 1)) {
                key = KeyEquivalent(Character(scalar))
            } else if let character = shortcut.key.first, shortcut.key.count == 1 {
                key = KeyEquivalent(character)
            } else {
                return nil
            }
        }
        var modifiers: EventModifiers = []
        if shortcut.command { modifiers.insert(.command) }
        if shortcut.option { modifiers.insert(.option) }
        if shortcut.control { modifiers.insert(.control) }
        if shortcut.shift { modifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    /// Символ для `NSMenuItem.keyEquivalent`.
    static func keyEquivalent(_ shortcut: Shortcut) -> String {
        let functionKey: Int?
        switch shortcut.key {
        case "up": functionKey = NSUpArrowFunctionKey
        case "down": functionKey = NSDownArrowFunctionKey
        case "left": functionKey = NSLeftArrowFunctionKey
        case "right": functionKey = NSRightArrowFunctionKey
        case "forwardDelete": functionKey = NSDeleteFunctionKey
        case "home": functionKey = NSHomeFunctionKey
        case "end": functionKey = NSEndFunctionKey
        case "pageUp": functionKey = NSPageUpFunctionKey
        case "pageDown": functionKey = NSPageDownFunctionKey
        case "delete": return "\u{8}"
        case "escape": return KeyShortcut.escape
        case "space": return " "
        case "return": return "\r"
        case "tab": return "\t"
        default: functionKey = shortcut.functionNumber.map { NSF1FunctionKey + $0 - 1 }
        }
        if let functionKey, let scalar = UnicodeScalar(UInt32(functionKey)) {
            return String(Character(scalar))
        }
        return shortcut.key
    }

    static func modifierFlags(_ shortcut: Shortcut) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.command { flags.insert(.command) }
        if shortcut.option { flags.insert(.option) }
        if shortcut.control { flags.insert(.control) }
        if shortcut.shift { flags.insert(.shift) }
        return flags
    }

    /// Нажатие — в сочетание: код клавиши для стрелок и функциональных,
    /// символ без модификаторов для остальных (`⇧⌘/` — это `/`, а не `?`).
    static func shortcut(from event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String
        if let named = Shortcut.namedKey(forKeyCode: event.keyCode) {
            key = named
        } else if let character = event.characters(byApplyingModifiers: [])?.lowercased(),
                  character.count == 1 {
            key = character
        } else {
            return nil
        }
        let shortcut = Shortcut(key, command: flags.contains(.command), option: flags.contains(.option),
                                control: flags.contains(.control), shift: flags.contains(.shift))
        return shortcut.isValid ? shortcut : nil
    }
}
