import AppKit
import Observation

/// Цветовая схема: палитра хрома и роли токенов.
///
/// Палитра разложена по слотам Catppuccin — от `crust` до `text` и
/// тринадцать акцентов. Весь хром (иконки файлов, бейджи, git, ревью)
/// берёт цвет из слота, поэтому чужой схеме достаточно разложить свои
/// цвета по тем же слотам. Подсветку кода схема задаёт явно: у Rider,
/// Darcula или Monokai роли токенов свои, и выводить их из палитры
/// значило бы переврать схему.
struct EditorScheme: Identifiable, Equatable {
    struct Palette {
        let crust, mantle, base, surface0, surface1, overlay2, subtext0, text: NSColor
        let rosewater, flamingo, pink, red, mauve, peach, yellow, green, teal, sky, sapphire, blue, lavender: NSColor
    }

    struct Syntax {
        let keyword, type, string, escape, number, comment, docComment, function,
            punctuation, preprocessor, attribute, constant, operatorTok, field, disabled: NSColor
    }

    enum Family: String, CaseIterable {
        case rider = "Rider"
        case catppuccin = "Catppuccin"
        case popular = "Популярные"
    }

    let id: String
    let name: String
    let family: Family
    let isDark: Bool
    let p: Palette
    let syntax: Syntax
    let caret: NSColor
    let selection: NSColor
    /// Фон вхождений идентификатора под курсором.
    let occurrence: NSColor
    let gutter: NSColor
    let gutterCurrent: NSColor

    static func == (a: EditorScheme, b: EditorScheme) -> Bool { a.id == b.id }
}

// MARK: - Хранилище

/// Выбранная схема. `@Observable`: SwiftUI сам следит, какие виды читали
/// `Theme.*`, и перерисовывает их при смене схемы. AppKit-частям — тексту,
/// гаттеру, дереву, Markdown — уходит `didChange`: свои цвета они
/// раскладывают сами и заранее.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    static let didChange = Notification.Name("PilotColorSchemeDidChange")
    private static let key = "pilot.colorScheme"

    private(set) var scheme: EditorScheme

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        scheme = EditorScheme.all.first { $0.id == saved } ?? EditorScheme.default
    }

    @MainActor
    func select(_ id: String) {
        guard id != scheme.id, let next = EditorScheme.all.first(where: { $0.id == id }) else { return }
        scheme = next
        UserDefaults.standard.set(id, forKey: Self.key)
        applyAppearance()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        // Хром, нарисованный AppKit'ом из статичных цветов, сам не узнает
        // о смене: между двумя тёмными схемами внешний вид не меняется.
        for window in NSApp.windows { window.contentView.map(Self.redraw) }
    }

    /// Стекло и системные контролы — в тон схеме: светлая схема на тёмном
    /// хроме (и наоборот) выглядит чужой.
    @MainActor
    func applyAppearance() {
        NSApp.appearance = NSAppearance(named: scheme.isDark ? .darkAqua : .aqua)
    }

    @MainActor
    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }
}

// MARK: - Схемы

extension EditorScheme {
    static let `default` = catppuccinMacchiato

    static let all: [EditorScheme] = [
        riderDark, riderLight, darcula, intellijLight,
        catppuccinLatte, catppuccinFrappe, catppuccinMacchiato, catppuccinMocha,
        oneDark, dracula, monokai, nord, gruvboxDark, tokyoNight,
        githubDark, githubLight, solarizedDark, solarizedLight,
    ]

    // MARK: Rider

