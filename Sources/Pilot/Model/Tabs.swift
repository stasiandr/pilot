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
