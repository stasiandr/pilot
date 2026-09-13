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
    func replace(_ range: NSRange, with replacement: [UInt16]) {
        let start = max(0, min(range.location, units.count))
        let oldEnd = max(start, min(NSMaxRange(range), units.count))
        let delta = Int32(replacement.count - (oldEnd - start))
        version += 1

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

        guard let spec, !units.isEmpty else { return }
        let editEndLine = firstLine + inserted.count
        let n = units.count
        var state = LexState(packed: lineStates[firstLine])
        var line = firstLine
        var i = Int(lineStarts[firstLine])
        var sink: [Token]? = nil
        let count = lineStarts.count

        // Тот же цикл, что в build(), только с первой затронутой строки.
        var states = lineStates
        lineStates = []   // чтобы правка states не копировала массив (CoW)
        units.withUnsafeBufferPointer { buf in
            let u = buf.baseAddress!
            while i < n {
                if u[i] == 0x0A {
                    i += 1
                    line += 1
                    guard line < count else { return }
                    let packed = state.packed
                    if line > editEndLine && states[line] == packed { return }
                    states[line] = packed
                    continue
                }
                i = step(u, n, i, &state, spec, sink: &sink)
            }
        }
        lineStates = states
    }

    // MARK: - Проход 2: токены видимых строк

    func tokens(fromLine: Int, toLine: Int) -> [Token] {
        guard let spec, !lineStarts.isEmpty else { return [] }
        let first = max(0, min(fromLine, lineStarts.count - 1))
        let last = max(first, min(toLine, lineStarts.count - 1))

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
                if sspec.escapes && u[i] == 0x5C && i + 1 < n { i += 2; continue }
                if matches(u, n, i, sspec.close) {
                    i += sspec.close.count
                    state.stringIdx = -1
                    break
                }
                i += 1
            }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: .string))
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
                if sspec.escapes && u[i] == 0x5C && i + 1 < n { i += 2; continue }
                if matches(u, n, i, sspec.close) { i += sspec.close.count; closed = true; break }
                i += 1
            }
            if !closed && sspec.multiline { state.stringIdx = Int8(idx) }
            sink?.append(Token(start: Int32(start), length: Int32(i - start), kind: .string))
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

            let word = String(decoding: UnsafeBufferPointer(start: u + start, count: i - start),
                              as: UTF16.self)
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
