import Foundation

/// Протокол отладчика Mono (Soft Debugger Wire Protocol) — им говорит
/// редактор Unity. Родственник JDWP: пакеты с заголовком в 11 байт,
/// числа в big-endian, строки — длина и UTF-8, идентификаторы — 4 байта.
///
/// Описан он только кодом: клиент — `Mono.Debugger.Soft/Connection.cs`,
/// сервер — `debugger-agent.c`. Номера команд и то, с какой версии
/// протокола поле появляется в ответе, взяты оттуда же.
enum SDB {
    static let handshake = Array("DWP-Handshake".utf8)
    static let headerLength = 11
    static let replyFlag: UInt8 = 0x80

    /// Какую версию протокола объявляем. У свежих рантаймов — 2.65; у
    /// старых — 2.56, как делает сам Mono.Debugger.Soft: с ней они ведут
    /// себя по-старому, и каждое поле ответа читается предсказуемо.
    static let newestMinor = 65
    static let fallbackMinor = 56

    enum CommandSet: UInt8 {
        case vm = 1, objectRef = 9, stringRef = 10, thread = 11, arrayRef = 13,
             eventRequest = 15, stackFrame = 16, appDomain = 20, assembly = 21,
             method = 22, type = 23, module = 24, field = 25, event = 64
    }

    enum VM: UInt8 {
        case version = 1, allThreads = 2, suspend = 3, resume = 4, exit = 5, dispose = 6,
             setProtocolVersion = 8, getTypesForSourceFile = 11, getTypes = 12
    }
    enum Thread: UInt8 { case getFrameInfo = 1, getName = 2, getState = 3 }
    enum EventRequest: UInt8 { case set = 1, clear = 2, clearAllBreakpoints = 3 }
    enum Method: UInt8 {
        case getName = 1, getDeclaringType = 2, getDebugInfo = 3, getParamInfo = 4, getLocalsInfo = 5, getInfo = 6
    }
    enum TypeCmd: UInt8 { case getInfo = 1, getMethods = 2, getFields = 3, getValues = 4, getSourceFiles2 = 13 }
    enum StackFrame: UInt8 { case getValues = 1, getThis = 2 }
    enum ArrayRef: UInt8 { case getLength = 1, getValues = 2 }
    enum StringRef: UInt8 { case getValue = 1 }
    enum ObjectRef: UInt8 { case getType = 1, getValues = 2 }
    static let compositeEvent: UInt8 = 100

    enum EventKind: UInt8 {
        case vmStart = 0, vmDeath = 1, threadStart = 2, threadDeath = 3,
             appDomainCreate = 4, appDomainUnload = 5, methodEntry = 6, methodExit = 7,
             assemblyLoad = 8, assemblyUnload = 9, breakpoint = 10, step = 11,
             typeLoad = 12, exception = 13, keepAlive = 14, userBreak = 15, userLog = 16,
             crash = 17, encUpdate = 18, methodUpdate = 19
    }

    enum SuspendPolicy: UInt8 { case none = 0, eventThread = 1, all = 2 }

    enum StepDepth: Int32 { case into = 0, over = 1, out = 2 }
    enum StepSize: Int32 { case min = 0, line = 1 }
    /// Шагом не заходить туда, где человеку делать нечего: статические
    /// конструкторы, [DebuggerHidden], [DebuggerStepThrough], [DebuggerNonUserCode].
    static let stepFilter: Int32 = 1 | 2 | 4 | 8

    enum Modifier {
        case count(Int32)
        case threadOnly(Int)
        case location(method: Int, offset: Int64)
        case step(thread: Int, size: StepSize, depth: StepDepth)
        case sourceFiles([String])
    }

    /// Типы значений в ответах. Сверх ECMA — четыре служебных.
    enum Element: UInt8 {
        case void = 0x01, boolean = 0x02, char = 0x03, i1 = 0x04, u1 = 0x05, i2 = 0x06, u2 = 0x07,
             i4 = 0x08, u4 = 0x09, i8 = 0x0a, u8 = 0x0b, r4 = 0x0c, r8 = 0x0d, string = 0x0e,
             ptr = 0x0f, valueType = 0x11, klass = 0x12, array = 0x14, i = 0x18, u = 0x19,
             object = 0x1c, szArray = 0x1d
        case null = 0xf0, typeRef = 0xf1, parentVType = 0xf2, fixedArray = 0xf3
    }

