import Foundation

/// Имя типа так, как его хранят метаданные: пространство имён отдельно,
/// а вложенные типы — цепочкой от внешнего к внутреннему.
struct TypeName: Equatable {
    var namespace: String
    var path: [String]

    var simple: String { path.map(TypeName.withoutArity).joined(separator: ".") }

    var full: String { namespace.isEmpty ? simple : namespace + "." + simple }

    /// `List`1` → `List`: число параметров в имени типа C# не пишут.
    static func withoutArity(_ name: String) -> String {
        guard let tick = name.lastIndex(of: "`"), name[name.index(after: tick)...].allSatisfy(\.isNumber)
        else { return name }
        return String(name[..<tick])
    }

    /// Сколько параметров дописано к имени: `Dictionary`2` — два.
    static func arity(_ name: String) -> Int {
        guard let tick = name.lastIndex(of: "`") else { return 0 }
        return Int(name[name.index(after: tick)...]) ?? 0
    }
}

/// Тип из сигнатуры ECMA-335 §II.23.2.12.
indirect enum TypeSignature {
    /// Встроенный тип: уже словом C# — `int`, `string`, `void`.
    case keyword(String)
    case named(TypeName)
    case instance(TypeSignature, [TypeSignature])
    case array(TypeSignature, rank: Int)
    case pointer(TypeSignature)
    case byRef(TypeSignature)
    /// Параметр типа: `T` у типа (`method` = false) или у метода.
    case variable(index: Int, method: Bool)
    case functionPointer
    case unknown

    /// Тип, на который ссылается объявление, без `ref` и массивов —
    /// по нему узнаётся, например, перечисление среди аргументов атрибута.
    var elementName: TypeName? {
        switch self {
        case .named(let name):         return name
        case .instance(let base, _):   return base.elementName
        case .array(let of, _),
             .pointer(let of),
             .byRef(let of):           return of.elementName
        default:                       return nil
        }
    }
}

struct MethodSignature {
    var hasThis = false
    var genericCount = 0
    var returnType: TypeSignature = .keyword("void")
    var parameters: [TypeSignature] = []
}

/// Разбор сигнатуры из кучи блобов.
///
/// Сигнатура — это байты, в которых типы записаны деревом; всё, что не
/// разобралось, становится `.unknown`, и объявление просто выйдет менее
/// подробным. Ошибок здесь нет: сборку показывают, а не проверяют.
struct SignatureParser {
    private let bytes: ArraySlice<UInt8>
    private var cursor: Int
    /// Токен TypeDefOrRef → имя типа; его умеет только читатель таблиц.
    private let resolve: (UInt32) -> TypeSignature

    init(_ bytes: ArraySlice<UInt8>, resolve: @escaping (UInt32) -> TypeSignature) {
        self.bytes = bytes
        self.cursor = bytes.startIndex
        self.resolve = resolve
    }

    private mutating func byte() -> UInt8 {
        guard cursor < bytes.endIndex else { return 0 }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    private mutating func peek() -> UInt8 {
        cursor < bytes.endIndex ? bytes[cursor] : 0
    }

    /// Сжатое число ECMA-335 §II.23.2: длину видно по старшим битам первого байта.
    private mutating func number() -> Int {
        let first = UInt32(byte())
        if first & 0x80 == 0 { return Int(first) }
        if first & 0xC0 == 0x80 { return Int(((first & 0x3F) << 8) | UInt32(byte())) }
        let rest = (UInt32(byte()) << 16) | (UInt32(byte()) << 8) | UInt32(byte())
        return Int(((first & 0x1F) << 24) | rest)
    }

    // MARK: - Виды сигнатур

    /// Поле: `FIELD` и тип.
    static func fieldType(_ bytes: ArraySlice<UInt8>,
                          resolve: @escaping (UInt32) -> TypeSignature) -> TypeSignature {
        var parser = SignatureParser(bytes, resolve: resolve)
        _ = parser.byte()                                  // 0x06
        return parser.type()
    }

    /// Метод: соглашение о вызове, число параметров, возвращаемый тип, параметры.
    static func method(_ bytes: ArraySlice<UInt8>,
                       resolve: @escaping (UInt32) -> TypeSignature) -> MethodSignature {
        var parser = SignatureParser(bytes, resolve: resolve)
        var signature = MethodSignature()
        let flags = parser.byte()
        signature.hasThis = flags & 0x20 != 0
        if flags & 0x10 != 0 { signature.genericCount = parser.number() }
        let count = parser.number()
        signature.returnType = parser.type()
        for _ in 0..<min(count, 512) {
            if parser.peek() == 0x41 { _ = parser.byte() }  // SENTINEL — дальше vararg
            signature.parameters.append(parser.type())
        }
        return signature
    }

    /// Свойство: тип и параметры индексатора.
    static func property(_ bytes: ArraySlice<UInt8>,
                         resolve: @escaping (UInt32) -> TypeSignature)
    -> (type: TypeSignature, parameters: [TypeSignature]) {
        var parser = SignatureParser(bytes, resolve: resolve)
        _ = parser.byte()                                  // 0x08 | HASTHIS
        let count = parser.number()
        let type = parser.type()
        var parameters: [TypeSignature] = []
        for _ in 0..<min(count, 512) { parameters.append(parser.type()) }
        return (type, parameters)
    }

    // MARK: - Тип

    mutating func type() -> TypeSignature {
        switch byte() {
        case 0x01: return .keyword("void")
        case 0x02: return .keyword("bool")
        case 0x03: return .keyword("char")
        case 0x04: return .keyword("sbyte")
        case 0x05: return .keyword("byte")
        case 0x06: return .keyword("short")
        case 0x07: return .keyword("ushort")
        case 0x08: return .keyword("int")
        case 0x09: return .keyword("uint")
        case 0x0A: return .keyword("long")
        case 0x0B: return .keyword("ulong")
        case 0x0C: return .keyword("float")
        case 0x0D: return .keyword("double")
        case 0x0E: return .keyword("string")
        case 0x0F: return .pointer(type())
        case 0x10: return .byRef(type())
        case 0x11, 0x12:
            return resolve(UInt32(number()))
        case 0x13: return .variable(index: number(), method: false)
        case 0x14:
            let element = type()
            let rank = number()
            for _ in 0..<min(number(), 64) { _ = number() }         // размеры
            for _ in 0..<min(number(), 64) { _ = number() }         // нижние границы
            return .array(element, rank: max(rank, 1))
        case 0x15:
            _ = byte()                                              // CLASS или VALUETYPE
            let base = resolve(UInt32(number()))
            let count = min(number(), 64)
            var arguments: [TypeSignature] = []
            for _ in 0..<count { arguments.append(type()) }
            return .instance(base, arguments)
        case 0x16: return .keyword("TypedReference")
        case 0x18: return .keyword("IntPtr")
        case 0x19: return .keyword("UIntPtr")
        case 0x1B:
            _ = SignatureParser.method(bytes[cursor...], resolve: resolve)
            cursor = bytes.endIndex                                 // дальше по такой сигнатуре не идём
            return .functionPointer
        case 0x1C: return .keyword("object")
        case 0x1D: return .array(type(), rank: 1)
        case 0x1E: return .variable(index: number(), method: true)
        case 0x1F, 0x20:
            _ = number()                                            // модификатор — на объявление не влияет
            return type()
        case 0x45: return type()                                    // pinned
        default:   return .unknown
        }
    }
}
