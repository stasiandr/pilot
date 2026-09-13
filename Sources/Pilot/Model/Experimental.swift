import Foundation

/// Экспериментальные функции: выключены по умолчанию, включаются в меню
/// «Pilot → Экспериментальное». Хранятся в UserDefaults.
enum Experimental {

    /// Демон языковых серверов (LSPDaemon): держит прогретый Roslyn между
    /// запусками Pilot. Переменная окружения PILOT_LSP_DAEMON=1/0 перекрывает
    /// настройку — удобно для отладки.
    static let lspDaemonKey = "pilot.experimental.lspDaemon"

    static var lspDaemon: Bool {
        switch ProcessInfo.processInfo.environment["PILOT_LSP_DAEMON"] {
        case "1": return true
        case "0": return false
        default: return UserDefaults.standard.bool(forKey: lspDaemonKey)
        }
    }
}
