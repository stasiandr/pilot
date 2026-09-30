import SwiftUI
import AppKit

/// Коммит: что подготовлено, что нет, дифф выбранного файла по кускам и
/// строкам, сообщение, коммит, amend, fixup и push. Всё — настоящим git,
/// в фоне, по одной операции за раз: индекс — общий ресурс, и две записи
/// в него сразу git не простит (`index.lock`).
///
/// Операции не отказывают, пока идёт предыдущая, а встают в очередь, и
/// список меняется сразу, до ответа git, — как в Sublime Merge: на
/// большом репозитории каждая запись индекса — десятые доли секунды, и
/// кнопка, которая не нажимается, пока git думает, раздражает больше
/// всего.
@MainActor
final class GitCommitService: ObservableObject {
    /// Какую сторону файла смотрим: подготовленное (индекс против HEAD)
    /// или то, что ещё нет (рабочая копия против индекса).
    struct Selection: Hashable {
        var path: String
        var staged: Bool
    }

    @Published private(set) var repository: URL?
    @Published private(set) var tree = GitWorkingTree()
    @Published private(set) var isLoaded = false
    @Published var selection: Selection? {
        didSet {
            if selection != oldValue {
                selectedLines = [:]
                loadPatch()
            }
        }
    }
    @Published private(set) var patch: GitFilePatch?
    /// Выбранные строки в диффе: id куска → индексы его строк.
    @Published var selectedLines: [String: Set<Int>] = [:]
    /// Текст неотслеживаемого файла — у него диффа с индексом нет.
    @Published private(set) var untrackedText: String?
    /// Черновик сохраняется после паузы в наборе: запись в UserDefaults на
    /// каждую букву перерисовывала все окна (DeferredSave).
    @Published var message = "" {
        didSet { if !amend { draftSave.schedule() } }
    }
    @Published var amend = false {
        didSet { amendChanged(from: oldValue) }
    }
    /// Что делается сейчас; nil — ничего.
    @Published private(set) var busy: String?
    /// Коммит, push — пока идут, второй не начать. Подготовка — ставится в очередь.
    @Published private(set) var isCommitting = false
    /// Последний отказ git — показать как есть; nil — всё хорошо.
    @Published var error: String?
    /// Что получилось — одной строкой в окне.
    @Published private(set) var notice: String?
    /// Разорванные пары ассет — `.meta` среди подготовленного.
    @Published private(set) var metaProblems: [MetaPairs.Problem] = []
    /// Последние коммиты ветки — для fixup.
    @Published private(set) var recentCommits: [GitCommitInfo] = []

    /// Перед тем как откатить правки файла — снимок в локальную историю.
    var beforeDiscard: ((URL) -> Void)?
    /// После коммита, push и прочего, что двигает HEAD, — пусть остальные
    /// (полоски, история) перечитают.
    var onRepositoryChanged: (() -> Void)?
    /// После подготовки и отката: HEAD на месте, историю перечитывать незачем.
    var onIndexChanged: (() -> Void)?

    private let queue = DispatchQueue(label: "pilot.git.commit", qos: .userInitiated)
    private var generation = 0
    /// Операции, которые ещё не дошли до git.
    private var pending = 0
    /// Сообщение до того, как включили amend: выключили — вернём.
    private var messageBeforeAmend: String?

    private static let draftsKey = "pilot.commitDrafts"
    private lazy var draftSave = DeferredSave { [weak self] in self?.saveDraft() }

    /// Ничего не подготовлено — коммит берёт все изменения, как «smart
    /// commit» в VS Code: подготавливать ради одного коммита каждый файл
    /// руками незачем.
    var commitsEverything: Bool { tree.staged.isEmpty && !amend }

    var canCommit: Bool {
        !isCommitting && !CommitMessage.isEmpty(message)
            && (amend || !tree.staged.isEmpty || !tree.unstaged.filter { !$0.isConflicted }.isEmpty)
            && !tree.changes.contains(where: \.isConflicted)
    }

