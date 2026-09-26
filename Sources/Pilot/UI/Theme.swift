import SwiftUI
import AppKit

/// Цвета Pilot: подсветка кода и весь хром. Берутся из выбранной
/// цветовой схемы (`EditorScheme`, `ThemeStore`), поэтому читать их нужно
/// в момент рисования, а не запоминать: схему меняют на ходу.
enum Theme {

    static var current: EditorScheme { ThemeStore.shared.scheme }
    private static var P: EditorScheme.Palette { current.p }

    static func color(_ kind: TokenKind) -> NSColor {
        let s = current.syntax
        switch kind {
        case .plain:        return plainText
        case .keyword:      return s.keyword
        case .type:         return s.type
        case .string:       return s.string
        case .escape:       return s.escape
        case .number:       return s.number
        case .comment:      return s.comment
        case .docComment:   return s.docComment
        case .function:     return s.function
        case .punctuation:  return s.punctuation
        case .preprocessor: return s.preprocessor
        case .attribute:    return s.attribute
        case .constant:     return s.constant
        case .operatorTok:  return s.operatorTok
        case .disabled:     return s.disabled
        }
    }

    /// Обычный текст и фон редактора — динамические цвета: они запечены
    /// в атрибуты текста каждой вкладки и в фоны AppKit-видов, а так
    /// берут значение из схемы при каждой отрисовке и перекрашивать их
    /// при смене схемы не нужно.
    private static let plainText = NSColor(name: "PilotText") { _ in ThemeStore.shared.scheme.p.text }
    private static let background = NSColor(name: "PilotBackground") { _ in ThemeStore.shared.scheme.p.base }

    static var editorBackground: NSColor { background }

    /// Фон вхождений идентификатора под курсором. Намеренно бледный:
    /// это ориентир при чтении, а не результат поиска.
    static var occurrenceHighlight: NSColor { current.occurrence }

    static var selection: NSColor { current.selection }

    static var gutterText: NSColor { current.gutter }

    static var gutterTextCurrent: NSColor { current.gutterCurrent }

    /// Unity: методы, которые вызывает движок, ссылки на ассеты по GUID
    /// и ссылки, которым не нашлось ассета.
    static var unityEvent: NSColor { P.teal }
    static var assetLink: NSColor { P.sapphire }
    static var brokenLink: NSColor { P.red }

    /// Волна под ошибкой и предупреждением, значок в гаттере.
    static var diagnosticError: NSColor { P.red }
    static var diagnosticWarning: NSColor { P.yellow }
    /// Стрелки сворачивания и рамка «⋯» вместо свёрнутого.
    static var foldMarker: NSColor { P.overlay2 }

    /// Подсказки в строке (`count:`, `int`) и «3 использования» над
    /// объявлением — как в Rider: тише кода, но читаются.
    static var inlayHintText: NSColor { P.overlay2 }
    static var inlayHintBackground: NSColor { P.surface0.withAlphaComponent(0.75) }
    static var codeLensText: NSColor { P.overlay2 }
    static var codeLensHover: NSColor { P.blue }

    /// Полоса под строкой с курсором — как в Xcode, едва заметная.
    static var currentLine: NSColor { P.surface0.withAlphaComponent(0.55) }

    /// Отладка: ярлык точки останова — как у Xcode, синий; строка, где
    /// стоит программа, — зелёная стрелка и едва зелёная полоса под текстом.
    static var breakpoint: NSColor { P.blue }
    static var breakpointText: NSColor { P.crust }
    static var debugExecution: NSColor { P.green }
    static var debugExecutionLine: NSColor { P.green.withAlphaComponent(0.16) }

    static var caret: NSColor { current.caret }

    /// Фон хрома вокруг редактора: чуть темнее самого текста, чтобы
    /// стеклянный сайдбар и тулбар читались отдельными слоями.
    static var chromeBackground: NSColor { P.mantle }

    static var separator: NSColor { P.surface0 }

    /// Вкладки: активная — плашкой, под курсором — её тенью.
    static var tabActive: NSColor { P.surface0 }
    static var tabHover: NSColor { P.surface0.withAlphaComponent(0.45) }

