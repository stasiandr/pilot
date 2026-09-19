import Foundation

/// Сборка .NET, показанная как C#.
///
/// Исходников у собранной библиотеки нет, но есть метаданные: типы, их
/// члены, сигнатуры, атрибуты и константы. Из них складывается текст,
/// который читают как обычный C#-файл — с подсветкой, структурой (`⌘⇧O`)
/// и переходами внутри файла. Тела методов не восстанавливаются: в
/// метаданных лежит IL, а перевод IL в C# — это отдельная среда, не
/// редактор, который открывается мгновенно.
enum AssemblySource {

    /// Расширения, за которыми может стоять сборка .NET.
    static let extensions: Set<String> = ["dll", "exe", "winmd"]

    static func isAssembly(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Имя сборки из шапки декомпилированного файла — или nil, если это
    /// обычный исходник.
    ///
    /// Языковой сервер (Roslyn, а до него Visual Studio и Rider) начинает
    /// такой файл строкой `#region Assembly UnityEngine.CoreModule,
    /// Version=…`. По ней Pilot и узнаёт чужой код в своём кэше: где лежит
    /// этот кэш, сервер нигде не объявляет, а шапку пишет всегда.
    static func decompiledAssembly(inHeader text: String) -> String? {
        var line = Substring(text.prefix { !$0.isNewline })
        if line.first == "\u{FEFF}" { line = line.dropFirst() }      // Roslyn пишет файл с BOM
        let marker = "#region Assembly "
        guard line.hasPrefix(marker) else { return nil }
        let name = line.dropFirst(marker.count).prefix { $0 != "," }
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Текст сборки. Бросает, если это не .NET-библиотека, а нативная
    /// или битый файл. Синхронный и не из главного потока: на крупной
    /// сборке разбор идёт десятки миллисекунд.
    ///
    /// Сборку читает Rustlyn, если он есть: тот же ECMA-335, но его читатель
    /// ещё и разбирает IL, поэтому у тел методов появляется содержимое —
    /// см. `methodBody(of:line:)`. И его ответ кэшируется по отпечатку
    /// файла: сборка — это большой файл, который почти никогда не меняется,
    /// то есть ровно тот случай, ради которого кэш и нужен. Второе открытие
    /// `System.Runtime` читает маленький файл вместо большого.
    ///
    /// Свой читатель остаётся на случай, когда Rustlyn не собран: тогда
    /// объявления будут, а тел не будет — как было до этого.
    static func text(of url: URL) throws -> String {
        if let rustlyn = Rustlyn.shared, let text = rustlyn.assemblyText(url) {
            return text
        }
        let metadata = try AssemblyMetadata(url: url)
        return AssemblyPrinter(metadata: metadata, fileName: url.lastPathComponent).render()
    }

    /// IL метода, объявленного в строке `line` уже показанного текста сборки.
    ///
    /// Второй вопрос, который задают по одному: поверхность сборки — это
    /// один проход по таблицам и ни одной инструкции, а тело читают у того
    /// метода, который открыли. Возвращает `nil`, если в этой строке
    /// объявления метода нет или Rustlyn не собран.
    ///
    /// Это IL, а не восстановленный C#. Перевод IL обратно в исходник —
    /// отдельная программа (ILSpy внутри Roslyn делает именно это), и
    /// честный дизассемблер с разрешёнными именами полезнее уверенной
    /// выдумки: видно, что метод на самом деле делает, и видно, что это не
    /// тот текст, который писали.
    static func methodBody(of url: URL, line: Int) -> String? {
        guard let rustlyn = Rustlyn.shared,
              let token = rustlyn.methodToken(url, line: line) else { return nil }
        return rustlyn.methodBody(url, token: token)
    }

    /// То же для уже прочитанных байтов — так сборку разбирают тесты.
    static func text(bytes: [UInt8], fileName: String) throws -> String {
        AssemblyPrinter(metadata: try AssemblyMetadata(bytes: bytes), fileName: fileName).render()
    }
}

/// Сборка типов и членов в текст. Живёт на один файл: все карты строятся
/// разом, потому что каждая нужна и при выводе типа, и при выводе члена.
private final class AssemblyPrinter {

    private let metadata: AssemblyMetadata
    private let fileName: String

    /// Вложенный тип → внешний, и обратно.
    private var enclosing: [Int: Int] = [:]
    private var nested: [Int: [Int]] = [:]
    /// Тип → реализуемые интерфейсы (токены TypeDefOrRef).
    private var interfaces: [Int: [UInt32]] = [:]
    /// Тип → диапазон свойств и событий.
    private var propertyRange: [Int: Range<Int>] = [:]
    private var eventRange: [Int: Range<Int>] = [:]
    /// Свойство и событие → методы, которые их читают и пишут.
    private var propertyAccessors: [Int: [(kind: UInt32, method: Int)]] = [:]
    private var eventAccessors: [Int: [(kind: UInt32, method: Int)]] = [:]
    /// Метод → тип, которому он принадлежит.
    private var ownerOfMethod: [Int: Int] = [:]
    /// Параметры обобщённого типа или метода и ограничения на них.
    private var genericParameters: [Key: [Int]] = [:]
    private var constraints: [Int: [UInt32]] = [:]
    /// Значения по умолчанию и константы.
    private var constants: [Key: Int] = [:]
    /// Атрибуты, навешанные на строку таблицы.
    private var attributes: [Key: [Int]] = [:]
    /// Метод с `DllImport` → имя библиотеки.
    private var imports: [Int: String] = [:]
    /// Имя типа атрибута по строке CustomAttribute: одни и те же атрибуты
    /// спрашивают по нескольку раз на каждый член.
    private var attributeNames: [Int: TypeName] = [:]
    /// Полное имя типа → его строка: нужен, чтобы узнать перечисление
    /// в аргументах атрибута. Строится при первом же вопросе.
    private var typeDefIndex: [String: Int] = [:]
    /// Пространства имён самой сборки: их, как и `System`, в именах типов
    /// не повторяют — в исходнике они были бы закрыты `using`.
    private var ownNamespaces: Set<String> = []
    /// Готовый текст: собирается по кусочку, в порядке вывода.
    private var out = ""

    struct Key: Hashable {
        let table: Int
        let row: Int
        init(_ table: AssemblyMetadata.Table, _ row: Int) {
            self.table = table.rawValue
            self.row = row
        }
    }

    init(metadata: AssemblyMetadata, fileName: String) {
        self.metadata = metadata
        self.fileName = fileName
        buildMaps()
    }

    /// Строки таблицы, нумерованные с единицы; у пустой таблицы — ничего.
    private func rows(_ table: AssemblyMetadata.Table) -> Range<Int> {
        1..<(metadata.rowCount(table) + 1)
    }

    private func buildMaps() {
        for row in rows(.nestedClass) {
            let inner = Int(metadata.cell(.nestedClass, row, 0))
            let outer = Int(metadata.cell(.nestedClass, row, 1))
            enclosing[inner] = outer
            nested[outer, default: []].append(inner)
        }
        for row in rows(.interfaceImpl) {
            interfaces[Int(metadata.cell(.interfaceImpl, row, 0)), default: []]
                .append(metadata.cell(.interfaceImpl, row, 1))
        }
        for row in rows(.propertyMap) {
            propertyRange[Int(metadata.cell(.propertyMap, row, 0))] =
                metadata.range(.propertyMap, row, 1, into: .property)
        }
        for row in rows(.eventMap) {
            eventRange[Int(metadata.cell(.eventMap, row, 0))] = metadata.range(.eventMap, row, 1, into: .event)
        }
        for row in rows(.methodSemantics) {
            let kind = metadata.cell(.methodSemantics, row, 0)
            let method = Int(metadata.cell(.methodSemantics, row, 1))
            guard let owner = metadata.target(.hasSemantics, metadata.cell(.methodSemantics, row, 2)) else { continue }
            if owner.table == .property {
                propertyAccessors[owner.row, default: []].append((kind, method))
            } else {
                eventAccessors[owner.row, default: []].append((kind, method))
            }
        }
        for type in rows(.typeDef) {
            for method in metadata.range(.typeDef, type, 5, into: .methodDef) { ownerOfMethod[method] = type }
        }
        for row in rows(.genericParam) {
            guard let owner = metadata.target(.typeOrMethodDef, metadata.cell(.genericParam, row, 2)) else { continue }
            genericParameters[Key(owner.table, owner.row), default: []].append(row)
        }
        for list in genericParameters.keys {
            genericParameters[list]?.sort { metadata.cell(.genericParam, $0, 0) < metadata.cell(.genericParam, $1, 0) }
        }
        for row in rows(.genericParamConstraint) {
            constraints[Int(metadata.cell(.genericParamConstraint, row, 0)), default: []]
                .append(metadata.cell(.genericParamConstraint, row, 1))
        }
        for row in rows(.constant) {
            guard let owner = metadata.target(.hasConstant, metadata.cell(.constant, row, 1)) else { continue }
            constants[Key(owner.table, owner.row)] = row
        }
        for row in rows(.customAttribute) {
            guard let owner = metadata.target(.hasCustomAttribute, metadata.cell(.customAttribute, row, 0))
            else { continue }
            attributes[Key(owner.table, owner.row), default: []].append(row)
        }
        for row in rows(.typeDef) where enclosing[row] == nil {
            ownNamespaces.insert(metadata.string(.typeDef, row, 2))
        }
        for row in rows(.implMap) {
            guard let member = metadata.target(.memberForwarded, metadata.cell(.implMap, row, 1)),
                  member.table == .methodDef else { continue }
            imports[member.row] = metadata.string(.moduleRef, Int(metadata.cell(.implMap, row, 3)), 0)
        }
    }

    // MARK: - Имена типов

    /// Имя типа из строки TypeDef вместе с цепочкой внешних типов.
    private func nameOfTypeDef(_ row: Int) -> TypeName {
        var path = [metadata.string(.typeDef, row, 1)]
        var current = row
        while let outer = enclosing[current] {
            path.insert(metadata.string(.typeDef, outer, 1), at: 0)
            current = outer
        }
        return TypeName(namespace: metadata.string(.typeDef, current, 2), path: path)
    }

    /// То же для типа из другой сборки: вложенность видна по области видимости.
    private func nameOfTypeRef(_ row: Int) -> TypeName {
        var path = [metadata.string(.typeRef, row, 1)]
        var namespace = metadata.string(.typeRef, row, 2)
        var current = row
        var depth = 0
        while let scope = metadata.target(.resolutionScope, metadata.cell(.typeRef, current, 0)),
              scope.table == .typeRef, depth < 16 {
            path.insert(metadata.string(.typeRef, scope.row, 1), at: 0)
            namespace = metadata.string(.typeRef, scope.row, 2)
            current = scope.row
            depth += 1
        }
        return TypeName(namespace: namespace, path: path)
    }

    /// Токен TypeDefOrRef → тип. `TypeSpec` — это уже сигнатура, её разбираем.
    private func typeSignature(token: UInt32) -> TypeSignature {
        guard let target = metadata.target(.typeDefOrRef, token) else { return .unknown }
        switch target.table {
        case .typeDef: return .named(nameOfTypeDef(target.row))
        case .typeRef: return .named(nameOfTypeRef(target.row))
        case .typeSpec:
            var parser = SignatureParser(metadata.blob(.typeSpec, target.row, 0)) { [weak self] token in
                self?.typeSignature(token: token) ?? .unknown
            }
            return parser.type()
        default: return .unknown
        }
    }

    private func resolver() -> (UInt32) -> TypeSignature {
        { [weak self] token in self?.typeSignature(token: token) ?? .unknown }
    }
}

// MARK: - Вывод

private extension AssemblyPrinter {

    static let indentUnit = "    "

    func line(_ indent: Int, _ code: String) {
        out += String(repeating: Self.indentUnit, count: indent)
        out += code
        out += "\n"
    }

    func render() -> String {
        out.reserveCapacity(1 << 18)

        // Типы верхнего уровня, разложенные по пространствам имён: так их
        // и читают, а порядок строк в метаданных читателю ничего не говорит.
        var byNamespace: [String: [Int]] = [:]
        var count = 0
        for row in rows(.typeDef) where enclosing[row] == nil && !isHidden(type: row) {
            byNamespace[metadata.string(.typeDef, row, 2), default: []].append(row)
            count += 1
        }
        writeHeader(types: count)
        for namespace in byNamespace.keys.sorted() {
            let types = (byNamespace[namespace] ?? []).sorted {
                metadata.string(.typeDef, $0, 1) < metadata.string(.typeDef, $1, 1)
            }
            if namespace.isEmpty {
                for type in types { write(type: type, indent: 0, namespace: namespace) }
            } else {
                out += "\n"
                line(0, "namespace \(namespace)")
                line(0, "{")
                for (position, type) in types.enumerated() {
                    if position > 0 { out += "\n" }
                    write(type: type, indent: 1, namespace: namespace)
                }
                line(0, "}")
            }
        }
        return out
    }

    func writeHeader(types: Int) {
        line(0, "// \(fileName)")
        if metadata.rowCount(.assembly) > 0 {
            var parts = [metadata.string(.assembly, 1, 7)]
            let version = (1...4).map { String(metadata.cell(.assembly, 1, $0)) }.joined(separator: ".")
            parts.append("Version=\(version)")
            let culture = metadata.string(.assembly, 1, 8)
            parts.append("Culture=" + (culture.isEmpty ? "neutral" : culture))
            line(0, "// " + parts.joined(separator: ", "))
        }
        line(0, "// Типов верхнего уровня: \(types). Из метаданных видны объявления,")
        line(0, "// тела методов в C# не восстанавливаются.")
    }

    // MARK: - Тип

    /// Служебные типы компилятора — замыкания, итераторы, `<Module>`:
    /// в исходниках их не писали, читать там нечего.
    func isHidden(type row: Int) -> Bool {
        let name = metadata.string(.typeDef, row, 1)
        if name.isEmpty || name.contains("<") || name.contains(">") { return true }
        return has(attribute: "System.Runtime.CompilerServices.CompilerGeneratedAttribute",
                   on: Key(.typeDef, row)) && enclosing[row] != nil
    }

    func write(type row: Int, indent: Int, namespace: String) {
        let flags = metadata.cell(.typeDef, row, 0)
        let name = metadata.string(.typeDef, row, 1)
        let base = typeSignature(token: metadata.cell(.typeDef, row, 3))
        let baseName = base.elementName?.full ?? ""
        let parameters = genericParameters[Key(.typeDef, row)] ?? []
        let scope = Scope(namespace: namespace, typeParameters: parameters.map { metadata.string(.genericParam, $0, 3) })

        writeAttributes(on: Key(.typeDef, row), indent: indent, scope: scope)

        var words = [visibility(ofType: flags)]
        let isInterface = flags & 0x20 != 0
        let isEnum = baseName == "System.Enum"
        let isDelegate = baseName == "System.MulticastDelegate" || baseName == "System.Delegate"
        let isStruct = baseName == "System.ValueType"

        if isDelegate {
            // Делегат — это класс с методом Invoke; в C# он пишется строкой.
            var returns = "void", list = "()"
            if let invoke = metadata.range(.typeDef, row, 5, into: .methodDef)
                .first(where: { metadata.string(.methodDef, $0, 3) == "Invoke" }) {
                let signature = SignatureParser.method(metadata.blob(.methodDef, invoke, 4), resolve: resolver())
                returns = csharp(signature.returnType, scope)
                list = parameterList(method: invoke, types: signature.parameters, scope: scope)
            }
            line(indent, "\(words.joined(separator: " ")) delegate \(returns) "
                 + "\(TypeName.withoutArity(name))\(genericList(parameters, scope: scope))\(list)"
                 + constraintSuffix(parameters, scope: scope) + ";")
            return
        }

        if isInterface {
            words.append("interface")
        } else if isEnum {
            words.append("enum")
        } else if isStruct {
            if has(attribute: "System.Runtime.CompilerServices.IsByRefLikeAttribute", on: Key(.typeDef, row)) {
                words.append("ref")
            }
            if has(attribute: "System.Runtime.CompilerServices.IsReadOnlyAttribute", on: Key(.typeDef, row)) {
                words.append("readonly")
            }
            words.append("struct")
        } else {
            let abstract = flags & 0x80 != 0, sealed = flags & 0x100 != 0
            if abstract && sealed { words.append("static") }
            else if abstract { words.append("abstract") }
            else if sealed { words.append("sealed") }
            words.append("class")
        }

        var declaration = words.joined(separator: " ") + " " + TypeName.withoutArity(name)
            + genericList(parameters, scope: scope)

        // Список наследования: базовый тип, кроме подразумеваемого, и интерфейсы.
        var inherits: [String] = []
        if isEnum {
            let underlying = enumUnderlying(row)
            if underlying != "int", let underlying { inherits.append(underlying) }
        } else if !isInterface, !isStruct, !baseName.isEmpty, baseName != "System.Object" {
            inherits.append(csharp(base, scope))
        }
        inherits += (interfaces[row] ?? []).map { csharp(typeSignature(token: $0), scope) }
        if !inherits.isEmpty { declaration += " : " + inherits.joined(separator: ", ") }
        declaration += constraintSuffix(parameters, scope: scope)

        line(indent, declaration)
        line(indent, "{")
        if isEnum {
            writeEnumMembers(type: row, indent: indent + 1)
        } else {
            writeMembers(type: row, indent: indent + 1, scope: scope, isInterface: isInterface)
        }
        line(indent, "}")
    }

    func writeEnumMembers(type row: Int, indent: Int) {
        for field in metadata.range(.typeDef, row, 4, into: .field) {
            let flags = metadata.cell(.field, field, 0)
            guard flags & 0x40 != 0 else { continue }              // только константы, не value__
            let name = metadata.string(.field, field, 1)
            let value = constants[Key(.field, field)].map { " = " + constantLiteral($0) } ?? ""
            line(indent, "\(name)\(value),")
        }
    }

    func writeMembers(type row: Int, indent: Int, scope: Scope, isInterface: Bool) {
        let accessors = Set((propertyRange[row] ?? 0..<0).flatMap { propertyAccessors[$0] ?? [] }.map(\.method)
            + (eventRange[row] ?? 0..<0).flatMap { eventAccessors[$0] ?? [] }.map(\.method))

        for field in metadata.range(.typeDef, row, 4, into: .field) {
            writeField(field, indent: indent, scope: scope)
        }
        for property in propertyRange[row] ?? 0..<0 {
            writeProperty(property, indent: indent, scope: scope, isInterface: isInterface)
        }
        for event in eventRange[row] ?? 0..<0 {
            writeEvent(event, indent: indent, scope: scope, isInterface: isInterface)
        }
        for method in metadata.range(.typeDef, row, 5, into: .methodDef) where !accessors.contains(method) {
            writeMethod(method, indent: indent, scope: scope, isInterface: isInterface)
        }
        for child in nested[row] ?? [] where !isHidden(type: child) {
            out += "\n"
            write(type: child, indent: indent, namespace: scope.namespace)
        }
    }
}

// MARK: - Члены типа

private extension AssemblyPrinter {

    func writeField(_ row: Int, indent: Int, scope: Scope) {
        let flags = metadata.cell(.field, row, 0)
        let name = metadata.string(.field, row, 1)
        guard !name.contains("<"),
              !has(attribute: "System.Runtime.CompilerServices.CompilerGeneratedAttribute", on: Key(.field, row))
        else { return }

        writeAttributes(on: Key(.field, row), indent: indent, scope: scope)
        var words = [access(flags & 0x7)]
        if flags & 0x40 != 0 {
            words.append("const")
        } else {
            if flags & 0x10 != 0 { words.append("static") }
            if flags & 0x20 != 0 { words.append("readonly") }
        }
        let type = csharp(SignatureParser.fieldType(metadata.blob(.field, row, 2), resolve: resolver()), scope)
        let value = constants[Key(.field, row)].map { " = " + constantLiteral($0) } ?? ""
        line(indent, "\(words.joined(separator: " ")) \(type) \(name)\(value);")
    }

    func writeProperty(_ row: Int, indent: Int, scope: Scope, isInterface: Bool) {
        let name = metadata.string(.property, row, 1)
        guard !name.contains("<") else { return }
        let signature = SignatureParser.property(metadata.blob(.property, row, 2), resolve: resolver())
        let accessors = propertyAccessors[row] ?? []
        let getter = accessors.first { $0.kind & 0x0002 != 0 }?.method
        let setter = accessors.first { $0.kind & 0x0001 != 0 }?.method
        guard let any = getter ?? setter else { return }

        writeAttributes(on: Key(.property, row), indent: indent, scope: scope)
        // Доступность свойства — самая широкая из его аксессоров; более
        // узкий пишется у самого `get` или `set`, как в исходнике.
        let levels = [getter, setter].compactMap { $0.map { metadata.cell(.methodDef, $0, 2) & 0x7 } }
        let widest = levels.max() ?? 0
        var head = memberModifiers(method: any, accessibility: widest, isInterface: isInterface)

        // Индексатор: в метаданных это свойство с параметрами и именем Item.
        let title: String
        if signature.parameters.isEmpty {
            title = name
        } else {
            let list = getter.map { parameterList(method: $0, types: signature.parameters, scope: scope) }
                ?? "(" + signature.parameters.map { csharp($0, scope) }.joined(separator: ", ") + ")"
            title = "this[" + list.dropFirst().dropLast() + "]"
        }
        head += csharp(signature.type, scope) + " " + title

        var parts: [String] = []
        if let getter { parts.append(accessorPrefix(getter, widest) + "get;") }
        if let setter { parts.append(accessorPrefix(setter, widest) + "set;") }
        line(indent, head + " { " + parts.joined(separator: " ") + " }")
    }

    /// `private set;` — когда аксессор уже самого свойства.
    func accessorPrefix(_ method: Int, _ widest: UInt32) -> String {
        let own = metadata.cell(.methodDef, method, 2) & 0x7
        return own == widest ? "" : access(own) + " "
    }

    func writeEvent(_ row: Int, indent: Int, scope: Scope, isInterface: Bool) {
        let name = metadata.string(.event, row, 1)
        guard !name.contains("<") else { return }
        let accessors = eventAccessors[row] ?? []
        guard let add = accessors.first(where: { $0.kind & 0x0008 != 0 })?.method ?? accessors.first?.method
        else { return }
        writeAttributes(on: Key(.event, row), indent: indent, scope: scope)
        let type = csharp(typeSignature(token: metadata.cell(.event, row, 2)), scope)
        let head = memberModifiers(method: add, accessibility: metadata.cell(.methodDef, add, 2) & 0x7,
                                   isInterface: isInterface)
        line(indent, "\(head)event \(type) \(name);")
    }

    func writeMethod(_ row: Int, indent: Int, scope: Scope, isInterface: Bool) {
        let name = metadata.string(.methodDef, row, 3)
        guard !name.contains("<"),
              !has(attribute: "System.Runtime.CompilerServices.CompilerGeneratedAttribute", on: Key(.methodDef, row))
        else { return }

        let flags = metadata.cell(.methodDef, row, 2)
        let parameters = genericParameters[Key(.methodDef, row)] ?? []
        var inner = scope
        inner.methodParameters = parameters.map { metadata.string(.genericParam, $0, 3) }
        let signature = SignatureParser.method(metadata.blob(.methodDef, row, 4), resolve: resolver())

        writeAttributes(on: Key(.methodDef, row), indent: indent, scope: inner)
        if let library = imports[row] {
            line(indent, "[DllImport(\(csharpString(library)))]")
        }

        let owner = ownerOfMethod[row].map { TypeName.withoutArity(metadata.string(.typeDef, $0, 1)) } ?? ""
        let list = parameterList(method: row, types: signature.parameters, scope: inner,
                                 isExtension: has(attribute: "System.Runtime.CompilerServices.ExtensionAttribute",
                                                  on: Key(.methodDef, row)))
        let generics = genericList(parameters, scope: inner)
        let constraintsTail = constraintSuffix(parameters, scope: inner)
        // Тело здесь не печатается: у абстрактных и внешних методов его нет
        // и в исходнике, у остальных оно осталось в IL.
        let hasBody = !(flags & 0x400 != 0 || flags & 0x2000 != 0 || metadata.cell(.methodDef, row, 0) == 0)
        let tail = hasBody ? " { }" : ";"

        switch name {
        case ".ctor":
            line(indent, "\(access(flags & 0x7)) \(owner)\(list)\(tail)")
        case ".cctor":
            line(indent, "static \(owner)()\(tail)")
        case "op_Implicit", "op_Explicit":
            let word = name == "op_Implicit" ? "implicit" : "explicit"
            line(indent, "public static \(word) operator \(csharp(signature.returnType, inner))\(list)\(tail)")
        case let name where name.hasPrefix("op_") && Self.operators[name] != nil:
            let symbol = Self.operators[name] ?? ""
            line(indent, "public static \(csharp(signature.returnType, inner)) operator \(symbol)\(list)\(tail)")
        default:
            let head = memberModifiers(method: row, accessibility: flags & 0x7, isInterface: isInterface)
            let returns = csharp(signature.returnType, inner)
            line(indent, "\(head)\(returns) \(TypeName.withoutArity(name))\(generics)\(list)\(constraintsTail)\(tail)")
        }
    }

    /// Слова перед типом члена: доступность и то, как он связан с базовым.
    /// В интерфейсе всё это подразумевается и не пишется.
    func memberModifiers(method row: Int, accessibility: UInt32, isInterface: Bool) -> String {
        let flags = metadata.cell(.methodDef, row, 2)
        let name = metadata.string(.methodDef, row, 3)
        // Явная реализация интерфейса: имя уже содержит интерфейс, слов не нужно.
        if name.contains("."), accessibility == 1, flags & 0x20 != 0 { return "" }
        if isInterface, flags & 0x400 != 0 { return "" }

        var words = [access(accessibility)]
        if flags & 0x10 != 0 { words.append("static") }
        if flags & 0x400 != 0 {
            words.append("abstract")
        } else if flags & 0x40 != 0 {
            if flags & 0x100 != 0 {
                if flags & 0x20 == 0 { words.append("virtual") }         // sealed virtual — просто метод
            } else {
                if flags & 0x20 != 0 { words.append("sealed") }
                words.append("override")
            }
        }
        if flags & 0x2000 != 0 { words.append("extern") }
        return words.joined(separator: " ") + " "
    }

    /// Список параметров со скобками: имена, `ref`/`out`/`params`, значения
    /// по умолчанию. `this` у первого — расширяющий метод.
    func parameterList(method row: Int, types: [TypeSignature], scope: Scope,
                       isExtension: Bool = false) -> String {
        var bySequence: [Int: Int] = [:]
        for param in metadata.range(.methodDef, row, 5, into: .param) {
            bySequence[Int(metadata.cell(.param, param, 1))] = param
        }
        var printed: [String] = []
        for (position, type) in types.enumerated() {
            let param = bySequence[position + 1]
            let flags = param.map { metadata.cell(.param, $0, 0) } ?? 0
            var text = ""
            if position == 0, isExtension { text += "this " }
            var bare = type
            if case .byRef(let inner) = type {
                text += flags & 0x2 != 0 ? "out " : "ref "
                bare = inner
            }
            if let param, has(attribute: "System.ParamArrayAttribute", on: Key(.param, param)) {
                text += "params "
            }
            let name = param.map { metadata.string(.param, $0, 2) } ?? ""
            text += csharp(bare, scope) + " " + (name.isEmpty ? "arg\(position + 1)" : name)
            if let param, let constant = constants[Key(.param, param)] {
                text += " = " + constantLiteral(constant)
            }
            printed.append(text)
        }
        return "(" + printed.joined(separator: ", ") + ")"
    }

    static let operators: [String: String] = [
        "op_Addition": "+", "op_Subtraction": "-", "op_Multiply": "*", "op_Division": "/",
        "op_Modulus": "%", "op_ExclusiveOr": "^", "op_BitwiseAnd": "&", "op_BitwiseOr": "|",
        "op_LeftShift": "<<", "op_RightShift": ">>", "op_Equality": "==", "op_Inequality": "!=",
        "op_LessThan": "<", "op_GreaterThan": ">", "op_LessThanOrEqual": "<=",
        "op_GreaterThanOrEqual": ">=", "op_UnaryNegation": "-", "op_UnaryPlus": "+",
        "op_LogicalNot": "!", "op_OnesComplement": "~", "op_Increment": "++", "op_Decrement": "--",
        "op_True": "true", "op_False": "false",
    ]
}

// MARK: - Типы в тексте

/// Что вокруг: своё пространство имён (его в именах не повторяют) и
/// параметры типа с параметрами метода — по ним читаются `T` и `M`.
private struct Scope {
    var namespace: String
    var typeParameters: [String] = []
    var methodParameters: [String] = []

    func name(_ index: Int, method: Bool) -> String {
        let list = method ? methodParameters : typeParameters
        if index >= 0, index < list.count, !list[index].isEmpty { return list[index] }
        return (method ? "M" : "T") + String(index)
    }
}

private extension AssemblyPrinter {

    static let keywords: [String: String] = [
        "System.Void": "void", "System.Boolean": "bool", "System.Char": "char",
        "System.SByte": "sbyte", "System.Byte": "byte", "System.Int16": "short",
        "System.UInt16": "ushort", "System.Int32": "int", "System.UInt32": "uint",
        "System.Int64": "long", "System.UInt64": "ulong", "System.Single": "float",
        "System.Double": "double", "System.Decimal": "decimal", "System.String": "string",
        "System.Object": "object",
    ]

    func csharp(_ type: TypeSignature, _ scope: Scope) -> String {
        switch type {
        case .keyword(let word):
            return word
        case .named(let name):
            return display(name, scope)
        case .instance(let base, let arguments):
            guard case .named(let name) = base else { return csharp(base, scope) }
            return display(name, scope, arguments: arguments.map { csharp($0, scope) })
        case .array(let element, let rank):
            return csharp(element, scope) + "[" + String(repeating: ",", count: max(rank - 1, 0)) + "]"
        case .pointer(let element):
            return csharp(element, scope) + "*"
        case .byRef(let element):
            return "ref " + csharp(element, scope)
        case .variable(let index, let method):
            return scope.name(index, method: method)
        case .functionPointer:
            return "delegate*"
        case .unknown:
            return "object"
        }
    }

    /// Имя типа в тексте: своё пространство имён и `System` не пишутся —
    /// в исходнике их закрыли бы `using`.
    func display(_ name: TypeName, _ scope: Scope, arguments: [String] = []) -> String {
        if arguments.isEmpty, let keyword = Self.keywords[name.full] { return keyword }
        if name.full == "System.Nullable", arguments.count == 1 { return arguments[0] + "?" }

        var path = name.path.map(TypeName.withoutArity)
        if !arguments.isEmpty {
            path[path.count - 1] += "<" + arguments.joined(separator: ", ") + ">"
        } else if let last = name.path.last, TypeName.arity(last) > 0 {
            path[path.count - 1] += "<" + String(repeating: ",", count: TypeName.arity(last) - 1) + ">"
        }
        let simple = path.joined(separator: ".")
        return known(namespace: name.namespace, scope) ? simple : name.namespace + "." + simple
    }

    /// Пространство имён, которое в исходнике закрыл бы `using`: своё,
    /// `System` с потомками и всё, что объявлено в этой же сборке. Остальные
    /// пишутся целиком — по ним и видно, из какой библиотеки пришёл тип.
    func known(namespace: String, _ scope: Scope) -> Bool {
        namespace.isEmpty || namespace == scope.namespace || namespace == "System"
            || namespace.hasPrefix("System.") || ownNamespaces.contains(namespace)
    }

    func genericList(_ parameters: [Int], scope: Scope) -> String {
        guard !parameters.isEmpty else { return "" }
        let names = parameters.map { row -> String in
            let variance = metadata.cell(.genericParam, row, 1) & 0x3
            let prefix = variance == 1 ? "out " : variance == 2 ? "in " : ""
            return prefix + metadata.string(.genericParam, row, 3)
        }
        return "<" + names.joined(separator: ", ") + ">"
    }

    func constraintSuffix(_ parameters: [Int], scope: Scope) -> String {
        var clauses: [String] = []
        for row in parameters {
            let flags = metadata.cell(.genericParam, row, 1)
            var items: [String] = []
            if flags & 0x04 != 0 { items.append("class") }
            if flags & 0x08 != 0 { items.append("struct") }
            for token in constraints[row] ?? [] {
                let type = typeSignature(token: token)
                // `struct` уже сказал то же самое.
                if flags & 0x08 != 0, type.elementName?.full == "System.ValueType" { continue }
                items.append(csharp(type, scope))
            }
            if flags & 0x10 != 0, flags & 0x08 == 0 { items.append("new()") }
            guard !items.isEmpty else { continue }
            clauses.append("where \(metadata.string(.genericParam, row, 3)) : " + items.joined(separator: ", "))
        }
        return clauses.isEmpty ? "" : " " + clauses.joined(separator: " ")
    }

    /// Доступность члена (MethodAttributes и FieldAttributes совпадают).
    func access(_ bits: UInt32) -> String {
        switch bits {
        case 1:  return "private"
        case 2:  return "private protected"
        case 3:  return "internal"
        case 4:  return "protected"
        case 5:  return "protected internal"
        case 6:  return "public"
        default: return "private"
        }
    }

    func visibility(ofType flags: UInt32) -> String {
        switch flags & 0x7 {
        case 1, 2: return "public"
        case 3:    return "private"
        case 4:    return "protected"
        case 5:    return "internal"
        case 6:    return "private protected"
        case 7:    return "protected internal"
        default:   return "internal"
        }
    }

    /// Чем на самом деле считается перечисление: тип его поля `value__`.
    func enumUnderlying(_ type: Int) -> String? {
        for field in metadata.range(.typeDef, type, 4, into: .field)
        where metadata.cell(.field, field, 0) & 0x10 == 0 {
            return csharp(SignatureParser.fieldType(metadata.blob(.field, field, 2), resolve: resolver()),
                          Scope(namespace: ""))
        }
        return nil
    }
}

// MARK: - Атрибуты и константы

/// Чтение значения из блоба: числа лежат младшим байтом вперёд, строки —
/// длиной и UTF-8, как описано в ECMA-335 §II.23.3.
private struct BlobReader {
    private let bytes: ArraySlice<UInt8>
    private var cursor: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.cursor = bytes.startIndex
    }

    var isEmpty: Bool { cursor >= bytes.endIndex }

    mutating func byte() -> UInt8 {
        guard cursor < bytes.endIndex else { return 0 }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    mutating func integer(_ size: Int) -> UInt64 {
        var value: UInt64 = 0
        for shift in 0..<size { value |= UInt64(byte()) << (8 * shift) }
        return value
    }

    mutating func compressed() -> Int {
        let first = UInt32(byte())
        if first & 0x80 == 0 { return Int(first) }
        if first & 0xC0 == 0x80 { return Int(((first & 0x3F) << 8) | UInt32(byte())) }
        let rest = (UInt32(byte()) << 16) | (UInt32(byte()) << 8) | UInt32(byte())
        return Int(((first & 0x1F) << 24) | rest)
    }

    enum Text {
        case null
        case value(String)
        case broken
    }

    /// SerString: длина сжатым числом, 0xFF — это null.
    mutating func string() -> Text {
        guard cursor < bytes.endIndex else { return .broken }
        if bytes[cursor] == 0xFF {
            cursor += 1
            return .null
        }
        let length = compressed()
        guard length >= 0, cursor + length <= bytes.endIndex else { return .broken }
        defer { cursor += length }
        return .value(String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self))
    }

    /// Остаток блоба как UTF-16 — так лежат строковые константы.
    mutating func rest() -> String {
        var units: [UInt16] = []
        while cursor + 1 < bytes.endIndex {
            units.append(UInt16(byte()) | (UInt16(byte()) << 8))
        }
        return String(decoding: units, as: UTF16.self)
    }
}

private extension AssemblyPrinter {