    /// Схемы Rider «Rider Dark» и «Rider Light» — цвета ReSharper-подсветки.
    static let riderDark = EditorScheme(
        id: "rider-dark", name: "Rider Dark", family: .rider, isDark: true,
        p: Palette(
            crust: rgb(0x1A1A1A), mantle: rgb(0x1F1F1F), base: rgb(0x262626),
            surface0: rgb(0x333333), surface1: rgb(0x4A4A4A), overlay2: rgb(0x808080),
            subtext0: rgb(0xA0A0A0), text: rgb(0xD0D0D0),
            rosewater: rgb(0xE6C8B0), flamingo: rgb(0xE8A7A7), pink: rgb(0xED94C0), red: rgb(0xFF5647),
            mauve: rgb(0xC191FF), peach: rgb(0xE0955A), yellow: rgb(0xF5D86A), green: rgb(0x85C46C),
            teal: rgb(0x39CC8F), sky: rgb(0x66C3CC), sapphire: rgb(0x4FA8D8), blue: rgb(0x6C95EB),
            lavender: rgb(0xA5B4F5)),
        syntax: Syntax(
            keyword: rgb(0x6C95EB), type: rgb(0xC191FF), string: rgb(0xC9A26D), escape: rgb(0xD688D4),
            number: rgb(0xED94C0), comment: rgb(0x85C46C), docComment: rgb(0x85C46C), function: rgb(0x39CC8F),
            punctuation: rgb(0xD0D0D0), preprocessor: rgb(0x8F8F8F), attribute: rgb(0xC191FF),
            constant: rgb(0x66C3CC), operatorTok: rgb(0xD0D0D0), field: rgb(0x66C3CC), disabled: rgb(0x5C5C5C)),
        caret: rgb(0xD0D0D0), selection: rgb(0x214283), occurrence: rgb(0x373F4F),
        gutter: rgb(0x6E6E6E), gutterCurrent: rgb(0xC0C0C0))

    static let riderLight = EditorScheme(
        id: "rider-light", name: "Rider Light", family: .rider, isDark: false,
        p: Palette(
            crust: rgb(0xFFFFFF), mantle: rgb(0xF7F8FA), base: rgb(0xFFFFFF),
            surface0: rgb(0xEBECF0), surface1: rgb(0xC9CCD6), overlay2: rgb(0x818594),
            subtext0: rgb(0x5A5D6B), text: rgb(0x202020),
            rosewater: rgb(0xB35E40), flamingo: rgb(0xC24E4E), pink: rgb(0xAB2F6B), red: rgb(0xD91400),
            mauve: rgb(0x6B2FBA), peach: rgb(0xB85E00), yellow: rgb(0x826A00), green: rgb(0x248700),
            teal: rgb(0x00855F), sky: rgb(0x0093A1), sapphire: rgb(0x1478A8), blue: rgb(0x0F54D6),
            lavender: rgb(0x4A5CCB)),
        syntax: Syntax(
            keyword: rgb(0x0F54D6), type: rgb(0x6B2FBA), string: rgb(0x8C6C41), escape: rgb(0xAB2F6B),
            number: rgb(0xAB2F6B), comment: rgb(0x248700), docComment: rgb(0x248700), function: rgb(0x00855F),
            punctuation: rgb(0x202020), preprocessor: rgb(0x808080), attribute: rgb(0x6B2FBA),
            constant: rgb(0x0093A1), operatorTok: rgb(0x202020), field: rgb(0x0093A1), disabled: rgb(0xB0B0B0)),
        caret: rgb(0x000000), selection: rgb(0xA6D2FF), occurrence: rgb(0xE4E4FF),
        gutter: rgb(0xADADAD), gutterCurrent: rgb(0x505050))

    /// Классическая тёмная схема IntelliJ, в Rider она тоже есть.
    static let darcula = EditorScheme(
        id: "darcula", name: "Darcula", family: .rider, isDark: true,
        p: Palette(
            crust: rgb(0x1E1E1E), mantle: rgb(0x252526), base: rgb(0x2B2B2B),
            surface0: rgb(0x353739), surface1: rgb(0x4A4C4E), overlay2: rgb(0x808080),
            subtext0: rgb(0x9EA3A8), text: rgb(0xA9B7C6),
            rosewater: rgb(0xE8BF6A), flamingo: rgb(0xD69A8E), pink: rgb(0xC77DBB), red: rgb(0xFF6B68),
            mauve: rgb(0x9876AA), peach: rgb(0xCC7832), yellow: rgb(0xFFC66D), green: rgb(0x6A8759),
            teal: rgb(0x4FB6A8), sky: rgb(0x6CB6D6), sapphire: rgb(0x6897BB), blue: rgb(0x5394EC),
            lavender: rgb(0x9EA7D9)),
        syntax: Syntax(
            keyword: rgb(0xCC7832), type: rgb(0xA9B7C6), string: rgb(0x6A8759), escape: rgb(0xCC7832),
            number: rgb(0x6897BB), comment: rgb(0x808080), docComment: rgb(0x629755), function: rgb(0xFFC66D),
            punctuation: rgb(0xA9B7C6), preprocessor: rgb(0xBBB529), attribute: rgb(0xBBB529),
            constant: rgb(0x9876AA), operatorTok: rgb(0xA9B7C6), field: rgb(0x9876AA), disabled: rgb(0x606366)),
        caret: rgb(0xBBBBBB), selection: rgb(0x214283), occurrence: rgb(0x344134),
        gutter: rgb(0x606366), gutterCurrent: rgb(0xA4A3A3))

