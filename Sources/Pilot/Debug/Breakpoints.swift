import Foundation

/// Точки останова проекта: файл → строки с нуля. Живут между запусками
/// Pilot и между сессиями отладки — как в Rider и Xcode.
struct BreakpointSet: Equatable {
    private(set) var lines: [URL: Set<Int>] = [:]
    /// Условия — только у тех точек, где они есть: строка → выражение C#.
    private(set) var conditions: [URL: [Int: String]] = [:]

    init(lines: [URL: Set<Int>] = [:], conditions: [URL: [Int: String]] = [:]) {
        self.lines = lines.filter { !$0.value.isEmpty }
        for (file, map) in conditions {
            let kept = map.filter { self.lines[file]?.contains($0.key) == true }
            if !kept.isEmpty { self.conditions[file] = kept }
        }
    }

    var isEmpty: Bool { lines.isEmpty }
    var count: Int { lines.values.reduce(0) { $0 + $1.count } }

    func lines(in file: URL) -> Set<Int> { lines[file.standardizedFileURL] ?? [] }

    func condition(in file: URL, line: Int) -> String? { conditions[file.standardizedFileURL]?[line] }

    /// Что отдать отладчику по файлу.
    func specs(in file: URL) -> [BreakpointSpec] {
        let key = file.standardizedFileURL
        return lines(in: key).sorted().map { BreakpointSpec(line: $0, condition: conditions[key]?[$0]) }
    }

    /// Условие точки; пустое — снять. Точки на строке нет — она ставится:
    /// условие без точки ничего не значит.
    mutating func setCondition(_ file: URL, line: Int, _ condition: String?) {
        let key = file.standardizedFileURL
        let text = condition?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty, !lines(in: key).contains(line) { lines[key, default: []].insert(line) }
        var map = conditions[key] ?? [:]
        map[line] = text.isEmpty ? nil : text
        conditions[key] = map.isEmpty ? nil : map
    }

    /// Поставить или снять. Возвращает, стоит ли точка теперь.
    @discardableResult
    mutating func toggle(_ file: URL, line: Int) -> Bool {
        let key = file.standardizedFileURL
        var set = lines[key] ?? []
        let added = set.insert(line).inserted
        if !added {
            set.remove(line)
            setCondition(key, line: line, nil)
        }
        lines[key] = set.isEmpty ? nil : set
        return added
    }

    /// Точку переставили: отладчик нашёл код только ниже. Условие едет с ней.
    mutating func move(_ file: URL, from: Int, to: Int) {
        let key = file.standardizedFileURL
        guard from != to, lines[key]?.remove(from) != nil else { return }
        lines[key]?.insert(to)
        if let condition = conditions[key]?.removeValue(forKey: from), conditions[key]?[to] == nil {
            conditions[key]?[to] = condition
        }
    }

    mutating func removeAll() {
        lines = [:]
        conditions = [:]
    }

    /// Правка в файле: точки и их условия едут вместе со строками.
    /// Возвращает, сдвинулось ли что-нибудь.
    @discardableResult
    mutating func shift(_ file: URL, start: (line: Int, character: Int), endLine: Int, inserted: Int) -> Bool {
        let key = file.standardizedFileURL
        let old = lines(in: key)
        guard !old.isEmpty else { return false }
        var fresh = Set<Int>()
        var moved: [Int: String] = [:]
        // По порядку: если две точки слились в одну, условие — у верхней.
        for line in old.sorted() {
            let to = Self.shift(line, start: start, endLine: endLine, inserted: inserted)
            fresh.insert(to)
            if let condition = conditions[key]?[line], moved[to] == nil { moved[to] = condition }
        }
        guard fresh != old || moved != (conditions[key] ?? [:]) else { return false }
        lines[key] = fresh
        conditions[key] = moved.isEmpty ? nil : moved
        return true
    }

