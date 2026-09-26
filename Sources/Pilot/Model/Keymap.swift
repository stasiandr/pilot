import Foundation

// MARK: - Сочетание

/// Сочетание клавиш: клавиша и модификаторы. Без AppKit — ради тестов и
/// ради файла настроек, который можно править руками.
///
/// Клавиша — строчный символ (`p`, `[`, `/`) или имя: `up`, `down`,
/// `left`, `right`, `delete`, `forwardDelete`, `escape`, `space`, `return`,
/// `tab`, `home`, `end`, `pageUp`, `pageDown`, `f1`…`f19`.
struct Shortcut: Hashable, Codable {
    var key: String
    var command = false
    var option = false
    var control = false
    var shift = false

    init(_ key: String, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    static let namedKeys: [String: String] = [
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "delete": "⌫", "forwardDelete": "⌦", "escape": "⎋", "space": "Space",
        "return": "↩", "tab": "⇥", "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟",
    ]

    /// Номер функциональной клавиши, если это она.
    var functionNumber: Int? {
        guard key.hasPrefix("f"), key.count > 1, let n = Int(key.dropFirst()), (1...19).contains(n) else { return nil }
        return n
    }

    var isValid: Bool {
        key.count == 1 || Self.namedKeys[key] != nil || functionNumber != nil
    }

    /// Можно ли без модификаторов: функциональные клавиши — да, буква — нет,
    /// иначе её нельзя было бы набрать.
    var needsModifier: Bool { functionNumber == nil }

    var hasModifier: Bool { command || option || control || shift }

    /// Как в меню macOS: ⌃⌥⇧⌘ и клавиша.
    var display: String {
        var out = ""
        if control { out += "⌃" }
        if option { out += "⌥" }
        if shift { out += "⇧" }
        if command { out += "⌘" }
        if let named = Self.namedKeys[key] { return out + named }
        if let n = functionNumber { return out + "F\(n)" }
        return out + key.uppercased()
    }

    /// В файле настроек: `cmd+shift+p`, `f2`, `ctrl+alt+cmd+left`.
    var text: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        parts.append(key == "+" ? "plus" : key)
        return parts.joined(separator: "+")
    }

    init?(text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        self.init(last == "plus" ? "+" : Self.canonicalName(last))
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘": command = true
            case "alt", "opt", "option", "⌥": option = true
            case "ctrl", "control", "⌃": control = true
            case "shift", "⇧": shift = true
            default: return nil
            }
        }
        guard isValid else { return nil }
    }

    /// Имена клавиш в файле пишут как угодно: `pageup`, `PageUp`, `backspace`.
    private static func canonicalName(_ name: String) -> String {
        let aliases: [String: String] = ["backspace": "delete", "del": "forwardDelete", "esc": "escape",
                                         "enter": "return", "pageup": "pageUp", "pagedown": "pageDown",
                                         "forwarddelete": "forwardDelete", "arrowup": "up", "arrowdown": "down",
                                         "arrowleft": "left", "arrowright": "right"]
        return aliases[name] ?? name
    }

    // Файл настроек хранит сочетание строкой, а не объектом.
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Shortcut(text: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Не сочетание: \(text)"))
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    /// Клавиша по коду клавиатуры — для тех, что символа не дают.
    static func namedKey(forKeyCode code: UInt16) -> String? {
        switch code {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 51: return "delete"
        case 117: return "forwardDelete"
        case 53: return "escape"
        case 49: return "space"
        case 36, 76: return "return"
        case 48: return "tab"
        case 115: return "home"
        case 119: return "end"
        case 116: return "pageUp"
        case 121: return "pageDown"
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        case 96: return "f5"
        case 97: return "f6"
        case 98: return "f7"
        case 100: return "f8"
        case 101: return "f9"
        case 109: return "f10"
        case 103: return "f11"
        case 111: return "f12"
        case 105: return "f13"
        case 107: return "f14"
        case 113: return "f15"
        case 106: return "f16"
        case 64: return "f17"
        case 79: return "f18"
        case 80: return "f19"
        default: return nil
        }
    }
}

