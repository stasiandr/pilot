import Foundation

struct Token {
    var start: Int32     // смещение в UTF-16 от начала документа
    var length: Int32
    var kind: TokenKind
}

/// Состояние на границе строки: внутри ли мы блочного комментария
/// (с учётом вложенности) или многострочного литерала.
struct LexState: Equatable {
    var blockDepth: UInt8 = 0
    var stringIdx: Int8 = -1

    var isNormal: Bool { blockDepth == 0 && stringIdx < 0 }

    var packed: UInt16 {
        (UInt16(blockDepth) << 8) | UInt16(UInt8(bitPattern: stringIdx))
    }
    init() {}
    init(packed: UInt16) {
        blockDepth = UInt8(packed >> 8)
        stringIdx = Int8(bitPattern: UInt8(packed & 0xFF))
    }
}

/// Синтаксическая модель документа.
///
/// Устроена в два прохода:
///   1. `build` — один быстрый проход по всему тексту, который запоминает
///      начала строк и состояние лексера на входе в каждую строку.
///      Ключевые слова здесь НЕ распознаются — это самая дорогая часть.
///   2. `tokens(forLineRange:)` — полная токенизация только тех строк,
///      которые реально видны на экране.
///
/// Благодаря этому открытие файла на 500 000 строк не зависит от его размера
/// в части подсветки: красится ровно один экран.
///
/// Правки (`replace`) применяются инкрементально и только на главном потоке.
/// Фоновой работе с моделью открытого документа нужен `snapshot()`.
final class SyntaxModel: @unchecked Sendable {
    private(set) var units: [UInt16]
    private(set) var lineStarts: [Int32] = []   // смещение начала каждой строки
    private(set) var lineStates: [UInt16] = []  // состояние лексера на входе в строку
    let spec: LanguageSpec?
    /// Растёт с каждой правкой: фоновый результат по старой версии — выбрасываем.
    private(set) var version = 0

    /// Файл, из которого модель построена, если он на диске и это C#.
    ///
    /// По нему подсветку спрашивают у Rustlyn: настоящий лексер C# знает
    /// raw-строки, вложенную интерполяцию и мёртвые ветки `#if`, к которым
    /// свой лексер только приближается.
    ///
    /// Сбрасывается первой же правкой и ставится заново, когда файл устоится
    /// (сохранение, переоткрытие): по нему решают, отдавать ли Rustlyn текст
    /// в вопросе и верить ли его структуре файла. Раскраска Rustlyn правкой
    /// не сбрасывается — она переносится через правки (`colorTokens`).
    private(set) var settledFile: URL?

    /// Раскраска Rustlyn и текст, по которому она посчитана; nil — красит
    /// свой лексер.
    private var colors: ColorBase?

    /// Последние правки — для `edits(since:)`.
    private var journal: [(version: Int, range: Range<Int>, length: Int)] = []
    private static let journalLimit = 256

    /// Считать подсветку этого файла по Rustlyn: `session` только что его
    /// прочитала, и текст модели — ровно тот, что у неё.
    func useRustlyn(for url: URL, session: Rustlyn) {
        guard Rustlyn.understands(url) else {
            settledFile = nil
            return
        }
        useColors(settled: url) { [weak session] lines in session?.tokens(url, lines: lines) }
    }

    /// Раскраска по разбору нынешнего текста: `classify` отдаёт токены его
    /// строк. С этой минуты правки её переносят, а не сбрасывают. `settled` —
    /// файл, который совпадает с текстом (у Rustlyn это файл на диске).
    func useColors(settled url: URL? = nil, _ classify: @escaping @Sendable (ClosedRange<Int>) -> [Token]?) {
        if let url { settledFile = url }
        // Токены приходят по номерам строк: режь Rustlyn строки иначе, чем мы,
        // он раскрасил бы не те строки. Такой файл красит свой лексер.
        colors = Self.linesMatchCSharp(units)
            ? ColorBase(classify: classify, lineStarts: lineStarts, lineStates: lineStates) : nil
    }

