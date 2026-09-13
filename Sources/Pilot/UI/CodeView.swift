import SwiftUI
import AppKit

// MARK: - Загрузка файла

struct LoadedDocument: Sendable {
    let url: URL
    let text: String
    let model: SyntaxModel
    let languageName: String
    /// Структура файла для навигации. Строится здесь же, в фоне.
    let outline: [OutlineItem]
    /// Сцена, префаб или другой сериализованный ассет Unity — разобранный.
    var unityFile: UnityYAMLFile? = nil
    /// Растёт при повторном разборе того же файла — вьюхе пора перекрасить.
    var revision = 0
    /// Растёт, когда меняется сам текст (правка из инспектора): вьюха
    /// подменяет содержимое, не сбрасывая прокрутку.
    var edition = 0
    /// Когда файл менялся на диске на момент чтения. Перед записью сверяемся:
    /// если Unity успел его пересохранить, наша правка легла бы поверх чужой.
    var modificationDate: Date? = nil

    enum LoadError: Error, LocalizedError {
        case tooLarge(Int)
        case binary
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return "Файл слишком большой (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
            case .binary:
                return "Бинарный файл — предпросмотр недоступен"
            case .unreadable(let why):
                return "Не удалось прочитать файл: \(why)"
            }
        }
    }

    /// Порог, после которого просмотр отключается. 64 МБ — заведомо больше
    /// любого исходника; такие файлы в репозитории почти всегда бинарные.
    static let maxBytes = 64 * 1024 * 1024

    static func load(url: URL, unity: UnityContext? = nil) throws -> LoadedDocument {
        let text = try readText(url: url, maxBytes: maxBytes)
        var document = make(url: url, text: text, unity: unity)
        document.modificationDate = modificationDate(of: url)
        return document
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Документ из уже известного текста — например, после правки из инспектора.
    static func make(url: URL, text: String, unity: UnityContext?) -> LoadedDocument {
        let spec = Languages.detect(filename: url.lastPathComponent)
        let model = SyntaxModel(text: text, spec: spec)
        let outline = OutlineBuilder.build(model: model)
        let semantics = UnitySemantics.analyze(model: model, lexicalOutline: outline, context: unity)
        return LoadedDocument(url: url, text: text, model: model,
                              languageName: spec?.name ?? "Plain Text",
                              outline: semantics?.outline ?? outline,
                              unityFile: semantics?.serialized)
    }

    /// Тот же документ, заново осмысленный: индекс ассетов Unity
    /// дособрался, и у скриптов в сцене появились имена.
    func reanalyzed(unity: UnityContext?) -> LoadedDocument {
        guard let semantics = UnitySemantics.analyze(
            model: model, lexicalOutline: OutlineBuilder.build(model: model), context: unity) else { return self }
        return LoadedDocument(url: url, text: text, model: model, languageName: languageName,
                              outline: semantics.outline, unityFile: semantics.serialized,
                              revision: revision + 1, edition: edition,
                              modificationDate: modificationDate)
    }

    /// Текст файла с теми же проверками, что и при открытии: размер,
    /// бинарность, кодировка. Нужен и предпросмотру в палитре.
    static func readText(url: URL, maxBytes: Int) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        if data.count > maxBytes { throw LoadError.tooLarge(data.count) }

        // Эвристика бинарности: NUL в первых 8 КБ.
        let probe = data.prefix(8192)
        if probe.contains(0) { throw LoadError.binary }

        if let s = String(data: data, encoding: .utf8) { return s }
        // фолбэк, чтобы не падать на legacy-кодировках
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw LoadError.binary
    }
}

// MARK: - Украшения поверх подсветки

/// Смысловая разметка поверх лексической подсветки: ссылка на ассет,
/// битая ссылка, метод-сообщение Unity. Считается, как и подсветка,
/// только для видимых строк.
struct TextDecoration {
    var range: NSRange
    var color: NSColor? = nil
    var underline = false
    var toolTip: String? = nil
}

