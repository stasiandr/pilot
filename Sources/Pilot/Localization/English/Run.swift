/// Консоль запуска и лог сервера в ней.
extension English {
    static let run: [(String, String)] = [
        // RunConsole.swift
        ("Лог", "Log"),
        ("Вывод", "Output"),
        ("Лог сервера событиями или вывод процесса как есть", "Server log as events, or the process output as is"),

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
