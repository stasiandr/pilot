import Foundation

/// «Где используется этот ассет» — без Unity и без языкового сервера.
///
/// Любая ссылка на ассет в сериализованных файлах — это его GUID, поэтому
/// поиск сводится к поиску 32 байт по всем текстовым ассетам проекта.
/// `memmem` по отображённым в память файлам проходит сотни мегабайт сцен
/// и префабов за доли секунды; разбираются только файлы с попаданиями.
enum UnityUsages {

    struct Hit: Sendable, Equatable {
        var relPath: String
        /// Строка и колонка (UTF-16) — в координатах LSP.
        var line: Int
        var column: Int
        /// Где именно: `Canvas / Button › PlayerInput`. `nil` — если файл не сцена.
        var context: String?
    }

    /// Файлы, в которых Unity хранит ссылки на ассеты по GUID.
    /// Регистр не важен: сравниваем с расширением в нижнем регистре.
    static let searchableExtensions: Set<String> = [
        "unity", "prefab", "asset", "mat", "anim", "controller", "overridecontroller",
        "playable", "mask", "physicmaterial", "physicsmaterial2d", "mixer", "rendertexture",
        "lighting", "spriteatlas", "spriteatlasv2", "terrainlayer", "signal", "preset",
        "guiskin", "fontsettings", "flare", "brush", "cubemap", "giparams", "scenetemplate",
        "shadergraph", "shadersubgraph", "vfx", "vfxoperator", "vfxblock",
        "asmdef", "asmref", "uxml", "uss", "tss",
    ]

    static func isSearchable(_ relPath: String) -> Bool {
        searchableExtensions.contains((relPath as NSString).pathExtension.lowercased())
    }

    /// Файлы больше этого не разбираем ради контекста — только номер строки.
    static let maxContextBytes = 64 * 1024 * 1024

    /// Синхронно и параллельно — вызывать вне главного потока.
    ///
    /// Несколько попаданий внутри одного объекта сворачиваются в одно:
    /// вложенный префаб упоминает GUID своего источника в каждой из
    /// десятков переопределённых строк, а интересен сам факт вставки.
    static func find(guid: UnityGUID, root: URL, paths: [String],
                     resolve: @escaping @Sendable (UnityGUID) -> String?,
                     shouldStop: @escaping @Sendable () -> Bool = { false }) -> [Hit] {
        let needle = guid.asciiBytes
        let candidates = paths.filter(isSearchable)
        var perFile = [[Hit]](repeating: [], count: candidates.count)

        perFile.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: candidates.count) { k in
                if shouldStop() { return }
                let rel = candidates[k]
                let url = root.appendingPathComponent(rel)
                guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
                out[k] = data.withUnsafeBytes { bytes in
                    hits(in: bytes, needle: needle, relPath: rel, resolve: resolve)
                }
            }
        }
        return perFile.flatMap { $0 }
    }

    static func hits(in bytes: UnsafeRawBufferPointer, needle: [UInt8], relPath: String,
                     resolve: (UnityGUID) -> String?) -> [Hit] {
        let offsets = occurrences(of: needle, in: bytes)
        guard !offsets.isEmpty else { return [] }

        // Номера строк — одним проходом по файлу, попадания отсортированы.
        var positions: [(line: Int, lineStart: Int, offset: Int)] = []
        positions.reserveCapacity(offsets.count)
        var line = 0, lineStart = 0, cursor = 0
        for offset in offsets {
            while cursor < offset {
                if bytes[cursor] == 0x0A { line += 1; lineStart = cursor + 1 }
                cursor += 1
            }
            positions.append((line, lineStart, offset))
        }

        // Контекст — только для сериализованных файлов Unity.
        var file: UnityYAMLFile? = nil
        if bytes.count <= maxContextBytes, bytes.count >= 7,
           bytes.starts(with: Array("%YAML".utf8)) || containsHeader(bytes) {
            let text = String(decoding: bytes, as: UTF8.self)
            file = UnityYAMLFile.parse(Array(text.utf16))
        }

        var result: [Hit] = []
        var seenObjects = Set<Int>()
        for p in positions {
            var context: String? = nil
            if let file, let index = file.objectIndex(containingLine: p.line) {
                guard seenObjects.insert(index).inserted else { continue }
                context = file.describe(objectAt: index, resolve: resolve)
            }
            let prefix = UnsafeRawBufferPointer(rebasing: bytes[p.lineStart..<p.offset])
            let column = String(decoding: prefix, as: UTF8.self).utf16.count
            result.append(Hit(relPath: relPath, line: p.line, column: column, context: context))
        }
        return result
    }

    private static func containsHeader(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let probe = UnsafeRawBufferPointer(rebasing: bytes[0..<min(bytes.count, 512)])
        return !occurrences(of: Array("--- !u!".utf8), in: probe).isEmpty
    }

    /// Все вхождения `needle` — через `memmem`, он векторизован в libc.
    static func occurrences(of needle: [UInt8], in bytes: UnsafeRawBufferPointer) -> [Int] {
        guard let base = bytes.baseAddress, !needle.isEmpty, bytes.count >= needle.count else { return [] }
        var result: [Int] = []
        var offset = 0
        needle.withUnsafeBytes { n in
            while offset + needle.count <= bytes.count {
                guard let found = memmem(base + offset, bytes.count - offset,
                                         n.baseAddress, needle.count) else { break }
                let position = base.distance(to: UnsafeRawPointer(found))
                result.append(position)
                offset = position + needle.count
            }
        }
        return result
    }
}
