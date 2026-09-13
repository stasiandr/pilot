import Foundation

/// GUID → ассет и обратно.
///
/// Всё, что Unity сериализует — сцены, префабы, материалы, — ссылается на
/// другие ассеты только по GUID из их `.meta`. Без этой таблицы
/// `{fileID: 11500000, guid: a79441f3…}` — просто шум; с ней — ссылка на
/// конкретный скрипт.
///
/// Строится фоном из всех `.meta` в `Assets/`, `Packages/` и
/// `Library/PackageCache/` — последняя нужна, чтобы резолвились скрипты
/// и ресурсы пакетов. Обход идёт мимо `.gitignore`: игнорируемый в git
/// ассет на диске всё равно есть, и ссылки на него настоящие.
final class UnityAssetIndex: @unchecked Sendable {   // неизменяем после init

    /// Пути относительно корня проекта.
    private let pathByGUID: [UnityGUID: String]
    private let guidByPath: [String: UnityGUID]
    /// Скрипты по имени файла: `Team` → `Assets/Scripts/Team.cs`. Так
    /// находится enum, объявленный в своём файле.
    private let scriptByName: [String: String]

    var count: Int { pathByGUID.count }

    /// Порядок важен: при совпадении GUID выигрывает первый. Ассет проекта
    /// важнее пакета, встроенный пакет — важнее копии в кэше.
    init(entries: [(UnityGUID, String)]) {
        var byGUID: [UnityGUID: String] = [:]
        var byPath: [String: UnityGUID] = [:]
        var scripts: [String: String] = [:]
        byGUID.reserveCapacity(entries.count)
        byPath.reserveCapacity(entries.count)
        for (guid, path) in entries {
            if byGUID[guid] == nil { byGUID[guid] = path }
            byPath[path] = guid
            if path.hasSuffix(".cs") {
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                if scripts[name] == nil { scripts[name] = path }
            }
        }
        pathByGUID = byGUID
        guidByPath = byPath
        scriptByName = scripts
    }

    func path(for guid: UnityGUID) -> String? { pathByGUID[guid] }

    func guid(forAsset relPath: String) -> UnityGUID? { guidByPath[relPath] }

    func scriptPath(named name: String) -> String? { scriptByName[name] }

    /// Имя, под которым ассет виден в Unity, — имя файла без расширения.
    /// Для скрипта это заодно и имя класса: Unity требует, чтобы они совпадали.
    func displayName(for guid: UnityGUID) -> String? {
        guard let path = pathByGUID[guid] else { return nil }
        let name = (path as NSString).lastPathComponent
        return (name as NSString).deletingPathExtension
    }

    // MARK: - Сборка

    /// Где искать `.meta`, в порядке приоритета.
    static let searchRoots = ["Assets", "Packages", "Library/PackageCache"]

    /// Синхронно — вызывать вне главного потока.
    static func build(root: URL, shouldStop: () -> Bool = { false }) -> UnityAssetIndex {
        var metaPaths: [String] = []
        for base in searchRoots {
            if shouldStop() { break }
            collectMetaFiles(under: root.appendingPathComponent(base).path,
                             relativeTo: root.path, into: &metaPaths)
        }
        if shouldStop() { return UnityAssetIndex(entries: []) }

        // Чтение тысяч мелких файлов упирается в системные вызовы, а не в
        // диск, поэтому параллелится почти линейно.
        let rootPath = root.path
        let chunk = 256
        let chunkCount = (metaPaths.count + chunk - 1) / chunk
        var parts = [[(UnityGUID, String)]](repeating: [], count: chunkCount)
        parts.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                var local: [(UnityGUID, String)] = []
                local.reserveCapacity(chunk)
                for k in (c * chunk)..<min(metaPaths.count, (c + 1) * chunk) {
                    let meta = metaPaths[k]
                    guard let guid = readGUID(metaFile: rootPath + "/" + meta) else { continue }
                    local.append((guid, String(meta.dropLast(5))))   // без ".meta"
                }
                out[c] = local
            }
        }
        return UnityAssetIndex(entries: parts.flatMap { $0 })
    }

    /// Все `.meta` в поддереве. `fts` вместо `FileManager.enumerator`: на
    /// кэше пакетов в десятки тысяч файлов он быстрее на порядок, потому что
    /// не заводит строку и не зовёт `stat` на каждый файл.
    ///
    /// Скрытые папки и папки с `~` на конце (`Samples~`, `Documentation~`)
    /// Unity не импортирует — не заходим в них и мы.
    private static func collectMetaFiles(under path: String, relativeTo root: String,
                                         into result: inout [String]) {
        guard let start = strdup(path) else { return }
        defer { free(start) }
        var paths: [UnsafeMutablePointer<CChar>?] = [start, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil) else { return }
        defer { fts_close(fts) }
        let prefixLength = root.utf8.count + 1

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            // Имя берём хвостом пути: так не нужно лезть в `fts_name`,
            // который в Swift виден как массив из одного символа.
            let path = UnsafeRawPointer(entry.pointee.fts_path).assumingMemoryBound(to: UInt8.self)
            let length = Int(entry.pointee.fts_pathlen)
            if info == FTS_D {
                let nameStart = Int(entry.pointee.fts_pathlen) - Int(entry.pointee.fts_namelen)
                if entry.pointee.fts_level > 0, length > nameStart,
                   path[nameStart] == 0x2E || path[length - 1] == 0x7E {
                    fts_set(fts, entry, FTS_SKIP)
                }
                continue
            }
            guard info == FTS_F || info == FTS_NSOK, length > prefixLength + 5,
                  path[length - 5] == 0x2E, path[length - 4] == 0x6D, path[length - 3] == 0x65,
                  path[length - 2] == 0x74, path[length - 1] == 0x61 else { continue }   // .meta
            let rel = UnsafeBufferPointer(start: path + prefixLength, count: length - prefixLength)
            result.append(String(decoding: rel, as: UTF8.self))
        }
    }

    /// GUID из `.meta`. Он всегда во второй строке, поэтому читаем
    /// только начало файла, а не весь импортёр целиком.
    static func readGUID(metaFile path: String) -> UnityGUID? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 256) }
        guard n > 0 else { return nil }
        return parseMeta(buffer[0..<n])
    }

    /// Ищет строку `guid: <32 hex>` в начале `.meta`.
    static func parseMeta(_ bytes: ArraySlice<UInt8>) -> UnityGUID? {
        let key: [UInt8] = Array("guid: ".utf8)
        let base = bytes.startIndex
        var lineStart = base
        while lineStart + key.count + 32 <= bytes.endIndex {
            var matches = true
            for k in 0..<key.count where bytes[lineStart + k] != key[k] { matches = false; break }
            if matches {
                let array = Array(bytes[(lineStart + key.count)...])
                return UnityGUID.parse(array, at: 0)
            }
            guard let newline = bytes[lineStart...].firstIndex(of: 0x0A) else { return nil }
            lineStart = newline + 1
        }
        return nil
    }
}
