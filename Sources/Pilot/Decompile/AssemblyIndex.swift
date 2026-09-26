import Foundation

/// Типы из сборок проекта — тех, к которым нет исходников.
///
/// Нужен там, где ответить больше нечем: `⌘B` на `Vector3`, пока Rustlyn
/// ещё компилирует проект, или без Rustlyn вовсе. Индекс отвечает и без
/// компиляции — объявлением из самой сборки.
///
/// Читаются только имена типов: таблица TypeDef и две строки на тип.
/// Полный разбор сборки в текст (`AssemblySource`) идёт потом и только для
/// той, которую открыли.
///
/// Имена лежат в одном непрерывном буфере, как в `TypeIndex` и `FileIndex`:
/// поиск бежит по нему без аллокаций на тип.
final class AssemblyIndex: @unchecked Sendable {   // неизменяем после построения

    struct Entry {
        /// Индекс сборки в `assemblies`.
        var assembly: Int32
        /// Имя без числа параметров: `Dictionary`, а не `Dictionary`2`.
        /// По нему и ищут: в коде тип пишут именно так.
        var name: String
        var namespace: String
        /// Сколько у типа параметров обобщения.
        var arity: Int

        var full: String { namespace.isEmpty ? name : namespace + "." + name }

        /// Как показать в списке: `Task` и `Task<>` — разные типы, и в
        /// выдаче они не должны выглядеть одной строкой дважды.
        var display: String {
            guard arity > 0 else { return name }
            return name + "<" + String(repeating: ",", count: arity - 1) + ">"
        }
    }

    private struct Span {
        var start: Int32
        var length: Int32
        var nameStart: Int32      // где в «Пространство.Имя» начинается имя
    }

    /// Сборки, в которых нашлись типы.
    private(set) var assemblies: [URL] = []
    /// Всё, что просили прочитать, — включая пустые и нечитаемые: по этому
    /// списку видно, что пересобирать индекс не из-за чего.
    private(set) var sources: [URL] = []
    private(set) var entries: [Entry] = []
    private var bytes: [UInt8] = []
    private var spans: [Span] = []
    /// Точное имя типа → его объявления: так отвечают на ⌘B.
    private var byName: [String: [Int32]] = [:]

    var count: Int { entries.count }
    var assemblyCount: Int { assemblies.count }

    func entry(_ id: Int32) -> Entry { entries[Int(id)] }

    func assembly(_ id: Int32) -> URL { assemblies[Int(entries[Int(id)].assembly)] }

    /// Куда прыгать: сборка целиком и имя типа в ней. Строки в тексте ещё
    /// нет — он собирается при открытии, и объявление ищется уже по нему.
    func target(_ id: Int32) -> NavTarget {
        NavTarget(url: assembly(id), range: nil, declaration: entries[Int(id)].name)
    }

    func declaration(_ id: Int32) -> FoundDeclaration {
        let entry = entries[Int(id)]
        return FoundDeclaration(target: target(id), name: entry.display, kind: .type,
                                container: entry.namespace.isEmpty ? nil : entry.namespace,
                                path: assembly(id).lastPathComponent)
    }

    /// Объявления типа с таким именем. Регистр важен — как и в C#.
    func matching(name: String) -> [Int32] { byName[name] ?? [] }

    // MARK: - Построение

    // MARK: - Кэш на диске

    /// Сначала все исходные сборки (по ним видно, что пересобирать нечего),
    /// потом сборки с типами, потом типы: `сборка<TAB>пространство<TAB>имя<TAB>арность`.
    func serialized() -> String {
        var out = "assemblies 1\n\(sources.count)\n"
        for url in sources { out += url.path + "\n" }
        out += "\(assemblies.count)\n"
        for url in assemblies { out += url.path + "\n" }
        for entry in entries {
            out += "\(entry.assembly)\t\(entry.namespace)\t\(entry.name)\t\(entry.arity)\n"
        }
        return out
    }