    /// Атрибуты компилятора: в исходнике их не писали, они — способ записи
    /// того, что и так видно по объявлению (`this`, `readonly`, `params`).
    static let hiddenAttributes: Set<String> = [
        "System.Runtime.CompilerServices.CompilerGeneratedAttribute",
        "System.Runtime.CompilerServices.ExtensionAttribute",
        "System.Runtime.CompilerServices.IsReadOnlyAttribute",
        "System.Runtime.CompilerServices.IsByRefLikeAttribute",
        "System.Runtime.CompilerServices.NullableAttribute",
        "System.Runtime.CompilerServices.NullableContextAttribute",
        "System.Runtime.CompilerServices.NullablePublicOnlyAttribute",
        "System.Runtime.CompilerServices.RefSafetyRulesAttribute",
        "System.Runtime.CompilerServices.AsyncStateMachineAttribute",
        "System.Runtime.CompilerServices.IteratorStateMachineAttribute",
        "System.Runtime.CompilerServices.DecimalConstantAttribute",
        "System.Reflection.DefaultMemberAttribute",
        "System.ParamArrayAttribute",
        "System.Diagnostics.DebuggerBrowsableAttribute",
        "System.Diagnostics.DebuggerHiddenAttribute",
        "System.Diagnostics.DebuggerNonUserCodeAttribute",
        "System.Diagnostics.DebuggerStepThroughAttribute",
    ]

