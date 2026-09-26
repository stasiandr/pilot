import Foundation
import Observation

/// Курсор и то, что от него зависит: позиция, объявление под ним,
/// вхождения слова.
///
/// Отдельно от Workspace и через Observation, а не @Published: курсор
/// сдвигается на каждое нажатие, и опубликованный в Workspace, он
/// заставлял SwiftUI пересчитывать на каждую букву всё окно вместе с меню
/// команд — на файле в 10 000 строк это десятки миллисекунд. Observation
/// следит за чтением по свойствам: строка состояния зависит только от
/// позиции, jump bar и навигатор — от объявления, текст — от вхождений.
///
/// Observation оповещает о любой записи, даже того же значения, поэтому
/// пишем только через `set…`: они пропускают повторы.
@MainActor @Observable
final class EditorCaret {
    /// Позиция курсора (UTF-16) — отсюда берутся запросы к LSP.
    private(set) var offset = 0
    /// Объявление, внутри которого курсор, — для jump bar и навигатора структуры.
    private(set) var outlineItem: OutlineItem?
    /// Вхождения идентификатора под курсором — подсвечиваются в тексте.
    private(set) var occurrences: [NSRange] = []

    func setOffset(_ value: Int) {
        if offset != value { offset = value }
    }

    func setOutlineItem(_ item: OutlineItem?) {
        if outlineItem != item { outlineItem = item }
    }

    func setOccurrences(_ ranges: [NSRange]) {
        if occurrences != ranges { occurrences = ranges }
    }

    func reset() {
        setOffset(0)
        setOutlineItem(nil)
        setOccurrences([])
    }
}