    /// «IntelliJ Light» — светлая классика JetBrains.
    static let intellijLight = EditorScheme(
        id: "intellij-light", name: "IntelliJ Light", family: .rider, isDark: false,
        p: Palette(
            crust: rgb(0xFFFFFF), mantle: rgb(0xF7F8FA), base: rgb(0xFFFFFF),
            surface0: rgb(0xEBEDF2), surface1: rgb(0xC9CCD6), overlay2: rgb(0x8C8C8C),
            subtext0: rgb(0x5E6068), text: rgb(0x080808),
            rosewater: rgb(0xB0695A), flamingo: rgb(0xC75450), pink: rgb(0xB200B2), red: rgb(0xC7222D),
            mauve: rgb(0x871094), peach: rgb(0xB35C00), yellow: rgb(0x9E880D), green: rgb(0x067D17),
            teal: rgb(0x00627A), sky: rgb(0x1F7FA8), sapphire: rgb(0x1750EB), blue: rgb(0x0033B3),
            lavender: rgb(0x5059C9)),
        syntax: Syntax(
            keyword: rgb(0x0033B3), type: rgb(0x080808), string: rgb(0x067D17), escape: rgb(0x0037A6),
            number: rgb(0x1750EB), comment: rgb(0x8C8C8C), docComment: rgb(0x8C8C8C), function: rgb(0x00627A),
            punctuation: rgb(0x080808), preprocessor: rgb(0x1F542E), attribute: rgb(0x9E880D),
            constant: rgb(0x871094), operatorTok: rgb(0x080808), field: rgb(0x871094), disabled: rgb(0xB0B0B0)),
        caret: rgb(0x000000), selection: rgb(0xA6D2FF), occurrence: rgb(0xEDEBFC),
        gutter: rgb(0xADADAD), gutterCurrent: rgb(0x505050))

    // MARK: Catppuccin

    /// https://catppuccin.com/palette. Роли токенов — по style guide Catppuccin,
    /// у всех четырёх вкусов одинаковые.
    private static func catppuccin(_ id: String, _ name: String, dark: Bool, _ p: Palette) -> EditorScheme {
        EditorScheme(
            id: id, name: name, family: .catppuccin, isDark: dark, p: p,
            syntax: Syntax(
                keyword: p.mauve, type: p.yellow, string: p.green, escape: p.pink, number: p.peach,
                comment: p.overlay2, docComment: p.subtext0, function: p.blue, punctuation: p.overlay2,
                preprocessor: p.pink, attribute: p.rosewater, constant: p.peach, operatorTok: p.sky,
                field: p.teal,
                // Приглушённо, но не как комментарий: код в невзятой ветке `#if`
                // читают — просто помня, что собирается не он.
                disabled: p.surface1),
            // Курсор — Rosewater, выделение — Overlay 2 с прозрачностью 20–30%.
            caret: p.rosewater, selection: p.overlay2.withAlphaComponent(0.3),
            // В Latte Surface 1 под словом слишком плотный — там хватает Surface 0.
            occurrence: dark ? p.surface1 : p.surface0, gutter: p.surface1, gutterCurrent: p.lavender)
    }

    static let catppuccinLatte = catppuccin("catppuccin-latte", "Catppuccin Latte", dark: false, Palette(
        crust: rgb(0xDCE0E8), mantle: rgb(0xE6E9EF), base: rgb(0xEFF1F5),
        surface0: rgb(0xCCD0DA), surface1: rgb(0xBCC0CC), overlay2: rgb(0x7C7F93),
        subtext0: rgb(0x6C6F85), text: rgb(0x4C4F69),
        rosewater: rgb(0xDC8A78), flamingo: rgb(0xDD7878), pink: rgb(0xEA76CB), red: rgb(0xD20F39),
        mauve: rgb(0x8839EF), peach: rgb(0xFE640B), yellow: rgb(0xDF8E1D), green: rgb(0x40A02B),
        teal: rgb(0x179299), sky: rgb(0x04A5E5), sapphire: rgb(0x209FB5), blue: rgb(0x1E66F5),
        lavender: rgb(0x7287FD)))

