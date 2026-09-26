import Foundation

/// Что сейчас показывает палитра.
///
/// Лежит отдельно от Workspace и не зависит от AppKit намеренно: так этот
/// тип попадает в сборку тестов, и компилятор проверяет полноту switch
/// по режимам. Иначе забытая ветка всплывает только при сборке приложения.
enum PaletteMode: Equatable, CaseIterable {
    case search         // ⌘P ⇧⇧ ⌘T ⇧⌘F — единый поиск: файлы, типы, символы, текст
    case outline        // ⌘⇧O — структура текущего файла, лексически, без LSP
    case references     // ⌘R  — использования символа под курсором
    case declarations   // ⌘B, когда тип цели неясен — выбор из одноимённых
    case implementations // ⌥⌘B — наследники типа, переопределения метода
    case changes        // ⌃⇧G — файлы, изменённые относительно HEAD
    case recentLocations // ⇧⌘E — недавние места курсора и правки
    case assetUsages    // ⇧⌘R — где используется ассет Unity: поиск GUID, без LSP
    case counterparts   // ⌃⌘T — двойник во второй половине пары, связи конфига
    case contract       // сверка датаграмм клиента и сервера
    case mirrors        // зеркальные файлы пары, которые разошлись

    var placeholder: String {
        switch self {
        case .search:     return SearchScope.everything.placeholder
        case .outline:    return L("Метод, свойство, поле…")
        case .references: return L("Использования")
        case .declarations: return L("Одноимённые объявления — уточните")
        case .implementations: return L("Реализации и наследники")
        case .changes:    return L("Изменённый файл…")
        case .recentLocations: return L("Недавнее место…")
        case .assetUsages: return L("Где используется ассет")
        case .counterparts: return L("Во второй половине пары")
        case .contract:   return L("Датаграмма…")
        case .mirrors:    return L("Зеркальный файл…")
        }
    }

    var icon: String {
        switch self {
        case .search:     return "magnifyingglass"
        case .outline:    return "list.bullet.indent"
        case .references: return "arrow.triangle.branch"
        case .declarations: return "arrow.down.right.and.arrow.up.left"
        case .implementations: return "point.3.connected.trianglepath.dotted"
        case .changes:    return "plusminus"
        case .recentLocations: return "clock.arrow.circlepath"
        case .assetUsages: return "link"
        case .counterparts: return "arrow.left.arrow.right"
        case .contract:   return "antenna.radiowaves.left.and.right"
        case .mirrors:    return "doc.on.doc"
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
    /// Имя объявления, к которому прыгаем, когда строка заранее неизвестна:
    /// тип из сборки ищут в её тексте уже после того, как он собран.
    var declaration: String? = nil
}