    /// Молния быстрого индекса в статус-строке: пока навигация идёт по нему.
    static var fastIndex: NSColor { P.yellow }

    // MARK: - Иконки файлов

    struct Icon {
        let symbol: String
        let color: NSColor
    }

    static var folderIcon: Icon { Icon(symbol: "folder.fill", color: P.blue) }

    /// Иерархия сцены и префаба в дереве — как в окне Hierarchy у Unity:
    /// GameObject — серый кубик, вложенный префаб — кубик цвета префаба.
    static var gameObjectIcon: Icon { Icon(symbol: "cube", color: P.subtext0) }
    static var prefabInstanceIcon: Icon { Icon(symbol: "cube.fill", color: P.sapphire) }

    /// Иконки по типу файла. Как в навигаторе Xcode — цветные, но цвета
    /// взяты из той же палитры, чтобы хром не спорил с подсветкой.
    static func fileIcon(forName name: String) -> Icon {
        switch name {
        case "Package.swift":           return Icon(symbol: "shippingbox.fill", color: P.peach)
        case "Dockerfile":              return Icon(symbol: "shippingbox", color: P.sapphire)
        case "Makefile", "CMakeLists.txt": return Icon(symbol: "hammer", color: P.subtext0)
        default: break
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if let unity = unityIcon(forExtension: ext) { return unity }
        switch ext {
        case "swift":                   return Icon(symbol: "swift", color: P.peach)
        case "cs", "csx":               return Icon(symbol: "number.square", color: P.mauve)
        case "c":                       return Icon(symbol: "c.square", color: P.blue)
        case "cpp", "cc", "cxx":        return Icon(symbol: "c.square", color: P.sapphire)
        case "h", "hpp", "hh", "hxx":   return Icon(symbol: "h.square", color: P.red)
        case "m", "mm":                 return Icon(symbol: "m.square", color: P.peach)
        case "js", "mjs", "cjs", "jsx": return Icon(symbol: "curlybraces.square", color: P.yellow)
        case "ts", "tsx", "mts":        return Icon(symbol: "curlybraces.square", color: P.blue)
        case "py", "pyi":               return Icon(symbol: "p.square", color: P.blue)
        case "rs":                      return Icon(symbol: "r.square", color: P.peach)
        case "go":                      return Icon(symbol: "g.square", color: P.sky)
        case "java":                    return Icon(symbol: "j.square", color: P.red)
        case "kt", "kts":               return Icon(symbol: "k.square", color: P.mauve)
        case "rb":                      return Icon(symbol: "r.square", color: P.red)
        case "php":                     return Icon(symbol: "p.square", color: P.lavender)
        case "json":                    return Icon(symbol: "curlybraces", color: P.yellow)
        case "xml", "plist", "csproj", "sln", "props", "targets", "xaml", "storyboard", "xib":
                                        return Icon(symbol: "chevron.left.forwardslash.chevron.right", color: P.teal)
        case "html", "htm":             return Icon(symbol: "chevron.left.forwardslash.chevron.right", color: P.peach)
        case "css", "scss", "sass", "less": return Icon(symbol: "paintbrush", color: P.blue)
        case "yaml", "yml", "toml", "ini", "cfg", "conf", "editorconfig":
                                        return Icon(symbol: "gearshape", color: P.subtext0)
        case "md", "markdown", "rst":   return Icon(symbol: "doc.richtext", color: P.lavender)
        case "txt", "log":              return Icon(symbol: "doc.text", color: P.subtext0)
        case "sh", "bash", "zsh", "fish", "command": return Icon(symbol: "terminal", color: P.green)
        case "sql":                     return Icon(symbol: "cylinder", color: P.yellow)
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns", "heic", "tiff":
                                        return Icon(symbol: "photo", color: P.teal)
        case "pdf":                     return Icon(symbol: "doc.richtext", color: P.red)
        case "dll", "exe", "winmd":     return Icon(symbol: "shippingbox", color: P.mauve)
        case "lock", "resolved":        return Icon(symbol: "lock", color: P.overlay2)
        default:                        return Icon(symbol: "doc", color: P.overlay2)
        }
    }

    /// Unity-ассеты: сцены, префабы, материалы, шейдеры… Цвета — по роли,
    /// как в окне Project у Unity: сцены и префабы заметнее остального.
    private static func unityIcon(forExtension ext: String) -> Icon? {
        guard let symbol = UnitySemantics.icon(forExtension: ext) else { return nil }
        let color: NSColor
        switch ext {
        case "unity":                           color = P.lavender
        case "prefab":                          color = P.sapphire
        case "mat", "physicmaterial", "physicsmaterial2d": color = P.pink
        case "shader", "hlsl", "cginc", "compute", "shadergraph", "shadersubgraph", "glsl", "vfx":
                                                color = P.mauve
        case "anim", "controller", "overridecontroller", "playable": color = P.peach
        case "asset", "preset", "lighting":     color = P.teal
        case "fbx", "obj", "blend", "dae", "3ds", "max": color = P.sky
        case "wav", "mp3", "ogg", "aif", "aiff", "flac": color = P.green
        default:                                color = P.subtext0
        }
        return Icon(symbol: symbol, color: color)
    }

    // MARK: - Бейджи символов

    /// Буква в цветном квадратике — как у символов в Xcode.
    /// Текст на бейдже тёмный: пастельные цвета тёмных схем с белым не читаются;
    /// у светлых схем `crust` светлый, а акценты тёмные.
    static func badge(for kind: OutlineKind) -> (letter: String, color: NSColor) {
        switch kind {
        case .type:        return ("C", P.mauve)
        case .method:      return ("M", P.blue)
        case .function:    return ("F", P.green)
        case .property:    return ("P", P.teal)
        case .field:       return ("V", P.sky)
        case .variable:    return ("V", P.sky)
        case .namespace:   return ("N", P.flamingo)
        case .initializer: return ("I", P.peach)
        case .enumCase:    return ("E", P.yellow)
        case .gameObject:      return ("GO", P.sapphire)
        case .component:       return ("C", P.teal)
        case .prefab:          return ("Pf", P.lavender)
        case .unityMessage:    return ("U", P.teal)
        case .serializedField: return ("SF", P.sky)
        case .heading:         return ("H", P.overlay2)
        }
    }

    /// У типов буква — по ключевому слову, как в Xcode: S — struct,
    /// E — enum, Pr — протокол. Без ключевого слова — по виду объявления.
    static func badge(for kind: OutlineKind, keyword: String?) -> (letter: String, color: NSColor) {
        if kind == .type, let keyword {
            switch keyword {
            case "struct":            return ("S", P.mauve)
            case "enum":              return ("E", P.mauve)
            case "record":            return ("R", P.mauve)
            case "protocol":          return ("Pr", P.lavender)
            case "interface":         return ("I", P.lavender)
            case "trait":             return ("T", P.lavender)
            case "extension", "impl": return ("Ex", P.overlay2)
            default: break
            }
        }
        return badge(for: kind)
    }

    /// Бейдж варианта дополнения по CompletionItemKind из LSP — те же буквы
    /// и цвета, что у структуры файла, чтобы метод выглядел методом везде.
    static func completionBadge(kind: Int) -> (letter: String, color: NSColor) {
        switch kind {
        case 2:      return ("M", P.blue)        // Method
        case 3:      return ("F", P.green)       // Function
        case 4:      return ("I", P.peach)       // Constructor
        case 5:      return ("V", P.sky)         // Field
        case 6:      return ("V", P.sky)         // Variable
        case 7:      return ("C", P.mauve)       // Class
        case 8:      return ("Pr", P.lavender)   // Interface
        case 9:      return ("N", P.flamingo)    // Module
        case 10:     return ("P", P.teal)        // Property
        case 13:     return ("E", P.mauve)       // Enum
        case 14:     return ("K", P.pink)        // Keyword
        case 15:     return ("{}", P.overlay2)   // Snippet
        case 20:     return ("E", P.yellow)      // EnumMember
        case 21:     return ("K", P.peach)       // Constant
        case 22:     return ("S", P.mauve)       // Struct
        case 23:     return ("Ev", P.yellow)     // Event
        case 24:     return ("Op", P.sky)        // Operator
        case 25:     return ("T", P.lavender)    // TypeParameter
        default:     return ("T", P.overlay2)    // Text и прочее
        }
    }

    static var badgeText: NSColor { P.crust }

    /// «1 файл», «3 файла», «7 055 файлов» — на языке интерфейса: формы
    /// берутся из перевода по ключу `"файл|файла|файлов"`.
    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        Localization.count(n, one, few, many)
    }