    // MARK: - Проект

    func workspaceChanged(to repository: URL?) {
        // Недописанное — черновиком прежнего репозитория, пока он ещё тот.
        draftSave.flush()
        self.repository = repository
        tree = GitWorkingTree()
        isLoaded = false
        selection = nil
        patch = nil
        error = nil
        notice = nil
        amend = false
        messageBeforeAmend = nil
        recentCommits = []
        metaProblems = []
        message = loadDraft()
    }

    /// Окно открылось или git поменялся снаружи.
    func refresh() {
        guard let repository else { return }
        // Пока в очереди наши операции, статус перечитает последняя из них:
        // промежуточный ответ вернул бы в список то, что уже переложено.
        guard pending == 0 else { return }
        generation += 1
        let current = generation
        queue.async { [weak self] in
            let output = Git.run(Git.Tuning.flags(for: repository)
                                 + ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: repository)
            let tree = output.flatMap { $0.status == 0 ? GitWorkingTree.parse($0.stdout) : nil }
            let problems = tree.map { Self.metaProblems(in: $0, repository: repository) } ?? []
            Task { @MainActor in
                guard let self, self.generation == current, self.pending == 0, let tree else { return }
                if self.tree != tree { self.tree = tree }
                if self.metaProblems != problems { self.metaProblems = problems }
                self.isLoaded = true
                self.fixSelection()
                self.loadPatch()
            }
        }
    }

    nonisolated private static func metaProblems(in tree: GitWorkingTree, repository: URL) -> [MetaPairs.Problem] {
        // Только там, где .meta вообще есть: без них проверка — пустая трата.
        guard tree.changes.contains(where: { $0.path.hasSuffix(".meta") }) else { return [] }
        let fm = FileManager.default
        return MetaPairs.problems(
            in: tree,
            exists: { fm.fileExists(atPath: repository.appendingPathComponent($0).path) },
            tracked: { path in Git.run(["cat-file", "-e", "HEAD:\(path)"], in: repository)?.status == 0 })
    }

    /// Выбранный файл ушёл из своей группы (подготовили целиком) — выбираем
    /// его же в другой, а если его нет совсем — первый.
    private func fixSelection() {
        if let selection {
            let change = tree.changes.first { $0.path == selection.path }
            if let change {
                if selection.staged && !change.hasStaged { self.selection = Selection(path: change.path, staged: false) }
                if !selection.staged && !change.hasUnstaged { self.selection = Selection(path: change.path, staged: true) }
                return
            }
        }
        if let first = tree.unstaged.first {
            selection = Selection(path: first.path, staged: false)
        } else if let first = tree.staged.first {
            selection = Selection(path: first.path, staged: true)
        } else {
            selection = nil
        }
    }

    private func loadPatch() {
        guard let repository, let selection,
              let change = tree.changes.first(where: { $0.path == selection.path }) else {
            patch = nil
            untrackedText = nil
            return
        }
        let current = generation
        queue.async { [weak self] in
            var patch: GitFilePatch?
            var text: String?
            if change.isUntracked && !selection.staged {
                let url = repository.appendingPathComponent(change.path)
                if let data = try? Data(contentsOf: url), data.count < 2_000_000 {
                    text = data.contains(0) ? nil : String(decoding: data, as: UTF8.self)
                }
            } else {
                var arguments = ["diff", "--no-color", "--no-ext-diff", "-U3"]
                if selection.staged { arguments.append("--cached") }
                arguments += ["--", change.path]
                if let output = Git.run(arguments, in: repository), output.status == 0 {
                    patch = GitFilePatch.parse(String(decoding: output.stdout, as: UTF8.self))
                }
            }
            Task { @MainActor in
                guard let self, self.generation == current, self.selection == selection else { return }
                if self.patch != patch { self.patch = patch }
                self.untrackedText = text
                // Строки, выбранные в куске, которого больше нет, не выбраны.
                let ids = Set(patch?.hunks.map(\.id) ?? [])
                self.selectedLines = self.selectedLines.filter { ids.contains($0.key) }
            }
        }
    }