    /// `nil` — не тот формат или файл испорчен.
    static func deserialize(_ text: String) -> AssemblyIndex? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.popFirst() == "assemblies 1" else { return nil }
        let index = AssemblyIndex()
        func paths() -> [URL]? {
            guard let line = lines.popFirst(), let count = Int(line), count >= 0,
                  lines.count >= count else { return nil }
            let taken = lines.prefix(count).map { URL(fileURLWithPath: String($0)) }
            lines = lines.dropFirst(count)
            return taken
        }
        guard let sources = paths(), let assemblies = paths() else { return nil }
        index.sources = sources
        index.assemblies = assemblies
        for line in lines where !line.isEmpty {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4, let assembly = Int32(parts[0]), let arity = Int(parts[3]),
                  assembly >= 0, Int(assembly) < assemblies.count else { return nil }
            index.append(name: String(parts[2]), arity: arity, namespace: String(parts[1]),
                         assembly: assembly)
        }
        return index
    }

    /// Синхронно и по одной сборке — вызывать вне главного потока.
    /// Порядок важен: при одинаковых именах первой идёт сборка из списка
    /// раньше, а списком распоряжается тот, кто его собрал.
    ///
    /// `base` — индекс прошлого раза, собранный начиная с `since`: сборка,
    /// не менявшаяся с тех пор, не читается — её типы переносятся оттуда.
    static func build(assemblies: [URL], reusing base: AssemblyIndex? = nil, since: Date? = nil,
                      shouldStop: () -> Bool = { false }) -> AssemblyIndex {
        let index = AssemblyIndex()
        index.sources = assemblies
        // Прошлые типы по сборке: сборки из `sources`, в которых типов не
        // нашлось, тоже известны — пустыми.
        var previous: [String: [Entry]] = [:]
        if let base, since != nil {
            for url in base.sources { previous[url.path] = [] }
            for entry in base.entries {
                previous[base.assemblies[Int(entry.assembly)].path, default: []].append(entry)
            }
        }
        let cutoff = (since?.timeIntervalSince1970 ?? 0) - 2
        // Одна и та же сборка попадается дважды: копия плагина в кэше
        // пакетов, две версии рядом. Считаем сборку по имени файла: второй
        // раз те же типы в выдаче только мешают.
        var seen = Set<String>()
        for url in assemblies {
            if shouldStop() { break }
            guard seen.insert(url.lastPathComponent).inserted else { continue }
            if let known = previous[url.path], modified(url) < cutoff {
                index.append(copies: known, of: url)
            } else {
                index.append(url)
            }
        }
        return index
    }

    private static func modified(_ url: URL) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? .infinity
    }

    /// Типы сборки из прошлого индекса, как если бы их прочли заново.
    private func append(copies entries: [Entry], of url: URL) {
        guard !entries.isEmpty else { return }
        let assembly = Int32(assemblies.count)
        assemblies.append(url)
        for entry in entries {
            append(name: entry.name, arity: entry.arity, namespace: entry.namespace, assembly: assembly)
        }
    }

    private func append(_ url: URL) {
        guard let metadata = try? AssemblyMetadata(url: url) else { return }
        let count = metadata.rowCount(.typeDef)
        guard count > 0 else { return }

        // Вложенные типы в индекс не идут: их находят через внешний, а в
        // выдаче `⇧⇧` они были бы сотнями одинаковых `Enumerator`.
        var nested = Set<Int>()
        for row in 1..<(metadata.rowCount(.nestedClass) + 1) {
            nested.insert(Int(metadata.cell(.nestedClass, row, 0)))
        }

        let assembly = Int32(assemblies.count)
        var added = false
        for row in 1..<(count + 1) where !nested.contains(row) {
            let raw = metadata.string(.typeDef, row, 1)
            // `<Module>`, замыкания, итераторы — то, чего в исходниках не писали.
            guard !raw.isEmpty, !raw.contains("<"), !raw.contains(">") else { continue }
            if !added {
                assemblies.append(url)
                added = true
            }
            append(name: TypeName.withoutArity(raw), arity: TypeName.arity(raw),
                   namespace: metadata.string(.typeDef, row, 2), assembly: assembly)
        }
    }

    private func append(name: String, arity: Int, namespace: String, assembly: Int32) {
        let id = Int32(entries.count)
        let start = bytes.count
        for byte in namespace.utf8 { bytes.append(lowercased(byte)) }
        if !namespace.isEmpty { bytes.append(0x2E) }
        let nameStart = bytes.count - start
        for byte in name.utf8 { bytes.append(lowercased(byte)) }
        spans.append(Span(start: Int32(start), length: Int32(bytes.count - start),
                          nameStart: Int32(nameStart)))
        entries.append(Entry(assembly: assembly, name: name, namespace: namespace, arity: arity))
        byName[name, default: []].append(id)
    }

    @inline(__always)
    private func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 32 : byte
    }

    // MARK: - Поиск

    /// До `limit` лучших типов — тем же нечётким поиском, что у `⌘P` и `⇧⇧`.
    /// Запрос с точкой матчится по полному имени с пространством имён,
    /// без точки — только по имени.
    func search(_ queryString: String, limit: Int, shouldStop: () -> Bool) -> [SearchHit] {
        let q = FuzzyMatch.Query(queryString)
        guard !q.isEmpty else { return [] }
        let qualified = q.lower.contains(0x2E)

        var results: [SearchHit] = []
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var positions: [Int32]? = []

            for i in 0..<spans.count {
                if i & 0x3FF == 0 && shouldStop() { return }
                let span = spans[i]
                let skip = qualified ? 0 : Int(span.nameStart)
                let pointer = base + Int(span.start) + skip
                let length = Int(span.length) - skip
                guard FuzzyMatch.firstPass(q, pointer, length) != nil,
                      let score = FuzzyMatch.score(q, text: pointer, len: length,
                                                   nameStart: Int(span.nameStart) - skip,
                                                   positions: &positions) else { continue }
                let shift = Int32(Int(span.nameStart) - skip)
                let inName = (positions ?? []).compactMap { $0 >= shift ? $0 - shift : nil }
                results.append(SearchHit(id: Int32(i), score: score, positions: inName))
            }
        }
        if shouldStop() { return [] }

        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return spans[Int($0.id)].length < spans[Int($1.id)].length
        }
        if results.count > limit { results.removeSubrange(limit...) }
        return results
    }
}
