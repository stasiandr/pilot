import Foundation

// Всё, что Rustlyn отдаёт, уже переведённое в свифтовые типы.
//
// Здесь намеренно нет `import CRustlyn`: эти типы должны собираться и там,
// где библиотеки нет вовсе — в тестах ядра, которые гоняются и на Linux, и в
// сборке Pilot у того, кто не ставил Rust. Разбор C-структур живёт в
// `Rustlyn.swift`, за `#if canImport`.

/// Что объявляет объявление. Повторяет `DeclarationKind` из Rustlyn; что
/// таблицы не разъехались, проверяет `Rustlyn.buildsAgree()` при запуске.
enum RustlynDeclarationKind: UInt8, CaseIterable {
    case namespace = 0
    case `class` = 1
    case `struct` = 2
    case `interface` = 3
    case `enum` = 4
    case record = 5
    case delegate = 6
    case method = 7
    case constructor = 8
    case destructor = 9
    case property = 10
    case indexer = 11
    case field = 12
    case event = 13
    case enumMember = 14
    case `operator` = 15
    case extensionBlock = 16

    /// Как это показать там, где Pilot уже умеет показывать объявления.
    ///
    /// Видов у Rustlyn больше, чем у структуры файла: индексатор и оператор —
    /// это методы для читателя, деструктор — тоже. Разницу, которую видно
    /// глазом, несёт `keyword`, а не иконка.
    var outlineKind: OutlineKind {
        switch self {
        case .namespace:                    return .namespace
        case .class, .struct, .interface,
             .enum, .record, .delegate,
             .extensionBlock:               return .type
        case .method, .operator,
             .destructor, .indexer:         return .method
        case .constructor:                  return .initializer
        case .property:                     return .property
        case .field, .event:                return .field
        case .enumMember:                   return .enumCase
        }
    }

    var isType: Bool {
        switch self {
        case .class, .struct, .interface, .enum, .record, .delegate: return true
        default: return false
        }
    }
}

/// Одно объявление, как его прочитал парсер.
struct RustlynDeclaration {
    var name: String
    var kind: RustlynDeclarationKind
    /// Слово, которым объявление введено: `class`, `record`, тип у поля.
    var keyword: String
    /// Объемлющий тип или пространство имён, полным именем.
    var container: String?
    /// Тип поля и свойства, возвращаемый тип метода — как записан.
    var typeText: String?
    var bases: [String] = []
    var genericParams: [String] = []
    /// Атрибуты без суффикса `Attribute`: `[SerializeField]` — это
    /// `SerializeField`.
    var attributes: [String] = []
    /// Параметры, каждый как `тип имя`.
    var parameters: [String] = []
    /// Диапазон имени в документе, UTF-16.
    var nameRange: NSRange
    /// Всё объявление целиком — для сворачивания.
    var fullRange: NSRange
    var line: Int
    var depth: Int
    var isStatic = false
    var isAbstract = false
    var isOverride = false
    var isPartial = false
    var isExtensionMethod = false

    /// Типы параметров, без имён: столько же, сколько их, и в том же порядке.
    /// Быстрый навигатор различает перегрузки по ним.
    var parameterTypes: [String] {
        parameters.map { parameter in
            guard let space = parameter.lastIndex(of: " ") else { return parameter }
            return String(parameter[parameter.startIndex..<space])
        }
    }
}

/// `using` в шапке файла.
struct RustlynUsing {
    var name: String
    var alias: String?

    init(name: String, alias: String? = nil) {
        self.name = name
        self.alias = alias
    }

    /// Из строки, как её отдаёт библиотека: псевдоним записан как
    /// `alias=name`, потому что список — это одна строка через `\n`.
    init(_ text: String) {
        if let equals = text.firstIndex(of: "=") {
            alias = String(text[text.startIndex..<equals])
            name = String(text[text.index(after: equals)...])
        } else {
            alias = nil
            name = text
        }
    }
}

