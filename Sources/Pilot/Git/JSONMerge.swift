import Foundation

/// Слияние JSON по структуре, с сохранением текста.
///
/// Серверные конфиги — тысячи JSON-файлов с разным форматированием (в
/// одном и том же файле бывают и табуляции, и пробелы), поэтому результат
/// не пересобирается заново — иначе дифф на весь файл. Он строится из
/// нашей версии: меняются только места, куда пришли их правки, и они
/// вставляются их текстом.
///
/// - ключ правила одна сторона — берётся её значение;
/// - ключ добавила или удалила одна сторона — так и будет;
/// - массивы объектов с общим ключом (`id`, `alias`, `path`, `name`…)
///   сливаются по нему, как словари;
/// - спор — только значение, которое обе стороны изменили по-разному;
///   у него путь `top_sell_items.ManBlackReaper.price`.
enum JSONMerge {

    // MARK: - Разбор с позициями

    indirect enum Value: Equatable {
        case object([Member], range: Range<Int>)
        case array([Value], range: Range<Int>)
        case scalar(String, range: Range<Int>)

        var range: Range<Int> {
            switch self {
            case .object(_, let r), .array(_, let r), .scalar(_, let r): return r
            }
        }
    }

    struct Member: Equatable {
        var key: String
        /// От кавычки ключа до конца значения.
        var range: Range<Int>
        var value: Value
    }

    /// Разбор UTF-16 текста; nil — не JSON.
    static func parse(_ text: [UInt16]) -> Value? {
        var parser = Parser(u: text)
        parser.skip()
        guard let value = parser.value() else { return nil }
        parser.skip()
        return parser.i == text.count ? value : nil
    }

    private struct Parser {
        let u: [UInt16]
        var i = 0

        mutating func skip() {
            while i < u.count, u[i] == 0x20 || u[i] == 0x09 || u[i] == 0x0A || u[i] == 0x0D { i += 1 }
        }

        mutating func value() -> Value? {
            guard i < u.count else { return nil }
            let start = i
            switch u[i] {
            case 0x7B: // {
                i += 1
                var members: [Member] = []
                skip()
                if i < u.count, u[i] == 0x7D { i += 1; return .object([], range: start..<i) }
                while true {
                    skip()
                    let keyStart = i
                    guard let key = string() else { return nil }
                    skip()
                    guard i < u.count, u[i] == 0x3A else { return nil }
                    i += 1
                    skip()
                    guard let value = value() else { return nil }
                    members.append(Member(key: key, range: keyStart..<value.range.upperBound, value: value))
                    skip()
                    guard i < u.count else { return nil }
                    if u[i] == 0x2C { i += 1; continue }
                    if u[i] == 0x7D { i += 1; return .object(members, range: start..<i) }
                    return nil
                }
            case 0x5B: // [
                i += 1
                var items: [Value] = []
                skip()
                if i < u.count, u[i] == 0x5D { i += 1; return .array([], range: start..<i) }
                while true {
                    skip()
                    guard let item = value() else { return nil }
                    items.append(item)
                    skip()
                    guard i < u.count else { return nil }
                    if u[i] == 0x2C { i += 1; continue }
                    if u[i] == 0x5D { i += 1; return .array(items, range: start..<i) }
                    return nil
                }
            case 0x22:
                guard string() != nil else { return nil }
                return .scalar(String(decoding: u[start..<i], as: UTF16.self), range: start..<i)
            default:
                while i < u.count, !(u[i] == 0x2C || u[i] == 0x7D || u[i] == 0x5D || u[i] == 0x20
                                     || u[i] == 0x0A || u[i] == 0x0D || u[i] == 0x09) { i += 1 }
                guard i > start else { return nil }
                return .scalar(String(decoding: u[start..<i], as: UTF16.self), range: start..<i)
            }
        }

        /// Строка в кавычках — её содержимое без разбора экранирования
        /// (для ключей этого хватает: сравниваются как написаны).
        mutating func string() -> String? {
            guard i < u.count, u[i] == 0x22 else { return nil }
            i += 1
            let start = i
            while i < u.count, u[i] != 0x22 {
                if u[i] == 0x5C { i += 1 }
                i += 1
            }
            guard i < u.count else { return nil }
            let text = String(decoding: u[start..<i], as: UTF16.self)
            i += 1
            return text
        }
    }

