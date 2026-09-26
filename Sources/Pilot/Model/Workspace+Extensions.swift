import Foundation

// MARK: - Расширения проекта
//
// Соглашения конкретной кодовой базы — что у пары общего, где конфиги, как
// выглядит сетевая структура — Pilot берёт из `.pilot/extensions/*/extension.json`
// в репозитории самого проекта (см. ProjectRules). Расширение описывает, а не
// исполняет, но включается только с согласия: оно меняет, куда ведут ⌘B и
// ⌃⌘T и что подчёркивается в коде. Согласие помнится по папке расширения и
// отпечатку содержимого — поменялось расширение, Pilot спросит снова.

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
        if Self.trusted[key] == item.fingerprint { return .enabled }
        if Self.declined[key] == item.fingerprint { return .disabled }
        return .pending
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
        let ownRules = ProjectRules.merged(own.found.filter { state(of: $0) == .enabled }.map(\.manifest.rules))
        refreshPartner(extra: ownRules.pair.suffixes)

        var found = own.found
        var problems = own.problems
        if let partner {
            let theirs = ProjectExtension.discover(in: partner)
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