    /// Строки текста режутся только по `\n` — так, как режем их мы. C# рвёт
    /// строку ещё на одиноком `\r` и на U+0085, U+2028, U+2029, и Rustlyn
    /// считает строки так же. Токены он отдаёт по номерам строк: в файле с
    /// такими разрывами он раскрасил бы не те строки, а видимые остались бы
    /// без цвета. Такой файл красит свой лексер.
    static func linesMatchCSharp(_ units: [UInt16]) -> Bool {
        var i = 0
        let n = units.count
        while i < n {
            switch units[i] {
            case 0x0D:
                if i + 1 == n || units[i + 1] != 0x0A { return false }
                i += 2
            case 0x85, 0x2028, 0x2029:
                return false
            default:
                i += 1
            }
        }
        return true
    }

    /// Раскраска Rustlyn отстаёт от текста: его правили с тех пор, как
    /// Rustlyn его разобрал, и правленое красит свой лексер.
    var colorsLag: Bool { colors.map { !$0.edits.isEmpty } ?? false }

    var lineCount: Int { lineStarts.count }

    init(text: String, spec: LanguageSpec?) {
        self.units = Array(text.utf16)
        self.spec = spec
        build()
    }

    private init(copying other: SyntaxModel) {
        units = other.units
        lineStarts = other.lineStarts
        lineStates = other.lineStates
        spec = other.spec
        version = other.version
        settledFile = other.settledFile
        colors = other.colors
    }

    /// Неизменяемая копия для фоновой работы. Массивы копируются лениво
    /// (copy-on-write), так что снимок стоит O(1), пока модель не правят.
    func snapshot() -> SyntaxModel { SyntaxModel(copying: self) }

    var text: String { String(decoding: units, as: UTF16.self) }

    func lineRange(_ line: Int) -> Range<Int> {
        let start = Int(lineStarts[line])
        let end = line + 1 < lineStarts.count ? Int(lineStarts[line + 1]) : units.count
        return start..<end
    }

