import Foundation

/// Правила вкладок без AppKit — чтобы гонять их в тестах ядра.
enum Tabs {

    /// Больше вкладок не держим: переходы по ⌘B открывают файл за файлом,
    /// и без предела полоса быстро забилась бы тем, что смотрели мельком.
    static let limit = 12

    /// Новая вкладка встаёт сразу за активной — рядом с тем, откуда пришли;
    /// без активной — в конец.
    static func insertionIndex(active: Int?, count: Int) -> Int {
        guard let active, active >= 0, active < count else { return count }
        return active + 1
    }

    /// Какую вкладку закрыть сверх лимита: ту, где дольше всех не были.
    /// Активную и с несохранёнными правками — никогда; nil — закрывать некого.
    static func evictionIndex(lastActivated: [Int], dirty: [Bool], active: Int?) -> Int? {
        var victim: Int?
        for index in lastActivated.indices where index != active && !dirty[index] {
            if victim.map({ lastActivated[index] < lastActivated[$0] }) ?? true { victim = index }
        }
        return victim
    }

    /// Порядок от недавней к давней — так ходит ⌃Tab.
    static func recentOrder(lastActivated: [Int]) -> [Int] {
        lastActivated.indices.sorted { lastActivated[$0] > lastActivated[$1] }
    }

    /// Подписи к одноимённым вкладкам: ближайшие папки, которых хватает,
    /// чтобы их различить, — `Scripts/Enemy` и `Scripts/Player` у двух
    /// `Health.cs`. У единственного имени подписи нет.
    static func details(forPaths paths: [String]) -> [String?] {
        let parts = paths.map { $0.split(separator: "/").map(String.init) }
        var byName: [String: [Int]] = [:]
        for (index, components) in parts.enumerated() {
            byName[components.last ?? "", default: []].append(index)
        }

        var result = [String?](repeating: nil, count: paths.count)
        for group in byName.values where group.count > 1 {
            let folders = group.map { Array(parts[$0].dropLast()) }
            let deepest = folders.map(\.count).max() ?? 0
            // Меньше папок — короче подпись; берём минимум, при котором
            // подписи разные. Совсем одинаковые пути (файл и его версия из MR)
            // так не различить — там разницу показывает значок.
            var depth = 1
            while depth < deepest {
                let tails = folders.map { $0.suffix(depth).joined(separator: "/") }
                if Set(tails).count == tails.count { break }
                depth += 1
            }
            for (position, index) in group.enumerated() {
                let tail = folders[position].suffix(depth).joined(separator: "/")
                result[index] = tail.isEmpty ? nil : tail
            }
        }
        return result
    }

    /// Длинное имя сокращается посередине: начало и расширение важнее.
    static func shortened(_ name: String, limit: Int = 36) -> String {
        guard name.count > limit else { return name }
        let tail = limit / 3
        return String(name.prefix(limit - tail - 1)) + "…" + String(name.suffix(tail))
    }
}

// MARK: - Куда попасть, открыв файл

/// Переход к месту в файле — поиск, ⌘B, использования, история, Unity, —
/// пока он «встаёт». Правила без AppKit, чтобы гонять их в тестах ядра;
/// применяет их CodeViewController.
///
/// После перехода экран ещё может уехать: раскладка досчитывает высоту
/// текста, SwiftUI даёт редактору размер, вкладка восстанавливает свою
/// прокрутку, над строками появляются счётчики использований. Поэтому место
/// держится, пока человек сам не тронул текст: увели — ставим снова.
struct Landing: Equatable {
    /// Что выделить: имя объявления, найденный текст или место курсора.
    let range: NSRange
    /// До какого момента держим место (по часам того, кто проверяет).
    let until: TimeInterval
    /// Сколько раз ещё можно поставить заново — чтобы не спорить без конца
    /// с тем, кто уводит экран на каждом витке.
    private(set) var fixesLeft: Int

    static let holdTime: TimeInterval = 1.2
    static let maxFixes = 8
    /// Когда проверять после перехода: следующий виток, потом по мере того,
    /// как доходят раскладка, размер вьюхи и поздние обновления.
    static let checkDelays: [TimeInterval] = [0, 0.05, 0.15, 0.3, 0.6, 1.2]

    init(range: NSRange, now: TimeInterval) {
        self.range = range
        until = now + Self.holdTime
        fixesLeft = Self.maxFixes
    }

    /// С чего показать вкладку. Переход важнее места, где её оставили:
    /// иначе уже открытый файл показался бы там, где его читали в прошлый
    /// раз. Без перехода — где оставили; новая — с начала.
    enum Start: Equatable {
        case target(NSRange)
        case saved
        case top
    }

    static func start(target: NSRange?, hasSaved: Bool) -> Start {
        if let target { return .target(target) }
        return hasSaved ? .saved : .top
    }

    /// Очередная проверка: true — место увели (выделение не то или цель не
    /// на экране), и его надо поставить снова.
    mutating func needsFix(selection: NSRange, onScreen: Bool) -> Bool {
        guard selection != range || !onScreen, fixesLeft > 0 else { return false }
        fixesLeft -= 1
        return true
    }

    /// Держать дальше незачем: время вышло или поправки кончились.
    func isOver(now: TimeInterval) -> Bool { now >= until || fixesLeft == 0 }

    // Прокрутка к цели, как в Rider. Всё — по вертикали, в координатах текста.

    /// Цель видна с запасом `margin` — экран не двигается. Цель выше экрана
    /// целиком не увидеть — достаточно её начала.
    static func isVisible(target: ClosedRange<CGFloat>, visible: ClosedRange<CGFloat>, margin: CGFloat) -> Bool {
        let height = visible.upperBound - visible.lowerBound
        let pad = padding(margin, height: height)
        let tall = target.upperBound - target.lowerBound > height - 2 * pad
        let bottom = tall ? target.lowerBound : target.upperBound
        return target.lowerBound >= visible.lowerBound + pad && bottom <= visible.upperBound - pad
    }

    /// Верх видимой области высотой `height`, при котором цель посередине.
    /// Цель выше экрана (блок на несколько экранов) — её начало, с запасом.
    static func centeredTop(target: ClosedRange<CGFloat>, height: CGFloat, margin: CGFloat) -> CGFloat {
        let pad = padding(margin, height: height)
        if target.upperBound - target.lowerBound > height - 2 * pad { return target.lowerBound - pad }
        return (target.lowerBound + target.upperBound) / 2 - height / 2
    }

    /// Запас не больше четверти экрана: на низком окне два поля съели бы всё.
    private static func padding(_ margin: CGFloat, height: CGFloat) -> CGFloat {
        min(margin, max(0, height / 4))
    }
}
