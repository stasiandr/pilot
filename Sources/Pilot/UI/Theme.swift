import SwiftUI
import AppKit

/// Палитра подсветки — Catppuccin Macchiato. Тема одна и тёмная, поэтому
/// приложение принудительно работает в тёмном внешнем виде (см. AppDelegate):
/// иначе стекло и системные контролы в светлом режиме спорили бы с фоном.
/// Роли токенов разложены по style guide Catppuccin.
enum Theme {

    static func color(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .plain:        return Macchiato.text
        case .keyword:      return Macchiato.mauve
        case .type:         return Macchiato.yellow
        case .string:       return Macchiato.green
        case .escape:       return Macchiato.pink
        case .number:       return Macchiato.peach
        case .comment:      return Macchiato.overlay2
        case .docComment:   return Macchiato.subtext0
        case .function:     return Macchiato.blue
        case .punctuation:  return Macchiato.overlay2
        case .preprocessor: return Macchiato.pink
        case .attribute:    return Macchiato.rosewater
        case .constant:     return Macchiato.peach
        case .operatorTok:  return Macchiato.sky
        }
    }

    static var editorBackground: NSColor { Macchiato.base }

    /// Фон вхождений идентификатора под курсором. Намеренно бледный:
    /// это ориентир при чтении, а не результат поиска.
    static var occurrenceHighlight: NSColor { Macchiato.surface1 }

    /// Выделение по гайду Catppuccin: Overlay 2 с прозрачностью 20–30%.
    static var selection: NSColor { Macchiato.overlay2.withAlphaComponent(0.3) }

    static var gutterText: NSColor { Macchiato.surface1 }

    static var gutterTextCurrent: NSColor { Macchiato.lavender }

    /// Иконки боковой панели: папки заметнее файлов, чтобы структура
    /// читалась с одного взгляда.
    static var sidebarFolder: NSColor { Macchiato.blue }
    static var sidebarFile: NSColor { Macchiato.overlay2 }

    /// Шрифт редактора: Hack Nerd Font Mono, если установлен, иначе системный моноширинный.
    static func editorFont(size: CGFloat) -> NSFont {
        if let f = NSFont(name: "HackNFM-Regular", size: size) { return f }
        if let f = NSFont(name: "SF Mono", size: size) { return f }
        if let f = NSFont(name: "Menlo", size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// https://catppuccin.com/palette — flavor Macchiato.
    private enum Macchiato {
        static let rosewater = rgb(0xF4DBD6)
        static let pink      = rgb(0xF5BDE6)
        static let mauve     = rgb(0xC6A0F6)
        static let peach     = rgb(0xF5A97F)
        static let yellow    = rgb(0xEED49F)
        static let green     = rgb(0xA6DA95)
        static let sky       = rgb(0x91D7E3)
        static let blue      = rgb(0x8AADF4)
        static let lavender  = rgb(0xB7BDF8)
        static let text      = rgb(0xCAD3F5)
        static let subtext0  = rgb(0xA5ADCB)
        static let overlay2  = rgb(0x939AB7)
        static let surface1  = rgb(0x494D64)
        static let base      = rgb(0x24273A)
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green:   CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue:    CGFloat(hex & 0xFF) / 255.0,
                alpha:   1.0)
    }
}
