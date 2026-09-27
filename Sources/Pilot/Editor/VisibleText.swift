import AppKit

extension NSTextView {
    /// Символы, которые сейчас на экране — в границах клипа, — по разложенному
    /// тексту, а не по оценке.
    ///
    /// Раскладка у редактора ленивая (`allowsNonContiguousLayout`): пока
    /// место не разложено, `glyphRange(forBoundingRect:)` отвечает оценкой
    /// по числу символов, а отрисовка потом раскладывает его по-своему. После
    /// прыжка бегунком в большом файле они расходились на сотни строк —
    /// красились одни строки, а на экране оказывались другие, без цвета, пока
    /// текст не сдвинут снова.
    ///
    /// Поэтому видимое раскладывается здесь же и тем же прямоугольником, каким
    /// его спросит отрисовка, — в координатах контейнера. Даже сдвиг на отступ
    /// текста раскладывает его иначе: отрисовке пришлось бы доложить полоску
    /// сверху, и на экране снова оказались бы другие строки. Лишней работы
    /// нет — отрисовка всё равно разложила бы видимое перед тем, как рисовать.
    ///
    /// Раскладка уточняет высоту текста, и клип от этого сдвигается — тогда
    /// видимое спрашивается заново, пока клип не встанет.
    func charactersOnScreen() -> NSRange? {
        guard let layout = layoutManager, let container = textContainer,
              let clip = enclosingScrollView?.contentView else { return nil }
        var characters: NSRange?
        var asked = NSRect.null
        for _ in 0..<4 where clip.bounds != asked {
            asked = clip.bounds
            let origin = textContainerOrigin
            // По горизонтали — от начала строк: экран, прокрученный вправо, не
            // должен терять короткие строки, до которых прямоугольник не достаёт.
            let area = NSRect(x: 0, y: asked.minY - origin.y,
                              width: max(0, asked.maxX - origin.x), height: asked.height)
            layout.ensureLayout(forBoundingRect: area, in: container)
            let glyphs = layout.glyphRange(forBoundingRect: area, in: container)
            characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }
        return characters
    }
}
