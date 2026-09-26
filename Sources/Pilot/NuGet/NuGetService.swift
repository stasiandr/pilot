import SwiftUI

/// Пакет, установленный хотя бы в один проект.
struct InstalledPackage: Identifiable, Hashable {
    var id: String
    /// Проект → версия как записана (или nil, если её не разобрать).
    var versions: [String: String?]

    /// Самая старшая из установленных — с ней сравнивается обновление.
    var newestInstalled: NuGetVersion? {
        versions.values.compactMap { $0.flatMap(NuGetVersion.init) }.max()
    }

    /// Разные версии в разных проектах — стоит свести к одной.
    var isInconsistent: Bool { Set(versions.values.compactMap { $0 }).count > 1 }
}

/// Окно NuGet: пакеты проектов решения, поиск на nuget.org, установка,
/// обновление и удаление через `dotnet`. У каждого проекта Pilot свой.
@MainActor
final class NuGetService: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case installed, updates, browse
        var id: String { rawValue }
        var title: String {
            switch self {
            case .installed: return L("Установленные")
            case .updates: return L("Обновления")
            case .browse: return L("Поиск")
            }
        }
    }

    enum OperationState: Equatable {
        case idle
        case running(String)
        case finished(succeeded: Bool, message: String)
    }

    @Published private(set) var root: URL?
    @Published private(set) var projects: [NuGetProject] = []
    @Published private(set) var isScanning = false
    /// Проекты уже читали: окно открывали. До того изменения на диске
    /// ничего не перечитывают.
    private(set) var isLoaded = false

    @Published var tab: Tab = .installed
    @Published var filter = ""
    @Published var includePrerelease = UserDefaults.standard.bool(forKey: NuGetService.prereleaseKey) {
        didSet {
            UserDefaults.standard.set(includePrerelease, forKey: Self.prereleaseKey)
            if tab == .browse { search() }
        }
    }
    @Published var selectedID: String?

    @Published private(set) var results: [NuGetPackage] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?

    /// Сведения с nuget.org о пакетах — по id в нижнем регистре.
    @Published private(set) var details: [String: NuGetPackage] = [:]
    /// Все версии пакета — по id в нижнем регистре.
    @Published private(set) var versions: [String: [NuGetVersion]] = [:]
    @Published private(set) var isCheckingUpdates = false

    @Published private(set) var operation: OperationState = .idle
    let log = RunLog()
    @Published var showsLog = false

    private var process: RunProcess?
    private var searchTask: Task<Void, Never>?
    private var scanGeneration = 0

    private static let prereleaseKey = "pilot.nuget.prerelease"

    var isBusy: Bool {
        if case .running = operation { return true }
        return false
    }

    // MARK: - Проект

    func workspaceChanged(to root: URL?) {
        self.root = root
        projects = []
        results = []
        selectedID = nil
        isLoaded = false
        scanGeneration += 1
    }

    /// Окно открылось: читаем проекты, если ещё не читали.
    func activate() {
        guard !isLoaded else { return }
        refresh()
    }

    /// Перечитать .csproj: открыли окно, поменялось на диске, отработал dotnet.
    func refresh() {
        guard let root else { return }
        isLoaded = true
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let found = NuGetProjects.discover(root: root)
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.projects = found
                self.isScanning = false
                self.checkUpdates()
            }
        }
    }

    /// Пакеты всех проектов, по имени.
    var installed: [InstalledPackage] {
        var byID: [String: InstalledPackage] = [:]
        for project in projects {
            for reference in project.references {
                let key = reference.id.lowercased()
                var entry = byID[key] ?? InstalledPackage(id: reference.id, versions: [:])
                entry.versions[project.path] = .some(reference.version)
                byID[key] = entry
            }
        }
        return byID.values.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    func installed(_ id: String) -> InstalledPackage? {
        installed.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Новее установленного на nuget.org — если версии уже узнали.
    func update(for package: InstalledPackage) -> NuGetVersion? {
        guard let current = package.newestInstalled, let all = versions[package.id.lowercased()] else { return nil }
        // С галкой «предварительные» — и они в обновлениях, как в Rider.
        if includePrerelease, let newest = all.max(), newest > current { return newest }
        return NuGetVersion.update(for: current, among: all)
    }

    var updates: [InstalledPackage] { installed.filter { update(for: $0) != nil } }

    /// Списки вкладок «Установленные» и «Обновления» — с фильтром по имени.
    func list(for tab: Tab) -> [InstalledPackage] {
        let source = tab == .updates ? updates : installed
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return source }
        return source.filter { $0.id.localizedCaseInsensitiveContains(needle) }
    }

    // MARK: - nuget.org

    /// Версии всех установленных пакетов — для вкладки обновлений.
    func checkUpdates() {
        let ids = Set(installed.map { $0.id.lowercased() }).subtracting(versions.keys)
        guard !ids.isEmpty else { return }
        isCheckingUpdates = true
        Task {
            await withTaskGroup(of: (String, [NuGetVersion]?).self) { group in
                for id in ids {
                    group.addTask { (id, try? await NuGetClient.shared.versions(id)) }
                }
                for await (id, found) in group {
                    if let found { versions[id] = found }
                }
            }
            isCheckingUpdates = false
        }
    }

    /// Описание и версии выбранного пакета, если их ещё нет.
    func loadDetails(_ id: String) {
        let key = id.lowercased()
        if details[key] == nil {
            Task {
                if let found = try? await NuGetClient.shared.package(id) {
                    details[key] = found
                }
            }
        }
        if versions[key] == nil {
            Task {
                if let found = try? await NuGetClient.shared.versions(id) {
                    versions[key] = found
                }
            }
        }
    }

    /// Поиск с задержкой: не на каждую букву.
    func search(debounced: Bool = false) {
        searchTask?.cancel()
        let query = filter.trimmingCharacters(in: .whitespaces)
        let prerelease = includePrerelease
        isSearching = true
        searchError = nil
        searchTask = Task {
            if debounced { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            do {
                let found = try await NuGetClient.shared.search(query, prerelease: prerelease)
                guard !Task.isCancelled else { return }
                results = found
                for package in found { details[package.id.lowercased()] = details[package.id.lowercased()] ?? package }
                if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
                    selectedID = found.first?.id
                }
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    // MARK: - dotnet

    /// Поставить или сменить версию в проектах.
    func install(_ id: String, version: String?, projects paths: [String]) {
        guard !paths.isEmpty else { return }
        let commands = paths.map { NuGetProjects.addCommand(project: $0, id: id, version: version) }
        let title = version.map { L("Установка \(id) \($0)") } ?? L("Установка \(id)")
        execute(commands, title: title)
    }

    func remove(_ id: String, projects paths: [String]) {
        guard !paths.isEmpty else { return }
        execute(paths.map { NuGetProjects.removeCommand(project: $0, id: id) }, title: L("Удаление \(id)"))
    }

    /// Все пакеты вкладки «Обновления» — до предложенных версий.
    func updateAll() {
        var commands: [String] = []
        for package in updates {
            guard let target = update(for: package) else { continue }
            for (project, version) in package.versions.sorted(by: { $0.key < $1.key })
            where version.flatMap(NuGetVersion.init) != target {
                commands.append(NuGetProjects.addCommand(project: project, id: package.id, version: target.text))
            }
        }
        execute(commands, title: L("Обновление пакетов"))
    }

    func cancel() {
        process?.stop()
    }

    /// Команды по очереди, первая неудача останавливает остальные.
    private func execute(_ commands: [String], title: String) {
        guard let root, !isBusy, !commands.isEmpty else { return }
        log.clear()
        log.append(commands.map { "▶ " + $0 }.joined(separator: "\n") + "\n\n")
        operation = .running(title)
        let script = commands.map { "echo; echo \"▶ \" " + RunTargets.shellQuoted($0) + " && " + $0 }
            .joined(separator: " && ")
        do {
            process = try RunProcess.start(
                command: script, directory: root, environment: ["DOTNET_CLI_TELEMETRY_OPTOUT": "1"],
                onOutput: { [weak self] data in
                    let text = String(decoding: data, as: UTF8.self)
                    Task { @MainActor in self?.log.append(text) }
                },
                onExit: { [weak self] code in
                    Task { @MainActor in self?.finished(code, title: title) }
                })
        } catch {
            operation = .finished(succeeded: false, message: error.localizedDescription)
            log.append(error.localizedDescription + "\n")
        }
    }

    private func finished(_ code: Int32, title: String) {
        process = nil
        let message: String
        switch code {
        case 0: message = L("\(title): готово")
        // Так shell отвечает на команду, которой нет.
        case 127: message = L("Не найден dotnet — установите .NET SDK")
        case 130, 143: message = L("\(title): отменено")
        default: message = L("\(title): ошибка, код \(Int(code))")
        }
        operation = .finished(succeeded: code == 0, message: message)
        if code != 0 { showsLog = true }
        log.append("\n■ " + message + "\n")
        refresh()
    }
}