// MARK: - Команды

/// Всё, на что можно назначить сочетание: пункты меню Pilot.
enum EditorCommand: String, CaseIterable {
    // Файл
    case newWindow = "file.newWindow"
    case openFolder = "file.openFolder"
    case closeProject = "file.closeProject"
    case closeTab = "file.closeTab"
    case closeOtherTabs = "file.closeOtherTabs"
    case save = "file.save"
    case saveAll = "file.saveAll"
    // Правка
    case toggleComment = "edit.toggleComment"
    case showCompletions = "edit.showCompletions"
    case duplicateLines = "edit.duplicateLines"
    case deleteLines = "edit.deleteLines"
    case moveLinesUp = "edit.moveLinesUp"
    case moveLinesDown = "edit.moveLinesDown"
    case joinLines = "edit.joinLines"
    case toggleCase = "edit.toggleCase"
    case extendSelection = "edit.extendSelection"
    case shrinkSelection = "edit.shrinkSelection"
    case quickDocumentation = "edit.quickDocumentation"
    case parameterInfo = "edit.parameterInfo"
    case fold = "edit.fold"
    case unfold = "edit.unfold"
    case foldAll = "edit.foldAll"
    case unfoldAll = "edit.unfoldAll"
    // Поиск в файле
    case find = "find.find"
    case findAndReplace = "find.replace"
    case findNext = "find.next"
    case findPrevious = "find.previous"
    case useSelectionForFind = "find.useSelection"
    // Поиск по проекту
    case searchEverywhere = "search.everywhere"
    case searchTypes = "search.types"
    case fileStructure = "search.structure"
    case searchSymbols = "search.symbols"
    case findInFiles = "search.text"
    case changedFiles = "search.changedFiles"
    case recentLocations = "search.recentLocations"
    // Навигация
    case goToDefinition = "nav.definition"
    case findReferences = "nav.references"
    case implementations = "nav.implementations"
    case valueGraph = "nav.valueGraph"
    case contextActions = "nav.contextActions"
    case back = "nav.back"
    case forward = "nav.forward"
    case lastEdit = "nav.lastEdit"
    case goToLine = "nav.goToLine"
    case nextMember = "nav.nextMember"
    case previousMember = "nav.previousMember"
    case nextOccurrence = "nav.nextOccurrence"
    case previousOccurrence = "nav.previousOccurrence"
    case nextProblem = "nav.nextProblem"
    case previousProblem = "nav.previousProblem"
    case rename = "refactor.rename"
    // Вкладки и вид
    case nextTab = "view.nextTab"
    case previousTab = "view.previousTab"
    case recentTab = "view.recentTab"
    case toggleSidebar = "view.sidebar"
    case revealInTree = "view.revealInTree"
    case toggleInspector = "view.inspector"
    case fontBigger = "view.fontBigger"
    case fontSmaller = "view.fontSmaller"
    case fontReset = "view.fontReset"
    // Git и ревью
    case nextChange = "git.nextChange"
    case previousChange = "git.previousChange"
    case reviews = "git.reviews"
    case commentLine = "git.commentLine"
    case nextThread = "git.nextThread"
    case previousThread = "git.previousThread"
    case nextReviewFile = "git.nextReviewFile"
    case previousReviewFile = "git.previousReviewFile"
    case nextConflict = "git.nextConflict"
    case previousConflict = "git.previousConflict"
    case acceptCurrent = "git.acceptCurrent"
    case acceptIncoming = "git.acceptIncoming"
    case acceptBoth = "git.acceptBoth"
    case markResolved = "git.markResolved"
    case localHistory = "git.localHistory"
    case commit = "git.commit"
    // Unity
    case assetUsages = "unity.assetUsages"
    case toggleMeta = "unity.toggleMeta"
    case unityConsole = "unity.console"
    // Отладка — сочетания как в Rider
    case debugStart = "debug.start"
    case debugStop = "debug.stop"
    case debugContinue = "debug.continue"
    case debugPause = "debug.pause"
    case stepOver = "debug.stepOver"
    case stepInto = "debug.stepInto"
    case stepOut = "debug.stepOut"
    case toggleBreakpoint = "debug.toggleBreakpoint"
    case removeAllBreakpoints = "debug.removeAllBreakpoints"