/// Документ и видимый диапазон → украшения.
typealias CodeDecorator = (LoadedDocument, NSRange) -> [TextDecoration]

// MARK: - NSTextView с подсветкой только видимой области

final class CodeTextView: NSTextView {
    /// ⌘+клик по символу — переход к определению.
    var onCommandClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if index >= 0, index <= (textStorage?.length ?? 0) {
            onCommandClick?(index)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Курсор-палец под ⌘ намекает, что по символу можно провалиться.
        if NSEvent.modifierFlags.contains(.command) {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    // MARK: Текущая строка

    /// Где полоса текущей строки нарисована сейчас — чтобы при смене строки
    /// перерисовать только две полосы, а не весь экран.
    private var currentLineRect: NSRect?

    /// Полоса под строкой с курсором на всю ширину, как в Xcode.
    /// При выделении через несколько строк не рисуется — там она только мешает.
    func lineHighlightRect() -> NSRect? {
        guard let layout = layoutManager, let storage = textStorage else { return nil }
        let selection = selectedRange()
        let text = storage.string as NSString
        // Длинное выделение почти наверняка многострочное, а искать в нём
        // перевод строки на каждой отрисовке — лишняя работа.
        if selection.length > 4096 { return nil }
        if selection.length > 0,
           text.rangeOfCharacter(from: .newlines, options: [], range: selection).location != NSNotFound {
            return nil
        }

        var rect: NSRect
        let atEnd = selection.location >= storage.length
        if storage.length == 0 || (atEnd && text.character(at: storage.length - 1) == 0x0A) {
            // Курсор на пустой последней строке — у неё свой «лишний» фрагмент.
            rect = layout.extraLineFragmentRect
            if rect.isEmpty { return nil }
        } else {
            let glyph = layout.glyphIndexForCharacter(at: min(selection.location, storage.length - 1))
            rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        rect.origin.x = 0
        rect.origin.y += textContainerOrigin.y
        rect.size.width = max(bounds.width, visibleRect.maxX)
        return rect
    }

    /// Возвращает true, если полоса появилась или исчезла — тогда
    /// перерисовать надо и гаттер.
    @discardableResult
    func updateCurrentLineHighlight() -> Bool {
        let new = lineHighlightRect()
        guard new != currentLineRect else { return false }
        if let old = currentLineRect { setNeedsDisplay(old) }
        if let new { setNeedsDisplay(new) }
        let toggled = (new == nil) != (currentLineRect == nil)
        currentLineRect = new
        return toggled
    }

    /// Именно draw, а не drawBackground: при drawsBackground = false
    /// AppKit drawBackground не зовёт. Полоса рисуется до текста — под ним.
    ///
    /// Прямоугольник считаем здесь же, а не берём сохранённый: раскладка
    /// ленивая, и посчитанная заранее позиция строки бывает лишь оценкой,
    /// которая уезжает, когда строки выше раскладываются по-настоящему.
    override func draw(_ dirtyRect: NSRect) {
        currentLineRect = lineHighlightRect()
        if let line = currentLineRect, line.intersects(dirtyRect) {
            Theme.currentLine.setFill()
            line.intersection(dirtyRect).intersection(bounds).fill()
        }
        super.draw(dirtyRect)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Не перехватываем Cmd+P и Cmd+F — их обрабатывает окно.
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "p" || key == "o" { return false }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// На macOS 26 NSScrollView кладёт клип-вью под вертикальную линейку —
/// она «плавает» над текстом, и начало строк прячется за гаттером.
/// Возвращаем классическую раскладку: текст начинается справа от линейки.
final class CodeScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard rulersVisible, let ruler = verticalRulerView else { return }
        let edge = ruler.frame.maxX
        var clip = contentView.frame
        guard clip.minX < edge else { return }
        clip.size.width -= edge - clip.minX
        clip.origin.x = edge
        contentView.frame = clip
    }
}

final class CodeViewController: NSViewController, NSTextViewDelegate {

    /// Курсор поехал — обновляем позицию, от неё зависят все запросы к LSP.
    var onCaretChange: ((Int) -> Void)?
    /// ⌘+клик по символу.
    var onGoToDefinition: ((Int) -> Void)?
    private let scrollView = CodeScrollView()
    private var textView: CodeTextView!
    private var ruler: LineNumberRuler?

    private var model: SyntaxModel?
    private var document: LoadedDocument?
    /// Смысловые украшения; меняются вместе с `invalidateDecorations()`.
    var decorator: CodeDecorator?
    private var fontSize: CGFloat = 12.5
    private var isApplying = false
    private var lastHighlighted: ClosedRange<Int>?
    private var occurrences: [NSRange] = []

    override func loadView() {
        let font = Theme.editorFont(size: fontSize)

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // Критично для больших файлов: раскладка считается лениво,
        // иначе NSTextView разложит все глифы файла при открытии.
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false   // без переноса строк
        container.lineFragmentPadding = 6
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        // Контейнер передаём в инициализатор: replaceTextContainer на уже
        // готовом NSTextView оставляет висеть его собственный layout manager.
        textView = CodeTextView(frame: .zero, textContainer: container)
        textView.isEditable = false          // просмотрщик, но выделение и ⌘C работают
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = font
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.textContainerInset = NSSize(width: 4, height: 10)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self
        textView.onCommandClick = { [weak self] index in
            self?.onGoToDefinition?(index)
        }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        let ruler = LineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        self.ruler = ruler

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        self.view = scrollView
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func focusText() {
        view.window?.makeFirstResponder(textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if textView.updateCurrentLineHighlight() { ruler?.needsDisplay = true }
        if let model {
            ruler?.currentLine = model.line(containing: min(textView.selectedRange().location,
                                                            max(0, model.units.count - 1)))
        }
        onCaretChange?(textView.selectedRange().location)
    }

    /// Прокручивает к диапазону, выделяет его и коротко подсвечивает.
    /// Без вспышки после перехода глазами не найти, куда именно попал.
    func reveal(range: NSRange) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let location = max(0, min(range.location, storage.length))
        let length = max(0, min(range.length, storage.length - location))
        let safe = NSRange(location: location, length: length)

        textView.setSelectedRange(safe)
        scrollCentering(safe)
        flash(safe)
        onCaretChange?(location)
    }

    /// scrollRangeToVisible прижимает строку к краю окна; для перехода
    /// удобнее видеть её примерно на трети экрана сверху.
    ///
    /// Раскладка ленивая, и позиция далёкой строки до раскладки — лишь
    /// оценка: прокрутишь по ней, строки выше разложатся по-настоящему,
    /// и на экране окажется совсем другое место. Поэтому уточняем:
    /// прокрутили, разложили видимое, пересчитали — пара итераций сходится.
    private func scrollCentering(_ range: NSRange) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            textView.scrollRangeToVisible(range)
            return
        }
        let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let clip = scrollView.contentView
        for _ in 0..<4 {
            layout.ensureLayout(forGlyphRange: glyphRange)
            var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.y += textView.textContainerInset.height
            let targetY = max(0, rect.midY - clip.bounds.height / 3)
            if abs(clip.bounds.origin.y - targetY) < 1 { break }
            clip.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(clip)
            layout.ensureLayout(forBoundingRect: clip.bounds, in: container)
        }
        highlightVisible()
    }

    private func flash(_ range: NSRange) {
        guard range.length > 0, let storage = textView.textStorage else { return }
        flashToken += 1
        let token = flashToken
        storage.addAttribute(.backgroundColor,
                             value: NSColor.findHighlightColor.withAlphaComponent(0.55),
                             range: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.flashToken == token,
                  let storage = self.textView.textStorage,
                  NSMaxRange(range) <= storage.length else { return }
            storage.removeAttribute(.backgroundColor, range: range)
        }
    }

    private var flashToken = 0

    @objc private func viewportChanged() {
        highlightVisible()
        ruler?.needsDisplay = true
    }

    func show(_ doc: LoadedDocument) {
        guard let storage = textView.textStorage else { return }
        model = doc.model
        document = doc
        lastHighlighted = nil

        let font = Theme.editorFont(size: fontSize)
        isApplying = true
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(
            string: doc.text,
            attributes: [.font: font, .foregroundColor: Theme.color(.plain)]))
        storage.endEditing()
        isApplying = false

        textView.scroll(NSPoint(x: 0, y: 0))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        ruler?.model = doc.model
        ruler?.eventLines = Self.gutterMarkers(for: doc)
        ruler?.currentLine = 0
        ruler?.invalidateWidth()
        highlightVisible()
        textView.updateCurrentLineHighlight()
    }

    /// Тот же файл, новый текст — правка из инспектора. Прокрутку и
    /// выделение сохраняем: иначе после каждой правки экран прыгал бы в начало.
    func replaceContents(_ doc: LoadedDocument) {
        guard let storage = textView.textStorage else { return }
        let origin = scrollView.contentView.bounds.origin
        let selection = textView.selectedRange()
        model = doc.model
        document = doc
        lastHighlighted = nil

        isApplying = true
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(
            string: doc.text,
            attributes: [.font: Theme.editorFont(size: fontSize), .foregroundColor: Theme.color(.plain)]))
        storage.endEditing()
        isApplying = false

        let length = storage.length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        ruler?.model = doc.model
        ruler?.eventLines = Self.gutterMarkers(for: doc)
        ruler?.invalidateWidth()
        highlightVisible()
    }