    /// Коды ошибок ответа, о которых стоит говорить человеку по-русски.
    static func describe(error code: Int) -> String {
        switch code {
        case 20: return "объект уже собран сборщиком мусора"
        case 25: return "нет такого поля"
        case 30: return "кадр стека больше недействителен"
        case 100: return "рантайм этого не умеет"
        case 101: return "программа не остановлена"
        case 102: return "неверный аргумент"
        case 103: return "домен выгружен"
        case 105: return "нет отладочной информации"
        case 106: return "нет точки останова по этому смещению"
        default: return "ошибка \(code)"
        }
    }
}

struct SDBVersion: Comparable, CustomStringConvertible {
    var major: Int
    var minor: Int

    func atLeast(_ major: Int, _ minor: Int) -> Bool { self >= SDBVersion(major: major, minor: minor) }

    static func < (a: SDBVersion, b: SDBVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }

    var description: String { "\(major).\(minor)" }

    /// Что объявить рантайму и с какой версией потом разбирать ответы:
    /// поле, которого нет у одной из сторон, не пишет ни одна.
    static func negotiate(runtime: SDBVersion) -> (announce: SDBVersion, effective: SDBVersion) {
        let announce = SDBVersion(major: 2, minor: runtime.atLeast(2, SDB.newestMinor) ? SDB.newestMinor : SDB.fallbackMinor)
        return (announce, min(runtime, announce))
    }
}

enum SDBError: Error, LocalizedError, Equatable {
    case malformed(String)
    case remote(command: String, code: Int)
    case disconnected
    case timeout(String)
    case connect(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let what): return "Непонятный ответ отладчика Mono: \(what)"
        case .remote(let command, let code): return "\(command): \(SDB.describe(error: code))"
        case .disconnected: return "Связь с отладчиком Mono прервалась"
        case .timeout(let what): return "Mono не ответил: \(what)"
        case .connect(let what): return what
        }
    }

    var code: Int? {
        if case .remote(_, let code) = self { return code }
        return nil
    }
}

// MARK: - Кодек

struct SDBWriter {
    private(set) var bytes: [UInt8] = []

    @discardableResult mutating func byte(_ v: UInt8) -> SDBWriter { bytes.append(v); return self }