/// Структура файла целиком.
struct RustlynOutline {
    var declarations: [RustlynDeclaration] = []
    var namespaces: [String] = []
    var usings: [RustlynUsing] = []
    /// Сколько ошибок нашёл парсер. Ненулевое значение — это нормально в
    /// файле, который правят прямо сейчас: структура всё равно лучшая из
    /// доступных, просто не полная.
    var parseErrors: Int = 0

    /// Структура файла в том виде, в каком её ждут `⌘⇧O`, jump bar и вкладка
    /// структуры в навигаторе.
    ///
    /// Пространства имён сюда не попадают по той же причине, по какой их нет
    /// и у своего разбора: в C#-файле оно почти всегда одно, и строка
    /// «Game.Systems» наверху списка занимает место, не отвечая ни на один
    /// вопрос. Имя пространства видно в хлебных крошках у типа.
    func outlineItems() -> [OutlineItem] {
        var items: [OutlineItem] = []
        items.reserveCapacity(declarations.count)
        for (id, declaration) in declarations.enumerated() {
            guard declaration.kind != .namespace else { continue }
            var kind = declaration.kind.outlineKind
            // Правила Unity — те же, что у своего разбора, и живут там же:
            // Rustlyn приносит имена и атрибуты, а что из этого значит
            // «движок это позовёт», знает Pilot.
            //
            // Разница в том, откуда берутся атрибуты. Своему разбору их
            // приходится искать пробегом назад по тексту до границы
            // предыдущей конструкции; здесь они разобраны парсером и висят
            // на объявлении, так что `[field: SerializeField]` и
            // `[UnityEngine.SerializeField]` узнаются наравне с обычным.
            if declaration.kind == .method,
               declaration.container != nil,
               UnityCSharp.eventFunctions.contains(declaration.name) {
                kind = .unityMessage
            } else if declaration.kind == .field || declaration.kind == .property,
                      declaration.attributes.contains(where: {
                          UnityCSharp.serializationAttributes.contains($0)
                      }) {
                kind = .serializedField
            }
            items.append(OutlineItem(
                id: id,
                name: declaration.name,
                kind: kind,
                range: declaration.nameRange,
                line: declaration.line,
                depth: declaration.depth,
                container: declaration.container,
                keyword: declaration.keyword.isEmpty ? nil : declaration.keyword,
                typeText: declaration.typeText,
                bases: declaration.bases,
                genericParams: declaration.genericParams,
                parameters: declaration.parameterTypes
            ))
        }
        return items
    }
}

/// Почему не получилось. Стоит различать: «курсор не на имени» — это не
/// ошибка вовсе, а «получателя не удалось вывести» стоит сказать вслух.
enum RustlynRefusal: Equatable {
    case none
    case notOpen
    case notCsharp
    case notIndexed
    case notAName
    /// Слева от точки стоит то, чей тип неизвестен. Сказать об этом честнее,
    /// чем найти другое имя с тем же словом и уйти туда.
    case receiverUnknown
    /// Имени нет в проекте — почти всегда тип из сборки.
    case notInProject
    case assembly
    case io
    /// Проект ещё не скомпилирован: что код значит, неизвестно, известно
    /// только, что он объявляет.
    case notCompiled
    case other

    /// Стоит ли говорить об этом в строке состояния. Про «не на имени»
    /// говорить нечего: пользователь и сам видит, где курсор.
    var worthSaying: Bool {
        switch self {
        case .none, .notAName, .notOpen, .notCsharp: return false
        default: return true
        }
    }
}

/// Одно объявление, куда можно прыгнуть.
struct RustlynTarget: Equatable {
    /// Путь, как его отдаёт библиотека: от корня проекта — для файла
    /// проекта, абсолютный — для того, что вне его. Вне проекта это почти
    /// всегда сборка: `⌘B` на `Vector3` ведёт в `UnityEngine.CoreModule.dll`,
    /// показанную как C#.
    static func url(forPath path: String, root: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    var url: URL
    /// Полное имя — чтобы показать список кандидатов.
    var name: String
    var line: Int
    /// UTF-16 от начала строки.
    var character: Int
    var length: Int
    var kind: RustlynDeclarationKind

    var navTarget: NavTarget {
        NavTarget(url: url,
                  range: LSPRange(start: LSPPosition(line: line, character: character),
                                  end: LSPPosition(line: line, character: character + length)))
    }

    /// Короткое имя без пути к нему: `Game.Pawn.Health` — это `Health`.
    var shortName: String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    /// То, что содержит объявление: `Game.Pawn.Health` — это `Game.Pawn`.
    var container: String? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        return String(name[name.startIndex..<dot])
    }
}

