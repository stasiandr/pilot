/// Расширения проекта: ExtensionViews.swift, настройки.
extension English {
    static let extensions: [(String, String)] = [
        ("Расширения", "Extensions"),
        ("В проекте есть расширение «%@» — включить?", "This project has the “%@” extension — enable it?"),
        ("Не включать", "Don’t Enable"),
        ("Включить", "Enable"),
        ("имена пары", "pair names"),
        ("зеркальные папки", "mirrored folders"),
        ("сетевые структуры", "network structures"),
        ("конфиги", "configs"),
        ("ничего не описывает", "describes nothing"),
        ("Откройте проект — здесь появятся его расширения.", "Open a project to see its extensions here."),
        ("%@ — встроено в эту сборку", "%@ — built into this build"),
        ("Расширение — папка .pilot/extensions/<имя>/ с extension.json в репозитории проекта (или встроенное в сборку Pilot). Оно описывает соглашения проекта: как узнать вторую половину пары, какие папки у половин одинаковые, как устроены сетевые структуры и конфиги. Код расширения не исполняют.",
         "An extension is a .pilot/extensions/<name>/ folder with extension.json in the project’s repository (or one built into this Pilot build). It describes the project’s conventions: how to find the other half of a pair, which folders both halves share, and how network structures and configs are laid out. Extensions contain no code to run."),
        ("Перечитать", "Reload"),
        ("Расширений нет", "No extensions"),
        // ProjectRules.swift
        ("%@/%@/%@: нет «%@»", "%@/%@/%@: “%@” is missing"),
        ("%@/%@/%@: не JSON", "%@/%@/%@: not JSON"),
    ]
}
