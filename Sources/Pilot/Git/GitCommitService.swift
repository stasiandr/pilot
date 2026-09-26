import SwiftUI
import AppKit

/// Окно коммита: что подготовлено, что нет, дифф выбранного файла по
/// кускам, сообщение, коммит, amend и push. Всё — настоящим git, в фоне,
/// по одной операции за раз: индекс — общий ресурс, и две записи в него
/// сразу git не простит (`index.lock`).
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
        didSet { if selection != oldValue { loadPatch() } }
    }
    @Published private(set) var patch: GitFilePatch?
    /// Текст неотслеживаемого файла — у него диффа с индексом нет.
    @Published private(set) var untrackedText: String?
    @Published var message = "" {
        didSet { saveDraft() }
    }
    @Published var amend = false {
        didSet { amendChanged(from: oldValue) }
    }
    @Published private(set) var busy: String?
    /// Последний отказ git — показать как есть; nil — всё хорошо.
    @Published var error: String?
    /// Что получилось — одной строкой в окне.
    @Published private(set) var notice: String?

    /// Перед тем как откатить правки файла — снимок в локальную историю.
    var beforeDiscard: ((URL) -> Void)?

    private let queue = DispatchQueue(label: "pilot.git.commit", qos: .userInitiated)
    private var generation = 0
    /// Сообщение до того, как включили amend: выключили — вернём.
    private var messageBeforeAmend: String?

    private static let draftsKey = "pilot.commitDrafts"

    var canCommit: Bool {
        busy == nil && !CommitMessage.isEmpty(message) && (amend || !tree.staged.isEmpty)
    }

    // MARK: - Проект

    func workspaceChanged(to repository: URL?) {
        self.repository = repository
        tree = GitWorkingTree()
        isLoaded = false
        selection = nil
        patch = nil
        error = nil
        notice = nil
        amend = false
        messageBeforeAmend = nil
        message = loadDraft()
    }

    /// Окно открылось или git поменялся снаружи.
    func refresh() {
        guard let repository else { return }
        generation += 1
        let current = generation
        queue.async { [weak self] in
            let output = Git.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: repository)
            let tree = output.flatMap { $0.status == 0 ? GitWorkingTree.parse($0.stdout) : nil }
            Task { @MainActor in
                guard let self, self.generation == current, let tree else { return }
                self.tree = tree
                self.isLoaded = true
                self.fixSelection()
                self.loadPatch()
            }
        }
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
                self.patch = patch
                self.untrackedText = text
            }
        }
    }

    // MARK: - Индекс

    func stage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        run(L("Подготовка"), ["add", "-A", "--"] + paths)
    }

    func unstage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        // До первого коммита HEAD нет — reset не к чему; убираем из индекса.
        let arguments = tree.head == nil ? ["rm", "--cached", "-r", "-q", "--"] + paths : ["reset", "-q", "--"] + paths
        run(L("Отмена подготовки"), arguments)
    }

    func stageAll() { stage(tree.unstaged.map(\.path)) }
    func unstageAll() { unstage(tree.staged.map(\.path)) }

    /// Подготовить кусок — или, в подготовленном, убрать его обратно.
    func toggle(_ hunk: GitFilePatch.Hunk) {
        guard let patch, let selection else { return }
        let text = patch.patch(for: hunk)
        var arguments = ["apply", "--cached", "--whitespace=nowarn"]
        if selection.staged { arguments.append("--reverse") }
        arguments.append("-")
        run(selection.staged ? L("Отмена подготовки куска") : L("Подготовка куска"), arguments, input: Data(text.utf8))
    }

    /// Откатить правки файла в рабочей копии — к подготовленному, а если
    /// ничего не подготовлено, к HEAD. Новый файл — удалить. Перед этим —
    /// версия в локальную историю: ошибиться здесь легко.
    func discard(_ change: GitChange) {
        guard let repository else { return }
        let url = repository.appendingPathComponent(change.path)
        beforeDiscard?(url)
        if change.isUntracked {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                notice = L("\(change.fileName) — в Корзине")
            } catch {
                self.error = error.localizedDescription
            }
            refresh()
            return
        }
        run(L("Откат"), ["checkout", "--", change.path])
    }

    // MARK: - Коммит

    func commit(andPush push: Bool) {
        guard canCommit, let repository else { return }
        var arguments = ["commit", "-F", "-", "--cleanup=strip"]
        if amend { arguments.append("--amend") }
        let text = message
        busy = amend ? L("Изменяю коммит…") : L("Коммит…")
        error = nil
        notice = nil
        queue.async { [weak self] in
            let result = Git.execute(arguments, in: repository, input: Data(text.utf8))
            let hash = Git.run(["rev-parse", "--short", "HEAD"], in: repository)
                .map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            Task { @MainActor in
                guard let self else { return }
                self.busy = nil
                guard let result, result.succeeded else {
                    self.error = result?.message ?? L("Не удалось запустить git")
                    self.refresh()
                    return
                }
                self.notice = L("Закоммичено: \(hash ?? "") \(CommitMessage.summary(text))")
                self.messageBeforeAmend = nil
                self.amend = false
                self.message = ""
                self.refresh()
                if push { self.push() }
            }
        }
    }

    func push() {
        guard let repository, busy == nil else { return }
        // Ветки на сервере ещё нет — создать её и связать с локальной.
        var arguments = ["push"]
        if tree.upstream == nil, let branch = tree.branch { arguments += ["-u", "origin", branch] }
        busy = L("Отправляю…")
        error = nil
        queue.async { [weak self] in
            let result = Git.execute(arguments, in: repository)
            Task { @MainActor in
                guard let self else { return }
                self.busy = nil
                if let result, result.succeeded {
                    self.notice = L("Отправлено")
                } else {
                    self.error = result?.message ?? L("Не удалось запустить git")
                }
                self.refresh()
            }
        }
    }

    /// Amend: сообщение прошлого коммита в поле — его обычно и правят.
    private func amendChanged(from old: Bool) {
        guard amend != old, let repository else { return }
        if amend {
            messageBeforeAmend = message
            if let output = Git.run(["log", "-1", "--format=%B"], in: repository), output.status == 0 {
                message = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let previous = messageBeforeAmend {
            message = previous
            messageBeforeAmend = nil
        }
    }

    // MARK: - Запуск

    private func run(_ title: String, _ arguments: [String], input: Data? = nil) {
        guard let repository, busy == nil else { return }
        busy = title + "…"
        error = nil
        queue.async { [weak self] in
            let result = Git.execute(arguments, in: repository, input: input)
            Task { @MainActor in
                guard let self else { return }
                self.busy = nil
                if result?.succeeded != true {
                    self.error = result?.message ?? L("Не удалось запустить git")
                }
                self.refresh()
            }
        }
    }

    // MARK: - Черновик

    /// Недописанное сообщение переживает закрытие окна и перезапуск Pilot.
    private func saveDraft() {
        guard let repository, !amend else { return }
        var drafts = UserDefaults.standard.dictionary(forKey: Self.draftsKey) as? [String: String] ?? [:]
        drafts[repository.path] = message.isEmpty ? nil : message
        UserDefaults.standard.set(drafts, forKey: Self.draftsKey)
    }

    private func loadDraft() -> String {
        guard let repository else { return "" }
        return (UserDefaults.standard.dictionary(forKey: Self.draftsKey) as? [String: String])?[repository.path] ?? ""
    }
}
