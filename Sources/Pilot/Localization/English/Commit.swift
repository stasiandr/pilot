/// Окно коммита: подготовка, дифф, коммит, push.
extension English {
    static let commit: [(String, String)] = [
        // PilotApp.swift, Keymap.swift, Workspace.swift
        ("Коммит…", "Commit…"),
        ("Коммит", "Commit"),
        ("Проект не в git-репозитории", "The project isn’t in a git repository"),

        // CommitWindow.swift
        ("Коммит — %@", "Commit — %@"),
        ("Откатить правки в «%@»?", "Discard changes in “%@”?"),
        ("В Корзину", "Move to Trash"),
        ("Откатить", "Discard"),
        ("Новый файл уйдёт в Корзину.", "The new file will be moved to the Trash."),
        ("Неподготовленные правки пропадут; текущий текст останется в локальной истории (⌃⌥H).",
         "Unstaged changes will be lost; the current text stays in local history (⌃⌥H)."),
        ("Коммитов, которых нет на сервере", "Commits not on the server yet"),
        ("Коммитов на сервере, которых нет здесь", "Commits on the server not here yet"),
        ("Отправить коммиты", "Push"),
        ("Создать ветку на сервере и отправить", "Create the branch on the server and push"),
        ("Обновить", "Refresh"),
        ("Подготовлено", "Staged"),
        ("Убрать все", "Unstage All"),
        ("Изменения", "Changes"),
        ("Подготовить все", "Stage All"),
        ("Рабочая копия чистая", "Working tree is clean"),
        ("Убрать из коммита", "Unstage"),
        ("Подготовить к коммиту", "Stage"),
        ("Откатить правки…", "Discard Changes…"),
        ("Открыть в редакторе", "Open in Editor"),
        ("Сообщение коммита", "Commit message"),
        ("Изменить последний коммит", "Amend last commit"),
        ("Первая строка длиннее, чем удобно читать в git log", "The first line is longer than reads well in git log"),
        ("Закоммитить и отправить", "Commit and Push"),
        ("Изменить коммит", "Amend"),
        ("Закоммитить", "Commit"),
        ("подготовлено", "staged"),
        ("не подготовлено", "unstaged"),
        ("Выберите файл", "Select a file"),
        ("Двоичный файл — показать нечего", "Binary file — nothing to show"),
        ("Отличий нет", "No differences"),
        ("Убрать кусок", "Unstage Hunk"),
        ("Подготовить кусок", "Stage Hunk"),

        // GitCommitService.swift
        ("Подготовка", "Staging"),
        ("Отмена подготовки", "Unstaging"),
        ("Отмена подготовки куска", "Unstaging hunk"),
        ("Подготовка куска", "Staging hunk"),
        ("%@ — в Корзине", "%@ moved to the Trash"),
        ("Откат", "Discarding"),
        ("Изменяю коммит…", "Amending…"),
        ("Коммит…", "Commit…"),
        ("Закоммичено: %@ %@", "Committed: %@ %@"),
        ("Отправляю…", "Pushing…"),
        ("Отправлено", "Pushed"),

        // LocalHistoryView.swift
        ("до отката", "before discard"),
    ]
}