// MARK: - Переименование

/// Можно ли переименовать имя под курсором, и что это за имя.
struct RustlynRenameInfo: Equatable {
    /// Где имя в тексте, UTF-16.
    var range: NSRange
    /// Как оно написано: `@class` у экранированного ключевого слова.
    var text: String
    /// Что переименовывается, одной строкой: `class Game.Pawn`.
    var description: String
    /// Почему нельзя, или `nil`.
    var refused: String?

    /// Тип — его файл может ехать вслед за ним.
    var isType: Bool {
        let keyword = description.split(separator: " ").first.map(String.init) ?? ""
        return ["class", "struct", "interface", "enum", "record", "delegate"].contains(keyword)
    }

    /// Метод — у него бывают перегрузки. Описание метода — его сигнатура.
    var isMethod: Bool { !isType && description.contains("(") }
}

/// Что переименование делает кроме самого кода: галочки Roslyn.
struct RustlynRenameOptions: OptionSet {
    let rawValue: UInt32
    static let inComments = RustlynRenameOptions(rawValue: 1)
    static let inStrings = RustlynRenameOptions(rawValue: 2)
    static let overloads = RustlynRenameOptions(rawValue: 4)
    static let file = RustlynRenameOptions(rawValue: 8)
}

/// Одна правка в одном файле. Диапазон — UTF-16: в тексте, с которым
/// спрашивали, для того файла, и в скомпилированном — для остальных.
struct RustlynFileEdit: Equatable {
    var url: URL
    var range: NSRange
    var text: String
}

/// Место, которое переименование ломает, или — `resolved` — уже починило,
/// дописав `this.` или имя типа.
struct RustlynRenameConflict: Equatable {
    var url: URL
    var range: NSRange
    var message: String
    var resolved: Bool
}

/// Переименование целиком: правки, файлы, которые переименовать, и конфликты.
struct RustlynRenameResult: Equatable {
    var edits: [RustlynFileEdit] = []
    var files: [RustlynFileMove] = []
    var conflicts: [RustlynRenameConflict] = []
    /// Почему ничего не переименовано, или `nil`.
    var refused: String?
}

struct RustlynFileMove: Equatable {
    var from: URL
    var to: URL
}

/// Куда ведёт имя под курсором.
struct RustlynDefinition {
    /// Слово, которое было под курсором.
    var word: String = ""
    var targets: [RustlynTarget] = []
    /// Разрешила ли область видимости выбор. Если нет — показываем список,
    /// а не прыгаем в первое: наугад выбранный вариант уводит молча.
    var certain: Bool = true
    var refusal: RustlynRefusal = .none
    /// Причина словами, для строки состояния.
    var reason: String = ""

    var isEmpty: Bool { targets.isEmpty }

    init() {}

    init(refusal: RustlynRefusal, reason: String) {
        self.refusal = refusal
        self.reason = reason
    }
}

// MARK: - Компиляция проекта

/// Откуда Rustlyn узнал, что компилировать и против чего.
enum RustlynProjectKind: UInt8, Equatable {
    /// Из `.sln` и `.csproj`.
    case msbuild = 0
    /// Unity-проект без проектных файлов — по редактору, которым его открывали.
    case unity = 1
    /// Ни того ни другого: все `.cs` против самого нового .NET на машине.
    case folder = 2

    /// Файлы, по которым Rustlyn решает, что компилировать и против чего.
    /// Их правка меняет проект целиком, а не один файл.
    static func isProjectFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        return ["csproj", "sln", "slnx", "projitems", "props", "asmdef"].contains(ext)
            || name == "project.assets.json"
    }
}