    @discardableResult mutating func int(_ v: Int32) -> SDBWriter {
        let u = UInt32(bitPattern: v)
        bytes += [UInt8(u >> 24 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]
        return self
    }

    @discardableResult mutating func int(_ v: Int) -> SDBWriter { int(Int32(truncatingIfNeeded: v)) }

    /// Идентификаторы в протоколе — 4 байта, хоть в C# они и long.
    @discardableResult mutating func id(_ v: Int) -> SDBWriter { int(Int32(truncatingIfNeeded: v)) }

    @discardableResult mutating func long(_ v: Int64) -> SDBWriter {
        int(Int32(truncatingIfNeeded: v >> 32))
        return int(Int32(truncatingIfNeeded: v & 0xffff_ffff))
    }

    @discardableResult mutating func bool(_ v: Bool) -> SDBWriter { byte(v ? 1 : 0) }

    @discardableResult mutating func string(_ s: String) -> SDBWriter {
        let utf8 = Array(s.utf8)
        int(utf8.count)
        bytes += utf8
        return self
    }

    mutating func modifier(_ modifier: SDB.Modifier, version: SDBVersion) {
        switch modifier {
        case .count(let n):
            byte(1); int(n)
        case .threadOnly(let thread):
            byte(3); id(thread)
        case .location(let method, let offset):
            byte(7); id(method); long(offset)
        case .step(let thread, let size, let depth):
            byte(10); id(thread); int(size.rawValue); int(depth.rawValue)
            if version.atLeast(2, 16) { int(SDB.stepFilter) }
        case .sourceFiles(let files):
            byte(12); int(files.count)
            for file in files { string(file) }
        }
    }

    /// Пакет команды целиком: длина, номер, флаги, набор, команда, данные.
    static func packet(id: Int32, set: UInt8, command: UInt8, body: [UInt8]) -> [UInt8] {
        var w = SDBWriter()
        w.int(Int32(SDB.headerLength + body.count))
        w.int(id)
        w.byte(0)
        w.byte(set)
        w.byte(command)
        return w.bytes + body
    }
}

struct SDBReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var hasMore: Bool { offset < bytes.count }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, offset + n <= bytes.count else {
            throw SDBError.malformed("пакет короче, чем ожидалось (\(offset)+\(n) из \(bytes.count))")
        }
        defer { offset += n }
        return bytes[offset..<offset + n]
    }

    mutating func byte() throws -> UInt8 { try take(1).first! }

    mutating func short() throws -> Int {
        let b = try take(2)
        return Int(b[b.startIndex]) << 8 | Int(b[b.startIndex + 1])
    }

    mutating func int() throws -> Int32 {
        let b = try take(4)
        let s = b.startIndex
        let u = UInt32(b[s]) << 24 | UInt32(b[s + 1]) << 16 | UInt32(b[s + 2]) << 8 | UInt32(b[s + 3])
        return Int32(bitPattern: u)
    }

    mutating func count() throws -> Int {
        let n = Int(try int())
        // Число элементов больше самого пакета — значит, мы читаем не то поле.
        guard n >= 0, n <= bytes.count else { throw SDBError.malformed("длина \(n)") }
        return n
    }

    mutating func id() throws -> Int { Int(try int()) }

    mutating func long() throws -> Int64 {
        let high = UInt64(UInt32(bitPattern: try int()))
        let low = UInt64(UInt32(bitPattern: try int()))
        return Int64(bitPattern: high << 32 | low)
    }

    mutating func bool() throws -> Bool { try byte() != 0 }

    mutating func string() throws -> String {
        let n = try count()
        return String(decoding: try take(n), as: UTF8.self)
    }

    mutating func utf16String() throws -> String {
        let n = try count()
        let raw = try take(n)
        var units: [UInt16] = []
        units.reserveCapacity(n / 2)
        var i = raw.startIndex
        while i + 1 < raw.endIndex {
            units.append(UInt16(raw[i]) | UInt16(raw[i + 1]) << 8)   // UTF-16LE
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func float() throws -> Float { Float(bitPattern: UInt32(bitPattern: try int())) }

    mutating func double() throws -> Double { Double(bitPattern: UInt64(bitPattern: try long())) }

    mutating func value(_ version: SDBVersion) throws -> SDBValue {
        let tag = try byte()
        guard let element = SDB.Element(rawValue: tag) else {
            throw SDBError.malformed("тип значения 0x\(String(tag, radix: 16))")
        }
        switch element {
        case .void: return .void
        case .boolean: return .bool(try int() != 0)
        case .char: return .char(UInt16(truncatingIfNeeded: try int()))
        case .i1: return .int(Int64(Int8(truncatingIfNeeded: try int())), element)
        case .u1: return .int(Int64(UInt8(truncatingIfNeeded: try int())), element)
        case .i2: return .int(Int64(Int16(truncatingIfNeeded: try int())), element)
        case .u2: return .int(Int64(UInt16(truncatingIfNeeded: try int())), element)
        case .i4: return .int(Int64(try int()), element)
        case .u4: return .int(Int64(UInt32(bitPattern: try int())), element)
        case .i8, .i: return .int(try long(), element)
        case .u8, .u: return .uint(UInt64(bitPattern: try long()), element)
        case .r4: return .float(Double(try float()))
        case .r8: return .double(try double())
        case .ptr:
            let address = try long()
            if version.atLeast(2, 46) { _ = try id() }
            return .pointer(address)
        case .string, .szArray, .klass, .array, .object:
            let object = try id()
            return object == 0 ? .null : .object(object, element)
        case .valueType:
            let isEnum = try byte() == 1
            if version.atLeast(2, 61) { _ = try byte() }            // упакован ли
            let type = try id()
            var inline = -1
            if version.atLeast(2, 65) { inline = Int(try int()) }
            let n = try count()
            var fields: [SDBValue] = []
            for _ in 0..<n { fields.append(try value(version)) }
            // Inline-массив: первый элемент — он же первое поле.
            if inline > 1 { for _ in 1..<inline { _ = try value(version) } }
            return .valueType(type: type, isEnum: isEnum, fields: fields)
        case .null:
            if version.atLeast(2, 59) {
                let kind = try byte()
                if kind == SDB.Element.szArray.rawValue || kind == SDB.Element.array.rawValue {
                    let elementKind = try byte()
                    _ = try int()                                       // ранг
                    if elementKind == SDB.Element.klass.rawValue { _ = try int() }
                    _ = try int()
                } else {
                    _ = try int()
                }
            }
            return .null
        case .typeRef: return .typeRef(try id())
        case .parentVType: return .parentVType(Int(try int()))
        case .fixedArray:
            let kind = try byte()
            let n = try count()
            var items: [SDBValue] = []
            for _ in 0..<n {
                switch SDB.Element(rawValue: kind) {
                case .i8, .u8: items.append(.int(try long(), .i8))
                case .r4: items.append(.float(Double(try float())))
                case .r8: items.append(.double(try double()))
                case .boolean: items.append(.bool(try int() != 0))
                case .char: items.append(.char(UInt16(truncatingIfNeeded: try int())))
                default: items.append(.int(Int64(try int()), .i4))
                }
            }
            return .fixedArray(items)
        }
    }
}

/// Значение из ответа Mono. Объекты — только ссылкой: содержимое читается,
/// когда человек развернёт узел.
indirect enum SDBValue: Equatable {
    case void
    case null
    case bool(Bool)
    case char(UInt16)
    case int(Int64, SDB.Element)
    case uint(UInt64, SDB.Element)
    case float(Double)
    case double(Double)
    case pointer(Int64)
    case object(Int, SDB.Element)
    case valueType(type: Int, isEnum: Bool, fields: [SDBValue])
    case typeRef(Int)
    case parentVType(Int)
    case fixedArray([SDBValue])

    /// Как значение выглядит без похода в рантайм. Строки и объекты
    /// так не показать — это делает отладчик.
    var primitiveText: String? {
        switch self {
        case .void: return "void"
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .char(let c):
            let scalar = Unicode.Scalar(c).map { String(Character($0)) } ?? "?"
            return "\(c) '\(scalar)'"
        case .int(let v, _): return String(v)
        case .uint(let v, _): return String(v)
        case .float(let v): return Self.format(v, float: true)
        case .double(let v): return Self.format(v, float: false)
        case .pointer(let p): return "0x" + String(UInt64(bitPattern: p), radix: 16)
        default: return nil
        }
    }

    var primitiveTypeName: String? {
        switch self {
        case .bool: return "bool"
        case .char: return "char"
        case .float: return "float"
        case .double: return "double"
        case .int(_, let e), .uint(_, let e):
            switch e {
            case .i1: return "sbyte"
            case .u1: return "byte"
            case .i2: return "short"
            case .u2: return "ushort"
            case .i4: return "int"
            case .u4: return "uint"
            case .i8: return "long"
            case .u8: return "ulong"
            case .i: return "nint"
            case .u: return "nuint"
            default: return nil
            }
        default: return nil
        }
    }

    private static func format(_ v: Double, float: Bool) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v > 0 ? "∞" : "-∞" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return float ? String(Float(v)) : String(v)
    }
}

