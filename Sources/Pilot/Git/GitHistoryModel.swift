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

    @Published var filter = Filter() {
        didSet { if filter != oldValue { reload() } }
    }
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

    var selectedCommit: GitCommitInfo? { commits.first { $0.hash == selection } }

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
        hasMore = false
        error = nil
        selection = nil
        loadPage()
    }

    /// Следующая страница — когда долистали до конца.
    func loadMore() {
        guard hasMore, !isLoading else { return }
        loadPage()
    }

    private func arguments(skip: Int) -> [String] {
        var arguments = ["log", GitCommitInfo.format, "-n", "\(Self.pageSize)", "--skip=\(skip)"]
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
            if hashLike, let output = Git.run(["log", GitCommitInfo.format, "-n", "1", text, "--"], in: repository),
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
