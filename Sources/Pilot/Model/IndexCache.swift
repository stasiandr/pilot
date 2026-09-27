import Foundation

// MARK: - Кэш индекса на диске

/// Кэш — просто список относительных путей, по одному на строку. Читается
/// за десятки миллисекунд даже на 100k файлов, поэтому повторный запуск
/// не ждёт обхода файловой системы.
///
/// Рядом, с тем же хэшем корня, — объявления и типы, типы сборок и GUID
/// Unity. Каждый файл — свой вид кэша (`CacheKind`), и выключенный вид
/// здесь не пишется и не читается: все, кто зовёт, уже умеют без кэша —
/// так проект открывается впервые.
enum IndexCache {

    /// Где лежат файлы. Тесты подставляют свою папку.
    nonisolated(unsafe) static var locations = CacheStore.Locations.standard

    /// Файл кэша, если его вид хранится. Выключенный — nil: и запись, и
    /// чтение проходят мимо, даже если на диске осталось прежнее, — оно
    /// больше не обновляется, и показывать по нему было бы всё более старое.
    private static func fileURL(root: URL, extension ext: String = "idx") -> URL? {
        guard let kind = CacheKind.ofIndexFile(extension: ext), CachePolicy.current.stores(kind) else { return nil }
        try? FileManager.default.createDirectory(at: locations.caches, withIntermediateDirectories: true)
        return locations.indexFile(root: root, extension: ext)
    }

    static func save(_ index: FileIndex, root: URL) {
        guard let url = fileURL(root: root) else { return }
        let payload = index.display.joined(separator: "\n")
        try? payload.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func load(root: URL, exclude: ((String, Bool) -> Bool)? = nil) -> FileIndex? {
        guard let url = fileURL(root: root),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }

        let index = FileIndex(root: root)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let rel = String(line)
            if let exclude, exclude(rel, false) { continue }
            index.appendCached(rel: rel)
        }
        return index.count > 0 ? index : nil
    }

    // Типы лежат рядом, в соседнем файле с тем же хэшем.

    static func saveTypes(_ index: TypeIndex, root: URL) {
        guard let url = fileURL(root: root, extension: "types") else { return }
        try? index.serialized().data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func loadTypes(root: URL) -> TypeIndex? {
        guard let url = fileURL(root: root, extension: "types"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return TypeIndex.deserialize(text, root: root)
    }

    static func saveAssemblies(_ index: AssemblyIndex, root: URL, builtFrom: Date) {
        guard let url = fileURL(root: root, extension: "assemblies") else { return }
        try? index.serialized().data(using: .utf8)?.write(to: url, options: .atomic)
        stamp(url, builtFrom)
    }

    static func loadAssemblies(root: URL) -> (index: AssemblyIndex, builtAt: Date?)? {
        guard let url = fileURL(root: root, extension: "assemblies"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let index = AssemblyIndex.deserialize(text) else { return nil }
        return (index, modified(url))
    }

    /// Индекс GUID Unity — по корню Unity-проекта, а не открытой папки:
    /// это один и тот же индекс, откуда бы проект ни открыли.
    ///
    /// `builtFrom` — когда начали читать файлы, по которым он собран: это
    /// время ставится файлу кэша, и следующий запуск перечитывает только то,
    /// что менялось после него (`builtAt`).
    static func saveAssets(_ index: UnityAssetIndex, root: URL, builtFrom: Date) {
        guard let url = fileURL(root: root, extension: "unity") else { return }
        try? index.serialized().data(using: .utf8)?.write(to: url, options: .atomic)
        stamp(url, builtFrom)
    }

    /// Обход не нашёл ничего нового: содержимое кэша верно, сдвигается
    /// только его метка — иначе `.meta`, тронутые без смены GUID (настройки
    /// импорта), перечитывались бы при каждом открытии.
    static func restampAssets(root: URL, builtFrom: Date) {
        guard let url = fileURL(root: root, extension: "unity") else { return }
        stamp(url, builtFrom)
    }

    static func loadAssets(root: URL) -> (index: UnityAssetIndex, builtAt: Date?)? {
        guard let url = fileURL(root: root, extension: "unity"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let index = UnityAssetIndex.deserialize(text) else { return nil }
        return (index, modified(url))
    }

    /// Файл кэша помечен временем начала сборки, а не записи: что поменялось,
    /// пока шла сборка, могло в неё не попасть, и в следующий раз его надо
    /// перечитать.
    private static func stamp(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func saveSymbols(_ index: SymbolIndex, root: URL, builtFrom: Date) {
        guard let url = fileURL(root: root, extension: "symbols") else { return }
        try? index.serialized().data(using: .utf8)?.write(to: url, options: .atomic)
        stamp(url, builtFrom)
    }

    static func loadSymbols(root: URL) -> (index: SymbolIndex, builtAt: Date?)? {
        guard let url = fileURL(root: root, extension: "symbols"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let index = SymbolIndex.deserialize(text, root: root) else { return nil }
        return (index, modified(url))
    }
}