    /// Тот же файл, новый разбор (например, дособрался индекс ассетов):
    /// текст и прокрутку не трогаем, только перекрашиваем.
    func refresh(_ doc: LoadedDocument) {
        document = doc
        ruler?.eventLines = Self.gutterMarkers(for: doc)
        ruler?.needsDisplay = true
        invalidateDecorations()
    }

    func invalidateDecorations() {
        lastHighlighted = nil
        highlightVisible()
    }

    /// Значки в колонке номеров: методы, которые вызывает движок.
    private static func gutterMarkers(for doc: LoadedDocument) -> Set<Int> {
        Set(doc.outline.lazy.filter { $0.kind == .unityMessage }.map(\.line))
    }

    func showEmpty() {
        model = nil
        document = nil
        ruler?.eventLines = []
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        ruler?.model = nil
        ruler?.setChanges([])
    }

    /// Отличия от HEAD — полосками в колонке номеров.
    func setLineChanges(_ changes: [LineDiff.Change]) {
        ruler?.setChanges(changes)
    }

    /// Вхождения красим не все сразу, а вместе с остальной подсветкой —
    /// то есть только в видимой области. Иначе на файле с тысячами
    /// совпадений каждый скролл упирался бы в применение атрибутов.
    func setOccurrences(_ ranges: [NSRange]) {
        occurrences = ranges
        lastHighlighted = nil
        highlightVisible()
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = max(8, min(32, size))
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let font = Theme.editorFont(size: fontSize)
        storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        lastHighlighted = nil
        ruler?.font = font
        ruler?.invalidateWidth()
        highlightVisible()
        textView.updateCurrentLineHighlight()
    }

