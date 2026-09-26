import Foundation
#if canImport(Compression)
import Compression
#endif

/// FBX без SDK Autodesk: ровно столько, сколько нужно, чтобы посмотреть
/// модель, — дерево узлов, геометрия, трансформы и цвета материалов.
///
/// Формат — дерево записей `Имя: свойства { дети }`, двоичное (7.x, всё,
/// что экспортируют Blender, Max и Maya) или текстовое. Сцена собирается
/// из `Objects` (Model, Geometry, Material) и `Connections`, которые
/// связывают их по числовым id.
enum FBX {

    enum Value: Equatable {
        case int(Int64)
        case double(Double)
        case string(String)
        case ints([Int64])
        case doubles([Double])
        /// Двоичные данные (`R`): нам не нужны, только занимают место.
        case raw

        var int: Int64? {
            switch self {
            case .int(let v): return v
            case .double(let v): return Int64(v)
            default: return nil
            }
        }

        var double: Double? {
            switch self {
            case .int(let v): return Double(v)
            case .double(let v): return v
            default: return nil
            }
        }

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        var doubles: [Double]? {
            switch self {
            case .doubles(let v): return v
            case .ints(let v): return v.map(Double.init)
            default: return nil
            }
        }

        var ints: [Int64]? {
            switch self {
            case .ints(let v): return v
            case .doubles(let v): return v.map { Int64($0) }
            default: return nil
            }
        }
    }

    struct Node {
        var name: String
        var properties: [Value]
        var children: [Node]

        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        func children(_ name: String) -> [Node] { children.filter { $0.name == name } }
    }

    enum ParseError: LocalizedError, Equatable {
        case notFBX
        case truncated
        case unsupportedVersion(Int)
        case compressionUnavailable

        var errorDescription: String? {
            switch self {
            case .notFBX: return L("Не FBX: нет ни двоичного заголовка, ни текстовых записей")
            case .truncated: return L("FBX повреждён: записи выходят за конец файла")
            case .unsupportedVersion(let v): return L("FBX \(v / 1000).\(v / 100 % 10) не поддерживается — нужен 7.x")
            case .compressionUnavailable: return L("Сжатые массивы FBX здесь не распаковать")
            }
        }
    }

    // MARK: - Разбор

    static let binaryMagic = Array("Kaydara FBX Binary  ".utf8) + [0]

    /// Узлы верхнего уровня: FBXHeaderExtension, GlobalSettings, Objects, Connections…
    static func parse(_ data: Data) throws -> [Node] {
        if data.count >= 27, data.prefix(binaryMagic.count).elementsEqual(binaryMagic) {
            return try data.withUnsafeBytes { bytes in
                var reader = BinaryReader(bytes: bytes)
                return try reader.document()
            }
        }
        return try data.withUnsafeBytes { bytes in
            var reader = TextReader(bytes: bytes.bindMemory(to: UInt8.self))
            return try reader.document()
        }
    }

    private struct BinaryReader {
        let bytes: UnsafeRawBufferPointer
        var pos = 0

        init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

        mutating func document() throws -> [Node] {
            // Байт 22 — порядок байтов: 1 — big-endian, так писал только FBX 6
            // со старых машин, и версия тоже записана в нём.
            let bigEndian = bytes[22] == 1
            pos = 23
            let raw = try u32()
            let version = Int(bigEndian ? raw.byteSwapped : raw)
            guard !bigEndian, version >= 7000, version < 8000 else { throw ParseError.unsupportedVersion(version) }
            let wide = version >= 7500
            var nodes: [Node] = []
            // После последнего узла — нулевая запись, за ней подвал файла.
            while pos + (wide ? 25 : 13) <= bytes.count, let node = try node(wide: wide) {
                nodes.append(node)
            }
            return nodes
        }

