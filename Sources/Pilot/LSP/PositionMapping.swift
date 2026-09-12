import Foundation

/// Перевод между смещением в документе и координатами LSP.
///
/// LSP по умолчанию считает `character` в UTF-16 code units — ровно в тех же
/// единицах, в которых работает SyntaxModel и NSTextView. Поэтому здесь нет
/// ни перекодирования, ни прохода по строке: только арифметика над lineStarts.
extension SyntaxModel {

    /// Смещение в документе (UTF-16) -> позиция LSP.
    func position(at offset: Int) -> LSPPosition {
        guard lineCount > 0 else { return LSPPosition(line: 0, character: 0) }
        let clamped = max(0, min(offset, units.count))
        let line = self.line(containing: clamped)
        return LSPPosition(line: line, character: clamped - Int(lineStarts[line]))
    }

    /// Позиция LSP -> смещение в документе (UTF-16).
    /// Позиции за концом строки и за концом файла подрезаются, а не роняют:
    /// сервер вполне может прислать координаты чуть устаревшей версии файла.
    func offset(at position: LSPPosition) -> Int {
        guard lineCount > 0 else { return 0 }
        let line = max(0, min(position.line, lineCount - 1))
        let start = Int(lineStarts[line])
        let end = line + 1 < lineCount ? Int(lineStarts[line + 1]) : units.count

        // Конец строки без учёта перевода строки.
        var lineEnd = end
        if lineEnd > start && units[lineEnd - 1] == 0x0A { lineEnd -= 1 }
        if lineEnd > start && units[lineEnd - 1] == 0x0D { lineEnd -= 1 }

        return min(start + max(0, position.character), lineEnd)
    }

    /// Диапазон LSP -> NSRange в тексте документа.
    func nsRange(for range: LSPRange) -> NSRange {
        let start = offset(at: range.start)
        let end = max(start, offset(at: range.end))
        return NSRange(location: start, length: end - start)
    }
}
