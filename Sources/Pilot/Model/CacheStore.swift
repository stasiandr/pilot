import Foundation

/// Что Pilot хранит на диске ради скорости, и сколько это стоит.
///
/// Каждый открытый проект оставляет после себя индексы в
/// `~/Library/Caches/Pilot` (`<хэш>.idx`, `.types`, `.symbols`, `.assemblies`,
/// `.unity`) и папку Rustlyn в `Caches/Pilot/rustlyn/<имя>-<хэш>` — у большого
/// Unity-проекта это сотни мегабайт. Хэш везде один — FNV-1a пути корня, —
/// так что всё, что относится к проекту, собирается в одну строку. Удалить
/// кэш безопасно: при следующем открытии проект соберёт его заново.
///
/// Локальная история правок лежит рядом, но это не кэш — её заново не
/// собрать. Она показывается отдельно и удаляется только по подтверждению.
enum CacheStore {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case project
            /// Сборки .NET, разобранные Rustlyn: общие для всех проектов.
            case assemblies
            /// Архив классов JVM для jadx: быстрее запускает декомпилятор.
            case jadx
            /// Скачанные когда-то версии сервера Copilot, кроме текущей.
            case oldCopilot
            case history
        }

        let id: String
        let kind: Kind
        var name: String
        /// Корень проекта, если он известен.
        var projectPath: String?
        var urls: [URL]
        var size: Int64 = 0
        var lastUsed: Date?
        /// Проект открыт в окне Pilot: его кэш сейчас в работе.
        var isOpen = false

        /// Папки проекта больше нет — кэш не пригодится никогда.
        var isOrphan: Bool {
            guard let projectPath else { return false }
            return !FileManager.default.fileExists(atPath: projectPath)
        }
    }

    struct Locations {
        var caches: URL
        var support: URL

        static var standard: Locations {
            let fm = FileManager.default
            return Locations(
                caches: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pilot"),
                support: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pilot"))
        }

        var rustlyn: URL { caches.appendingPathComponent("rustlyn") }
        var history: URL { support.appendingPathComponent("History") }
        var copilot: URL { support.appendingPathComponent("Copilot") }
    }

    /// FNV-1a пути корня: так кэши проекта называют и индекс, и Rustlyn,
    /// и локальная история.
    static func projectHash(_ path: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }

    private static let indexExtensions: Set<String> = ["idx", "types", "symbols", "assemblies", "unity"]

    /// `clm-client-601d193ed31307b3` → (`clm-client`, хэш). Индекс пишет хэш
    /// с нулями впереди, Rustlyn — без: сравниваем числа, а не строки.
    static func splitNameAndHash(_ folder: String) -> (name: String, hash: UInt64)? {
        guard let dash = folder.lastIndex(of: "-"),
              let hash = UInt64(folder[folder.index(after: dash)...], radix: 16) else { return nil }
        return (String(folder[..<dash]), hash)
    }

    // MARK: - Обзор

    /// Всё, что лежит на диске. `known` — корни проектов, которые Pilot
    /// помнит (недавние и открытые): по ним строки получают имя и путь.
    static func scan(known: [URL], open: [URL], copilotVersion: String?,
                     at locations: Locations = .standard) -> [Entry] {
        let fm = FileManager.default
        var byHash: [UInt64: String] = [:]
        for root in known + open { byHash[projectHash(root.path)] = root.path }
        let openHashes = Set(open.map { projectHash($0.path) })

        var projects: [UInt64: Entry] = [:]
        func project(_ hash: UInt64, name: String?) -> Entry {
            if let entry = projects[hash] { return entry }
            let path = byHash[hash]
            return Entry(id: "project-" + String(hash, radix: 16), kind: .project,
                         name: path.map { ($0 as NSString).lastPathComponent } ?? name ?? String(format: "%016llx", hash),
                         projectPath: path, urls: [], isOpen: openHashes.contains(hash))
        }

        // Rustlyn первым: его папка знает имя проекта.
        for folder in contents(of: locations.rustlyn) where folder.lastPathComponent != "assemblies" {
            guard let (name, hash) = splitNameAndHash(folder.lastPathComponent) else { continue }
            var entry = project(hash, name: name)
            entry.urls.append(folder)
            projects[hash] = entry
        }
        for file in contents(of: locations.caches) where indexExtensions.contains(file.pathExtension) {
            guard let hash = UInt64(file.deletingPathExtension().lastPathComponent, radix: 16) else { continue }
            var entry = project(hash, name: nil)
            entry.urls.append(file)
            projects[hash] = entry
        }

        // Проекты без имени — те, что выпали из недавних и не оставили папки
        // Rustlyn: от них только индексы по несколько килобайт. Порознь это
        // десяток строк из хэшей, вместе — одна.
        let nameless = projects.filter { byHash[$0.key] == nil && $0.value.name == String(format: "%016llx", $0.key) }
        var entries = projects.filter { nameless[$0.key] == nil }.map(\.value)
        if !nameless.isEmpty {
            entries.append(Entry(id: "project-unknown", kind: .project,
                                 name: L("Проекты, которых Pilot не помнит (\(String(nameless.count)))"),
                                 urls: nameless.values.flatMap(\.urls)))
        }
        let assemblies = locations.rustlyn.appendingPathComponent("assemblies")
        if fm.fileExists(atPath: assemblies.path) {
            entries.append(Entry(id: "assemblies", kind: .assemblies, name: L("Разобранные сборки .NET"), urls: [assemblies]))
        }
        let jadx = locations.caches.appendingPathComponent("jadx.jsa")
        if fm.fileExists(atPath: jadx.path) {
            entries.append(Entry(id: "jadx", kind: .jadx, name: L("Архив классов jadx"), urls: [jadx]))
        }
        let old = contents(of: locations.copilot).filter { $0.lastPathComponent != copilotVersion }
        if !old.isEmpty {
            entries.append(Entry(id: "copilot", kind: .oldCopilot,
                                 name: L("Старые версии сервера Copilot"), urls: old))
        }
        for folder in contents(of: locations.history) {
            guard let (name, hash) = splitNameAndHash(folder.lastPathComponent) else { continue }
            entries.append(Entry(id: "history-" + String(hash, radix: 16), kind: .history,
                                 name: byHash[hash].map { ($0 as NSString).lastPathComponent } ?? name,
                                 projectPath: byHash[hash], urls: [folder],
                                 isOpen: openHashes.contains(hash)))
        }

        for index in entries.indices {
            let (size, date) = measure(entries[index].urls)
            entries[index].size = size
            entries[index].lastUsed = date
        }
        return entries.sorted { $0.size > $1.size }
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? []
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

    // MARK: - Удаление

    /// Кэш открытого проекта не трогаем: Rustlyn и индекс держат его в работе
    /// и запишут заново, как только что-то поменяется.
    static func canRemove(_ entry: Entry) -> Bool { !entry.isOpen }

    @discardableResult
    static func remove(_ entry: Entry) -> Bool {
        guard canRemove(entry) else { return false }
        var ok = true
        for url in entry.urls where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch { ok = false }
        }
        return ok
    }

    /// Кэши проектов, которых не открывали `days` дней или которых больше
    /// нет на диске. История правок сюда не входит — она не кэш.
    static func stale(_ entries: [Entry], olderThan days: Int, now: Date = Date()) -> [Entry] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { entry in
            entry.kind == .project && canRemove(entry)
                && (entry.isOrphan || (entry.lastUsed.map { $0 < cutoff } ?? true))
        }
    }

    // MARK: - Автоочистка

    static let autoCleanKey = "pilot.caches.autoCleanDays"

    /// Раз в день, в фоне: кэши проектов, которые давно не открывали.
    /// 0 — выключено.
    static func autoClean(known: [URL], open: [URL], copilotVersion: String?) {
        let days = UserDefaults.standard.integer(forKey: autoCleanKey)
        guard days > 0 else { return }
        let lastKey = "pilot.caches.lastAutoClean"
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        DispatchQueue.global(qos: .utility).async {
            let entries = scan(known: known, open: open, copilotVersion: copilotVersion)
            for entry in stale(entries, olderThan: days) { remove(entry) }
        }
    }
}
