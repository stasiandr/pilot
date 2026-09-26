import Foundation

/// Совпадение в тексте файла.
struct TextHit: Equatable {
    /// Номер файла в списке, который искали.
    var file: Int32
    /// Строка и колонка начала, с нуля. Колонка — в UTF-16, как в `LSPRange`.
    var line: Int
    var column: Int
    /// Длина совпадения в UTF-16.
    var length: Int
    /// Строка целиком (или её кусок вокруг совпадения), без отступа.
    var text: String
    /// Байтовые позиции совпадения внутри `text` — для подсветки.
    var positions: [Int32]
    /// Совпадение не продолжает слово ни слева, ни справа.
    var wholeWord: Bool
}

/// Поиск текста по файлам проекта — то, ради чего обычно зовут ripgrep:
/// файлы читаются параллельно на всех ядрах, двоичные и огромные
/// пропускаются, регистр — «умный»: запрос без заглавных находит любые.
///
/// Читает с диска, а не из открытых вкладок: несохранённая правка найдётся
/// после сохранения. Страничный кэш системы делает повторный поиск по тем же
/// файлам чтением из памяти.
enum ContentSearch {

    struct Options {
        /// Сколько совпадений всего. Дальше поиск останавливается.
        var limit = 400
        /// Сколько совпадений в одном файле: минифицированный JSON иначе
        /// заполнил бы собой всю выдачу.
        var perFile = 20
        /// Файлы больше этого не читаются — это данные, а не код.
        var maxFileSize = 4 << 20
    }

