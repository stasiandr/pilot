import Foundation

/// Двойное нажатие Shift, как в JetBrains.
///
/// Считаются только «чистые» нажатия: Shift нажат и отпущен сам по себе,
/// без других клавиш и модификаторов. Иначе поиск выпрыгивал бы посреди
/// набора заглавных букв или на ⌘⇧O.
///
/// AppKit здесь нет — только время и состояние модификаторов, поэтому
/// логика проверяется тестами ядра.
struct DoubleShiftDetector {
    /// Дольше — это уже не нажатие, а удержание.
    static let maxHold: TimeInterval = 0.35
    /// Сколько можно ждать второго нажатия после первого.
    static let maxGap: TimeInterval = 0.4

    private var pressedAt: TimeInterval?
    private var lastTapAt: TimeInterval?

    /// Сменилось состояние модификаторов. `shiftOnly` — зажат ровно Shift,
    /// `none` — не зажато ничего. Возвращает true, когда случилось ⇧⇧.
    mutating func modifiersChanged(shiftOnly: Bool, none: Bool, at time: TimeInterval) -> Bool {
        if shiftOnly {
            if let last = lastTapAt, time - last > Self.maxGap { lastTapAt = nil }
            pressedAt = time
            return false
        }
        // Добавился другой модификатор, или отпустили что-то, кроме Shift.
        guard none, let pressed = pressedAt else { reset(); return false }

        pressedAt = nil
        guard time - pressed <= Self.maxHold else { lastTapAt = nil; return false }
        if lastTapAt != nil {
            lastTapAt = nil
            return true
        }
        lastTapAt = time
        return false
    }

    /// Нажата обычная клавиша — последовательность прерывается.
    mutating func keyPressed() { reset() }

    mutating func reset() {
        pressedAt = nil
        lastTapAt = nil
    }
}
