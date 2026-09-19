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
