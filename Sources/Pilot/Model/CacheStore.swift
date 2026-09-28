import Foundation

// MARK: - Виды кэша

/// Что именно Pilot хранит на диске: где лежит, что ускоряет и во что
/// обходится без него.
///
/// Порядок случаев — порядок цветов на схеме в Настройках → Кэши: соседние
/// цвета там подобраны так, чтобы различаться и при нарушениях цветового
/// зрения. Новый вид встаёт в конец, а не между.
enum CacheKind: String, CaseIterable, Identifiable, Sendable {
    /// `rustlyn/<проект>/compilation.bin`: снимок компиляции проекта.
    case compilation
    /// `rustlyn/<проект>/{lines,outline,symbols}`: разобранные файлы C#.
    case parsedFiles
    /// `<хэш>.symbols` и `<хэш>.types`: объявления для навигатора и ⇧⇧.
    case declarations
    /// `<хэш>.idx`: список файлов проекта.
    case fileList
    /// `<хэш>.unity`: GUID ассетов Unity.
    case unityAssets
    /// `<хэш>.assemblies`: типы сборок, к которым нет исходников.
    case assemblyTypes
    /// `rustlyn/assemblies`: декомпилированные сборки, общие для всех проектов.
    case decompiled
    /// `jadx.jsa`: архив классов JVM, с которым быстрее запускается jadx.
    case jadx
    /// `rustlyn/<проект>/{assembly,decompiled}`: сборки, разобранные в папке
    /// проекта до того, как их кэш стал общим. Их никто уже не читает.
    case leftovers
    /// `Application Support/Pilot/Copilot/<версия>`, кроме текущей.
    case oldCopilot
    /// Локальная история правок. Не кэш: заново её не собрать, поэтому
    /// она не выключается, не входит ни в какую очистку и удаляется только
    /// по подтверждению.
    case history

    var id: String { rawValue }

    /// Всё, что на самом деле кэш, — без истории правок.
    static var caches: [CacheKind] { allCases.filter(\.isCache) }

    var isCache: Bool { self != .history }

    /// Можно не хранить: Pilot пишет его сам и умеет без него — медленнее,
    /// но так же верно. Остатки и старые версии Copilot никто не пишет,
    /// выключать там нечего.
    var isSwitchable: Bool {
        switch self {
        case .leftovers, .oldCopilot, .history: return false
        default: return true
        }
    }

    /// Один на все проекты, а не свой у каждого.
    var isShared: Bool { self == .decompiled || self == .jadx || self == .oldCopilot }

    /// Хранится только вместе с другим видом: компиляцию Rustlyn пишет в ту
    /// же папку проекта, что и разбор файлов, а без неё писать её некуда.
    var storedWith: CacheKind? { self == .compilation ? .parsedFiles : nil }

    /// Настройка доходит до открытых проектов сразу. Папку кэша и общее
    /// хранилище сборок сессия Rustlyn получает, когда проект открывают, а
    /// архив классов — JVM jadx при запуске: для них — со следующего раза.
    var appliesToOpenProjects: Bool { self != .parsedFiles && self != .decompiled && self != .jadx }

    /// Вид файла индекса по расширению: `.idx`, `.symbols`, `.types`,
    /// `.assemblies`, `.unity`. nil — не индекс.
    static func ofIndexFile(extension ext: String) -> CacheKind? {
        switch ext {
        case "idx": return .fileList
        case "symbols", "types": return .declarations
        case "assemblies": return .assemblyTypes
        case "unity": return .unityAssets
        default: return nil
        }
    }

    /// Вид того, что лежит в папке проекта у Rustlyn. Всё незнакомое —
    /// тоже его кэш разбора: Rustlyn пишет в эту папку, только когда разбор
    /// хранится.
    static func ofRustlynItem(_ name: String) -> CacheKind {
        // `compilation.bin` и недописанный `compilation.<pid>.partial`.
        if name.hasPrefix("compilation.") { return .compilation }
        if name == "assembly" || name == "decompiled" { return .leftovers }
        return .parsedFiles
    }

