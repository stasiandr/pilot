import SwiftUI
import AppKit

/// Git в редакторе: окно git, история файла и фрагмента, слияние
/// конфликтов, подготовка и откат блока изменений с колонки номеров.
extension Workspace {

    // MARK: - Окно

    /// Панель git под редактором на нужной вкладке.
    func openGitPanel(tab: GitWindowTab) {
        guard git.repository != nil else {
            showNotice(L("Проект не в git-репозитории"))
            return
        }
        gitClient.windowTab = tab
        if tab == .history { gitHistory.open(repository: git.repository) }
        if !showsGitPanel { showsGitPanel = true }
    }

    /// ⌘9, как панель Git в Rider: открыть на логе или спрятать.
    func toggleGitPanel() {
        if showsGitPanel { showsGitPanel = false } else { openGitPanel(tab: gitClient.windowTab) }
    }

    /// История файла или папки (путь от корня репозитория); с `lines` —
    /// история фрагмента.
    func showHistory(path: String, lines: ClosedRange<Int>? = nil) {
        gitHistory.open(repository: git.repository)
        gitHistory.mode = .graph
        gitHistory.comparison = nil
        var filter = gitHistory.filter
        filter.path = path
        filter.lines = lines
        filter.scope = .current
        gitHistory.filter = filter
        openGitPanel(tab: .history)
    }

    /// Путь открытого файла от корня его репозитория.
    private var repositoryPathOfDocument: String? {
        guard let document, document.revision == nil, let repository = git.repository else { return nil }
        let path = document.url.resolvingSymlinksInPath().path
        guard path.hasPrefix(repository.path + "/") else { return nil }
        return String(path.dropFirst(repository.path.count + 1))
    }

    /// ⌥⌘H в редакторе: история файла; с выделением — история выделенных строк.
    func showCurrentFileHistory() {
        guard let path = repositoryPathOfDocument, let document else {
            showNotice(L("У этого файла нет истории в git"))
            return
        }
        if editorSelection.length > 0 {
            let model = document.model
            let first = model.line(containing: editorSelection.location)
            let last = model.line(containing: max(editorSelection.location, NSMaxRange(editorSelection) - 1))
            let start = headLine(forLine: first), end = max(start, headLine(forLine: last))
            showHistory(path: path, lines: (start + 1)...(end + 1))
        } else {
            showHistory(path: path)
        }
    }

    /// История строк из HEAD (номера с нуля): `git log -L` считает строки
    /// по HEAD, а не по тексту в редакторе.
    func showLineHistory(headLines lines: Range<Int>) {
        guard let path = repositoryPathOfDocument, !lines.isEmpty else { return }
        showHistory(path: path, lines: (lines.lowerBound + 1)...lines.upperBound)
    }

    /// Строка в HEAD, соответствующая строке редактора: сдвиг на
    /// изменения выше неё. Внутри изменённого блока — его начало в HEAD.
    func headLine(forLine line: Int) -> Int {
        var shift = 0
        for change in editorLineChanges {
            if change.lines.contains(line) { return change.oldLines.lowerBound }
            guard change.lines.lowerBound <= line else { break }
            shift += change.oldLines.count - change.lines.count
        }
        return max(0, line + shift)
    }

    /// MR по номеру — в ревью Pilot, как ⌥⌘R с `!номер`.
    func openMergeRequest(iid: Int) {
        Task {
            guard let mr = await review.mergeRequest(iid: iid) else {
                showNotice(L("MR !\(iid) не найден — нет доступа к GitLab?"))
                return
            }
            navigatorTab = .review
            openReview(mr)
            bringToFront()
        }
    }

    // MARK: - Изменения файла в коммите

    /// Изменения версии, открытой в редакторе, против её родителя.
    var revisionDiff: RevisionDiff? {
        guard let document, let revision = document.revision else { return nil }
        return revisionDiffs[revision + "\n" + document.url.path]
    }

