import Foundation

/// Источник значения — то, на чём граф значения останавливается, потому
/// что ответ найден: литерал в коде, константа, значение перечисления, JSON
/// конфига, инспектор Unity, время или случайное число движка. Граф
/// показывает их отдельными узлами: «откуда берётся» — это они.
///
/// Здесь только классификация по тексту и именам — без компилятора, чтобы
/// проверялось тестами ядра.
struct ValueOrigin: Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// Литерал в коде: `0`, `"idle"`, `true`.
        case literal
        /// `const` — или член сборки вроде `Vector3.zero`, `int.MaxValue`.
        case constant
        /// `JobType.Courier`.
        case enumValue
        /// Начальное значение поля или свойства в объявлении.
        case initial
        /// Умолчание: `default`, `null`, `new()`, параметр `= 5`, который вызов не передал.
        case defaultValue
        /// JSON конфига проекта: модель с ключами `[JsonProperty]`.
        case config
        /// JSON вообще: сообщение, ответ сервиса, `JsonConvert.Deserialize`.
        case json
        /// Колонка таблицы, запрос к базе.
        case database
        /// Сеть: датаграмма, которую во второй половине пары не отследить.
        case network
        /// Инспектор Unity: значение лежит в префабе, сцене или ассете.
        case inspector
        /// Контейнер зависимостей: `[Inject]`, `[Injectable]`.
        case injection
        /// `Time.deltaTime`, `DateTime.UtcNow`, `Stopwatch`.
        case time
        /// `Random.Range`, `Guid.NewGuid`.
        case random
        /// Ввод игрока: клавиатура, касания, поля интерфейса, консоль.
        case input
        /// Файлы, PlayerPrefs, окружение, HTTP, ресурсы.
        case external
        /// Состояние движка: Transform, физика, экран.
        case engine
        /// Член сборки, про который больше ничего не известно.
        case library

        /// Как назвать вид источника в подписи узла и в легенде.
        var label: String {
            switch self {
            case .literal: return L("литерал")
            case .constant: return L("константа")
            case .enumValue: return L("значение перечисления")
            case .initial: return L("начальное значение")
            case .defaultValue: return L("по умолчанию")
            case .config: return L("конфиг")
            case .json: return L("JSON")
            case .database: return L("база данных")
            case .network: return L("сеть")
            case .inspector: return L("инспектор Unity")
            case .injection: return L("контейнер зависимостей")
            case .time: return L("время")
            case .random: return L("случайное число")
            case .input: return L("ввод игрока")
            case .external: return L("файлы и окружение")
            case .engine: return L("движок")
            case .library: return L("сборка")
            }
        }

        /// Значение задано в коде — а не приходит снаружи во время игры.
        var isWrittenInCode: Bool {
            [.literal, .constant, .enumValue, .initial, .defaultValue].contains(self)
        }
    }

    var kind: Kind
    /// Что показать: `1500`, `Time.deltaTime`, `car_spawn_check_radius`.
    var title: String
}

enum ValueOrigins {

    /// Что такое член сборки для графа значения.
    enum Library: Equatable {
        /// Источник: время, случайное число, ввод, файлы, движок.
        case origin(ValueOrigin.Kind)
        /// Постоянная библиотеки: `Vector3.zero`, `int.MaxValue`, `string.Empty`.
        case constant
        /// Преобразование: `Math.Max`, `Parse`, `list.Count`, `ToString()` —
        /// значение из аргументов и получателя, а сам вызов источником не
        /// считается.
        case transform
        /// Неизвестно, что это: член чужой сборки.
        case unknown
    }

    /// Член сборки по имени типа (полному `UnityEngine.Time` или короткому
    /// `Time`) и имени члена. Короткое имя — когда компилятор типа не знает
    /// (`Math.Min` на net8.0) и оно взято из текста.
    static func classify(type: String, member: String) -> Library {
        let parts = cleanType(type).split(separator: ".").map(String.init)
        guard let short = parts.last else { return .unknown }
        let namespace = parts.dropLast().joined(separator: ".")
        let unity = namespace.isEmpty || namespace.hasPrefix("UnityEngine")
        let system = namespace.isEmpty || namespace.hasPrefix("System")

        // Время.
        if short == "Time", unity { return .origin(.time) }
        if short == "Stopwatch", system { return .origin(.time) }
        if ["DateTime", "DateTimeOffset"].contains(short), ["Now", "UtcNow", "Today"].contains(member) {
            return .origin(.time)
        }
        if short == "Environment", member.hasPrefix("TickCount") { return .origin(.time) }
        if short == "AudioSettings", member == "dspTime" { return .origin(.time) }
        if short == "TimeProvider" { return .origin(.time) }
        // Случайное.
        if short == "Random", unity || system || namespace.hasPrefix("Unity.Mathematics") { return .origin(.random) }
        if short == "Guid", member == "NewGuid" { return .origin(.random) }
        if short == "RandomNumberGenerator" { return .origin(.random) }
        // Ввод игрока.
        if short == "Input", unity { return .origin(.input) }
        if namespace.hasPrefix("UnityEngine.InputSystem") { return .origin(.input) }
        if short == "Console", member.hasPrefix("Read") { return .origin(.input) }
        if ["InputField", "TMP_InputField"].contains(short), member == "text" { return .origin(.input) }
        if ["Slider", "Scrollbar", "Dropdown", "TMP_Dropdown"].contains(short), member == "value" { return .origin(.input) }
        if short == "Toggle", member == "isOn" { return .origin(.input) }
        // JSON.
        if ["JsonConvert", "JsonSerializer"].contains(short), member.hasPrefix("Deserialize") || member.hasPrefix("Populate") {
            return .origin(.json)
        }
        if short == "JsonUtility", member.hasPrefix("FromJson") { return .origin(.json) }
        if ["JObject", "JToken", "JArray", "JValue"].contains(short) { return .origin(.json) }
        // База данных.
        let databases = ["MySqlConnector", "MySql.Data", "Npgsql", "Dapper", "Microsoft.EntityFrameworkCore",
                         "System.Data", "StackExchange.Redis", "MongoDB", "Microsoft.Data"]
        if databases.contains(where: { namespace == $0 || namespace.hasPrefix($0 + ".") }) { return .origin(.database) }
        // Файлы, окружение, сеть, ресурсы.
        if short == "Path" { return .transform }
        if namespace == "System.IO" || namespace.hasPrefix("System.IO.") { return .origin(.external) }
        if namespace == "System.Net" || namespace.hasPrefix("System.Net.") { return .origin(.external) }
        if ["PlayerPrefs", "Environment", "UnityWebRequest", "HttpClient", "WebClient", "Resources", "Addressables",
            "AssetDatabase", "AssetBundle", "SystemInfo", "Application", "EditorPrefs"].contains(short) {
            return .origin(.external)
        }
        // Чистые функции и то, что берут у значения: из аргументов и получателя.
        // Кроме постоянных тех же типов: `Vector3.zero` рядом с `Vector3.Lerp`
        // (а `transform.up` — не постоянная: Transform сюда не входит).
        if transforms.contains(short) { return constants.contains(member) ? .constant : .transform }
        // Остальное у Unity — состояние движка: Transform, физика, камера.
        if namespace.hasPrefix("UnityEngine") || namespace.hasPrefix("UnityEditor") || namespace.hasPrefix("Unity.")
            || ["Transform", "GameObject", "Component", "MonoBehaviour", "Physics", "Physics2D", "Camera", "Screen",
                "Animator", "Rigidbody", "Rigidbody2D", "Collider", "NavMeshAgent", "Renderer"].contains(short) {
            return .origin(.engine)
        }
        return .unknown
    }

