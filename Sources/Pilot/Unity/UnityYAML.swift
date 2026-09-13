import Foundation

/// Один объект сериализованного файла Unity: блок от `--- !u!<класс> &<fileID>`
/// до следующего такого заголовка.
struct UnityObject: Sendable {
    /// Числовой ID класса Unity: 1 — GameObject, 4 — Transform, 114 — MonoBehaviour…
    var classID: Int
    var fileID: Int64
    /// Заглушка объекта из вложенного префаба: сам объект живёт в префабе,
    /// здесь только ссылка на него.
    var stripped: Bool
    /// Где начинается блок (UTF-16) и в какой строке.
    var start: Int
    var startLine: Int
    var typeName: String = ""
    /// Имя типа в начале блока — сюда ведут переходы.
    var typeNameRange: NSRange
    var typeNameLine: Int
    var name: String?
    var nameRange: NSRange?
    var nameLine: Int?
    /// `m_GameObject` — владелец компонента.
    var gameObject: Int64?
    /// `m_Father` — есть только у Transform и RectTransform.
    var father: Int64?
    /// `m_PrefabInstance` — у заглушек вложенного префаба.
    var prefabInstance: Int64?
    /// `m_TransformParent` у PrefabInstance — куда в иерархии он вставлен.
    var transformParent: Int64?
    /// `m_Script` у MonoBehaviour.
    var script: UnityGUID?
    /// `m_SourcePrefab` у PrefabInstance.
    var sourcePrefab: UnityGUID?
    /// Переопределённое в сцене `m_Name` вложенного префаба.
    var modifiedName: String?
    /// `Сборка::Пространство.Класс` — Unity 6 пишет его у MonoBehaviour.
    var editorClassIdentifier: String?

    var isGameObject: Bool { classID == 1 }
    var isPrefabInstance: Bool { classID == 1001 }
}

/// Ссылка в сериализованном файле.
enum UnityReference: Equatable {
    /// `{fileID: N}` — объект в этом же файле.
    case local(fileID: Int64)
    /// `{fileID: N, guid: G, type: T}` — другой ассет (и, возможно, объект в нём).
    case asset(guid: UnityGUID, fileID: Int64?)
}

/// Разбор текстового формата сериализации Unity (`.unity`, `.prefab`,
/// `.asset`, `.mat`, `.controller`…).
///
/// Это не YAML-парсер: формат у Unity жёсткий, и хватает построчного
/// прохода, который смотрит только на ключи верхнего уровня объекта.
/// Сцена на сотни тысяч строк разбирается за десятки миллисекунд.
final class UnityYAMLFile: @unchecked Sendable {   // неизменяем после init
    let objects: [UnityObject]
    private let indexByFileID: [Int64: Int]
    /// GameObject → его Transform: по нему идём вверх по иерархии.
    private let transformByGameObject: [Int64: Int64]

    init(objects: [UnityObject]) {
        self.objects = objects
        var byID: [Int64: Int] = [:]
        var transforms: [Int64: Int64] = [:]
        byID.reserveCapacity(objects.count)
        for (i, object) in objects.enumerated() {
            byID[object.fileID] = i
            if object.father != nil, !object.stripped, let go = object.gameObject {
                transforms[go] = object.fileID
            }
        }
        indexByFileID = byID
        transformByGameObject = transforms
    }

    func object(_ fileID: Int64) -> UnityObject? {
        indexByFileID[fileID].map { objects[$0] }
    }

    func index(ofFileID fileID: Int64) -> Int? { indexByFileID[fileID] }

    /// Объект, внутри блока которого лежит смещение.
    func objectIndex(containing offset: Int) -> Int? {
        lastIndex(where: { $0.start <= offset })
    }

    func objectIndex(containingLine line: Int) -> Int? {
        lastIndex(where: { $0.startLine <= line })
    }

