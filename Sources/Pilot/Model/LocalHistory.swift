import Foundation

/// Версия файла в локальной истории.
struct HistoryVersion: Codable, Hashable, Identifiable {
    enum Reason: String, Codable {
        /// Каким файл был до первой правки в Pilot — чтобы было куда вернуться.
        case original
        /// Сохранили в Pilot.
        case saved
        /// Поменялся мимо Pilot: другой редактор, git, генератор.
        case external
        /// Перед откатом правок из окна коммита.
        case discarded
    }

    var date: Date
    var blob: String
    var reason: Reason
    /// Строк в версии — для списка, без чтения самого текста.
    var lines: Int

    var id: String { "\(date.timeIntervalSince1970)-\(blob)" }
}

/// Локальная история, как в Rider: снимок файла при каждом сохранении и
/// при изменении снаружи, независимо от git. Спасает то, что не попало в
/// коммит: откатили не то, переписали файл целиком, git checkout поверх.
///
/// Лежит в `~/Library/Application Support/Pilot/History/<проект>/`:
/// тексты в `blobs/` по хэшу содержимого (одинаковые версии хранятся раз),
/// список версий каждого файла — `files/<хэш пути>.json`. Старше
/// `keepDays` и сверх `maxVersions` на файл — уходит.
final class LocalHistory: @unchecked Sendable {
    static let keepDays = 30
    static let maxVersions = 200
    /// Больше — не текст, который правят руками: сгенерированное, данные.
    static let maxFileSize = 4 * 1024 * 1024

    let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    /// Папка истории проекта: по хэшу пути корня, имя — для человека.
    static func directory(forProject root: URL, base: URL? = nil) -> URL {
        let base = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pilot/History")
        let path = root.standardizedFileURL.path
        return base.appendingPathComponent("\(root.lastPathComponent)-\(hash(path))")
    }

    // MARK: - Запись

    /// Записать версию. Такая же, как последняя, — не пишется. Вернёт true,
    /// если записал.
    @discardableResult
    func record(_ text: String, path: String, reason: HistoryVersion.Reason, date: Date = Date()) -> Bool {
        let data = Data(text.utf8)
        guard data.count <= Self.maxFileSize else { return false }
        let blob = Self.blobID(data)
        lock.lock()
        defer { lock.unlock() }
        var file = load(path) ?? FileHistory(path: path, versions: [])
        if file.versions.last?.blob == blob { return false }
        let fm = FileManager.default
        let blobURL = blobs.appendingPathComponent(blob)
        if !fm.fileExists(atPath: blobURL.path) {
            try? fm.createDirectory(at: blobs, withIntermediateDirectories: true)
            guard (try? data.write(to: blobURL, options: .atomic)) != nil else { return false }
        }
        let lines = text.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        file.versions.append(HistoryVersion(date: date, blob: blob, reason: reason, lines: lines))
        file.versions = Self.pruned(file.versions, now: date)
        save(file)
        return true
    }

    /// Есть ли у файла хоть одна версия.
    func hasVersions(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(load(path)?.versions.isEmpty ?? true)
    }

    // MARK: - Чтение

    /// Версии файла, новые первыми.
    func versions(of path: String) -> [HistoryVersion] {
        lock.lock()
        defer { lock.unlock() }
        return (load(path)?.versions ?? []).reversed()
    }