    case run = "run.run"
    case stop = "run.stop"
    case toggleConsole = "run.console"
    case nuget = "run.nuget"
    // Пара проектов
    case openPartner = "pair.open"
    case counterpart = "pair.counterpart"
    case pairSearch = "pair.search"
    case datagramContract = "pair.contract"
    case mirrorDrift = "pair.mirrors"

    var title: String {
        switch self {
        case .newWindow: return L("Новое окно")
        case .openFolder: return L("Открыть папку")
        case .closeProject: return L("Закрыть проект")
        case .closeTab: return L("Закрыть вкладку")
        case .closeOtherTabs: return L("Закрыть другие вкладки")
        case .save: return L("Сохранить")
        case .saveAll: return L("Сохранить все")
        case .toggleComment: return L("Закомментировать строки")
        case .showCompletions: return L("Показать варианты")
        case .duplicateLines: return L("Дублировать строку")
        case .deleteLines: return L("Удалить строку")
        case .moveLinesUp: return L("Строку выше")
        case .moveLinesDown: return L("Строку ниже")
        case .joinLines: return L("Склеить строки")
        case .toggleCase: return L("Заглавные ↔ строчные")
        case .extendSelection: return L("Расширить выделение")
        case .shrinkSelection: return L("Сузить выделение")
        case .quickDocumentation: return L("Документация")
        case .parameterInfo: return L("Параметры вызова")
        case .fold: return L("Свернуть")
        case .unfold: return L("Развернуть")
        case .foldAll: return L("Свернуть всё")
        case .unfoldAll: return L("Развернуть всё")
        case .find: return L("Найти в файле")
        case .findAndReplace: return L("Найти и заменить")
        case .findNext: return L("Найти далее")
        case .findPrevious: return L("Найти ранее")
        case .useSelectionForFind: return L("Искать выделенное")
        case .searchEverywhere: return L("Найти везде")
        case .searchTypes: return L("Найти тип (кроме ⇧⇧)")
        case .fileStructure: return L("Структура файла")
        case .searchSymbols: return L("Символ в проекте")
        case .findInFiles: return L("Найти в файлах")
        case .changedFiles: return L("Изменённые файлы")
        case .recentLocations: return L("Недавние места")
        case .goToDefinition: return L("Перейти к объявлению")
        case .findReferences: return L("Найти использования")
        case .valueGraph: return L("Граф значения")
        case .implementations: return L("Перейти к реализациям")
        case .contextActions: return L("Действия в контексте")
        case .back: return L("Назад")
        case .forward: return L("Вперёд")
        case .lastEdit: return L("К последней правке")
        case .goToLine: return L("Перейти к строке")
        case .nextMember: return L("Следующее объявление")
        case .previousMember: return L("Предыдущее объявление")
        case .nextOccurrence: return L("Следующее вхождение")
        case .previousOccurrence: return L("Предыдущее вхождение")
        case .nextProblem: return L("Следующая ошибка")
        case .previousProblem: return L("Предыдущая ошибка")
        case .rename: return L("Переименовать")
        case .nextTab: return L("Следующая вкладка")
        case .previousTab: return L("Предыдущая вкладка")
        case .recentTab: return L("Недавняя вкладка (кроме ⌃Tab)")
        case .toggleSidebar: return L("Навигатор")
        case .revealInTree: return L("Показать файл в дереве")
        case .toggleInspector: return L("Инспектор Unity")
        case .fontBigger: return L("Шрифт крупнее")
        case .fontSmaller: return L("Шрифт мельче")
        case .fontReset: return L("Исходный размер шрифта")
        case .nextChange: return L("Следующее изменение")
        case .previousChange: return L("Предыдущее изменение")
        case .reviews: return L("Ревью мерж-реквестов")
        case .commentLine: return L("Комментировать строку")
        case .nextThread: return L("Следующий тред")
        case .previousThread: return L("Предыдущий тред")
        case .nextReviewFile: return L("Следующий файл MR")
        case .previousReviewFile: return L("Предыдущий файл MR")
        case .nextConflict: return L("Следующий конфликт")
        case .previousConflict: return L("Предыдущий конфликт")
        case .acceptCurrent: return L("Принять текущее")
        case .acceptIncoming: return L("Принять входящее")
        case .acceptBoth: return L("Принять оба")
        case .markResolved: return L("Отметить конфликт решённым")
        case .localHistory: return L("Локальная история")
        case .commit: return L("Коммит")
        case .assetUsages: return L("Где используется ассет")
        case .toggleMeta: return L("Ассет ↔ .meta")
        case .unityConsole: return L("Консоль Unity")
        case .run: return L("Запустить")
        case .stop: return L("Остановить")
        case .toggleConsole: return L("Консоль")
        case .nuget: return L("Пакеты NuGet")
        case .debugStart: return L("Начать отладку")
        case .debugStop: return L("Остановить отладку")
        case .debugContinue: return L("Продолжить")
        case .debugPause: return L("Приостановить")
        case .stepOver: return L("Шаг с обходом")
        case .stepInto: return L("Шаг с заходом")
        case .stepOut: return L("Шаг с выходом")
        case .toggleBreakpoint: return L("Точка останова")
        case .removeAllBreakpoints: return L("Убрать все точки останова")
        case .openPartner: return L("Парный проект")
        case .counterpart: return L("Двойник в паре")
        case .pairSearch: return L("Искать и в паре")
        case .datagramContract: return L("Сверка датаграмм")
        case .mirrorDrift: return L("Расхождения зеркал")
        }
    }

