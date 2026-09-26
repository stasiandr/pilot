import Foundation

/// Правила проекта из расширений: соглашения конкретной кодовой базы, по
/// которым работают общие движки Pilot — сверка сетевых структур между
/// половинами пары, каталог конфигов, зеркальные папки, сетевые переходы в
/// графе значения. Без правил эти возможности выключены: сам Pilot ничего
/// не знает ни о чьём протоколе и чьих конфигах.
///
/// Расширение — папка `.pilot/extensions/<имя>/` в корне проекта с файлом
/// `extension.json`. Оно живёт в репозитории того проекта, к которому
/// относится, и обновляется вместе с ним. Код расширение не исполняет —
/// только описывает, поэтому достаточно один раз согласиться его включить.
///
/// ```json
/// {
///   "name": "Game",
///   "pair": { "suffixes": [["-app", "-backend"]], "mirrors": ["docs/shared/"] },
///   "datagrams": { "interface": "IPacket", "write": ["Write"], "read": ["Read"],
///                  "send": ["Send"], "receive": ["PacketFilter"] },
///   "configs": { "folder": "Configs", "registry": "registry.json", "aliases": "ConfigNames",
///                "modelAttribute": "ConfigModel", "keyAttribute": "JsonProperty" }
/// }
/// ```
///
/// Без AppKit — проверяется тестами ядра.
struct ProjectRules: Equatable, Sendable {
    var pair = PairRules()
    var datagrams: DatagramRules?
    var configs: ConfigRules?

    static let none = ProjectRules()

    var isEmpty: Bool { self == .none }

    /// Правила нескольких расширений (своих и второй половины пары) — в
    /// одни: списки складываются, у разделов выигрывает первое расширение.
    static func merged(_ all: [ProjectRules]) -> ProjectRules {
        var result = ProjectRules()
        for rules in all {
            for pair in rules.pair.suffixes where !result.pair.suffixes.contains(pair) {
                result.pair.suffixes.append(pair)
            }
            for mirror in rules.pair.mirrors where !result.pair.mirrors.contains(mirror) {
                result.pair.mirrors.append(mirror)
            }
            result.datagrams = result.datagrams ?? rules.datagrams
            result.configs = result.configs ?? rules.configs
        }
        return result
    }
}

/// Пара проектов: как ещё узнавать половины по именам папок и какие папки
/// по договорённости лежат одинаковыми копиями в обеих.
struct PairRules: Equatable, Sendable {
    /// Окончания имён сверх встроенных `-client` / `-server`.
    var suffixes: [Suffixes] = []
    /// Пути от корня, которые должны совпадать в обеих половинах.
    var mirrors: [String] = []

    struct Suffixes: Equatable, Sendable {
        var first: String
        var second: String
    }

    /// Путь от корня — из зеркальных папок?
    func isMirrored(_ relativePath: String) -> Bool {
        mirrors.contains { relativePath.hasPrefix($0) }
    }
}

/// Сетевые структуры, объявленные одинаково в обеих половинах пары:
/// тип реализует `interface`, пишет себя в провод методом из `write`, читает
/// методом из `read`. Сверяются шаги этих методов.
struct DatagramRules: Equatable, Sendable {
    /// Базовый интерфейс (или класс) сетевых структур.
    var interface: String
    /// Первое имя — метод структуры, все — префиксы вызовов записи внутри:
    /// `writer.WriteInt(…)`, `Id.Serialize(writer)`.
    var write: [String] = ["Write"]
    var read: [String] = ["Read"]
    /// Вызовы, которыми структуру отправляют: `client.Send(ref packet)`.
    var send: [String] = ["Send"]
    /// Обобщённые типы, цикл по которым срабатывает на пришедшую структуру:
    /// `foreach (var e in PacketFilter<T>)`.
    var receive: [String] = []

    var writeMethod: String { write.first ?? "Write" }
    var readMethod: String { read.first ?? "Read" }
}