    /// Номер строки, содержащей смещение (двоичный поиск).
    func line(containing offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Int(lineStarts[mid]) <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: - Проход 1: границы строк + состояния

    private func build() {
        let n = units.count
        lineStarts.reserveCapacity(n / 32 + 1)
        lineStates.reserveCapacity(n / 32 + 1)

        lineStarts.append(0)

        guard let spec else {
            // Языка нет — только режем на строки.
            var i = 0
            while i < n {
                if units[i] == 0x0A { lineStarts.append(Int32(i + 1)) }
                i += 1
            }
            lineStates = [UInt16](repeating: 0, count: lineStarts.count)
            return
        }

        lineStates.append(LexState().packed)
        var state = LexState()
        var i = 0

        var sink: [Token]? = nil   // nil = токены не нужны, только состояния
        units.withUnsafeBufferPointer { buf in
            let u = buf.baseAddress!
            while i < n {
                if u[i] == 0x0A {
                    i += 1
                    lineStarts.append(Int32(i))
                    lineStates.append(state.packed)
                    continue
                }
                i = step(u, n, i, &state, spec, sink: &sink)
            }
        }
    }

    // MARK: - Правка

    /// Заменяет `range` (в координатах текста до правки) на `replacement`.
    ///
    /// Начала строк сдвигаются арифметикой, а лексер перезапускается только
    /// с первой затронутой строки — и останавливается, как только состояние
    /// на входе в очередную строку за правкой совпало с прежним: дальше всё
    /// разобрано так же, как было. Открытый `/*` честно переразберёт файл
    /// до конца, обычный набор — одну строку.
    ///
    /// Возвращает смещение (в тексте после правки), с которого токены те же,
    /// что были, — только сдвинулись: перекрашивать нужно лишь то, что до него.
    @discardableResult
    func replace(_ range: NSRange, with replacement: [UInt16]) -> Int {
        let start = max(0, min(range.location, units.count))
        let oldEnd = max(start, min(NSMaxRange(range), units.count))
        let delta = Int32(replacement.count - (oldEnd - start))
        version += 1
        // Текст разошёлся с файлом на диске, а Rustlyn знает файл: спрашивать
        // его теперь — с текстом в вопросе, пока сохранение не поставит
        // `settledFile` обратно. Его раскраска остаётся — через карту правок.
        settledFile = nil
        note(start..<oldEnd, replacement)

        let firstLine = line(containing: start)
        let lastLine = line(containing: oldEnd)

        units.replaceSubrange(start..<oldEnd, with: replacement)

        var inserted: [Int32] = []
        for (k, u) in replacement.enumerated() where u == 0x0A {
            inserted.append(Int32(start + k + 1))
        }
        // Строки, начинавшиеся внутри заменённого куска, исчезли вместе с его
        // переводами строк; на их место встают строки из вставки.
        let removed = (firstLine + 1)..<(lastLine + 1)
        lineStarts.replaceSubrange(removed, with: inserted)
        lineStates.replaceSubrange(removed, with: repeatElement(UInt16(0), count: inserted.count))
        if delta != 0 {
            for i in (firstLine + 1 + inserted.count)..<lineStarts.count { lineStarts[i] += delta }
        }

        let editEndLine = firstLine + inserted.count
        guard let spec, !units.isEmpty else {
            return editEndLine + 1 < lineStarts.count ? Int(lineStarts[editEndLine + 1]) : units.count
        }
        let n = units.count
        var state = LexState(packed: lineStates[firstLine])
        var line = firstLine
        var i = Int(lineStarts[firstLine])
        var sink: [Token]? = nil
        let count = lineStarts.count

        // Тот же цикл, что в build(), только с первой затронутой строки.
        var states = lineStates
        lineStates = []   // чтобы правка states не копировала массив (CoW)
        var settled = n
        units.withUnsafeBufferPointer { buf in
            let u = buf.baseAddress!
            while i < n {
                if u[i] == 0x0A {
                    i += 1
                    line += 1
                    guard line < count else { return }
                    let packed = state.packed
                    if line > editEndLine && states[line] == packed { settled = i; return }
                    states[line] = packed
                    continue
                }
                i = step(u, n, i, &state, spec, sink: &sink)
            }
        }
        lineStates = states
        return settled
    }

    /// Правка — в журнал и в карту раскраски, ещё по прежнему тексту. Общие
    /// начало и конец заменённого и вставленного не в счёт: форматирование
    /// заменяет пробелы вокруг слов вместе со словами, а слова те же.
    private func note(_ range: Range<Int>, _ replacement: [UInt16]) {
        var head = 0
        while head < range.count, head < replacement.count,
              units[range.lowerBound + head] == replacement[head] { head += 1 }
        var tail = 0
        while tail < range.count - head, tail < replacement.count - head,
              units[range.upperBound - 1 - tail] == replacement[replacement.count - 1 - tail] { tail += 1 }
        let changed = (range.lowerBound + head)..<(range.upperBound - tail)
        let length = replacement.count - head - tail
        colors?.edits.record(changed, length: length)
        journal.append((version, changed, length))
        if journal.count > 2 * Self.journalLimit { journal.removeFirst(journal.count - Self.journalLimit) }
    }

    /// Правки после версии `version` — чтобы перенести в нынешний текст то,
    /// что посчитано по ней: структура файла догоняет набор с задержкой.
    /// nil — так давно, что журнал уже не помнит.
    func edits(since version: Int) -> EditMap? {
        guard version >= 0, version <= self.version else { return nil }
        var map = EditMap()
        guard version < self.version else { return map }
        guard let oldest = journal.first, oldest.version <= version + 1 else { return nil }
        for entry in journal where entry.version > version {
            map.record(entry.range, length: entry.length)
        }
        return map
    }

    // MARK: - Проход 2: токены видимых строк

    func tokens(fromLine: Int, toLine: Int) -> [Token] {
        guard spec != nil, !lineStarts.isEmpty else { return [] }
        let first = max(0, min(fromLine, lineStarts.count - 1))
        let last = max(first, min(toLine, lineStarts.count - 1))

        // Устоявшийся C# красит Rustlyn. Промах — не беда и не редкость:
        // сессии может не быть вовсе, файл мог не открыться на той стороне,
        // — и тогда работает свой лексер, как работал всегда. Поэтому
        // ошибку здесь не показывают: подсветка не та причина, по которой
        // стоит что-то говорить пользователю.
        if settledFile != nil, let tokens = colors?.classify(first...last) {
            return tokens
        }
        return lexerTokens(first, last)
    }

    /// Токены для раскраски строк `fromLine...toLine` в редакторе.
    ///
    /// Файл, который красит Rustlyn, красится им и после правок: токены по
    /// тексту, который Rustlyn знает, переносятся через правки (`EditMap`), а
    /// свой лексер красит только задетое правкой (`CarriedColors`): набранное
    /// слово, разрезанную строку, строки за открытым `/*`. Пробел между
    /// словами не задевает ничего — и цвета вокруг не меняются, сколько бы
    /// раз экран ни перекрашивали до свежего разбора. Прежде первая же правка
    /// отдавала весь файл своему лексеру, у которого свои цвета (`Foo(` у
    /// него функция, у Rustlyn — тип), и экран перекрашивался целиком.
    ///
    /// Только с главного потока: помнит последний ответ Rustlyn.
    func colorTokens(fromLine: Int, toLine: Int) -> [Token] {
        guard var base = colors, spec != nil, !lineStarts.isEmpty else {
            return tokens(fromLine: fromLine, toLine: toLine)
        }
        let first = max(0, min(fromLine, lineStarts.count - 1))
        let last = max(first, min(toLine, lineStarts.count - 1))
        let window = Int(lineStarts[first])..<lineRange(last).upperBound
        // Только окно: комментарий, начатый выше, за его краем мог стать
        // другим, а там его перекрасит своё окно.
        func clipped(_ tokens: [Token]) -> [Token] {
            tokens.compactMap { token in
                let lower = max(Int(token.start), window.lowerBound)
                let upper = min(Int(token.start) + Int(token.length), window.upperBound)
                return lower < upper ? Token(start: Int32(lower), length: Int32(upper - lower), kind: token.kind) : nil
            }
        }
        // Задетое правкой решается целиком, сколько бы строк оно ни заняло:
        // окно, которое видит полмёртвой ветки, решило бы иначе, чем окно,
        // которое видит её всю, — и цвет зависел бы от того, что перекрасили.
        var span = window
        var kept: [Token] = [], cut: [Token] = []
        while true {
            guard let carried = base.tokens(covering: base.edits.oldRange(covering: span)) else {
                return lexerTokens(first, last)
            }
            colors = base
            guard !base.edits.isEmpty else { return clipped(carried) }
            (kept, cut) = base.edits.carry(carried)
            var lower = span.lowerBound, upper = span.upperBound
            for token in cut where Int(token.start) < span.upperBound && span.lowerBound < Int(token.start + token.length) {
                lower = min(lower, Int(token.start))
                upper = max(upper, Int(token.start) + Int(token.length))
            }
            lower = Int(lineStarts[line(containing: max(0, lower))])
            upper = lineRange(line(containing: max(lower, min(upper, units.count) - 1))).upperBound
            guard lower < span.lowerBound || upper > span.upperBound else { break }
            span = min(lower, span.lowerBound)..<max(upper, span.upperBound)
        }

        let changes = base.edits.newRanges(near: span)
        // Строки, куда лексер теперь входит не в том состоянии, что в тексте
        // Rustlyn: выше открыли или закрыли комментарий, строку.
        var stale: [Range<Int>] = []
        for line in first...last {
            let start = Int(lineStarts[line])
            let state = lineStates[line]
            let same: Bool
            if let old = base.edits.oldLineStart(start), let baseLine = base.line(startingAt: old) {
                same = base.lineStates[baseLine] == state
            } else {
                // Строка начинается в правленом — сравнить не с чем.
                same = LexState(packed: state).isNormal
            }
            if !same { stale.append(lineRange(line)) }
        }
        guard !cut.isEmpty || !changes.isEmpty || !stale.isEmpty else { return clipped(kept) }
        let lexed = lexerTokens(line(containing: span.lowerBound), line(containing: max(span.lowerBound, span.upperBound - 1)))
        return clipped(CarriedColors.merge(kept: kept, cut: cut, changes: changes, stale: stale,
                                           lexed: lexed, units: units, window: span))
    }

    /// Свой лексер по строкам `first...last`.
    private func lexerTokens(_ first: Int, _ last: Int) -> [Token] {
        guard let spec else { return [] }
        var state = LexState(packed: lineStates[first])
        let start = Int(lineStarts[first])
        let end = last + 1 < lineStarts.count ? Int(lineStarts[last + 1]) : units.count

        var sink: [Token]? = []
        sink?.reserveCapacity((end - start) / 6 + 16)

        units.withUnsafeBufferPointer { buf in
            let u = buf.baseAddress!
            var i = start
            while i < end {
                if u[i] == 0x0A { i += 1; continue }
                i = step(u, end, i, &state, spec, sink: &sink)
            }
        }
        return sink ?? []
    }

    // MARK: - Ядро лексера

    /// Обрабатывает одну лексему начиная с `i`, обновляет состояние и
    /// (опционально) складывает токен в `sink`. Возвращает новую позицию.
    /// Одна и та же функция используется обоими проходами — разница лишь
    /// в том, равен ли `sink` nil.
    private func step(_ u: UnsafePointer<UInt16>,
                      _ n: Int,
                      _ i0: Int,
                      _ state: inout LexState,
                      _ spec: LanguageSpec,
                      sink: inout [Token]?) -> Int {
        var i = i0

        // --- внутри блочного комментария ---
        if state.blockDepth > 0, let bc = spec.blockComment {
            let start = i
            while i < n {
                if u[i] == 0x0A { break }
                if spec.nestedBlockComments && matches(u, n, i, bc.open) {
                    state.blockDepth &+= 1
                    i += bc.open.count
                    continue
                }
                if matches(u, n, i, bc.close) {
                    state.blockDepth &-= 1
                    i += bc.close.count
                    if state.blockDepth == 0 { break }
                    continue
                }
                i += 1
            }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: .comment))
            return i
        }