    // MARK: - Индекс

    /// Все изменённые пути — для пар `.meta`.
    private var changedPaths: Set<String> { Set(tree.changes.map(\.path)) }

    func stage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let all = MetaPairs.expand(paths, within: changedPaths)
        moveOptimistically(all, toStaged: true)
        enqueue(L("Подготовка"), ["add", "-A", "--"] + all)
    }

    func unstage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let all = MetaPairs.expand(paths, within: changedPaths)
        moveOptimistically(all, toStaged: false)
        // До первого коммита HEAD нет — reset не к чему; убираем из индекса.
        let arguments = tree.head == nil ? ["rm", "--cached", "-r", "-q", "--"] + all : ["reset", "-q", "--"] + all
        enqueue(L("Отмена подготовки"), arguments)
    }

    func stageAll() { stage(tree.unstaged.filter { !$0.isConflicted }.map(\.path)) }
    func unstageAll() { unstage(tree.staged.map(\.path)) }

    /// Список меняется сразу; настоящий статус придёт после git. Файл,
    /// у которого правки есть в обеих группах, так и остаётся в обеих —
    /// до ответа не угадать.
    private func moveOptimistically(_ paths: [String], toStaged: Bool) {
        let set = Set(paths)
        var changed = false
        for i in tree.changes.indices where set.contains(tree.changes[i].path) {
            var change = tree.changes[i]
            guard !change.isConflicted else { continue }
            if toStaged, change.staged == nil {
                change.staged = change.isUntracked ? .added : (change.unstaged ?? .modified)
                change.unstaged = nil
                change.isUntracked = false
            } else if !toStaged, change.unstaged == nil, !change.isUntracked {
                if change.staged == .added { change.isUntracked = true } else { change.unstaged = change.staged }
                change.staged = nil
            } else {
                continue
            }
            tree.changes[i] = change
            changed = true
        }
        if changed { fixSelection() }
    }

    /// Подготовить кусок — или, в подготовленном, убрать его обратно.
    /// Выбраны строки куска — только их.
    func toggle(_ hunk: GitFilePatch.Hunk) {
        guard let patch, let selection else { return }
        let lines = selectedLines[hunk.id] ?? []
        let text: String
        if lines.isEmpty {
            text = patch.patch(for: hunk)
        } else {
            guard let partial = patch.patch(for: hunk, lines: lines, reverse: selection.staged) else { return }
            text = partial
        }
        var arguments = ["apply", "--cached", "--whitespace=nowarn"]
        if selection.staged { arguments.append("--reverse") }
        arguments.append("-")
        selectedLines[hunk.id] = nil
        enqueue(selection.staged ? L("Отмена подготовки куска") : L("Подготовка куска"), arguments, input: Data(text.utf8))
    }

    /// Откатить кусок (или выбранные строки) в рабочей копии — только для
    /// неподготовленного. Перед этим — файл в локальную историю.
    func discard(_ hunk: GitFilePatch.Hunk) {
        guard let repository, let patch, let selection, !selection.staged else { return }
        let lines = selectedLines[hunk.id] ?? []
        let text: String
        if lines.isEmpty {
            text = patch.patch(for: hunk)
        } else {
            // Откат выбранных строк — тот же «назад», что и у подготовленного:
            // невыбранные правки остаются в рабочей копии.
            guard let partial = patch.patch(for: hunk, lines: lines, reverse: true) else { return }
            text = partial
        }
        beforeDiscard?(repository.appendingPathComponent(selection.path))
        selectedLines[hunk.id] = nil
        enqueue(L("Откат куска"), ["apply", "--reverse", "--whitespace=nowarn", "-"], input: Data(text.utf8))
    }

    /// Откатить правки файла в рабочей копии — к подготовленному, а если
    /// ничего не подготовлено, к HEAD. Новый файл — в Корзину. Перед этим —
    /// версия в локальную историю: ошибиться здесь легко. `.meta` — вместе
    /// с ассетом.
    func discard(_ change: GitChange) {
        guard let repository else { return }
        let paths = MetaPairs.expand([change.path], within: changedPaths)
        let changes = paths.compactMap { path in tree.changes.first { $0.path == path } }
        var tracked: [String] = []
        for change in changes {
            let url = repository.appendingPathComponent(change.path)
            beforeDiscard?(url)
            if change.isUntracked {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    notice = L("\(change.fileName) — в Корзине")
                } catch {
                    self.error = error.localizedDescription
                }
            } else {
                tracked.append(change.path)
            }
        }
        if tracked.isEmpty { refresh() } else { enqueue(L("Откат"), ["checkout", "--"] + tracked) }
    }

    // MARK: - Выбор строк

    func toggleLine(_ index: Int, in hunk: GitFilePatch.Hunk, extend: Bool) {
        guard GitFilePatch.changeLines(hunk).contains(index) else { return }
        var lines = selectedLines[hunk.id] ?? []
        if extend, let anchor = lines.min() {
            let range = min(anchor, index)...max(anchor, index)
            lines = Set(GitFilePatch.changeLines(hunk).filter { range.contains($0) })
        } else if lines.contains(index) {
            lines.remove(index)
        } else {
            lines.insert(index)
        }
        selectedLines[hunk.id] = lines.isEmpty ? nil : lines
    }

    // MARK: - Коммит

    /// `fixup` — хэш коммита, в который влить подготовленное
    /// (`commit --fixup`); `autosquash` — и сразу переписать ветку.
    func commit(andPush push: Bool, fixup: GitCommitInfo? = nil, autosquash: Bool = false) {
        guard let repository, !isCommitting else { return }
        if fixup == nil, !canCommit { return }
        var arguments = ["commit", "--cleanup=strip"]
        if let fixup {
            arguments += ["--fixup=\(fixup.hash)"]
        } else {
            arguments += ["-F", "-"]
            if amend { arguments.append("--amend") }
        }
        let everything = commitsEverything && fixup == nil
        let text = message
        busy = fixup != nil ? L("Fixup…") : amend ? L("Изменяю коммит…") : L("Коммит…")
        isCommitting = true
        error = nil
        notice = nil
        queue.async { [weak self] in
            if everything {
                if let staged = Git.execute(["add", "-A"], in: repository), !staged.succeeded {
                    Task { @MainActor in self?.finishCommit(error: staged.message) }
                    return
                }
            }
            let result = Git.execute(arguments, in: repository, input: fixup == nil ? Data(text.utf8) : nil)
            var squashError: String?
            if let fixup, result?.succeeded == true, autosquash {
                // Неинтерактивный `rebase -i --autosquash`: список не
                // показываем, git сам ставит fixup под нужный коммит.
                let base = fixup.parents.first ?? "--root"
                let squash = Git.execute(["rebase", "-i", "--autosquash", "--autostash", base], in: repository,
                                         environment: ["GIT_SEQUENCE_EDITOR": "true"])
                if squash?.succeeded != true { squashError = squash?.message ?? L("Не удалось запустить git") }
            }
            let hash = Git.run(["rev-parse", "--short", "HEAD"], in: repository)
                .map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            Task { @MainActor in
                guard let self else { return }
                guard let result, result.succeeded else {
                    self.finishCommit(error: result?.message ?? L("Не удалось запустить git"))
                    return
                }
                if let squashError {
                    self.finishCommit(error: squashError)
                    return
                }
                if fixup == nil {
                    self.notice = L("Закоммичено: \(hash ?? "") \(CommitMessage.summary(text))")
                    self.messageBeforeAmend = nil
                    self.amend = false
                    self.message = ""
                } else {
                    self.notice = autosquash ? L("Влито в \(fixup!.shortHash)") : L("Fixup-коммит для \(fixup!.shortHash)")
                }
                self.finishCommit(error: nil)
                if push { self.push() }
            }
        }
    }

    private func finishCommit(error: String?) {
        busy = nil
        isCommitting = false
        if let error { self.error = error }
        refresh()
        onRepositoryChanged?()
    }

    func push(force: Bool = false) {
        guard let repository, !isCommitting else { return }
        // Ветки на сервере ещё нет — создать её и связать с локальной.
        var arguments = ["push"]
        if force { arguments.append("--force-with-lease") }
        if tree.upstream == nil, let branch = tree.branch { arguments += ["-u", "origin", branch] }
        busy = L("Отправляю…")
        isCommitting = true
        error = nil
        queue.async { [weak self] in
            let result = Git.execute(arguments, in: repository)
            Task { @MainActor in
                guard let self else { return }
                if let result, result.succeeded { self.notice = L("Отправлено") }
                self.finishCommit(error: result?.succeeded == true ? nil : (result?.message ?? L("Не удалось запустить git")))
            }
        }
    }

    /// Последние коммиты ветки, которых нет ни в одной ветке на сервере, —
    /// в них можно влить fixup, не переписывая опубликованную историю.
    func loadRecentCommits() {
        guard let repository else { return }
        queue.async { [weak self] in
            let arguments = ["log", "-n", "30", GitCommitInfo.format, "HEAD", "--not", "--remotes"]
            let commits = Git.run(arguments, in: repository).map { GitCommitInfo.parse($0.stdout) } ?? []
            Task { @MainActor in self?.recentCommits = commits.filter { !$0.isMerge } }
        }
    }

    /// Amend: сообщение прошлого коммита в поле — его обычно и правят.
    private func amendChanged(from old: Bool) {
        guard amend != old, let repository else { return }
        if amend {
            // С amend черновик не пишется — набранное до него сохраняем сейчас.
            draftSave.flush()
            messageBeforeAmend = message
            if let output = Git.run(["log", "-1", "--format=%B"], in: repository), output.status == 0 {
                message = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let previous = messageBeforeAmend {
            message = previous
            messageBeforeAmend = nil
        }
    }

    // MARK: - Очередь

    /// Операция с индексом — в очередь. Статус перечитывается, когда
    /// очередь опустела: промежуточный ответ дёрнул бы список назад.
    private func enqueue(_ title: String, _ arguments: [String], input: Data? = nil) {
        guard let repository else { return }
        pending += 1
        busy = title + "…"
        error = nil
        queue.async { [weak self] in
            let result = Git.execute(arguments, in: repository, input: input)
            Task { @MainActor in
                guard let self else { return }
                self.pending -= 1
                if result?.succeeded != true {
                    self.error = result?.message ?? L("Не удалось запустить git")
                }
                if self.pending == 0 {
                    self.busy = nil
                    self.refresh()
                    self.onIndexChanged?()
                }
            }
        }
    }

    // MARK: - Черновик

    /// Недописанное сообщение переживает закрытие окна и перезапуск Pilot.
    /// Сообщение amend черновиком не бывает: пока amend включён, запись не
    /// планируется, а набранное до него записано при включении.
    private func saveDraft() {
        guard let repository else { return }
        var drafts = UserDefaults.standard.dictionary(forKey: Self.draftsKey) as? [String: String] ?? [:]
        drafts[repository.path] = message.isEmpty ? nil : message
        UserDefaults.standard.set(drafts, forKey: Self.draftsKey)
    }

    private func loadDraft() -> String {
        guard let repository else { return "" }
        return (UserDefaults.standard.dictionary(forKey: Self.draftsKey) as? [String: String])?[repository.path] ?? ""
    }
}
