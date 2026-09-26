import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Раскладка JetBrains

/// Нажатие в записи JetBrains: `meta alt B`, у аккорда — два нажатия.
struct RiderKeystroke: Equatable {
    var first: String
    var second: String?

    /// Сочетание Pilot. Аккордов в Pilot нет, клавиш цифрового блока тоже —
    /// для них `nil`.
    var shortcut: Shortcut? {
        guard second == nil else { return nil }
        return Self.shortcut(first)
    }

    var display: String {
        let one = { (text: String) in Self.shortcut(text)?.display ?? text }
        return second.map { "\(one(first)) \(one($0))" } ?? one(first)
    }

    static func shortcut(_ text: String) -> Shortcut? {
        let parts = text.split(separator: " ").map { $0.lowercased() }
        guard let last = parts.last, let key = key(last) else { return nil }
        var shortcut = Shortcut(key)
        for part in parts.dropLast() {
            switch part {
            case "meta": shortcut.command = true
            case "alt": shortcut.option = true
            case "ctrl", "control": shortcut.control = true
            case "shift": shortcut.shift = true
            default: return nil          // altGraph, кнопки мыши
            }
        }
        return shortcut.isValid ? shortcut : nil
    }

    /// Имена клавиш — из `java.awt.event.KeyEvent` без `VK_`.
    private static func key(_ name: String) -> String? {
        let named: [String: String] = [
            "back_space": "delete", "delete": "forwardDelete", "escape": "escape", "enter": "return",
            "tab": "tab", "space": "space", "home": "home", "end": "end", "page_up": "pageUp",
            "page_down": "pageDown", "up": "up", "down": "down", "left": "left", "right": "right",
            "open_bracket": "[", "close_bracket": "]", "minus": "-", "equals": "=", "slash": "/",
            "back_slash": "\\", "period": ".", "comma": ",", "semicolon": ";", "quote": "'",
            "back_quote": "`",
        ]
        if let key = named[name] { return key }
        if name.count == 1, let c = name.first, c.isLetter || c.isNumber { return name }
        if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...19).contains(n) { return name }
        return nil
    }
}

/// Раскладка Rider: `keymaps/*.xml` или встроенная. В ней только то, чем
/// она отличается от родителя, остальное берётся у него.
struct RiderKeymap {
    var name: String
    var parent: String?
    /// Действие → сочетания. Пустой список — «в этой раскладке без
    /// сочетания», а не «как у родителя».
    var actions: [String: [RiderKeystroke]]

    /// Раскладки, которые IntelliJ собирает как `MacOSDefaultKeymap`:
    /// сочетания родителя (`$default`, писанного под Windows) они получают
    /// с ctrl и ⌘, поменянными местами.
    var swapsParentModifiers: Bool { name.hasPrefix("Mac OS X") }

    init(name: String, parent: String?, actions: [String: [RiderKeystroke]]) {
        self.name = name
        self.parent = parent
        self.actions = actions
    }

    init?(xml data: Data) {
        guard let root = RiderXML.parse(data), root.name == "keymap", let name = root["name"] else { return nil }
        var actions: [String: [RiderKeystroke]] = [:]
        for action in root.children where action.name == "action" {
            guard let id = action["id"] else { continue }
            actions[id] = action.children.compactMap { element in
                guard element.name == "keyboard-shortcut", let first = element["first-keystroke"] else { return nil }
                return RiderKeystroke(first: first, second: element["second-keystroke"])
            }
        }
        self.init(name: name, parent: root["parent"], actions: actions)
    }
}

/// Раскладки по именам: свои из настроек поверх встроенных в Rider.
struct RiderKeymaps {
    var keymaps: [String: RiderKeymap]

    /// Сочетания действия с учётом родителей; `nil` — действие не упомянуто
    /// ни в одной раскладке цепочки.
    func keystrokes(_ action: String, in name: String) -> [RiderKeystroke]? {
        var current = keymaps[name]
        var swap = false
        var seen: Set<String> = []
        while let keymap = current, seen.insert(keymap.name).inserted {
            if let found = keymap.actions[action] {
                return swap ? found.map(Self.swapped) : found
            }
            // Как в IntelliJ: каждая маковская раскладка переставляет
            // сочетания своего родителя. На деле это один шаг — к `$default`.
            if keymap.swapsParentModifiers { swap.toggle() }
            current = keymap.parent.flatMap { keymaps[Self.alias($0)] }
        }
        return nil
    }