        /// nil — нулевая запись: список узлов на этом уровне закончился.
        private mutating func node(wide: Bool) throws -> Node? {
            let end = Int(wide ? try u64() : UInt64(try u32()))
            let propertyCount = Int(wide ? try u64() : UInt64(try u32()))
            _ = wide ? try u64() : UInt64(try u32())
            let nameLength = Int(try u8())
            if end == 0 { return nil }
            guard end <= bytes.count, end > pos else { throw ParseError.truncated }
            let name = try string(nameLength)
            var properties: [Value] = []
            properties.reserveCapacity(propertyCount)
            for _ in 0..<propertyCount { properties.append(try property()) }
            var children: [Node] = []
            while pos < end, let child = try node(wide: wide) { children.append(child) }
            pos = end
            return Node(name: name, properties: properties, children: children)
        }

        private mutating func property() throws -> Value {
            switch try u8() {
            case UInt8(ascii: "Y"): return .int(Int64(Int16(bitPattern: UInt16(try load(UInt16.self)))))
            case UInt8(ascii: "C"): return .int(Int64(try u8()))
            case UInt8(ascii: "I"): return .int(Int64(Int32(bitPattern: try u32())))
            case UInt8(ascii: "L"): return .int(Int64(bitPattern: try u64()))
            case UInt8(ascii: "F"): return .double(Double(Float(bitPattern: try u32())))
            case UInt8(ascii: "D"): return .double(Double(bitPattern: try u64()))
            case UInt8(ascii: "S"): return .string(try string(Int(try u32())))
            case UInt8(ascii: "R"):
                let length = Int(try u32())
                try skip(length)
                return .raw
            case UInt8(ascii: "f"): return .doubles(try array(4) { Double(Float(bitPattern: $0.loadUnaligned(fromByteOffset: $1, as: UInt32.self))) })
            case UInt8(ascii: "d"): return .doubles(try array(8) { $0.loadUnaligned(fromByteOffset: $1, as: Double.self) })
            case UInt8(ascii: "i"): return .ints(try array(4) { Int64($0.loadUnaligned(fromByteOffset: $1, as: Int32.self)) })
            case UInt8(ascii: "l"): return .ints(try array(8) { $0.loadUnaligned(fromByteOffset: $1, as: Int64.self) })
            case UInt8(ascii: "b"): return .ints(try array(1) { Int64($0[$1]) })
            default: throw ParseError.truncated
            }
        }

        private mutating func array<T>(_ size: Int, _ element: (UnsafeRawBufferPointer, Int) -> T) throws -> [T] {
            let count = Int(try u32())
            let encoding = try u32()
            let stored = Int(try u32())
            guard pos + stored <= bytes.count else { throw ParseError.truncated }
            let payload = UnsafeRawBufferPointer(rebasing: bytes[pos..<(pos + stored)])
            pos += stored
            func decode(_ raw: UnsafeRawBufferPointer) throws -> [T] {
                guard raw.count >= count * size else { throw ParseError.truncated }
                return (0..<count).map { element(raw, $0 * size) }
            }
            guard encoding == 1 else { return try decode(payload) }
            let inflated = try FBX.inflate(payload, expected: count * size)
            return try inflated.withUnsafeBytes { try decode($0) }
        }

