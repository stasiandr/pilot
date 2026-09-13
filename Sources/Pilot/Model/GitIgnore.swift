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

    /// Как проверять. Правило сверяется с каждым путём проекта, поэтому
    /// разбор паттерна делается один раз здесь, а не на каждом пути.
    enum Kind {
        /// Без спецсимволов: `Thumbs.db`, `Assets/link.xml` — простое сравнение.
        case literal
        /// `*.csproj` — окончание имени.
        case suffix([UInt8])
        /// Общий случай. Сначала ищем в пути самый длинный кусок паттерна без
        /// спецсимволов (`ssets/StreamingAssets/` из `/[Aa]ssets/StreamingAssets/**/*.bank`):
        /// если его нет, глоб даже не запускаем. Так отсеивается почти всё.
        case glob(required: [UInt8])
    }
    let kind: Kind

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
        self.kind = Self.classify(pattern, anchored: anch || slash)
    }

    private static func isSpecial(_ b: UInt8) -> Bool { b == 0x2A || b == 0x3F || b == 0x5B }   // * ? [

    static func classify(_ p: [UInt8], anchored: Bool) -> Kind {
        if !p.contains(where: isSpecial) { return .literal }
        // Одиночная `*` не проходит через `/`, поэтому суффикс годится только
        // для правил по имени — в имени слешей нет.
        if !anchored, p.count > 1, p[0] == 0x2A, !p[1...].contains(where: isSpecial) {
            return .suffix(Array(p[1...]))
        }
        return .glob(required: longestLiteral(p))
    }

    /// Самый длинный кусок паттерна без `*`, `?` и `[...]`.
    static func longestLiteral(_ p: [UInt8]) -> [UInt8] {
        var best: ArraySlice<UInt8> = []
        var runStart = 0
        var i = 0
        func close(_ end: Int) {
            if end - runStart > best.count { best = p[runStart..<end] }
        }
        while i < p.count {
            if p[i] == 0x5B {                                   // пропускаем класс целиком
                close(i)
                var k = i + 1
                if k < p.count && (p[k] == 0x21 || p[k] == 0x5E) { k += 1 }
                if k < p.count && p[k] == 0x5D { k += 1 }         // `]` сразу после `[` — литерал
                while k < p.count && p[k] != 0x5D { k += 1 }
                i = k + 1
                runStart = i
            } else if p[i] == 0x2A && i + 1 < p.count && p[i + 1] == 0x2A {
                // `**/` может совпасть с пустотой: `**/foo` ловит и `foo` в корне.
                // Значит, слеш после `**` не обязателен и в литерал не входит.
                close(i)
                i += 2
                if i < p.count && p[i] == 0x2F { i += 1 }
                runStart = i
            } else if isSpecial(p[i]) {
                close(i)
                i += 1
                runStart = i
            } else {
                i += 1
            }
        }
        close(min(i, p.count))
        return Array(best)
    }

    /// `target` — имя или путь относительно папки с .gitignore, смотря по `anchored`.
    func matches(_ target: UnsafeBufferPointer<UInt8>) -> Bool {
        switch kind {
        case .literal:
            return target.elementsEqual(pattern)
        case .suffix(let tail):
            // Правило по имени получает имя, а в нём слешей нет; проверка —
            // чтобы и на пути ответ был как у глоба, где `*` не проходит через `/`.
            return target.count >= tail.count
                && UnsafeBufferPointer(rebasing: target[(target.count - tail.count)...]).elementsEqual(tail)
                && !target[..<(target.count - tail.count)].contains(0x2F)
        case .glob(let required):
            if !required.isEmpty && !Self.contains(target, required) { return false }
            return pattern.withUnsafeBufferPointer { Glob.match(pattern: $0, text: target) }
        }
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count, let base = haystack.baseAddress else { return false }
        return needle.withUnsafeBufferPointer { n in
            let first = n[0]
            var i = 0
            let last = haystack.count - n.count
            while i <= last {
                if base[i] == first && memcmp(base + i, n.baseAddress!, n.count) == 0 { return true }
                i += 1
            }
            return false
        }
    }
}

/// Набор правил одного .gitignore вместе с путём папки, к которой он относится.
struct IgnoreLayer {
    let rules: [IgnoreRule]
    /// Путь папки с .gitignore относительно корня воркспейса ("" для корня).
    let base: String
    fileprivate let baseBytes: [UInt8]

    init(rules: [IgnoreRule], base: String) {
        self.rules = rules
        self.base = base
        self.baseBytes = Array(base.utf8)
    }

    static func load(at dirURL: URL, base: String) -> IgnoreLayer? {
        load(path: dirURL.appendingPathComponent(".gitignore").path, base: base)
    }

    static func load(path: String, base: String) -> IgnoreLayer? {
        guard let data = FileManager.default.contents(atPath: path),
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

        guard !layers.isEmpty else { return false }
        // Байты пути и имени — один раз на путь, а не на каждое правило.
        let relBytes = Array(relPath.utf8)
        let nameBytes = Array(name.utf8)
        return relBytes.withUnsafeBufferPointer { rel in
            nameBytes.withUnsafeBufferPointer { nameBuffer in
                var ignored = false
                for layer in layers {
                    // путь относительно папки, в которой лежит этот .gitignore
                    let scoped: UnsafeBufferPointer<UInt8>
                    let baseCount = layer.baseBytes.count
                    if baseCount == 0 {
                        scoped = rel
                    } else if rel.count > baseCount, rel[baseCount] == 0x2F,
                              UnsafeBufferPointer(rebasing: rel[..<baseCount]).elementsEqual(layer.baseBytes) {
                        scoped = UnsafeBufferPointer(rebasing: rel[(baseCount + 1)...])
                    } else {
                        continue
                    }
                    for rule in layer.rules {
                        if rule.dirOnly && !isDir { continue }
                        // Побеждает последнее совпавшее правило. Если правило
                        // не может изменить ответ, проверять его незачем.
                        if ignored != rule.negated { continue }
                        // Якорное правило (/build или src/*.ts) матчится по пути,
                        // остальные — по имени в любой папке.
                        if rule.matches(rule.anchored ? scoped : nameBuffer) {
                            ignored = !rule.negated
                        }
                    }
                }
                return ignored
            }
        }
    }
}

/// Глоб-матчер с поддержкой *, ?, ** и [...].
enum Glob {
    static func match(pattern: [UInt8], text: [UInt8]) -> Bool {
        pattern.withUnsafeBufferPointer { p in
            text.withUnsafeBufferPointer { t in match(pattern: p, text: t) }
        }
    }

    /// Без массивов: матчер зовётся на каждый путь и каждое правило,
    /// и копия пути ради одной проверки обходилась дороже самой проверки.
    static func match(pattern: UnsafeBufferPointer<UInt8>, text: UnsafeBufferPointer<UInt8>) -> Bool {
        matchFrom(pattern, 0, text, 0)
    }

    private static func matchFrom(_ p: UnsafeBufferPointer<UInt8>, _ pi0: Int,
                                  _ t: UnsafeBufferPointer<UInt8>, _ ti0: Int) -> Bool {
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