    /// Цепочка раскладок; последний элемент — первая, которой нет.
    func chain(_ name: String) -> (known: [String], missing: String?) {
        var known: [String] = []
        var next: String? = name
        while let current = next, !known.contains(current) {
            guard let keymap = keymaps[Self.alias(current)] else { return (known, current) }
            known.append(keymap.name)
            next = keymap.parent
        }
        return (known, nil)
    }

    /// Старое имя, под которым раскладка ещё встречается в `parent`.
    private static func alias(_ name: String) -> String {
        name == "Default for Mac OS X" ? "Mac OS X" : name
    }

    private static func swapped(_ keystroke: RiderKeystroke) -> RiderKeystroke {
        func swap(_ text: String) -> String {
            text.split(separator: " ").map { part -> String in
                switch part.lowercased() {
                case "meta": return "ctrl"
                case "ctrl", "control": return "meta"
                default: return String(part)
                }
            }.joined(separator: " ")
        }
        return RiderKeystroke(first: swap(keystroke.first), second: keystroke.second.map(swap))
    }
}

// MARK: - Команды Pilot ↔ действия Rider

enum RiderImport {

    /// Действия IntelliJ для команды — по порядку: берётся первое, у
    /// которого есть сочетание. Идентификаторы отсюда же читает
    /// `bin/rider-keymaps.py`, собирая встроенные раскладки.
    static func actions(for command: EditorCommand) -> [String] {
        switch command {
        case .openFolder: return ["OpenFile"]
        case .closeProject: return ["CloseProject"]
        case .closeTab: return ["CloseContent", "CloseEditor"]
        case .closeOtherTabs: return ["CloseAllEditorsButActive"]
        case .save: return ["SaveDocument", "SaveAll"]
        case .saveAll: return ["SaveAll"]
        case .toggleComment: return ["CommentByLineComment"]
        case .showCompletions: return ["CodeCompletion"]
        case .duplicateLines: return ["EditorDuplicateLines", "EditorDuplicate"]
        case .deleteLines: return ["EditorDeleteLine"]
        case .moveLinesUp: return ["MoveLineUp"]
        case .moveLinesDown: return ["MoveLineDown"]
        case .extendSelection: return ["EditorSelectWord"]
        case .shrinkSelection: return ["EditorUnSelectWord"]
        case .quickDocumentation: return ["QuickJavaDoc"]
        case .parameterInfo: return ["ParameterInfo"]
        case .fold: return ["CollapseRegion"]
        case .unfold: return ["ExpandRegion"]
        case .foldAll: return ["CollapseAllRegions"]
        case .unfoldAll: return ["ExpandAllRegions"]
        case .find: return ["Find"]
        case .findAndReplace: return ["Replace"]
        case .findNext: return ["FindNext"]
        case .findPrevious: return ["FindPrevious"]
        case .useSelectionForFind: return ["FindWordAtCaret"]
        case .searchEverywhere: return ["GotoFile"]
        case .searchTypes: return ["GotoClass"]
        case .fileStructure: return ["FileStructurePopup"]
        case .searchSymbols: return ["GotoSymbol"]
        case .findInFiles: return ["FindInPath"]
        case .changedFiles: return []
        case .recentLocations: return ["RecentLocations"]
        case .goToDefinition: return ["GotoDeclaration"]
        case .findReferences: return ["FindUsages"]
        case .valueGraph: return []
        case .implementations: return ["GotoImplementation"]
        case .contextActions: return ["ShowIntentionActions"]
        case .back: return ["Back"]
        case .forward: return ["Forward"]
        case .lastEdit: return ["JumpToLastChange"]
        case .nextMember: return ["MethodDown"]
        case .previousMember: return ["MethodUp"]
        case .nextOccurrence: return ["GotoNextElementUnderCaretUsage"]
        case .previousOccurrence: return ["GotoPrevElementUnderCaretUsage"]
        case .nextProblem: return ["GotoNextError"]
        case .previousProblem: return ["GotoPreviousError"]
        case .rename: return ["RenameElement"]
        case .nextTab: return ["NextTab"]
        case .previousTab: return ["PreviousTab"]
        case .recentTab: return []
        case .toggleSidebar: return ["ActivateProjectToolWindow"]
        case .revealInTree: return ["SelectInProjectView"]
        case .newWindow: return []
        case .toggleInspector: return []
        case .fontBigger: return ["EditorIncreaseFontSize"]
        case .fontSmaller: return ["EditorDecreaseFontSize"]
        case .fontReset: return ["EditorResetFontSize"]
        case .nextChange: return ["VcsShowNextChangeMarker"]
        case .previousChange: return ["VcsShowPrevChangeMarker"]
        case .reviews, .commentLine, .nextThread, .previousThread, .nextReviewFile, .previousReviewFile,
             .nextConflict, .previousConflict, .acceptCurrent, .acceptIncoming, .acceptBoth, .markResolved,
             .assetUsages, .toggleMeta, .unityConsole:
            return []
        case .run: return ["Run"]
        // «Остановить» останавливает и запуск, и отладку — как Stop в Rider.
        case .stop: return ["Stop"]
        case .toggleConsole: return ["ActivateRunToolWindow"]
        case .nuget: return ["ActivateNuGetToolWindow"]
        case .joinLines: return ["EditorJoinLines"]
        case .toggleCase: return ["EditorToggleCase"]
        case .goToLine: return ["GotoLine"]
        case .localHistory: return ["LocalHistory.ShowHistory"]
        case .commit: return ["CheckinProject"]
        case .debugStart: return ["Debug"]
        case .debugStop: return []
        case .debugContinue: return ["Resume"]
        case .debugPause: return ["Pause"]
        case .stepOver: return ["StepOver"]
        case .stepInto: return ["StepInto"]
        case .stepOut: return ["StepOut"]
        case .toggleBreakpoint: return ["ToggleLineBreakpoint"]
        case .removeAllBreakpoints: return ["Debugger.RemoveAllBreakpoints"]
        case .openPartner, .counterpart, .pairSearch, .datagramContract, .mirrorDrift:
            return []
        }
    }

