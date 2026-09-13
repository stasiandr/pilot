import Foundation

/// Содержимое папки через readdir: имя и тип приходят одной записью —
/// без URL на каждый файл и без отдельного stat.
enum DirectoryReader {
    struct Entry {
        let name: String
        let isDirectory: Bool
    }

    /// Файлы и папки без скрытых и без симлинков (по ним не ходим), плюс
    /// есть ли в папке свой .gitignore. nil — папку не открыть.
    static func read(_ path: String) -> (entries: [Entry], hasGitignore: Bool)? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }

        var entries: [Entry] = []
        var hasGitignore = false
        while let record = readdir(dir) {
            let name = withUnsafePointer(to: &record.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: MemoryLayout.size(ofValue: record.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name.utf8.first == 0x2E {                 // скрытые, а заодно «.» и «..»
                if name == ".gitignore" { hasGitignore = true }
                continue
            }
            var type = Int(record.pointee.d_type)
            if type == typeUnknown {
                // Не всякая ФС заполняет d_type — тогда спрашиваем явно.
                var info = stat()
                guard lstat(path + "/" + name, &info) == 0 else { continue }
                switch Int(info.st_mode) & 0o170000 {
                case 0o040000: type = typeDirectory
                case 0o100000: type = typeRegular
                default: continue
                }
            }
            switch type {
            case typeDirectory: entries.append(Entry(name: name, isDirectory: true))
            case typeRegular:   entries.append(Entry(name: name, isDirectory: false))
            default: continue                            // симлинки, сокеты, устройства
            }
        }
        return (entries, hasGitignore)
    }

    // Значения d_type одинаковы на macOS и Linux.
    private static let typeUnknown = 0, typeDirectory = 4, typeRegular = 8
}

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

    /// Индекс из готового списка относительных путей — от git.
    convenience init(root: URL, paths: [String]) {
        self.init(root: root)
        reserve(paths.count)
        for path in paths { append(rel: path) }
    }

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
        // Никакого reserveCapacity на каждую запись: он выделяет ровно
        // запрошенное и ломает геометрический рост — буфер копировался бы
        // целиком чуть ли не на каждом пути, и на 272 000 файлов это полторы
        // секунды вместо десятков миллисекунд.
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

    /// Список файлов проекта. В git-репозитории его даёт git — это на порядки
    /// быстрее обхода; иначе обходим диск сами.
    ///
    /// `early` получает индекс из одних отслеживаемых файлов, как только git
    /// их отдал (десятые доли секунды), — до того, как он найдёт новые.
    /// Синхронный — вызывать вне главного потока.
    static func scan(root: URL, shouldStop: @escaping () -> Bool,
                     early: ((FileIndex) -> Void)? = nil) -> FileIndex {
        // Пустой ответ бывает, когда открыта папка, которую git игнорирует
        // или ещё не видел: тогда он ничего о ней не знает, и обходим сами.
        if let tracked = GitFiles.tracked(root: root), !tracked.isEmpty, !shouldStop() {
            early?(FileIndex(root: root, paths: tracked))
            let complete = shouldStop() ? nil : GitFiles.complete(root: root, tracked: tracked)
            return FileIndex(root: root, paths: complete ?? tracked)
        }
        return build(root: root, shouldStop: shouldStop)
    }

    /// Рекурсивный обход. Синхронный — вызывающий обязан делать это вне главного потока.
    /// `shouldStop` позволяет прервать обход, если воркспейс сменился.
    ///
    /// Обход в ширину, по уровням: все папки одного уровня читаются
    /// параллельно, а результаты складываются в порядке папок — индекс
    /// получается тот же, что при последовательном обходе.
    static func build(root: URL, shouldStop: @escaping () -> Bool) -> FileIndex {
        let index = FileIndex(root: root)
        index.reserve(8192)

        let rootPath = root.path
        let hasRootIgnore = FileManager.default.fileExists(atPath: rootPath + "/.gitignore")

        // Каждый фрейм несёт цепочку .gitignore своих предков, поэтому правила
        // родителей корректно наследуются вглубь. Свой .gitignore папка
        // добавляет сама, когда её читают: есть ли он, видно из листинга.
        var level = [WalkFrame(rel: "", inherited: IgnoreMatcher(layers: [], useSoftSkip: !hasRootIgnore))]

        while !level.isEmpty && !shouldStop() {
            let frames = level
            var listings = [WalkListing](repeating: WalkListing(), count: frames.count)
            listings.withUnsafeMutableBufferPointer { out in
                // Каждая итерация пишет только в свою ячейку.
                DispatchQueue.concurrentPerform(iterations: frames.count) { i in
                    out[i] = walk(frames[i], rootPath: rootPath)
                }
            }
            level = []
            for listing in listings {
                for rel in listing.files { index.append(rel: rel) }
                level += listing.dirs
            }
        }
        return index
    }

    private struct WalkFrame {
        let rel: String
        let inherited: IgnoreMatcher   // слои .gitignore предков, без своего
    }

    private struct WalkListing {
        var files: [String] = []
        var dirs: [WalkFrame] = []
    }

    private static func walk(_ frame: WalkFrame, rootPath: String) -> WalkListing {
        let dirPath = frame.rel.isEmpty ? rootPath : rootPath + "/" + frame.rel
        var listing = WalkListing()
        guard let contents = DirectoryReader.read(dirPath) else { return listing }

        // .gitignore папки действует только на её содержимое.
        let ignore = contents.hasGitignore
            ? frame.inherited.adding(IgnoreLayer.load(path: dirPath + "/.gitignore", base: frame.rel))
            : frame.inherited

        for entry in contents.entries {
            let rel = frame.rel.isEmpty ? entry.name : frame.rel + "/" + entry.name
            if ignore.isIgnored(relPath: rel, name: entry.name, isDir: entry.isDirectory) { continue }
            if entry.isDirectory {
                listing.dirs.append(WalkFrame(rel: rel, inherited: ignore))
            } else {
                listing.files.append(rel)
            }
        }
        return listing
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