/// Что сделала компиляция проекта.
struct RustlynCompiled: Equatable {
    var files = 0
    var references = 0
    /// Сколько `.csproj` описали проект.
    var projects = 0
    var milliseconds = 0
    var kind: RustlynProjectKind = .folder
    /// Ничего не изменилось с компиляции, что уже была, — часто прочитанной
    /// с диска, — и она осталась.
    var unchanged = false

    /// Для подсказки в статус-строке: что скомпилировано и против чего.
    var summary: String {
        let source: String
        switch kind {
        case .msbuild: source = Self.count(projects, "проект", "проекта", "проектов")
        case .unity:   source = L("Unity без .csproj")
        case .folder:  source = L("папка без .csproj")
        }
        // Не компилировали, а прочли или сверили: время тогда — не то, о
        // котором спрашивают.
        let seconds = String(format: "%.1f", Double(milliseconds) / 1000)
        let time = unchanged ? L("из кэша") : L("\(seconds) с")
        let compiled = Self.count(files, "файл", "файла", "файлов")
        let against = Self.count(references, "сборки", "сборок", "сборок")
        return L("\(compiled) против \(against) · \(source) · \(time)")
    }

    /// «1 файл», «3 файла», «7 файлов» — как `Theme.count`, которого здесь
    /// нет: эти типы собираются и без AppKit.
    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        Localization.count(n, one, few, many, grouped: false)
    }
}

/// Кто сейчас отвечает на вопросы о смысле C#-кода.
enum CompilerState: Equatable {
    /// Rustlyn нет или проект не открыт.
    case idle
    /// Компилируется. `first` — ни одной компиляции ещё не было, и на ⌘B
    /// отвечает индекс объявлений; иначе отвечает предыдущая компиляция.
    case compiling(first: Bool)
    case ready(RustlynCompiled)

    var isReady: Bool {
        switch self {
        case .ready, .compiling(first: false): return true
        default: return false
        }
    }
}

// MARK: - Автодополнение

/// Что предлагается. Повторяет `CompletionKind` из Rustlyn; что таблицы не
/// разъехались, проверяет `Rustlyn.buildsAgree()`.
enum RustlynCompletionKind: UInt8, CaseIterable {
    case method = 0
    case field = 1
    case property = 2
    case event = 3
    case local = 4
    case parameter = 5
    case `class` = 6
    case `struct` = 7
    case interface = 8
    case `enum` = 9
    case enumMember = 10
    case delegate = 11
    case namespace = 12
    case keyword = 13
    case typeParameter = 14
    case constant = 15
    /// Заготовка вроде `prop` или `ctor`: вставляет кусок кода, а не имя.
    case snippet = 16

    /// CompletionItemKind из LSP: по нему попап выбирает значок.
    var lspKind: Int {
        switch self {
        case .method:        return 2
        case .field:         return 5
        case .property:      return 10
        case .event:         return 23
        case .local,
             .parameter:     return 6
        case .class:         return 7
        case .struct:        return 22
        case .interface:     return 8
        case .enum:          return 13
        case .enumMember:    return 20
        case .delegate:      return 3
        case .namespace:     return 9
        case .keyword:       return 14
        case .typeParameter: return 25
        case .constant:      return 21
        case .snippet:       return 15
        }
    }
}

struct RustlynCompletion: Equatable {
    var label: String
    /// Тип или сигнатура: `int Health`, `void Heal(int by)`.
    var detail: String
    var kind: RustlynCompletionKind
    /// Меньше — выше: локальные, потом члены, потом типы, потом ключевые слова.
    var rank: Int
}

struct RustlynCompletions: Equatable {
    var items: [RustlynCompletion] = []
    /// Где начинается дописываемое слово, UTF-16: от него до курсора —
    /// то, по чему фильтруют, и то, что заменит выбранный вариант.
    var start = 0