    static let catppuccinFrappe = catppuccin("catppuccin-frappe", "Catppuccin Frappé", dark: true, Palette(
        crust: rgb(0x232634), mantle: rgb(0x292C3C), base: rgb(0x303446),
        surface0: rgb(0x414559), surface1: rgb(0x51576D), overlay2: rgb(0x949CBB),
        subtext0: rgb(0xA5ADCE), text: rgb(0xC6D0F5),
        rosewater: rgb(0xF2D5CF), flamingo: rgb(0xEEBEBE), pink: rgb(0xF4B8E4), red: rgb(0xE78284),
        mauve: rgb(0xCA9EE6), peach: rgb(0xEF9F76), yellow: rgb(0xE5C890), green: rgb(0xA6D189),
        teal: rgb(0x81C8BE), sky: rgb(0x99D1DB), sapphire: rgb(0x85C1DC), blue: rgb(0x8CAAEE),
        lavender: rgb(0xBABBF1)))

    static let catppuccinMacchiato = catppuccin("catppuccin-macchiato", "Catppuccin Macchiato", dark: true, Palette(
        crust: rgb(0x181926), mantle: rgb(0x1E2030), base: rgb(0x24273A),
        surface0: rgb(0x363A4F), surface1: rgb(0x494D64), overlay2: rgb(0x939AB7),
        subtext0: rgb(0xA5ADCB), text: rgb(0xCAD3F5),
        rosewater: rgb(0xF4DBD6), flamingo: rgb(0xF0C6C6), pink: rgb(0xF5BDE6), red: rgb(0xED8796),
        mauve: rgb(0xC6A0F6), peach: rgb(0xF5A97F), yellow: rgb(0xEED49F), green: rgb(0xA6DA95),
        teal: rgb(0x8BD5CA), sky: rgb(0x91D7E3), sapphire: rgb(0x7DC4E4), blue: rgb(0x8AADF4),
        lavender: rgb(0xB7BDF8)))

    static let catppuccinMocha = catppuccin("catppuccin-mocha", "Catppuccin Mocha", dark: true, Palette(
        crust: rgb(0x11111B), mantle: rgb(0x181825), base: rgb(0x1E1E2E),
        surface0: rgb(0x313244), surface1: rgb(0x45475A), overlay2: rgb(0x9399B2),
        subtext0: rgb(0xA6ADC8), text: rgb(0xCDD6F4),
        rosewater: rgb(0xF5E0DC), flamingo: rgb(0xF2CDCD), pink: rgb(0xF5C2E7), red: rgb(0xF38BA8),
        mauve: rgb(0xCBA6F7), peach: rgb(0xFAB387), yellow: rgb(0xF9E2AF), green: rgb(0xA6E3A1),
        teal: rgb(0x94E2D5), sky: rgb(0x89DCEB), sapphire: rgb(0x74C7EC), blue: rgb(0x89B4FA),
        lavender: rgb(0xB4BEFE)))

    // MARK: Популярные

    /// Atom One Dark.
    static let oneDark = EditorScheme(
        id: "one-dark", name: "One Dark", family: .popular, isDark: true,
        p: Palette(
            crust: rgb(0x1B1D23), mantle: rgb(0x21252B), base: rgb(0x282C34),
            surface0: rgb(0x333842), surface1: rgb(0x3E4451), overlay2: rgb(0x5C6370),
            subtext0: rgb(0x828997), text: rgb(0xABB2BF),
            rosewater: rgb(0xE5C5A5), flamingo: rgb(0xE59C9C), pink: rgb(0xE27EB8), red: rgb(0xE06C75),
            mauve: rgb(0xC678DD), peach: rgb(0xD19A66), yellow: rgb(0xE5C07B), green: rgb(0x98C379),
            teal: rgb(0x56B6C2), sky: rgb(0x6FC5D0), sapphire: rgb(0x4AA5D9), blue: rgb(0x61AFEF),
            lavender: rgb(0x8A9CF0)),
        syntax: Syntax(
            keyword: rgb(0xC678DD), type: rgb(0xE5C07B), string: rgb(0x98C379), escape: rgb(0x56B6C2),
            number: rgb(0xD19A66), comment: rgb(0x5C6370), docComment: rgb(0x7F848E), function: rgb(0x61AFEF),
            punctuation: rgb(0xABB2BF), preprocessor: rgb(0xC678DD), attribute: rgb(0xD19A66),
            constant: rgb(0xD19A66), operatorTok: rgb(0x56B6C2), field: rgb(0xE06C75), disabled: rgb(0x4B5263)),
        caret: rgb(0x528BFF), selection: rgb(0x3E4451), occurrence: rgb(0x3A3F4B),
        gutter: rgb(0x4B5263), gutterCurrent: rgb(0xABB2BF))

