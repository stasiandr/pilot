import Foundation

/// Точки останова проекта: файл → строки с нуля. Живут между запусками
/// Pilot и между сессиями отладки — как в Rider и Xcode.
struct BreakpointSet: Equatable {
    private(set) var lines: [URL: Set<Int>] = [:]

    init(lines: [URL: Set<Int>] = [:]) {
        self.lines = lines.filter { !$0.value.isEmpty }
    }

    var isEmpty: Bool { lines.isEmpty }
    var count: Int { lines.values.reduce(0) { $0 + $1.count } }

    func lines(in file: URL) -> Set<Int> { lines[file.standardizedFileURL] ?? [] }

    /// Поставить или снять. Возвращает, стоит ли точка теперь.
    @discardableResult
    mutating func toggle(_ file: URL, line: Int) -> Bool {
        let key = file.standardizedFileURL
        var set = lines[key] ?? []
        let added = set.insert(line).inserted
        if !added { set.remove(line) }
        lines[key] = set.isEmpty ? nil : set
        return added
    }

    mutating func set(_ file: URL, _ fresh: Set<Int>) {
        lines[file.standardizedFileURL] = fresh.isEmpty ? nil : fresh
    }

    mutating func removeAll() { lines = [:] }

    /// Правка в файле сдвигает точки ниже неё, как сдвигаются сами строки.
    /// `start`–`end` — заменённый кусок (строка, символ) в старом тексте,
    /// `inserted` — сколько переводов строки во вставленном.
    ///
    /// Точка внутри удалённых строк переезжает на строку правки: терять её
    /// молча хуже, чем оставить рядом. Перевод строки, вставленный в самое
    /// начало строки с точкой, уносит её вниз вместе с текстом.
    static func shift(_ lines: Set<Int>, start: (line: Int, character: Int), endLine: Int, inserted: Int) -> Set<Int> {
        let removed = endLine - start.line
        let delta = inserted - removed
        guard delta != 0 else { return lines }
        var result = Set<Int>()
        for line in lines {
            if line < start.line {
                result.insert(line)
            } else if line == start.line {
                let pushedDown = start.character == 0 && removed == 0 && inserted > 0
                result.insert(pushedDown ? line + delta : line)
            } else if line <= endLine {
                result.insert(start.line)
            } else {
                result.insert(max(start.line, line + delta))
            }
        }
        return result
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

    static func deserialized(_ stored: [String: [Int]], root: URL) -> BreakpointSet {
        var set = BreakpointSet()
        for (relative, lines) in stored {
            set.lines[root.appendingPathComponent(relative).standardizedFileURL] = Set(lines.filter { $0 >= 0 })
        }
        return BreakpointSet(lines: set.lines)
    }

    private static let defaultsKey = "pilot.breakpoints"

    static func load(root: URL, defaults: UserDefaults = .standard) -> BreakpointSet {
        let all = defaults.dictionary(forKey: defaultsKey) as? [String: [String: [Int]]] ?? [:]
        return deserialized(all[root.standardizedFileURL.path] ?? [:], root: root)
    }

    func save(root: URL, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: [Int]]] ?? [:]
        let mine = serialized(root: root)
        all[root.standardizedFileURL.path] = mine.isEmpty ? nil : mine
        defaults.set(all, forKey: Self.defaultsKey)
    }
}