        // --- внутри многострочного литерала ---
        if state.stringIdx >= 0 {
            let sspec = spec.strings[Int(state.stringIdx)]
            let start = i
            while i < n {
                if u[i] == 0x0A {
                    if !sspec.multiline { state.stringIdx = -1 }
                    break
                }
                // `\` перед переводом строки его не съедает: иначе строка не
                // кончится, где кончается строка текста, и за ней собьются
                // начала и состояния всех строк ниже.
                if sspec.escapes && u[i] == 0x5C && i + 1 < n && u[i + 1] != 0x0A { i += 2; continue }
                if matches(u, n, i, sspec.close) {
                    i += sspec.close.count
                    state.stringIdx = -1
                    break
                }
                i += 1
            }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: sspec.kind))
            return i
        }

        let c = u[i]

        // --- пробелы ---
        if c == 0x20 || c == 0x09 || c == 0x0D { return i + 1 }

        // --- комментарии до конца строки ---
        for pat in spec.docLineComments where matches(u, n, i, pat) {
            let start = i
            while i < n && u[i] != 0x0A { i += 1 }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: .docComment))
            return i
        }
        for pat in spec.lineComments where matches(u, n, i, pat) {
            let start = i
            while i < n && u[i] != 0x0A { i += 1 }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: .comment))
            return i
        }

        // --- открытие блочного комментария ---
        if let bc = spec.blockComment, matches(u, n, i, bc.open) {
            state.blockDepth = 1
            let start = i
            i += bc.open.count
            while i < n {
                if u[i] == 0x0A { break }
                if spec.nestedBlockComments && matches(u, n, i, bc.open) {
                    state.blockDepth &+= 1; i += bc.open.count; continue
                }
                if matches(u, n, i, bc.close) {
                    state.blockDepth &-= 1
                    i += bc.close.count
                    if state.blockDepth == 0 { break }
                    continue
                }
                i += 1
            }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: .comment))
            return i
        }

        // --- строковые литералы (порядок в spec важен: длинные открывашки первыми) ---
        for (idx, sspec) in spec.strings.enumerated() where matches(u, n, i, sspec.open) {
            let start = i
            i += sspec.open.count
            var closed = false
            while i < n {
                if u[i] == 0x0A { break }
                if sspec.escapes && u[i] == 0x5C && i + 1 < n && u[i + 1] != 0x0A { i += 2; continue }
                if matches(u, n, i, sspec.close) { i += sspec.close.count; closed = true; break }
                i += 1
            }
            if !closed && sspec.multiline { state.stringIdx = Int8(idx) }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: sspec.kind))
            return i
        }

        // --- числа ---
        if isDigit(c) {
            let start = i
            while i < n && (isDigit(u[i]) || isAlpha(u[i]) || u[i] == 0x5F
                            || (u[i] == 0x2E && i + 1 < n && isDigit(u[i + 1]))) { i += 1 }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: .number))
            return i
        }

        // --- препроцессор / атрибуты ---
        if let pp = spec.preprocessorPrefix, c == UInt16(pp) {
            let start = i
            i += 1
            while i < n && (isAlpha(u[i]) || isDigit(u[i]) || u[i] == 0x5F) { i += 1 }
            if i > start + 1 {
                sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: .preprocessor))
                return i
            }
            sink?.append(Token(start: Int32(start), length: 1, kind: .punctuation))
            return start + 1
        }
        if let ap = spec.attributePrefix, c == UInt16(ap) {
            let start = i
            i += 1
            // Сдвоенный префикс — одно имя: `@@version` в SQL, `!!str` в YAML.
            while i < n && u[i] == c { i += 1 }
            while i < n && (isAlpha(u[i]) || isDigit(u[i]) || u[i] == 0x5F) { i += 1 }
            if i > start + 1 {
                sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: .attribute))
                return i
            }
            sink?.append(Token(start: Int32(start), length: 1, kind: .punctuation))
            return start + 1
        }

        // --- идентификаторы и ключевые слова ---
        if isIdentStart(c) {
            let start = i
            while i < n && isIdentPart(u[i]) { i += 1 }

            guard sink != nil else { return i }   // проход 1: не тратим время на строки

            var word = String(decoding: UnsafeBufferPointer(start: u + start, count: i - start),
                              as: UTF16.self)
            if spec.caseInsensitiveKeywords { word = word.lowercased() }
            var kind: TokenKind = .plain
            if spec.keywords.contains(word) { kind = .keyword }
            else if spec.constants.contains(word) { kind = .constant }
            else if spec.typeKeywords.contains(word) { kind = .type }
            else {
                // идентификатор перед '(' — вызов функции
                var j = i
                while j < n && (u[j] == 0x20 || u[j] == 0x09) { j += 1 }
                if j < n && u[j] == 0x28 { kind = .function }
                // `ключ: значение` в YAML — ключ красится как имя, а не как тип.
                // Двоеточие вплотную и за ним пробел или конец строки:
                // `http://` ключом не считается.
                else if spec.keysBeforeColon && i < n && u[i] == 0x3A
                            && (i + 1 == n || u[i + 1] == 0x20 || u[i + 1] == 0x0A || u[i + 1] == 0x0D) {
                    kind = .function
                }
                else if spec.capitalizedIsType && c >= 0x41 && c <= 0x5A { kind = .type }
            }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: kind))
            return i
        }

        // --- всё остальное: пунктуация и операторы ---
        sink?.append(Token(start: Int32(i), length: 1, kind: isPunct(c) ? .punctuation : .operatorTok))
        return i + 1
    }

    // MARK: - Предикаты

    @inline(__always)
    private func matches(_ u: UnsafePointer<UInt16>, _ n: Int, _ i: Int, _ pat: [UInt8]) -> Bool {
        if pat.isEmpty || i + pat.count > n { return false }
        for k in 0..<pat.count where u[i + k] != UInt16(pat[k]) { return false }
        return true
    }

    @inline(__always) private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) private func isAlpha(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }
    @inline(__always) private func isIdentStart(_ c: UInt16) -> Bool {
        isAlpha(c) || c == 0x5F || c == 0x24 || c > 0x7F
    }
    @inline(__always) private func isIdentPart(_ c: UInt16) -> Bool {
        isIdentStart(c) || isDigit(c)
    }
    @inline(__always) private func isPunct(_ c: UInt16) -> Bool {
        c == 0x28 || c == 0x29 || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D
        || c == 0x2C || c == 0x3B || c == 0x2E || c == 0x3A
    }
}

