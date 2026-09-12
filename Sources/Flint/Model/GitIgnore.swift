import Foundation

/// Минимальная, но честная реализация семантики .gitignore:
/// отрицания (!), якорь в начале (/), только-директории (/ в конце),
/// глобы * ? и **. Правила применяются каскадом по дереву:
/// .gitignore в подпапке дополняет родительские.
struct IgnoreRule {
    let pattern: [UInt8]
    let negated: Bool
    let dirOnly: Bool
    let anchored: Bool       // паттерн привязан к папке, где лежит .gitignore
    let hasSlash: Bool       // матчим по относительному пути, а не по имени

    init?(line: String) {
        var s = Substring(line)
        // комментарии и пустые строки
        if s.isEmpty || s.hasPrefix("#") { return nil }
        // хвостовые пробелы не экранированные бэкслешем
        while s.hasSuffix(" ") { s = s.dropLast() }
        if s.isEmpty { return nil }

        var neg = false
        if s.hasPrefix("!") { neg = true; s = s.dropFirst() }
        else if s.hasPrefix("\\!") { s = s.dropFirst() }

        var dir = false
        if s.hasSuffix("/") { dir = true; s = s.dropLast() }
        if s.isEmpty { return nil }

        var anch = false
        if s.hasPrefix("/") { anch = true; s = s.dropFirst() }

        let slash = s.contains("/")
        self.pattern = Array(s.utf8)
        self.negated = neg
        self.dirOnly = dir
        self.anchored = anch || slash
        self.hasSlash = slash
    }
}

/// Набор правил одного .gitignore вместе с путём папки, к которой он относится.
struct IgnoreLayer {
    let rules: [IgnoreRule]
    /// Путь папки с .gitignore относительно корня воркспейса ("" для корня).
    let base: String

    static func load(at dirURL: URL, base: String) -> IgnoreLayer? {
        let f = dirURL.appendingPathComponent(".gitignore")
        guard let data = try? Data(contentsOf: f),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let rules = text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { IgnoreRule(line: String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))) }
        return rules.isEmpty ? nil : IgnoreLayer(rules: rules, base: base)
    }
}

/// Матчер, собранный из цепочки .gitignore-слоёв от корня до текущей папки.
/// Значимый тип: цепочка передаётся детям при обходе (массив COW — копии нет).
struct IgnoreMatcher {
    let layers: [IgnoreLayer]
    let useSoftSkip: Bool

    /// Всегда игнорируем — независимо от .gitignore.
    private static let hardSkip: Set<String> = [".git", ".svn", ".hg", ".DS_Store"]

    /// Эвристика на случай, когда .gitignore нет вообще (не git-проект).
    private static let softSkip: Set<String> = [
        "node_modules", "bin", "obj", ".build", ".gradle", "DerivedData",
        "target", "dist", "__pycache__", ".venv", "venv", "Pods", ".next",
        ".nuget", "packages", ".idea", ".vs"
    ]

    func adding(_ layer: IgnoreLayer?) -> IgnoreMatcher {
        guard let layer else { return self }
        return IgnoreMatcher(layers: layers + [layer], useSoftSkip: useSoftSkip)
    }

    /// `relPath` — путь относительно корня воркспейса, без ведущего слеша.
    func isIgnored(relPath: String, name: String, isDir: Bool) -> Bool {
        if Self.hardSkip.contains(name) { return true }
        if useSoftSkip && isDir && Self.softSkip.contains(name) { return true }

        var ignored = false
        for layer in layers {
            // путь относительно папки, в которой лежит этот .gitignore
            let scoped: String
            if layer.base.isEmpty {
                scoped = relPath
            } else if relPath.hasPrefix(layer.base + "/") {
                scoped = String(relPath.dropFirst(layer.base.count + 1))
            } else {
                continue
            }
            for rule in layer.rules {
                if rule.dirOnly && !isDir { continue }
                // Якорное правило (/build или src/*.ts) матчится по пути,
                // остальные — по имени в любой папке.
                let target = rule.anchored ? scoped : name
                if Glob.match(pattern: rule.pattern, text: Array(target.utf8)) {
                    ignored = !rule.negated
                }
            }
        }
        return ignored
    }
}

/// Глоб-матчер с поддержкой *, ?, ** и [...].
enum Glob {
    static func match(pattern: [UInt8], text: [UInt8]) -> Bool {
        return matchFrom(pattern, 0, text, 0)
    }

    private static func matchFrom(_ p: [UInt8], _ pi0: Int, _ t: [UInt8], _ ti0: Int) -> Bool {
        var pi = pi0, ti = ti0
        var starP = -1, starT = -1

        while ti < t.count {
            if pi < p.count {
                let pc = p[pi]
                if pc == 0x2A { // '*'
                    // '**' проходит через слеши, одиночная '*' — нет
                    if pi + 1 < p.count && p[pi + 1] == 0x2A {
                        var np = pi + 2
                        if np < p.count && p[np] == 0x2F { np += 1 }
                        // жадно пробуем все позиции
                        var k = ti
                        while k <= t.count {
                            if matchFrom(p, np, t, k) { return true }
                            k += 1
                        }
                        return false
                    }
                    starP = pi; starT = ti; pi += 1
                    continue
                }
                if pc == 0x3F && t[ti] != 0x2F { pi += 1; ti += 1; continue } // '?'
                if pc == 0x5B { // '[' класс символов
                    var k = pi + 1
                    var negate = false
                    if k < p.count && (p[k] == 0x21 || p[k] == 0x5E) { negate = true; k += 1 }
                    var matched = false
                    var first = true
                    while k < p.count && (p[k] != 0x5D || first) {
                        first = false
                        if k + 2 < p.count && p[k + 1] == 0x2D && p[k + 2] != 0x5D {
                            if t[ti] >= p[k] && t[ti] <= p[k + 2] { matched = true }
                            k += 3
                        } else {
                            if t[ti] == p[k] { matched = true }
                            k += 1
                        }
                    }
                    if k < p.count { k += 1 }
                    if matched != negate { pi = k; ti += 1; continue }
                } else if pc == t[ti] {
                    pi += 1; ti += 1; continue
                }
            }
            // бэктрекинг на последнюю '*' — но она не перепрыгивает через '/'
            if starP >= 0 && t[starT] != 0x2F {
                starT += 1; ti = starT; pi = starP + 1
                continue
            }
            return false
        }
        while pi < p.count && p[pi] == 0x2A { pi += 1 }
        return pi == p.count
    }
}
