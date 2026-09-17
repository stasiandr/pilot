import Foundation

/// Типы из сборок проекта — тех, к которым нет исходников.
///
/// Нужен там, где ответить больше нечем: `⌘B` на `Vector3` в только что
/// склонированном Unity-проекте, где `.csproj` ещё не сгенерированы, а
/// значит, языковому серверу нечего грузить. Индекс отвечает и без него —
/// объявлением из самой сборки.
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

    /// Синхронно и по одной сборке — вызывать вне главного потока.
    /// Порядок важен: при одинаковых именах первой идёт сборка из списка
    /// раньше, а списком распоряжается тот, кто его собрал.
    static func build(assemblies: [URL], shouldStop: () -> Bool = { false }) -> AssemblyIndex {
        let index = AssemblyIndex()
        index.sources = assemblies
        // Одна и та же сборка попадается дважды: копия плагина в кэше
        // пакетов, две версии рядом. Считаем сборку по имени файла: второй
        // раз те же типы в выдаче только мешают.
        var seen = Set<String>()
        for url in assemblies {
            if shouldStop() { break }
            guard seen.insert(url.lastPathComponent).inserted else { continue }
            index.append(url)
        }
        return index
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