    /// Красит только те строки, что попали в видимую область (+ запас).
    private func highlightVisible() {
        guard !isApplying,
              let model, model.spec != nil,
              let storage = textView.textStorage,
              let layout = textView.layoutManager,
              let container = textView.textContainer,
              storage.length > 0 else { return }

        let rect = scrollView.contentView.bounds
        let glyphRange = layout.glyphRange(forBoundingRect: rect, in: container)
        let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }

        let pad = 40   // запас строк сверху и снизу, чтобы скролл был плавным
        let firstLine = max(0, model.line(containing: charRange.location) - pad)
        let lastLine = min(model.lineCount - 1,
                           model.line(containing: min(NSMaxRange(charRange), model.units.count - 1)) + pad)
        guard firstLine <= lastLine else { return }

        // Уже покрашено — второй раз не тратимся.
        if let last = lastHighlighted, last.contains(firstLine), last.contains(lastLine) { return }

        let start = Int(model.lineStarts[firstLine])
        let end = lastLine + 1 < model.lineCount ? Int(model.lineStarts[lastLine + 1]) : storage.length
        let range = NSRange(location: start, length: max(0, min(end, storage.length) - start))
        guard range.length > 0 else { return }

        let tokens = model.tokens(fromLine: firstLine, toLine: lastLine)