    func attributeName(_ row: Int) -> TypeName? {
        if let known = attributeNames[row] { return known }
        guard let ctor = metadata.target(.customAttributeType, metadata.cell(.customAttribute, row, 1))
        else { return nil }
        var name: TypeName?
        switch ctor.table {
        case .methodDef:
            name = ownerOfMethod[ctor.row].map { nameOfTypeDef($0) }
        case .memberRef:
            if let parent = metadata.target(.memberRefParent, metadata.cell(.memberRef, ctor.row, 0)) {
                switch parent.table {
                case .typeDef: name = nameOfTypeDef(parent.row)
                case .typeRef: name = nameOfTypeRef(parent.row)
                default:       break
                }
            }
        default:
            break
        }
        if let name { attributeNames[row] = name }
        return name
    }

    func has(attribute full: String, on key: Key) -> Bool {
        (attributes[key] ?? []).contains { attributeName($0)?.full == full }
    }

    func writeAttributes(on key: Key, indent: Int, scope: Scope) {
        for row in attributes[key] ?? [] {
            guard var name = attributeName(row), !Self.hiddenAttributes.contains(name.full) else { continue }
            // `[Obsolete]`, а не `[ObsoleteAttribute]` — как это пишут в коде.
            if let last = name.path.last, last.hasSuffix("Attribute"), last.count > "Attribute".count {
                name.path[name.path.count - 1] = String(last.dropLast("Attribute".count))
            }
            line(indent, "[" + display(name, scope) + (attributeArguments(row) ?? "") + "]")
        }
    }

