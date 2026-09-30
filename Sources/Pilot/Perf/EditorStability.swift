import AppKit

/// Что видно в редакторе в один виток цикла событий: по строке — где она
/// стоит, где кончается, какого цвета её символы, какой над ней счётчик.
struct EditorFrame {
    struct Line {
        /// Верх текста строки от верха видимой области.
        var y: CGFloat
        /// Начало строк и конец этой — от левого края прокрутки.
        var left: CGFloat
        var endX: CGFloat
        /// Сам текст — чтобы не считать сдвигом правку.
        var text: Int
        /// Цвет символа — номер в палитре замера; 0 — цвет самого текста,
        /// 255 — пробел или таб, их цвет не виден.
        var colors: [UInt8]
        /// Подпись счётчика над строкой, если он виден.
        var lens: String?
    }

    var buffer: ObjectIdentifier
    var height: CGFloat
    var width: CGFloat
    var lines: [Int: Line] = [:]
}

/// Стабильность открытия файла — как CLS в вебе: сколько на экране
/// менялось после того, как файл впервые показан. Показали текст, а потом
/// он поехал вниз под счётчики использований, вбок под подсказки,
/// перекрасился — всё это глаз видит как дёрганье.
///
/// Кадр снимается на каждом витке главного цикла, перед сном (тогда же
/// AppKit рисует), и сравнивается с прошлым:
///
/// * сдвиг — строка встала в другое место по высоте или по ширине; счёт
///   сдвига — как у CLS: доля сдвинутых видимых строк × на сколько
///   сдвинулись (доля высоты или ширины экрана), по всем кадрам;
/// * перекраска — непробельный символ сменил цвет;
/// * счётчик — подпись над строкой появилась, пропала или сменилась
///   (появление с местом под него — ещё и сдвиг);
/// * первый кадр — через сколько после `show` файл на экране;
/// * успокоился — когда был последний такой кадр;
/// * неверно — символы, которые в конце не того цвета, что дала бы
///   раскраска сейчас: «слетевшая» подсветка.
///
/// Включается `PILOT_PERF` (сценарий `stability`) или `PILOT_STABILITY=log`:
/// тогда итог каждого открытия пишется в лог — для обычной работы.
@MainActor
final class EditorStability {
    static var shared: EditorStability? = {
        let wanted = PerfUI.isRequested || ProcessInfo.processInfo.environment["PILOT_STABILITY"] != nil
        return wanted ? EditorStability() : nil
    }()

    private var logs: Bool { ProcessInfo.processInfo.environment["PILOT_STABILITY"] == "log" }

    struct Report {
        var file = ""
        var firstMs = 0.0
        var settledMs = 0.0
        var shiftScore = 0.0
        var shifts = 0
        var movedLines = 0
        var recolors = 0
        var recoloredChars = 0
        var lensChanges = 0
        var wrongChars = 0
        var lines = 0
        var chars = 0
        var frames = 0
        /// Когда что-то менялось: мс от показа и что.
        var events: [(ms: Double, what: String)] = []

        var summary: String {
            let list = events.prefix(14).map { String(format: "%.0f мс %@", $0.ms, $0.what) }.joined(separator: "; ")
            return String(format: "%@: первый кадр %.0f мс, успокоился %.0f мс, сдвиг %.3f (%d раз, строк %d), "
                          + "перекраска %d раз (%d симв.), счётчики %d, неверно %d из %d симв. — %@",
                          file, firstMs, settledMs, shiftScore, shifts, movedLines, recolors, recoloredChars,
                          lensChanges, wrongChars, chars, list)
        }
    }

    private weak var controller: CodeViewController?
    private var observer: CFRunLoopObserver?
    private var began: UInt64 = 0
    private var previous: EditorFrame?
    private var palette: [NSColor] = []
    private var report = Report()
    private var lastChange: UInt64 = 0
    private var logTimer: Timer?

    /// Снимать кадры: в замере — только в своём сценарии, иначе кадр на
    /// каждом витке лёг бы в чужие числа; в логе — всегда.
    var isArmed = false

    /// Редактор показал буфер — новый отсчёт.
    func shown(_ controller: CodeViewController) {
        guard isArmed || logs else { return }
        if logs, previous != nil { finishAndLog() }
        self.controller = controller
        began = PerfCounters.now()
        lastChange = began
        previous = nil
        report = Report(file: controller.shownBuffer?.url.lastPathComponent ?? "?")
        install()
        if logs { scheduleLog() }
    }