        private mutating func string(_ length: Int) throws -> String {
            guard pos + length <= bytes.count else { throw ParseError.truncated }
            defer { pos += length }
            return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[pos..<(pos + length)]), as: UTF8.self)
        }

        private mutating func skip(_ count: Int) throws {
            guard pos + count <= bytes.count else { throw ParseError.truncated }
            pos += count
        }

        private mutating func load<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard pos + size <= bytes.count else { throw ParseError.truncated }
            defer { pos += size }
            return T(littleEndian: bytes.loadUnaligned(fromByteOffset: pos, as: T.self))
        }

        private mutating func u8() throws -> UInt8 { try load(UInt8.self) }
        private mutating func u32() throws -> UInt32 { try load(UInt32.self) }
        private mutating func u64() throws -> UInt64 { try load(UInt64.self) }
    }

    /// Массивы в двоичном FBX сжаты zlib: двухбайтовый заголовок, deflate
    /// и контрольная сумма. Compression понимает только сам deflate.
    static func inflate(_ payload: UnsafeRawBufferPointer, expected: Int) throws -> [UInt8] {
        #if canImport(Compression)
        guard payload.count > 2, let base = payload.baseAddress else { throw ParseError.truncated }
        var output = [UInt8](repeating: 0, count: max(expected, 1))
        let written = output.withUnsafeMutableBufferPointer { out in
            compression_decode_buffer(out.baseAddress!, out.count,
                                      base.advanced(by: 2).assumingMemoryBound(to: UInt8.self),
                                      payload.count - 2, nil, COMPRESSION_ZLIB)
        }
        guard written == expected else { throw ParseError.truncated }
        return output
        #else
        throw ParseError.compressionUnavailable
        #endif
    }

    /// Текстовый FBX 7.x: `Имя: знач, знач { дети }`, массивы —
    /// `Vertices: *24 { a: 1,2,3… }`, комментарии — с `;`.
    private struct TextReader {
        let bytes: UnsafeBufferPointer<UInt8>
        var pos = 0

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        mutating func document() throws -> [Node] {
            var nodes: [Node] = []
            while true {
                skipBlank()
                guard pos < bytes.count else { break }
                guard let node = try node() else { throw ParseError.notFBX }
                nodes.append(node)
            }
            guard nodes.contains(where: { $0.name == "Objects" }) else { throw ParseError.notFBX }
            return nodes
        }

        private var current: UInt8? { pos < bytes.count ? bytes[pos] : nil }

        private mutating func node() throws -> Node? {
            let start = pos
            while let c = current, isIdentifier(c) { pos += 1 }
            guard pos > start, current == UInt8(ascii: ":") else { return nil }
            let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<pos]), as: UTF8.self)
            pos += 1

            var properties: [Value] = []
            var isArray = false
            values: while true {
                skipSpaces()
                guard let c = current else { break }
                switch c {
                case UInt8(ascii: "{"), UInt8(ascii: "}"), 0x0A, 0x0D, UInt8(ascii: ";"):
                    break values
                case UInt8(ascii: "*"):
                    pos += 1
                    _ = number()
                    isArray = true
                case UInt8(ascii: "\""):
                    properties.append(.string(quoted()))
                default:
                    if let value = number() {
                        properties.append(value)
                    } else if isIdentifier(c) {
                        let s = pos
                        while let c = current, isIdentifier(c) { pos += 1 }
                        properties.append(.string(String(decoding: UnsafeBufferPointer(rebasing: bytes[s..<pos]), as: UTF8.self)))
                    } else {
                        throw ParseError.notFBX
                    }
                }
                skipSpaces()
                // Запятая в конце строки — продолжение списка на следующей.
                if current == UInt8(ascii: ",") {
                    pos += 1
                    skipBlank()
                }
            }

            var children: [Node] = []
            if current == UInt8(ascii: "{") {
                pos += 1
                while true {
                    skipBlank()
                    guard let c = current else { throw ParseError.truncated }
                    if c == UInt8(ascii: "}") { pos += 1; break }
                    guard let child = try node() else { throw ParseError.notFBX }
                    children.append(child)
                }
            }
            // `*N { a: … }` — массив: значения переезжают в сам узел.
            if isArray, let a = children.first(where: { $0.name == "a" }) {
                let allInts = a.properties.allSatisfy { if case .int = $0 { return true } else { return false } }
                properties = allInts ? [.ints(a.properties.compactMap(\.int))]
                                     : [.doubles(a.properties.compactMap(\.double))]
                children = []
            }
            return Node(name: name, properties: properties, children: children)
        }

        private mutating func quoted() -> String {
            pos += 1
            let start = pos
            while let c = current, c != UInt8(ascii: "\"") { pos += 1 }
            let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<pos]), as: UTF8.self)
            if current != nil { pos += 1 }
            return s
        }

        private mutating func number() -> Value? {
            let start = pos
            var isFloat = false
            while let c = current {
                if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") {
                    pos += 1
                } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                    // `e` посреди идентификатора — не число: его отсекает проверка ниже.
                    isFloat = true
                    pos += 1
                } else {
                    break
                }
            }
            guard pos > start else { return nil }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<pos]), as: UTF8.self)
            if !isFloat, let v = Int64(text) { return .int(v) }
            if let v = Double(text) { return .double(v) }
            pos = start
            return nil
        }

        private func isIdentifier(_ c: UInt8) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
                || c == UInt8(ascii: "_") || c == UInt8(ascii: "|")
        }

        private mutating func skipSpaces() {
            while let c = current, c == 0x20 || c == 0x09 { pos += 1 }
        }

        /// Пробелы, переводы строк и комментарии до конца строки.
        private mutating func skipBlank() {
            while let c = current {
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    pos += 1
                } else if c == UInt8(ascii: ";") {
                    while let c = current, c != 0x0A { pos += 1 }
                } else {
                    break
                }
            }
        }
    }
}

