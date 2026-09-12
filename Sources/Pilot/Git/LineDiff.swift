import Foundation

/// Какие строки открытого файла изменены относительно HEAD — для полосок
/// в колонке номеров.
///
/// Сравниваем сами, а не зовём `git diff`: git сравнивает с файлом на диске,
/// а на экране — снимок, прочитанный при открытии. Поменяли файл в другом
/// редакторе — и полоски `git diff` разъехались бы с текстом. Здесь обе
/// стороны — ровно то, что показано, и то, что лежит в HEAD.
enum LineDiff {

    enum Kind: Equatable {
        case added, modified, deleted
    }

    /// Изменение в координатах нового текста: номера строк с нуля, как в
    /// SyntaxModel. У `.deleted` диапазон пустой — строки удалены перед
    /// `lines.lowerBound`.
    struct Change: Equatable {
        var kind: Kind
        var lines: Range<Int>
    }

    /// Предел числа правок для Myers: дальше время O((N+M)·D) и память O(D²)
    /// перестают быть копеечными. Всё, что сверх, помечается одним блоком —
    /// файл, переписанный целиком, и выглядит как переписанный целиком.
    static let maxEdits = 2000

    static func changes(old: String, new: String, maxEdits: Int = maxEdits) -> [Change] {
        changes(old: lines(old), new: lines(new), maxEdits: maxEdits)
    }

    /// Строки режем по `\n` — ровно как SyntaxModel, иначе номера разъедутся.
    /// Хвостовой `\r` отбрасываем: файл с CRLF на диске и LF в репозитории
    /// (core.autocrlf) не должен целиком гореть изменённым.
    static func lines(_ text: String) -> [ArraySlice<UInt8>] {
        let bytes = Array(text.utf8)
        var result: [ArraySlice<UInt8>] = []
        result.reserveCapacity(bytes.count / 32 + 1)
        var start = 0
        for i in 0..<bytes.count where bytes[i] == 0x0A {
            result.append(trimmingCR(bytes[start..<i]))
            start = i + 1
        }
        result.append(trimmingCR(bytes[start..<bytes.count]))
        return result
    }

    private static func trimmingCR(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        line.last == 0x0D ? line.dropLast() : line
    }

    static func changes(old a: [ArraySlice<UInt8>], new b: [ArraySlice<UInt8>],
                        maxEdits: Int) -> [Change] {
        // Общие начало и конец отрезаем сразу: обычно правка — пара мест
        // в большом файле, и до Myers доходят считанные строки.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let n = a.count - prefix - suffix
        let m = b.count - prefix - suffix
        if n == 0 && m == 0 { return [] }

        // Строки -> числа: дальше Myers сравнивает Int32, а не байты.
        var ids: [ArraySlice<UInt8>: Int32] = [:]
        func intern(_ line: ArraySlice<UInt8>) -> Int32 {
            if let id = ids[line] { return id }
            let id = Int32(ids.count)
            ids[line] = id
            return id
        }
        let x = a[prefix..<(prefix + n)].map(intern)
        let y = b[prefix..<(prefix + m)].map(intern)

        var deleted = [Bool](repeating: false, count: n)
        var inserted = [Bool](repeating: false, count: m)
        if !myers(x, y, limit: maxEdits, deleted: &deleted, inserted: &inserted) {
            deleted = [Bool](repeating: true, count: n)
            inserted = [Bool](repeating: true, count: m)
        }
        return hunks(deleted: deleted, inserted: inserted, offset: prefix)
    }

    // MARK: - Myers

    /// Жадный алгоритм Майерса (1986): кратчайший путь по сетке правок,
    /// где шаг вправо — удаление строки старого текста, шаг вниз — вставка
    /// строки нового, диагональ — совпадение. Отмечает удалённые и
    /// вставленные строки. false — правок больше `limit`.
    private static func myers(_ a: [Int32], _ b: [Int32], limit: Int,
                              deleted: inout [Bool], inserted: inout [Bool]) -> Bool {
        let n = a.count, m = b.count
        let maxD = min(n + m, limit)
        let offset = maxD + 1
        // v[k] — самый дальний x на диагонали k = x - y; -1 — недостижима.
        var v = [Int](repeating: -1, count: 2 * maxD + 3)
        // После каждого шага d запоминаем v[-d...d]: по ним идёт обратный ход.
        var trace: [[Int32]] = []
        var total = -1

        search: for d in 0...maxD {
            for k in stride(from: -d, through: d, by: 2) where k >= -m && k <= n {
                var x: Int
                if d == 0 {
                    x = 0
                } else if let move = step(k: k, d: d, n: n, m: m, at: { v[offset + $0] }) {
                    x = move.x
                } else {
                    v[offset + k] = -1
                    continue
                }
                var y = x - k
                while x < n && y < m && a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x == n && y == m { total = d; break search }
            }
            trace.append(v[(offset - d)...(offset + d)].map { Int32($0) })
        }
        guard total >= 0 else { return false }

        // Обратный ход: от (n, m) к (0, 0), повторяя тот же выбор хода.
        var x = n, y = m
        for d in stride(from: total, to: 0, by: -1) {
            let k = x - y
            let previous = trace[d - 1]
            guard let move = step(k: k, d: d, n: n, m: m,
                                  at: { Int(previous[$0 + d - 1]) }) else { return false }
            if move.down {
                inserted[move.x - k - 1] = true
                x = move.x
                y = move.x - k - 1
            } else {
                deleted[move.x - 1] = true
                x = move.x - 1
                y = move.x - k
            }
        }
        return true
    }

    /// Каким ходом на шаге d попасть на диагональ k: вниз с k+1 или вправо
    /// с k-1 — берём тот, что дальше. Ходы за пределы сетки отбрасываются:
    /// без этого «самая дальняя» точка могла бы оказаться за краем текста.
    /// `at(k)` — v[k] после шага d-1. Возвращает x сразу после хода.
    @inline(__always)
    private static func step(k: Int, d: Int, n: Int, m: Int,
                             at: (Int) -> Int) -> (x: Int, down: Bool)? {
        var best: (x: Int, down: Bool)?
        if k != d, k + 1 <= n {
            let px = at(k + 1)
            if px >= 0, px - k <= m { best = (px, true) }
        }
        if k != -d, k - 1 >= -m {
            let px = at(k - 1)
            if px >= 0, px + 1 <= n, px + 1 > (best?.x ?? -1) { best = (px + 1, false) }
        }
        return best
    }

    // MARK: - Сборка блоков

    /// Между двумя совпавшими строками удалённые и вставленные идут сплошными
    /// кусками; каждый такой промежуток — один блок в колонке.
    private static func hunks(deleted: [Bool], inserted: [Bool], offset: Int) -> [Change] {
        var result: [Change] = []
        let n = deleted.count, m = inserted.count
        var i = 0, j = 0
        while i < n || j < m {
            let isDeleted = i < n && deleted[i]
            let isInserted = j < m && inserted[j]
            if !isDeleted && !isInserted { i += 1; j += 1; continue }

            let i0 = i, j0 = j
            while i < n && deleted[i] { i += 1 }
            while j < m && inserted[j] { j += 1 }

            let lines = (offset + j0)..<(offset + j)
            let kind: Kind = lines.isEmpty ? .deleted : (i == i0 ? .added : .modified)
            result.append(Change(kind: kind, lines: lines))
        }
        return result
    }
}