        isApplying = true
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: Theme.color(.plain), range: range)
        for t in tokens {
            let r = NSRange(location: Int(t.start), length: Int(t.length))
            guard r.location >= 0, NSMaxRange(r) <= storage.length, r.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: Theme.color(t.kind), range: r)
        }
        storage.removeAttribute(.backgroundColor, range: range)
        storage.removeAttribute(.underlineStyle, range: range)
        storage.removeAttribute(.toolTip, range: range)
        if let decorator, let document {
            for d in decorator(document, range) {
                guard d.range.length > 0, NSMaxRange(d.range) <= storage.length else { continue }
                if let color = d.color { storage.addAttribute(.foregroundColor, value: color, range: d.range) }
                if d.underline {
                    storage.addAttribute(.underlineStyle,
                                         value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                         range: d.range)
                }
                if let tip = d.toolTip { storage.addAttribute(.toolTip, value: tip, range: d.range) }
            }
        }
        for occurrence in occurrences {
            guard NSIntersectionRange(occurrence, range).length > 0,
                  NSMaxRange(occurrence) <= storage.length else { continue }
            storage.addAttribute(.backgroundColor,
                                 value: Theme.occurrenceHighlight, range: occurrence)
        }
        storage.endEditing()
        isApplying = false

        lastHighlighted = firstLine...lastLine
    }
}

