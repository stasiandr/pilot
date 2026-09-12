import Foundation

struct SearchHit: Identifiable {
    let id: Int32            // индекс записи в FileIndex
    let score: Int
    let positions: [Int32]   // байтовые позиции совпадений в relPath (для подсветки)
}

/// Индекс файлов воркспейса.
///
/// Все относительные пути лежат в одном непрерывном буфере `bytes`
/// (в нижнем регистре, для матчинга), а отображаемые строки — в `display`.
/// Поиск бежит по `bytes` без единой аллокации на файл.
final class FileIndex: @unchecked Sendable {
    struct Entry {
        var start: Int32       // смещение в bytes
        var length: Int32
        var nameStart: Int32   // смещение начала имени файла (абсолютное, внутри bytes)
    }

    private(set) var bytes: [UInt8] = []
    private(set) var entries: [Entry] = []
    private(set) var display: [String] = []
    private(set) var root: URL

    init(root: URL) { self.root = root }

    var count: Int { entries.count }

    func relPath(_ i: Int32) -> String { display[Int(i)] }

    func absoluteURL(_ i: Int32) -> URL {
        root.appendingPathComponent(display[Int(i)])
    }

    /// Смещение имени файла внутри отображаемой строки (в байтах UTF-8).
    func nameOffset(_ i: Int32) -> Int {
        let e = entries[Int(i)]
        return Int(e.nameStart - e.start)
    }

    /// Точка входа для восстановления из кэша (минуя обход ФС).
    func appendCached(rel: String) { append(rel: rel) }

    private func append(rel: String) {
        let utf8 = Array(rel.utf8)
        let start = bytes.count
        var lastSlash = -1
        bytes.reserveCapacity(bytes.count + utf8.count)
        for (k, b) in utf8.enumerated() {
            if b == 0x2F { lastSlash = k }
            bytes.append((b >= 0x41 && b <= 0x5A) ? b + 32 : b)
        }
        entries.append(Entry(start: Int32(start),
                             length: Int32(utf8.count),
                             nameStart: Int32(start + lastSlash + 1)))
        display.append(rel)
    }

    private func reserve(_ n: Int) {
        entries.reserveCapacity(n)
        display.reserveCapacity(n)
        bytes.reserveCapacity(n * 48)
    }

    // MARK: - Сканирование

    /// Рекурсивный обход. Синхронный — вызывающий обязан делать это вне главного потока.
    /// `shouldStop` позволяет прервать обход, если воркспейс сменился.
    /// `exclude` — правила проекта поверх `.gitignore`: например, `.meta` в Unity.
    static func build(root: URL,
                      exclude: ((_ relPath: String, _ isDirectory: Bool) -> Bool)? = nil,
                      shouldStop: @escaping () -> Bool) -> FileIndex {
        let index = FileIndex(root: root)
        index.reserve(8192)

        let fm = FileManager.default
        let hasRootIgnore = fm.fileExists(atPath: root.appendingPathComponent(".gitignore").path)

        struct Frame {
            let url: URL
            let rel: String
            let ignore: IgnoreMatcher   // цепочка слоёв, действующая на содержимое url
        }

        let rootMatcher = IgnoreMatcher(layers: [], useSoftSkip: !hasRootIgnore)
            .adding(IgnoreLayer.load(at: root, base: ""))

        // Обход в ширину: каждый фрейм несёт свою цепочку .gitignore,
        // поэтому правила родителей корректно наследуются вглубь.
        var queue: [Frame] = [Frame(url: root, rel: "", ignore: rootMatcher)]
        var head = 0

        while head < queue.count {
            if shouldStop() { break }
            let frame = queue[head]
            head += 1

            guard let children = try? fm.contentsOfDirectory(
                at: frame.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                let name = child.lastPathComponent
                let rel = frame.rel.isEmpty ? name : frame.rel + "/" + name

                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }   // не ходим по симлинкам
                let isDir = values?.isDirectory ?? false

                if frame.ignore.isIgnored(relPath: rel, name: name, isDir: isDir) { continue }
                if let exclude, exclude(rel, isDir) { continue }

                if isDir {
                    // .gitignore самой подпапки действует только на её содержимое
                    let childIgnore = frame.ignore.adding(IgnoreLayer.load(at: child, base: rel))
                    queue.append(Frame(url: child, rel: rel, ignore: childIgnore))
                } else {
                    index.append(rel: rel)
                }
            }
        }

        return index
    }

    // MARK: - Поиск

    /// Возвращает до `limit` лучших совпадений. Прерывается по `shouldStop`.
    func search(_ queryString: String, limit: Int, shouldStop: () -> Bool) -> [SearchHit] {
        let q = FuzzyMatch.Query(queryString)

        if q.isEmpty {
            return (0..<min(limit, entries.count)).map {
                SearchHit(id: Int32($0), score: 0, positions: [])
            }
        }

        var results: [SearchHit] = []
        results.reserveCapacity(1024)

        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var positions: [Int32]? = []

            for i in 0..<entries.count {
                if i & 0x3FF == 0 && shouldStop() { return }
                let e = entries[i]
                let ptr = base + Int(e.start)
                // дешёвый отсев до полного скоринга
                guard FuzzyMatch.firstPass(q, ptr, Int(e.length)) != nil else { continue }
                guard let s = FuzzyMatch.score(q,
                                               text: ptr,
                                               len: Int(e.length),
                                               nameStart: Int(e.nameStart - e.start),
                                               positions: &positions) else { continue }
                results.append(SearchHit(id: Int32(i), score: s, positions: positions ?? []))
            }
        }

        if shouldStop() { return [] }

        // Сортируем по очкам, при равенстве — по длине пути (короче лучше).
        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return entries[Int($0.id)].length < entries[Int($1.id)].length
        }
        if results.count > limit { results.removeSubrange(limit...) }
        return results
    }
}
