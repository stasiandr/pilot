import AppKit

/// Пункт меню у курсора (⌘.): что можно сделать с тем, что под ним.
struct ContextAction {
    var title: String
    /// SF Symbol слева от названия.
    var icon: String
    /// Сочетание, которым то же делается без меню, — подпись справа.
    /// Пока меню открыто, оно же и выбирает пункт.
    var shortcut: KeyShortcut? = nil
    var perform: () -> Void
}

/// Раздел меню. Заголовок — то, к чему относятся действия: имя символа,
/// «Конфликт слияния», «Строка 42».
struct ContextActionGroup {
    var title: String?
    var actions: [ContextAction]
}

struct KeyShortcut {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    init(_ functionKey: Int, _ modifiers: NSEvent.ModifierFlags) {
        self.init(String(Character(UnicodeScalar(UInt32(functionKey))!)), modifiers)
    }

    static let escape = "\u{1b}"
}
