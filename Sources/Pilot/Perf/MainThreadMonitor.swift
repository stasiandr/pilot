import Foundation

/// Сколько главный поток занят и где застревал: виток цикла событий — от
/// пробуждения до засыпания. Виток дольше ~100 мс пользователь видит:
/// клавиша не печатается, окно не отзывается.
///
/// Инструкции главного потока считает не наблюдатель, а `Mark`: счётчики
/// потока в начале и в конце отрезка. Звать его — только с главного.
@MainActor
final class MainThreadMonitor {
    static let shared = MainThreadMonitor()

    /// Виток дольше этого — застревание.
    static let stallThreshold: UInt64 = 100_000_000

    private var observer: CFRunLoopObserver?
    private var awake: UInt64?
    private var busy: UInt64 = 0
    private var iterations = 0
    /// С последнего `resetLongest`: сколько длился и когда начался.
    private var longest: UInt64 = 0
    private var longestStart: UInt64 = 0
    private var stalls = 0

    func install() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let created = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, Int.max) { _, activity in
            MainActor.assumeIsolated {
                MainThreadMonitor.shared.observe(activity)
            }
        }
        observer = created
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
    }

    private func observe(_ activity: CFRunLoopActivity) {
        let now = PerfCounters.now()
        if activity == .afterWaiting {
            awake = now
        } else if let start = awake {
            let spent = now - start
            busy += spent
            iterations += 1
            if spent > longest {
                longest = spent
                longestStart = start
            }
            if spent >= Self.stallThreshold { stalls += 1 }
            awake = nil
        }
    }

    /// Точка отсчёта.
    struct Mark {
        fileprivate let wall: UInt64
        fileprivate let busy: UInt64
        fileprivate let iterations: Int
        fileprivate let stalls: Int
        fileprivate let thread: PerfCounters.Thread
        fileprivate let process: PerfCounters.Process
    }

    /// Занято с засыпания, включая текущий виток.
    private var busyNow: UInt64 { busy + (awake.map { PerfCounters.now() - $0 } ?? 0) }

    func mark() -> Mark {
        Mark(wall: PerfCounters.now(), busy: busyNow, iterations: iterations, stalls: stalls,
             thread: PerfCounters.thread(), process: PerfCounters.process())
    }

    /// Самый долгий виток считается заново.
    func resetLongest() {
        longest = 0
        longestStart = 0
    }

    struct Span {
        var wallMs: Double
        /// Главный поток: занят, миллионы инструкций, витков, застреваний.
        var busyMs: Double
        var mainInstructions: Double
        var iterations: Int
        var stalls: Int
        /// Самый долгий виток с последнего `resetLongest` и когда он начался
        /// от начала отрезка — по нему видно, на каком шаге застряли.
        var longestMs: Double
        var longestAtMs: Double
        /// Весь процесс.
        var instructions: Double
        var cpuMs: Double
        var bytesWritten: UInt64
        var peakFootprint: UInt64
    }

    func since(_ mark: Mark) -> Span {
        let thread = PerfCounters.thread()
        let process = PerfCounters.process()
        return Span(wallMs: Double(PerfCounters.now() - mark.wall) / 1e6,
                    busyMs: Double(busyNow - mark.busy) / 1e6,
                    mainInstructions: Double(thread.instructions &- mark.thread.instructions) / 1e6,
                    iterations: iterations - mark.iterations,
                    stalls: stalls - mark.stalls,
                    longestMs: Double(longest) / 1e6,
                    longestAtMs: longestStart > mark.wall ? Double(longestStart - mark.wall) / 1e6 : 0,
                    instructions: Double(process.instructions &- mark.process.instructions) / 1e6,
                    cpuMs: Double(process.cpu &- mark.process.cpu) / 1e6,
                    bytesWritten: process.bytesWritten &- mark.process.bytesWritten,
                    peakFootprint: process.peakFootprint)
    }
}
