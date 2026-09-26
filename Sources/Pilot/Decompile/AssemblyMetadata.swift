import Foundation

/// Метаданные .NET-сборки: PE-контейнер, заголовок CLI и таблицы ECMA-335.
///
/// Читается ровно то, из чего складывается объявление: таблицы типов и их
/// членов, куча строк и куча сигнатур. IL не трогается — у сборки берётся
/// поверхность, а не тела методов.
///
/// Каждое чтение проверяет границы и за ними даёт нули: обрезанный или
/// битый файл должен кончиться неполным текстом, а не падением редактора.
struct AssemblyMetadata {

    enum Failure: Error, LocalizedError {
        /// PE без заголовка CLI: нативная библиотека, метаданных в ней нет.
        case notManaged
        case damaged(String)

        var errorDescription: String? {
            switch self {
            case .notManaged:      return L("Нативная библиотека: .NET-метаданных в ней нет")
            case .damaged(let why): return L("Не удалось прочитать сборку: \(why)")
            }
        }
    }

    // MARK: - Таблицы

    enum Table: Int, CaseIterable {
        case module = 0x00, typeRef = 0x01, typeDef = 0x02, fieldPtr = 0x03, field = 0x04
        case methodPtr = 0x05, methodDef = 0x06, paramPtr = 0x07, param = 0x08, interfaceImpl = 0x09
        case memberRef = 0x0A, constant = 0x0B, customAttribute = 0x0C, fieldMarshal = 0x0D
        case declSecurity = 0x0E, classLayout = 0x0F, fieldLayout = 0x10, standAloneSig = 0x11
        case eventMap = 0x12, eventPtr = 0x13, event = 0x14, propertyMap = 0x15, propertyPtr = 0x16
        case property = 0x17, methodSemantics = 0x18, methodImpl = 0x19, moduleRef = 0x1A
        case typeSpec = 0x1B, implMap = 0x1C, fieldRVA = 0x1D, encLog = 0x1E, encMap = 0x1F
        case assembly = 0x20, assemblyProcessor = 0x21, assemblyOS = 0x22, assemblyRef = 0x23
        case assemblyRefProcessor = 0x24, assemblyRefOS = 0x25, file = 0x26, exportedType = 0x27
        case manifestResource = 0x28, nestedClass = 0x29, genericParam = 0x2A, methodSpec = 0x2B
        case genericParamConstraint = 0x2C
    }

    /// Составной индекс: младшие биты — номер таблицы, старшие — строка в ней.
    enum Coded {
        case typeDefOrRef, hasConstant, hasCustomAttribute, hasFieldMarshal, hasDeclSecurity
        case memberRefParent, hasSemantics, methodDefOrRef, memberForwarded, implementation
        case customAttributeType, resolutionScope, typeOrMethodDef

        var tables: [Table?] {
            switch self {
            case .typeDefOrRef:   return [.typeDef, .typeRef, .typeSpec]
            case .hasConstant:    return [.field, .param, .property]
            case .hasCustomAttribute:
                return [.methodDef, .field, .typeRef, .typeDef, .param, .interfaceImpl, .memberRef,
                        .module, .declSecurity, .property, .event, .standAloneSig, .moduleRef,
                        .typeSpec, .assembly, .assemblyRef, .file, .exportedType, .manifestResource,
                        .genericParam, .genericParamConstraint, .methodSpec]
            case .hasFieldMarshal: return [.field, .param]
            case .hasDeclSecurity: return [.typeDef, .methodDef, .assembly]
            case .memberRefParent: return [.typeDef, .typeRef, .moduleRef, .methodDef, .typeSpec]
            case .hasSemantics:    return [.event, .property]
            case .methodDefOrRef:  return [.methodDef, .memberRef]
            case .memberForwarded: return [.field, .methodDef]
            case .implementation:  return [.file, .assemblyRef, .exportedType]
            case .customAttributeType: return [nil, nil, .methodDef, .memberRef, nil]
            case .resolutionScope: return [.module, .moduleRef, .assemblyRef, .typeRef]
            case .typeOrMethodDef: return [.typeDef, .methodDef]
            }
        }

        /// Сколько младших бит занимает тег таблицы.
        var bits: Int {
            var bits = 0
            while (1 << bits) < tables.count { bits += 1 }
            return bits
        }
    }

