import SwiftUI
import AppKit

enum GitWindowTab: String, CaseIterable, Hashable {
    case commit, history, stash, journal

    var title: String {
        switch self {
        case .commit: return L("Коммит")
        case .history: return L("Лог")
        case .stash: return "Stash"
        case .journal: return L("Консоль")
        }
    }

    var icon: String {
        switch self {
        case .commit: return "checkmark.circle"
        case .history: return "clock.arrow.circlepath"
        case .stash: return "tray.full"
        case .journal: return "terminal"
        }
    }
}

/// Репозиторий целиком: ветки, stash, fetch и pull, слияние, rebase,
/// cherry-pick, незаконченные операции. Окно коммита — про индекс, этот
/// объект — про ссылки.
///
/// **Опубликованное не переписываем.** Коммит, который есть хоть в одной
/// ветке на сервере (`--remotes`), уже у коллег: rebase, reset и fixup его
/// не трогают, force push Pilot не делает. Revert слияния Pilot не
/// предлагает вовсе — во многих командах он запрещён: потом ветку не
/// влить повторно. Отката операций (undo) тоже нет — сознательно.
@MainActor
final class GitClient: ObservableObject {
    @Published private(set) var repository: URL?
    @Published private(set) var branches: [GitBranch] = []
    @Published private(set) var stashes: [GitStash] = []
    /// Незаконченное слияние, rebase, cherry-pick.
    @Published private(set) var operation: GitOperation?
    @Published private(set) var busy: String?
    @Published var error: String?
    @Published private(set) var notice: String?
    /// Отказ, после которого можно попробовать иначе: переключиться, спрятав правки.
    @Published var offer: Offer?
    /// Большой репозиторий, и ускорение включено не всё.
    @Published private(set) var tuning: Git.Tuning.State?
    @Published private(set) var journal: [Git.Journal.Entry] = []
    /// Вкладка окна git.
    @Published var windowTab: GitWindowTab = .history

    struct Offer: Identifiable, Equatable {
        enum Kind: Equatable { case stashAndSwitch(GitBranch), forceDelete(String) }
        var kind: Kind
        var message: String
        var id: String { message }
    }

    /// После операции, которая двигает HEAD или индекс.
    var onRepositoryChanged: (() -> Void)?
    /// Перед операцией, которая перепишет рабочую копию.
    var beforeCheckout: (() -> Bool)?

    private let queue = DispatchQueue(label: "pilot.git.client", qos: .userInitiated)
    private var gitDirectory: URL?
    private var generation = 0