// MARK: - Сцена

extension FBX {

    /// Что показывает просмотр: сетки уже в мировых координатах и в осях
    /// с Y вверх, поэтому узлам SceneKit трансформ не нужен.
    struct Scene {
        struct Mesh {
            var name: String
            /// xyz подряд, по вершине на каждый угол полигона.
            var positions: [Float]
            var normals: [Float]
            /// Треугольники, разбитые по слотам материала модели.
            var parts: [(material: Int?, indices: [UInt32])]
        }

        struct Material {
            var name: String
            var color: (Float, Float, Float)?
        }

        var meshes: [Mesh] = []
        var materials: [Material] = []
        var controlPoints = 0
        var triangles = 0
        var models = 0
        var bones = 0
        var animations = 0
        var boundsMin: (Float, Float, Float) = (0, 0, 0)
        var boundsMax: (Float, Float, Float) = (0, 0, 0)
        /// Сколько метров в единице файла: FBX считает в сантиметрах.
        var metersPerUnit: Double = 0.01
    }

    static func scene(from data: Data) throws -> Scene {
        try scene(from: parse(data))
    }

    static func scene(from nodes: [Node]) throws -> Scene {
        var scene = Scene()
        guard let objects = nodes.first(where: { $0.name == "Objects" }) else { throw ParseError.notFBX }

        let settings = properties(nodes.first { $0.name == "GlobalSettings" })
        if let unit = settings["UnitScaleFactor"]?.first { scene.metersPerUnit = unit / 100 }
        let axes = axisConversion(settings)

        var models: [Int64: Node] = [:]
        var geometries: [Int64: Node] = [:]
        var materialIndex: [Int64: Int] = [:]
        for object in objects.children {
            guard let id = object.properties.first?.int else { continue }
            switch object.name {
            case "Model":
                models[id] = object
                scene.models += 1
                if object.properties.count > 2, object.properties[2].string == "LimbNode" { scene.bones += 1 }
            case "Geometry" where object.properties.count < 3 || object.properties[2].string == "Mesh":
                geometries[id] = object
            case "Material":
                materialIndex[id] = scene.materials.count
                let color = properties(object)["DiffuseColor"]
                scene.materials.append(Scene.Material(
                    name: objectName(object),
                    color: color.flatMap { $0.count >= 3 ? (Float($0[0]), Float($0[1]), Float($0[2])) : nil }))
            case "AnimationStack":
                scene.animations += 1
            default:
                break
            }
        }

        var parentModel: [Int64: Int64] = [:]
        var geometryModels: [Int64: [Int64]] = [:]
        var modelMaterials: [Int64: [Int]] = [:]
        for connection in nodes.first(where: { $0.name == "Connections" })?.children("C") ?? [] {
            let p = connection.properties
            guard p.count >= 3, p[0].string == "OO", let child = p[1].int, let parent = p[2].int else { continue }
            if models[child] != nil, models[parent] != nil {
                parentModel[child] = parent
            } else if geometries[child] != nil, models[parent] != nil {
                geometryModels[child, default: []].append(parent)
            } else if let material = materialIndex[child], models[parent] != nil {
                modelMaterials[parent, default: []].append(material)
            }
        }

        var worldCache: [Int64: Matrix4] = [:]
        func world(_ id: Int64, depth: Int = 0) -> Matrix4 {
            if let cached = worldCache[id] { return cached }
            guard let model = models[id] else { return .identity }
            let local = localTransform(properties(model))
            let parent = depth < 256 ? parentModel[id].map { world($0, depth: depth + 1) } ?? .identity : .identity
            let result = parent * local
            worldCache[id] = result
            return result
        }

        var lo = (Float.infinity, Float.infinity, Float.infinity)
        var hi = (-Float.infinity, -Float.infinity, -Float.infinity)
        // Геометрия без модели тоже показывается — на месте, без трансформа.
        let orderedGeometries = objects.children.compactMap { node -> Int64? in
            guard let id = node.properties.first?.int, geometries[id] != nil else { return nil }
            return id
        }
        for geometryID in orderedGeometries {
            let geometry = geometries[geometryID]!
            scene.controlPoints += (geometry.child("Vertices")?.properties.first?.doubles?.count ?? 0) / 3
            let owners = geometryModels[geometryID] ?? []
            for owner in owners.isEmpty ? [nil] : owners.map(Optional.some) {
                var transform = axes
                var name = objectName(geometry)
                if let owner, let model = models[owner] {
                    let props = properties(model)
                    transform = axes * world(owner) * geometricTransform(props)
                    name = objectName(model)
                }
                guard var mesh = buildMesh(geometry, transform: transform) else { continue }
                mesh.name = name
                let slots = owner.flatMap { modelMaterials[$0] } ?? []
                mesh.parts = mesh.parts.map { part in
                    (part.material.flatMap { $0 < slots.count ? slots[$0] : nil }, part.indices)
                }
                scene.triangles += mesh.parts.reduce(0) { $0 + $1.indices.count / 3 }
                var i = 0
                while i < mesh.positions.count {
                    lo = (min(lo.0, mesh.positions[i]), min(lo.1, mesh.positions[i + 1]), min(lo.2, mesh.positions[i + 2]))
                    hi = (max(hi.0, mesh.positions[i]), max(hi.1, mesh.positions[i + 1]), max(hi.2, mesh.positions[i + 2]))
                    i += 3
                }
                scene.meshes.append(mesh)
            }
        }
        if lo.0 <= hi.0 {
            scene.boundsMin = lo
            scene.boundsMax = hi
        }
        return scene
    }