    private enum Kind {
        case fixed(Int)          // поле в столько байт, как есть
        case string, blob, guid
        case index(Table)
        case coded(Coded)
    }

    /// Раскладка строк: порядок столбцов из ECMA-335 §II.22.
    private static func layout(_ table: Table) -> [Kind] {
        switch table {
        case .module:        return [.fixed(2), .string, .guid, .guid, .guid]
        case .typeRef:       return [.coded(.resolutionScope), .string, .string]
        case .typeDef:       return [.fixed(4), .string, .string, .coded(.typeDefOrRef),
                                     .index(.field), .index(.methodDef)]
        case .fieldPtr:      return [.index(.field)]
        case .field:         return [.fixed(2), .string, .blob]
        case .methodPtr:     return [.index(.methodDef)]
        case .methodDef:     return [.fixed(4), .fixed(2), .fixed(2), .string, .blob, .index(.param)]
        case .paramPtr:      return [.index(.param)]
        case .param:         return [.fixed(2), .fixed(2), .string]
        case .interfaceImpl: return [.index(.typeDef), .coded(.typeDefOrRef)]
        case .memberRef:     return [.coded(.memberRefParent), .string, .blob]
        case .constant:      return [.fixed(2), .coded(.hasConstant), .blob]
        case .customAttribute: return [.coded(.hasCustomAttribute), .coded(.customAttributeType), .blob]
        case .fieldMarshal:  return [.coded(.hasFieldMarshal), .blob]
        case .declSecurity:  return [.fixed(2), .coded(.hasDeclSecurity), .blob]
        case .classLayout:   return [.fixed(2), .fixed(4), .index(.typeDef)]
        case .fieldLayout:   return [.fixed(4), .index(.field)]
        case .standAloneSig: return [.blob]
        case .eventMap:      return [.index(.typeDef), .index(.event)]
        case .eventPtr:      return [.index(.event)]
        case .event:         return [.fixed(2), .string, .coded(.typeDefOrRef)]
        case .propertyMap:   return [.index(.typeDef), .index(.property)]
        case .propertyPtr:   return [.index(.property)]
        case .property:      return [.fixed(2), .string, .blob]
        case .methodSemantics: return [.fixed(2), .index(.methodDef), .coded(.hasSemantics)]
        case .methodImpl:    return [.index(.typeDef), .coded(.methodDefOrRef), .coded(.methodDefOrRef)]
        case .moduleRef:     return [.string]
        case .typeSpec:      return [.blob]
        case .implMap:       return [.fixed(2), .coded(.memberForwarded), .string, .index(.moduleRef)]
        case .fieldRVA:      return [.fixed(4), .index(.field)]
        case .encLog:        return [.fixed(4), .fixed(4)]
        case .encMap:        return [.fixed(4)]
        case .assembly:      return [.fixed(4), .fixed(2), .fixed(2), .fixed(2), .fixed(2), .fixed(4),
                                     .blob, .string, .string]
        case .assemblyProcessor: return [.fixed(4)]
        case .assemblyOS:    return [.fixed(4), .fixed(4), .fixed(4)]
        case .assemblyRef:   return [.fixed(2), .fixed(2), .fixed(2), .fixed(2), .fixed(4),
                                     .blob, .string, .string, .blob]
        case .assemblyRefProcessor: return [.fixed(4), .index(.assemblyRef)]
        case .assemblyRefOS: return [.fixed(4), .fixed(4), .fixed(4), .index(.assemblyRef)]
        case .file:          return [.fixed(4), .string, .blob]
        case .exportedType:  return [.fixed(4), .fixed(4), .string, .string, .coded(.implementation)]
        case .manifestResource: return [.fixed(4), .fixed(4), .string, .coded(.implementation)]
        case .nestedClass:   return [.index(.typeDef), .index(.typeDef)]
        case .genericParam:  return [.fixed(2), .fixed(2), .coded(.typeOrMethodDef), .string]
        case .methodSpec:    return [.coded(.methodDefOrRef), .blob]
        case .genericParamConstraint: return [.index(.genericParam), .coded(.typeDefOrRef)]
        }
    }

    // MARK: - Разбор файла