    /// Аргументы атрибута в скобках; `nil` — их нет вовсе. Что не удалось
    /// разобрать (чаще всего — перечисление из другой сборки, размер
    /// которого отсюда не виден), сворачивается в многоточие: лучше
    /// честный пропуск, чем выдуманное значение.
    func attributeArguments(_ row: Int) -> String? {
        let blob = metadata.blob(.customAttribute, row, 2)
        guard !blob.isEmpty else { return nil }
        guard let ctor = metadata.target(.customAttributeType, metadata.cell(.customAttribute, row, 1))
        else { return nil }
        let signature: MethodSignature
        switch ctor.table {
        case .methodDef: signature = SignatureParser.method(metadata.blob(.methodDef, ctor.row, 4), resolve: resolver())
        case .memberRef: signature = SignatureParser.method(metadata.blob(.memberRef, ctor.row, 2), resolve: resolver())
        default:         return nil
        }

        var reader = BlobReader(blob)
        guard reader.integer(2) == 1 else { return "(…)" }
        var printed: [String] = []
        for type in signature.parameters {
            guard let value = argument(type, &reader) else { return "(…)" }
            printed.append(value)
        }
        let named = Int(reader.integer(2))
        for _ in 0..<min(named, 64) {
            _ = reader.byte()                                  // поле или свойство — в тексте не различаются
            guard let type = taggedType(&reader) else { break }
            guard case .value(let name) = reader.string(), let value = argument(type, &reader) else {
                printed.append("…")
                break
            }
            printed.append("\(name) = \(value)")
        }
        return printed.isEmpty ? nil : "(" + printed.joined(separator: ", ") + ")"
    }