/// Событие от Mono. Разные виды несут разное, общее — поток и id объекта.
struct SDBEvent: Equatable {
    var kind: SDB.EventKind
    var request: Int32
    var thread: Int
    /// Метод (точка останова, шаг), тип (загрузка типа), исключение (объект).
    var id: Int = 0
    var location: Int64 = 0
    var exitCode: Int32 = 0
    var message: String?

    /// Разбор составного события: политика приостановки и список.
    static func parseComposite(_ reader: inout SDBReader, version: SDBVersion) throws -> (SDB.SuspendPolicy, [SDBEvent]) {
        let policy = SDB.SuspendPolicy(rawValue: try reader.byte()) ?? .all
        let n = try reader.count()
        var events: [SDBEvent] = []
        for _ in 0..<n {
            let raw = try reader.byte()
            guard let kind = SDB.EventKind(rawValue: raw) else {
                // Неизвестный вид — дальше в пакете не разобрать ничего.
                throw SDBError.malformed("вид события \(raw)")
            }
            let request = try reader.int()
            let thread = try reader.id()
            var event = SDBEvent(kind: kind, request: request, thread: thread)
            switch kind {
            case .vmStart, .threadStart, .threadDeath, .userBreak, .keepAlive:
                break
            case .vmDeath:
                if version.atLeast(2, 27) { event.exitCode = try reader.int() }
            case .crash:
                _ = try reader.long()
                event.message = try reader.string()
            case .assemblyLoad, .assemblyUnload, .typeLoad, .methodEntry, .methodExit,
                 .appDomainCreate, .appDomainUnload, .exception, .methodUpdate:
                event.id = try reader.id()
            case .breakpoint, .step:
                event.id = try reader.id()
                event.location = try reader.long()
            case .userLog:
                _ = try reader.int()
                _ = try reader.string()
                event.message = try reader.string()
            case .encUpdate:
                throw SDBError.malformed("событие EnC")
            }
            events.append(event)
        }
        return (policy, events)
    }
}

