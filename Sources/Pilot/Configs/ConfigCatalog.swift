import Foundation

/// Каталог конфигов по правилам расширения (`ConfigRules`, имена ниже — по
/// умолчанию). Реестр в папке конфигов сопоставляет алиас — то, по чему код
/// берёт конфиг, `Config.Get<T>(ConfigNames.Jobs)`, — и JSON-файл с ним:
///
/// ```json
/// { "shared": [ { "path": "jobs/jobs.json", "alias": "Jobs" } ], "server": [ … ] }
/// ```
///
/// Второй источник — «деревья»: папка с `folder.json` собирается при
/// загрузке в один конфиг (`Generated/<алиас>_data_generated.json`).
/// `by_files` — все JSON папки под одним алиасом; `by_folders` — алиас с
/// точкой на конце плюс имя файла из подпапки: `Chests.` + `main.json` в
/// каждой папке — это `Chests.main`. У такого алиаса исходников много, и
/// ведёт он к ним, а не к сгенерированному файлу, который правят не руками.
///
/// Ни компилятор, ни индекс объявлений об этой связи не знают: для них
/// алиас — просто строковая константа. Каталог её и восстанавливает — ⌘B по
/// `ConfigNames.Jobs` открывает `jobs/jobs.json`.
struct ConfigCatalog: Sendable {
    /// Папка конфигов: пути — от неё.
    let directory: URL
    /// Имена из расширения проекта: реестр, сборка папок, атрибуты.
    let rules: ConfigRules
    /// Алиас → файлы, из которых он собран, от `directory`.
    let sources: [String: [String]]
    /// Путь от `directory` → алиас.
    let aliasByPath: [String: String]

    var metaURL: URL { directory.appendingPathComponent(rules.registry) }

    /// Файлы конфига. Алиас с точкой на конце, которого нет целиком, —
    /// префикс: код дописывает к нему имя (`DAILY_TASKS_DIRECTORY + "army"`),
    /// и ведёт он ко всем конфигам с этим началом.
    func files(forAlias alias: String) -> [URL] {
        if let paths = sources[alias] { return paths.map { directory.appendingPathComponent($0) } }
        guard alias.count > 1, alias.hasSuffix(".") else { return [] }
        return sources.filter { $0.key.hasPrefix(alias) }
            .sorted { $0.key < $1.key }
            .flatMap(\.value)
            .map { directory.appendingPathComponent($0) }
    }

    func knows(_ alias: String) -> Bool { !files(forAlias: alias).isEmpty }

    /// Алиас конфига, лежащего по этому адресу.
    func alias(of url: URL) -> String? {
        path(of: url).flatMap { aliasByPath[$0] }
    }

    func path(of url: URL) -> String? {
        let base = directory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    func isMeta(_ url: URL) -> Bool {
        url.standardizedFileURL.path == metaURL.standardizedFileURL.path
    }

    /// Каталог проекта: реестр в папке конфигов и деревья под ней.
    /// `nil` — у проекта такого нет, или это какой-то другой JSON.
    static func load(root: URL, rules: ConfigRules) -> ConfigCatalog? {
        let directory = root.appendingPathComponent(rules.folder)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(rules.registry)),
              let entries = parse(data), !entries.isEmpty else { return nil }
        return ConfigCatalog(directory: directory, rules: rules, entries: entries + trees(in: directory, rules: rules))
    }

    init(directory: URL, rules: ConfigRules, entries: [(alias: String, path: String)]) {
        self.directory = directory
        self.rules = rules
        var byAlias: [String: [String]] = [:]
        var byPath: [String: String] = [:]
        for entry in entries {
            // Сгенерированный файл дерева — не исходник: его алиас ведёт к
            // файлам, из которых он собран.
            if entry.path.hasPrefix(rules.generated + "/") { continue }
            if byAlias[entry.alias]?.contains(entry.path) != true { byAlias[entry.alias, default: []].append(entry.path) }
            if byPath[entry.path] == nil { byPath[entry.path] = entry.alias }
        }
        sources = byAlias.mapValues { $0.count > 1 ? $0.sorted() : $0 }
        aliasByPath = byPath
    }

