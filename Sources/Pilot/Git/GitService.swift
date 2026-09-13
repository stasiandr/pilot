import SwiftUI
import AppKit

/// Git для одного воркспейса: ветка, изменённые файлы, полоски у открытого
/// файла и авторство строк.
///
/// Как и языковой сервер, git **никогда не блокирует интерфейс**: каждый
/// запуск — в фоне, результат приходит, когда готов, а если за это время
/// открыли другой файл — выбрасывается. Нет git или проект не под git —
/// приложение просто не показывает ничего из этого.
@MainActor
final class GitService: ObservableObject {

    /// Корень репозитория проекта; nil — не git или git не установлен.
    @Published private(set) var repository: URL?
    @Published private(set) var status: GitStatus?
    /// Изменённые файлы проекта; пути — от корня проекта, как в индексе.
    @Published private(set) var changedFiles: [String: GitFileState] = [:]
    /// Отличия открытого файла от HEAD.
    @Published private(set) var lineChanges: [LineDiff.Change] = []
    /// Авторство строк открытого файла. Считается с задержкой и дольше всего.
    @Published private(set) var blame: GitBlame?

    /// Статус обновился — палитре пора перерисовать буквы.
    var onStatusChange: (() -> Void)?

    private var projectRoot: URL?
    private var document: LoadedDocument?

    private let queue = DispatchQueue(label: "pilot.git", qos: .userInitiated)
    private let blameQueue = DispatchQueue(label: "pilot.git.blame", qos: .utility)
    private let statusGeneration = AtomicCounter()
    private let documentGeneration = AtomicCounter()
    private var blameTask: Task<Void, Never>?
    private var blameCancellation: Git.Cancellation?

    init() {
        // Вернулись в Pilot из терминала — возможно, там закоммитили или
        // переключили ветку. Опрашивать git по таймеру ради этого незачем.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var changedCount: Int { changedFiles.count }

    // MARK: - Проект

    func workspaceChanged(to root: URL?) {
        _ = statusGeneration.bump()
        projectRoot = root?.resolvingSymlinksInPath()
        repository = Git.executable == nil ? nil : projectRoot.flatMap(Git.repositoryRoot(for:))
        status = nil
        changedFiles = [:]
        documentOpened(nil)
        refresh()
    }

    /// Перечитать ветку и список изменённых файлов. Если с прошлого раза
    /// сдвинулся HEAD (коммит, checkout), пересчитываем и открытый файл.
    func refresh() {
        guard let repository, let projectRoot else { return }
        let generation = statusGeneration.bump()
        let counter = statusGeneration

        queue.async { [weak self] in
            guard let fresh = Git.status(in: projectRoot) else { return }
            let files = Self.projectRelative(fresh.files, repository: repository, project: projectRoot)
            Task { @MainActor in
                guard let self, counter.isCurrent(generation) else { return }
                let headMoved = self.status != nil && self.status?.head != fresh.head
                if self.status != fresh { self.status = fresh }
                if self.changedFiles != files {
                    self.changedFiles = files
                    self.onStatusChange?()
                }
                if headMoved { self.recomputeDocument() }
            }
        }
    }

    /// git отдаёт пути от корня репозитория, а проект может быть его подпапкой.
    nonisolated private static func projectRelative(_ files: [String: GitFileState],
                                                    repository: URL, project: URL) -> [String: GitFileState] {
        guard project.path != repository.path else { return files }
        let prefix = String(project.path.dropFirst(repository.path.count + 1)) + "/"
        var result: [String: GitFileState] = [:]
        for (path, state) in files where path.hasPrefix(prefix) {
            result[String(path.dropFirst(prefix.count))] = state
        }
        return result
    }

    // MARK: - Открытый файл

    func documentOpened(_ document: LoadedDocument?) {
        self.document = document
        lineChanges = []
        blame = nil
        recomputeDocument()
    }

    /// Текст открытого файла поменялся: полоски пересчитываем по нему, но
    /// старые не сбрасываем — пусть висят до ответа, а не мигают.
    func documentEdited(_ document: LoadedDocument) {
        self.document = document
        recomputeDocument()
    }

    private func recomputeDocument() {
        let generation = documentGeneration.bump()
        blameTask?.cancel()
        blameCancellation?.cancel()

        // Файл может лежать во вложенном репозитории или подмодуле — корень
        // ищем от самого файла, а не берём корень проекта.
        guard Git.executable != nil, let document else { return }
        let fileURL = document.url.resolvingSymlinksInPath()
        guard let repo = Git.repositoryRoot(for: fileURL.deletingLastPathComponent()) else { return }
        let path = String(fileURL.path.dropFirst(repo.path.count + 1))
        let text = document.text
        let lineCount = document.model.lineCount
        let counter = documentGeneration

        queue.async { [weak self] in
            guard counter.isCurrent(generation),
                  let result = Git.lineChanges(text: text, path: path, repository: repo) else { return }
            Task { @MainActor in
                guard let self, counter.isCurrent(generation) else { return }
                if self.lineChanges != result.changes { self.lineChanges = result.changes }
                if result.tracked {
                    self.scheduleBlame(text: text, path: path, repository: repo,
                                       lineCount: lineCount, generation: generation)
                } else {
                    self.blame = nil
                }
            }
        }
    }

    /// Blame — самое дорогое, что тут есть, поэтому с задержкой: пока
    /// листаешь файлы через ⌘P, на каждый промежуточный он не запускается.
    private func scheduleBlame(text: String, path: String, repository: URL,
                               lineCount: Int, generation: Int) {
        let cancellation = Git.Cancellation()
        blameCancellation = cancellation
        let counter = documentGeneration

        blameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            self.blameQueue.async {
                guard counter.isCurrent(generation),
                      let blame = Git.blame(text: text, path: path, repository: repository,
                                            lineCount: lineCount, cancellation: cancellation)
                else { return }
                Task { @MainActor in
                    guard counter.isCurrent(generation) else { return }
                    self.blame = blame
                }
            }
        }
    }
}