// MARK: - Отладочная информация метода

/// Точки следования метода: смещение IL и строка исходника. Отсюда и
/// «куда поставить точку останова», и «на какой строке стоит кадр».
struct SDBDebugInfo: Equatable {
    struct Point: Equatable {
        var offset: Int
        var line: Int
        /// Индекс в `files`; -1 — неизвестно.
        var file: Int
    }
    var files: [String]
    var points: [Point]

    static func parse(_ reader: inout SDBReader, version: SDBVersion) throws -> SDBDebugInfo {
        _ = try reader.int()                                         // max_il_offset
        var files: [String] = []
        if version.atLeast(2, 13) {
            let n = try reader.count()
            for _ in 0..<n {
                files.append(try reader.string())
                if version.atLeast(2, 14) { for _ in 0..<16 { _ = try reader.byte() } }   // хеш
            }
        } else {
            files.append(try reader.string())
        }
        let n = try reader.count()
        var points: [Point] = []
        points.reserveCapacity(n)
        for _ in 0..<n {
            let offset = Int(try reader.int())
            let line = Int(try reader.int())
            var file = files.isEmpty ? -1 : 0
            if version.atLeast(2, 12) { file = Int(try reader.int()) }
            if version.atLeast(2, 19) { _ = try reader.int() }      // столбец
            if version.atLeast(2, 32) { _ = try reader.int(); _ = try reader.int() }   // конец
            points.append(Point(offset: offset, line: line, file: file))
        }
        return SDBDebugInfo(files: files, points: points)
    }

    func file(of point: Point) -> String? {
        point.file >= 0 && point.file < files.count ? files[point.file] : nil
    }

    /// Строка, на которой стоит кадр: последняя точка не дальше смещения.
    /// Строки у Mono с единицы; 0xfeefee — «скрытая» точка, её пропускаем.
    func location(at offset: Int) -> (file: String?, line: Int)? {
        var best: Point?
        for point in points where point.offset <= offset && point.line > 0 && point.line != 0xfeefee {
            if best == nil || point.offset >= best!.offset { best = point }
        }
        guard let best else { return nil }
        return (file(of: best), best.line)
    }

    /// Строки метода в этом файле — чтобы понять, какой метод ближе всех
    /// обнимает строку точки останова.
    func lines(in file: (String) -> Bool) -> ClosedRange<Int>? {
        let mine = points.filter { $0.line > 0 && $0.line != 0xfeefee && (self.file(of: $0).map(file) ?? false) }
        guard let lo = mine.map(\.line).min(), let hi = mine.map(\.line).max() else { return nil }
        return lo...hi
    }
}

/// Где поставить точку останова на строке `line` (с единицы): у самой
/// строки или, если на ней кода нет, у первой строки ниже в том же методе.
/// Из методов, чьи строки её обнимают, берётся самый тесный — лямбда
/// внутри метода, а не сам метод. Возвращает смещение и настоящую строку.
struct SDBLineResolver {
    struct Candidate {
        var method: Int
        var info: SDBDebugInfo
    }

    static func resolve(line: Int, in candidates: [Candidate],
                        matches: (String) -> Bool) -> [(method: Int, offset: Int, line: Int)] {
        var scored: [(span: Int, method: Int, offset: Int, line: Int)] = []
        for candidate in candidates {
            guard let range = candidate.info.lines(in: matches), range.contains(line) else { continue }
            let points = candidate.info.points.filter {
                $0.line >= line && $0.line != 0xfeefee && (candidate.info.file(of: $0).map(matches) ?? false)
            }
            guard let first = points.min(by: { ($0.line, $0.offset) < ($1.line, $1.offset) }) else { continue }
            scored.append((range.count, candidate.method, first.offset, first.line))
        }
        guard let tightest = scored.map(\.span).min() else { return [] }
        // Одна и та же строка бывает в нескольких экземплярах метода
        // (обобщённые) — ставим во все самые тесные.
        return scored.filter { $0.span == tightest }.map { ($0.method, $0.offset, $0.line) }
    }