    /// Тип именованного аргумента записан прямо в блобе одним байтом.
    func taggedType(_ reader: inout BlobReader) -> TypeSignature? {
        switch reader.byte() {
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
        case 0x1D: return taggedType(&reader).map { .array($0, rank: 1) }
        case 0x50: return .named(TypeName(namespace: "System", path: ["Type"]))
        case 0x51: return .keyword("object")
        case 0x55:
            guard case .value(let name) = reader.string() else { return nil }
            return .named(Self.typeName(fromSerialized: name))
        default:   return nil
        }
    }

    /// `Foo.Bar, Assembly, Version=…` — в блобах атрибутов тип записан строкой.
    static func typeName(fromSerialized text: String) -> TypeName {
        let full = text.split(separator: ",").first.map(String.init) ?? text
        guard let dot = full.lastIndex(of: ".") else { return TypeName(namespace: "", path: [full]) }
        return TypeName(namespace: String(full[..<dot]),
                        path: String(full[full.index(after: dot)...]).split(separator: "+").map(String.init))
    }

    func argument(_ type: TypeSignature, _ reader: inout BlobReader) -> String? {
        switch type {
        case .keyword("object"):
            guard let inner = taggedType(&reader) else { return nil }
            return argument(inner, &reader)
        case .keyword("string"):
            switch reader.string() {
            case .null:            return "null"
            case .value(let text): return csharpString(text)
            case .broken:          return nil
            }
        case .keyword(let word):
            return literal(word, &reader)
        case .named(let name):
            if name.full == "System.Type" {
                switch reader.string() {
                case .null:            return "null"
                case .value(let text): return "typeof(" + Self.typeName(fromSerialized: text).simple + ")"
                case .broken:          return nil
                }
            }
            // Перечисление своей сборки читается членом; чужое — числом с
            // приведением: его настоящий размер отсюда не виден, а по
            // умолчанию в C# перечисление — это `int`.
            let enumeration = typeDef(named: name)
            let underlying = enumeration.flatMap { enumUnderlying($0) } ?? "int"
            guard let raw = literal(underlying, &reader) else { return nil }
            if let enumeration, let member = member(ofEnum: enumeration, value: raw) { return member }
            return "(\(name.simple))\(raw)"
        case .array(let element, 1):
            let count = reader.integer(4)
            if count == 0xFFFF_FFFF { return "null" }
            var items: [String] = []
            for _ in 0..<min(count, 1024) {
                guard let value = argument(element, &reader) else { return nil }
                items.append(value)
            }
            return "new[] { " + items.joined(separator: ", ") + " }"
        default:
            return nil
        }
    }

