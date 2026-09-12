import Foundation

/// fzf-подобный матчер. Работает над плоским байтовым буфером, чтобы
/// при наборе запроса не было ни одной аллокации на файл.
///
/// Алгоритм: жадный проход вперёд (найти самое раннее вхождение как
/// подпоследовательности), затем обратный проход, чтобы «стянуть» совпадение
/// вправо и получить минимальное окно, затем подсчёт очков с бонусами.
enum FuzzyMatch {

    // Веса подобраны так, чтобы совпадение в имени файла почти всегда
    // выигрывало у совпадения в пути к нему.
    private static let scoreMatch            = 16
    private static let bonusBoundary         = 18   // после / _ - . пробела
    private static let bonusCamel            = 14   // aB -> B
    private static let bonusConsecutive      = 12
    private static let bonusFirstChar        = 24   // совпал самый первый символ
    private static let bonusInFilename       = 20   // символ лежит в имени файла
    private static let penaltyGapStart       = -6
    private static let penaltyGapExtension   = -2
    private static let penaltyUnmatchedName  = 2    // за каждый непокрытый символ имени

    /// Подготовленный запрос: хранится лениво, переиспользуется на всех файлах.
    struct Query {
        let lower: [UInt8]       // запрос в нижнем регистре
        let hasUpper: Bool       // есть ли заглавные -> включаем smart case
        let raw: [UInt8]

        init(_ s: String) {
            var l = [UInt8](); l.reserveCapacity(s.utf8.count)
            var r = [UInt8](); r.reserveCapacity(s.utf8.count)
            var upper = false
            for b in s.utf8 where b != 0x20 {   // пробелы в запросе игнорируем
                r.append(b)
                if b >= 0x41 && b <= 0x5A { upper = true; l.append(b + 32) }
                else { l.append(b) }
            }
            self.lower = l
            self.raw = r
            self.hasUpper = upper
        }

        var isEmpty: Bool { lower.isEmpty }
    }

    /// Быстрый отсев: является ли запрос подпоследовательностью текста.
    /// Возвращает индекс, на котором закончилось жадное совпадение, или nil.
    @inline(__always)
    static func firstPass(_ q: Query, _ text: UnsafePointer<UInt8>, _ len: Int) -> (start: Int, end: Int)? {
        let p = q.lower
        var pi = 0
        var start = -1
        var i = 0
        while i < len {
            let c = lowerASCII(text[i])
            if c == p[pi] {
                if start < 0 { start = i }
                pi += 1
                if pi == p.count { return (start, i + 1) }
            }
            i += 1
        }
        return nil
    }

    @inline(__always)
    private static func lowerASCII(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 32 : b
    }

    @inline(__always)
    private static func isBoundaryChar(_ b: UInt8) -> Bool {
        b == 0x2F || b == 0x5F || b == 0x2D || b == 0x2E || b == 0x20 || b == 0x5C
    }

    @inline(__always)
    private static func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }

    @inline(__always)
    private static func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }

    /// Полный подсчёт очков. `nameStart` — смещение начала имени файла внутри text.
    /// `positions` (если передан) заполняется индексами совпавших байт для подсветки.
    static func score(_ q: Query,
                      text: UnsafePointer<UInt8>,
                      len: Int,
                      nameStart: Int,
                      positions: inout [Int32]?) -> Int? {

        guard let (gStart, gEnd) = firstPass(q, text, len) else { return nil }

        let p = q.lower
        let pcount = p.count

        // Обратный проход: тянем совпадение вправо, чтобы окно было как можно уже.
        var pi = pcount - 1
        var tightStart = gStart
        var i = gEnd - 1
        while i >= gStart {
            if lowerASCII(text[i]) == p[pi] {
                if pi == 0 { tightStart = i; break }
                pi -= 1
            }
            i -= 1
        }

        // Финальный проход слева направо по окну [tightStart, gEnd) с бонусами.
        var total = 0
        var pIdx = 0
        var prevMatched = false
        var consecutive = 0
        var inGap = false
        var caseMismatchPenalty = 0
        var matchedInName = 0

        if positions != nil { positions!.removeAll(keepingCapacity: true) }

        var idx = tightStart
        while idx < gEnd && pIdx < pcount {
            let ch = text[idx]
            let lc = lowerASCII(ch)
            if lc == p[pIdx] {
                var s = scoreMatch

                // Бонус за границу слова.
                let prev: UInt8 = idx > 0 ? text[idx - 1] : 0x2F
                if isBoundaryChar(prev) {
                    s += bonusBoundary
                } else if isUpper(ch) && isLower(prev) {
                    s += bonusCamel
                }
                if idx == 0 { s += bonusFirstChar }
                if idx >= nameStart { s += bonusInFilename; matchedInName += 1 }
                if idx == nameStart { s += bonusBoundary }

                if prevMatched {
                    consecutive += 1
                    s += bonusConsecutive * min(consecutive, 4)
                } else {
                    consecutive = 0
                }

                // smart case: запрос без заглавных матчит что угодно,
                // запрос с заглавными штрафует несовпадение регистра.
                if q.hasUpper && q.raw[pIdx] != ch { caseMismatchPenalty += 4 }

                total += s
                positions?.append(Int32(idx))
                pIdx += 1
                prevMatched = true
                inGap = false
            } else {
                if prevMatched || inGap {
                    total += inGap ? penaltyGapExtension : penaltyGapStart
                    inGap = true
                }
                prevMatched = false
                consecutive = 0
            }
            idx += 1
        }

        guard pIdx == pcount else { return nil }

        total -= caseMismatchPenalty

        // Насколько запрос покрывает само имя файла. Без этого
        // UserServiceTests.cs и UserService.cs набирают поровну, и побеждает
        // просто более короткий путь — а нужен более точный файл.
        let nameLength = len - nameStart
        total -= (nameLength - matchedInName) * penaltyUnmatchedName

        // Короткие пути предпочтительнее при прочих равных.
        total -= len / 8
        // Плотное совпадение предпочтительнее размазанного.
        total -= (gEnd - tightStart - pcount) / 2

        return total
    }
}