    /// Путь из PDB и файл на диске — один и тот же? Unity пишет пути то
    /// полными, то от корня проекта, поэтому относительный сравнивается
    /// как хвост. Регистр не важен: файловая система macOS к нему глуха.
    static func pdbPath(_ pdb: String, matches file: String) -> Bool {
        let a = pdb.replacingOccurrences(of: "\\", with: "/").lowercased()
        let b = file.lowercased()
        if a.hasPrefix("/") { return (a as NSString).standardizingPath == (b as NSString).standardizingPath }
        let tail = a.hasPrefix("./") ? String(a.dropFirst(2)) : a
        return b == tail || b.hasSuffix("/" + tail)
    }
}

/// Имена из рантайма — в то, как их пишут в C#.
enum SDBNames {
    /// Имя типа как у Mono — `List`1[[System.Int32, mscorlib, …]]` — в
    /// привычное `List<int>`. Пространства имён у аргументов убираем:
    /// в столбце типа они только мешают читать.
    static func pretty(_ name: String) -> String {
        var chars = Array(name)
        var i = 0
        func parse(short: Bool) -> String {
            var head = ""
            while i < chars.count, chars[i] != "[", chars[i] != "]", chars[i] != ",", chars[i] != "`" {
                head.append(chars[i]); i += 1
            }
            var args: [String] = []
            if i < chars.count, chars[i] == "`" {
                i += 1
                while i < chars.count, chars[i].isNumber { i += 1 }
                if i + 1 < chars.count, chars[i] == "[", chars[i + 1] == "[" {
                    i += 1
                    while i < chars.count, chars[i] == "[" {
                        i += 1
                        args.append(parse(short: true))
                        // Имя сборки после запятой — до закрывающей скобки.
                        var depth = 0
                        while i < chars.count {
                            if chars[i] == "[" { depth += 1 }
                            if chars[i] == "]" { if depth == 0 { break }; depth -= 1 }
                            i += 1
                        }
                        i += 1                                          // ]
                        if i < chars.count, chars[i] == "," { i += 1 }
                    }
                    i += 1                                              // ]
                }
            }
            var suffix = ""
            while i + 1 < chars.count, chars[i] == "[", chars[i + 1] == "]" { suffix += "[]"; i += 2 }
            if short, let dot = head.lastIndex(of: ".") { head = String(head[head.index(after: dot)...]) }
            head = csharpAlias[head] ?? csharpAlias["System." + head].flatMap { short ? $0 : nil } ?? head
            return args.isEmpty ? head + suffix : head + "<" + args.joined(separator: ", ") + ">" + suffix
        }
        let result = parse(short: false)
        chars = []
        return result.isEmpty ? name : result
    }

    /// `System.Collections.Generic.List<int>` → `List<int>`.
    static func short(_ full: String) -> String {
        let generic = full.firstIndex(of: "<") ?? full.endIndex
        let head = full[..<generic]
        guard let dot = head.lastIndex(of: ".") else { return full }
        return String(full[full.index(after: dot)...])
    }

    private static let csharpAlias: [String: String] = [
        "System.Int32": "int", "System.Int64": "long", "System.Int16": "short", "System.Byte": "byte",
        "System.SByte": "sbyte", "System.UInt32": "uint", "System.UInt64": "ulong", "System.UInt16": "ushort",
        "System.Single": "float", "System.Double": "double", "System.Boolean": "bool", "System.Char": "char",
        "System.String": "string", "System.Object": "object", "System.Decimal": "decimal",
    ]

    /// `<Health>k__BackingField` — это свойство `Health`.
    static func field(_ name: String) -> String {
        if name.hasPrefix("<"), let end = name.firstIndex(of: ">"), name.hasSuffix("k__BackingField") {
            return String(name[name.index(after: name.startIndex)..<end])
        }
        return name
    }

    /// Строка — в кавычках и с экранированием, длинная — обрезанной.
    static func quote(_ text: String) -> String {
        var clipped = text
        if clipped.count > 500 { clipped = String(clipped.prefix(500)) + "…" }
        let escaped = clipped
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