    static let dracula = EditorScheme(
        id: "dracula", name: "Dracula", family: .popular, isDark: true,
        p: Palette(
            crust: rgb(0x191A21), mantle: rgb(0x21222C), base: rgb(0x282A36),
            surface0: rgb(0x343746), surface1: rgb(0x44475A), overlay2: rgb(0x6272A4),
            subtext0: rgb(0x9EA1B8), text: rgb(0xF8F8F2),
            rosewater: rgb(0xF4D4C8), flamingo: rgb(0xFF9EB8), pink: rgb(0xFF79C6), red: rgb(0xFF5555),
            mauve: rgb(0xBD93F9), peach: rgb(0xFFB86C), yellow: rgb(0xF1FA8C), green: rgb(0x50FA7B),
            teal: rgb(0x69E6C4), sky: rgb(0x8BE9FD), sapphire: rgb(0x7AC4F0), blue: rgb(0x8FA8F8),
            lavender: rgb(0xC6B8FA)),
        syntax: Syntax(
            keyword: rgb(0xFF79C6), type: rgb(0x8BE9FD), string: rgb(0xF1FA8C), escape: rgb(0xFF79C6),
            number: rgb(0xBD93F9), comment: rgb(0x6272A4), docComment: rgb(0x6272A4), function: rgb(0x50FA7B),
            punctuation: rgb(0xF8F8F2), preprocessor: rgb(0xFF79C6), attribute: rgb(0x50FA7B),
            constant: rgb(0xBD93F9), operatorTok: rgb(0xFF79C6), field: rgb(0xFFB86C), disabled: rgb(0x5A5E7A)),
        caret: rgb(0xF8F8F2), selection: rgb(0x44475A), occurrence: rgb(0x424450),
        gutter: rgb(0x6272A4), gutterCurrent: rgb(0xF8F8F2))

    static let monokai = EditorScheme(
        id: "monokai", name: "Monokai", family: .popular, isDark: true,
        p: Palette(
            crust: rgb(0x1A1B16), mantle: rgb(0x1E1F1C), base: rgb(0x272822),
            surface0: rgb(0x3E3D32), surface1: rgb(0x49483E), overlay2: rgb(0x75715E),
            subtext0: rgb(0xA59F85), text: rgb(0xF8F8F2),
            rosewater: rgb(0xF2C9A0), flamingo: rgb(0xF59CA9), pink: rgb(0xF77FBE), red: rgb(0xF92672),
            mauve: rgb(0xAE81FF), peach: rgb(0xFD971F), yellow: rgb(0xE6DB74), green: rgb(0xA6E22E),
            teal: rgb(0xA1EFE4), sky: rgb(0x66D9EF), sapphire: rgb(0x4FB8DD), blue: rgb(0x7AA6FF),
            lavender: rgb(0xB6A6FF)),
        syntax: Syntax(
            keyword: rgb(0xF92672), type: rgb(0x66D9EF), string: rgb(0xE6DB74), escape: rgb(0xAE81FF),
            number: rgb(0xAE81FF), comment: rgb(0x75715E), docComment: rgb(0x908B73), function: rgb(0xA6E22E),
            punctuation: rgb(0xF8F8F2), preprocessor: rgb(0xF92672), attribute: rgb(0xA6E22E),
            constant: rgb(0xAE81FF), operatorTok: rgb(0xF92672), field: rgb(0xFD971F), disabled: rgb(0x5B5A4E)),
        caret: rgb(0xF8F8F0), selection: rgb(0x49483E), occurrence: rgb(0x3E3D32),
        gutter: rgb(0x90908A), gutterCurrent: rgb(0xF8F8F2))

