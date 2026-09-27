import Foundation

/// Восстановлены ли пакеты проектов на этой машине. Без сети и без
/// `dotnet restore` — по тому, что restore оставляет в `obj/project.assets.json`.
/// Этот же файл читает Rustlyn, узнавая сборки пакетов (`assets_references`
/// в rustlyn-ide): нет файла, нет в нём пакета или нет на диске папки пакета —
/// компиляция пакета не увидит, и имена из него в редакторе не найдутся.
///
/// Проекты внутри Unity-проекта не проверяются: пакеты Unity — забота его
/// самого, а генераторы и анализаторы в SDK-стиле рядом со скриптами
/// собирают отдельно и часто не восстанавливают вовсе.
///
/// Без AppKit — проверяется тестами ядра.
enum NuGetRestore {
    /// Где restore оставляет пакеты проекта. Там же их ищет Rustlyn.
    static let assetsFile = "obj/project.assets.json"

    /// Что поменялось на диске настолько, что проверку стоит повторить.
    static func isRelevant(_ path: String) -> Bool {
        NuGetProjects.isRelevant(path) || isAssets(path)
    }

    /// restore записал пакеты проекта заново.
    static func isAssets(_ path: String) -> Bool {
        path.hasSuffix("/" + assetsFile)
    }

    /// Проекты из `NuGetProjects.discover` — что с их пакетами.
    static func check(root: URL, projects: [NuGetProject]) -> NuGetRestoreReport {
        var report = NuGetRestoreReport(projectCount: projects.count)
        for project in projects where !isInUnityProject(project.path, root: root) {
            let directory = (project.path as NSString).deletingLastPathComponent
            let folder = directory.isEmpty ? root : root.appendingPathComponent(directory)
            let file = folder.appendingPathComponent(assetsFile)
            if let data = try? Data(contentsOf: file) {
                // restore здесь был, даже если файл пишут прямо сейчас. Тогда
                // проверим, когда допишут: придёт событие.
                report.restoredSomewhere = true
                guard let assets = NuGetAssets(data) else { continue }
                let edited = isNewer(root.appendingPathComponent(project.path), than: file)
                report.problems += problems(project: project.path, references: project.references, assets: assets,
                                            editedSinceRestore: edited)
            } else {
                let ids = explicitIDs(project.references)
                guard !ids.isEmpty, !movesIntermediate(project.path, root: root) else { continue }
                report.problems.append(.init(project: project.path, reason: .notRestored, packages: ids))
            }
        }
        report.problems.sort { a, b in
            a.reason != b.reason ? a.reason < b.reason : a.project.localizedStandardCompare(b.project) == .orderedAscending
        }
        return report
    }

