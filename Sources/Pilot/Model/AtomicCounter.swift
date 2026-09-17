import Foundation

/// Счётчик поколений, безопасный для чтения из любого потока.
///
/// Нужен, чтобы фоновый обход/поиск мог дёшево проверить «меня ещё ждут?».
/// Обращение к @MainActor-свойству отсюда было бы либо гонкой,
/// либо (через main.sync) потенциальным дедлоком.
final class AtomicCounter: @unchecked Sendable {
    private var value: Int = 0
    private let lock = NSLock()

    /// Увеличивает счётчик и возвращает новое поколение.
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    /// Текущее поколение — для того, кто обход не запускал, а лишь
    /// пристраивает к нему свою фоновую работу.
    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Актуально ли ещё это поколение.
    func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == generation
    }
}
