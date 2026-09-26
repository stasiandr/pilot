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

/// Окно NuGet: пакеты проектов решения, поиск по лентам из NuGet.Config,
/// установка, обновление и удаление через `dotnet`, сами ленты — с логином
/// и токеном. У каждого проекта Pilot свой.
@MainActor
final class NuGetService: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case installed, updates, browse, sources
        var id: String { rawValue }
        var title: String {
            switch self {
            case .installed: return L("Установленные")
            case .updates: return L("Обновления")
            case .browse: return L("Поиск")
            case .sources: return L("Источники")
            }
        }
    }

    /// Ответила ли лента с сохранённым логином и паролем.
    enum SourceStatus: Equatable {
        case checking
        case ok
        case unauthorized
        case failed(String)
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
    /// Ленты, которые при поиске не ответили, — когда остальные ответили.
    @Published private(set) var searchFailures: [String] = []

    let client = NuGetClient()
    /// Ленты из NuGet.Config — те, что видит `dotnet restore` в корне проекта.
    @Published private(set) var sources: [NuGetSource] = []
    @Published private(set) var sourceStatus: [String: SourceStatus] = [:]
    /// Выбранное на вкладке «Источники»: id ленты, `suggested:<адрес>` или `new`.
    @Published var selectedSource: String?
    /// Ленты, которые проекту нужны по его расширениям (ProjectRules).
    @Published var suggestedSources: [SuggestedNuGetSource] = []

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
        sources = []
        sourceStatus = [:]
        selectedSource = nil
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
            let sources = NuGetConfig.sources(for: root)
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.projects = found
                self.isScanning = false
                Task {
                    await self.apply(sources)
                    self.checkUpdates()
                }
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

    // MARK: - Ленты

    /// Версии всех установленных пакетов — для вкладки обновлений.
    func checkUpdates() {
        let ids = Set(installed.map { $0.id.lowercased() }).subtracting(versions.keys)
        guard !ids.isEmpty else { return }
        isCheckingUpdates = true
        Task {
            let client = self.client
            await withTaskGroup(of: (String, [NuGetVersion]?).self) { group in
                for id in ids {
                    group.addTask { (id, await client.versions(id)) }
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
                if let found = await client.package(id) {
                    details[key] = found
                }
            }
        }
        if versions[key] == nil {
            Task {
                if let found = await client.versions(id) {
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
            let (found, failures) = await client.search(query, prerelease: prerelease)
            guard !Task.isCancelled else { return }
            results = found
            for package in found { details[package.id.lowercased()] = details[package.id.lowercased()] ?? package }
            if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
                selectedID = found.first?.id
            }
            // Не ответила ни одна — ошибкой на весь список, иначе строкой над ним.
            searchError = found.isEmpty && !failures.isEmpty ? failures.joined(separator: "\n") : nil
            searchFailures = found.isEmpty ? [] : failures
            isSearching = false
        }
    }

    // MARK: - Источники

    /// Ленты поменялись — версии и описания спрашиваем заново: пакет мог
    /// найтись в новой ленте.
    private func apply(_ found: [NuGetSource]) async {
        guard found != sources else { return }
        let previous = sources
        sources = found
        await client.setSources(found)
        if !previous.isEmpty {
            versions = [:]
            details = [:]
            results = []
        }
        // Проверка в силе, только пока лента та же — с тем же логином.
        sourceStatus = sourceStatus.filter { key, _ in
            found.first { $0.id == key } == previous.first { $0.id == key }
        }
        // Свои ленты проверяем сразу: не пускающая без логина — повод для
        // плашки. nuget.org отвечает всем.
        for source in found where source.isEnabled && source.isRemote && !source.isNuGetOrg
            && sourceStatus[source.id] == nil {
            check(source)
        }
    }

    /// Перечитать NuGet.Config: после своей правки или по кнопке.
    func reloadSources() {
        let root = self.root
        Task {
            let found = await Task.detached { NuGetConfig.sources(for: root) }.value
            await apply(found)
            checkUpdates()
            if tab == .browse { search() }
        }
    }

    /// Нужные проекту ленты, которых нет среди подключённых.
    var missingSources: [SuggestedNuGetSource] {
        suggestedSources.filter { suggested in
            !sources.contains { Self.sameURL($0.url, suggested.url) }
        }
    }

    /// Подключённая лента, которой не хватает логина: проект её ждёт, а
    /// она отвечает 401.
    var sourcesNeedingLogin: [NuGetSource] {
        sources.filter { $0.isEnabled && sourceStatus[$0.id] == .unauthorized }
    }

    static func sameURL(_ a: String, _ b: String) -> Bool {
        func normalized(_ s: String) -> String {
            var s = s.trimmingCharacters(in: .whitespaces).lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return normalized(a) == normalized(b)
    }

    /// Отвечает ли лента: с логином и паролем, какие есть.
    func check(_ source: NuGetSource) {
        guard source.isRemote else { return }
        sourceStatus[source.id] = .checking
        Task {
            let feed = NuGetFeed(source: source)
            let status: SourceStatus
            do {
                try await feed.check()
                status = .ok
            } catch NuGetFeed.Failure.unauthorized {
                status = .unauthorized
            } catch {
                status = .failed(error.localizedDescription)
            }
            // Пока проверяли, ленту могли поменять.
            if sources.first(where: { $0.id == source.id }) == source { sourceStatus[source.id] = status }
        }
    }

    func checkAllSources() {
        for source in sources where source.isEnabled && source.isRemote { check(source) }
    }

    /// Лента объявлена в пользовательском NuGet.Config — её можно убрать и
    /// переименовать. Объявленной в репозитории Pilot меняет только пароль.
    func isUserSource(_ source: NuGetSource) -> Bool {
        source.configFile?.standardizedFileURL.path == NuGetConfig.userFile.standardizedFileURL.path
    }

    enum SourceError: LocalizedError {
        case emptyName, badURL, duplicate(String)
        var errorDescription: String? {
            switch self {
            case .emptyName: return L("Нужно имя")
            case .badURL: return L("Адрес — https://…/index.json или папка на диске")
            case .duplicate(let name): return L("Лента «\(name)» уже есть")
            }
        }
    }

    /// Добавить ленту или сохранить изменения. `original` — какую правим.
    /// Логин и пароль пишутся в пользовательский NuGet.Config открытым
    /// текстом: по-другому `dotnet` на macOS их не прочтёт.
    func saveSource(original: NuGetSource?, name: String, url: String, username: String, password: String) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        let url = url.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw SourceError.emptyName }
        let lower = url.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") || url.hasPrefix("/") || url.hasPrefix("~") else {
            throw SourceError.badURL
        }
        if sources.contains(where: { $0.id == name.lowercased() && $0.id != original?.id }) {
            throw SourceError.duplicate(name)
        }
        let file = NuGetConfig.userFile
        var data = try? Data(contentsOf: file)
        let credentials = (username: username.trimmingCharacters(in: .whitespaces), password: password)
        if let original, !isUserSource(original) {
            // Лента из репозитория: адрес и имя — его, наш только пароль.
            data = try NuGetConfig.upserting(name: original.name, url: nil, credentials: credentials, in: data)
        } else {
            if let original, original.id != name.lowercased(), let current = data {
                data = try NuGetConfig.removing(name: original.name, from: current)
            }
            data = try NuGetConfig.upserting(name: name, url: url, credentials: credentials, in: data)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data!.write(to: file, options: .atomic)
        selectedSource = (original.map { isUserSource($0) } ?? true) ? name.lowercased() : original?.id
        reloadSources()
    }

    func removeSource(_ source: NuGetSource) throws {
        guard isUserSource(source), let data = try? Data(contentsOf: NuGetConfig.userFile) else { return }
        try NuGetConfig.removing(name: source.name, from: data).write(to: NuGetConfig.userFile, options: .atomic)
        selectedSource = nil
        reloadSources()
    }

    func setEnabled(_ enabled: Bool, source: NuGetSource) throws {
        let file = NuGetConfig.userFile
        let data = try NuGetConfig.settingEnabled(enabled, name: source.name, in: try? Data(contentsOf: file))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        reloadSources()
    }

    /// Лента в GitLab, а для этого GitLab у Pilot уже есть токен (ревью
    /// мерж-реквестов): логин и токен для формы. Имя пользователя — у
    /// самого GitLab.
    func gitLabCredentials(for url: String) async -> (username: String, token: String)? {
        guard let host = URL(string: url)?.host, url.contains("/api/v4/"),
              let token = TokenStore.token(for: host) else { return nil }
        guard let user = try? await GitLabClient(host: host, token: token).currentUser() else { return nil }
        return (user.username, token)
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