    /// `Name\0\u{1}Model` в двоичном файле, `Model::Name` — в текстовом.
    static func objectName(_ node: Node) -> String {
        guard node.properties.count > 1, let raw = node.properties[1].string else { return node.name }
        if let range = raw.range(of: "\u{0}\u{1}") { return String(raw[..<range.lowerBound]) }
        if let range = raw.range(of: "::") { return String(raw[range.upperBound...]) }
        return raw
    }

    /// `Properties70 { P: "Lcl Translation", "Lcl Translation", "", "A", 0, 0, 0 }` → числа.
    static func properties(_ node: Node?) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        for p in node?.child("Properties70")?.children("P") ?? [] {
            guard let name = p.properties.first?.string, p.properties.count > 4 else { continue }
            result[name] = p.properties.dropFirst(4).compactMap(\.double)
        }
        return result
    }

    private static func vector(_ props: [String: [Double]], _ name: String, _ fallback: Double = 0) -> (Double, Double, Double) {
        guard let v = props[name], v.count >= 3 else { return (fallback, fallback, fallback) }
        return (v[0], v[1], v[2])
    }

    /// Порядок, в котором FBX применяет части трансформа модели:
    /// T · Roff · Rp · Rpre · R · Rpost⁻¹ · Rp⁻¹ · Soff · Sp · S · Sp⁻¹.
    static func localTransform(_ props: [String: [Double]]) -> Matrix4 {
        let order = Int(props["RotationOrder"]?.first ?? 0)
        let rp = vector(props, "RotationPivot")
        let sp = vector(props, "ScalingPivot")
        return Matrix4.translation(vector(props, "Lcl Translation"))
            * .translation(vector(props, "RotationOffset"))
            * .translation(rp)
            * .euler(vector(props, "PreRotation"), order: 0)
            * .euler(vector(props, "Lcl Rotation"), order: order)
            * Matrix4.euler(vector(props, "PostRotation"), order: 0).transposed
            * .translation((-rp.0, -rp.1, -rp.2))
            * .translation(vector(props, "ScalingOffset"))
            * .translation(sp)
            * .scale(vector(props, "Lcl Scaling", 1))
            * .translation((-sp.0, -sp.1, -sp.2))
    }

    /// Смещение самой сетки относительно модели — детям не наследуется.
    static func geometricTransform(_ props: [String: [Double]]) -> Matrix4 {
        Matrix4.translation(vector(props, "GeometricTranslation"))
            * .euler(vector(props, "GeometricRotation"), order: 0)
            * .scale(vector(props, "GeometricScaling", 1))
    }

    /// Оси файла → Y вверх, как в SceneKit и Unity. Без GlobalSettings
    /// FBX и так Y-up.
    static func axisConversion(_ settings: [String: [Double]]) -> Matrix4 {
        func axis(_ name: String, _ fallback: Int) -> (index: Int, sign: Double) {
            let index = settings[name].flatMap(\.first).map { Int($0) } ?? fallback
            let sign = settings[name + "Sign"].flatMap(\.first) ?? 1
            return (min(max(index, 0), 2), sign < 0 ? -1 : 1)
        }
        let coord = axis("CoordAxis", 0), up = axis("UpAxis", 1), front = axis("FrontAxis", 2)
        guard Set([coord.index, up.index, front.index]).count == 3 else { return .identity }
        var m = Matrix4.identity
        // Строка i результата — ось файла, которая становится осью i.
        for (row, a) in [coord, up, front].enumerated() {
            for column in 0..<3 { m[row, column] = column == a.index ? a.sign : 0 }
        }
        return m
    }

    /// Полигоны → треугольники веером; вершина на каждый угол полигона,
    /// чтобы нормали и материалы по полигонам ложились без склейки.
    static func buildMesh(_ geometry: Node, transform: Matrix4) -> Scene.Mesh? {
        guard let vertices = geometry.child("Vertices")?.properties.first?.doubles,
              let polygonIndex = geometry.child("PolygonVertexIndex")?.properties.first?.ints,
              !vertices.isEmpty, !polygonIndex.isEmpty else { return nil }
        let pointCount = vertices.count / 3

        let normalLayer = geometry.child("LayerElementNormal")
        let normals = normalLayer?.child("Normals")?.properties.first?.doubles
        let normalIndex = normalLayer?.child("NormalsIndex")?.properties.first?.ints
        let normalMapping = normalLayer?.child("MappingInformationType")?.properties.first?.string ?? ""
        let normalReference = normalLayer?.child("ReferenceInformationType")?.properties.first?.string ?? ""

        let materialLayer = geometry.child("LayerElementMaterial")
        let materialSlots = materialLayer?.child("Materials")?.properties.first?.ints
        let materialMapping = materialLayer?.child("MappingInformationType")?.properties.first?.string ?? ""

        let normalMatrix = transform.normalMatrix
        var positions: [Float] = []
        var outNormals: [Float] = []
        positions.reserveCapacity(polygonIndex.count * 3)
        outNormals.reserveCapacity(polygonIndex.count * 3)
        var parts: [Int: [UInt32]] = [:]

        var polygonStart = 0
        var polygon = 0
        for (corner, raw) in polygonIndex.enumerated() {
            let isLast = raw < 0
            guard isLast else { continue }
            let range = polygonStart..<(corner + 1)
            polygonStart = corner + 1
            defer { polygon += 1 }
            guard range.count >= 3 else { continue }

            let base = UInt32(positions.count / 3)
            for pv in range {
                var point = Int(polygonIndex[pv])
                if point < 0 { point = ~point }
                guard point < pointCount else { return nil }
                let p = transform.transformPoint((vertices[point * 3], vertices[point * 3 + 1], vertices[point * 3 + 2]))
                positions.append(Float(p.0)); positions.append(Float(p.1)); positions.append(Float(p.2))
            }
            var faceNormal: (Double, Double, Double)?
            for pv in range {
                var n: (Double, Double, Double)?
                if let normals {
                    var point = Int(polygonIndex[pv])
                    if point < 0 { point = ~point }
                    var index: Int
                    switch normalMapping {
                    case "ByVertice", "ByVertex", "ByControlPoint": index = point
                    case "ByPolygon": index = polygon
                    case "AllSame": index = 0
                    default: index = pv
                    }
                    if normalReference == "IndexToDirect" || normalReference == "Index" {
                        index = normalIndex.flatMap { index < $0.count ? Int($0[index]) : nil } ?? -1
                    }
                    if index >= 0, index * 3 + 2 < normals.count {
                        n = normalMatrix.transformDirection((normals[index * 3], normals[index * 3 + 1], normals[index * 3 + 2]))
                    }
                }
                if n == nil {
                    if faceNormal == nil { faceNormal = flatNormal(positions, first: Int(base), count: range.count) }
                    n = faceNormal
                }
                let normal = normalized(n!)
                outNormals.append(Float(normal.0)); outNormals.append(Float(normal.1)); outNormals.append(Float(normal.2))
            }

            var slot = -1
            if let materialSlots, !materialSlots.isEmpty {
                slot = Int(materialMapping == "ByPolygon" && polygon < materialSlots.count
                           ? materialSlots[polygon] : materialSlots[0])
            }
            for k in 1..<(range.count - 1) {
                parts[slot, default: []].append(contentsOf: [base, base + UInt32(k), base + UInt32(k + 1)])
            }
        }
        guard !positions.isEmpty else { return nil }
        let ordered = parts.keys.sorted().map { (material: $0 < 0 ? nil : Optional($0), indices: parts[$0]!) }
        return Scene.Mesh(name: "", positions: positions, normals: outNormals, parts: ordered)
    }

    private static func flatNormal(_ positions: [Float], first: Int, count: Int) -> (Double, Double, Double) {
        func p(_ i: Int) -> (Double, Double, Double) {
            (Double(positions[i * 3]), Double(positions[i * 3 + 1]), Double(positions[i * 3 + 2]))
        }
        // Метод Ньюэлла: годится и для невыпуклых полигонов.
        var n = (0.0, 0.0, 0.0)
        for k in 0..<count {
            let a = p(first + k), b = p(first + (k + 1) % count)
            n.0 += (a.1 - b.1) * (a.2 + b.2)
            n.1 += (a.2 - b.2) * (a.0 + b.0)
            n.2 += (a.0 - b.0) * (a.1 + b.1)
        }
        return n
    }

    private static func normalized(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        let length = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
        return length > 0 ? (v.0 / length, v.1 / length, v.2 / length) : (0, 1, 0)
    }
}