    private func lastIndex(where predicate: (UnityObject) -> Bool) -> Int? {
        var lo = 0, hi = objects.count - 1, found: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if predicate(objects[mid]) { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    // MARK: - Иерархия

    typealias Resolver = (UnityGUID) -> String?

    /// Путь GameObject'а от корня сцены: `["Canvas", "Panel", "Button"]`.
    /// `resolve` даёт имя ассета по GUID — им называются вложенные префабы,
    /// которым в сцене имя не переопределяли.
    func path(ofGameObject id: Int64, resolve: Resolver = { _ in nil }) -> [String] {
        gameObjectPath(id, resolve, budget: 128)
    }

    /// Путь вложенного префаба, включая его самого.
    func path(ofPrefabInstance id: Int64, resolve: Resolver = { _ in nil }) -> [String] {
        prefabInstancePath(id, resolve, budget: 128)
    }

    /// `budget` страхует от циклов в битом файле.
    private func gameObjectPath(_ id: Int64, _ resolve: Resolver, budget: Int) -> [String] {
        guard budget > 0, let go = object(id) else { return [] }
        if go.stripped, let instance = go.prefabInstance {
            return prefabInstancePath(instance, resolve, budget: budget - 1)
        }
        let name = go.name ?? "GameObject"
        guard let transform = transformByGameObject[id],
              let father = object(transform)?.father, father != 0 else { return [name] }
        return transformPath(father, resolve, budget: budget - 1) + [name]
    }

    private func transformPath(_ id: Int64, _ resolve: Resolver, budget: Int) -> [String] {
        guard budget > 0, let transform = object(id) else { return [] }
        if transform.stripped, let instance = transform.prefabInstance {
            return prefabInstancePath(instance, resolve, budget: budget - 1)
        }
        guard let go = transform.gameObject else { return [] }
        return gameObjectPath(go, resolve, budget: budget - 1)
    }

    private func prefabInstancePath(_ id: Int64, _ resolve: Resolver, budget: Int) -> [String] {
        guard budget > 0, let instance = object(id) else { return [] }
        let name = displayName(of: instance, resolve: resolve)
        guard let parent = instance.transformParent, parent != 0 else { return [name] }
        return transformPath(parent, resolve, budget: budget - 1) + [name]
    }

    // MARK: - Имена

    /// Как объект называется для человека: имя скрипта для MonoBehaviour,
    /// имя исходного префаба для вложенного префаба, иначе — тип.
    func displayName(of object: UnityObject, resolve: Resolver) -> String {
        if object.isPrefabInstance {
            return object.modifiedName ?? object.sourcePrefab.flatMap(resolve) ?? "Prefab"
        }
        if object.isGameObject { return object.name ?? "GameObject" }
        return componentName(of: object, resolve: resolve)
    }

    func componentName(of object: UnityObject, resolve: Resolver) -> String {
        if let script = object.script {
            if let name = resolve(script) { return name }
            if let name = Self.className(fromEditorIdentifier: object.editorClassIdentifier) { return name }
        }
        return object.typeName.isEmpty ? "Object" : object.typeName
    }

    /// `Unity.RenderPipelines.Universal.Runtime::UnityEngine.Rendering.Universal.UniversalAdditionalCameraData`
    /// → `UniversalAdditionalCameraData`.
    static func className(fromEditorIdentifier identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        var id = Substring(identifier)
        if let range = id.range(of: "::") { id = id[range.upperBound...] }
        if let dot = id.lastIndex(of: ".") { id = id[id.index(after: dot)...] }
        return id.isEmpty ? nil : String(id)
    }

    /// Человеческое описание объекта: `Canvas / Button › Image`.
    func describe(objectAt index: Int, resolve: Resolver) -> String {
        let object = objects[index]
        if object.isGameObject {
            return gameObjectPath(object.fileID, resolve, budget: 128).joined(separator: " / ")
        }
        if object.isPrefabInstance {
            return prefabInstancePath(object.fileID, resolve, budget: 128).joined(separator: " / ")
        }
        let component = componentName(of: object, resolve: resolve)
        if let go = object.gameObject, go != 0 {
            let path = gameObjectPath(go, resolve, budget: 128)
            if !path.isEmpty { return path.joined(separator: " / ") + " › " + component }
        }
        if let name = object.name, name != component { return "\(component) «\(name)»" }
        return component
    }

    // MARK: - Структура для ⌘⇧O

    /// GameObject'ы, их компоненты и вложенные префабы — в порядке файла.
    /// Контейнер — путь в иерархии, поэтому хлебные крошки показывают
    /// `Canvas / Panel › Image`, а не голый номер строки.
    func outline(resolve: Resolver) -> [OutlineItem] {
        var items: [OutlineItem] = []
        items.reserveCapacity(objects.count)
        func add(_ name: String, _ kind: OutlineKind, _ range: NSRange, _ line: Int,
                 _ path: [String]) {
            items.append(OutlineItem(
                id: items.count, name: name, kind: kind, range: range, line: line,
                depth: path.count,
                container: path.isEmpty ? nil : path.joined(separator: " / ")))
        }

        for object in objects where !object.stripped {
            if object.isGameObject {
                let path = gameObjectPath(object.fileID, resolve, budget: 128)
                add(path.last ?? "GameObject", .gameObject,
                    object.nameRange ?? object.typeNameRange,
                    object.nameLine ?? object.typeNameLine, Array(path.dropLast()))
            } else if object.isPrefabInstance {
                let path = prefabInstancePath(object.fileID, resolve, budget: 128)
                add(path.last ?? "Prefab", .prefab, object.typeNameRange, object.typeNameLine,
                    Array(path.dropLast()))
            } else if let go = object.gameObject, go != 0 {
                add(componentName(of: object, resolve: resolve), .component,
                    object.typeNameRange, object.typeNameLine, gameObjectPath(go, resolve, budget: 128))
            } else {
                // Самостоятельный объект ассета: материал, клип, состояние
                // аниматора, ScriptableObject, настройки сцены.
                let type = componentName(of: object, resolve: resolve)
                if let name = object.name, !name.isEmpty {
                    add(name, .component, object.nameRange ?? object.typeNameRange,
                        object.nameLine ?? object.typeNameLine, [type])
                } else {
                    add(type, .component, object.typeNameRange, object.typeNameLine, [])
                }
            }
        }
        return items
    }

    // MARK: - Разбор

    /// `nil`, если это не сериализованный файл Unity (нет ни одного `--- !u!`).
    static func parse(_ units: [UInt16]) -> UnityYAMLFile? {
        units.withUnsafeBufferPointer { parse($0) }
    }

    static func parse(_ u: UnsafeBufferPointer<UInt16>) -> UnityYAMLFile? {
        let n = u.count
        var objects: [UnityObject] = []
        var current: UnityObject?
        var expectTypeName = false
        var nameModificationPending = false
        var lineNumber = 0
        var i = 0

        while i < n {
            let lineStart = i
            var lineEnd = i
            while lineEnd < n && u[lineEnd] != 0x0A { lineEnd += 1 }
            var end = lineEnd
            if end > lineStart && u[end - 1] == 0x0D { end -= 1 }
            defer {
                i = lineEnd + 1
                lineNumber += 1
            }

            if hasPrefix(u, lineStart, end, "--- !u!") {
                if let done = current { objects.append(done) }
                current = parseHeader(u, lineStart, end, line: lineNumber)
                expectTypeName = current != nil
                nameModificationPending = false
                continue
            }
            guard current != nil else { continue }

            if expectTypeName {
                expectTypeName = false
                var j = lineStart
                while j < end && u[j] != 0x3A { j += 1 }
                if j < end, j > lineStart, u[lineStart] != 0x20 {
                    current!.typeName = string(u, lineStart, j)
                    current!.typeNameRange = NSRange(location: lineStart, length: j - lineStart)
                    current!.typeNameLine = lineNumber
                }
                continue
            }

            var indent = 0
            while lineStart + indent < end && u[lineStart + indent] == 0x20 { indent += 1 }
            let k = lineStart + indent

            if nameModificationPending {
                nameModificationPending = false
                if indent == 6, hasPrefix(u, k, end, "value: "), current!.modifiedName == nil {
                    let value = scalar(u, k + 7, end)
                    if !value.isEmpty { current!.modifiedName = value }
                }
                continue
            }

            switch indent {
            case 2:
                if hasPrefix(u, k, end, "m_Name: ") || (end - k == 7 && hasPrefix(u, k, end, "m_Name:")) {
                    let valueStart = min(k + 8, end)
                    let value = scalar(u, valueStart, end)
                    if !value.isEmpty {
                        current!.name = value
                        current!.nameRange = NSRange(location: valueStart, length: end - valueStart)
                        current!.nameLine = lineNumber
                    }
                } else if hasPrefix(u, k, end, "m_GameObject: ") {
                    current!.gameObject = reference(u, k, end)?.fileID
                } else if hasPrefix(u, k, end, "m_Father: ") {
                    current!.father = reference(u, k, end)?.fileID
                } else if hasPrefix(u, k, end, "m_PrefabInstance: ") {
                    current!.prefabInstance = reference(u, k, end)?.fileID
                } else if hasPrefix(u, k, end, "m_Script: ") {
                    current!.script = reference(u, k, end)?.guid
                } else if hasPrefix(u, k, end, "m_SourcePrefab: ") {
                    current!.sourcePrefab = reference(u, k, end)?.guid
                } else if hasPrefix(u, k, end, "m_EditorClassIdentifier: ") {
                    let value = scalar(u, k + 25, end)
                    if !value.isEmpty { current!.editorClassIdentifier = value }
                }
            case 4:
                if hasPrefix(u, k, end, "m_TransformParent: ") {
                    current!.transformParent = reference(u, k, end)?.fileID
                }
            case 6:
                if end - k == 20, hasPrefix(u, k, end, "propertyPath: m_Name") {
                    nameModificationPending = true
                }
            default:
                break
            }
        }
        if let done = current { objects.append(done) }
        return objects.isEmpty ? nil : UnityYAMLFile(objects: objects)
    }

    /// `--- !u!114 &4862123940720277325` или `--- !u!224 &-12345 stripped`.
    private static func parseHeader(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int,
                                     line: Int) -> UnityObject? {
        var j = start + 7
        var classID = 0
        while j < end, u[j] >= 0x30, u[j] <= 0x39 {
            classID = classID &* 10 &+ Int(u[j] - 0x30)
            j += 1
        }
        while j < end, u[j] == 0x20 { j += 1 }
        guard j < end, u[j] == 0x26 else { return nil }   // &
        guard let (fileID, after) = signedInteger(u, j + 1, end) else { return nil }
        let stripped = hasPrefix(u, after, end, " stripped")
        let headerRange = NSRange(location: start, length: end - start)
        return UnityObject(classID: classID, fileID: fileID, stripped: stripped,
                           start: start, startLine: line,
                           typeNameRange: headerRange, typeNameLine: line)
    }

    // MARK: - Ссылки

    /// Ссылка `{fileID: …, guid: …}` в строке `start..<end`.
    static func reference(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int)
        -> (fileID: Int64?, guid: UnityGUID?)? {
        guard let open = find(u, start, end, "{") else { return nil }
        let close = find(u, open, end, "}") ?? end
        var fileID: Int64? = nil
        var guid: UnityGUID? = nil
        if let key = find(u, open, close, "fileID: ") {
            fileID = signedInteger(u, key + 8, close)?.value
        }
        if let key = find(u, open, close, "guid: ") {
            guid = UnityGUID.parse(u, at: key + 6)
        }
        if fileID == nil && guid == nil { return nil }
        return (fileID, guid)
    }

    /// Ссылка под курсором. Если курсор не внутри фигурных скобок, но в
    /// строке ровно одна ссылка — берём её: на `m_Script:` удобно
    /// нажимать ⌘B, не целясь в сам GUID.
    static func reference(in units: [UInt16], line: Range<Int>, at offset: Int)
        -> (reference: UnityReference, range: NSRange)? {
        units.withUnsafeBufferPointer { u in
            var end = min(line.upperBound, u.count)
            while end > line.lowerBound, u[end - 1] == 0x0A || u[end - 1] == 0x0D { end -= 1 }

            var spans: [(open: Int, close: Int)] = []
            var j = line.lowerBound
            while let open = find(u, j, end, "{") {
                let close = find(u, open, end, "}") ?? end - 1
                spans.append((open, close))
                j = close + 1
            }

            let chosen = spans.first { offset >= $0.open && offset <= $0.close + 1 }
                ?? (spans.count == 1 ? spans[0] : nil)
            if let span = chosen, let parsed = reference(u, span.open, span.close + 1) {
                let range = NSRange(location: span.open, length: span.close + 1 - span.open)
                if let guid = parsed.guid {
                    return (.asset(guid: guid, fileID: parsed.fileID), range)
                }
                if let fileID = parsed.fileID, fileID != 0 {
                    return (.local(fileID: fileID), range)
                }
                return nil
            }

            // GUID без фигурных скобок: `guid: …` в .meta, `"GUID:…"` в .asmdef,
            // `guid=…` в .uxml.
            let guids = guidRanges(u, line.lowerBound, end)
            let hit = guids.first { offset >= $0.range.location && offset <= NSMaxRange($0.range) }
                ?? (guids.count == 1 ? guids[0] : nil)
            if let hit { return (.asset(guid: hit.guid, fileID: nil), hit.range) }
            return nil
        }
    }

    /// Все GUID в диапазоне: 32 hex-символа сразу после `guid: `, `GUID:` или `guid=`.
    static func guidRanges(in units: [UInt16], _ range: Range<Int>) -> [(range: NSRange, guid: UnityGUID)] {
        units.withUnsafeBufferPointer { guidRanges($0, range.lowerBound, min(range.upperBound, $0.count)) }
    }

    static func guidRanges(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int)
        -> [(range: NSRange, guid: UnityGUID)] {
        var result: [(NSRange, UnityGUID)] = []
        var j = start
        while j + 36 <= end {
            // Ищем `guid` без учёта регистра.
            if u[j] | 0x20 == 0x67, u[j + 1] | 0x20 == 0x75, u[j + 2] | 0x20 == 0x69, u[j + 3] | 0x20 == 0x64 {
                var k = j + 4
                if k < end, u[k] == 0x3A || u[k] == 0x3D { k += 1 }   // : или =
                else { j += 1; continue }
                if k < end, u[k] == 0x20 { k += 1 }
                if k + 32 <= end, let guid = UnityGUID.parse(u, at: k) {
                    result.append((NSRange(location: k, length: 32), guid))
                    j = k + 32
                    continue
                }
            }
            j += 1
        }
        return result
    }

    /// Все локальные ссылки `{fileID: N}` без GUID — диапазон самого числа.
    static func localReferences(in units: [UInt16], _ range: Range<Int>) -> [(range: NSRange, fileID: Int64)] {
        units.withUnsafeBufferPointer { u in
            let end = min(range.upperBound, u.count)
            var result: [(NSRange, Int64)] = []
            var j = range.lowerBound
            while let key = find(u, j, end, "{fileID: ") {
                let numberStart = key + 9
                guard let (value, after) = signedInteger(u, numberStart, end) else { j = numberStart; continue }
                if after < end, u[after] == 0x7D, value != 0 {   // сразу `}` — GUID нет
                    result.append((NSRange(location: numberStart, length: after - numberStart), value))
                }
                j = after
            }
            return result
        }
    }

    /// Номер строки заголовка `--- !u!N &fileID` в сыром файле (UTF-8).
    /// Для прыжка в другой файл, который ещё не открыт.
    static func anchorLine(fileID: Int64, in bytes: UnsafeRawBufferPointer) -> Int? {
        let anchor = Array("&\(fileID)".utf8)
        let header = Array("--- !u!".utf8)
        let n = bytes.count
        var line = 0
        var i = 0
        while i < n {
            if i + header.count <= n, zip(header.indices, header).allSatisfy({ bytes[i + $0] == $1 }) {
                var j = i + header.count
                while j < n, bytes[j] != 0x26, bytes[j] != 0x0A { j += 1 }   // до '&'
                if j + anchor.count <= n, zip(anchor.indices, anchor).allSatisfy({ bytes[j + $0] == $1 }) {
                    let after = j + anchor.count
                    if after == n || bytes[after] == 0x0A || bytes[after] == 0x0D || bytes[after] == 0x20 {
                        return line
                    }
                }
            }
            while i < n, bytes[i] != 0x0A { i += 1 }
            i += 1
            line += 1
        }
        return nil
    }

    // MARK: - Примитивы

    @inline(__always)
    private static func hasPrefix(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int,
                                  _ prefix: StaticString) -> Bool {
        let count = prefix.utf8CodeUnitCount
        guard start + count <= end else { return false }
        let p = prefix.utf8Start
        for k in 0..<count where u[start + k] != UInt16(p[k]) { return false }
        return true
    }

    private static func find(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int,
                             _ needle: StaticString) -> Int? {
        let count = needle.utf8CodeUnitCount
        guard count > 0, end - start >= count else { return nil }
        let first = UInt16(needle.utf8Start[0])
        var j = start
        while j + count <= end {
            if u[j] == first, hasPrefix(u, j, end, needle) { return j }
            j += 1
        }
        return nil
    }

    private static func signedInteger(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int)
        -> (value: Int64, after: Int)? {
        var j = start
        var negative = false
        if j < end, u[j] == 0x2D { negative = true; j += 1 }
        let digitsStart = j
        var value: Int64 = 0
        while j < end, u[j] >= 0x30, u[j] <= 0x39 {
            value = value &* 10 &+ Int64(u[j] - 0x30)
            j += 1
        }
        guard j > digitsStart else { return nil }
        return (negative ? -value : value, j)
    }

    private static func string(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: u[start..<end]), as: UTF16.self)
    }

    /// Скалярное значение: без пробелов по краям и без кавычек.
    private static func scalar(_ u: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int) -> String {
        var s = start, e = end
        while s < e, u[s] == 0x20 { s += 1 }
        while e > s, u[e - 1] == 0x20 { e -= 1 }
        if e - s >= 2, (u[s] == 0x27 && u[e - 1] == 0x27) || (u[s] == 0x22 && u[e - 1] == 0x22) {
            s += 1; e -= 1
        }
        return s < e ? string(u, s, e) : ""
    }
}