    /// Раздел в настройках — по части идентификатора до точки.
    var group: String {
        switch rawValue.split(separator: ".").first.map(String.init) ?? "" {
        case "file": return L("Файл")
        case "edit": return L("Правка")
        case "find": return L("Поиск в файле")
        case "search": return L("Поиск по проекту")
        case "nav", "refactor": return L("Навигация")
        case "view": return L("Вкладки и вид")
        case "git": return L("Git, ревью, конфликты")
        case "unity": return "Unity"
        case "run": return L("Запуск")
        case "debug": return L("Отладка")
        case "pair": return L("Пара")
        default: return L("Другое")
        }
    }

    static var groups: [String] { [L("Файл"), L("Правка"), L("Поиск в файле"), L("Поиск по проекту"), L("Навигация"),
                         L("Вкладки и вид"), L("Git, ревью, конфликты"), "Unity", L("Запуск"), L("Отладка"),
                         L("Пара")] }

    var defaultShortcut: Shortcut? {
        switch self {
        case .newWindow: return Shortcut("n", command: true, shift: true)
        case .openFolder: return Shortcut("o", command: true)
        case .closeProject: return Shortcut("w", command: true, shift: true)
        case .closeTab: return Shortcut("w", command: true)
        case .closeOtherTabs: return Shortcut("w", command: true, option: true)
        case .save: return Shortcut("s", command: true)
        case .saveAll: return Shortcut("s", command: true, option: true)
        case .toggleComment: return Shortcut("/", command: true)
        case .showCompletions: return Shortcut("escape", option: true)
        case .duplicateLines: return Shortcut("d", command: true)
        case .deleteLines: return Shortcut("delete", command: true)
        case .moveLinesUp: return Shortcut("up", option: true, shift: true)
        case .moveLinesDown: return Shortcut("down", option: true, shift: true)
        // Как в Rider.
        case .joinLines: return Shortcut("j", control: true, shift: true)
        case .toggleCase: return Shortcut("u", command: true, shift: true)
        case .extendSelection: return Shortcut("w", control: true)
        case .shrinkSelection: return Shortcut("w", control: true, shift: true)
        case .quickDocumentation: return Shortcut("j", control: true)
        case .parameterInfo: return Shortcut("space", command: true, shift: true)
        case .fold: return Shortcut("left", command: true, option: true)
        case .unfold: return Shortcut("right", command: true, option: true)
        case .foldAll: return Shortcut("left", command: true, option: true, shift: true)
        case .unfoldAll: return Shortcut("right", command: true, option: true, shift: true)
        case .find: return Shortcut("f", command: true)
        case .findAndReplace: return Shortcut("f", command: true, option: true)
        case .findNext: return Shortcut("g", command: true)
        case .findPrevious: return Shortcut("g", command: true, shift: true)
        case .useSelectionForFind: return Shortcut("e", command: true)
        case .searchEverywhere: return Shortcut("p", command: true)
        case .searchTypes: return nil
        case .fileStructure: return Shortcut("o", command: true, shift: true)
        case .searchSymbols: return Shortcut("t", command: true)
        case .findInFiles: return Shortcut("f", command: true, shift: true)
        case .changedFiles: return Shortcut("g", control: true, shift: true)
        case .recentLocations: return Shortcut("e", command: true, shift: true)
        case .goToDefinition: return Shortcut("b", command: true)
        case .findReferences: return Shortcut("r", command: true)
        case .valueGraph: return Shortcut("g", command: true, option: true)
        case .implementations: return Shortcut("b", command: true, option: true)
        case .contextActions: return Shortcut(".", command: true)
        case .back: return Shortcut("[", command: true)
        case .forward: return Shortcut("]", command: true)
        case .lastEdit: return Shortcut("delete", command: true, shift: true)
        case .goToLine: return Shortcut("l", command: true)
        case .nextMember: return Shortcut("down", control: true)
        case .previousMember: return Shortcut("up", control: true)
        case .nextOccurrence: return Shortcut("down", option: true)
        case .previousOccurrence: return Shortcut("up", option: true)
        case .nextProblem: return Shortcut("f2")
        case .previousProblem: return Shortcut("f2", shift: true)
        case .rename: return Shortcut("f6", shift: true)
        case .nextTab: return Shortcut("]", command: true, shift: true)
        case .previousTab: return Shortcut("[", command: true, shift: true)
        case .recentTab: return nil
        case .toggleSidebar: return Shortcut("s", command: true, control: true)
        case .revealInTree: return Shortcut("j", command: true, shift: true)
        case .toggleInspector: return Shortcut("0", command: true, option: true)
        case .fontBigger: return Shortcut("=", command: true)
        case .fontSmaller: return Shortcut("-", command: true)
        case .fontReset: return Shortcut("0", command: true)
        case .nextChange: return Shortcut("down", option: true, control: true)
        case .previousChange: return Shortcut("up", option: true, control: true)
        case .reviews: return Shortcut("r", command: true, option: true)
        case .commentLine: return Shortcut("c", command: true, option: true)
        case .nextThread: return Shortcut("]", command: true, option: true)
        case .previousThread: return Shortcut("[", command: true, option: true)
        case .nextReviewFile: return Shortcut("down", command: true, option: true)
        case .previousReviewFile: return Shortcut("up", command: true, option: true)
        case .nextConflict: return Shortcut("down", command: true, option: true, control: true)
        case .previousConflict: return Shortcut("up", command: true, option: true, control: true)
        case .acceptCurrent: return Shortcut("left", command: true, option: true, control: true)
        case .acceptIncoming: return Shortcut("right", command: true, option: true, control: true)
        case .acceptBoth: return nil
        case .markResolved: return nil
        case .localHistory: return Shortcut("h", option: true, control: true)
        // Как в Rider.
        case .commit: return Shortcut("k", command: true)
        case .assetUsages: return Shortcut("r", command: true, shift: true)
        case .toggleMeta: return Shortcut("m", command: true, control: true)
        case .unityConsole: return Shortcut("u", command: true, control: true)
        // Как в Rider: ⌘R и ⌘. здесь уже заняты использованиями и действиями.
        case .run: return Shortcut("r", control: true)
        case .stop: return Shortcut("f2", command: true)
        case .toggleConsole: return Shortcut("y", command: true, shift: true)
        case .nuget: return Shortcut("n", command: true, option: true)
        case .debugStart: return Shortcut("f9", shift: true)
        // ⌘F2 — у «Остановить» из запуска: он останавливает и отладку.
        case .debugStop: return nil
        case .debugContinue: return Shortcut("f9")
        case .debugPause: return nil
        case .stepOver: return Shortcut("f8")
        case .stepInto: return Shortcut("f7")
        case .stepOut: return Shortcut("f8", shift: true)
        case .toggleBreakpoint: return Shortcut("f8", command: true)
        case .removeAllBreakpoints: return nil
        case .openPartner: return Shortcut("p", command: true, control: true)
        case .counterpart: return Shortcut("t", command: true, control: true)
        case .pairSearch: return Shortcut("p", command: true, option: true)
        case .datagramContract: return nil
        case .mirrorDrift: return nil
        }
    }
}