/// Раскраска Rustlyn и текст, по которому она посчитана, — основа.
private struct ColorBase {
    /// Токены строк основы; nil — не вышло (сессии нет, файл закрыт).
    let classify: @Sendable (ClosedRange<Int>) -> [Token]?
    /// Начала строк основы и состояния своего лексера на входе в них.
    let lineStarts: [Int32]
    let lineStates: [UInt16]
    /// Правки с тех пор.
    var edits = EditMap()
    /// Последний ответ Rustlyn: строки основы и их токены. Основа не
    /// меняется, поэтому и ответ про неё не стареет.
    private var cache: (lines: ClosedRange<Int>, tokens: [Token])?

    init(classify: @escaping @Sendable (ClosedRange<Int>) -> [Token]?, lineStarts: [Int32], lineStates: [UInt16]) {
        self.classify = classify
        self.lineStarts = lineStarts
        self.lineStates = lineStates
    }

    /// Строк сверх окна, которые берутся у Rustlyn про запас: прокрутка и
    /// перевод строки сдвигают окно понемногу, и спрашивать заново незачем.
    private static let slack = 64

    /// Токены основы, задевающие участок `range` её текста, — и строку по
    /// краям: правка на границе окна смотрит, к чему она примыкает.
    mutating func tokens(covering range: Range<Int>) -> [Token]? {
        guard !lineStarts.isEmpty else { return [] }
        let first = max(0, line(containing: range.lowerBound) - 1)
        let last = min(lineStarts.count - 1, line(containing: max(range.lowerBound, range.upperBound - 1)) + 1)
        if cache.map({ !$0.lines.contains(first) || !$0.lines.contains(last) }) ?? true {
            let lines = max(0, first - Self.slack)...min(lineStarts.count - 1, last + Self.slack)
            guard let fresh = classify(lines) else { return nil }
            cache = (lines, fresh)
        }
        let lower = Int(lineStarts[first])
        let upper = last + 1 < lineStarts.count ? Int(lineStarts[last + 1]) : Int.max
        return cache?.tokens.filter { Int($0.start) < upper && lower < Int($0.start) + Int($0.length) } ?? []
    }

    func line(containing offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Int(lineStarts[mid]) <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Строка основы, которая начинается ровно в `offset`.
    func line(startingAt offset: Int) -> Int? {
        let line = line(containing: offset)
        return Int(lineStarts[line]) == offset ? line : nil
    }
}
