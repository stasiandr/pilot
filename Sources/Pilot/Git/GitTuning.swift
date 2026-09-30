import Foundation

extension Git {

    /// Скорость на больших репозиториях. На clm-client (272 тыс. файлов,
    /// индекс 42 МБ) `git status` обходит все файлы и идёт 0,8–1,6 с, а
    /// с fsmonitor и кэшем неотслеживаемых — 0,07–0,14 с. Дело не в размере
    /// индекса, а в обходе: его и снимает fsmonitor.
    ///
    /// Настройки репозитория не трогаем: флаги идут в каждый наш запуск
    /// через `-c`. Постоянно включить их (и `splitIndex`, который меняет
    /// формат индекса) — только по кнопке, с согласия: `enable(in:)`.
    enum Tuning {
        /// Индекс больше этого — репозиторий большой. Маленьким флаги не
        /// нужны: fsmonitor — ещё один процесс на каждый репозиторий.
        static let largeIndexBytes = 8 * 1024 * 1024

        private static let lock = NSLock()
        private static var cache: [String: [String]] = [:]

        /// Флаги для команды в `directory` (корень репозитория или папка в нём).
        static func flags(for directory: URL) -> [String] {
            guard let root = Git.repositoryRoot(for: directory) else { return [] }
            lock.lock()
            if let cached = cache[root.path] { lock.unlock(); return cached }
            lock.unlock()
            let flags = isLarge(root) ? ["-c", "core.fsmonitor=true", "-c", "core.untrackedCache=true"] : []
            lock.lock()
            cache[root.path] = flags
            lock.unlock()
            return flags
        }

        static func isLarge(_ repository: URL) -> Bool {
            guard let size = indexSize(repository) else { return false }
            return size > largeIndexBytes
        }

        static func indexSize(_ repository: URL) -> Int? {
            let dotGit = repository.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            let directory: URL
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory), isDirectory.boolValue {
                directory = dotGit
            } else if let resolved = Git.gitDirectory(for: repository) {
                directory = resolved
            } else {
                return nil
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("index").path)
            return (attributes?[.size] as? NSNumber)?.intValue
        }

        /// Что из ускорения в репозитории уже включено постоянно.
        struct State: Equatable {
            var fsmonitor = false
            var untrackedCache = false
            var splitIndex = false
            var commitGraph = false

            var isComplete: Bool { fsmonitor && untrackedCache && splitIndex && commitGraph }
        }

        static func state(of repository: URL) -> State {
            func config(_ key: String) -> Bool {
                guard let output = Git.run(["config", "--bool", key], in: repository), output.status == 0 else { return false }
                return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            }
            var state = State(fsmonitor: config("core.fsmonitor"), untrackedCache: config("core.untrackedCache"),
                              splitIndex: config("core.splitIndex"))
            if let directory = Git.gitDirectory(for: repository) {
                let graph = directory.appendingPathComponent("objects/info/commit-graph").path
                let chain = directory.appendingPathComponent("objects/info/commit-graphs").path
                state.commitGraph = FileManager.default.fileExists(atPath: graph) || FileManager.default.fileExists(atPath: chain)
            }
            return state
        }

        /// Включить всё постоянно: fsmonitor и кэш неотслеживаемых — для
        /// status в терминале тоже; split index — запись индекса пишет
        /// маленький файл, а не все 42 МБ; commit-graph с Bloom-фильтрами —
        /// история файла (`git log -- путь`) в разы быстрее.
        /// Шаги по очереди; вернуть — первую ошибку.
        static func enable(in repository: URL) -> String? {
            let steps: [[String]] = [
                ["config", "core.fsmonitor", "true"],
                ["config", "core.untrackedCache", "true"],
                ["config", "core.splitIndex", "true"],
                ["update-index", "--split-index"],
                ["commit-graph", "write", "--reachable", "--changed-paths"],
            ]
            for step in steps {
                guard let result = Git.execute(step, in: repository) else { return L("Не удалось запустить git") }
                if !result.succeeded { return result.message }
            }
            return nil
        }
    }

    // MARK: - Журнал

    /// Что Pilot делал с репозиториями: команда, код, вывод. Показывается
    /// в окне git — «не прятать git» просили чаще всего, а вывод хуков
    /// коммита иначе негде увидеть.
    final class Journal: @unchecked Sendable {
        struct Entry: Identifiable, Equatable, Sendable {
            var id: Int
            var date: Date
            var repository: String
            var command: String
            var status: Int32
            var output: String
            var duration: TimeInterval

            var succeeded: Bool { status == 0 }
        }

        static let shared = Journal()
        static let limit = 300

        private let lock = NSLock()
        private var entries: [Entry] = []
        private var counter = 0
        /// После каждой записи; приходит с любой очереди.
        static let changed = Notification.Name("PilotGitJournalChanged")

        func record(arguments: [String], directory: URL, result: Git.Result, duration: TimeInterval) {
            lock.lock()
            counter += 1
            let output = [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            entries.append(Entry(id: counter, date: Date(), repository: directory.path,
                                 command: "git " + arguments.map(Self.quoted).joined(separator: " "),
                                 status: result.status, output: String(output.prefix(20_000)), duration: duration))
            if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
            lock.unlock()
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }

        func snapshot(repository: String? = nil) -> [Entry] {
            lock.lock(); defer { lock.unlock() }
            guard let repository else { return entries }
            return entries.filter { $0.repository.hasPrefix(repository) }
        }

        /// Аргумент как его набрали бы в терминале.
        static func quoted(_ argument: String) -> String {
            let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@^~{}+,%"))
            if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ plain.contains($0) }) { return argument }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
}