// MARK: - Раскладка

/// Сочетания команд: по умолчанию и то, что человек поменял. В файле —
/// только поменянное, так что новые сочетания по умолчанию из следующих
/// версий Pilot до него доходят сами.
struct Keymap: Equatable {
    /// Поменянное: сочетание или `nil` — «без сочетания».
    private(set) var overrides: [EditorCommand: Shortcut?] = [:]

    func shortcut(for command: EditorCommand) -> Shortcut? {
        if let custom = overrides[command] { return custom }
        return command.defaultShortcut
    }

    func isCustomized(_ command: EditorCommand) -> Bool { overrides[command] != nil }

    /// Совпало с сочетанием по умолчанию — это уже не переопределение.
    mutating func set(_ shortcut: Shortcut?, for command: EditorCommand) {
        if shortcut == command.defaultShortcut {
            overrides[command] = nil
        } else {
            overrides[command] = .some(shortcut)
        }
    }

    mutating func reset(_ command: EditorCommand) { overrides[command] = nil }

    mutating func resetAll() { overrides = [:] }

    /// Другие команды с тем же сочетанием.
    func conflicts(for command: EditorCommand) -> [EditorCommand] {
        guard let shortcut = shortcut(for: command) else { return [] }
        return EditorCommand.allCases.filter { $0 != command && self.shortcut(for: $0) == shortcut }
    }