// MARK: - Колонка с номерами строк

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var model: SyntaxModel?
    var font: NSFont = Theme.editorFont(size: 11)
    /// Строки со значком слева от номера — методы-сообщения Unity.
    var eventLines: Set<Int> = []
    private lazy var markerImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(.init(paletteColors: [Theme.unityEvent]))
        return NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Сообщение Unity")?
            .withSymbolConfiguration(config)
    }()
    /// Строка с курсором: её номер ярче, а полоса продолжается в гаттер.
    var currentLine = 0 {
        didSet { if currentLine != oldValue { needsDisplay = true } }
    }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) { fatalError() }

    func invalidateWidth() {
        let digits = max(3, String(model?.lineCount ?? 0).count)
        ruleThickness = CGFloat(digits) * 8.0 + 20
        needsDisplay = true
    }

    /// Фон — как у редактора, без системной разделительной линии:
    /// у Xcode гаттер и текст на одной подложке.
    ///
    /// Заливаем строго свои границы: с macOS 14 виды по умолчанию не
    /// обрезаются по bounds, и dirtyRect бывает шире линейки — залив его
    /// целиком, гаттер закрасил бы и текст, и соседние SwiftUI-виды.
    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        Theme.editorBackground.setFill()
        rect.fill()
        drawHashMarksAndLabels(in: rect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layout = textView.layoutManager,
              let container = textView.textContainer,
              let model else { return }

        let visible = scrollView?.contentView.bounds ?? rect
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard model.lineCount > 0 else { return }

        let firstLine = model.line(containing: charRange.location)
        let inset = textView.textContainerInset.height
        // Правильный перевод координат текста в координаты линейки:
        // вычитание visible.minY даёт рассинхрон при overscroll.
        let origin = self.convert(NSPoint.zero, from: textView)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.gutterText,
        ]
        let currentAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.gutterTextCurrent,
        ]
        // Полоса текущей строки та же, что в тексте, — продолжаем её в гаттер.
        let highlight = (textView as? CodeTextView)?.lineHighlightRect()

        var line = firstLine
        while line < model.lineCount {
            let lineStart = Int(model.lineStarts[line])
            if lineStart > NSMaxRange(charRange) { break }

            let glyphIdx = layout.glyphIndexForCharacter(at: lineStart)
            var effective = NSRange()
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &effective)

            let y = origin.y + inset + lineRect.minY
            let isCurrent = line == currentLine
            if isCurrent, highlight != nil {
                Theme.currentLine.setFill()
                NSRect(x: 0, y: y, width: ruleThickness, height: lineRect.height).fill()
            }
            let label = String(line + 1) as NSString
            let labelAttrs = isCurrent ? currentAttrs : attrs
            let size = label.size(withAttributes: labelAttrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8,
                                   y: y + (lineRect.height - size.height) / 2),
                       withAttributes: labelAttrs)
            if eventLines.contains(line), let image = markerImage {
                let side = image.size
                image.draw(in: NSRect(x: 4, y: y + (lineRect.height - side.height) / 2,
                                      width: side.width, height: side.height))
            }
            if line < marks.count, marks[line] != 0 {
                drawMark(marks[line], top: y, height: lineRect.height)
            }
            line += 1
        }
    }

    // MARK: Отличия от HEAD

    /// Пометки по строкам, битами `Mark`. Плотный массив, а не список
    /// блоков: при отрисовке — одно обращение по индексу на видимую строку.
    private var marks: [UInt8] = []

    private enum Mark {
        static let added: UInt8 = 1
        static let modified: UInt8 = 2
        static let deletedAbove: UInt8 = 4
        static let deletedBelow: UInt8 = 8   // удалено после последней строки
    }

    func setChanges(_ changes: [LineDiff.Change]) {
        let count = model?.lineCount ?? 0
        guard !changes.isEmpty, count > 0 else {
            if !marks.isEmpty { marks = []; needsDisplay = true }
            return
        }
        var fresh = [UInt8](repeating: 0, count: count)
        for change in changes {
            switch change.kind {
            case .added, .modified:
                let bit = change.kind == .added ? Mark.added : Mark.modified
                for line in change.lines where line < count { fresh[line] |= bit }
            case .deleted:
                if change.lines.lowerBound < count {
                    fresh[change.lines.lowerBound] |= Mark.deletedAbove
                } else {
                    fresh[count - 1] |= Mark.deletedBelow
                }
            }
        }
        marks = fresh
        needsDisplay = true
    }

    /// Полоска вплотную к тексту, как в VS Code; удаление — треугольник
    /// на стыке строк, между которыми что-то было.
    private func drawMark(_ mark: UInt8, top: CGFloat, height: CGFloat) {
        let x = ruleThickness - 4
        if mark & (Mark.added | Mark.modified) != 0 {
            (mark & Mark.added != 0 ? Theme.gitAdded : Theme.gitModified).setFill()
            NSRect(x: x, y: top, width: 3, height: height).fill()
        }
        for (bit, y) in [(Mark.deletedAbove, top), (Mark.deletedBelow, top + height)] where mark & bit != 0 {
            let wedge = NSBezierPath()
            wedge.move(to: NSPoint(x: x - 1, y: y - 4))
            wedge.line(to: NSPoint(x: x + 4, y: y))
            wedge.line(to: NSPoint(x: x - 1, y: y + 4))
            wedge.close()
            Theme.gitDeleted.setFill()
            wedge.fill()
        }
    }
}

// MARK: - Мост в SwiftUI