    func typeDef(named name: TypeName) -> Int? {
        if typeDefIndex.isEmpty {
            for row in rows(.typeDef) { typeDefIndex[nameOfTypeDef(row).full] = row }
        }
        return typeDefIndex[name.full]
    }

    func member(ofEnum type: Int, value: String) -> String? {
        for field in metadata.range(.typeDef, type, 4, into: .field)
        where metadata.cell(.field, field, 0) & 0x40 != 0 {
            guard let constant = constants[Key(.field, field)], constantLiteral(constant) == value else { continue }
            return TypeName.withoutArity(metadata.string(.typeDef, type, 1)) + "." + metadata.string(.field, field, 1)
        }
        return nil
    }

    /// Константа из таблицы Constant: значение поля или параметра.
    func constantLiteral(_ row: Int) -> String {
        var reader = BlobReader(metadata.blob(.constant, row, 2))
        switch metadata.cell(.constant, row, 0) & 0xFF {
        case 0x0E: return csharpString(reader.rest())
        case 0x12: return "null"
        case let code:
            guard let keyword = Self.constantKeywords[code], let value = literal(keyword, &reader)
            else { return "default" }
            return value
        }
    }

    static let constantKeywords: [UInt32: String] = [
        0x02: "bool", 0x03: "char", 0x04: "sbyte", 0x05: "byte", 0x06: "short", 0x07: "ushort",
        0x08: "int", 0x09: "uint", 0x0A: "long", 0x0B: "ulong", 0x0C: "float", 0x0D: "double",
    ]