    /// Команда, на которой это сочетание, — кроме `except`.
    func command(using shortcut: Shortcut, except: EditorCommand? = nil) -> EditorCommand? {
        EditorCommand.allCases.first { $0 != except && self.shortcut(for: $0) == shortcut }
    }

    // MARK: Файл настроек

    /// JSON: `{"nav.back": "ctrl+-", "refactor.rename": null}`, ключи по
    /// алфавиту — чтобы файл было удобно читать и сравнивать.
    func serialized() -> String {
        var lines: [String] = []
        for command in EditorCommand.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let value = overrides[command] else { continue }
            let text = value.map { "\"\($0.text)\"" } ?? "null"
            lines.append("  \"\(command.rawValue)\": \(text)")
        }
        return lines.isEmpty ? "{}\n" : "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }

    /// Неизвестные команды и испорченные сочетания пропускаются: файл
    /// правят руками, и одна опечатка не должна стоить остальных привязок.
    static func parse(_ text: String) -> Keymap {
        var keymap = Keymap()
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let entries = object as? [String: Any] else { return keymap }
        for (id, value) in entries {
            guard let command = EditorCommand(rawValue: id) else { continue }
            if value is NSNull {
                keymap.set(nil, for: command)
            } else if let text = value as? String, let shortcut = Shortcut(text: text) {
                keymap.set(shortcut, for: command)
            }
        }
        return keymap
    }
}
