import SwiftUI

/// Разрешение конфликтов слияния в открытом файле: принять сторону,
/// перейти к следующему, отметить файл решённым.
extension Workspace {

    /// git считает файл конфликтным — даже если маркеров в тексте уже нет
    /// (их убрали руками, а `git add` ещё не сделали).
    var isConflictedFile: Bool {
        guard let path = openFilePath, buffer?.isReadOnly != true else { return false }
        return git.changedFiles[path] == .conflicted
    }

    /// Показывать ли полосу конфликтов над редактором.
    var showsConflictBar: Bool {
        guard let buffer, !buffer.isReadOnly else { return false }
        return !conflicts.isEmpty || isConflictedFile
    }

    /// Конфликт, в котором стоит курсор; если курсор между конфликтами —
    /// ближайший ниже, как у «следующего».
    var conflictNearCaret: MergeConflict? {
        guard let document, !conflicts.isEmpty else { return nil }
        let line = document.model.line(containing: caretOffset)
        return MergeConflicts.conflict(atLine: line, in: conflicts)
            ?? conflicts.first { $0.start > line }
    }

    /// Номер конфликта под курсором — «2 из 5» в полосе.
    var conflictIndexNearCaret: Int? {
        guard let conflict = conflictNearCaret else { return nil }
        return conflicts.firstIndex(of: conflict)
    }

    func acceptConflict(_ choice: ConflictChoice) {
        guard let conflict = conflictNearCaret else { NSSound.beep(); return }
        requestConflictAction(start: conflict.start, choice: choice)
    }

    func acceptAllConflicts(_ choice: ConflictChoice) {
        guard !conflicts.isEmpty else { return }
        requestConflictAction(start: nil, choice: choice)
    }

    /// По кругу, как вхождения: выделяется строка `<<<<<<<`.
    func jumpToConflict(_ direction: Int) {
        guard let document, !conflicts.isEmpty else { return }
        let line = document.model.line(containing: caretOffset)
        let target = direction > 0
            ? conflicts.first { $0.start > line } ?? conflicts.first!
            : conflicts.last { $0.start < line } ?? conflicts.last!
        let end = document.model.lineRange(target.start).count
        requestReveal(LSPRange(start: LSPPosition(line: target.start, character: 0),
                               end: LSPPosition(line: target.start, character: max(0, end - 1))))
    }

    /// Сохранить и `git add`: для git это и есть «конфликт решён».
    /// Пока в файле остались маркеры, отказываемся — иначе в коммит
    /// уйдёт текст с `<<<<<<<`.
    func markConflictsResolved() {
        conflictError = nil
        guard conflicts.isEmpty else {
            conflictError = "В файле ещё остались конфликты"
            return
        }
        guard let url = buffer?.url else { return }
        if isCurrentDirty { save() }
        guard !isCurrentDirty else { return }   // сохранение не удалось — alert уже показан
        Task {
            conflictError = await git.markResolved(url)
        }
    }
}
