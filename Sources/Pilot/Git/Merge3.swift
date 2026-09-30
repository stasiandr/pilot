import Foundation

/// Слияние трёх версий файла по строкам (diff3): общий предок, наша и их.
/// Отсюда — окно слияния, как в Rider: слева наша версия, справа их, в
/// середине результат, и каждый кусок, где правили обе стороны, решается
/// отдельно.
///
/// Считаем сами, а не берём маркеры из рабочей копии: там уже итог
/// `git merge-file`, и понять по нему, какие куски git слил сам, нельзя.
/// Здесь видно всё: что пришло только с нашей стороны, что только с их,
/// что обе сделали одинаково и где настоящий конфликт.
enum Merge3 {

    enum Side: Equatable, Sendable {
        case ours, theirs, both
    }

    struct Chunk: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Никто не трогал.
            case stable
            /// Правка одной стороны (или одинаковая у обеих) — берётся сама.
            case changed(Side)
            /// Обе стороны правили по-разному.
            case conflict
        }

        var kind: Kind
        var base: [String]
        var ours: [String]
        var theirs: [String]

        var isConflict: Bool { kind == .conflict }

        /// Что кусок даёт в результат, пока человек не решил иначе:
        /// конфликт — ничего не выбрано, остаётся база.
        var automatic: [String] {
            switch kind {
            case .stable: return base
            case .changed(.theirs): return theirs
            case .changed: return ours
            case .conflict: return base
            }
        }
    }

    static func merge(base: String, ours: String, theirs: String) -> [Chunk] {
        merge(base: split(base), ours: split(ours), theirs: split(theirs))
    }

    /// Строки как их видит человек: без `\r` и без пустого хвоста после
    /// последнего перевода строки.
    static func split(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func merge(base: [String], ours: [String], theirs: [String]) -> [Chunk] {
        let a = changes(base, ours)
        let b = changes(base, theirs)

        // Правки обеих сторон — по порядку в координатах базы. Перекрытые
        // или соприкасающиеся сливаются в одну область: вставка с одной
        // стороны вплотную к правке с другой — уже спор о том же месте.
        struct Edit { var base: Range<Int>; var new: Range<Int>; var side: Int }
        var edits = a.map { Edit(base: $0.oldLines, new: $0.lines, side: 0) }
            + b.map { Edit(base: $0.oldLines, new: $0.lines, side: 1) }
        edits.sort { ($0.base.lowerBound, $0.base.upperBound) < ($1.base.lowerBound, $1.base.upperBound) }

        var chunks: [Chunk] = []
        var position = 0
        // Сдвиг «строка базы → строка стороны» перед текущей областью.
        var delta = [0, 0]
        var i = 0
        while i < edits.count {
            var lo = edits[i].base.lowerBound
            var hi = edits[i].base.upperBound
            var group = [edits[i]]
            i += 1
            // Правки одной стороны друг друга не касаются: между кусками
            // диффа всегда есть общая строка. Значит, `<=` сливает только
            // перекрытие или стык с правкой другой стороны.
            while i < edits.count, edits[i].base.lowerBound <= hi {
                hi = max(hi, edits[i].base.upperBound)
                lo = min(lo, edits[i].base.lowerBound)
                group.append(edits[i])
                i += 1
            }
            if position < lo {
                chunks.append(Chunk(kind: .stable, base: Array(base[position..<lo]),
                                    ours: Array(base[position..<lo]), theirs: Array(base[position..<lo])))
            }
            // Диапазон области в каждой стороне: начало — через сдвиг до
            // области, конец — плюс сумма изменений длины внутри неё.
            var sideLines: [[String]] = []
            for side in 0..<2 {
                let own = group.filter { $0.side == side }
                let growth = own.reduce(0) { $0 + $1.new.count - $1.base.count }
                let start = lo + delta[side]
                let end = hi + delta[side] + growth
                let lines = side == 0 ? ours : theirs
                sideLines.append(Array(lines[max(0, start)..<min(lines.count, max(start, end))]))
                delta[side] += growth
            }
            let sides = Set(group.map(\.side))
            let kind: Chunk.Kind
            if sides.count == 1 {
                kind = .changed(sides.first == 0 ? .ours : .theirs)
            } else if sideLines[0] == sideLines[1] {
                kind = .changed(.both)
            } else {
                kind = .conflict
            }
            chunks.append(Chunk(kind: kind, base: Array(base[lo..<hi]), ours: sideLines[0], theirs: sideLines[1]))
            position = hi
        }
        if position < base.count {
            let rest = Array(base[position...])
            chunks.append(Chunk(kind: .stable, base: rest, ours: rest, theirs: rest))
        }
        return chunks
    }

    private static func changes(_ old: [String], _ new: [String]) -> [LineDiff.Change] {
        LineDiff.changes(old: old.map { ArraySlice($0.utf8) }, new: new.map { ArraySlice($0.utf8) },
                         maxEdits: LineDiff.maxEdits)
    }

    // MARK: - Разрешение без человека

    /// «Волшебная палочка» Rider: конфликты, которые можно решить без
    /// спора. Возвращает решение или nil.
    ///
    /// - стороны отличаются только пробелами — берём нашу;
    /// - одна сторона только добавила строки в конец базы, другая — тоже
    ///   только добавила: обе вставки подряд (типичные два новых `using`
    ///   или два новых поля в конце класса);
    /// - строки одной стороны — подмножество другой при том же порядке, и
    ///   база пуста: берём большую.
    static func autoResolve(_ chunk: Chunk) -> [String]? {
        guard chunk.isConflict else { return nil }
        func squeezed(_ lines: [String]) -> [String] {
            lines.map { $0.filter { !$0.isWhitespace } }.filter { !$0.isEmpty }
        }
        if squeezed(chunk.ours) == squeezed(chunk.theirs) { return chunk.ours }

        let base = chunk.base
        if chunk.ours.starts(with: base), chunk.theirs.starts(with: base) {
            let addedOurs = Array(chunk.ours.dropFirst(base.count))
            let addedTheirs = Array(chunk.theirs.dropFirst(base.count))
            return base + addedOurs + addedTheirs.filter { !addedOurs.contains($0) }
        }
        if base.isEmpty {
            if isSubsequence(chunk.ours, of: chunk.theirs) { return chunk.theirs }
            if isSubsequence(chunk.theirs, of: chunk.ours) { return chunk.ours }
        }
        return nil
    }

    private static func isSubsequence(_ small: [String], of big: [String]) -> Bool {
        var i = 0
        for line in big where i < small.count && line == small[i] { i += 1 }
        return i == small.count
    }

    /// Итоговый текст: куски по порядку, между строками `\n`, в конце —
    /// перевод строки, если он был у нашей версии.
    static func text(_ lines: [[String]], trailingNewline: Bool) -> String {
        let all = lines.joined()
        return all.joined(separator: "\n") + (trailingNewline && !all.isEmpty ? "\n" : "")
    }
}
