#if !canImport(CRustlyn)
import Foundation

/// Pilot без Rustlyn.
///
/// Библиотеки может не быть: `build-rust.sh` не запускали, Rust не стоит,
/// или это тесты ядра, которые собирают подмножество исходников отдельным
/// пакетом — и гоняются в том числе на Linux. Во всех этих случаях Pilot
/// должен собираться и работать, просто без того, что Rustlyn добавляет к C#.
///
/// Поэтому заглушка повторяет поверхность настоящей сессии и отвечает
/// «ничего». Зовущие уже написаны так, что «ничего» — это возврат к своему
/// лексеру, своему структурному разбору и своему читателю метаданных: тому,
/// чем Pilot обходился раньше. Ни одного `#if` на стороне зовущих нет
/// намеренно — иначе их было бы с десяток, и каждый пришлось бы держать в
/// голове при следующей правке.
///
/// Единственное, чего здесь нет, — `start` не создаёт сессию, поэтому
/// `shared` всегда `nil`, и до методов экземпляра дело не доходит вовсе.
/// Они объявлены только чтобы вызовы типизировались.
final class Rustlyn: @unchecked Sendable {

    /// Всегда `nil`: сессию поднимать нечем, и до методов экземпляра дело
    /// не доходит.
    static var shared: Rustlyn? { nil }

    @discardableResult
    static func start(root: URL, symbols: [String] = []) -> Rustlyn? { nil }

    static func stop() {}

    /// Без библиотеки понимать нечего.
    static func understands(_ url: URL) -> Bool { false }

    /// Сверять нечего, поэтому расхождения нет.
    static func buildsAgree() -> Bool { true }

    let root: URL

    private init(root: URL) { self.root = root }

    var lastError: String { "" }

    struct Statistics {
        var stamped: UInt64 = 0
        var rehashed: UInt64 = 0
        var fromDisk: UInt64 = 0
        var computed: UInt64 = 0
        var entries: Int = 0
        var bytes: Int = 0
        var reuseRatio: Double { 0 }
    }

    var statistics: Statistics { Statistics() }

    struct IndexReport {
        var files = 0
        var reused = 0
        var parsed = 0
        var unreadable = 0
    }

    @discardableResult func open(_ url: URL) -> Bool { false }
    @discardableResult func open(_ url: URL, text: String) -> Bool { false }
    @discardableResult func setText(_ url: URL, _ text: String) -> Bool { false }
    func close(_ url: URL) {}

    func tokens(_ url: URL, lines: ClosedRange<Int>) -> [Token]? { nil }
    func warm(_ url: URL) {}
    func outline(_ url: URL) -> RustlynOutline? { nil }

    @discardableResult
    func reindex(_ urls: [URL]) -> IndexReport { IndexReport() }

    func definition(_ url: URL, offset: Int) -> RustlynDefinition { RustlynDefinition() }
    func implementations(_ url: URL, offset: Int) -> RustlynDefinition { RustlynDefinition() }

    func assemblyText(_ url: URL) -> String? { nil }
    func methodToken(_ url: URL, line: Int) -> UInt32? { nil }
    func methodBody(_ url: URL, token: UInt32) -> String? { nil }
}
#endif
