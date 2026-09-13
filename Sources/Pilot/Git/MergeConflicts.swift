import Foundation

/// Конфликт слияния в тексте файла — блок между маркерами git:
///
///     <<<<<<< HEAD              ← start
///     текущее (ours)
///     ||||||| base              ← base, только в стиле diff3/zdiff3
///     общий предок
///     =======                   ← separator
///     входящее (theirs)
///     >>>>>>> feature           ← end
///
/// Номера строк — с нуля, как в SyntaxModel.
struct MergeConflict: Equatable, Sendable {
    var start: Int
    var base: Int?
    var separator: Int
    var end: Int
    /// Что git написал после маркера: обычно `HEAD` и имя ветки или коммита.
    var currentLabel: String
    var incomingLabel: String

    var current: Range<Int> { (start + 1)..<(base ?? separator) }
    var common: Range<Int>? { base.map { ($0 + 1)..<separator } }
    var incoming: Range<Int> { (separator + 1)..<end }
    var lines: ClosedRange<Int> { start...end }
}

/// Чем заменить конфликт.
enum ConflictChoice: Equatable, Sendable {
    case current
    case incoming
    /// Оба варианта: сначала текущее, потом входящее.
    case both
    /// Общий предок — «откатить обе стороны».
    case base
}

enum MergeConflicts {

    /// Все целые конфликты файла. Недописанные (нет `=======` или
    /// `>>>>>>>`) пропускаются: это либо чужой текст, либо правка на ходу.
    static func find(in model: SyntaxModel) -> [MergeConflict] {
        var result: [MergeConflict] = []
        var open: (start: Int, label: String)?
        var base: Int?
        var separator: Int?

        let units = model.units
        for line in 0..<model.lineCount {
            let range = model.lineRange(line)
            // Быстрый отсев: маркер — семь одинаковых символов в начале строки.
            guard range.count >= 7, let first = units[safe: range.lowerBound],
                  first == 0x3C || first == 0x7C || first == 0x3D || first == 0x3E else { continue }
            guard let marker = Marker(units, range) else { continue }

            switch marker.kind {
            case .start:
                // Новый `<<<<<<<` до закрытия прошлого — прошлый был не конфликтом.
                open = (line, marker.label)
                base = nil
                separator = nil
            case .base:
                if open != nil, separator == nil, base == nil { base = line }
            case .separator:
                if open != nil, separator == nil { separator = line }
            case .end:
                if let opened = open, let sep = separator {
                    result.append(MergeConflict(start: opened.start, base: base, separator: sep, end: line,
                                                currentLabel: opened.label, incomingLabel: marker.label))
                }
                open = nil
                base = nil
                separator = nil
            }
        }
        return result
    }

    /// Какой диапазон текста заменить и на что. Диапазон — от начала строки
    /// `<<<<<<<` до начала строки после `>>>>>>>` (UTF-16, как NSRange).
    static func resolution(of conflict: MergeConflict, choice: ConflictChoice,
                           in model: SyntaxModel) -> (range: NSRange, text: String) {
        let units = model.units
        let startOffset = model.lineRange(conflict.start).lowerBound
        let endRange = model.lineRange(conflict.end)

        func text(_ lines: Range<Int>) -> [UInt16] {
            guard !lines.isEmpty else { return [] }
            let from = model.lineRange(lines.lowerBound).lowerBound
            let to = model.lineRange(lines.upperBound - 1).upperBound
            return Array(units[from..<to])
        }

        var replacement: [UInt16]
        switch choice {
        case .current:  replacement = text(conflict.current)
        case .incoming: replacement = text(conflict.incoming)
        case .both:     replacement = text(conflict.current) + text(conflict.incoming)
        case .base:     replacement = conflict.common.map(text) ?? []
        }

        // `>>>>>>>` на последней строке без перевода строки: у замены тоже
        // не должно быть хвостового перевода, иначе файл «вырастет» на строку.
        let endHasNewline = endRange.upperBound > endRange.lowerBound && units[endRange.upperBound - 1] == 0x0A
        if !endHasNewline, replacement.last == 0x0A {
            replacement.removeLast()
            if replacement.last == 0x0D { replacement.removeLast() }
        }

        return (NSRange(location: startOffset, length: endRange.upperBound - startOffset),
                String(decoding: replacement, as: UTF16.self))
    }

    /// Конфликт, в котором стоит строка, — для команд «принять» с клавиатуры.
    static func conflict(atLine line: Int, in conflicts: [MergeConflict]) -> MergeConflict? {
        conflicts.first { $0.lines.contains(line) }
    }

    // MARK: - Маркеры

    private struct Marker {
        enum Kind { case start, base, separator, end }
        var kind: Kind
        var label: String

        /// Ровно семь символов маркера, дальше — конец строки или пробел
        /// с меткой. `========` (восемь) — уже не маркер, а, скажем, заголовок
        /// в Markdown.
        init?(_ units: [UInt16], _ range: Range<Int>) {
            let first = units[range.lowerBound]
            for i in 1..<7 where units[range.lowerBound + i] != first { return nil }
            var end = range.upperBound
            while end > range.lowerBound + 7, units[end - 1] == 0x0A || units[end - 1] == 0x0D { end -= 1 }
            let restStart = range.lowerBound + 7
            if restStart < end, units[restStart] != 0x20 { return nil }

            switch first {
            case 0x3C: kind = .start
            case 0x7C: kind = .base
            case 0x3E: kind = .end
            default:
                kind = .separator
                // У разделителя метки не бывает.
                guard restStart == end else { return nil }
            }
            label = restStart < end
                ? String(decoding: units[(restStart + 1)..<end], as: UTF16.self)
                    .trimmingCharacters(in: .whitespaces)
                : ""
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