    init() {
        NotificationCenter.default.addObserver(forName: Git.Journal.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadJournal() }
        }
    }

    var currentBranch: GitBranch? { branches.first { $0.isCurrent } }
    var localBranches: [GitBranch] { branches.filter { !$0.isRemote } }
    var remoteBranches: [GitBranch] { branches.filter(\.isRemote) }

    func workspaceChanged(to repository: URL?) {
        self.repository = repository
        gitDirectory = repository.flatMap(Git.gitDirectory(for:))
        branches = []
        stashes = []
        operation = nil
        error = nil
        notice = nil
        offer = nil
        tuning = nil
        generation += 1
        reloadJournal()
        guard let repository else { return }
        let current = generation
        queue.async { [weak self] in
            let large = Git.Tuning.isLarge(repository)
            let state = large ? Git.Tuning.state(of: repository) : nil
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.tuning = state
            }
        }
    }

    /// Ветки, stash и состояние операции. Дёшево: for-each-ref читает
    /// только ссылки.
    func refresh() {
        guard let repository else { return }
        let current = generation
        let gitDirectory = gitDirectory
        queue.async { [weak self] in
            let branches = Git.run(["for-each-ref", "--sort=-committerdate", GitBranch.format,
                                    "refs/heads", "refs/remotes"], in: repository)
                .map { GitBranch.parse($0.stdout) } ?? []
            let stashes = Git.run(["stash", "list", GitStash.format], in: repository)
                .map { GitStash.parse($0.stdout) } ?? []
            let operation = gitDirectory.flatMap(GitOperation.current(gitDirectory:))
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if self.branches != branches { self.branches = branches }
                if self.stashes != stashes { self.stashes = stashes }
                if self.operation != operation { self.operation = operation }
            }
        }
    }

    /// Состояние операции — сразу, без процесса: полоса «идёт слияние» над
    /// редактором должна появиться, как только git её начал.
    func refreshOperation() {
        let fresh = gitDirectory.flatMap(GitOperation.current(gitDirectory:))
        if fresh != operation { operation = fresh }
    }

    private func reloadJournal() {
        let entries = Git.Journal.shared.snapshot(repository: repository?.path)
        if entries != journal { journal = entries }
    }

    // MARK: - Ветки

    func checkout(_ branch: GitBranch, stashing: Bool = false) {
        guard beforeCheckout?() ?? true else { return }
        let local = localBranches.first { $0.name == branch.localName }
        var steps: [[String]] = []
        if stashing { steps.append(["stash", "push", "--include-untracked", "-m", L("Pilot: перед переключением на \(branch.localName)")]) }
        if branch.isRemote && local == nil {
            steps.append(["switch", "--track", "-c", branch.localName, branch.name])
        } else {
            steps.append(["switch", branch.localName])
        }
        if stashing { steps.append(["stash", "pop"]) }
        run(L("Переключаюсь на \(branch.localName)"), steps, success: L("Ветка \(branch.localName)")) { [weak self] message in
            // Правки мешают переключиться — предложить спрятать их и вернуть после.
            guard !stashing, message.contains("would be overwritten") || message.contains("commit your changes or stash") else {
                return false
            }
            self?.offer = Offer(kind: .stashAndSwitch(branch),
                                message: L("Незакоммиченные правки мешают переключиться на \(branch.localName)."))
            return true
        }
    }

    func createBranch(_ name: String, from start: String? = nil, checkout: Bool = true) {
        guard GitBranch.isValidName(name) else {
            error = L("Так ветку назвать нельзя: \(name)")
            return
        }
        guard beforeCheckout?() ?? true else { return }
        var arguments = checkout ? ["switch", "-c", name] : ["branch", name]
        if let start { arguments.append(start) }
        run(L("Создаю ветку \(name)"), [arguments], success: L("Ветка \(name) создана"))
    }

    func renameBranch(_ branch: GitBranch, to name: String) {
        guard !branch.isRemote, GitBranch.isValidName(name) else {
            error = L("Так ветку назвать нельзя: \(name)")
            return
        }
        run(L("Переименовываю"), [["branch", "-m", branch.name, name]], success: L("Ветка теперь \(name)"))
    }

    /// Удалить локальную ветку. Не влитая — git откажет; тогда спросим ещё раз.
    func deleteBranch(_ branch: GitBranch, force: Bool = false) {
        guard !branch.isRemote, !branch.isCurrent else { return }
        run(L("Удаляю ветку \(branch.name)"), [["branch", force ? "-D" : "-d", branch.name]],
            success: L("Ветка \(branch.name) удалена")) { [weak self] message in
            guard !force, message.contains("not fully merged") else { return false }
            self?.offer = Offer(kind: .forceDelete(branch.name),
                                message: L("В ветке \(branch.name) есть коммиты, которых нет больше нигде. Удалить всё равно?"))
            return true
        }
    }

    func accept(_ offer: Offer) {
        self.offer = nil
        switch offer.kind {
        case .stashAndSwitch(let branch): checkout(branch, stashing: true)
        case .forceDelete(let name):
            if let branch = localBranches.first(where: { $0.name == name }) { deleteBranch(branch, force: true) }
        }
    }

    // MARK: - Сервер

    func fetch() {
        run(L("Получаю с сервера"), [["fetch", "--all", "--prune"]], success: L("Получено"))
    }

    /// Pull как настроено в репозитории (merge или rebase), со спрятанными
    /// на время правками.
    func pull() {
        guard beforeCheckout?() ?? true else { return }
        run(L("Обновляю ветку"), [["pull", "--autostash"]], success: L("Ветка обновлена"))
    }

    func push() {
        guard let branch = currentBranch else { return }
        var arguments = ["push"]
        if branch.upstream == nil || branch.upstreamGone { arguments += ["-u", "origin", branch.name] }
        run(L("Отправляю"), [arguments], success: L("Отправлено"))
    }

    // MARK: - Слияние, rebase, cherry-pick

    func merge(_ ref: String) {
        guard beforeCheckout?() ?? true else { return }
        run(L("Вливаю \(ref)"), [["merge", "--no-edit", ref]], success: L("\(ref) влита"))
    }

    /// Перенести текущую ветку на `ref`. Если в ней есть опубликованные
    /// коммиты, которых нет в `ref`, — отказ: после rebase их пришлось бы
    /// отправлять с force push.
    func rebase(onto ref: String) {
        guard let repository, beforeCheckout?() ?? true else { return }
        busy = L("Проверяю…")
        queue.async { [weak self] in
            let published = Self.publishedCommits(in: repository, range: "\(ref)..HEAD")
            Task { @MainActor in
                guard let self else { return }
                self.busy = nil
                if published > 0 {
                    self.error = L("В ветке \(published) коммитов уже на сервере — rebase переписал бы их. Влейте \(ref) слиянием.")
                    return
                }
                self.run(L("Rebase на \(ref)"), [["rebase", "--autostash", ref]], success: L("Ветка перенесена на \(ref)"))
            }
        }
    }

    func cherryPick(_ commit: GitCommitInfo) {
        guard !commit.isMerge else {
            error = L("Cherry-pick слияния не делается: непонятно, какую сторону брать")
            return
        }
        run(L("Cherry-pick \(commit.shortHash)"), [["cherry-pick", commit.hash]], success: L("Коммит \(commit.shortHash) перенесён"))
    }

    /// Обратный коммит. Для слияний не бывает: revert слияния ломает
    /// повторное вливание ветки, и во многих командах он запрещён.
    func revert(_ commit: GitCommitInfo) {
        guard !commit.isMerge else {
            error = L("Revert слияния Pilot не делает")
            return
        }
        run(L("Revert \(commit.shortHash)"), [["revert", "--no-edit", commit.hash]], success: L("Коммит \(commit.shortHash) отменён новым коммитом"))
    }

    enum ResetMode: String { case soft, mixed }

    /// Сдвинуть ветку назад, оставив правки в рабочей копии. Только на
    /// предка HEAD и только если уходящие коммиты не опубликованы.
    func reset(to commit: GitCommitInfo, mode: ResetMode) {
        guard let repository else { return }
        busy = L("Проверяю…")
        queue.async { [weak self] in
            let ancestor = Git.run(["merge-base", "--is-ancestor", commit.hash, "HEAD"], in: repository)?.status == 0
            let published = Self.publishedCommits(in: repository, range: "\(commit.hash)..HEAD")
            Task { @MainActor in
                guard let self else { return }
                self.busy = nil
                if !ancestor {
                    self.error = L("\(commit.shortHash) — не предок текущего коммита")
                } else if published > 0 {
                    self.error = L("\(published) из уходящих коммитов уже на сервере — сдвигать ветку назад нельзя")
                } else {
                    self.run(L("Сдвигаю ветку"), [["reset", "--\(mode.rawValue)", commit.hash]],
                             success: L("Ветка на \(commit.shortHash), правки остались в рабочей копии"))
                }
            }
        }
    }

    /// Сколько коммитов из диапазона уже есть в ветках на сервере.
    nonisolated static func publishedCommits(in repository: URL, range: String) -> Int {
        func count(_ extra: [String]) -> Int {
            guard let output = Git.run(["rev-list", "--count", range] + extra, in: repository), output.status == 0 else { return 0 }
            return Int(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return count([]) - count(["--not", "--remotes"])
    }

    // MARK: - Интерактивный rebase

    /// Коммиты от `base` (не включая) до HEAD — старые первыми, как в
    /// списке rebase. Слияния в диапазоне — отказ: их rebase развалил бы.
    func rebaseSteps(from base: GitCommitInfo) async -> Result<[RebaseStep], RebaseRefusal> {
        guard let repository else { return .failure(.message(L("Нет репозитория"))) }
        return await Task.detached(priority: .userInitiated) {
            let range = "\(base.hash)..HEAD"
            guard Git.run(["merge-base", "--is-ancestor", base.hash, "HEAD"], in: repository)?.status == 0 else {
                return .failure(.message(L("\(base.shortHash) — не предок текущего коммита")))
            }
            let commits = Git.run(["log", "--reverse", GitCommitInfo.format, range], in: repository)
                .map { GitCommitInfo.parse($0.stdout) } ?? []
            if commits.isEmpty { return .failure(.message(L("Переписывать нечего"))) }
            if commits.contains(where: \.isMerge) {
                return .failure(.message(L("В диапазоне есть слияния — интерактивный rebase их развалит")))
            }
            let published = Self.publishedCommits(in: repository, range: range)
            if published > 0 {
                return .failure(.message(L("\(published) из этих коммитов уже на сервере — переписывать их нельзя")))
            }
            return .success(commits.map { RebaseStep(commit: $0) })
        }.value
    }

    enum RebaseRefusal: Error { case message(String) }

    func runRebase(base: GitCommitInfo, steps: [RebaseStep]) {
        if let problem = RebaseStep.problem(steps) {
            error = problem
            return
        }
        guard beforeCheckout?() ?? true else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-rebase-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (i, step) in steps.enumerated() where step.action == .reword {
                try (step.message ?? step.commit.subject).write(to: directory.appendingPathComponent("msg\(i)"),
                                                                 atomically: true, encoding: .utf8)
            }
            let todo = RebaseStep.todo(steps) { directory.appendingPathComponent("msg\($0)").path }
            let todoFile = directory.appendingPathComponent("todo")
            try todo.write(to: todoFile, atomically: true, encoding: .utf8)
            // git зовёт «редактор» с путём к своему списку — подменяем его нашим.
            let editor = "cp " + RebaseStep.shellQuote(todoFile.path)
            run(L("Rebase"), [["rebase", "-i", "--autostash", base.hash]], success: L("История переписана"),
                environment: ["GIT_SEQUENCE_EDITOR": editor],
                after: { try? FileManager.default.removeItem(at: directory) })
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Незаконченная операция

    func continueOperation() {
        guard let operation else { return }
        run(L("Продолжаю"), [[operation.command, "--continue"]], success: L("Готово"))
    }

    func abortOperation() {
        guard let operation else { return }
        run(L("Прерываю"), [[operation.command, "--abort"]], success: L("Прервано, всё как было"))
    }

    func skipCommit() {
        guard let operation, operation != .merge else { return }
        run(L("Пропускаю коммит"), [[operation.command, "--skip"]], success: L("Коммит пропущен"))
    }

    // MARK: - Stash

    func stash(message: String, includeUntracked: Bool) {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if !message.trimmingCharacters(in: .whitespaces).isEmpty { arguments += ["-m", message] }
        run(L("Прячу правки"), [arguments], success: L("Правки спрятаны"))
    }

    func applyStash(_ stash: GitStash, pop: Bool) {
        guard beforeCheckout?() ?? true else { return }
        run(pop ? L("Достаю правки") : L("Применяю"), [["stash", pop ? "pop" : "apply", "--index", stash.ref]],
            success: pop ? L("Правки возвращены") : L("Правки применены"))
    }

    func dropStash(_ stash: GitStash) {
        run(L("Удаляю"), [["stash", "drop", stash.ref]], success: L("Спрятанное удалено"))
    }

    // MARK: - Ускорение

    func enableTuning() {
        guard let repository else { return }
        busy = L("Ускоряю репозиторий…")
        queue.async { [weak self] in
            let failure = Git.Tuning.enable(in: repository)
            let state = Git.Tuning.state(of: repository)
            Task { @MainActor in
                guard let self else { return }
                self.busy = nil
                self.tuning = state
                if let failure { self.error = failure } else { self.notice = L("Репозиторий ускорен") }
            }
        }
    }

    // MARK: - Запуск

    /// Шаги по очереди; первый отказ останавливает остальные. `onFailure`
    /// может перехватить отказ (вернув true) — тогда ошибку не показываем.
    private func run(_ title: String, _ steps: [[String]], success: String,
                     environment: [String: String] = [:],
                     onFailure: ((String) -> Bool)? = nil, after: (() -> Void)? = nil) {
        guard let repository, busy == nil else { return }
        busy = title + "…"
        error = nil
        notice = nil
        offer = nil
        queue.async { [weak self] in
            var failure: String?
            for step in steps {
                guard let result = Git.execute(step, in: repository, environment: environment) else {
                    failure = L("Не удалось запустить git")
                    break
                }
                if !result.succeeded {
                    failure = result.message.isEmpty ? L("git завершился с кодом \(result.status)") : result.message
                    break
                }
            }
            Task { @MainActor in
                guard let self else { return }
                after?()
                self.busy = nil
                if let failure {
                    if onFailure?(failure) != true { self.error = failure }
                } else {
                    self.notice = success
                }
                self.refresh()
                self.refreshOperation()
                self.onRepositoryChanged?()
            }
        }
    }
}
