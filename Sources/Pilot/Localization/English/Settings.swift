/// Настройки: PilotApp.swift, LanguageSettings.swift, KeymapSettings.swift.
extension English {
    static let settings: [(String, String)] = [
        ("Общие", "General"),
        ("Сочетания клавиш", "Key Bindings"),
        // Язык
        ("Язык интерфейса", "Interface language"),
        ("Как в системе — %@", "System default — %@"),
        ("Системные меню и диалоги macOS сменят язык после перезапуска Pilot.",
         "Standard macOS menus and dialogs switch language after Pilot restarts."),
        // Сочетания клавиш
        ("Команда или сочетание", "Command or shortcut"),
        ("Сбросить всё", "Reset All"),
        ("Показать keybindings.json в Finder — его можно править руками и носить с собой",
         "Show keybindings.json in Finder — you can edit it by hand and take it with you"),
        ("⇧⇧, ⌃Tab, ⌃- / ⌃⇧- и боковые кнопки мыши работают всегда, в дополнение к назначенному.",
         "⇧⇧, ⌃Tab, ⌃- / ⌃⇧- and the side mouse buttons always work, in addition to what is assigned."),
        ("«%@»", "“%@”"),
        ("То же сочетание у %@ — сработает одно из них", "%@ has the same shortcut — only one of them will fire"),
        ("Нажмите сочетание…", "Press shortcut…"),
        ("Клик — записать новое сочетание; ⌫ — убрать, ⎋ — отменить",
         "Click to record a new shortcut; ⌫ removes it, ⎋ cancels"),
        ("без сочетания", "no shortcut"),
        ("Вернуть: %@", "Restore: %@"),
        ("%@ уже у «%@»", "%1$@ is already used by “%2$@”"),
        ("Забрать сочетание у той команды или оставить у обеих? С двумя сработает только одна.",
         "Take the shortcut from that command or keep it on both? With two, only one will fire."),
        ("Забрать", "Take It"),
        ("Оставить у обеих", "Keep on Both"),
        ("Отмена", "Cancel"),

        // Слитые ветки: настройки
        ("Оформление", "Appearance"),
        ("Импорт из Rider…", "Import from Rider…"),
        ("Сочетания, размер шрифта и счётчики использований из settings.zip или папки настроек Rider", "Shortcuts, font size and usage counters from a Rider settings.zip or settings folder"),
        ("Окно", "Window"),
        ("Верхняя панель", "Top Bar"),
        ("Обычная", "Regular"),
        ("Компактная", "Compact"),
        ("Путь к файлу над редактором", "File path above the editor"),
        ("Вкладки проектов", "Project tabs"),
        ("Проекты открываются вкладками одного окна; полоса с названиями — когда их больше одного. Выключено — каждый проект в своём окне, а вторая половина пары — вкладкой по своей кнопке.", "Projects open as tabs of one window; the bar with their names appears when there’s more than one. Off — each project gets its own window, and the other half of a pair opens as a tab from its button."),
        ("Кнопки на панели", "Toolbar buttons"),
        ("Настроить…", "Customize…"),
    ]
}
