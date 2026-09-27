/// Консоль запуска и лог сервера в ней; тот же вывод и переменные в панели отладки.
extension English {
    static let run: [(String, String)] = [
        // RunConsole.swift
        ("Лог", "Log"),
        ("Вывод", "Output"),
        ("Лог сервера событиями или вывод процесса как есть", "Server log as events, or the process output as is"),

        // RunService.swift, DebugService.swift: последняя строка вывода
        ("Остановлено", "Stopped"),
        ("Завершилось", "Finished"),
        ("Завершилось сигналом %@", "Exited on signal %@"),
        ("Завершилось с кодом %@", "Exited with code %@"),
        ("Не запустилось: %@", "Failed to start: %@"),
        ("Сборка не удалась", "Build failed"),
        ("Программа завершилась с кодом %@", "The program exited with code %@"),
        ("Типы для %@: %@", "Types for %@: %@"),

        // DebugViews.swift
        ("Переменные", "Variables"),
        ("Отладчик", "Debugger"),
        ("Клик — изменить", "Click to change"),
        ("Двойной клик — изменить", "Double-click to change"),

        // ServerLogView.swift
        ("Вывод процесса мимо логгера: сборка, Console.WriteLine", "Process output that bypassed the logger: build, Console.WriteLine"),
        ("Выберите сообщение — здесь будут свойства и стек; двойной клик — к строке, которая его записала, или к месту ошибки",
         "Select a message to see its properties and stack; double-click to go to the line that logged it, or to where the error happened"),
        ("Перейти к записи лога", "Go to Log Call"),
        ("Перейти к месту ошибки", "Go to Error Location"),
        ("Записано", "Logged at"),
        ("Место ошибки", "Error at"),
    ]
}