    /// `System.Collections.Generic.Dictionary`2` и `List<int>` — без арности
    /// и аргументов типа; `int?` — `int`.
    static func cleanType(_ type: String) -> String {
        var result = type
        if let angle = result.firstIndex(of: "<") { result = String(result[..<angle]) }
        if let tick = result.firstIndex(of: "`") { result = String(result[..<tick]) }
        while result.hasSuffix("?") || result.hasSuffix("[]") {
            result = result.hasSuffix("?") ? String(result.dropLast()) : String(result.dropLast(2))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Типы, члены которых — преобразование того, что им дали: математика,
    /// строки, коллекции, числа, время как величина.
    static let transforms: Set<String> = [
        "Math", "MathF", "Mathf", "math", "Convert", "BitConverter", "BinaryPrimitives", "Enum", "Array", "Buffer",
        "String", "string", "StringBuilder", "Char", "char", "Encoding", "Regex", "Match", "Group",
        "Enumerable", "Queryable", "ParallelEnumerable", "Tuple", "ValueTuple", "KeyValuePair", "Nullable", "Lazy",
        "Object", "object", "ValueType", "Int16", "Int32", "Int64", "UInt16", "UInt32", "UInt64", "Byte", "SByte",
        "Single", "Double", "Decimal", "Boolean", "int", "uint", "long", "ulong", "short", "ushort", "byte", "sbyte",
        "float", "double", "decimal", "bool", "Half", "BigInteger", "Complex",
        "TimeSpan", "DateTime", "DateTimeOffset", "DateOnly", "TimeOnly", "Guid", "Uri", "Version",
        "List", "Dictionary", "HashSet", "SortedSet", "SortedDictionary", "SortedList", "LinkedList", "Queue", "Stack",
        "PriorityQueue", "ConcurrentDictionary", "ConcurrentQueue", "ConcurrentBag", "ConcurrentStack",
        "ImmutableArray", "ImmutableList", "ImmutableDictionary", "ImmutableHashSet", "ReadOnlyCollection",
        "IEnumerable", "IEnumerator", "ICollection", "IList", "IDictionary", "ISet", "IReadOnlyList",
        "IReadOnlyCollection", "IReadOnlyDictionary", "IReadOnlySet", "CollectionExtensions", "CollectionsMarshal",
        "Span", "ReadOnlySpan", "Memory", "ReadOnlyMemory", "ArraySegment", "MemoryExtensions", "MemoryMarshal",
        "Unsafe", "Task", "ValueTask", "Interlocked", "Volatile", "StringComparer", "Comparer", "EqualityComparer",
        "CultureInfo", "StringComparison",
        "Vector2", "Vector3", "Vector4", "Vector2Int", "Vector3Int", "Quaternion", "Matrix4x4", "Plane", "Ray",
        "Color", "Color32", "Rect", "RectInt", "Bounds", "BoundsInt", "LayerMask", "AnimationCurve", "Gradient",
        "float2", "float3", "float4", "int2", "int3", "int4", "quaternion", "float4x4",
    ]

    /// Члены, которые у любого типа — постоянная: `Vector3.zero`, `int.MaxValue`.
    static let constants: Set<String> = [
        "MaxValue", "MinValue", "Epsilon", "PositiveInfinity", "NegativeInfinity", "NaN", "Empty", "Zero", "One",
        "zero", "one", "up", "down", "left", "right", "forward", "back", "identity", "positiveInfinity",
        "negativeInfinity", "white", "black", "red", "green", "blue", "clear", "gray", "grey", "yellow", "cyan",
        "magenta", "PI", "E", "Tau", "Deg2Rad", "Rad2Deg", "Infinity", "NegativeInfinity", "MaxLength",
        "Ordinal", "OrdinalIgnoreCase", "InvariantCulture", "InvariantCultureIgnoreCase", "CurrentCulture",
    ]
}