    /// Смысл значения без форматирования и порядка ключей — чтобы
    /// переформатирование не считалось правкой.
    static func canonical(_ value: Value) -> String {
        switch value {
        case .scalar(let text, _): return text
        case .array(let items, _): return "[" + items.map(canonical).joined(separator: ",") + "]"
        case .object(let members, _):
            return "{" + members.sorted { $0.key < $1.key }.map { "\"\($0.key)\":" + canonical($0.value) }
                .joined(separator: ",") + "}"
        }
    }

    // MARK: - Результат

    struct Conflict: Identifiable, Equatable {
        var id: String { path }
        /// `a.b[3].c`, у элемента массива по ключу — `a.b[id=7].c`.
        var path: String
        /// Текст значения с каждой стороны; nil — ключа там нет.
        var base: String?
        var ours: String?
        var theirs: String?
    }

    enum Pick: Equatable { case ours, theirs }

    struct Result: Equatable {
        /// Наш текст, в который вносятся правки.
        var ours: [UInt16]
        var edits: [Edit]
        var conflicts: [Conflict]
        var fromTheirs = 0

        struct Edit: Equatable {
            var range: Range<Int>
            var text: String
            /// Спор: текст зависит от выбора. `text` — на случай «их».
            var conflict: String?
        }

        /// Итоговый текст. Нерешённый спор — наша сторона.
        func text(_ picks: [String: Pick]) -> String {
            var out = ours
            // С конца, чтобы начала ещё не применённых правок не сдвигались.
            // В одной точке — сперва вырезать, потом вставить: иначе
            // вставленное попало бы под вырезание.
            for edit in edits.sorted(by: { ($0.range.lowerBound, $0.range.count) > ($1.range.lowerBound, $1.range.count) }) {
                if let id = edit.conflict, picks[id] != .theirs { continue }
                out.replaceSubrange(edit.range, with: Array(edit.text.utf16))
            }
            return String(decoding: out, as: UTF16.self)
        }
    }

    // MARK: - Слияние

    static func merge(base: String, ours: String, theirs: String) -> Result? {
        let b = Array(base.utf16), o = Array(ours.utf16), t = Array(theirs.utf16)
        guard let ov = parse(o), let tv = parse(t) else { return nil }
        let bv = parse(b)
        var result = Result(ours: o, edits: [], conflicts: [])
        var context = Context(b: b, o: o, t: t)
        context.merge(base: bv, ours: ov, theirs: tv, path: "", into: &result)
        return result
    }

    private struct Context {
        let b: [UInt16], o: [UInt16], t: [UInt16]

        func text(_ source: [UInt16], _ range: Range<Int>) -> String {
            String(decoding: source[range], as: UTF16.self)
        }

        mutating func merge(base: Value?, ours: Value, theirs: Value, path: String, into result: inout Result) {
            let oc = canonical(ours), tc = canonical(theirs), bc = base.map(canonical)
            if oc == tc || tc == bc { return }                       // одинаково или они не трогали
            // Правили только они. Скаляр — их текстом; объект и массив — вглубь,
            // чтобы наше форматирование осталось, а поменялось только нужное.
            let sameShape: Bool = {
                switch (ours, theirs) {
                case (.object, .object), (.array, .array): return true
                default: return false
                }
            }()
            if oc == bc, !sameShape {
                result.edits.append(.init(range: ours.range, text: text(t, theirs.range), conflict: nil))
                result.fromTheirs += 1
                return
            }
            switch (ours, theirs) {
            case (.object(let om, _), .object(let tm, _)):
                var baseMembers: [Member] = []
                if case .object(let bm, _)? = base { baseMembers = bm }
                mergeMembers(base: baseMembers, ours: om, theirs: tm, oursRange: ours.range, path: path, into: &result)
            case (.array(let oi, _), .array(let ti, _)):
                var bi: [Value] = []
                if case .array(let items, _)? = base { bi = items }
                if let key = identityKey([bi, oi, ti]) {
                    let asMembers: ([Value]) -> [Member] = { items in
                        items.map { Member(key: JSONMerge.identity(of: $0, key: key) ?? "", range: $0.range, value: $0) }
                    }
                    mergeMembers(base: asMembers(bi), ours: asMembers(oi), theirs: asMembers(ti), oursRange: ours.range,
                                 path: path, keyed: key, into: &result)
                } else if canonical(ours) == base.map(canonical) {
                    // Мы массив только переформатировали — берём их, целиком.
                    result.edits.append(.init(range: ours.range, text: text(t, theirs.range), conflict: nil))
                    result.fromTheirs += 1
                } else if oi.count == ti.count, bi.count == oi.count {
                    for index in oi.indices {
                        merge(base: bi[index], ours: oi[index], theirs: ti[index], path: path + "[\(index)]", into: &result)
                    }
                } else {
                    conflict(path, base: base, ours: ours, theirs: theirs, into: &result)
                }
            default:
                conflict(path, base: base, ours: ours, theirs: theirs, into: &result)
            }
        }