    func text(of version: HistoryVersion) -> String? {
        guard let data = try? Data(contentsOf: blobs.appendingPathComponent(version.blob)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Уборка

    /// Тексты, на которые не ссылается ни одна версия, — после обрезки
    /// старого. Раз при открытии проекта, фоном.
    func collectGarbage() {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard let indexes = try? fm.contentsOfDirectory(at: files, includingPropertiesForKeys: nil),
              let stored = try? fm.contentsOfDirectory(atPath: blobs.path) else { return }
        var referenced: Set<String> = []
        for url in indexes {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(FileHistory.self, from: data) else { continue }
            let kept = Self.pruned(file.versions, now: Date())
            if kept.count != file.versions.count {
                if kept.isEmpty { try? fm.removeItem(at: url) } else { save(FileHistory(path: file.path, versions: kept)) }
            }
            referenced.formUnion(kept.map(\.blob))
        }
        for name in stored where !referenced.contains(name) {
            try? fm.removeItem(at: blobs.appendingPathComponent(name))
        }
    }

    static func pruned(_ versions: [HistoryVersion], now: Date) -> [HistoryVersion] {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        var kept = versions.filter { $0.date >= cutoff }
        // Всё старое ушло — последнюю версию всё равно держим: с ней сравнивать.
        if kept.isEmpty, let last = versions.last { kept = [last] }
        if kept.count > maxVersions { kept.removeFirst(kept.count - maxVersions) }
        return kept
    }

    // MARK: - Внутреннее

    private struct FileHistory: Codable {
        var path: String
        var versions: [HistoryVersion]
    }

    private var blobs: URL { directory.appendingPathComponent("blobs") }
    private var files: URL { directory.appendingPathComponent("files") }

    private func indexURL(_ path: String) -> URL {
        files.appendingPathComponent(Self.hash(path) + ".json")
    }

    private func load(_ path: String) -> FileHistory? {
        guard let data = try? Data(contentsOf: indexURL(path)),
              let file = try? JSONDecoder().decode(FileHistory.self, from: data), file.path == path else { return nil }
        return file
    }

    private func save(_ file: FileHistory) {
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: indexURL(file.path), options: .atomic)
    }

    /// FNV-1a, 64 бита, и длина: имя текста в `blobs/`. Криптостойкость тут
    /// ни к чему, а CryptoKit нет на Linux, где тоже гоняются тесты.
    static func blobID(_ data: Data) -> String {
        hash(data) + "-" + String(data.count, radix: 16)
    }

    static func hash(_ string: String) -> String { hash(Data(string.utf8)) }

    private static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}

/// Сравнение версии с текущим текстом — куски для окна истории.
enum HistoryDiff {
    /// Кусок различий: какие строки старой версии заменены какими строками
    /// нынешней. Номера — с нуля.
    struct Hunk: Equatable, Identifiable {
        var old: Range<Int>
        var new: Range<Int>
        var id: String { "\(old.lowerBound)-\(new.lowerBound)" }
    }

    static func hunks(old: String, new: String) -> [Hunk] {
        LineDiff.changes(old: old, new: new).map { Hunk(old: $0.oldLines, new: $0.lines) }
    }

    /// Вернуть кусок: строки `hunk.new` нынешнего текста заменить строками
    /// `hunk.old` версии. Ответ — одна правка нынешнего текста (UTF-16).
    ///
    /// Строки — части между `\n`, как у LineDiff: тогда разбиение и склейка
    /// обратимы, и перевод строки в конце файла не требует особых случаев.
    static func revert(_ hunk: Hunk, old: String, new: String) -> (range: NSRange, text: String) {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let result = (newLines[..<hunk.new.lowerBound] + oldLines[hunk.old] + newLines[hunk.new.upperBound...])
            .joined(separator: "\n")
        return difference(from: new, to: result)
    }

    /// Одна правка, которая превращает `a` в `b`: общие начало и конец не трогаем.
    static func difference(from a: String, to b: String) -> (range: NSRange, text: String) {
        let x = a as NSString, y = b as NSString
        var prefix = 0
        while prefix < min(x.length, y.length), x.character(at: prefix) == y.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(x.length, y.length) - prefix,
              x.character(at: x.length - 1 - suffix) == y.character(at: y.length - 1 - suffix) { suffix += 1 }
        return (NSRange(location: prefix, length: x.length - prefix - suffix),
                y.substring(with: NSRange(location: prefix, length: y.length - prefix - suffix)))
    }

    /// Строки текста — для показа куска.
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}
