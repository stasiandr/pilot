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

    /// Unity: методы, которые вызывает движок, ссылки на ассеты по GUID
    /// и ссылки, которым не нашлось ассета.
    static var unityEvent: NSColor { Macchiato.teal }
    static var assetLink: NSColor { Macchiato.sapphire }
    static var brokenLink: NSColor { Macchiato.red }

    /// Полоса под строкой с курсором — как в Xcode, едва заметная.
    static var currentLine: NSColor { Macchiato.surface0.withAlphaComponent(0.55) }

    /// Курсор по гайду Catppuccin — Rosewater.
    static var caret: NSColor { Macchiato.rosewater }

    /// Фон хрома вокруг редактора: чуть темнее самого текста, чтобы
    /// стеклянный сайдбар и тулбар читались отдельными слоями.
    static var chromeBackground: NSColor { Macchiato.mantle }

    static var separator: NSColor { Macchiato.surface0 }

    /// Молния быстрого индекса в статус-строке: пока навигация идёт по нему.
    static var fastIndex: NSColor { Macchiato.yellow }

    // MARK: - Иконки файлов

    struct Icon {
        let symbol: String
        let color: NSColor
    }

    static var folderIcon: Icon { Icon(symbol: "folder.fill", color: Macchiato.blue) }

    /// Иерархия сцены и префаба в дереве — как в окне Hierarchy у Unity:
    /// GameObject — серый кубик, вложенный префаб — кубик цвета префаба.
    static var gameObjectIcon: Icon { Icon(symbol: "cube", color: Macchiato.subtext0) }
    static var prefabInstanceIcon: Icon { Icon(symbol: "cube.fill", color: Macchiato.sapphire) }

    /// Иконки по типу файла. Как в навигаторе Xcode — цветные, но цвета
    /// взяты из той же Macchiato, чтобы хром не спорил с подсветкой.
    static func fileIcon(forName name: String) -> Icon {
        switch name {
        case "Package.swift":           return Icon(symbol: "shippingbox.fill", color: Macchiato.peach)
        case "Dockerfile":              return Icon(symbol: "shippingbox", color: Macchiato.sapphire)
        case "Makefile", "CMakeLists.txt": return Icon(symbol: "hammer", color: Macchiato.subtext0)
        default: break
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if let unity = unityIcon(forExtension: ext) { return unity }
        switch ext {
        case "swift":                   return Icon(symbol: "swift", color: Macchiato.peach)
        case "cs", "csx":               return Icon(symbol: "number.square", color: Macchiato.mauve)
        case "c":                       return Icon(symbol: "c.square", color: Macchiato.blue)
        case "cpp", "cc", "cxx":        return Icon(symbol: "c.square", color: Macchiato.sapphire)
        case "h", "hpp", "hh", "hxx":   return Icon(symbol: "h.square", color: Macchiato.red)
        case "m", "mm":                 return Icon(symbol: "m.square", color: Macchiato.peach)
        case "js", "mjs", "cjs", "jsx": return Icon(symbol: "curlybraces.square", color: Macchiato.yellow)
        case "ts", "tsx", "mts":        return Icon(symbol: "curlybraces.square", color: Macchiato.blue)
        case "py", "pyi":               return Icon(symbol: "p.square", color: Macchiato.blue)
        case "rs":                      return Icon(symbol: "r.square", color: Macchiato.peach)
        case "go":                      return Icon(symbol: "g.square", color: Macchiato.sky)
        case "java":                    return Icon(symbol: "j.square", color: Macchiato.red)
        case "kt", "kts":               return Icon(symbol: "k.square", color: Macchiato.mauve)
        case "rb":                      return Icon(symbol: "r.square", color: Macchiato.red)
        case "php":                     return Icon(symbol: "p.square", color: Macchiato.lavender)
        case "json":                    return Icon(symbol: "curlybraces", color: Macchiato.yellow)
        case "xml", "plist", "csproj", "sln", "props", "targets", "xaml", "storyboard", "xib":
                                        return Icon(symbol: "chevron.left.forwardslash.chevron.right", color: Macchiato.teal)
        case "html", "htm":             return Icon(symbol: "chevron.left.forwardslash.chevron.right", color: Macchiato.peach)
        case "css", "scss", "sass", "less": return Icon(symbol: "paintbrush", color: Macchiato.blue)
        case "yaml", "yml", "toml", "ini", "cfg", "conf", "editorconfig":
                                        return Icon(symbol: "gearshape", color: Macchiato.subtext0)
        case "md", "markdown", "rst":   return Icon(symbol: "doc.richtext", color: Macchiato.lavender)
        case "txt", "log":              return Icon(symbol: "doc.text", color: Macchiato.subtext0)
        case "sh", "bash", "zsh", "fish", "command": return Icon(symbol: "terminal", color: Macchiato.green)
        case "sql":                     return Icon(symbol: "cylinder", color: Macchiato.yellow)
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns", "heic", "tiff":
                                        return Icon(symbol: "photo", color: Macchiato.teal)
        case "pdf":                     return Icon(symbol: "doc.richtext", color: Macchiato.red)
        case "lock", "resolved":        return Icon(symbol: "lock", color: Macchiato.overlay2)
        default:                        return Icon(symbol: "doc", color: Macchiato.overlay2)
        }
    }

    /// Unity-ассеты: сцены, префабы, материалы, шейдеры… Цвета — по роли,
    /// как в окне Project у Unity: сцены и префабы заметнее остального.
    private static func unityIcon(forExtension ext: String) -> Icon? {
        guard let symbol = UnitySemantics.icon(forExtension: ext) else { return nil }
        let color: NSColor
        switch ext {
        case "unity":                           color = Macchiato.lavender
        case "prefab":                          color = Macchiato.sapphire
        case "mat", "physicmaterial", "physicsmaterial2d": color = Macchiato.pink
        case "shader", "hlsl", "cginc", "compute", "shadergraph", "shadersubgraph", "glsl", "vfx":
                                                color = Macchiato.mauve
        case "anim", "controller", "overridecontroller", "playable": color = Macchiato.peach
        case "asset", "preset", "lighting":     color = Macchiato.teal
        case "fbx", "obj", "blend", "dae", "3ds", "max": color = Macchiato.sky
        case "wav", "mp3", "ogg", "aif", "aiff", "flac": color = Macchiato.green
        default:                                color = Macchiato.subtext0
        }
        return Icon(symbol: symbol, color: color)
    }

    // MARK: - Бейджи символов

    /// Буква в цветном квадратике — как у символов в Xcode.
    /// Текст на бейдже тёмный: пастельные цвета Macchiato с белым не читаются.
    static func badge(for kind: OutlineKind) -> (letter: String, color: NSColor) {
        switch kind {
        case .type:        return ("C", Macchiato.mauve)
        case .method:      return ("M", Macchiato.blue)
        case .function:    return ("F", Macchiato.green)
        case .property:    return ("P", Macchiato.teal)
        case .field:       return ("V", Macchiato.sky)
        case .variable:    return ("V", Macchiato.sky)
        case .namespace:   return ("N", Macchiato.flamingo)
        case .initializer: return ("I", Macchiato.peach)
        case .enumCase:    return ("E", Macchiato.yellow)
        case .gameObject:      return ("GO", Macchiato.sapphire)
        case .component:       return ("C", Macchiato.teal)
        case .prefab:          return ("Pf", Macchiato.lavender)
        case .unityMessage:    return ("U", Macchiato.teal)
        case .serializedField: return ("SF", Macchiato.sky)
        }
    }

    /// У типов буква — по ключевому слову, как в Xcode: S — struct,
    /// E — enum, Pr — протокол. Без ключевого слова — по виду объявления.
    static func badge(for kind: OutlineKind, keyword: String?) -> (letter: String, color: NSColor) {
        if kind == .type, let keyword {
            switch keyword {
            case "struct":            return ("S", Macchiato.mauve)
            case "enum":              return ("E", Macchiato.mauve)
            case "record":            return ("R", Macchiato.mauve)
            case "protocol":          return ("Pr", Macchiato.lavender)
            case "interface":         return ("I", Macchiato.lavender)
            case "trait":             return ("T", Macchiato.lavender)
            case "extension", "impl": return ("Ex", Macchiato.overlay2)
            default: break
            }
        }
        return badge(for: kind)
    }

    /// Бейдж варианта дополнения по CompletionItemKind из LSP — те же буквы
    /// и цвета, что у структуры файла, чтобы метод выглядел методом везде.
    static func completionBadge(kind: Int) -> (letter: String, color: NSColor) {
        switch kind {
        case 2:      return ("M", Macchiato.blue)        // Method
        case 3:      return ("F", Macchiato.green)       // Function
        case 4:      return ("I", Macchiato.peach)       // Constructor
        case 5:      return ("V", Macchiato.sky)         // Field
        case 6:      return ("V", Macchiato.sky)         // Variable
        case 7:      return ("C", Macchiato.mauve)       // Class
        case 8:      return ("Pr", Macchiato.lavender)   // Interface
        case 9:      return ("N", Macchiato.flamingo)    // Module
        case 10:     return ("P", Macchiato.teal)        // Property
        case 13:     return ("E", Macchiato.mauve)       // Enum
        case 14:     return ("K", Macchiato.pink)        // Keyword
        case 15:     return ("{}", Macchiato.overlay2)   // Snippet
        case 20:     return ("E", Macchiato.yellow)      // EnumMember
        case 21:     return ("K", Macchiato.peach)       // Constant
        case 22:     return ("S", Macchiato.mauve)       // Struct
        case 23:     return ("Ev", Macchiato.yellow)     // Event
        case 24:     return ("Op", Macchiato.sky)        // Operator
        case 25:     return ("T", Macchiato.lavender)    // TypeParameter
        default:     return ("T", Macchiato.overlay2)    // Text и прочее
        }
    }

    static var badgeText: NSColor { Macchiato.crust }

    /// «1 файл», «3 файла», «7 055 файлов».
    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod100 = n % 100, mod10 = n % 10
        let word: String
        if (11...14).contains(mod100) { word = many }
        else if mod10 == 1 { word = one }
        else if (2...4).contains(mod10) { word = few }
        else { word = many }
        return "\(n.formatted()) \(word)"
    }

    /// Git: полоски у номеров строк и имена файлов в дереве. Привычные
    /// роли: добавлено зелёным, изменено жёлтым, удалено красным.
    static var gitAdded: NSColor { Macchiato.green }
    static var gitModified: NSColor { Macchiato.yellow }
    static var gitDeleted: NSColor { Macchiato.red }
    static var gitRenamed: NSColor { Macchiato.sky }
    static var gitConflicted: NSColor { Macchiato.peach }

    /// Открытый тред ревью — значок у строки. Голубой не спорит ни с одной
    /// из полосок диффа.
    static var reviewThread: NSColor { Macchiato.sky }
    /// Конфликт слияния: текущее (HEAD) — зелёным, входящее — синим,
    /// общий предок — серым, строки маркеров — персиковым, как буква U.
    static var conflictCurrent: NSColor { Macchiato.green.withAlphaComponent(0.10) }
    static var conflictIncoming: NSColor { Macchiato.blue.withAlphaComponent(0.13) }
    static var conflictBase: NSColor { Macchiato.overlay2.withAlphaComponent(0.10) }
    static var conflictMarker: NSColor { Macchiato.peach.withAlphaComponent(0.16) }

    /// Фон удалённых строк во всплывающем окне.
    static var removedLineBackground: NSColor { Macchiato.red.withAlphaComponent(0.14) }
    static var removedLineText: NSColor { Macchiato.red }

    static func git(_ state: GitFileState) -> NSColor {
        switch state {
        case .added, .untracked: return gitAdded
        case .modified:          return gitModified
        case .deleted:           return gitDeleted
        case .renamed:           return gitRenamed
        case .conflicted:        return gitConflicted
        }
    }

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
        static let flamingo  = rgb(0xF0C6C6)
        static let pink      = rgb(0xF5BDE6)
        static let red       = rgb(0xED8796)
        static let mauve     = rgb(0xC6A0F6)
        static let peach     = rgb(0xF5A97F)
        static let yellow    = rgb(0xEED49F)
        static let green     = rgb(0xA6DA95)
        static let teal      = rgb(0x8BD5CA)
        static let sky       = rgb(0x91D7E3)
        static let sapphire  = rgb(0x7DC4E4)
        static let blue      = rgb(0x8AADF4)
        static let lavender  = rgb(0xB7BDF8)
        static let text      = rgb(0xCAD3F5)
        static let subtext0  = rgb(0xA5ADCB)
        static let overlay2  = rgb(0x939AB7)
        static let surface1  = rgb(0x494D64)
        static let surface0  = rgb(0x363A4F)
        static let base      = rgb(0x24273A)
        static let mantle    = rgb(0x1E2030)
        static let crust     = rgb(0x181926)
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green:   CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue:    CGFloat(hex & 0xFF) / 255.0,
                alpha:   1.0)
    }
}