    /// https://www.nordtheme.com/docs/colors-and-palettes
    static let nord = EditorScheme(
        id: "nord", name: "Nord", family: .popular, isDark: true,
        p: Palette(
            crust: rgb(0x242933), mantle: rgb(0x292E39), base: rgb(0x2E3440),
            surface0: rgb(0x3B4252), surface1: rgb(0x434C5E), overlay2: rgb(0x616E88),
            subtext0: rgb(0x9AA3B5), text: rgb(0xD8DEE9),
            rosewater: rgb(0xD8C2B4), flamingo: rgb(0xC89A9E), pink: rgb(0xC895BF), red: rgb(0xBF616A),
            mauve: rgb(0xB48EAD), peach: rgb(0xD08770), yellow: rgb(0xEBCB8B), green: rgb(0xA3BE8C),
            teal: rgb(0x8FBCBB), sky: rgb(0x88C0D0), sapphire: rgb(0x7EA9C9), blue: rgb(0x81A1C1),
            lavender: rgb(0x9DAED6)),
        syntax: Syntax(
            keyword: rgb(0x81A1C1), type: rgb(0x8FBCBB), string: rgb(0xA3BE8C), escape: rgb(0xEBCB8B),
            number: rgb(0xB48EAD), comment: rgb(0x616E88), docComment: rgb(0x7B88A1), function: rgb(0x88C0D0),
            punctuation: rgb(0xECEFF4), preprocessor: rgb(0x5E81AC), attribute: rgb(0xD08770),
            constant: rgb(0xB48EAD), operatorTok: rgb(0x81A1C1), field: rgb(0xD8DEE9), disabled: rgb(0x4C566A)),
        caret: rgb(0xD8DEE9), selection: rgb(0x434C5E).withAlphaComponent(0.8), occurrence: rgb(0x434C5E),
        gutter: rgb(0x4C566A), gutterCurrent: rgb(0xD8DEE9))

    /// https://github.com/morhetz/gruvbox — контраст medium.
    static let gruvboxDark = EditorScheme(
        id: "gruvbox-dark", name: "Gruvbox Dark", family: .popular, isDark: true,
        p: Palette(
            crust: rgb(0x171A1A), mantle: rgb(0x1D2021), base: rgb(0x282828),
            surface0: rgb(0x3C3836), surface1: rgb(0x504945), overlay2: rgb(0x928374),
            subtext0: rgb(0xA89984), text: rgb(0xEBDBB2),
            rosewater: rgb(0xD5C4A1), flamingo: rgb(0xE9A08A), pink: rgb(0xE08FA8), red: rgb(0xFB4934),
            mauve: rgb(0xD3869B), peach: rgb(0xFE8019), yellow: rgb(0xFABD2F), green: rgb(0xB8BB26),
            teal: rgb(0x8EC07C), sky: rgb(0x89B8A8), sapphire: rgb(0x76A89C), blue: rgb(0x83A598),
            lavender: rgb(0xBDAEC6)),
        syntax: Syntax(
            keyword: rgb(0xFB4934), type: rgb(0xFABD2F), string: rgb(0xB8BB26), escape: rgb(0xFE8019),
            number: rgb(0xD3869B), comment: rgb(0x928374), docComment: rgb(0xA89984), function: rgb(0x8EC07C),
            punctuation: rgb(0xEBDBB2), preprocessor: rgb(0xFE8019), attribute: rgb(0x8EC07C),
            constant: rgb(0xD3869B), operatorTok: rgb(0xFE8019), field: rgb(0x83A598), disabled: rgb(0x665C54)),
        caret: rgb(0xEBDBB2), selection: rgb(0x504945), occurrence: rgb(0x45403D),
        gutter: rgb(0x7C6F64), gutterCurrent: rgb(0xFABD2F))

