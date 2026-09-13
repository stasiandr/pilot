import SwiftUI

/// Ревью MR внутри воркспейса: какой файл MR открыт, чьи полоски и треды
/// показывать, окно у строки и переходы по файлам MR.
extension Workspace {

    /// Файл MR, который сейчас в редакторе. Документ из рабочей копии
    /// с тем же путём сюда не относится — у него нет ревизии.
    var currentReviewFile: ReviewFile? {
        guard let document, let revision = document.revision,
              let active = review.active, let repository = review.repository else { return nil }
        return active.files.first { file in
            let sha = file.raw.deletedFile ? active.refs.baseSha : active.refs.headSha
            return sha == revision && repository.appendingPathComponent(file.path).path == document.url.path
        }
    }

    var isReviewDocument: Bool { currentReviewFile != nil }

    /// Полоски в колонке номеров: у файла MR — против базы MR, у рабочей
    /// копии — против HEAD. У удалённого файла полосок нет: он весь удалён.
    var editorLineChanges: [LineDiff.Change] {
        if let file = currentReviewFile { return file.raw.deletedFile ? [] : file.diff.changes }
        return document?.revision == nil ? git.lineChanges : []
    }

    /// Значки тредов у строк открытого файла MR.
    var editorCommentMarks: [Int: CommentMark] {
        guard let file = currentReviewFile, let active = review.active else { return [:] }
        return active.threads(in: file).mapValues { threads in
            CommentMark(count: threads.count, open: threads.contains { $0.isResolvable && !$0.isResolved })
        }
    }

    func threads(atLine line: Int) -> [GLDiscussion] {
        guard let file = currentReviewFile else { return [] }
        return review.active?.threads(in: file)[line] ?? []
    }

    /// Что было на месте строки до изменений: в MR — по диффу GitLab,
    /// в рабочей копии — по HEAD.
    func removedLines(at line: Int) -> [String]? {
        if let file = currentReviewFile {
            guard !file.raw.deletedFile, let removed = file.diff.block(atNewLine: line)?.removed,
                  !removed.isEmpty else { return nil }
            return removed
        }
        return document?.revision == nil ? git.removedLines(at: line) : nil
    }

    // MARK: - Окно у строки

    /// Клик по номеру строки. В файле MR окно есть всегда — хотя бы чтобы
    /// прокомментировать; в рабочей копии — только там, где что-то удалено.
    func lineClicked(_ line: Int) {
        if isReviewDocument || removedLines(at: line) != nil || !threads(atLine: line).isEmpty {
            requestLinePopover(line: line, compose: false)
        }
    }

    func commentOnLine(_ line: Int) {
        guard isReviewDocument else { return }
        requestLinePopover(line: line, compose: true)
    }

    func commentOnCaretLine() {
        guard let document else { return }
        commentOnLine(document.model.line(containing: caretOffset))
    }

    // MARK: - MR

    /// ⌥⌘R: вкладка ревью, а над списком MR — сразу в поиск.
    func showReviews() {
        navigatorTab = .review
        if isReviewSearchVisible { focusNavigatorFilter() }
    }

    /// Поиск есть, пока виден список: у открытого MR своя панель.
    var isReviewSearchVisible: Bool { review.phase == .ready && review.active == nil }

    /// Return в поиске: верхний найденный MR. Для `!123` — именно этот номер,
    /// даже если GitLab ещё не ответил на поиск.
    func openTopReviewSearchResult() {
        let search = MergeRequestSearch(review.searchQuery)
        let top = review.listing.first
        guard let iid = search.iid, top?.iid != iid else {
            if let top { openReview(top) }
            return
        }
        Task {
            if let mr = await review.mergeRequest(iid: iid) { openReview(mr) }
            else if let top { openReview(top) }
        }
    }

    /// Открывает MR и сразу первый файл — ревью начинается с кода, а не со списка.
    func openReview(_ mr: GLMergeRequest) {
        Task {
            await review.open(mr)
            guard let files = review.active?.files, review.active?.mr.iid == mr.iid else { return }
            if let first = files.first(where: { !$0.raw.deletedFile }) ?? files.first {
                open(reviewFile: first)
            }
        }
    }

    /// Следующий/предыдущий файл MR; из рабочей копии — первый/последний.
    func openAdjacentReviewFile(_ direction: Int) {
        guard let next = review.adjacentFile(to: currentReviewFile?.id, direction: direction) else { return }
        open(reviewFile: next)
    }

    /// Выход из ревью возвращает файл в версии рабочей копии, если он есть.
    func closeReview() {
        let url = document?.revision != nil ? document?.url : nil
        review.close()
        if let url, FileManager.default.fileExists(atPath: url.path) {
            open(file: url)
        }
    }

    /// Следующий/предыдущий тред в файле — по кругу, как вхождения.
    func jumpToThread(_ direction: Int) {
        guard let document else { return }
        let lines = editorCommentMarks.keys.sorted()
        guard !lines.isEmpty else { return }
        let current = document.model.line(containing: caretOffset)
        let target = direction > 0
            ? lines.first { $0 > current } ?? lines.first!
            : lines.last { $0 < current } ?? lines.last!
        requestReveal(LSPRange(start: LSPPosition(line: target, character: 0),
                               end: LSPPosition(line: target, character: 0)))
        requestLinePopover(line: target, compose: false)
    }
}