/// 4×4 по столбцам, как в SceneKit и simd: точка — столбец справа.
/// Свой тип, а не simd: ядро собирается и гоняет тесты и на Linux.
struct Matrix4: Equatable {
    var m: [Double]   // 16 чисел, m[column * 4 + row]

    subscript(row: Int, column: Int) -> Double {
        get { m[column * 4 + row] }
        set { m[column * 4 + row] = newValue }
    }

    static let identity = Matrix4(m: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    static func translation(_ t: (Double, Double, Double)) -> Matrix4 {
        var r = identity
        r[0, 3] = t.0; r[1, 3] = t.1; r[2, 3] = t.2
        return r
    }

    static func scale(_ s: (Double, Double, Double)) -> Matrix4 {
        var r = identity
        r[0, 0] = s.0; r[1, 1] = s.1; r[2, 2] = s.2
        return r
    }

    static func rotation(axis: Int, degrees: Double) -> Matrix4 {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        var r = identity
        let (i, j) = [(1, 2), (2, 0), (0, 1)][axis]
        r[i, i] = c; r[i, j] = -s
        r[j, i] = s; r[j, j] = c
        return r
    }

    /// Углы в градусах. `order` — RotationOrder из FBX: 0 — XYZ (сначала X),
    /// 1 — XZY, 2 — YZX, 3 — YXZ, 4 — ZXY, 5 — ZYX.
    static func euler(_ angles: (Double, Double, Double), order: Int) -> Matrix4 {
        let sequence = [[0, 1, 2], [0, 2, 1], [1, 2, 0], [1, 0, 2], [2, 0, 1], [2, 1, 0]][min(max(order, 0), 5)]
        let values = [angles.0, angles.1, angles.2]
        var r = identity
        for axis in sequence where values[axis] != 0 {
            r = rotation(axis: axis, degrees: values[axis]) * r
        }
        return r
    }

    static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
        var r = Matrix4(m: [Double](repeating: 0, count: 16))
        for column in 0..<4 {
            for row in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += a[row, k] * b[k, column] }
                r[row, column] = sum
            }
        }
        return r
    }

    var transposed: Matrix4 {
        var r = self
        for row in 0..<4 { for column in 0..<4 { r[row, column] = self[column, row] } }
        return r
    }

    func transformPoint(_ p: (Double, Double, Double)) -> (Double, Double, Double) {
        (self[0, 0] * p.0 + self[0, 1] * p.1 + self[0, 2] * p.2 + self[0, 3],
         self[1, 0] * p.0 + self[1, 1] * p.1 + self[1, 2] * p.2 + self[1, 3],
         self[2, 0] * p.0 + self[2, 1] * p.1 + self[2, 2] * p.2 + self[2, 3])
    }

    func transformDirection(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (self[0, 0] * v.0 + self[0, 1] * v.1 + self[0, 2] * v.2,
         self[1, 0] * v.0 + self[1, 1] * v.1 + self[1, 2] * v.2,
         self[2, 0] * v.0 + self[2, 1] * v.1 + self[2, 2] * v.2)
    }

    /// Для нормалей — матрица алгебраических дополнений верхнего 3×3:
    /// это обратная транспонированная с точностью до множителя, а длину
    /// нормали всё равно нормируем. Знак определителя сохраняем, чтобы
    /// зеркальный масштаб не вывернул нормали внутрь.
    var normalMatrix: Matrix4 {
        let a = self
        var r = Matrix4.identity
        r[0, 0] = a[1, 1] * a[2, 2] - a[1, 2] * a[2, 1]
        r[0, 1] = a[1, 2] * a[2, 0] - a[1, 0] * a[2, 2]
        r[0, 2] = a[1, 0] * a[2, 1] - a[1, 1] * a[2, 0]
        r[1, 0] = a[0, 2] * a[2, 1] - a[0, 1] * a[2, 2]
        r[1, 1] = a[0, 0] * a[2, 2] - a[0, 2] * a[2, 0]
        r[1, 2] = a[0, 1] * a[2, 0] - a[0, 0] * a[2, 1]
        r[2, 0] = a[0, 1] * a[1, 2] - a[0, 2] * a[1, 1]
        r[2, 1] = a[0, 2] * a[1, 0] - a[0, 0] * a[1, 2]
        r[2, 2] = a[0, 0] * a[1, 1] - a[0, 1] * a[1, 0]
        let det = a[0, 0] * r[0, 0] + a[0, 1] * r[0, 1] + a[0, 2] * r[0, 2]
        if det < 0 { for i in 0..<3 { for j in 0..<3 { r[i, j] = -r[i, j] } } }
        return r
    }
}