    /// Сочетания, которые Pilot ловит всегда, мимо раскладки: ⌃Tab
    /// переключает вкладки, ⌃- / ⌃⇧- ходят назад и вперёд.
    static let alwaysOn: Set<Shortcut> = [
        Shortcut("tab", control: true), Shortcut("tab", control: true, shift: true),
        Shortcut("-", control: true), Shortcut("-", control: true, shift: true),
    ]

    struct Entry: Equatable {
        let command: EditorCommand
        let outcome: Outcome
    }

    enum Outcome: Equatable {
        /// Сочетание из Rider; `was` — что было в Pilot.
        case assigned(Shortcut, was: Shortcut?)
        /// В Rider то же, что уже стоит в Pilot.
        case same(Shortcut)
        /// Сочетание Pilot отдано команде, получившей его из Rider.
        case yielded(Shortcut, to: EditorCommand)
        /// Не перенесено — почему, словами; сочетание Pilot осталось.
        case kept(reason: String)
    }

    struct KeymapResult {
        var keymap: Keymap
        var entries: [Entry]
        /// Раскладка, которой нет ни в настройках, ни в Pilot: её
        /// сочетания не перенеслись, только то, что поменяли поверх.
        var missingKeymap: String?

        var changed: Int {
            entries.filter {
                switch $0.outcome {
                case .assigned, .yielded: return true
                case .same, .kept: return false
                }
            }.count
        }
    }

    /// Сочетания Rider поверх `base`. Взятое из Rider важнее сочетаний
    /// Pilot: команда, у которой оно было, остаётся без сочетания.
    static func keymap(_ name: String, from keymaps: RiderKeymaps, over base: Keymap) -> KeymapResult {
        var keymap = base
        var entries: [EditorCommand: Outcome] = [:]
        var taken: [Shortcut: EditorCommand] = [:]

        for command in EditorCommand.allCases {
            let ids = actions(for: command)
            guard !ids.isEmpty else { continue }
            let found = ids.lazy.compactMap { id in keymaps.keystrokes(id, in: name).map { (id, $0) } }
            guard let (_, strokes) = found.first(where: { !$0.1.isEmpty }) ?? found.first else {
                entries[command] = .kept(reason: "нет в раскладке Rider")
                continue
            }
            if strokes.isEmpty {
                entries[command] = .kept(reason: "в Rider без сочетания")
                continue
            }
            let usable = strokes.compactMap(\.shortcut).filter { !$0.needsModifier || $0.hasModifier }
            let fresh = usable.filter { !alwaysOn.contains($0) }
            guard let shortcut = fresh.first(where: { taken[$0] == nil }) else {
                let reason: String
                if let other = fresh.first.flatMap({ taken[$0] }) {
                    reason = "\(fresh[0].display) уже у «\(other.title)»"
                } else if let builtin = usable.first(where: alwaysOn.contains) {
                    reason = "\(builtin.display) работает в Pilot всегда"
                } else {
                    reason = "в Pilot нет аккордов: " + strokes.map(\.display).joined(separator: ", ")
                }
                entries[command] = .kept(reason: reason)
                continue
            }
            taken[shortcut] = command
            let was = keymap.shortcut(for: command)
            keymap.set(shortcut, for: command)
            entries[command] = was == shortcut ? .same(shortcut) : .assigned(shortcut, was: was)
        }

        // Сочетание Pilot, которое Rider отдал другой команде, снимается:
        // иначе сработала бы только одна из двух.
        for command in EditorCommand.allCases where taken.values.contains(command) == false {
            guard let current = keymap.shortcut(for: command), let owner = taken[current] else { continue }
            keymap.set(nil, for: command)
            entries[command] = .yielded(current, to: owner)
        }

        let ordered = EditorCommand.allCases.compactMap { command in
            entries[command].map { Entry(command: command, outcome: $0) }
        }
        return KeymapResult(keymap: keymap, entries: ordered, missingKeymap: keymaps.chain(name).missing)
    }
}

