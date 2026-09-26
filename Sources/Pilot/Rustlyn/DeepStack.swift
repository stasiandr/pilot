import Foundation

/// Потоки с глубоким стеком — для вызовов Rustlyn.
///
/// Компилятор рекурсивен ровно настолько, насколько глубок код, который он
/// читает: длинная конкатенация строк, член перечисления, чьё значение
/// выражено через другие, — и у связывателя крупные кадры. Потокам GCD
/// дано 512 КБ стека, этого на настоящих проектах не хватает, и переполнение
/// роняет весь Pilot, а не один ответ. Поэтому вызов уходит на поток со
/// стеком в 64 МБ, а зовущий ждёт ответа — как ждал бы его и так.
///
/// Потоки не заводятся на каждый вызов: отработавший ждёт следующего, а
/// новый появляется, только когда все заняты. Так одновременные вопросы
/// (проверка файла, автодополнение, поиск ссылок) не выстраиваются в очередь
/// друг за другом. Стек только зарезервирован: память занимает то, что
/// в самом деле понадобилось.
enum DeepStack {

    static let size = 64 << 20

    /// Сколько свободных потоков держать про запас; лишние завершаются.
    private static let spare = 4

    private final class Worker: @unchecked Sendable {
        let wake = DispatchSemaphore(value: 0)
        var job: (() -> Void)?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var idle: [Worker] = []

    /// Выполнить `body` на потоке с глубоким стеком и вернуть его ответ.
    /// Уже на таком потоке — прямо здесь.
    static func run<T>(_ body: () -> T) -> T {
        if pthread_get_stacksize_np(pthread_self()) >= size { return body() }
        return withoutActuallyEscaping(body) { body in
            var result: T?
            let done = DispatchSemaphore(value: 0)
            // Приоритет — зовущего: компиляция с фона не должна спорить с
            // автодополнением, которого ждут с клавиатуры.
            let qos = qos_class_self()
            dispatch {
                pthread_set_qos_class_self_np(qos, 0)
                result = body()
                done.signal()
            }
            done.wait()
            return result!
        }
    }

    private static func dispatch(_ job: @escaping () -> Void) {
        lock.lock()
        let worker = idle.popLast()
        lock.unlock()
        if let worker {
            worker.job = job
            worker.wake.signal()
            return
        }
        let fresh = Worker()
        fresh.job = job
        let thread = Thread { loop(fresh) }
        thread.name = "pilot.rustlyn"
        thread.stackSize = size
        thread.start()
    }

    private static func loop(_ worker: Worker) {
        while true {
            worker.job?()
            worker.job = nil
            lock.lock()
            guard idle.count < spare else {
                lock.unlock()
                return
            }
            idle.append(worker)
            lock.unlock()
            worker.wake.wait()
        }
    }
}