    /// Git: полоски у номеров строк и имена файлов в дереве. Привычные
    /// роли: добавлено зелёным, изменено жёлтым, удалено красным.
    static var gitAdded: NSColor { P.green }
    static var gitModified: NSColor { P.yellow }
    static var gitDeleted: NSColor { P.red }
    static var gitRenamed: NSColor { P.sky }
    static var gitConflicted: NSColor { P.peach }

    /// Открытый тред ревью — значок у строки. Голубой не спорит ни с одной
    /// из полосок диффа.
    static var reviewThread: NSColor { P.sky }
    /// Слитый MR в результатах поиска — лиловым, как принято в GitHub и GitLab.
    static var reviewMerged: NSColor { P.mauve }
    /// Конфликт слияния: текущее (HEAD) — зелёным, входящее — синим,
    /// общий предок — серым, строки маркеров — персиковым, как буква U.
    static var conflictCurrent: NSColor { P.green.withAlphaComponent(0.10) }
    static var conflictIncoming: NSColor { P.blue.withAlphaComponent(0.13) }
    static var conflictBase: NSColor { P.overlay2.withAlphaComponent(0.10) }
    static var conflictMarker: NSColor { P.peach.withAlphaComponent(0.16) }

    /// Фон удалённых строк во всплывающем окне.
    static var removedLineBackground: NSColor { P.red.withAlphaComponent(0.14) }
    static var removedLineText: NSColor { P.red }

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