    /// В том виде, в каком его показывает попап. Порядок — Rustlyn'а:
    /// `sortText` держит его, пока фильтр не переставит по совпадению.
    /// Правки нет: заменяется слово от его начала до курсора, как у
    /// дополнения словами, — Rustlyn считает начало слова так же.
    var list: CompletionList {
        CompletionList(items: items.enumerated().map { position, item in
            CompletionItem(
                label: item.label,
                kind: item.kind.lspKind,
                detail: item.detail.isEmpty ? nil : item.detail,
                sortText: String(format: "%03d%06d", item.rank, position))
        })
    }
}

// MARK: - Ошибки, сигнатуры, документация

/// Что не так в файле: место в UTF-16 текста, который спрашивали.
struct RustlynDiagnostic: Equatable {
    /// `hidden` — не ошибка, а код, который ничего не делает (лишний
    /// `using`, неиспользуемая переменная): его не перечисляют, а бледнят.
    enum Severity: UInt8 { case hidden = 0, info = 1, warning = 2, error = 3 }
    var range: NSRange
    var severity: Severity
    /// `CS0103`.
    var code: String
    var message: String
    /// Код лишний — редактор может его приглушить (IDE0005, IDE0051…).
    var unnecessary = false
    /// Использование `[Obsolete]` — редактор может его зачеркнуть.
    var deprecated = false
}

/// Ошибки файла и то, смотрел ли компилятор: до компиляции — только разбор.
struct RustlynDiagnostics: Equatable {
    var items: [RustlynDiagnostic] = []
    /// Лишний код без ошибки (severity `hidden`): не в списке и не волной,
    /// только чтобы приглушить.
    var faded: [RustlynDiagnostic] = []
    var semantic = false

    var errors: Int { items.filter { $0.severity == .error }.count }
    var warnings: Int { items.filter { $0.severity == .warning }.count }
}

/// Подсказка в строке, как в Rider: имя параметра перед аргументом
/// (`count:`), тип там, где он не написан (`var`, параметры лямбды).
/// В тексте её нет — редактор рисует её перед символом `position`.
struct RustlynInlayHint: Equatable {
    enum Kind: UInt8 { case type = 0, parameter = 1 }
    var position: Int
    var label: String
    var kind: Kind
    var paddingLeft = false
    var paddingRight = false
}

/// Сколько раз по проекту использовано объявленное в файле: `range` — имя
/// в объявлении.
struct RustlynLens: Equatable {
    var range: NSRange
    var count: Int
}

/// Подсказки в строках и счётчики использований файла — одним пакетом:
/// считаются вместе, после проверки файла.
struct RustlynInsights: Equatable {
    var hints: [RustlynInlayHint] = []
    var lenses: [RustlynLens] = []
}

/// Перегрузка вызова: `void Add(T item)` и где в ней каждый параметр.
struct RustlynSignature: Equatable {
    var label: String
    /// Диапазоны UTF-16 внутри `label`.
    var parameters: [NSRange]
}

/// Перегрузки набираемого вызова, подходящая и параметр под курсором.
struct RustlynSignatures: Equatable {
    var items: [RustlynSignature]
    var active: Int
    var parameter: Int

    /// Параметр, на котором курсор, в подходящей перегрузке.
    var activeParameter: NSRange? {
        guard items.indices.contains(active) else { return nil }
        let parameters = items[active].parameters
        return parameters.indices.contains(parameter) ? parameters[parameter] : nil
    }
}

/// Документация имени — обычным текстом.
struct RustlynDocumentation: Equatable {
    var signature: String
    var container: String
    var summary: String
    var parameters: [(name: String, text: String)]
    var returns: String

    static func == (a: Self, b: Self) -> Bool {
        a.signature == b.signature && a.container == b.container && a.summary == b.summary
            && a.returns == b.returns && a.parameters.map(\.name) == b.parameters.map(\.name)
            && a.parameters.map(\.text) == b.parameters.map(\.text)
    }

    /// Есть ли что показать сверх сигнатуры.
    var hasText: Bool { !summary.isEmpty || !returns.isEmpty || !parameters.isEmpty }
}