    var title: String {
        switch self {
        case .compilation: return L("Компиляция Rustlyn")
        case .parsedFiles: return L("Разбор файлов Rustlyn")
        case .declarations: return L("Индекс объявлений")
        case .fileList: return L("Список файлов")
        case .unityAssets: return L("GUID ассетов Unity")
        case .assemblyTypes: return L("Типы из сборок")
        case .decompiled: return L("Разобранные сборки .NET")
        case .jadx: return L("Архив классов jadx")
        case .leftovers: return L("Остатки прежних версий")
        case .oldCopilot: return L("Старые версии сервера Copilot")
        case .history: return L("История правок")
        }
    }

    /// Что ускоряет — и что будет без него.
    var detail: String {
        switch self {
        case .compilation:
            return L("⌘B, ссылки и подсказки работают сразу при открытии проекта. Без неё — только после компиляции.")
        case .parsedFiles:
            return L("Открытие проекта читает разобранные файлы C#, а не разбирает их заново. Без него — разбор всех файлов, и компиляция не хранится.")
        case .declarations:
            return L("Навигатор и ⇧⇧ по типам — с первой секунды; разбираются только изменённые файлы. Без него — весь проект при каждом открытии.")
        case .fileList:
            return L("Дерево и ⌘P — сразу при открытии. Без него — после обхода папки, а вторая половина пары ищется, только пока открыто её окно.")
        case .unityAssets:
            return L("Ссылки на ассеты подписаны с первой секунды, перечитываются только изменённые .meta. Без него — все .meta при каждом открытии.")
        case .assemblyTypes:
            return L("⇧⇧ и ⌘B по типам движка и плагинов без чтения сотен сборок. Без него — сборки читаются при каждом открытии.")
        case .decompiled:
            return L("Декомпилированные сборки, общие для всех проектов: UnityEditor разбирается один раз. Без них — при каждом открытии проекта.")
        case .jadx:
            return L("Ускоряет запуск декомпилятора Java. Без него каждый запуск дольше.")
        case .leftovers:
            return L("Сборки, разобранные в папках проектов до того, как их кэш стал общим. Не используются.")
        case .oldCopilot:
            return L("Скачанные раньше; нужна только текущая версия.")
        case .history:
            return L("Не кэш: прежние версии файлов, которые Pilot сохранял при правке. Удалённую историю не вернуть.")
        }
    }
}

// MARK: - Настройка

/// Какие виды кэша Pilot хранит на диске.
///
/// Выключенный вид Pilot не пишет и не читает — даже если от прошлого на
/// диске что-то осталось: оно больше не обновляется и с каждым днём
/// старее. Всё, что кэш ускоряет, строится заново при каждом открытии.
struct CachePolicy: Equatable, Sendable {
    /// Выключенные в настройках — как есть, без зависимостей: включат
    /// разбор файлов обратно — вернётся и компиляция, если её саму не
    /// выключали.
    var switchedOff: Set<CacheKind> = []

    /// Хранится ли вид — с учётом того, без чего его хранить негде.
    func stores(_ kind: CacheKind) -> Bool {
        guard kind.isSwitchable else { return true }
        if switchedOff.contains(kind) { return false }
        return kind.storedWith.map(stores) ?? true
    }

    static let key = "pilot.caches.off"

    /// Откуда читать настройку. Тесты подставляют свой набор.
    nonisolated(unsafe) static var defaults = UserDefaults.standard

    /// Настройка сейчас. Кэши спрашивают её при каждой записи и чтении —
    /// это словарь в памяти процесса, а не диск.
    static var current: CachePolicy {
        get {
            let names = defaults.stringArray(forKey: key) ?? []
            return CachePolicy(switchedOff: Set(names.compactMap(CacheKind.init(rawValue:))))
        }
        set { defaults.set(newValue.switchedOff.map(\.rawValue).sorted(), forKey: key) }
    }
}

// MARK: - Обзор и удаление