    /// Правка в файле сдвигает точки ниже неё, как сдвигаются сами строки.
    /// `start`–`end` — заменённый кусок (строка, символ) в старом тексте,
    /// `inserted` — сколько переводов строки во вставленном.
    ///
    /// Точка внутри удалённых строк переезжает на строку правки: терять её
    /// молча хуже, чем оставить рядом. Перевод строки, вставленный в самое
    /// начало строки с точкой, уносит её вниз вместе с текстом.
    static func shift(_ lines: Set<Int>, start: (line: Int, character: Int), endLine: Int, inserted: Int) -> Set<Int> {
        Set(lines.map { shift($0, start: start, endLine: endLine, inserted: inserted) })
    }

    static func shift(_ line: Int, start: (line: Int, character: Int), endLine: Int, inserted: Int) -> Int {
        let removed = endLine - start.line
        let delta = inserted - removed
        guard delta != 0 else { return line }
        if line < start.line { return line }
        if line == start.line {
            let pushedDown = start.character == 0 && removed == 0 && inserted > 0
            return pushedDown ? line + delta : line
        }
        if line <= endLine { return start.line }
        return max(start.line, line + delta)
    }

    // MARK: Хранение

    /// В настройках — по корню проекта, пути от корня: проект можно
    /// переложить в другую папку, и точки поедут вместе с ним.
    func serialized(root: URL) -> [String: [Int]] {
        let base = root.standardizedFileURL.path + "/"
        var result: [String: [Int]] = [:]
        for (file, set) in lines where file.path.hasPrefix(base) {
            result[String(file.path.dropFirst(base.count))] = set.sorted()
        }
        return result
    }

    /// Условия — отдельно от строк, чтобы старые настройки читались как
    /// есть: файл → номер строки строкой → выражение.
    func serializedConditions(root: URL) -> [String: [String: String]] {
        let base = root.standardizedFileURL.path + "/"
        var result: [String: [String: String]] = [:]
        for (file, map) in conditions where file.path.hasPrefix(base) {
            result[String(file.path.dropFirst(base.count))] = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        }
        return result
    }

    static func deserialized(_ stored: [String: [Int]], conditions storedConditions: [String: [String: String]] = [:],
                             root: URL) -> BreakpointSet {
        var lines: [URL: Set<Int>] = [:]
        for (relative, list) in stored {
            lines[root.appendingPathComponent(relative).standardizedFileURL] = Set(list.filter { $0 >= 0 })
        }
        var conditions: [URL: [Int: String]] = [:]
        for (relative, map) in storedConditions {
            var parsed: [Int: String] = [:]
            for (line, text) in map { if let n = Int(line) { parsed[n] = text } }
            conditions[root.appendingPathComponent(relative).standardizedFileURL] = parsed
        }
        return BreakpointSet(lines: lines, conditions: conditions)
    }

    private static let defaultsKey = "pilot.breakpoints"
    private static let conditionsKey = "pilot.breakpointConditions"

    static func load(root: URL, defaults: UserDefaults = .standard) -> BreakpointSet {
        let path = root.standardizedFileURL.path
        let all = defaults.dictionary(forKey: defaultsKey) as? [String: [String: [Int]]] ?? [:]
        let conditions = defaults.dictionary(forKey: conditionsKey) as? [String: [String: [String: String]]] ?? [:]
        return deserialized(all[path] ?? [:], conditions: conditions[path] ?? [:], root: root)
    }

    func save(root: URL, defaults: UserDefaults = .standard) {
        let path = root.standardizedFileURL.path
        var all = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: [Int]]] ?? [:]
        let mine = serialized(root: root)
        all[path] = mine.isEmpty ? nil : mine
        defaults.set(all, forKey: Self.defaultsKey)
        var conditions = defaults.dictionary(forKey: Self.conditionsKey) as? [String: [String: [String: String]]] ?? [:]
        let mineConditions = serializedConditions(root: root)
        conditions[path] = mineConditions.isEmpty ? nil : mineConditions
        defaults.set(conditions, forKey: Self.conditionsKey)
    }
}