    /// Файл из истории — вкладкой редактора: его версия в `revision`,
    /// изменения против `base` полосками и удалёнными строками в тексте,
    /// курсор — на первом изменении. Удалённый файл — версия из `base`.
    func openChanges(path: String, originalPath: String? = nil, revision: String, base: String?, deleted: Bool) {
        guard let repository = git.repository else { return }
        Task {
            let texts = await Task.detached(priority: .userInitiated) { () -> (new: String?, old: String?) in
                func show(_ ref: String?, _ path: String) -> String? {
                    guard let ref, let output = Git.run(["show", "\(ref):\(path)"], in: repository),
                          output.status == 0 else { return nil }
                    return String(data: output.stdout, encoding: .utf8) ?? String(decoding: output.stdout, as: UTF8.self)
                }
                return (deleted ? nil : show(revision, path), show(base, originalPath ?? path))
            }.value
            if deleted {
                guard let old = texts.old, let base else {
                    showNotice(L("Не удалось прочитать \(path)"))
                    return
                }
                openRevision(path: originalPath ?? path, revision: base, text: old)
                return
            }
            guard let new = texts.new else {
                showNotice(L("Не удалось прочитать \(path) в \(String(revision.prefix(8)))"))
                return
            }
            let diff = RevisionDiff(old: texts.old ?? "", new: new)
            let url = repository.appendingPathComponent(path)
            revisionDiffs[revision + "\n" + url.path] = diff
            openRevision(path: path, revision: revision, text: new, line: diff.changes.first?.lines.lowerBound)
        }
    }

    // MARK: - Авторы строк

    /// Колонка авторов для редактора: только когда включена и blame посчитан.
    var editorBlameColumn: BlameColumn? {
        guard showsBlame, document?.revision == nil, let blame = git.blame else { return nil }
        // Окно перерисовывается часто, а blame меняется редко — колонку не
        // собираем заново, пока не пришёл новый.
        if let cached = blameColumnCache, cached.generation == git.blameGeneration { return cached.column }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yy"
        let column = BlameColumn(blame) { formatter.string(from: $0) }
        blameColumnCache = (git.blameGeneration, column)
        return column
    }

    /// Клик по автору: коммит этой строки — в окне истории.
    func blameClicked(line: Int) {
        guard let blame = git.blame, let commit = blame.commit(atLine: line), !commit.isUncommitted else { return }
        gitHistory.open(repository: git.repository)
        gitHistory.comparison = nil
        gitHistory.mode = .graph
        var filter = GitHistoryModel.Filter()
        filter.text = commit.sha
        gitHistory.filter = filter
        openGitPanel(tab: .history)
    }

    // MARK: - После операций

    /// Коммит, переключение ветки, слияние: перечитать всё, что зависит от HEAD.
    func gitRepositoryChanged() {
        git.refresh()
        gitClient.refreshOperation()
        if let document { git.documentEdited(document) }
        if gitHistory.repository != nil { gitHistory.reload() }
    }