/// Что Pilot хранит на диске ради скорости, и сколько это стоит.
///
/// Каждый открытый проект оставляет после себя индексы в
/// `~/Library/Caches/Pilot` (`<хэш>.idx`, `.types`, `.symbols`, `.assemblies`,
/// `.unity`) и папку Rustlyn в `Caches/Pilot/rustlyn/<имя>-<хэш>` — у большого
/// Unity-проекта это сотни мегабайт. Хэш везде один — FNV-1a пути корня, —
/// так что всё, что относится к проекту, собирается в одну строку, а внутри
/// неё — по видам (`CacheKind`). Удалить кэш безопасно: при следующем
/// открытии проект соберёт его заново.
///
/// Локальная история правок лежит рядом, но это не кэш — её заново не
/// собрать. Она показывается отдельно и удаляется только по подтверждению.
enum CacheStore {
    /// Строка обзора: проект, общий кэш или история правок одного проекта.
    struct Entry: Identifiable, Equatable {
        enum Scope: Equatable {
            case project
            case shared
            case history
        }

        let id: String
        let scope: Scope
        var name: String
        /// Корень проекта, если он известен.
        var projectPath: String?
        /// По видам, в порядке `CacheKind`.
        var parts: [Part] = []
        /// Папки, которые остаются пустыми, когда удалено всё внутри: папка
        /// проекта у Rustlyn.
        var folders: [URL] = []
        /// Проект открыт в окне Pilot: его кэш сейчас в работе.
        var isOpen = false

        var size: Int64 { parts.reduce(0) { $0 + $1.size } }
        var lastUsed: Date? { parts.compactMap(\.lastUsed).max() }
        /// Всё, на что строка указывает. Папка Rustlyn содержит свои части —
        /// мерить по этому списку нельзя, размер — `size`.
        var urls: [URL] { parts.flatMap(\.urls) + folders }

        func part(_ kind: CacheKind) -> Part? { parts.first { $0.kind == kind } }

        /// Папки проекта больше нет — кэш не пригодится никогда.
        var isOrphan: Bool {
            guard let projectPath else { return false }
            return !FileManager.default.fileExists(atPath: projectPath)
        }
    }

    /// Всё одного вида в одной строке.
    struct Part: Identifiable, Equatable {
        let kind: CacheKind
        var urls: [URL]
        var size: Int64 = 0
        var lastUsed: Date?
        /// Лежит в папке, в которую сейчас пишет живая сессия Rustlyn.
        var isHeld = false

        var id: CacheKind { kind }
    }

    struct Locations {
        var caches: URL
        var support: URL

        /// `PILOT_CACHES` — своя папка вместо `~/Library`: замеры скорости
        /// (`bin/pilot-perf`) открывают проект каждый раз с одних и тех же
        /// кэшей и не трогают ни кэши, ни историю правок того Pilot, в
        /// котором работают.
        static var standard: Locations {
            if let own = ProcessInfo.processInfo.environment["PILOT_CACHES"], !own.isEmpty {
                let base = URL(fileURLWithPath: own, isDirectory: true)
                return Locations(caches: base.appendingPathComponent("Caches/Pilot"),
                                 support: base.appendingPathComponent("Application Support/Pilot"))
            }
            let fm = FileManager.default
            return Locations(
                caches: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pilot"),
                support: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pilot"))
        }

        var rustlyn: URL { caches.appendingPathComponent("rustlyn") }
        /// Общее хранилище разобранных сборок: движок Unity одной версии —
        /// один и тот же файл в каждом проекте.
        var sharedAssemblies: URL { rustlyn.appendingPathComponent("assemblies") }
        var jadxArchive: URL { caches.appendingPathComponent("jadx.jsa") }
        var history: URL { support.appendingPathComponent("History") }
        var copilot: URL { support.appendingPathComponent("Copilot") }

        /// Файл индекса проекта: хэш корня с нулями впереди и расширение вида.
        func indexFile(root: URL, extension ext: String) -> URL {
            caches.appendingPathComponent(String(format: "%016llx.", CacheStore.projectHash(root.path)) + ext)
        }

        /// Папка проекта у Rustlyn: читаемое начало имени и хэш — без нулей
        /// впереди, чтобы два проекта с одинаковым именем не делили кэш.
        func rustlynFolder(root: URL) -> URL {
            let name = root.lastPathComponent.prefix(32)
            return rustlyn.appendingPathComponent("\(name)-\(String(CacheStore.projectHash(root.path), radix: 16))")
        }
    }