struct CodeView: NSViewControllerRepresentable {
    let document: LoadedDocument?
    let fontSize: CGFloat
    let reveal: Workspace.RevealRequest?
    let occurrences: [NSRange]
    let lineChanges: [LineDiff.Change]
    let focusRequest: Int
    /// Смысловые украшения и их версия: сменилась — перекрашиваем.
    var decorator: CodeDecorator? = nil
    var decorationsVersion: Int = 0
    let onCaretChange: (Int) -> Void
    let onGoToDefinition: (Int) -> Void

    func makeNSViewController(context: Context) -> CodeViewController {
        let controller = CodeViewController()
        controller.onCaretChange = onCaretChange
        controller.onGoToDefinition = onGoToDefinition
        return controller
    }

    func updateNSViewController(_ controller: CodeViewController, context: Context) {
        controller.onCaretChange = onCaretChange
        controller.onGoToDefinition = onGoToDefinition
        controller.decorator = decorator

        var documentChanged = false
        if let document {
            if context.coordinator.shownURL == document.url,
               context.coordinator.edition != document.edition {
                context.coordinator.edition = document.edition
                context.coordinator.revision = document.revision
                context.coordinator.decorationsVersion = decorationsVersion
                controller.replaceContents(document)
            } else if context.coordinator.shownURL != document.url {
                context.coordinator.shownURL = document.url
                context.coordinator.edition = document.edition
                context.coordinator.revision = document.revision
                context.coordinator.decorationsVersion = decorationsVersion
                controller.show(document)
                documentChanged = true
            } else if context.coordinator.revision != document.revision
                        || context.coordinator.decorationsVersion != decorationsVersion {
                context.coordinator.revision = document.revision
                context.coordinator.decorationsVersion = decorationsVersion
                controller.refresh(document)
            }
        } else if context.coordinator.shownURL != nil {
            context.coordinator.shownURL = nil
            controller.showEmpty()
        }

        if context.coordinator.fontSize != fontSize {
            context.coordinator.fontSize = fontSize
            controller.setFontSize(fontSize)
        }

        if documentChanged || context.coordinator.occurrenceSignature != occurrenceSignature {
            context.coordinator.occurrenceSignature = occurrenceSignature
            controller.setOccurrences(occurrences)
        }

        // Блоков изменений — единицы, сравнить массивы целиком дёшево.
        if documentChanged || context.coordinator.lineChanges != lineChanges {
            context.coordinator.lineChanges = lineChanges
            controller.setLineChanges(lineChanges)
        }

        // Переход применяем один раз на запрос; порядковый номер нужен,
        // чтобы повторный прыжок в то же место тоже сработал.
        if let reveal, let document, reveal.seq != context.coordinator.appliedReveal {
            context.coordinator.appliedReveal = reveal.seq
            let range = reveal.range.map { document.model.nsRange(for: $0) }
                ?? NSRange(location: 0, length: 0)
            // Документ только что заменён — даём раскладке дойти до конца.
            if documentChanged {
                DispatchQueue.main.async { controller.reveal(range: range) }
            } else {
                controller.reveal(range: range)
            }
        }

        if focusRequest != context.coordinator.appliedFocus {
            context.coordinator.appliedFocus = focusRequest
            // Вьюха могла только что появиться и ещё не попасть в окно.
            DispatchQueue.main.async { controller.focusText() }
        }
    }

    /// Дешёвая подпись набора вхождений: сравнивать массивы целиком
    /// на каждом обновлении вьюхи незачем.
    private var occurrenceSignature: Int {
        var hasher = Hasher()
        hasher.combine(occurrences.count)
        hasher.combine(occurrences.first?.location ?? -1)
        hasher.combine(occurrences.last?.location ?? -1)
        return hasher.finalize()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shownURL: URL?
        var fontSize: CGFloat = 12.5
        var appliedReveal: Int = -1
        var lineChanges: [LineDiff.Change] = []
        var occurrenceSignature: Int = 0
        var appliedFocus: Int = 0
        var revision = 0
        var edition = 0
        var decorationsVersion = 0
    }
}