    /// Перед тем как git перепишет рабочую копию, — сохранить открытое:
    /// иначе несохранённый текст в редакторе разошёлся бы с новой веткой.
    func confirmUnsavedBeforeCheckout() -> Bool {
        let dirty = tabs.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = L("Сохранить изменения перед операцией git?")
        alert.informativeText = dirty.map { $0.url.lastPathComponent }.prefix(8).joined(separator: ", ")
        alert.addButton(withTitle: L("Сохранить все"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        saveAll()
        return !tabs.contains(where: \.isDirty)
    }

    // MARK: - Слияние

    func mergeSession(for path: String) -> MergeSession? {
        guard let repository = git.repository else { return nil }
        if let existing = mergeSessions[path] { return existing }
        let session = MergeSession(repository: repository, path: path,
                                   yamlMerge: MergeSession.locateYAMLMerge(editorContents: unity.project?.editorContents))
        mergeSessions[path] = session
        return session
    }

    /// Окно слияния для файла в конфликте.
    func openMerge(path: String) {
        guard let root else { return }
        mergeSessions[path] = nil
        ProjectWindows.shared.openWindow?(id: MergeWindow.sceneID, value: root.path + "\n" + path)
    }

    /// Окно слияния для файла, открытого в редакторе.
    func openMergeForCurrentFile() {
        guard let path = repositoryPathOfDocument else { return }
        openMerge(path: path)
    }

    /// Первый файл в конфликте — в окно слияния.
    func openNextConflict() {
        guard let repository = git.repository, let root else { return }
        let prefix = root.path == repository.path ? "" : String(root.path.dropFirst(repository.path.count + 1)) + "/"
        guard let path = git.changedFiles.filter({ $0.value == .conflicted }).keys.sorted().first else {
            showNotice(L("Конфликтов нет"))
            return
        }
        openMerge(path: prefix + path)
    }

    func mergeFinished(path: String) {
        mergeSessions[path] = nil
        gitRepositoryChanged()
        commits.refresh()
    }

    // MARK: - Блок изменений в редакторе

    /// Блок изменений (против HEAD) на строке открытого файла.
    func lineChange(at line: Int) -> LineDiff.Change? {
        editorLineChanges.first { $0.lines.contains(line) || ($0.lines.isEmpty && $0.lines.lowerBound == line) }
    }

    private var caretLine: Int? { document.map { $0.model.line(containing: caretOffset) } }

    func stageChangeAtCaret() {
        guard let line = caretLine else { return }
        stageChange(at: line)
    }

    func revertChangeAtCaret() {
        guard let line = caretLine else { return }
        revertChange(at: line)
    }

    /// Откатить блок в тексте — одной правкой, которую отменяет ⌘Z. Git не
    /// нужен: старый текст уже есть (полоски считаются по нему).
    func revertChange(at line: Int) {
        guard let buffer, !buffer.isReadOnly, let change = lineChange(at: line) else { return }
        let old = git.headLines(change.oldLines) ?? []
        let model = buffer.document.model
        let text = buffer.storage.string as NSString
        let range: NSRange
        if change.lines.isEmpty {
            // Удалённые строки встают перед строкой `lowerBound`.
            let at = change.lines.lowerBound < model.lineCount ? model.lineRange(change.lines.lowerBound).lowerBound : text.length
            let needsBreak = at == text.length && text.length > 0 && !text.hasSuffix("\n")
            let inserted = (needsBreak ? "\n" : "") + old.joined(separator: "\n") + (needsBreak ? "" : "\n")
            _ = applyEdits([UnityEdit(range: NSRange(location: at, length: 0), text: inserted)], to: buffer.url,
                           actionName: L("Откат изменения"))
            return
        }
        let start = model.lineRange(change.lines.lowerBound).lowerBound
        let lastLine = change.lines.upperBound - 1
        // Диапазон строки — вместе с её переводом строки.
        let end = model.lineRange(lastLine).upperBound
        range = NSRange(location: start, length: end - start)
        var replacement = old.isEmpty ? "" : old.joined(separator: "\n") + "\n"
        // Блок в самом конце файла без перевода строки — и замена без него.
        if end == text.length, !text.hasSuffix("\n"), replacement.hasSuffix("\n") { replacement.removeLast() }
        _ = applyEdits([UnityEdit(range: range, text: replacement)], to: buffer.url, actionName: L("Откат изменения"))
    }

    /// Подготовить к коммиту только этот блок. Файл сначала сохраняется:
    /// git берёт текст с диска.
    func stageChange(at line: Int) {
        guard let buffer, lineChange(at: line) != nil, let path = repositoryPathOfDocument,
              let repository = git.repository else { return }
        if buffer.isDirty { save() }
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let output = Git.run(["diff", "--no-color", "--no-ext-diff", "-U0", "--", path], in: repository),
                      output.status == 0 else { return L("Не удалось получить дифф") }
                let patch = GitFilePatch.parse(String(decoding: output.stdout, as: UTF8.self))
                // Строка в редакторе — с нуля, в диффе — с единицы.
                let target = line + 1
                guard let hunk = patch.hunks.first(where: { hunk in
                    let count = hunk.lines.filter { $0.hasPrefix("+") }.count
                    return count == 0 ? hunk.newStart == target - 1 || hunk.newStart == target
                                      : (hunk.newStart..<(hunk.newStart + count)).contains(target)
                }) else { return L("Этот блок уже подготовлен") }
                let result = Git.execute(["apply", "--cached", "--unidiff-zero", "--whitespace=nowarn", "-"],
                                         in: repository, input: Data(patch.patch(for: hunk).utf8))
                return result?.succeeded == true ? nil : (result?.message ?? L("Не удалось запустить git"))
            }.value
            if let failure { showNotice(failure) } else { showNotice(L("Блок подготовлен к коммиту")) }
            commits.refresh()
            git.refresh()
        }
    }
}

/// Изменения версии файла против другой: полоски у номеров и удалённые
/// строки, как у файла MR. Для версий из истории git — во вкладке версии.
struct RevisionDiff: Equatable {
    var changes: [LineDiff.Change]
    var oldLines: [String]

    init(old: String, new: String) {
        changes = LineDiff.changes(old: old, new: new)
        oldLines = old.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Удалённое — над строкой, с которой начинается изменение.
    var removedLines: [RemovedLines] {
        changes.filter { !$0.oldLines.isEmpty && $0.oldLines.upperBound <= oldLines.count }
            .map { RemovedLines(line: $0.lines.lowerBound, lines: Array(oldLines[$0.oldLines])) }
    }

    func removed(at line: Int) -> [String]? {
        guard let change = changes.first(where: { $0.lines.contains(line) || ($0.lines.isEmpty && $0.lines.lowerBound == line) }),
              !change.oldLines.isEmpty, change.oldLines.upperBound <= oldLines.count else { return nil }
        return Array(oldLines[change.oldLines])
    }
}
