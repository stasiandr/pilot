import Foundation

/// Кусок текста, который можно свернуть.
///
/// Свёрнутым он показывает свою первую строку до `hidden` и значок вместо
/// остального: `void M() {⋯}`, `#region Input ⋯`, `/* Лицензия ⋯`.
struct FoldRegion: Equatable, Hashable {
    /// Строка, у которой в гаттере стрелка.
    var line: Int
    /// Строка, где кончается.
    var endLine: Int
    /// Что прячется, в UTF-16: от после открывающей скобки до закрывающей.
    var hidden: NSRange
}

/// Что сворачивается в файле: скобки на несколько строк, `#region` и
/// многострочные комментарии. Лексер уже знает, где строки и комментарии,
/// так что скобка в строке или комментарии блока не открывает.
enum FoldRegions {

    static func compute(_ model: SyntaxModel) -> [FoldRegion] {
        guard model.lineCount > 1 else { return [] }
        let units = model.units
        let tokens = model.tokens(fromLine: 0, toLine: model.lineCount - 1)
        var regions: [FoldRegion] = []

        // Где скобки не в счёт: строки и комментарии. Лексемы идут по
        // порядку, так что хватает одного указателя.
        var skipped: [Range<Int>] = []
        // Блочный комментарий лексер отдаёт по лексеме на строку: где он
        // открылся, пока не встретится `*/`.
        var block: (start: Int, line: Int)?
        for token in tokens {
            let start = Int(token.start), end = Int(token.start + token.length)
            guard start >= 0, end <= units.count, end > start else { continue }
            switch token.kind {
            case .comment, .docComment:
                skipped.append(start..<end)
                let text = units[start..<end]
                let opens = block == nil && text.starts(with: [0x2F, 0x2A])          // /*
                let closes = text.count >= 2 && Array(text.suffix(2)) == [0x2A, 0x2F]   // */
                if opens { block = (start, model.line(containing: start)) }
                if let open = block, closes {
                    block = nil
                    let last = model.line(containing: end - 1)
                    let lineEnd = lineContentEnd(model, open.line)
                    if last > open.line, lineEnd < end {
                        regions.append(FoldRegion(line: open.line, endLine: last,
                                                  hidden: NSRange(location: lineEnd, length: end - lineEnd)))
                    }
                }
            case .string, .escape:
                skipped.append(start..<end)
            default:
                break
            }
        }

        var braces: [(offset: Int, line: Int)] = []
        var markers: [(offset: Int, line: Int)] = []   // #region
        var next = 0
        var line = 0
        var lineStart = true
        var i = 0
        while i < units.count {
            while next < skipped.count, skipped[next].upperBound <= i { next += 1 }
            if next < skipped.count, skipped[next].contains(i) {
                // Перевод строки внутри комментария всё равно перевод.
                let end = skipped[next].upperBound
                for k in i..<end where units[k] == 0x0A { line += 1 }
                lineStart = false
                i = end
                continue
            }
            let c = units[i]
            switch c {
            case 0x0A:
                line += 1
                lineStart = true
            case 0x20, 0x09, 0x0D:
                break
            case 0x23 where lineStart:   // # в начале строки
                let rest = String(decoding: units[i..<lineContentEnd(model, line)], as: UTF16.self)
                if rest.hasPrefix("#region") {
                    markers.append((lineContentEnd(model, line), line))
                } else if rest.hasPrefix("#endregion"), let open = markers.popLast(), line > open.line {
                    let start = Int(model.lineStarts[line])
                    regions.append(FoldRegion(line: open.line, endLine: line,
                                              hidden: NSRange(location: open.offset,
                                                              length: max(0, start - open.offset))))
                }
                lineStart = false
            case 0x7B:   // {
                braces.append((i, line))
                lineStart = false
            case 0x7D:   // }
                if let open = braces.popLast(), line > open.line {
                    regions.append(FoldRegion(line: open.line, endLine: line,
                                              hidden: NSRange(location: open.offset + 1,
                                                              length: i - open.offset - 1)))
                }
                lineStart = false
            default:
                lineStart = false
            }
            i += 1
        }
        regions.append(contentsOf: lineCommentRuns(model, tokens))
        // Одна стрелка на строку: внешнее — то, что начинается на ней первым.
        var byLine: [Int: FoldRegion] = [:]
        for region in regions {
            if let existing = byLine[region.line], existing.hidden.location <= region.hidden.location,
               existing.endLine >= region.endLine {
                continue
            }
            byLine[region.line] = region
        }
        return byLine.values.sorted { $0.line < $1.line }
    }

    /// Три и больше строчных комментариев подряд — шапка файла, описание
    /// метода — сворачиваются в первую строку.
    private static func lineCommentRuns(_ model: SyntaxModel, _ tokens: [Token]) -> [FoldRegion] {
        var runs: [FoldRegion] = []
        var first: Int?, last = -1, runEnd = 0
        func close() {
            if let start = first, last - start >= 2 {
                let lineEnd = lineContentEnd(model, start)
                if lineEnd < runEnd {
                    runs.append(FoldRegion(line: start, endLine: last,
                                           hidden: NSRange(location: lineEnd, length: runEnd - lineEnd)))
                }
            }
            first = nil
        }
        for token in tokens where token.kind == .comment || token.kind == .docComment {
            let line = model.line(containing: Int(token.start))
            let end = Int(token.start + token.length)
            // Только `//`: строки блочного комментария сворачиваются им самим.
            guard model.units[Int(token.start)..<end].starts(with: [0x2F, 0x2F]),
                  model.line(containing: max(Int(token.start), end - 1)) == line,
                  onlyWhitespaceBefore(model, Int(token.start), line) else {
                close()
                continue
            }
            if first != nil, line == last + 1 {
                last = line
            } else {
                close()
                first = line
                last = line
            }
            runEnd = end
        }
        close()
        return runs
    }

    /// Конец строки без перевода.
    private static func lineContentEnd(_ model: SyntaxModel, _ line: Int) -> Int {
        let range = model.lineRange(line)
        var end = range.upperBound
        while end > range.lowerBound, model.units[end - 1] == 0x0A || model.units[end - 1] == 0x0D { end -= 1 }
        return end
    }

    private static func onlyWhitespaceBefore(_ model: SyntaxModel, _ offset: Int, _ line: Int) -> Bool {
        let start = Int(model.lineStarts[line])
        return model.units[start..<offset].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }
}
