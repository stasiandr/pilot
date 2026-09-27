import AppKit

/// Подсветка редактора красит строки, которые `charactersOnScreen` назвала
/// видимыми. Раскладка у него ленивая, и после прыжка в неразложенную часть
/// большого файла оценка TextKit промахивалась на сотни строк: красились
/// одни строки, а рисовались другие, без цвета. Здесь — тот же текст-вид,
/// что у редактора, прыжки, как бегунком, и настоящая отрисовка в картинку:
/// всё нарисованное на экране должно быть среди названных строк.
///
/// Только на macOS: остальные тесты ядра гоняются и на Linux, без AppKit.
@MainActor
func runEditorLayoutTests() {
    section("Редактор: видимые строки после прыжка")

    final class DrawnGlyphs: NSLayoutManager {
        var drawn: [NSRange] = []
        override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
            drawn.append(characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil))
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        }
    }

    // Короткие строки кода: оценка по числу символов с ними врёт сильнее всего.
    let lines = (0..<20_000).map { $0 % 7 == 0 ? "    }" : "        var x\($0) = Foo(\($0));" }
    let text = lines.joined(separator: "\n")
    var starts = [0]
    for line in lines.dropLast() { starts.append(starts.last! + line.utf16.count + 1) }
    func line(of character: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= character { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // Как в CodeViewController.loadView.
    let storage = NSTextStorage(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)])
    let layout = DrawnGlyphs()
    layout.allowsNonContiguousLayout = true
    let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = false
    container.lineFragmentPadding = 6
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 900), textContainer: container)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.textContainerInset = NSSize(width: 4, height: 10)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
    scrollView.documentView = textView
    let clip = scrollView.contentView

    var missed = 0, jumps = 0
    var y: CGFloat = 3_000
    while y < 120_000 {
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        // Как highlightVisible по boundsDidChange: сразу после прокрутки, до отрисовки.
        guard let named = textView.charactersOnScreen() else {
            check(false, "видимые символы есть")
            return
        }
        let first = line(of: named.location), last = line(of: max(named.location, NSMaxRange(named) - 1))

        layout.drawn = []
        let visible = textView.visibleRect
        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: visible) else { return }
        textView.cacheDisplay(in: visible, to: bitmap)
        let origin = textView.textContainerOrigin
        var outside = 0
        for range in layout.drawn where range.length > 0 {
            for drawnLine in line(of: range.location)...line(of: NSMaxRange(range) - 1) {
                let glyph = layout.glyphIndexForCharacter(at: starts[drawnLine])
                let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil,
                                                       withoutAdditionalLayout: true)
                guard fragment.offsetBy(dx: origin.x, dy: origin.y).intersects(visible) else { continue }
                if drawnLine < first || drawnLine > last { outside += 1 }
            }
        }
        if outside > 0 { missed += 1 }
        jumps += 1
        y += 9_137
    }
    check(jumps > 10 && missed == 0, "после прыжков рисуются ровно названные строки (промахов \(missed) из \(jumps))")
}
