import Foundation

/// Где был курсор: история для ⌘[ и ⌘], места правок для ⇧⌘⌫ и список
/// недавних мест для ⇧⌘E.
///
/// Пишется в неё не только переход (⌘B, палитра, вкладка), но и далёкий
/// прыжок курсора внутри файла — клик на другом экране, ⌘↓, следующее
/// совпадение: назад хочется и оттуда. Мелкие движения — набор, стрелки —
/// не пишутся, а места в нескольких строках друг от друга считаются одним
/// местом: иначе ⌘[ пришлось бы жать по разу на каждую строку.
///
/// Без AppKit — ради тестов.
struct NavigationHistory {
    /// Дальше скольких строк движение курсора — прыжок, а не шаг.
    static let jumpLines = 10
    /// Ближе скольких строк два места — одно место.
    static let sameLines = 3
    static let capacity = 100

    private(set) var places: [NavTarget] = []
    private(set) var index = -1
    /// Места правок, свежие в конце.
    private(set) var edits: [NavTarget] = []
    /// Какое место правки показано последним (⇧⌘⌫ подряд идёт дальше в
    /// прошлое); `nil` — ещё ни одного, начинать с последней правки.
    private var editCursor: Int?

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < places.count - 1 }
    var current: NavTarget? { places.indices.contains(index) ? places[index] : nil }

    static func line(_ target: NavTarget) -> Int? { target.range?.start.line }

    /// Одно ли это место: тот же файл и рядом. Место без строки («файл, как
    /// он есть») совпадает с любым местом того же файла.
    static func near(_ a: NavTarget, _ b: NavTarget) -> Bool {
        guard a.url == b.url else { return false }
        guard let x = line(a), let y = line(b) else { return true }
        return abs(x - y) <= sameLines
    }

    // MARK: - Запись

    /// Явный переход: курсор был в `from`, уходит в `to`.
    mutating func navigate(from: NavTarget?, to: NavTarget) {
        if let from { settle(from) }
        push(to)
    }

    /// Курсор сдвинулся сам: клик, клавиши, поиск. Прыжок дальше
    /// `jumpLines` в том же файле записывается; приход курсора туда, куда
    /// только что перешли, уточняет текущее место, а не добавляет новое.
    mutating func caretMoved(from: NavTarget?, to: NavTarget) {
        if let current, Self.near(current, to) {
            // Переход по ⌘B, ⌘[ или вкладке приземлился — место уточняется.
            places[index] = Self.line(to) == nil ? current : to
            return
        }
        guard let from, from.url == to.url,
              let a = Self.line(from), let b = Self.line(to), abs(a - b) > Self.jumpLines else {
            // Шаг, или файл сменился без перехода (его записал бы переход).
            if let current, current.url == to.url, let a = Self.line(current), let b = Self.line(to),
               abs(a - b) <= Self.jumpLines {
                places[index] = to
            }
            return
        }
        settle(from)
        push(to)
    }

    /// Правка в `place`. Правки подряд в одном месте — одно место.
    mutating func edited(at place: NavTarget) {
        editCursor = nil
        if let last = edits.last, Self.near(last, place) {
            edits[edits.count - 1] = place
        } else {
            edits.append(place)
            if edits.count > Self.capacity { edits.removeFirst(edits.count - Self.capacity) }
        }
    }

    // MARK: - Назад, вперёд

    /// Шаг назад. `now` — где курсор сейчас: вперёд вернёт именно сюда.
    mutating func back(from now: NavTarget?) -> NavTarget? {
        guard canGoBack else { return nil }
        if let now { settle(now) }
        index -= 1
        return places[index]
    }

    mutating func forward(from now: NavTarget?) -> NavTarget? {
        guard canGoForward else { return nil }
        if let now { settle(now) }
        index += 1
        return places[index]
    }

    /// ⇧⌘⌫: последняя правка, а при повторе — правка перед ней. Место, где
    /// курсор уже стоит, пропускается: «к последней правке» оттуда, где
    /// только что правили, — это к предыдущей.
    mutating func previousEdit(from now: NavTarget?) -> NavTarget? {
        var i = (editCursor ?? edits.count) - 1
        while i >= 0 {
            if editCursor != nil || now.map({ !Self.near($0, edits[i]) }) ?? true {
                editCursor = i
                return edits[i]
            }
            i -= 1
        }
        return nil
    }

    /// Недавние места, свежие первыми, без повторов: история и правки.
    func recent(limit: Int = 50) -> [(place: NavTarget, edited: Bool)] {
        var result: [(place: NavTarget, edited: Bool)] = []
        // Сначала путь назад от текущего места, потом то, откуда вернулись.
        let upTo = min(index + 1, places.count)
        let visited: [NavTarget] = Array(places[..<upTo].reversed()) + Array(places[upTo...].reversed())
        var all: [(NavTarget, Bool)] = edits.reversed().map { ($0, true) }
        all += visited.map { ($0, false) }
        // Правки и переходы вперемешку по свежести не упорядочить — порядка
        // между ними нет. Правки первыми: к ним возвращаются чаще.
        for (place, edited) in all where !result.contains(where: { Self.near($0.place, place) }) {
            result.append((place, edited))
            if result.count >= limit { break }
        }
        return result
    }

    mutating func removeAll() {
        places.removeAll()
        edits.removeAll()
        index = -1
        editCursor = nil
    }

    // MARK: - Внутреннее

    /// Текущее место — туда, где курсор на самом деле: ушёл по экрану
    /// вниз — назад вернёт туда, а не к началу. Если он уже в другом
    /// файле (история пуста или переход его не записал), это новое место.
    private mutating func settle(_ now: NavTarget) {
        if let current, current.url == now.url {
            places[index] = now
        } else {
            push(now)
        }
    }

    private mutating func push(_ target: NavTarget) {
        if let current, Self.near(current, target) {
            places[index] = Self.line(target) == nil ? current : target
            return
        }
        if index < places.count - 1 { places.removeSubrange((index + 1)...) }
        places.append(target)
        if places.count > Self.capacity { places.removeFirst(places.count - Self.capacity) }
        index = places.count - 1
    }
}