    /// Разделы реестра — массивы записей `{path, alias}`. Хоть один раздел
    /// другой формы — значит, это не реестр, и каталога нет.
    static func parse(_ data: Data) -> [(alias: String, path: String)]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var entries: [(alias: String, path: String)] = []
        for key in object.keys.sorted() {
            guard let section = object[key] as? [[String: Any]] else { return nil }
            for item in section {
                guard let path = item["path"] as? String, let alias = item["alias"] as? String else { return nil }
                entries.append((alias, path))
            }
        }
        return entries
    }

    /// Способ сборки папки из её `folder.json`: алиас и `merge.type`.
    static func folderConfig(_ data: Data) -> (alias: String, byFolders: Bool)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let alias = object["alias"] as? String, !alias.isEmpty,
              let merge = object["merge"] as? [String: Any], let type = merge["type"] as? String else { return nil }
        switch type {
        case "by_files":   return (alias, false)
        case "by_folders": return (alias, true)
        default:           return nil
        }
    }

    /// Файл, который дерево берёт в сборку: JSON, кроме самого `folder.json`
    /// и того, что сгенерировано.
    static func isTreeSource(_ name: String, rules: ConfigRules) -> Bool {
        name.hasSuffix(".json") && name.lowercased() != rules.folderConfig.lowercased()
            && !name.hasSuffix("_generated.json")
    }

    /// Записи деревьев — как записи реестра: алиас и исходный файл.
    ///
    /// Обход по путям-строкам: `Configs` — это тысячи файлов, а
    /// `folder.json` среди них — два десятка; свойства спрашиваются только у
    /// содержимого этих папок.
    static func trees(in directory: URL, rules: ConfigRules) -> [(alias: String, path: String)] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: directory.path) else { return [] }
        func children(_ folder: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: directory.path + "/" + folder)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
        }
        func isFolder(_ path: String) -> Bool {
            var folder: ObjCBool = false
            return fm.fileExists(atPath: directory.path + "/" + path, isDirectory: &folder) && folder.boolValue
        }
        func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : a + "/" + b }

        var entries: [(alias: String, path: String)] = []
        while let path = walker.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            if name == rules.generated || name.hasPrefix(".") {
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { walker.skipDescendants() }
                continue
            }
            guard name == rules.folderConfig,
                  let data = fm.contents(atPath: directory.path + "/" + path),
                  let config = folderConfig(data) else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            if config.byFolders {
                for sub in children(folder).map({ join(folder, $0) }) where isFolder(sub) {
                    for file in children(sub) where isTreeSource(file, rules: rules) && !isFolder(join(sub, file)) {
                        entries.append((config.alias + (file as NSString).deletingPathExtension, join(sub, file)))
                    }
                }
            } else {
                for file in children(folder) where isTreeSource(file, rules: rules) && !isFolder(join(folder, file)) {
                    entries.append((config.alias, join(folder, file)))
                }
            }
        }
        return entries
    }

    // MARK: - Что под курсором

    /// Строковый литерал вокруг смещения — содержимое без кавычек и его
    /// диапазон. Кавычки считаются в пределах строки, `\"` — не кавычка.
    static func stringLiteral<C: RandomAccessCollection>(in units: C, line: Range<Int>, at offset: Int)
        -> (text: String, range: Range<Int>)? where C.Element == UInt16, C.Index == Int {
        var open: Int?
        var i = line.lowerBound
        while i < line.upperBound {
            let c = units[i]
            if c == 0x5C, open != nil { i += 2; continue }          // \x внутри строки
            if c == 0x22 {                                          // "
                if let start = open {
                    if start < offset && offset <= i {
                        let range = (start + 1)..<i
                        return (String(decoding: units[range], as: UTF16.self), range)
                    }
                    open = nil
                } else {
                    open = i
                }
            }
            i += 1
        }
        return nil
    }

    /// Объявление строковой константы в строке кода: `Name = "value"`.
    /// `name` — если нужно именно это имя. Отдаёт имя, значение и колонку
    /// имени в UTF-16.
    static func constant(in line: String, named name: String? = nil) -> (name: String, value: String, column: Int)? {
        let units = Array(line.utf16)
        var i = 0
        while i < units.count {
            guard units[i] == 0x3D else { i += 1; continue }        // =
            // `==`, `=>`, `<=`, `!=` — не присваивание.
            let next = i + 1 < units.count ? units[i + 1] : 0
            let previous = i > 0 ? units[i - 1] : 0
            if next == 0x3D || next == 0x3E || [0x3D, 0x21, 0x3C, 0x3E].contains(previous) { i += 1; continue }

            var end = i
            while end > 0, units[end - 1] == 0x20 || units[end - 1] == 0x09 { end -= 1 }
            var start = end
            while start > 0, isIdentifierPart(units[start - 1]) { start -= 1 }
            var q = i + 1
            while q < units.count, units[q] == 0x20 || units[q] == 0x09 { q += 1 }
            guard start < end, q < units.count, units[q] == 0x22 else { i += 1; continue }
            var close = q + 1
            while close < units.count, units[close] != 0x22 {
                if units[close] == 0x5C { close += 1 }
                close += 1
            }
            guard close < units.count else { return nil }
            let found = String(decoding: units[start..<end], as: UTF16.self)
            if name == nil || name == found {
                return (found, String(decoding: units[(q + 1)..<close], as: UTF16.self), start)
            }
            i = close + 1
        }
        return nil
    }

    /// Модель конфига из `[ConfigModel(typeof(Model))]` у объявления алиаса —
    /// текст внутри `typeof(…)`, дженерики как есть.
    static func modelType(in line: String, attribute name: String) -> String? {
        guard let attribute = line.range(of: name + "(typeof("),
              let close = line[attribute.upperBound...].range(of: "))") else { return nil }
        let text = line[attribute.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Имена в тексте типа, последнее — первым: у `Dictionary<ElementModel,
    /// VehicleParametersItemModel>` интереснее модель, чем словарь.
    static func typeNames(in text: String) -> [String] {
        var names: [String] = []
        var current = ""
        for c in text {
            if c.isLetter || c.isNumber || c == "_" {
                current.append(c)
            } else {
                if !current.isEmpty { names.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { names.append(current) }
        return names.reversed()
    }

    private static func isIdentifierPart(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
    }
}

/// Каталог текущего проекта. Собирается в фоне — обход папки конфигов это
/// тысячи файлов — и заранее, при открытии проекта: ⌘B берёт готовый.
///
/// Реестр правят, а деревья меняются и без него (новая папка),
/// поэтому каталог, чей реестр поменялся или который старше `lifetime`,
/// отдаётся как есть, а следом пересобирается.
@MainActor
final class ConfigCatalogCache {
    private var root: URL?
    private var rules: ConfigRules?
    private var stamp: Date?
    private var loaded = Date.distantPast
    private var cached: ConfigCatalog?
    private var loading = false
    private let lifetime: TimeInterval = 10

    /// Проект открыт: собрать каталог, пока до него не дошло.
    /// Без правил конфигов в расширениях проекта каталога нет.
    func warm(root: URL?, rules: ConfigRules?) {
        guard let root, let rules else { self.root = nil; self.rules = nil; cached = nil; return }
        if root != self.root || rules != self.rules {
            self.root = root; self.rules = rules; cached = nil; stamp = nil; loaded = .distantPast
        }
        refresh()
    }

    /// Каталог проекта, если он у проекта есть и уже собран.
    func catalog(root: URL, rules: ConfigRules?) -> ConfigCatalog? {
        guard let rules else { return nil }
        if root != self.root || rules != self.rules { warm(root: root, rules: rules); return nil }
        if cached == nil || metaStamp(root) != stamp || Date().timeIntervalSince(loaded) > lifetime { refresh() }
        return cached
    }

    private func metaStamp(_ root: URL) -> Date? {
        guard let rules else { return nil }
        let meta = root.appendingPathComponent(rules.folder).appendingPathComponent(rules.registry)
        return (try? FileManager.default.attributesOfItem(atPath: meta.path))?[.modificationDate] as? Date
    }

    private func refresh() {
        guard let root, let rules, !loading else { return }
        let stamp = metaStamp(root)
        // Нет реестра — нет и каталога, обходить нечего.
        guard stamp != nil else { cached = nil; self.stamp = nil; loaded = Date(); return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            let catalog = ConfigCatalog.load(root: root, rules: rules)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loading = false
                guard self.root == root, self.rules == rules else { return }
                self.cached = catalog
                self.stamp = stamp
                self.loaded = Date()
                if let catalog {
                    NSLog("[configs] каталог: %d алиасов, %d файлов за %d мс", catalog.sources.count,
                          catalog.aliasByPath.count, Int(Date().timeIntervalSince(started) * 1000))
                }
            }
        }
    }
}