    /// Смысловая подсветка декомпилированного кода: jadx знает про каждый
    /// токен, класс это, метод или поле, — лексеру такое не под силу.
    /// Переменные и пакеты остаются обычным текстом.
    static func decompiledColor(_ kind: DecompiledSpan.Kind) -> NSColor? {
        switch kind {
        case .declClass, .refClass:   return current.syntax.type
        case .declMethod, .refMethod: return current.syntax.function
        case .declField, .refField:   return current.syntax.field
        case .declVariable, .refVariable, .refPackage: return nil
        }
    }

    // MARK: - Markdown

    /// Стили свёрстанного Markdown — в той же палитре, что и редактор.
    static var markdownCSS: String {
        func hex(_ c: NSColor) -> String {
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                          Int(rgb.blueComponent * 255))
        }
        func rgba(_ c: NSColor, _ alpha: Double) -> String {
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return "rgba(\(Int(rgb.redComponent * 255)),\(Int(rgb.greenComponent * 255)),"
                + "\(Int(rgb.blueComponent * 255)),\(alpha))"
        }
        let M = P
        var tokens = ""
        for raw in 0...UInt8(13) {
            guard let kind = TokenKind(rawValue: raw), kind != .plain else { continue }
            tokens += ".t-\(kind){color:\(hex(color(kind)))}"
            if kind == .comment || kind == .docComment { tokens += ".t-\(kind){font-style:italic}" }
        }
        return """
        :root{color-scheme:\(current.isDark ? "dark" : "light")}
        html,body{background:\(hex(M.base));margin:0}
        body{color:\(hex(M.text));font:15px/1.65 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;
          -webkit-font-smoothing:antialiased;padding:28px 40px 80px}
        main{max-width:860px;margin:0 auto}
        h1,h2,h3,h4,h5,h6{color:\(hex(M.text));font-weight:650;line-height:1.25;margin:1.6em 0 .6em;scroll-margin-top:16px}
        h1{font-size:2em;padding-bottom:.3em;border-bottom:1px solid \(hex(M.surface0))}
        h2{font-size:1.5em;padding-bottom:.25em;border-bottom:1px solid \(hex(M.surface0))}
        h3{font-size:1.25em}h4{font-size:1.05em}h5,h6{font-size:.95em;color:\(hex(M.subtext0))}
        main>:first-child{margin-top:0}
        p,ul,ol,table,pre,blockquote,.alert,details{margin:0 0 1em}
        a{color:\(hex(M.blue));text-decoration:none}a:hover{text-decoration:underline}
        strong{color:\(hex(M.text));font-weight:650}em{color:\(hex(M.text))}del{color:\(hex(M.overlay2))}
        code{font:.88em/1.5 "HackNFM-Regular","SF Mono",Menlo,monospace;background:\(hex(M.surface0));
          color:\(hex(M.rosewater));padding:.12em .38em;border-radius:5px}
        pre{background:\(hex(M.mantle));border:1px solid \(hex(M.surface0));border-radius:9px;padding:14px 16px;
          overflow-x:auto;position:relative}
        pre code{background:none;color:\(hex(M.text));padding:0;font-size:13px;line-height:1.55}
        pre[data-lang]::after{content:attr(data-lang);position:absolute;top:6px;right:10px;font:11px -apple-system,sans-serif;
          color:\(hex(M.overlay2))}
        pre.front-matter{border-style:dashed}
        blockquote{margin-left:0;padding:.1em 1em;border-left:3px solid \(hex(M.surface1));color:\(hex(M.subtext0))}
        ul,ol{padding-left:1.7em}li{margin:.2em 0}li>p{margin:.3em 0}
        li::marker{color:\(hex(M.overlay2))}
        li.task{list-style:none}
        li.task input{margin:0 .45em 0 -1.35em;vertical-align:-1px;accent-color:\(hex(M.green))}
        hr{border:none;border-top:1px solid \(hex(M.surface1));margin:2em 0}
        table{border-collapse:collapse;display:block;overflow-x:auto;max-width:100%}
        th,td{border:1px solid \(hex(M.surface0));padding:6px 12px;vertical-align:top}
        th{background:\(hex(M.mantle));font-weight:600}
        tr:nth-child(even) td{background:\(rgba(M.surface0, 0.35))}
        img{max-width:100%;border-radius:4px}
        kbd{font:12px "SF Mono",monospace;border:1px solid \(hex(M.surface1));border-bottom-width:2px;border-radius:4px;
          padding:1px 5px;background:\(hex(M.surface0))}
        details{border:1px solid \(hex(M.surface0));border-radius:8px;padding:.5em 1em}
        summary{cursor:pointer;color:\(hex(M.subtext0))}
        .alert{border-left:3px solid;padding:.6em 1em;border-radius:0 8px 8px 0;background:\(hex(M.mantle))}
        .alert>:last-child{margin-bottom:0}
        .alert-title{font-weight:650;margin:0 0 .3em}
        .alert-note{border-color:\(hex(M.blue))}.alert-note .alert-title{color:\(hex(M.blue))}
        .alert-tip{border-color:\(hex(M.green))}.alert-tip .alert-title{color:\(hex(M.green))}
        .alert-important{border-color:\(hex(M.mauve))}.alert-important .alert-title{color:\(hex(M.mauve))}
        .alert-warning{border-color:\(hex(M.yellow))}.alert-warning .alert-title{color:\(hex(M.yellow))}
        .alert-caution{border-color:\(hex(M.red))}.alert-caution .alert-title{color:\(hex(M.red))}
        ::selection{background:\(rgba(current.selection, current.selection.alphaComponent < 1 ? current.selection.alphaComponent : 0.6))}
        .flash{animation:flash 1.2s ease-out}
        @keyframes flash{from{background:\(rgba(M.lavender, 0.18))}to{background:transparent}}
        \(tokens)
        """
    }
}