    /// Мс с последнего изменения на экране; nil — ещё не было первого кадра.
    var quietMs: Double? {
        previous == nil ? nil : Double(PerfCounters.now() - lastChange) / 1e6
    }

    /// Итог с проверкой цветов по последнему кадру. Отсчёт на этом кончается.
    func finish() -> Report {
        tick()
        var result = report
        if let controller, let frame = previous {
            for (line, shown) in frame.lines {
                guard let expected = controller.expectedColors(line: line, colors: palette),
                      expected.count == shown.colors.count else { continue }
                let wrong = zip(expected, shown.colors).filter { $0.0 != 255 && $0.0 != $0.1 }.count
                if wrong > 0, result.wrongChars == 0 {
                    // Первая неверная строка — чтобы было видно, что не так.
                    func names(_ colors: [UInt8]) -> String {
                        colors.map { $0 == 255 ? "_" : $0 == 254 ? "?" : String($0, radix: 36) }.joined()
                    }
                    result.events.append((0, "неверно в строке \(line + 1): экран \(names(shown.colors)) "
                                          + "ожидалось \(names(expected)); палитра "
                                          + palette.enumerated().map { "\($0.offset + 1)=\($0.element)" }
                                              .joined(separator: " ")))
                }
                result.wrongChars += wrong
                result.chars += shown.colors.lazy.filter { $0 != 255 }.count
            }
            result.lines = frame.lines.count
        }
        previous = nil
        controller = nil
        return result
    }

    private func install() {
        guard observer == nil else { return }
        let created = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                         true, Int.max) { _, _ in
            MainActor.assumeIsolated { EditorStability.shared?.tick() }
        }
        observer = created
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
    }

    private var ticking = false

    private func tick() {
        guard !ticking, let controller else { return }
        ticking = true
        defer { ticking = false }
        guard let frame = controller.stabilityFrame(colors: &palette) else { return }
        let now = PerfCounters.now()
        let ms = Double(now - began) / 1e6
        report.frames += 1
        guard let before = previous, before.buffer == frame.buffer else {
            if previous == nil { report.firstMs = ms }
            previous = frame
            return
        }
        previous = frame

        var moved = 0, dy: CGFloat = 0, dx: CGFloat = 0, recolored = 0, lens: [String] = []
        for (line, now) in frame.lines {
            guard let was = before.lines[line], was.text == now.text else { continue }
            let vertical = abs(now.y - was.y), horizontal = max(abs(now.left - was.left), abs(now.endX - was.endX))
            if vertical > 0.5 || horizontal > 0.5 {
                moved += 1
                dy = max(dy, vertical)
                dx = max(dx, horizontal)
            }
            if was.colors.count == now.colors.count {
                for (a, b) in zip(was.colors, now.colors) where a != b && a != 255 && b != 255 { recolored += 1 }
            }
            if was.lens != now.lens {
                lens.append("\(line + 1): \(was.lens ?? "—") → \(now.lens ?? "—")")
            }
        }
        guard moved > 0 || recolored > 0 || !lens.isEmpty else { return }
        lastChange = now
        report.settledMs = ms
        var what: [String] = []
        if moved > 0 {
            let impact = Double(moved) / Double(max(1, frame.lines.count))
            let distance = max(Double(dy / max(1, frame.height)), Double(dx / max(1, frame.width)))
            report.shiftScore += impact * distance
            report.shifts += 1
            report.movedLines += moved
            what.append(String(format: "сдвиг %d строк на %.0f/%.0f pt", moved, dy, dx))
        }
        if recolored > 0 {
            report.recolors += 1
            report.recoloredChars += recolored
            what.append("перекраска \(recolored) симв.")
        }
        if !lens.isEmpty {
            report.lensChanges += lens.count
            what.append("счётчики \(lens.count) (\(lens.prefix(2).joined(separator: ", ")))")
        }
        report.events.append((ms, what.joined(separator: ", ")))
    }

    // MARK: - Лог в обычной работе

    /// Итог — когда экран 3 с не менялся, или при показе следующего файла.
    private func scheduleLog() {
        logTimer?.invalidate()
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let stability = EditorStability.shared, let quiet = stability.quietMs, quiet > 3000 else { return }
                stability.finishAndLog()
            }
        }
    }

    private func finishAndLog() {
        logTimer?.invalidate()
        logTimer = nil
        let result = finish()
        NSLog("[stability] %@", result.summary)
    }
}