    private let bytes: [UInt8]
    private var strings = 0, blobs = 0, guids = 0
    private var rows = [Int](repeating: 0, count: 64)
    /// Смещение первой строки таблицы в файле и размер строки.
    private var rowStart = [Int](repeating: 0, count: 64)
    private var rowSize = [Int](repeating: 0, count: 64)
    /// Смещения столбцов внутри строки и их размеры.
    private var columns = [[(offset: Int, size: Int)]](repeating: [], count: 64)

    init(url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw Failure.damaged(error.localizedDescription) }
        try self.init(bytes: [UInt8](data))
    }

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        guard bytes.count > 0x40, u16(0) == 0x5A4D else { throw Failure.notManaged }    // «MZ»
        let pe = Int(u32(0x3C))
        guard pe > 0, u32(pe) == 0x0000_4550 else { throw Failure.notManaged }          // «PE\0\0»

        let coff = pe + 4
        let sectionCount = Int(u16(coff + 2))
        let optionalSize = Int(u16(coff + 16))
        let optional = coff + 20
        // PE32+ шире PE32 на 16 байт — на столько же сдвинуты директории.
        let directories = optional + (u16(optional) == 0x20B ? 112 : 96)
        let sections = optional + optionalSize

        var map: [(rva: UInt32, size: UInt32, file: UInt32)] = []
        for index in 0..<min(sectionCount, 96) {
            let header = sections + index * 40
            let virtualSize = u32(header + 8), rawSize = u32(header + 16)
            map.append((rva: u32(header + 12), size: max(virtualSize, rawSize), file: u32(header + 20)))
        }
        func offset(rva: UInt32) -> Int? {
            guard rva != 0 else { return nil }
            for section in map where rva >= section.rva && rva < section.rva &+ section.size {
                return Int(section.file &+ (rva - section.rva))
            }
            return nil
        }

        // Заголовок CLI — пятнадцатая директория; без неё это обычный PE.
        guard let cli = offset(rva: u32(directories + 14 * 8)) else { throw Failure.notManaged }
        guard let root = offset(rva: u32(cli + 8)), u32(root) == 0x424A_5342 else {   // «BSJB»
            throw Failure.notManaged
        }

        // Корень метаданных: за версией рантайма идут заголовки потоков.
        let versionLength = Int(u32(root + 12))
        var cursor = root + 16 + ((versionLength + 3) & ~3) + 2
        let streamCount = Int(u16(cursor))
        cursor += 2
        var tablesStream: Int?
        for _ in 0..<min(streamCount, 16) {
            let start = root + Int(u32(cursor))
            cursor += 8
            var nameBytes: [UInt8] = []
            while cursor < bytes.count, bytes[cursor] != 0 {
                nameBytes.append(bytes[cursor])
                cursor += 1
            }
            cursor = (cursor + 4) & ~3                      // имя выровнено по четырём байтам
            switch String(decoding: nameBytes, as: UTF8.self) {
            case "#Strings": strings = start
            case "#Blob":    blobs = start
            case "#GUID":    guids = start
            case "#~", "#-": tablesStream = start
            default:         break
            }
        }
        guard let tables = tablesStream else { throw Failure.damaged(L("нет потока таблиц")) }

        // Шапка потока таблиц: какие таблицы есть и сколько в них строк.
        let heapSizes = u8(tables + 6)
        let stringIndex = (heapSizes & 0x01) != 0 ? 4 : 2
        let guidIndex = (heapSizes & 0x02) != 0 ? 4 : 2
        let blobIndex = (heapSizes & 0x04) != 0 ? 4 : 2
        let valid = u64(tables + 8)
        var counts = tables + 24
        for table in 0..<64 where (valid >> UInt64(table)) & 1 == 1 {
            rows[table] = Int(u32(counts))
            counts += 4
        }
        if (heapSizes & 0x40) != 0 { counts += 4 }          // extra data у потока «#-»

        func size(_ kind: Kind) -> Int {
            switch kind {
            case .fixed(let bytes): return bytes
            case .string:           return stringIndex
            case .blob:             return blobIndex
            case .guid:             return guidIndex
            case .index(let table): return rows[table.rawValue] < 0x1_0000 ? 2 : 4
            case .coded(let coded):
                let limit = 1 << (16 - coded.bits)
                let biggest = coded.tables.map { $0.map { rows[$0.rawValue] } ?? 0 }.max() ?? 0
                return biggest < limit ? 2 : 4
            }
        }

        var start = counts
        for table in Table.allCases {
            let id = table.rawValue
            var offset = 0
            var layout: [(offset: Int, size: Int)] = []
            for kind in Self.layout(table) {
                let width = size(kind)
                layout.append((offset, width))
                offset += width
            }
            columns[id] = layout
            rowSize[id] = offset
            rowStart[id] = start
            start += offset * rows[id]
        }
        guard start <= bytes.count else { throw Failure.damaged(L("таблицы не помещаются в файл")) }
    }

    // MARK: - Чтение чисел

    @inline(__always) private func u8(_ at: Int) -> UInt32 {
        at >= 0 && at < bytes.count ? UInt32(bytes[at]) : 0
    }
    @inline(__always) private func u16(_ at: Int) -> UInt32 { u8(at) | (u8(at + 1) << 8) }
    @inline(__always) private func u32(_ at: Int) -> UInt32 { u16(at) | (u16(at + 2) << 16) }
    @inline(__always) private func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | (UInt64(u32(at + 4)) << 32) }

    // MARK: - Строки таблиц

    func rowCount(_ table: Table) -> Int { rows[table.rawValue] }

    /// Строки нумеруются с единицы — так на них ссылаются сами метаданные.
    func cell(_ table: Table, _ row: Int, _ column: Int) -> UInt32 {
        let id = table.rawValue
        guard row >= 1, row <= rows[id], column < columns[id].count else { return 0 }
        let (offset, size) = columns[id][column]
        let at = rowStart[id] + (row - 1) * rowSize[id] + offset
        switch size {
        case 1:  return u8(at)
        case 2:  return u16(at)
        default: return u32(at)
        }
    }

    /// Куда показывает составной индекс: таблица и строка в ней.
    func target(_ coded: Coded, _ value: UInt32) -> (table: Table, row: Int)? {
        let bits = coded.bits
        let tag = Int(value) & ((1 << bits) - 1)
        let row = Int(value) >> bits
        guard row > 0, tag < coded.tables.count, let table = coded.tables[tag] else { return nil }
        return (table, row)
    }

    /// Диапазон строк дочерней таблицы: от индекса в этой строке до индекса
    /// в следующей. Так в метаданных записаны поля и методы типа.
    func range(_ table: Table, _ row: Int, _ column: Int, into child: Table) -> Range<Int> {
        let first = Int(cell(table, row, column))
        guard first > 0 else { return 0..<0 }
        let last = row < rowCount(table) ? Int(cell(table, row + 1, column)) : rowCount(child) + 1
        return first..<max(first, last)
    }

    // MARK: - Кучи

    func string(_ table: Table, _ row: Int, _ column: Int) -> String {
        let index = Int(cell(table, row, column))
        guard strings > 0, index > 0 else { return "" }
        var end = strings + index
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        return String(decoding: bytes[(strings + index)..<min(end, bytes.count)], as: UTF8.self)
    }

    func blob(_ table: Table, _ row: Int, _ column: Int) -> ArraySlice<UInt8> {
        blob(index: cell(table, row, column))
    }

    func blob(index: UInt32) -> ArraySlice<UInt8> {
        let at = blobs + Int(index)
        guard blobs > 0, index > 0, at < bytes.count else { return ArraySlice() }
        var cursor = at
        guard let length = Self.compressed(bytes, &cursor) else { return ArraySlice() }
        let end = min(cursor + Int(length), bytes.count)
        return bytes[cursor..<max(cursor, end)]
    }

    /// Сжатое беззнаковое число ECMA-335 §II.23.2: длина видна по старшим битам.
    static func compressed(_ bytes: [UInt8], _ cursor: inout Int) -> UInt32? {
        guard cursor < bytes.count else { return nil }
        let first = UInt32(bytes[cursor])
        if first & 0x80 == 0 {
            cursor += 1
            return first
        }
        if first & 0xC0 == 0x80 {
            guard cursor + 1 < bytes.count else { return nil }
            let value = ((first & 0x3F) << 8) | UInt32(bytes[cursor + 1])
            cursor += 2
            return value
        }
        guard first & 0xE0 == 0xC0, cursor + 3 < bytes.count else { return nil }
        let value = ((first & 0x1F) << 24) | (UInt32(bytes[cursor + 1]) << 16)
            | (UInt32(bytes[cursor + 2]) << 8) | UInt32(bytes[cursor + 3])
        cursor += 4
        return value
    }
}
