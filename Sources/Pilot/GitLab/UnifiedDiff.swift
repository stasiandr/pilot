import Foundation

/// Дифф одного файла MR, разобранный из unified diff, который отдаёт GitLab.
///
/// Разбираем именно его, а не считаем свой: номера строк в комментариях
/// GitLab привязаны к его диффу, и полоски у строк должны совпадать с тем,
/// что ревьюер увидит в вебе. Файлы с версии MR при этом не нужны вовсе —
/// удалённые строки лежат прямо в диффе.
struct UnifiedDiff: Equatable, Sendable {

    /// Блок изменений: старые строки, заменённые новыми. Номера — с нуля,
    /// как в SyntaxModel; у блоков вида `.deleted` новый диапазон пустой.
    struct Block: Equatable, Sendable {
        var kind: LineDiff.Kind
        var newLines: Range<Int>
        var oldLines: Range<Int>
        var removed: [String]
    }

    var blocks: [Block] = []
    /// Диапазоны новых строк, которые GitLab показывает в диффе (с контекстом).
    var hunks: [Range<Int>] = []

    var additions: Int { blocks.reduce(0) { $0 + $1.newLines.count } }
    var deletions: Int { blocks.reduce(0) { $0 + $1.oldLines.count } }

    /// Для полосок в колонке номеров.
    var changes: [LineDiff.Change] {
        blocks.map { LineDiff.Change(kind: $0.kind, lines: $0.newLines, oldLines: $0.oldLines) }
    }

    static func parse(_ text: String) -> UnifiedDiff {
        var result = UnifiedDiff()
        var oldPos = 0, newPos = 0
        var hunkStart = 0
        var inHunk = false

        var pendingOld: Int?
        var pendingNew = 0
        var removed: [String] = []
        var added = 0

        func flush() {
            guard let oldStart = pendingOld else { return }
            let newLines = pendingNew..<(pendingNew + added)
            let oldLines = oldStart..<(oldStart + removed.count)
            let kind: LineDiff.Kind = newLines.isEmpty ? .deleted : (oldLines.isEmpty ? .added : .modified)
            result.blocks.append(Block(kind: kind, newLines: newLines, oldLines: oldLines, removed: removed))
            pendingOld = nil
            removed = []
            added = 0
        }
        func closeHunk() {
            flush()
            if inHunk { result.hunks.append(hunkStart..<max(hunkStart, newPos)) }
            inHunk = false
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(raw)
            if line.last == "\r" { line = line.dropLast() }
            guard let marker = line.first else { continue }
            switch marker {
            case "@":
                guard let header = HunkHeader(line) else { continue }
                closeHunk()
                oldPos = header.oldStart
                newPos = header.newStart
                hunkStart = newPos
                inHunk = true
            case " ":
                flush()
                oldPos += 1
                newPos += 1
            case "-":
                guard inHunk else { continue }
                if pendingOld == nil { pendingOld = oldPos; pendingNew = newPos }
                removed.append(String(line.dropFirst()))
                oldPos += 1
            case "+":
                guard inHunk else { continue }
                if pendingOld == nil { pendingOld = oldPos; pendingNew = newPos }
                added += 1
                newPos += 1
            default:
                continue   // «\ No newline at end of file» и заголовки файлов
            }
        }
        closeHunk()
        return result
    }

    /// `@@ -a,b +c,d @@ …`, счётчики необязательны. Возвращает начала с нуля:
    /// у пустой стороны (`-0,0`, `+5,0`) число — строка, после которой вставка.
    private struct HunkHeader {
        var oldStart: Int
        var newStart: Int

        init?(_ line: Substring) {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[0] == "@@",
                  let old = Self.range(parts[1], sign: "-"),
                  let new = Self.range(parts[2], sign: "+") else { return nil }
            oldStart = old.count == 0 ? old.start : old.start - 1
            newStart = new.count == 0 ? new.start : new.start - 1
        }

        private static func range(_ token: Substring, sign: Character) -> (start: Int, count: Int)? {
            guard token.first == sign else { return nil }
            let numbers = token.dropFirst().split(separator: ",")
            guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
            let count = numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1
            return (start, count)
        }
    }

    // MARK: - Сопоставление строк

    /// Блок, к которому относится новая строка: для изменённых строк — тот,
    /// что их содержит; для `.deleted` — тот, что удалён прямо перед ней.
    func block(atNewLine line: Int) -> Block? {
        blocks.first { $0.newLines.contains(line) }
            ?? blocks.first { $0.newLines.isEmpty && $0.newLines.lowerBound == line }
    }

    /// Старый номер неизменённой строки. nil — строка добавлена или изменена.
    func oldLine(forNewLine line: Int) -> Int? {
        var delta = 0
        for block in blocks {
            if block.newLines.contains(line) { return nil }
            if block.newLines.upperBound > line || (block.newLines.isEmpty && block.newLines.lowerBound > line) {
                break
            }
            delta += block.oldLines.count - block.newLines.count
        }
        return line + delta
    }

    /// Где в новом тексте показать то, что привязано к старой строке:
    /// неизменённая — на её новом месте, удалённая — там, где был блок.
    func newLine(forOldLine line: Int) -> Int {
        var delta = 0
        for block in blocks {
            if block.oldLines.contains(line) { return block.newLines.lowerBound }
            if block.oldLines.lowerBound > line { break }
            delta += block.newLines.count - block.oldLines.count
        }
        return line + delta
    }

    /// Позиция нового комментария к строке нового текста (номера с единицы,
    /// как их ждёт API): у добавленной строки — только новая, у неизменённой —
    /// обе, иначе GitLab не поймёт, к какой версии строки он относится.
    func commentLines(forNewLine line: Int) -> (old: Int?, new: Int) {
        (oldLine(forNewLine: line).map { $0 + 1 }, line + 1)
    }

    /// На какой строке нового текста показать тред.
    func displayLine(for position: GLPosition) -> Int? {
        if let new = position.newLine { return new - 1 }
        if let old = position.oldLine { return newLine(forOldLine: old - 1) }
        return nil
    }
}
