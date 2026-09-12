import SwiftUI
import AppKit

/// Палитра подсветки. Два набора — под светлую и тёмную тему системы.
/// Цвета собраны как динамические NSColor, поэтому переключение внешнего вида
/// macOS подхватывается без перерисовки вручную.
enum Theme {

    static func color(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .plain:        return dyn(light: 0x1F2328, dark: 0xE6EDF3)
        case .keyword:      return dyn(light: 0xCF222E, dark: 0xFF7B72)
        case .type:         return dyn(light: 0x953800, dark: 0xFFA657)
        case .string:       return dyn(light: 0x0A3069, dark: 0xA5D6FF)
        case .escape:       return dyn(light: 0x0550AE, dark: 0x79C0FF)
        case .number:       return dyn(light: 0x0550AE, dark: 0x79C0FF)
        case .comment:      return dyn(light: 0x6E7781, dark: 0x8B949E)
        case .docComment:   return dyn(light: 0x57606A, dark: 0x9DA7B3)
        case .function:     return dyn(light: 0x6639BA, dark: 0xD2A8FF)
        case .punctuation:  return dyn(light: 0x57606A, dark: 0xA8B1BB)
        case .preprocessor: return dyn(light: 0x8250DF, dark: 0xD2A8FF)
        case .attribute:    return dyn(light: 0x8250DF, dark: 0xD2A8FF)
        case .constant:     return dyn(light: 0x0550AE, dark: 0x79C0FF)
        case .operatorTok:  return dyn(light: 0x0550AE, dark: 0x79C0FF)
        }
    }

    static var editorBackground: NSColor {
        dyn(light: 0xFFFFFF, dark: 0x0D1117)
    }

    /// Фон вхождений идентификатора под курсором. Намеренно бледный:
    /// это ориентир при чтении, а не результат поиска.
    static var occurrenceHighlight: NSColor {
        dyn(light: 0xDCE8F5, dark: 0x264056)
    }

    static var gutterText: NSColor {
        dyn(light: 0xB1B8C0, dark: 0x4A5460)
    }

    static var gutterTextCurrent: NSColor {
        dyn(light: 0x57606A, dark: 0xC9D1D9)
    }

    /// Шрифт редактора: моноширинный системный, с гарантированным фолбэком.
    static func editorFont(size: CGFloat) -> NSFont {
        if let f = NSFont(name: "SF Mono", size: size) { return f }
        if let f = NSFont(name: "Menlo", size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func dyn(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green:   CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue:    CGFloat(hex & 0xFF) / 255.0,
                alpha:   1.0)
    }
}