    /// Проект, у которого restore уже был. `editedSinceRestore` — .csproj
    /// новее файла restore: иначе restore видел ровно этот текст, и ссылки,
    /// которых нет в файле, убрал сам SDK или Directory.Build.targets.
    static func problems(project: String, references: [NuGetReference], assets: NuGetAssets,
                         editedSinceRestore: Bool = true,
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [NuGetRestoreReport.Problem] {
        var out: [NuGetRestoreReport.Problem] = []
        // Проект просил, а restore не нашёл: пакета нет в лентах, лента не
        // ответила или не пустила без логина.
        let failed = assets.requested.filter { !assets.found.contains($0.key) }.map(\.value)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if !failed.isEmpty {
            let ids = Set(failed.map { $0.lowercased() })
            // Сперва — о самих пакетах, потом общее: лента не ответила.
            let own = assets.failures.filter { $0.library.map { ids.contains($0.lowercased()) } ?? false }
            let general = assets.failures.filter { $0.library == nil }
            let messages = unique((own + general).map(\.message))
            out.append(.init(project: project, reason: .failed, packages: failed, messages: Array(messages.prefix(3))))
        }
        // В проекте есть, а restore о нём не знал: ссылку добавили после restore.
        if assets.describesProject, editedSinceRestore {
            let outdated = explicitIDs(references).filter { assets.requested[$0.lowercased()] == nil }
            if !outdated.isEmpty { out.append(.init(project: project, reason: .outdated, packages: outdated)) }
        }
        // restore нашёл, а папки пакета на диске нет: кэш NuGet почистили или
        // файл достался с другой машины.
        if !assets.folders.isEmpty {
            let missing = assets.packages.filter { package in
                !assets.folders.contains { exists(($0 as NSString).appendingPathComponent(package.path)) }
            }
            if !missing.isEmpty {
                out.append(.init(project: project, reason: .missing, packages: unique(missing.map(\.id))))
            }
        }
        return out
    }

    /// Ссылки на них SDK превращает в ссылки на фреймворк или убирает из
    /// restore сам (NETSDK1080 и родня): в файле restore их нет и не будет.
    static let frameworkPackages: Set<String> = [
        "microsoft.netcore.app", "microsoft.aspnetcore.app", "microsoft.aspnetcore.all",
        "microsoft.windowsdesktop.app", "netstandard.library",
    ]

    /// Файл поменяли позже другого. Не узнать — считаем, что да.
    static func isNewer(_ file: URL, than other: URL) -> Bool {
        let key = URLResourceKey.contentModificationDateKey
        guard let a = try? file.resourceValues(forKeys: [key]).contentModificationDate,
              let b = try? other.resourceValues(forKeys: [key]).contentModificationDate else { return true }
        return a > b
    }

    /// Пакеты, которые проект просит всегда и прямо по имени: без условий
    /// и свойств MSBuild (`$(Name)`), без тех, что SDK забирает себе.
    /// `A;B` — два пакета.
    static func explicitIDs(_ references: [NuGetReference]) -> [String] {
        var ids: [String] = []
        for reference in references where !reference.isConditional {
            for part in reference.id.split(separator: ";") {
                let id = part.trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty, !["$(", "@(", "%("].contains(where: { id.contains($0) }),
                      !frameworkPackages.contains(id.lowercased()) else { continue }
                ids.append(id)
            }
        }
        return unique(ids)
    }

    /// Проект лежит в Unity-проекте: в его папке или выше, до корня, есть
    /// `Assets/` и `ProjectSettings/ProjectVersion.txt`.
    static func isInUnityProject(_ path: String, root: URL) -> Bool {
        var components = path.split(separator: "/").dropLast().map(String.init)
        while true {
            let directory = components.isEmpty ? root : root.appendingPathComponent(components.joined(separator: "/"))
            if UnityProjectInfo.detect(root: directory) != nil { return true }
            guard !components.isEmpty else { return false }
            components.removeLast()
        }
    }

    /// `obj/` проекта переназначен — в нём самом или в Directory.Build.props
    /// выше. Где restore оставил свой файл, по тексту не узнать, и «restore
    /// не запускался» было бы неправдой.
    static func movesIntermediate(_ path: String, root: URL) -> Bool {
        let properties = ["BaseIntermediateOutputPath", "MSBuildProjectExtensionsPath", "RestoreOutputPath",
                          "UseArtifactsOutput", "ArtifactsPath"]
        func moves(_ relative: String) -> Bool {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) else {
                return false
            }
            return properties.contains { text.range(of: "<" + $0, options: .caseInsensitive) != nil }
        }
        if moves(path) { return true }
        var components = path.split(separator: "/").dropLast().map(String.init)
        while true {
            if moves((components + ["Directory.Build.props"]).joined(separator: "/")) { return true }
            guard !components.isEmpty else { return false }
            components.removeLast()
        }
    }

    /// По порядку и без повторов; id NuGet регистр не различают.
    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Что из `project.assets.json` нужно проверке: какие пакеты проект просил,
/// какие restore нашёл, где лежат их папки и на что restore жаловался.
struct NuGetAssets {
    struct Package: Equatable {
        var id: String
        /// От папки пакетов: `newtonsoft.json/13.0.3`.
        var path: String
    }

    struct Failure: Equatable {
        /// О каком пакете; nil — о restore вообще: лента не ответила.
        var library: String?
        /// `NU1101: Unable to find package …` — одной строкой.
        var message: String
    }

    /// Пакеты, которые проект просил при restore: id в нижнем регистре → как записан.
    var requested: [String: String] = [:]
    /// Описание проекта в файле есть — `requested` полный.
    var describesProject = false
    /// Что restore нашёл — пакеты и проекты, id в нижнем регистре.
    var found: Set<String> = []
    var packages: [Package] = []
    /// Папки пакетов: `~/.nuget/packages/` и запасные.
    var folders: [String] = []
    /// Ошибки restore; предупреждения не в счёт.
    var failures: [Failure] = []

