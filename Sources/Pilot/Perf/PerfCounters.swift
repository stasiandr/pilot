import Darwin
import Foundation

/// Счётчики для замеров скорости (`bin/pilot-perf`, `PerfRun`).
///
/// Время на этой машине врёт: соседние сессии гоняют кампании тестов с
/// загрузкой 60–140, и одно и то же выходит то за 40 мс, то за 120. Число
/// выполненных инструкций от нагрузки почти не зависит: та же работа — те
/// же инструкции, на каком бы ядре и с какой бы частотой она ни шла. По нему
/// и судят о регрессиях, а время пишется рядом — ради порядка величин и
/// того, чего инструкции не видят: ожидания диска, замков и XPC.
enum PerfCounters {

    /// Весь процесс: все потоки, в том числе потоки Rustlyn.
    struct Process {
        var instructions: UInt64 = 0
        var cycles: UInt64 = 0
        /// Процессорное время всех потоков, пользователь и ядро, нс.
        var cpu: UInt64 = 0
        var footprint: UInt64 = 0
        /// Пик памяти за жизнь процесса: меньше не становится.
        var peakFootprint: UInt64 = 0
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
    }

    static func process() -> Process {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return Process() }
        // Время здесь — в тиках mach, а не в наносекундах: на Apple Silicon
        // тик — 125/3 нс.
        return Process(instructions: info.ri_instructions, cycles: info.ri_cycles,
                       cpu: nanoseconds(ticks: info.ri_user_time + info.ri_system_time),
                       footprint: info.ri_phys_footprint, peakFootprint: info.ri_lifetime_max_phys_footprint,
                       bytesRead: info.ri_diskio_bytesread, bytesWritten: info.ri_diskio_byteswritten)
    }

    /// Поток, который спрашивает.
    struct Thread {
        var instructions: UInt64 = 0
        var cycles: UInt64 = 0
    }

    /// `thread_selfcounts` — вызов ядра, которым считают и Instruments; в
    /// заголовках SDK его нет, поэтому через dlsym. Не нашёлся — нули, и
    /// замер судит по времени.
    private typealias SelfCounts = @convention(c) (Int32, UnsafeMutableRawPointer, Int) -> Int32
    private static let selfCounts: SelfCounts? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "thread_selfcounts")
        .map { unsafeBitCast($0, to: SelfCounts.self) }

    static func thread() -> Thread {
        guard let selfCounts else { return Thread() }
        var counts: (UInt64, UInt64) = (0, 0)
        // 1 — инструкции и такты (THSC_CPI).
        let status = withUnsafeMutableBytes(of: &counts) { selfCounts(1, $0.baseAddress!, $0.count) }
        return status == 0 ? Thread(instructions: counts.0, cycles: counts.1) : Thread()
    }

    static var hasThreadCounters: Bool { selfCounts != nil }

    /// Монотонные часы, нс.
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func nanoseconds(ticks: UInt64) -> UInt64 {
        ticks / UInt64(timebase.denom) * UInt64(timebase.numer)
    }
}

/// Отрезок замера: что сделал процесс и поток, который его открыл, от
/// начала до `finish`.
struct PerfSpan {
    let wall = PerfCounters.now()
    let process = PerfCounters.process()
    let thread = PerfCounters.thread()

    struct Result {
        var wallMs: Double
        /// Весь процесс, миллионы инструкций.
        var instructions: Double
        var cpuMs: Double
        /// Поток, открывший отрезок, миллионы инструкций.
        var threadInstructions: Double
        var bytesWritten: UInt64
        var bytesRead: UInt64
        var peakFootprint: UInt64
    }

    /// Звать с того же потока, что и `init`: иначе счётчики потока чужие.
    func finish() -> Result {
        let end = PerfCounters.process()
        let endThread = PerfCounters.thread()
        return Result(wallMs: Double(PerfCounters.now() - wall) / 1e6,
                      instructions: Double(end.instructions &- process.instructions) / 1e6,
                      cpuMs: Double(end.cpu &- process.cpu) / 1e6,
                      threadInstructions: Double(endThread.instructions &- thread.instructions) / 1e6,
                      bytesWritten: end.bytesWritten &- process.bytesWritten,
                      bytesRead: end.bytesRead &- process.bytesRead,
                      peakFootprint: end.peakFootprint)
    }
}
