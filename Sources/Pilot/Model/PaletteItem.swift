import Foundation

/// Что сейчас показывает палитра.
///
/// Лежит отдельно от Workspace и не зависит от AppKit намеренно: так этот
/// тип попадает в сборку тестов, и компилятор проверяет полноту switch
/// по режимам. Иначе забытая ветка всплывает только при сборке приложения.
enum PaletteMode: Equatable, CaseIterable {
    case files          // ⌘P  — fuzzy-поиск по именам файлов
    case classes        // ⇧⇧  — типы всего проекта, лексически, без LSP; следом файлы
    case outline        // ⌘⇧O — структура текущего файла, лексически, без LSP
    case symbols        // ⌘T  — символы проекта, через LSP
    case references     // ⌘R  — использования символа под курсором

    var placeholder: String {
        switch self {
        case .files:      return "Перейти к файлу…"
        case .classes:    return "Класс, интерфейс, структура…"
        case .outline:    return "Метод, свойство, поле…"
        case .symbols:    return "Символ в проекте…"
        case .references: return "Использования"
        }
    }

    var icon: String {
        switch self {
        case .files:      return "magnifyingglass"
        case .classes:    return "cube"
        case .outline:    return "list.bullet.indent"
        case .symbols:    return "number"
        case .references: return "arrow.triangle.branch"
        }
    }

    /// Нужен ли для этого режима языковой сервер.
    var requiresLanguageServer: Bool {
        switch self {
        case .files, .classes, .outline: return false
        case .symbols, .references:      return true
        }
    }
}

/// Строка в палитре. Один тип на все режимы, чтобы не плодить вьюхи.
struct PaletteItem: Identifiable {
    var id: Int
    var icon: String
    /// Основной текст; подсвечивается по `positions`.
    var primary: String
    var nameOffset: Int = 0
    var positions: [Int32] = []
    /// Приглушённый хвост: путь к файлу, имя класса-контейнера.
    var secondary: String?
    /// Правый край: номер строки, вид символа.
    var trailing: String?
    var target: NavTarget
}

/// Куда переходим. Диапазон нужен, чтобы подсветить найденное.
struct NavTarget: Equatable {
    var url: URL
    var range: LSPRange?
}