    /// FNV-1a пути корня: так кэши проекта называют и индекс, и Rustlyn,
    /// и локальная история.
    static func projectHash(_ path: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }

    /// `clm-client-601d193ed31307b3` → (`clm-client`, хэш). Индекс пишет хэш
    /// с нулями впереди, Rustlyn — без: сравниваем числа, а не строки.
    static func splitNameAndHash(_ folder: String) -> (name: String, hash: UInt64)? {
        guard let dash = folder.lastIndex(of: "-"),
              let hash = UInt64(folder[folder.index(after: dash)...], radix: 16) else { return nil }
        return (String(folder[..<dash]), hash)
    }

    // MARK: Кэш сессии Rustlyn и jadx

    /// Где сессии Rustlyn держать кэш.
    struct RustlynCaches: Equatable {
        /// Папка проекта; nil — между запусками не хранить ничего.
        var project: URL?
        /// Куда класть разобранные сборки.
        var assemblies: URL
        var keepsAssemblies: Bool
    }

    /// Папка, которой не может быть: `/dev/null` — не каталог. Своего «только
    /// в памяти» у общего хранилища сборок в Rustlyn нет, а без общего он
    /// складывал бы сборки в папку проекта. Запись, для которой не создать
    /// папку, он молча пропускает, а прочесть оттуда ему нечего, — так
    /// разобранное живёт только в памяти сессии.
    static let nowhere = URL(fileURLWithPath: "/dev/null/pilot-no-cache")

    static func rustlynCaches(root: URL, policy: CachePolicy, at locations: Locations = .standard) -> RustlynCaches {
        let keepsAssemblies = policy.stores(.decompiled)
        return RustlynCaches(project: policy.stores(.parsedFiles) ? locations.rustlynFolder(root: root) : nil,
                             assemblies: keepsAssemblies ? locations.sharedAssemblies : nowhere,
                             keepsAssemblies: keepsAssemblies)
    }

    /// Флаги JVM для архива общих классов jadx: с ним второй и следующие
    /// запуски заметно быстрее. Не хранится — JVM берёт только свой,
    /// встроенный в JDK, и ничего не пишет.
    static func jadxArguments(policy: CachePolicy, at locations: Locations = .standard) -> [String] {
        guard policy.stores(.jadx) else { return [] }
        return ["-XX:SharedArchiveFile=\(locations.jadxArchive.path)", "-XX:+AutoCreateSharedArchive", "-Xshare:auto"]
    }

    // MARK: Обзор