    /// Расширения, которые заведомо не текст: читать их незачем.
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tga", "psd", "exr", "hdr", "tif", "tiff", "bmp", "ico", "icns",
        "fbx", "obj", "blend", "dae", "3ds", "max", "wav", "mp3", "ogg", "aif", "aiff", "flac", "mp4", "mov",
        "ttf", "otf", "woff", "woff2", "dll", "so", "dylib", "exe", "pdb", "mdb", "a", "o", "lib",
        "zip", "gz", "7z", "rar", "tar", "unitypackage", "bundle", "bytes", "bin", "dat", "db", "sqlite",
        "pdf", "jar", "class", "pyc", "cache", "lfs",
    ]

    /// `paths` — относительно `root`. Результат идёт в порядке файлов из
    /// `paths` и строк в файле — ранжирует потом тот, кто спрашивал.
    static func search(_ query: String, root: URL, paths: [String], options: Options = Options(),
                       shouldStop: @escaping () -> Bool) -> [TextHit] {
        let needle = Array(query.utf8)
        guard !needle.isEmpty, !paths.isEmpty else { return [] }
        // «Умный» регистр — как в ripgrep и в нечётком поиске: заглавная в
        // запросе значит, что регистр важен.
        let ignoreCase = !query.contains { $0.isUppercase }
        let folded = ignoreCase ? needle.map(lower) : needle

        let collected = Collected(files: paths.count)
        let rootPath = root.path

        // Кусками, а не по файлу: у тысяч мелких файлов накладные расходы на
        // задачу были бы заметнее самого поиска.
        let chunk = 64
        let chunks = (paths.count + chunk - 1) / chunk
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var buffer = [UInt8]()
            for i in (c * chunk)..<min(paths.count, (c + 1) * chunk) {
                if shouldStop() || collected.total >= options.limit { return }
                let rel = paths[i]
                let ext = (rel as NSString).pathExtension.lowercased()
                if binaryExtensions.contains(ext) { continue }
                guard load(rootPath + "/" + rel, into: &buffer, max: options.maxFileSize) else { continue }
                let hits = scan(buffer, needle: folded, ignoreCase: ignoreCase,
                                file: Int32(i), perFile: options.perFile)
                if !hits.isEmpty { collected.add(hits, at: i) }
            }
        }
        if shouldStop() { return [] }
        return Array(collected.found.joined().prefix(options.limit))
    }

    /// Что нашли потоки, по месту файла в списке.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var found: [[TextHit]]
        private var count = 0

        init(files: Int) { found = Array(repeating: [], count: files) }

        var total: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func add(_ hits: [TextHit], at index: Int) {
            lock.lock()
            found[index] = hits
            count += hits.count
            lock.unlock()
        }
    }

    // MARK: - Чтение

    /// Файл целиком в `buffer`. `false` — не читается, слишком большой или
    /// двоичный (ноль в первых килобайтах — как решает git).
    private static func load(_ path: String, into buffer: inout [UInt8], max: Int) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        let size = Int(info.st_size)
        guard size > 0, size <= max else { return false }
        var ok = true
        buffer = [UInt8](unsafeUninitializedCapacity: size) { raw, count in
            var done = 0
            while done < size {
                let n = read(fd, raw.baseAddress! + done, size - done)
                if n <= 0 { break }
                done += n
            }
            count = done
            ok = done > 0
        }
        guard ok else { return false }
        let probe = min(buffer.count, 8000)
        return buffer.withUnsafeBufferPointer { memchr($0.baseAddress!, 0, probe) == nil }
    }

    // MARK: - Поиск в одном файле

    @inline(__always)
    private static func lower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 32 : b }

    @inline(__always)
    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == 0x5F || b >= 0x80
    }

    static func scan(_ text: [UInt8], needle: [UInt8], ignoreCase: Bool,
                     file: Int32, perFile: Int) -> [TextHit] {
        let n = needle.count
        guard text.count >= n else { return [] }
        var hits: [TextHit] = []
        text.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let count = buf.count
            let first = needle[0]
            // Первый байт в обоих регистрах: memchr ищет только один, поэтому
            // при игноре регистра для букв бежим сами.
            let firstUpper: UInt8 = ignoreCase && first >= 0x61 && first <= 0x7A ? first - 32 : first
            var line = 0
            var lineCounted = 0   // до какого байта строки уже посчитаны
            var lastHitLine = -1
            var i = 0
            while i <= count - n {
                // Кандидат на начало.
                if firstUpper == first {
                    guard let p = memchr(base + i, Int32(first), count - n + 1 - i) else { break }
                    i = base.distance(to: p.assumingMemoryBound(to: UInt8.self))
                } else {
                    let b = base[i]
                    if b != first && b != firstUpper { i += 1; continue }
                }
                var matched = true
                var k = 1
                while k < n {
                    let b = ignoreCase ? lower(base[i + k]) : base[i + k]
                    if b != needle[k] { matched = false; break }
                    k += 1
                }
                if !matched { i += 1; continue }

                // Номер строки — подсчётом переводов с прошлого места.
                var j = lineCounted
                while j < i {
                    if base[j] == 0x0A { line += 1 }
                    j += 1
                }
                lineCounted = i
                // Одна строка — одно совпадение: вторая в той же строке в
                // выдаче была бы копией первой.
                if line == lastHitLine { i += n; continue }
                lastHitLine = line

                var start = i
                while start > 0 && base[start - 1] != 0x0A { start -= 1 }
                var end = i + n
                while end < count && base[end] != 0x0A && base[end] != 0x0D { end += 1 }
                let whole = (i == 0 || !isWordByte(base[i - 1]))
                    && (i + n >= count || !isWordByte(base[i + n]))
                hits.append(makeHit(base, lineStart: start, lineEnd: end, match: i, length: n,
                                    file: file, line: line, wholeWord: whole))
                if hits.count >= perFile { return }
                i += n
            }
        }
        return hits
    }

    /// Строка для показа: без отступа и не длиннее разумного — вокруг
    /// совпадения остаётся контекст с обеих сторон.
    private static func makeHit(_ base: UnsafePointer<UInt8>, lineStart: Int, lineEnd: Int,
                                match: Int, length: Int, file: Int32, line: Int, wholeWord: Bool) -> TextHit {
        func string(_ from: Int, _ to: Int) -> String {
            String(decoding: UnsafeBufferPointer(start: base + from, count: max(0, to - from)), as: UTF8.self)
        }
        let column = string(lineStart, match).utf16.count
        let matchText = string(match, match + length)

        var shownStart = lineStart
        while shownStart < match && (base[shownStart] == 0x20 || base[shownStart] == 0x09) { shownStart += 1 }
        var shownEnd = lineEnd
        let maxBefore = 60, maxTotal = 220
        var cut = false
        if match - shownStart > maxBefore {
            cut = true
            shownStart = match - maxBefore
            // Не резать посреди UTF-8 символа.
            while shownStart < match && (base[shownStart] & 0xC0) == 0x80 { shownStart += 1 }
        }
        if shownEnd - shownStart > maxTotal {
            shownEnd = max(match + length, shownStart + maxTotal)
            while shownEnd < lineEnd && (base[shownEnd] & 0xC0) == 0x80 { shownEnd += 1 }
        }
        let prefix = cut ? "…" : ""
        let text = prefix + string(shownStart, shownEnd)
        let offset = prefix.utf8.count + (match - shownStart)
        return TextHit(file: file, line: line, column: column, length: matchText.utf16.count,
                       text: text, positions: (0..<length).map { Int32(offset + $0) },
                       wholeWord: wholeWord)
    }
}