    func literal(_ keyword: String, _ reader: inout BlobReader) -> String? {
        switch keyword {
        case "bool":   return reader.integer(1) != 0 ? "true" : "false"
        case "char":   return csharpChar(UInt16(truncatingIfNeeded: reader.integer(2)))
        case "sbyte":  return String(Int8(truncatingIfNeeded: reader.integer(1)))
        case "byte":   return String(UInt8(truncatingIfNeeded: reader.integer(1)))
        case "short":  return String(Int16(truncatingIfNeeded: reader.integer(2)))
        case "ushort": return String(UInt16(truncatingIfNeeded: reader.integer(2)))
        case "int":    return String(Int32(truncatingIfNeeded: reader.integer(4)))
        case "uint":   return String(UInt32(truncatingIfNeeded: reader.integer(4)))
        case "long":   return String(Int64(bitPattern: reader.integer(8)))
        case "ulong":  return String(reader.integer(8))
        case "float":  return Self.number(Float(bitPattern: UInt32(truncatingIfNeeded: reader.integer(4))),
                                          type: "float", suffix: "f")
        case "double": return Self.number(Double(bitPattern: reader.integer(8)), type: "double", suffix: "")
        default:       return nil
        }
    }

    static func number<Value: BinaryFloatingPoint & LosslessStringConvertible>(
        _ value: Value, type: String, suffix: String) -> String {
        if value.isNaN { return "\(type).NaN" }
        if value.isInfinite { return value < 0 ? "\(type).NegativeInfinity" : "\(type).PositiveInfinity" }
        return String(value) + suffix
    }

    func csharpChar(_ unit: UInt16) -> String {
        switch unit {
        case 0x27: return "'\\''"
        case 0x5C: return "'\\\\'"
        case 0x0A: return "'\\n'"
        case 0x0D: return "'\\r'"
        case 0x09: return "'\\t'"
        case 0x20...0x7E: return "'" + String(UnicodeScalar(UInt8(unit))) + "'"
        default: return String(format: "'\\u%04x'", unit)
        }
    }

    func csharpString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":  result += "\\\""
            case "\\":  result += "\\\\"
            case "\n":  result += "\\n"
            case "\r":  result += "\\r"
            case "\t":  result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