    /// Всё, что лежит на диске. `known` — корни проектов, которые Pilot
    /// помнит (недавние и открытые): по ним строки получают имя и путь.
    /// `held` — папки проектов у Rustlyn, в которые сейчас пишут живые сессии.
    static func scan(known: [URL], open: [URL], held: Set<String> = [], copilotVersion: String?,
                     at locations: Locations = .standard) -> [Entry] {
        let fm = FileManager.default
        var byHash: [UInt64: String] = [:]
        for root in known + open { byHash[projectHash(root.path)] = root.path }
        let openHashes = Set(open.map { projectHash($0.path) })

        var projects: [UInt64: Entry] = [:]
        func project(_ hash: UInt64, name: String?) -> Entry {
            if let entry = projects[hash] { return entry }
            let path = byHash[hash]
            return Entry(id: "project-" + String(hash, radix: 16), scope: .project,
                         name: path.map { ($0 as NSString).lastPathComponent } ?? name ?? String(format: "%016llx", hash),
                         projectPath: path, isOpen: openHashes.contains(hash))
        }

        // Rustlyn первым: его папка знает имя проекта.
        for folder in contents(of: locations.rustlyn) where folder.lastPathComponent != "assemblies" {
            guard let (name, hash) = splitNameAndHash(folder.lastPathComponent) else { continue }
            var entry = project(hash, name: name)
            entry.folders.append(folder)
            let isHeld = held.contains(folder.path)
            for item in contents(of: folder) {
                add(item, as: CacheKind.ofRustlynItem(item.lastPathComponent), to: &entry.parts, held: isHeld)
            }
            projects[hash] = entry
        }
        for file in contents(of: locations.caches) {
            guard let kind = CacheKind.ofIndexFile(extension: file.pathExtension),
                  let hash = UInt64(file.deletingPathExtension().lastPathComponent, radix: 16) else { continue }
            var entry = project(hash, name: nil)
            add(file, as: kind, to: &entry.parts)
            projects[hash] = entry
        }

        // Проекты без имени — те, что выпали из недавних и не оставили папки
        // Rustlyn: от них только индексы по несколько килобайт. Порознь это
        // десяток строк из хэшей, вместе — одна.
        let nameless = projects.filter { byHash[$0.key] == nil && $0.value.name == String(format: "%016llx", $0.key) }
        var entries = projects.filter { nameless[$0.key] == nil }.map(\.value)
        if !nameless.isEmpty {
            var merged = Entry(id: "project-unknown", scope: .project,
                               name: L("Проекты, которых Pilot не помнит (\(String(nameless.count)))"))
            for part in nameless.values.flatMap(\.parts) {
                for url in part.urls { add(url, as: part.kind, to: &merged.parts) }
            }
            entries.append(merged)
        }

        func shared(_ kind: CacheKind, _ urls: [URL]) {
            guard !urls.isEmpty else { return }
            entries.append(Entry(id: kind.rawValue, scope: .shared, name: kind.title,
                                 parts: [Part(kind: kind, urls: urls)]))
        }
        shared(.decompiled, [locations.sharedAssemblies].filter { fm.fileExists(atPath: $0.path) })
        shared(.jadx, [locations.jadxArchive].filter { fm.fileExists(atPath: $0.path) })
        shared(.oldCopilot, contents(of: locations.copilot).filter { $0.lastPathComponent != copilotVersion })

        for folder in contents(of: locations.history) {
            guard let (name, hash) = splitNameAndHash(folder.lastPathComponent) else { continue }
            entries.append(Entry(id: "history-" + String(hash, radix: 16), scope: .history,
                                 name: byHash[hash].map { ($0 as NSString).lastPathComponent } ?? name,
                                 projectPath: byHash[hash], parts: [Part(kind: .history, urls: [folder])],
                                 isOpen: openHashes.contains(hash)))
        }

        for index in entries.indices {
            for p in entries[index].parts.indices {
                let (size, date) = measure(entries[index].parts[p].urls)
                entries[index].parts[p].size = size
                entries[index].parts[p].lastUsed = date
            }
        }
        return entries.sorted { $0.size > $1.size }
    }

    /// В часть своего вида, а частей — в порядке `CacheKind`.
    private static func add(_ url: URL, as kind: CacheKind, to parts: inout [Part], held: Bool = false) {
        if let index = parts.firstIndex(where: { $0.kind == kind }) {
            parts[index].urls.append(url)
            parts[index].isHeld = parts[index].isHeld || held
            return
        }
        parts.append(Part(kind: kind, urls: [url], isHeld: held))
        let order = CacheKind.allCases
        parts.sort { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }

    /// Содержимое папки — путями от неё самой. Листинг по URL отдал бы
    /// `/private/var/…` там, где папку назвали `/var/…`, и пути, собранные
    /// из `Locations` (папки живых сессий Rustlyn), с ним бы не совпали.
    private static func contents(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Место на диске и последняя запись — по всем файлам внутри.
    static func measure(_ urls: [URL]) -> (Int64, Date?) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var size: Int64 = 0
        var newest: Date?
        func add(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return }
            size += Int64(values.totalFileAllocatedSize ?? 0)
            if let date = values.contentModificationDate, newest.map({ date > $0 }) ?? true { newest = date }
        }
        for url in urls {
            add(url)
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { continue }
            for case let file as URL in walker { add(file) }
        }
        return (size, newest)
    }

    /// Сколько занимает каждый вид — по всем строкам.
    static func totals(_ entries: [Entry]) -> [CacheKind: Int64] {
        var sums: [CacheKind: Int64] = [:]
        for part in entries.flatMap(\.parts) { sums[part.kind, default: 0] += part.size }
        return sums
    }

