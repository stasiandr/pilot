import SwiftUI

/// История: лог с графом, фильтры, выбранный коммит с файлами и диффом,
/// история файла и фрагмента, сравнение двух веток.
///
/// Лог грузится страницами по мере прокрутки: на clm-client 110 тыс.
/// коммитов и 7,5 тыс. ссылок, и первая страница `--topo-order` с
/// commit-graph приходит за 0,15 с — остальное не нужно, пока до него не
/// долистали. Поэтому по умолчанию — текущая ветка, а не `--all`.
@MainActor
final class GitHistoryModel: ObservableObject {
    enum Scope: Hashable {
        case current, all, ref(String)

        var title: String {
            switch self {
            case .current: return L("Текущая ветка")
            case .all: return L("Все ветки")
            case .ref(let ref): return ref
            }
        }
    }

    struct Filter: Equatable {
        var scope: Scope = .current
        var text = ""
        var author = ""
        /// История файла или папки (от корня репозитория).
        var path: String?
        /// История фрагмента: строки с 1, включительно.
        var lines: ClosedRange<Int>?

        var isFiltered: Bool { !text.isEmpty || !author.isEmpty || path != nil }
    }

    /// Сравнение: что есть в `target` и чего нет в `base` (`base...target`).
    struct Comparison: Equatable {
        var base: String
        var target: String
    }

    /// Как смотреть историю. Полный граф в репозитории, где история
    /// строится через MR, почти нечитаем: на clm-client за месяц 976
    /// коммитов, половина — слияния, 188 из них — обратные (master в
    /// ветку). По первому родителю тот же месяц — 150 строк, 145 из них — MR.
    enum Mode: String, CaseIterable, Hashable {
        /// Моя ветка относительно основной, как smartlog в Sapling и `jj log`.
        case mine
        /// Основная ветка по первому родителю: влитые MR, раскрываются в коммиты.
        case mainline
        /// Все коммиты с графом.
        case graph

        var title: String {
            switch self {
            case .mine: return L("Моя ветка")
            case .mainline: return L("По MR")
            case .graph: return L("Граф")
            }
        }
    }

    @Published var mode: Mode = .mine {
        didSet { if mode != oldValue { reload() } }
    }

    @Published var filter = Filter() {
        didSet { if filter != oldValue { reload() } }
    }

    // MARK: Моя ветка

    struct BranchOverview: Equatable {
        /// nil — HEAD отсоединён.
        var branch: String?
        /// `origin/master`.
        var mainRef: String
        /// Сама основная ветка: тогда «мои» — неотправленные.
        var onMain: Bool
        /// Коммиты ветки сверх основной, по первому родителю, новые сверху.
        var commits: [GitCommitInfo]
        /// Каких из них нет ни в одной ветке на сервере.
        var unpushed: Set<String>
        /// Где ветка отошла от основной.
        var forkPoint: GitCommitInfo?
        /// Насколько основная ушла вперёд с тех пор.
        var behind: Int
        var others: [OtherBranch]

        var mainName: String { mainRef.split(separator: "/").dropFirst().joined(separator: "/").nilIfEmpty ?? mainRef }
    }

    struct OtherBranch: Equatable, Identifiable {
        var name: String
        var ahead: Int
        var behind: Int
        var date: Date
        var subject: String
        var id: String { name }
    }

    @Published private(set) var overview: BranchOverview?

    // MARK: По MR

    struct MainlineEntry: Identifiable, Equatable {
        var commit: GitCommitInfo
        var request: MergeRequestInfo?
        var id: String { commit.hash }
    }