/// Каталог конфигов: JSON-реестр «путь файла → алиас» в папке конфигов,
/// константы-алиасы в коде и модели, в которые конфиг читается.
struct ConfigRules: Equatable, Sendable {
    /// Папка конфигов от корня проекта.
    var folder = "Configs"
    /// Реестр в этой папке: `{ "<группа>": [ { "path": …, "alias": … } ] }`.
    var registry = "registry.json"
    /// Сборка папки в один конфиг (`by_files`, `by_folders`).
    var folderConfig = "folder.json"
    /// Куда складываются собранные из папок конфиги.
    var generated = "Generated"
    /// Класс с константами-алиасами (и файл `<класс>.cs`).
    var aliases = "ConfigNames"
    /// Атрибут у константы, называющий модель: `[ConfigModel(typeof(Model))]`.
    var modelAttribute = "ConfigModel"
    /// Атрибут у поля модели с ключом JSON: `[JsonProperty("key")]`.
    var keyAttribute = "JsonProperty"

    var aliasesFile: String { aliases + ".cs" }
}

// MARK: - Разбор extension.json

extension ProjectRules {
    struct Manifest: Equatable, Sendable {
        var name: String
        var description: String?
        var rules: ProjectRules
    }

    enum ManifestError: Error, Equatable {
        case notJSON
        case missing(String)
    }

    static func manifest(from data: Data) throws -> Manifest {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManifestError.notJSON
        }
        guard let name = json["name"] as? String, !name.isEmpty else { throw ManifestError.missing("name") }
        var rules = ProjectRules()

        if let pair = json["pair"] as? [String: Any] {
            for item in pair["suffixes"] as? [[String]] ?? [] where item.count == 2 {
                rules.pair.suffixes.append(PairRules.Suffixes(first: item[0], second: item[1]))
            }
            rules.pair.mirrors = (pair["mirrors"] as? [String] ?? []).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        }

        if let section = json["datagrams"] as? [String: Any] {
            guard let interface = section["interface"] as? String, !interface.isEmpty else {
                throw ManifestError.missing("datagrams.interface")
            }
            var datagrams = DatagramRules(interface: interface)
            func list(_ key: String, into path: WritableKeyPath<DatagramRules, [String]>) {
                if let names = section[key] as? [String], !names.isEmpty { datagrams[keyPath: path] = names }
                else if let name = section[key] as? String, !name.isEmpty { datagrams[keyPath: path] = [name] }
            }
            list("write", into: \.write)
            list("read", into: \.read)
            list("send", into: \.send)
            list("receive", into: \.receive)
            rules.datagrams = datagrams
        }

        if let section = json["configs"] as? [String: Any] {
            var configs = ConfigRules()
            func text(_ key: String, into path: WritableKeyPath<ConfigRules, String>) {
                if let value = section[key] as? String, !value.isEmpty { configs[keyPath: path] = value }
            }
            text("folder", into: \.folder)
            text("registry", into: \.registry)
            text("folderConfig", into: \.folderConfig)
            text("generated", into: \.generated)
            text("aliases", into: \.aliases)
            text("modelAttribute", into: \.modelAttribute)
            text("keyAttribute", into: \.keyAttribute)
            rules.configs = configs
        }

        return Manifest(name: name, description: json["description"] as? String, rules: rules)
    }
}

// MARK: - Расширения в проекте

/// Расширение, найденное в проекте.
struct ProjectExtension: Equatable, Sendable {
    /// Папка расширения.
    var directory: URL
    var manifest: ProjectRules.Manifest
    /// Отпечаток содержимого: расширение поменялось — спросить заново.
    var fingerprint: String

    static let folder = ".pilot/extensions"
    static let manifestName = "extension.json"

    /// Все расширения в `.pilot/extensions/` корня. Сломанные пропускаются —
    /// с причиной в `problems`.
    static func discover(in root: URL) -> (found: [ProjectExtension], problems: [String]) {
        let base = root.appendingPathComponent(folder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return ([], []) }
        var found: [ProjectExtension] = []
        var problems: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let directory = base.appendingPathComponent(name, isDirectory: true)
            let file = directory.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                let manifest = try ProjectRules.manifest(from: data)
                found.append(ProjectExtension(directory: directory, manifest: manifest,
                                              fingerprint: fingerprint(of: data)))
            } catch ProjectRules.ManifestError.missing(let key) {
                problems.append(L("\(folder)/\(name)/\(manifestName): нет «\(key)»"))
            } catch {
                problems.append(L("\(folder)/\(name)/\(manifestName): не JSON"))
            }
        }
        return (found, problems)
    }

    /// FNV-1a: сравнить с тем, на что соглашались, — не криптография.
    static func fingerprint(of data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
