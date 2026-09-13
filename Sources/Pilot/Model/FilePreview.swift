import Foundation

/// Фрагмент файла для предпросмотра в палитре: несколько десятков строк
/// вокруг цели, уже разрезанные на отрезки с видом токена.
///
/// Разбор здесь тот же, что у редактора, — SyntaxModel. Лексятся только
/// строки фрагмента, поэтому стоимость не зависит от размера файла.
/// AppKit не нужен: цвета по виду токена назначает вьюха.
struct FilePreview {

    struct Segment: Equatable {
        var text: String
        var kind: TokenKind
        /// Отрезок попал в диапазон цели — его подсвечиваем.
        var focused: Bool
    }

    struct Line: Identifiable {
        /// Номер строки в файле, с нуля.
        let number: Int
        let segments: [Segment]
        var id: Int { number }
        var text: String { segments.map(\.text).joined() }
    }

    let lines: [Line]
    /// Строка цели — к ней прокручиваем. nil — показываем начало файла.
    let focusLine: Int?
    let lineCount: Int

    /// Сколько строк брать выше и ниже цели. Этого хватает, чтобы увидеть
    /// объявление целиком и было куда прокрутить колесом.
    static let linesBefore = 30
    static let linesAfter = 90
    /// Длиннее строки обрезаем: минифицированный файл в одну строку
    /// на мегабайт иначе лёг бы в палитру целиком.
    static let maxLineLength = 400
    static let tabWidth = 4

    static func make(model: SyntaxModel, range: LSPRange?) -> FilePreview {
        let count = model.lineCount
        guard count > 0 else { return FilePreview(lines: [], focusLine: nil, lineCount: 0) }

        let focus = range.map { max(0, min($0.start.line, count - 1)) }
        let first = focus.map { max(0, $0 - linesBefore) } ?? 0
        let last = min(count - 1, (focus ?? 0) + linesAfter + (focus == nil ? linesBefore : 0))

        // Токены приходят с абсолютными смещениями и никогда не переходят
        // через перевод строки — лексер режет по нему и комментарии, и литералы.
        let tokens = model.tokens(fromLine: first, toLine: last)
        var tokenIndex = 0
        var lines: [Line] = []
        lines.reserveCapacity(last - first + 1)

        for number in first...last {
            var bounds = model.lineRange(number)
            // Перевод строки в текст фрагмента не входит.
            var end = bounds.upperBound
            if end > bounds.lowerBound, model.units[end - 1] == 0x0A { end -= 1 }
            if end > bounds.lowerBound, model.units[end - 1] == 0x0D { end -= 1 }
            let truncated = end - bounds.lowerBound > maxLineLength
            if truncated { end = bounds.lowerBound + maxLineLength }
            bounds = bounds.lowerBound..<end
            let length = bounds.count

            // Вид токена на каждый code unit строки: строки короткие,
            // а так отрезки выходят сами, без разбора пересечений.
            var kinds = [TokenKind](repeating: .plain, count: length)
            while tokenIndex < tokens.count, Int(tokens[tokenIndex].start) < bounds.lowerBound { tokenIndex += 1 }
            var t = tokenIndex
            while t < tokens.count, Int(tokens[t].start) < model.lineRange(number).upperBound {
                let token = tokens[t]
                let from = max(0, Int(token.start) - bounds.lowerBound)
                let to = min(length, Int(token.start + token.length) - bounds.lowerBound)
                if from < to { for k in from..<to { kinds[k] = token.kind } }
                t += 1
            }
            tokenIndex = t

            var focused: Range<Int>? = nil
            if let range, number == focus {
                let from = max(0, min(range.start.character, length))
                let to = range.end.line == range.start.line
                    ? max(from, min(range.end.character, length))
                    : length
                if from < to { focused = from..<to }
            }

            var segments: [Segment] = []
            var runStart = 0
            func flush(_ at: Int) {
                guard at > runStart else { return }
                let units = model.units[(bounds.lowerBound + runStart)..<(bounds.lowerBound + at)]
                var text = String(decoding: units, as: UTF16.self)
                if text.contains("\t") {
                    text = text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth))
                }
                segments.append(Segment(text: text, kind: kinds[runStart],
                                        focused: focused?.contains(runStart) ?? false))
                runStart = at
            }
            if length > 1 {
                for k in 1..<length {
                    let changedKind = kinds[k] != kinds[k - 1]
                    let changedFocus = (focused?.contains(k) ?? false) != (focused?.contains(k - 1) ?? false)
                    if changedKind || changedFocus { flush(k) }
                }
            }
            flush(length)
            if truncated { segments.append(Segment(text: " …", kind: .comment, focused: false)) }

            lines.append(Line(number: number, segments: segments))
        }
        return FilePreview(lines: lines, focusLine: focus, lineCount: count)
    }
}