    @Published private(set) var mainline: [MainlineEntry] = []
    /// Раскрытые MR — их коммиты подгружаются по требованию.
    @Published var expanded: Set<String> = [] {
        didSet { for hash in expanded.subtracting(oldValue) { loadChildren(of: hash) } }
    }
    /// Коммиты MR без обратных слияний; и сколько обратных спрятано.
    @Published private(set) var children: [String: [GitCommitInfo]] = [:]
    @Published private(set) var hiddenBackMerges: [String: Int] = [:]
    /// Все коммиты, что сейчас на экране, — по ним ищется выбранный.
    private var registry: [String: GitCommitInfo] = [:]
    @Published private(set) var commits: [GitCommitInfo] = []
    @Published private(set) var rows: [GitGraphRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published var selection: String? {
        didSet { if selection != oldValue { loadSelection() } }
    }
    @Published private(set) var details: Details?
    @Published var selectedFile: String? {
        didSet { if selectedFile != oldValue { loadFilePatch() } }
    }
    @Published private(set) var filePatch: GitFilePatch?
    @Published var comparison: Comparison? {
        didSet { if comparison != oldValue { loadComparison() } }
    }
    @Published private(set) var comparisonFiles: [GitChangedFile] = []
    /// Что просили из меню коммита: новую ветку, revert, rebase — окна
    /// открывает вид истории.
    @Published var newBranchFrom: GitCommitInfo?
    @Published var confirmRevert: GitCommitInfo?
    @Published var rebaseBase: GitCommitInfo?
    @Published private(set) var error: String?

    struct Details: Equatable {
        var commit: GitCommitInfo
        var body: String
        var files: [GitChangedFile]
        /// С чем сравнивали: первый родитель; nil — корневой коммит.
        var parent: String?
    }

    private(set) var repository: URL?
    private var layout = GitGraphLayout()
    /// Хэши загруженных — чтобы страница не повторяла предыдущую.
    private var known = Set<String>()
    private var generation = 0
    private let queue = DispatchQueue(label: "pilot.git.history", qos: .userInitiated)
    static let pageSize = 400

    var selectedCommit: GitCommitInfo? { selection.flatMap { registry[$0] } }

    func open(repository: URL?) {
        guard repository != self.repository else { return }
        self.repository = repository
        commits = []
        rows = []
        selection = nil
        comparison = nil
        reload()
    }

    func reload() {
        generation += 1
        layout = GitGraphLayout()
        commits = []
        known = []
        rows = []
        mainline = []
        children = [:]
        hiddenBackMerges = [:]
        expanded = []
        registry = [:]
        overview = nil
        hasMore = false
        error = nil
        selection = nil
        // История файла или строк — всегда плоским списком: «моя ветка»
        // к ней не относится.
        switch filter.path == nil ? mode : .graph {
        case .graph: loadPage()
        case .mine: loadOverview()
        case .mainline: loadMainline()
        }
    }

    /// Следующая страница — когда долистали до конца.
    func loadMore() {
        guard hasMore, !isLoading else { return }
        if mode == .mainline && filter.path == nil { loadMainline() } else { loadPage() }
    }

    private func register(_ commits: [GitCommitInfo]) {
        for commit in commits { registry[commit.hash] = commit }
    }

    // MARK: - Основная ветка

    /// Основная ветка: куда смотрит `origin/HEAD`, иначе первая из
    /// привычных имён. `origin/…`, а не локальная, — она свежее.
    nonisolated static func mainRef(in repository: URL) -> String? {
        if let output = Git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repository),
           output.status == 0 {
            let ref = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty { return ref }
        }
        for ref in ["origin/main", "origin/master", "origin/develop", "main", "master", "develop"] {
            if Git.run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: repository)?.status == 0 { return ref }
        }
        return nil
    }

    // MARK: - Моя ветка

    private func loadOverview() {
        guard let repository else { return }
        isLoading = true
        let current = generation
        queue.async { [weak self] in
            let overview = Self.overview(in: repository)
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.isLoading = false
                self.overview = overview
                if let overview {
                    self.register(overview.commits + [overview.forkPoint].compactMap { $0 })
                    self.selection = overview.commits.first?.hash ?? overview.forkPoint?.hash
                } else {
                    self.error = L("Не нашлась основная ветка (origin/HEAD, main или master)")
                }
            }
        }
    }

    nonisolated private static func overview(in repository: URL) -> BranchOverview? {
        guard let main = mainRef(in: repository) else { return nil }
        func text(_ arguments: [String]) -> String {
            guard let output = Git.run(arguments, in: repository), output.status == 0 else { return "" }
            return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let branch = text(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let mainName = main.hasPrefix("origin/") ? String(main.dropFirst("origin/".count)) : main
        // По первому родителю: обратные слияния — одной строкой, без
        // коммитов основной ветки, которые они принесли.
        let commits = Git.run(["log", "--first-parent", GitCommitInfo.format, "--decorate=full", "-n", "300",
                               "HEAD", "--not", main], in: repository).map { GitCommitInfo.parse($0.stdout) } ?? []
        let unpushed = Set(text(["rev-list", "-n", "1000", "HEAD", "--not", "--remotes"]).split(separator: "\n").map(String.init))
        let base = text(["merge-base", "HEAD", main])
        let forkPoint = base.isEmpty ? nil
            : Git.run(["log", "-n", "1", GitCommitInfo.format, "--decorate=full", base], in: repository)
                .flatMap { GitCommitInfo.parse($0.stdout).first }
        let behind = Int(text(["rev-list", "--count", "HEAD.." + main])) ?? 0

        // Другие локальные ветки: насколько впереди и позади основной.
        var others: [OtherBranch] = []
        let refs = text(["for-each-ref", "--sort=-committerdate",
                         "--format=%(refname:short)%1f%(ahead-behind:\(main))%1f%(committerdate:unix)%1f%(subject)",
                         "refs/heads"])
        for line in refs.split(separator: "\n") {
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, f[0] != branch, f[0] != mainName else { continue }
            let counts = f[1].split(separator: " ").compactMap { Int($0) }
            others.append(OtherBranch(name: f[0], ahead: counts.first ?? 0, behind: counts.count > 1 ? counts[1] : 0,
                                      date: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0), subject: f[3]))
        }
        return BranchOverview(branch: branch.isEmpty ? nil : branch, mainRef: main, onMain: branch == mainName,
                              commits: commits, unpushed: unpushed, forkPoint: forkPoint, behind: behind, others: others)
    }

    // MARK: - По MR

    private func loadMainline() {
        guard let repository else { return }
        isLoading = true
        let current = generation
        let skip = mainline.count
        let text = filter.text.trimmingCharacters(in: .whitespaces)
        let author = filter.author.trimmingCharacters(in: .whitespaces)
        let scopeRef: String? = {
            if case .ref(let ref) = filter.scope { return ref }
            return nil
        }()
        queue.async { [weak self] in
            guard let main = scopeRef ?? Self.mainRef(in: repository) else {
                Task { @MainActor in
                    self?.isLoading = false
                    self?.error = L("Не нашлась основная ветка (origin/HEAD, main или master)")
                }
                return
            }
            var arguments = ["log", "--first-parent", GitCommitInfo.formatWithBody, "--decorate=full",
                             "-n", "\(Self.pageSize)", "--skip=\(skip)", main]
            if !text.isEmpty { arguments += ["-i", "--fixed-strings", "--grep=\(text)"] }
            if !author.isEmpty { arguments += ["-i", "--author=\(author)"] }
            let page = Git.run(arguments, in: repository).map { GitCommitInfo.parse($0.stdout) } ?? []
            let entries = page.map { MainlineEntry(commit: $0, request: MergeRequestInfo($0)) }
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.isLoading = false
                self.mainline += entries
                self.register(page)
                self.hasMore = page.count >= Self.pageSize
                if self.selection == nil, skip == 0 { self.selection = entries.first?.id }
            }
        }
    }

    /// Коммиты MR: что принесла вторая сторона слияния, без обратных слияний.
    private func loadChildren(of hash: String) {
        guard let repository, children[hash] == nil, let merge = registry[hash], merge.parents.count > 1 else { return }
        let current = generation
        queue.async { [weak self] in
            let main = Self.mainRef(in: repository) ?? "master"
            let all = Git.run(["log", "--first-parent", GitCommitInfo.format, "--decorate=full", "-n", "200",
                               "\(merge.parents[0])..\(merge.parents[1])"], in: repository)
                .map { GitCommitInfo.parse($0.stdout) } ?? []
            let shown = all.filter { !$0.isBackMerge(main: main) }
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.children[hash] = shown
                self.hiddenBackMerges[hash] = all.count - shown.count
                self.register(shown)
            }
        }
    }

    private func arguments(skip: Int) -> [String] {
        var arguments = ["log", GitCommitInfo.format, "--decorate=full", "-n", "\(Self.pageSize)", "--skip=\(skip)"]
        if let lines = filter.lines, let path = filter.path {
            // История фрагмента: git сам следит, куда строки уехали.
            arguments += ["-L", "\(lines.lowerBound),\(lines.upperBound):\(path)", "-s"]
        } else {
            arguments.append("--topo-order")
        }
        switch filter.scope {
        case .current: arguments.append("HEAD")
        case .all: arguments += ["--branches", "--remotes", "--tags", "HEAD"]
        case .ref(let ref): arguments.append(ref)
        }
        // По сообщению, без учёта регистра. Похожее на хэш сначала ищется
        // как ревизия (`loadPage`).
        let text = filter.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { arguments += ["-i", "--fixed-strings", "--grep=\(text)"] }
        let author = filter.author.trimmingCharacters(in: .whitespaces)
        if !author.isEmpty { arguments += ["-i", "--author=\(author)"] }
        if filter.lines == nil, let path = filter.path {
            // --follow (через переименования) — только для одного файла.
            let isDirectory = repository.flatMap {
                try? $0.appendingPathComponent(path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory
            } ?? false
            arguments += (isDirectory ? [] : ["--follow"]) + ["--", path]
        }
        return arguments
    }

    private func loadPage() {
        guard let repository else { return }
        isLoading = true
        let current = generation
        let skip = commits.count
        let arguments = arguments(skip: skip)
        // Хэш в поиске: сначала пробуем как ревизию.
        let text = filter.text.trimmingCharacters(in: .whitespaces)
        let hashLike = skip == 0 && text.count >= 6 && text.allSatisfy(\.isHexDigit)
        queue.async { [weak self] in
            var page: [GitCommitInfo] = []
            var failure: String?
            if hashLike, let output = Git.run(["log", GitCommitInfo.format, "--decorate=full", "-n", "1", text, "--"], in: repository),
               output.status == 0 {
                page = GitCommitInfo.parse(output.stdout)
            }
            if page.isEmpty {
                if let output = Git.run(arguments, in: repository) {
                    if output.status == 0 {
                        page = GitCommitInfo.parse(output.stdout)
                    } else if skip == 0 {
                        failure = L("git log завершился с кодом \(output.status)")
                    }
                }
            }
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.isLoading = false
                self.error = failure
                // Со -L git не умеет --skip — всё приходит первой страницей.
                let fresh = page.filter { self.known.insert($0.hash).inserted }
                var layout = self.layout
                let newRows = fresh.map { layout.add($0) }
                self.layout = layout
                self.commits += fresh
                self.register(fresh)
                self.rows += newRows
                self.hasMore = page.count >= Self.pageSize && self.filter.lines == nil
                if self.selection == nil, skip == 0 { self.selection = self.commits.first?.hash }
            }
        }
    }

    // MARK: - Выбранный коммит

    private func loadSelection() {
        details = nil
        selectedFile = nil
        filePatch = nil
        guard let repository, let commit = selectedCommit else { return }
        let current = generation
        queue.async { [weak self] in
            let body = Git.run(["show", "-s", "--format=%B", commit.hash], in: repository)
                .map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? commit.subject
            let parent = commit.parents.first
            // Файлы слияния — относительно первого родителя: то, что слияние
            // принесло в ветку.
            var arguments = ["diff", "--name-status", "-z", "-M", "--no-ext-diff"]
            if let parent { arguments += [parent, commit.hash] } else { arguments += ["--root", commit.hash] }
            if parent == nil { arguments = ["show", "--format=", "--name-status", "-z", "-M", "--root", commit.hash] }
            let files = Git.run(arguments, in: repository).map { GitChangedFile.parse($0.stdout) } ?? []
            Task { @MainActor in
                guard let self, self.generation == current, self.selection == commit.hash else { return }
                self.details = Details(commit: commit, body: body, files: files, parent: parent)
                // История файла — сразу его дифф.
                if let path = self.filter.path, files.contains(where: { $0.path == path }) {
                    self.selectedFile = path
                } else {
                    self.selectedFile = files.first?.path
                }
            }
        }
    }

    private func loadFilePatch() {
        filePatch = nil
        guard let repository, let path = selectedFile else { return }
        let range: (String?, String)
        if let comparison {
            range = (comparison.base, comparison.target)
        } else if let details {
            range = (details.parent, details.commit.hash)
        } else {
            return
        }
        let original = (comparison == nil ? details?.files : comparisonFiles)?.first { $0.path == path }?.originalPath
        let comparing = comparison != nil
        queue.async { [weak self] in
            var arguments: [String]
            if let base = range.0 {
                // Сравнение веток — от их общего предка (`...`), как в MR.
                arguments = ["diff", "--no-color", "--no-ext-diff", "-U3", "-M"]
                    + (comparing ? ["\(base)...\(range.1)"] : [base, range.1])
            } else {
                arguments = ["show", "--format=", "--no-color", "--no-ext-diff", "-U3", range.1]
            }
            arguments += ["--", path] + (original.map { [$0] } ?? [])
            let patch = Git.run(arguments, in: repository)
                .map { GitFilePatch.parse(String(decoding: $0.stdout, as: UTF8.self)) }
            Task { @MainActor in
                guard let self, self.selectedFile == path else { return }
                self.filePatch = patch
            }
        }
    }

    // MARK: - Сравнение веток

    private func loadComparison() {
        comparisonFiles = []
        selectedFile = nil
        filePatch = nil
        guard let repository, let comparison else { return }
        queue.async { [weak self] in
            let files = Git.run(["diff", "--name-status", "-z", "-M", "\(comparison.base)...\(comparison.target)"],
                                in: repository).map { GitChangedFile.parse($0.stdout) } ?? []
            Task { @MainActor in
                guard let self, self.comparison == comparison else { return }
                self.comparisonFiles = files
                self.selectedFile = files.first?.path
            }
        }
    }

    /// Текст файла в коммите — открыть версию целиком.
    func text(of path: String, at revision: String) async -> String? {
        guard let repository else { return nil }
        return await Task.detached {
            guard let output = Git.run(["show", "\(revision):\(path)"], in: repository), output.status == 0 else { return nil }
            return String(data: output.stdout, encoding: .utf8)
        }.value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