    /// https://github.com/folke/tokyonight.nvim — вариант night.
    static let tokyoNight = EditorScheme(
        id: "tokyo-night", name: "Tokyo Night", family: .popular, isDark: true,
        p: Palette(
            crust: rgb(0x101014), mantle: rgb(0x16161E), base: rgb(0x1A1B26),
            surface0: rgb(0x292E42), surface1: rgb(0x3B4261), overlay2: rgb(0x737AA2),
            subtext0: rgb(0xA9B1D6), text: rgb(0xC0CAF5),
            rosewater: rgb(0xE0B8A0), flamingo: rgb(0xF4A6B0), pink: rgb(0xF5A7D3), red: rgb(0xF7768E),
            mauve: rgb(0xBB9AF7), peach: rgb(0xFF9E64), yellow: rgb(0xE0AF68), green: rgb(0x9ECE6A),
            teal: rgb(0x73DACA), sky: rgb(0x7DCFFF), sapphire: rgb(0x2AC3DE), blue: rgb(0x7AA2F7),
            lavender: rgb(0x9FB0FA)),
        syntax: Syntax(
            keyword: rgb(0xBB9AF7), type: rgb(0x2AC3DE), string: rgb(0x9ECE6A), escape: rgb(0x89DDFF),
            number: rgb(0xFF9E64), comment: rgb(0x565F89), docComment: rgb(0x6B73A0), function: rgb(0x7AA2F7),
            punctuation: rgb(0x89DDFF), preprocessor: rgb(0x7DCFFF), attribute: rgb(0xE0AF68),
            constant: rgb(0xFF9E64), operatorTok: rgb(0x89DDFF), field: rgb(0x73DACA), disabled: rgb(0x414868)),
        caret: rgb(0xC0CAF5), selection: rgb(0x283457), occurrence: rgb(0x2F3549),
        gutter: rgb(0x3B4261), gutterCurrent: rgb(0x737AA2))

    /// Штатные GitHub Dark и Light (Primer).
    static let githubDark = EditorScheme(
        id: "github-dark", name: "GitHub Dark", family: .popular, isDark: true,
        p: Palette(
            crust: rgb(0x010409), mantle: rgb(0x090C10), base: rgb(0x0D1117),
            surface0: rgb(0x161B22), surface1: rgb(0x30363D), overlay2: rgb(0x6E7681),
            subtext0: rgb(0x8B949E), text: rgb(0xE6EDF3),
            rosewater: rgb(0xFFB8A8), flamingo: rgb(0xFFA198), pink: rgb(0xFF9BCE), red: rgb(0xFF7B72),
            mauve: rgb(0xD2A8FF), peach: rgb(0xFFA657), yellow: rgb(0xE3B341), green: rgb(0x56D364),
            teal: rgb(0x56D4DD), sky: rgb(0x79C0FF), sapphire: rgb(0x6CB6FF), blue: rgb(0x58A6FF),
            lavender: rgb(0xB1BAFF)),
        syntax: Syntax(
            keyword: rgb(0xFF7B72), type: rgb(0xFFA657), string: rgb(0xA5D6FF), escape: rgb(0x79C0FF),
            number: rgb(0x79C0FF), comment: rgb(0x8B949E), docComment: rgb(0x8B949E), function: rgb(0xD2A8FF),
            punctuation: rgb(0xE6EDF3), preprocessor: rgb(0xFF7B72), attribute: rgb(0xD2A8FF),
            constant: rgb(0x79C0FF), operatorTok: rgb(0xFF7B72), field: rgb(0x79C0FF), disabled: rgb(0x484F58)),
        caret: rgb(0x58A6FF), selection: rgb(0x3392FF).withAlphaComponent(0.27), occurrence: rgb(0x272E38),
        gutter: rgb(0x6E7681), gutterCurrent: rgb(0xE6EDF3))

    static let githubLight = EditorScheme(
        id: "github-light", name: "GitHub Light", family: .popular, isDark: false,
        p: Palette(
            crust: rgb(0xFFFFFF), mantle: rgb(0xF6F8FA), base: rgb(0xFFFFFF),
            surface0: rgb(0xEAEEF2), surface1: rgb(0xD0D7DE), overlay2: rgb(0x6E7781),
            subtext0: rgb(0x59636E), text: rgb(0x1F2328),
            rosewater: rgb(0xA6583A), flamingo: rgb(0xC24E4E), pink: rgb(0xBF3989), red: rgb(0xCF222E),
            mauve: rgb(0x8250DF), peach: rgb(0xBC4C00), yellow: rgb(0x9A6700), green: rgb(0x1A7F37),
            teal: rgb(0x1B7C83), sky: rgb(0x1A7FA6), sapphire: rgb(0x0550AE), blue: rgb(0x0969DA),
            lavender: rgb(0x5A5FC9)),
        syntax: Syntax(
            keyword: rgb(0xCF222E), type: rgb(0x953800), string: rgb(0x0A3069), escape: rgb(0x116329),
            number: rgb(0x0550AE), comment: rgb(0x6E7781), docComment: rgb(0x6E7781), function: rgb(0x8250DF),
            punctuation: rgb(0x1F2328), preprocessor: rgb(0xCF222E), attribute: rgb(0x8250DF),
            constant: rgb(0x0550AE), operatorTok: rgb(0xCF222E), field: rgb(0x0550AE), disabled: rgb(0xAFB8C1)),
        caret: rgb(0x1F2328), selection: rgb(0x0969DA).withAlphaComponent(0.2), occurrence: rgb(0xFFF5B1),
        gutter: rgb(0x8C959F), gutterCurrent: rgb(0x1F2328))