// MARK: - Папка настроек

/// Что Pilot понимает в настройках Rider: папка
/// `~/Library/Application Support/JetBrains/Rider…` или распакованный
/// `settings.zip` из File → Manage IDE Settings → Export Settings —
/// внутри у них одно и то же.
struct RiderSettings {
    /// Активная раскладка; у Rider на маке по умолчанию — «Mac OS X 10.5+»,
    /// в интерфейсе она называется «macOS».
    var activeKeymap = "Mac OS X 10.5+"
    /// Свои раскладки из `keymaps/`.
    var keymaps: [RiderKeymap] = []
    var fontSize: Double?
    var fontFamily: String?
    /// Code Vision — «N использований» над объявлениями.
    var codeVision: Bool?

    /// `nil` — в папке нет ничего похожего на настройки JetBrains.
    init?(folder: URL) {
        let options = folder.appendingPathComponent("options")
        let fm = FileManager.default
        guard fm.fileExists(atPath: options.path) || fm.fileExists(atPath: folder.appendingPathComponent("keymaps").path)
        else { return nil }

        func read(_ path: String) -> RiderXML.Element? {
            (try? Data(contentsOf: folder.appendingPathComponent(path))).flatMap(RiderXML.parse)
        }
        func option(_ root: RiderXML.Element?, component: String, _ name: String) -> String? {
            root?.children.first { $0.name == "component" && $0["name"] == component }?
                .children.first { $0.name == "option" && $0["name"] == name }?["value"]
        }

        // На маке раскладка лежит в `options/mac/`, на других системах — в `options/`.
        for path in ["options/mac/keymap.xml", "options/keymap.xml"] {
            let manager = read(path)?.children.first { $0["name"] == "KeymapManager" }
            if let name = manager?.children.first(where: { $0.name == "active_keymap" })?["name"] {
                activeKeymap = name
                break
            }
        }
        let keymapFolder = folder.appendingPathComponent("keymaps")
        let files = (try? fm.contentsOfDirectory(at: keymapFolder, includingPropertiesForKeys: nil)) ?? []
        keymaps = files.filter { $0.pathExtension == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(RiderKeymap.init(xml:)) }

        let font = read("options/editor-font.xml")
        fontSize = (option(font, component: "DefaultFont", "FONT_SIZE_2D")
            ?? option(font, component: "DefaultFont", "FONT_SIZE")).flatMap(Double.init)
        fontFamily = option(font, component: "DefaultFont", "FONT_FAMILY")
        codeVision = option(read("options/editor.xml"), component: "CodeVisionSettings", "codeVisionEnabled")
            .map { $0 == "true" }
    }

    /// Свои раскладки поверх встроенных.
    var allKeymaps: RiderKeymaps {
        var all = RiderBundledKeymaps.all.keymaps
        for keymap in keymaps { all[keymap.name] = keymap }
        return RiderKeymaps(keymaps: all)
    }

    func keymap(over base: Keymap) -> RiderImport.KeymapResult {
        RiderImport.keymap(activeKeymap, from: allKeymaps, over: base)
    }
}

// MARK: - XML

/// Настройки JetBrains — маленькие XML-файлы: хватает дерева элементов
/// с атрибутами, текст внутри не нужен.
enum RiderXML {
    final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Element] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        subscript(attribute: String) -> String? { attributes[attribute] }
    }

    static func parse(_ data: Data) -> Element? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Element?
        private var stack: [Element] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let element = Element(name: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(element) } else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}
