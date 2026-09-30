import Foundation

/// Что стоит в строке под редактором и в каком порядке — как кнопки в
/// тулбаре, только настраивается своим окном: тулбар настраивает AppKit,
/// а строка — вид SwiftUI. Хранится строкой через запятую: её можно
/// поправить и в `defaults write`.
enum StatusBarItem: String, CaseIterable, Hashable, Sendable {
    case language, lines, space, unity, blame, changes, branch, caret, activity

    var title: String {
        switch self {
        case .language: return L("Язык файла")
        case .lines: return L("Число строк")
        case .space: return L("Растяжка")
        case .unity: return "Unity"
        case .blame: return L("Автор строки (blame)")
        case .changes: return L("Изменения и ↑↓ к серверу")
        case .branch: return L("Ветка git")
        case .caret: return L("Позиция курсора")
        case .activity: return L("Индексация и компиляция")
        }
    }

    var icon: String {
        switch self {
        case .language: return "doc.text"
        case .lines: return "number"
        case .space: return "arrow.left.and.right"
        case .unity: return "cube"
        case .blame: return "person"
        case .changes: return "plusminus"
        case .branch: return "arrow.triangle.branch"
        case .caret: return "text.cursor"
        case .activity: return "circle.dotted"
        }
    }
}

enum StatusBarLayout {
    static let key = "pilot.statusBar"
    static let defaults: [StatusBarItem] = [.language, .lines, .space, .unity, .blame, .changes, .branch, .caret, .activity]
    static let defaultText = encode(defaults)

    /// Неизвестное пропускается, повтор — тоже; пустая строка — как по умолчанию.
    static func decode(_ text: String) -> [StatusBarItem] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return defaults }
        var seen = Set<StatusBarItem>()
        return text.split(separator: ",")
            .compactMap { StatusBarItem(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { seen.insert($0).inserted }
    }

    /// Всё скрыли — строка пустая, но не «как по умолчанию»: для этого
    /// пишем растяжку, она ничего не показывает.
    static func encode(_ items: [StatusBarItem]) -> String {
        items.isEmpty ? StatusBarItem.space.rawValue : items.map(\.rawValue).joined(separator: ",")
    }

    static func hidden(_ items: [StatusBarItem]) -> [StatusBarItem] {
        StatusBarItem.allCases.filter { !items.contains($0) }
    }
}