    /// https://ethanschoonover.com/solarized — у обеих половин одни акценты.
    private static let solarizedAccents = (
        rosewater: rgb(0xD8A58C), flamingo: rgb(0xE07A6A), pink: rgb(0xD33682), red: rgb(0xDC322F),
        mauve: rgb(0x6C71C4), peach: rgb(0xCB4B16), yellow: rgb(0xB58900), green: rgb(0x859900),
        teal: rgb(0x2AA198), sky: rgb(0x3AA7C9), sapphire: rgb(0x2F9BD5), blue: rgb(0x268BD2),
        lavender: rgb(0x8589D6))

    private static func solarized(_ id: String, _ name: String, dark: Bool,
                                  crust: Int, mantle: Int, base: Int, surface0: Int, surface1: Int,
                                  overlay2: Int, subtext0: Int, text: Int, comment: Int, docComment: Int,
                                  disabled: Int, caret: Int, selection: Int, occurrence: Int,
                                  gutter: Int, gutterCurrent: Int) -> EditorScheme {
        let a = solarizedAccents
        return EditorScheme(
            id: id, name: name, family: .popular, isDark: dark,
            p: Palette(
                crust: rgb(crust), mantle: rgb(mantle), base: rgb(base), surface0: rgb(surface0),
                surface1: rgb(surface1), overlay2: rgb(overlay2), subtext0: rgb(subtext0), text: rgb(text),
                rosewater: a.rosewater, flamingo: a.flamingo, pink: a.pink, red: a.red, mauve: a.mauve,
                peach: a.peach, yellow: a.yellow, green: a.green, teal: a.teal, sky: a.sky,
                sapphire: a.sapphire, blue: a.blue, lavender: a.lavender),
            syntax: Syntax(
                keyword: a.green, type: a.yellow, string: a.teal, escape: a.red, number: a.pink,
                comment: rgb(comment), docComment: rgb(docComment), function: a.blue, punctuation: rgb(text),
                preprocessor: a.peach, attribute: a.mauve, constant: a.teal, operatorTok: a.green,
                field: a.mauve, disabled: rgb(disabled)),
            caret: rgb(caret), selection: rgb(selection), occurrence: rgb(occurrence),
            gutter: rgb(gutter), gutterCurrent: rgb(gutterCurrent))
    }

    static let solarizedDark = solarized(
        "solarized-dark", "Solarized Dark", dark: true,
        crust: 0x00212B, mantle: 0x00252F, base: 0x002B36, surface0: 0x073642, surface1: 0x1E4B57,
        overlay2: 0x586E75, subtext0: 0x93A1A1, text: 0x839496, comment: 0x586E75, docComment: 0x657B83,
        disabled: 0x405E66, caret: 0x93A1A1, selection: 0x274642, occurrence: 0x0A4453,
        gutter: 0x586E75, gutterCurrent: 0x93A1A1)

    static let solarizedLight = solarized(
        "solarized-light", "Solarized Light", dark: false,
        crust: 0xFDF6E3, mantle: 0xEEE8D5, base: 0xFDF6E3, surface0: 0xEEE8D5, surface1: 0xD6CFB9,
        overlay2: 0x93A1A1, subtext0: 0x586E75, text: 0x657B83, comment: 0x93A1A1, docComment: 0x839496,
        disabled: 0xC9C3AE, caret: 0x657B83, selection: 0xDDD6C1, occurrence: 0xE6DFC8,
        gutter: 0x93A1A1, gutterCurrent: 0x586E75)

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green:   CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue:    CGFloat(hex & 0xFF) / 255.0,
                alpha:   1.0)
    }
}