    // MARK: Удаление

    /// Часть, которую сейчас держит открытый проект: удалять её незачем —
    /// её тут же запишут заново, — а папку разбора и нельзя: Rustlyn пишет
    /// в неё, пока сессия жива. Выключенный вид открытый проект уже не
    /// пишет — его можно; остатки и общие кэши — всегда.
    static func isBusy(_ part: Part, in entry: Entry, policy: CachePolicy = .current) -> Bool {
        switch part.kind {
        case .history: return entry.isOpen
        case .leftovers, .oldCopilot, .decompiled, .jadx: return false
        case .parsedFiles: return part.isHeld
        case .compilation: return part.isHeld && policy.stores(.compilation)
        case .fileList, .declarations, .unityAssets, .assemblyTypes: return entry.isOpen && policy.stores(part.kind)
        }
    }

    /// Есть что удалить — хотя бы пустую папку, оставшуюся от проекта.
    static func canRemove(_ entry: Entry, kinds: Set<CacheKind>? = nil, policy: CachePolicy = .current) -> Bool {
        entry.parts.contains { part in
            (kinds?.contains(part.kind) ?? true) && !isBusy(part, in: entry, policy: policy)
        } || (kinds == nil && !entry.isOpen && !entry.folders.isEmpty)
    }

    /// Сколько освободит `remove(entry, kinds:)`.
    static func removableSize(_ entry: Entry, kinds: Set<CacheKind>? = nil, policy: CachePolicy = .current) -> Int64 {
        entry.parts.filter { (kinds?.contains($0.kind) ?? true) && !isBusy($0, in: entry, policy: policy) }
            .reduce(0) { $0 + $1.size }
    }

    /// Удаляет части строки — все или только `kinds`, — кроме занятых.
    /// Опустевшую папку проекта у Rustlyn — тоже, если проект не открыт.
    /// false — что-то осталось: занято или не удалилось.
    @discardableResult
    static func remove(_ entry: Entry, kinds: Set<CacheKind>? = nil, policy: CachePolicy = .current) -> Bool {
        let fm = FileManager.default
        var ok = true
        for part in entry.parts where kinds?.contains(part.kind) ?? true {
            guard !isBusy(part, in: entry, policy: policy) else { ok = false; continue }
            for url in part.urls where fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) } catch { ok = false }
            }
        }
        if !entry.isOpen {
            for folder in entry.folders where (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fm.removeItem(at: folder)
            }
        }
        return ok
    }

    /// Устаревшее: кэши проектов, которых не открывали `days` дней или
    /// которых больше нет на диске, и остатки прежних версий у всех —
    /// их не читает никто. История правок сюда не входит — она не кэш;
    /// старые версии Copilot — тоже: у сборки Pilot из другой ветки версия
    /// может быть другой, и чужая «старая» для неё — текущая.
    static func stale(_ entries: [Entry], olderThan days: Int, now: Date = Date(),
                      policy: CachePolicy = .current) -> [Entry] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.compactMap { entry in
            guard entry.scope == .project else { return nil }
            if !entry.isOpen, entry.isOrphan || (entry.lastUsed.map { $0 < cutoff } ?? true),
               canRemove(entry, policy: policy) {
                return entry
            }
            var junk = entry
            junk.parts = entry.parts.filter { $0.kind == .leftovers }
            junk.folders = []
            return junk.parts.isEmpty ? nil : junk
        }
    }

    // MARK: - Автоочистка

    static let autoCleanKey = "pilot.caches.autoCleanDays"

    /// Раз в день, в фоне: кэши проектов, которые давно не открывали.
    /// 0 — выключено.
    static func autoClean(known: [URL], open: [URL], held: Set<String>, copilotVersion: String?) {
        let days = UserDefaults.standard.integer(forKey: autoCleanKey)
        guard days > 0 else { return }
        let lastKey = "pilot.caches.lastAutoClean"
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        DispatchQueue.global(qos: .utility).async {
            let entries = scan(known: known, open: open, held: held, copilotVersion: copilotVersion)
            for entry in stale(entries, olderThan: days) { remove(entry) }
        }
    }
}
