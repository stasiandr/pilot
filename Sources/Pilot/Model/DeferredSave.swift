import AppKit

/// Запись в UserDefaults после паузы, а не на каждое изменение.
///
/// Любая запись в UserDefaults будит все виды с @AppStorage: окна проектов
/// целиком — с тулбаром, навигатором и редактором — и главное меню
/// (PilotApp). Поле, которое сохраняло себя на каждую букву (SQL в окне базы,
/// сообщение коммита), так перерисовывало на каждую букву всё приложение.
/// Здесь запись ждёт паузы в наборе, а при выходе из Pilot делается сразу.
@MainActor
final class DeferredSave {
    private let write: @MainActor () -> Void
    private var pending: DispatchWorkItem?
    private var termination: NSObjectProtocol?

    init(_ write: @escaping @MainActor () -> Void) {
        self.write = write
        termination = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit {
        if let termination { NotificationCenter.default.removeObserver(termination) }
    }

    /// Записать, когда изменения утихнут: каждое новое откладывает запись.
    func schedule(after delay: TimeInterval = 1) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Записать сейчас, если запись ждёт.
    func flush() {
        guard let item = pending else { return }
        item.cancel()
        pending = nil
        write()
    }
}
