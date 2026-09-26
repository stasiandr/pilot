import Foundation

// MARK: - Расширения проекта
//
// Соглашения конкретной кодовой базы — что у пары общего, где конфиги, как
// выглядит сетевая структура — Pilot берёт из `.pilot/extensions/*/extension.json`
// в репозитории самого проекта (см. ProjectRules). Расширение описывает, а не
// исполняет, но включается только с согласия: оно меняет, куда ведут ⌘B и
// ⌃⌘T и что подчёркивается в коде. Согласие помнится по папке расширения и
// отпечатку содержимого — поменялось расширение, Pilot спросит снова.
//
// Встроенные расширения (`Extensions/` в бандле, их приносит сборка — например,
// форк Pilot для своей команды) действуют без вопроса, но только в проектах,
// подходящих под их `match`. Выключить их можно в настройках.

extension Workspace {

    private static let trustedKey = "pilot.extensions.trusted"
    private static let declinedKey = "pilot.extensions.declined"

    private static var trusted: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: trustedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: trustedKey) }
    }

    private static var declined: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: declinedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: declinedKey) }
    }

    enum ExtensionState { case enabled, disabled, pending }

    func state(of item: ProjectExtension) -> ExtensionState {
        let key = item.directory.path
        if item.builtIn { return Self.declined[key] == item.fingerprint ? .disabled : .enabled }
        if Self.trusted[key] == item.fingerprint { return .enabled }
        if Self.declined[key] == item.fingerprint { return .disabled }
        return .pending
    }

    /// Папка встроенных расширений: `Extensions` в ресурсах бандла.
    /// `PILOT_EXTENSIONS` подменяет её — для запуска не из бандла.
    nonisolated static var builtInDirectory: URL? {
        if let path = ProcessInfo.processInfo.environment["PILOT_EXTENSIONS"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("Extensions", isDirectory: true)
    }

    /// Встроенные читаются один раз: бандл за время работы не меняется.
    nonisolated static let builtInExtensions: (found: [ProjectExtension], problems: [String]) =
        builtInDirectory.map(ProjectExtension.builtIns(in:)) ?? ([], [])

    /// Встроенные расширения, которые относятся к этому корню.
    nonisolated static func builtIns(for root: URL) -> [ProjectExtension] {
        let all = builtInExtensions.found
        guard !all.isEmpty else { return [] }
        // Адреса remote спрашиваем, только если кому-то они нужны.
        let needsRemotes = all.contains { !($0.manifest.match?.remotes.isEmpty ?? true) }
        let remotes = needsRemotes ? remoteURLs(of: root) : []
        return all.filter { $0.applies(remotes: remotes, root: root) }
    }

    nonisolated static func remoteURLs(of root: URL) -> [String] {
        guard let output = Git.run(["remote", "-v"], in: root), output.status == 0 else { return [] }
        return String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").compactMap { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first.map(String.init)
        }
    }

    /// Найденные, но ещё не включённые и не отклонённые — о них плашка.
    var pendingExtensions: [ProjectExtension] {
        projectExtensions.filter { state(of: $0) == .pending }
    }

    func setExtension(_ item: ProjectExtension, enabled: Bool) {
        let key = item.directory.path
        if enabled {
            Self.trusted[key] = item.fingerprint
            Self.declined[key] = nil
        } else {
            Self.declined[key] = item.fingerprint
            Self.trusted[key] = nil
        }
        objectWillChange.send()
        // Расширение второй половины действует и в её окне.
        ProjectWindows.shared.workspaces.forEach { $0.refreshExtensions() }
        if !ProjectWindows.shared.workspaces.contains(where: { $0 === self }) { refreshExtensions() }
    }

    /// Прочитать расширения проекта и второй половины и пересобрать правила.
    /// Свои правила нужны раньше пары: окончания имён из расширения помогают
    /// её узнать.
    func refreshExtensions() {
        guard let root, !ArchiveLayout.isArchiveFile(root) else {
            projectExtensions = []
            extensionProblems = []
            rules = .none
            partner = nil
            configCatalogs.warm(root: nil, rules: nil)
            return
        }
        let own = ProjectExtension.discover(in: root)
        var found = Self.builtIns(for: root) + own.found
        let ownRules = ProjectRules.merged(found.filter { state(of: $0) == .enabled }.map(\.manifest.rules))
        refreshPartner(extra: ownRules.pair.suffixes)

        var problems = Self.builtInExtensions.problems + own.problems
        if let partner {
            let theirs = ProjectExtension.discover(in: partner)
            for item in Self.builtIns(for: partner) where !found.contains(where: { $0.directory == item.directory }) {
                found.insert(item, at: 0)
            }
            found += theirs.found
            problems += theirs.problems.map { "\(partner.lastPathComponent)/\($0)" }
        }
        let enabled = found.filter { state(of: $0) == .enabled }.map(\.manifest.rules)
        let merged = ProjectRules.merged(enabled)

        if projectExtensions != found { projectExtensions = found }
        if extensionProblems != problems { extensionProblems = problems }
        if rules != merged {
            rules = merged
            mirror = nil
            if buffer != nil { schedulePairChecks(delay: 0) }
        }
        configCatalogs.warm(root: root, rules: rules.configs)
        for problem in problems { NSLog("[extensions] %@", problem) }
    }

    /// Файл сохранили — если это `extension.json`, правила перечитываются.
    func extensionFileChanged(_ url: URL) {
        guard url.lastPathComponent == ProjectExtension.manifestName,
              url.path.contains("/" + ProjectExtension.folder + "/") else { return }
        refreshExtensions()
    }
}