    /// nil — не JSON: файл дописывают или он сломан.
    init?(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let frameworks = (json["project"] as? [String: Any])?["frameworks"] as? [String: Any] {
            describesProject = true
            for case let framework as [String: Any] in frameworks.values {
                for (id, spec) in framework["dependencies"] as? [String: Any] ?? [:] {
                    if let target = (spec as? [String: Any])?["target"] as? String,
                       target.caseInsensitiveCompare("Package") != .orderedSame { continue }
                    requested[id.lowercased()] = requested[id.lowercased()] ?? id
                }
            }
        }
        for (key, value) in json["libraries"] as? [String: Any] ?? [:] {
            // `Newtonsoft.Json/13.0.3`.
            let id = String(key.prefix { $0 != "/" })
            found.insert(id.lowercased())
            if let library = value as? [String: Any],
               (library["type"] as? String)?.caseInsensitiveCompare("package") == .orderedSame,
               let path = library["path"] as? String {
                packages.append(Package(id: id, path: path))
            }
        }
        // Словарь JSON — в случайном порядке, а отчёт сравнивается с прошлым.
        packages.sort { $0.id.lowercased() < $1.id.lowercased() }
        folders = ((json["packageFolders"] as? [String: Any]).map { Array($0.keys) } ?? []).sorted()
        for case let log as [String: Any] in json["logs"] as? [Any] ?? [] {
            guard (log["level"] as? String)?.caseInsensitiveCompare("Error") == .orderedSame else { continue }
            let text = (log["message"] as? String ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let message = [log["code"] as? String ?? "", text].filter { !$0.isEmpty }.joined(separator: ": ")
            failures.append(Failure(library: log["libraryId"] as? String, message: message))
        }
    }
}

/// Что с пакетами проектов на этой машине.
struct NuGetRestoreReport: Equatable {
    /// Почему компиляция пакетов не видит — по важности.
    enum Reason: Int, CaseIterable, Comparable {
        /// restore их не нашёл: нет в лентах, лента не ответила или не пустила.
        case failed
        /// restore их нашёл, но папок пакетов на диске больше нет.
        case missing
        /// Ссылки на них добавлены после последнего restore.
        case outdated
        /// restore у проекта здесь не запускался.
        case notRestored

        static func < (a: Reason, b: Reason) -> Bool { a.rawValue < b.rawValue }
    }

    struct Problem: Equatable {
        /// От корня: `Server/Server.csproj`.
        var project: String
        var reason: Reason
        var packages: [String]
        /// Что сказал сам restore: `NU1301: Unable to load the service index…`.
        var messages: [String] = []
    }

    /// Проектов .NET в SDK-стиле — окну NuGet есть что показать.
    var projectCount = 0
    var problems: [Problem] = []
    /// restore был хоть у одного проверенного проекта: здесь его уже собирали.
    var restoredSomewhere = false

    var hasProjects: Bool { projectCount > 0 }

    /// Стоит показать точкой в тулбаре и открыть окно NuGet: restore не нашёл
    /// пакеты, их папки пропали, ссылки новее restore — или restore не было ни
    /// у одного проекта. Невосстановленные тесты и утилиты рядом с собранным
    /// проектом — не повод: их здесь, видно, не собирают.
    var needsAttention: Bool {
        problems.contains { $0.reason != .notRestored } || (!restoredSomewhere && !problems.isEmpty)
    }

    /// Пакеты по порядку причин, без повторов.
    var packages: [String] { NuGetRestore.unique(problems.flatMap(\.packages)) }
    /// Проекты, которым нужен restore, — сперва те, где он не удался.
    var projects: [String] { NuGetRestore.unique(problems.map(\.project)) }

    // MARK: - Словами

    /// «Не восстановлены пакеты: Serilog, Dapper, Polly и ещё 3».
    var headline: String { L("Не восстановлены пакеты: \(Self.list(packages))") }

    /// По строке на причину: в каких проектах и почему.
    var reasons: [String] {
        Reason.allCases.compactMap { reason in
            let names = NuGetRestore.unique(problems.filter { $0.reason == reason }.map { Self.name($0.project) })
            guard !names.isEmpty else { return nil }
            let list = Self.list(names)
            switch reason {
            case .failed: return L("\(list): restore не смог их найти")
            case .missing: return L("\(list): их папок нет в кэше NuGet")
            case .outdated: return L("\(list): добавлены после последнего restore")
            case .notRestored: return L("\(list): restore здесь ещё не запускался")
            }
        }
    }

    /// Что сказал сам restore — первое и без повторов.
    var messages: [String] { Array(NuGetRestore.unique(problems.flatMap(\.messages)).prefix(2)) }

    /// Проект за проектом, со всеми пакетами — для подсказки.
    var details: String {
        projects.map { project in
            let ids = NuGetRestore.unique(problems.filter { $0.project == project }.flatMap(\.packages))
            return Self.name(project) + ": " + ids.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    /// `Server/Server.csproj` → `Server`.
    static func name(_ project: String) -> String {
        ((project as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Первые три, остальные — числом.
    static func list(_ items: [String], limit: Int = 3) -> String {
        guard items.count > limit + 1 else { return items.joined(separator: ", ") }
        return items.prefix(limit).joined(separator: ", ") + " " + L("и ещё \(items.count - limit)")
    }
}
