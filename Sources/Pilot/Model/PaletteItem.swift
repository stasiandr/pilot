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
    case symbols        // ⌘T  — символы проекта: быстрый индекс, затем LSP
    case references     // ⌘R  — использования символа под курсором
    case declarations   // ⌘B, когда тип цели неясен — выбор из одноимённых
    case changes        // ⌃⇧G — файлы, изменённые относительно HEAD
    case assetUsages    // ⇧⌘R — где используется ассет Unity: поиск GUID, без LSP

    var placeholder: String {
        switch self {
        case .files:      return "Перейти к файлу…"
        case .classes:    return "Класс, интерфейс, структура…"
        case .outline:    return "Метод, свойство, поле…"
        case .symbols:    return "Символ в проекте…"
        case .references: return "Использования"
        case .declarations: return "Одноимённые объявления — уточните"
        case .changes:    return "Изменённый файл…"
        case .assetUsages: return "Где используется ассет"
        }
    }

    var icon: String {
        switch self {
        case .files:      return "magnifyingglass"
        case .classes:    return "cube"
        case .outline:    return "list.bullet.indent"
        case .symbols:    return "number"
        case .references: return "arrow.triangle.branch"
        case .declarations: return "arrow.down.right.and.arrow.up.left"
        case .changes:    return "plusminus"
        case .assetUsages: return "link"
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