        mutating func conflict(_ path: String, base: Value?, ours: Value, theirs: Value, into result: inout Result) {
            let id = path.isEmpty ? "$" : path
            result.conflicts.append(Conflict(path: id, base: base.map { text(b, $0.range) },
                                             ours: text(o, ours.range), theirs: text(t, theirs.range)))
            result.edits.append(.init(range: ours.range, text: text(t, theirs.range), conflict: id))
        }

        /// Ключи объекта (или элементы массива по ключу): общие — вглубь,
        /// удалённые ими — вырезаются из нашего текста, добавленные ими —
        /// вставляются в конец.
        mutating func mergeMembers(base: [Member], ours: [Member], theirs: [Member], oursRange: Range<Int>,
                                   path: String, keyed: String? = nil, into result: inout Result) {
            let bm = Dictionary(base.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let tm = Dictionary(theirs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let ourKeys = Set(ours.map(\.key))
            func childPath(_ key: String) -> String {
                if let keyed { return path + "[\(keyed)=\(key)]" }
                return path.isEmpty ? key : path + "." + key
            }
            var removed = Set<Int>()
            for (index, member) in ours.enumerated() {
                if let their = tm[member.key] {
                    merge(base: bm[member.key]?.value, ours: member.value, theirs: their.value,
                          path: childPath(member.key), into: &result)
                } else if let old = bm[member.key] {
                    // Они удалили. Мы не трогали — удаляем; правили — спор.
                    if canonical(old.value) == canonical(member.value) {
                        removed.insert(index)
                        result.fromTheirs += 1
                    } else {
                        let id = childPath(member.key)
                        result.conflicts.append(Conflict(path: id, base: text(b, old.value.range),
                                                         ours: text(o, member.range), theirs: nil))
                        result.edits.append(.init(range: removal(of: index, in: ours, container: oursRange), text: "",
                                                  conflict: id))
                    }
                }
            }
            for range in removals(removed, in: ours) {
                result.edits.append(.init(range: range, text: "", conflict: nil))
            }
            // Добавленное ими: ключа нет ни у нас, ни в базе. Встаёт после
            // того же соседа, что и у них (как при текстовом слиянии), —
            // иначе новые записи реестра уезжали бы в конец.
            let kept = Dictionary(ours.enumerated().filter { !removed.contains($0.offset) }.map { ($0.element.key, $0.offset) },
                                  uniquingKeysWith: { a, _ in a })
            let glue = separator(ours)
            var groups: [(after: Int?, members: [Member])] = []
            var anchor: Int? = nil
            for member in theirs {
                if let index = kept[member.key] { anchor = index; continue }
                guard !ourKeys.contains(member.key), bm[member.key] == nil else { continue }
                if let last = groups.last, last.after == anchor, !last.members.isEmpty,
                   theirs.firstIndex(of: last.members.last!).map({ $0 + 1 }) == theirs.firstIndex(of: member) {
                    groups[groups.count - 1].members.append(member)
                } else {
                    groups.append((anchor, [member]))
                }
            }
            for group in groups {
                let body = group.members.map { text(t, $0.range) }.joined(separator: glue)
                result.fromTheirs += group.members.count
                if let after = group.after {
                    let at = ours[after].range.upperBound
                    result.edits.append(.init(range: at..<at, text: glue + body, conflict: nil))
                } else if let first = ours.indices.first(where: { !removed.contains($0) }) {
                    // Раньше всех наших — перед первым оставшимся.
                    let at = ours[first].range.lowerBound
                    result.edits.append(.init(range: at..<at, text: body + glue, conflict: nil))
                } else {
                    // Наших не осталось: на место последнего (или в пустой объект).
                    let at = insertionPoint(ours: ours, container: oursRange)
                    result.edits.append(.init(range: at..<at, text: body, conflict: nil))
                }
            }
            // Удалённое нами, но правленное ими, — спор (иначе их правка пропала бы молча).
            for their in theirs where !ourKeys.contains(their.key) {
                guard let old = bm[their.key], canonical(old.value) != canonical(their.value) else { continue }
                let id = childPath(their.key)
                let insertion = insertionPoint(ours: ours, container: oursRange)
                result.conflicts.append(Conflict(path: id, base: text(b, old.value.range), ours: nil, theirs: text(t, their.range)))
                result.edits.append(.init(range: insertion..<insertion,
                                          text: (ours.isEmpty ? "" : separator(ours)) + text(t, their.range), conflict: id))
            }
        }

        /// Что вырезать, чтобы убрать удалённые члены: подряд идущие — одним
        /// куском, вместе с запятыми. Серия в конце забирает запятую перед
        /// собой, остальные — после; иначе куски соседних удалений
        /// перекрывались, и запятая оставалась висеть.
        func removals(_ indices: Set<Int>, in members: [Member]) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var index = 0
            while index < members.count {
                guard indices.contains(index) else { index += 1; continue }
                let first = index
                while index + 1 < members.count, indices.contains(index + 1) { index += 1 }
                let last = index
                if last + 1 < members.count {
                    ranges.append(members[first].range.lowerBound..<members[last + 1].range.lowerBound)
                } else if first > 0 {
                    ranges.append(members[first - 1].range.upperBound..<members[last].range.upperBound)
                } else {
                    ranges.append(members[first].range.lowerBound..<members[last].range.upperBound)
                }
                index += 1
            }
            return ranges
        }

        /// Что вырезать, чтобы убрать член `index`: вместе с запятой — той,
        /// что после него, а у последнего — той, что перед ним.
        func removal(of index: Int, in members: [Member], container: Range<Int>) -> Range<Int> {
            let member = members[index]
            if index + 1 < members.count { return member.range.lowerBound..<members[index + 1].range.lowerBound }
            if index > 0 { return members[index - 1].range.upperBound..<member.range.upperBound }
            return member.range
        }

        /// Куда вставлять новые члены: сразу после последнего нашего, а в
        /// пустом — после открывающей скобки.
        func insertionPoint(ours: [Member], container: Range<Int>) -> Int {
            ours.last?.range.upperBound ?? (container.lowerBound + 1)
        }

        /// Чем отделить новый член от предыдущего — тем же, чем разделены
        /// соседи: запятая, перевод строки и отступ (табуляции остаются
        /// табуляциями). У единственного члена — его собственный отступ.
        func separator(_ members: [Member]) -> String {
            if members.count >= 2 {
                return String(decoding: o[members[members.count - 2].range.upperBound..<members[members.count - 1].range.lowerBound],
                              as: UTF16.self)
            }
            guard let only = members.first else { return "" }
            var start = only.range.lowerBound
            while start > 0, o[start - 1] == 0x20 || o[start - 1] == 0x09 { start -= 1 }
            let indent = String(decoding: o[start..<only.range.lowerBound], as: UTF16.self)
            return start > 0 && o[start - 1] == 0x0A ? ",\n" + indent : ","
        }
    }

    // MARK: - Ключ элементов массива

    static let identityKeys = ["id", "alias", "path", "key", "name", "item_id", "itemId", "uid", "guid"]

    /// Ключ, по которому элементы массива различимы: есть у каждого
    /// элемента всех трёх версий и не повторяется внутри версии. nil —
    /// массив сливается по позициям.
    static func identityKey(_ versions: [[Value]]) -> String? {
        let all = versions.flatMap { $0 }
        guard !all.isEmpty, all.allSatisfy({ if case .object = $0 { return true }; return false }) else { return nil }
        for key in identityKeys {
            let unique = versions.allSatisfy { items in
                let values = items.compactMap { identity(of: $0, key: key) }
                return values.count == items.count && Set(values).count == values.count
            }
            if unique { return key }
        }
        return nil
    }

    static func identity(of value: Value, key: String) -> String? {
        guard case .object(let members, _) = value,
              let member = members.first(where: { $0.key == key }),
              case .scalar(let text, _) = member.value else { return nil }
        return text
    }
}
