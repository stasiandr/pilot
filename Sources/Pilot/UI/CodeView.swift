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
    /// Коммит, из которого взят текст; nil — файл с диска. Ревью MR
    /// показывает файл в версии MR, и она может не совпадать с рабочей копией.
    var revision: String? = nil

    /// Один и тот же файл в разных версиях — разные документы.
    var identity: String { revision.map { "\(url.path)@\($0)" } ?? url.path }

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

    static func load(url: URL) throws -> LoadedDocument {
        make(url: url, text: try readText(url: url, maxBytes: maxBytes), revision: nil)
    }

    /// Файл из коммита — для ревью MR: те же проверки, что и с диска.
    static func make(url: URL, data: Data, revision: String?) throws -> LoadedDocument {
        make(url: url, text: try decodeText(data, maxBytes: maxBytes), revision: revision)
    }

    private static func make(url: URL, text: String, revision: String?) -> LoadedDocument {
        let spec = Languages.detect(filename: url.lastPathComponent)
        let model = SyntaxModel(text: text, spec: spec)
        let outline = OutlineBuilder.build(model: model)
        return LoadedDocument(url: url, text: text, model: model,
                              languageName: spec?.name ?? "Plain Text",
                              outline: outline, revision: revision)
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
        return try decodeText(data, maxBytes: maxBytes)
    }

    private static func decodeText(_ data: Data, maxBytes: Int) throws -> String {
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

    // MARK: Контекстное меню

    /// Задан — в меню текста появляется «Комментировать строку».
    var onCommentLine: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onCommentLine != nil else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let item = NSMenuItem(title: "Комментировать строку…", action: #selector(commentFromMenu(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = index
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func commentFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onCommentLine?(index)
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
    /// Клик по номеру строки — показать, что с ней: удалённое, треды ревью.
    var onLineClick: ((Int) -> Void)? {
        didSet { if isViewLoaded { applyLineHandlers() } }
    }
    /// «Комментировать строку» в меню текста; nil — пункта нет.
    var onCommentLine: ((Int) -> Void)? {
        didSet { if isViewLoaded { applyLineHandlers() } }
    }

    /// Обработчики приходят из SwiftUI и до создания вьюх, и после.
    private func applyLineHandlers() {
        ruler?.onLineClick = onLineClick
        textView.onCommentLine = onCommentLine.map { handler in
            { [weak self] offset in
                guard let self, let model = self.model else { return }
                handler(model.line(containing: min(offset, max(0, model.units.count - 1))))
            }
        }
    }
    private let scrollView = CodeScrollView()
    private var popover: NSPopover?
    private var textView: CodeTextView!
    private var ruler: LineNumberRuler?

    private var model: SyntaxModel?
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
        applyLineHandlers()

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
        closePopover()
        model = doc.model
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
        ruler?.currentLine = 0
        ruler?.invalidateWidth()
        highlightVisible()
        textView.updateCurrentLineHighlight()
    }

    func showEmpty() {
        closePopover()
        model = nil
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        ruler?.model = nil
        ruler?.setChanges([])
        ruler?.setCommentMarks([:], column: false)
    }

    /// Отличия от HEAD — полосками в колонке номеров.
    func setLineChanges(_ changes: [LineDiff.Change]) {
        ruler?.setChanges(changes)
    }

    /// Треды ревью — значками у строк. `column` оставляет под них место
    /// и тогда, когда тредов ещё нет: иначе гаттер дёргался бы от первого.
    func setCommentMarks(_ marks: [Int: CommentMark], column: Bool) {
        ruler?.setCommentMarks(marks, column: column)
    }

    // MARK: Всплывающее окно у строки

    /// Окно рядом с номером строки: что было удалено, треды, новый комментарий.
    func presentPopover(line: Int, content: AnyView) {
        closePopover()
        guard let ruler, let rect = ruler.rect(forLine: line) else { return }
        scrollLineIntoView(line)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        // Прямоугольник считаем заново: прокрутка могла сдвинуть строку.
        popover.show(relativeTo: ruler.rect(forLine: line) ?? rect, of: ruler, preferredEdge: .maxX)
        self.popover = popover
    }

    func closePopover() {
        popover?.close()
        popover = nil
    }

    private func scrollLineIntoView(_ line: Int) {
        guard let model, line < model.lineCount else { return }
        let start = Int(model.lineStarts[line])
        textView.scrollRangeToVisible(NSRange(location: start, length: 0))
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
        ruleThickness = CGFloat(digits) * 8.0 + 20 + (hasCommentColumn ? Self.commentColumn : 0)
        needsDisplay = true
    }

    // MARK: Треды ревью

    /// Слева от номеров — место под значок треда.
    private static let commentColumn: CGFloat = 16
    private var hasCommentColumn = false
    private var commentMarks: [Int: CommentMark] = [:]
    var onLineClick: ((Int) -> Void)?

    func setCommentMarks(_ marks: [Int: CommentMark], column: Bool) {
        guard marks != commentMarks || column != hasCommentColumn else { return }
        commentMarks = marks
        if column != hasCommentColumn {
            hasCommentColumn = column
            invalidateWidth()
        }
        needsDisplay = true
    }

    private func drawCommentMark(_ mark: CommentMark, top: CGFloat, height: CGFloat) {
        let symbol = mark.open ? "text.bubble.fill" : "checkmark.bubble"
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let tint = mark.open ? Theme.reviewThread : Theme.gutterText
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        let origin = NSPoint(x: 3, y: top + (height - size.height) / 2)
        tinted.draw(in: NSRect(origin: origin, size: size))
    }

    /// Где на линейке строка — для клика и для стрелки всплывающего окна.
    func rect(forLine line: Int) -> NSRect? {
        guard let textView, let layout = textView.layoutManager, let model,
              line >= 0, line < model.lineCount else { return nil }
        let start = Int(model.lineStarts[line])
        let lineRect: NSRect
        if start >= (textView.textStorage?.length ?? 0) {
            lineRect = layout.extraLineFragmentRect
        } else {
            lineRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start),
                                               effectiveRange: nil)
        }
        let origin = convert(NSPoint.zero, from: textView)
        let y = origin.y + textView.textContainerInset.height + lineRect.minY
        return NSRect(x: 0, y: y, width: ruleThickness, height: max(lineRect.height, 1))
    }

    override func mouseDown(with event: NSEvent) {
        guard let onLineClick, let line = line(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onLineClick(line)
    }

    private func line(at point: NSPoint) -> Int? {
        guard let textView, let layout = textView.layoutManager,
              let container = textView.textContainer, let model, model.lineCount > 0 else { return nil }
        let inText = textView.convert(point, from: self)
        let y = inText.y - textView.textContainerInset.height
        guard y >= 0 else { return nil }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        let char = layout.characterIndexForGlyph(at: glyph)
        let line = model.line(containing: min(char, max(0, model.units.count - 1)))
        // Ниже последней строки клик ничего не значит.
        guard let rect = rect(forLine: line), point.y <= rect.maxY + 2 else { return nil }
        return line
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
            if line < marks.count, marks[line] != 0 {
                drawMark(marks[line], top: y, height: lineRect.height)
            }
            if hasCommentColumn, let mark = commentMarks[line] {
                drawCommentMark(mark, top: y, height: lineRect.height)
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

/// Значок треда ревью у строки: открытый ярче, решённый — приглушён.
struct CommentMark: Equatable {
    var count: Int
    var open: Bool
}

// MARK: - Мост в SwiftUI

struct CodeView: NSViewControllerRepresentable {
    let document: LoadedDocument?
    let fontSize: CGFloat
    let reveal: Workspace.RevealRequest?
    let occurrences: [NSRange]
    let lineChanges: [LineDiff.Change]
    var commentMarks: [Int: CommentMark] = [:]
    /// Документ из ревью: под значки тредов в гаттере всегда есть место.
    var isReview = false
    var popover: Workspace.LinePopoverRequest? = nil
    var popoverContent: (Workspace.LinePopoverRequest) -> AnyView? = { _ in nil }
    let focusRequest: Int
    let onCaretChange: (Int) -> Void
    let onGoToDefinition: (Int) -> Void
    var onLineClick: ((Int) -> Void)? = nil
    var onCommentLine: ((Int) -> Void)? = nil

    func makeNSViewController(context: Context) -> CodeViewController {
        let controller = CodeViewController()
        controller.onCaretChange = onCaretChange
        controller.onGoToDefinition = onGoToDefinition
        controller.onLineClick = onLineClick
        controller.onCommentLine = onCommentLine
        return controller
    }

    func updateNSViewController(_ controller: CodeViewController, context: Context) {
        controller.onCaretChange = onCaretChange
        controller.onGoToDefinition = onGoToDefinition
        controller.onLineClick = onLineClick
        controller.onCommentLine = onCommentLine

        var documentChanged = false
        if let document {
            if context.coordinator.shownDocument != document.identity {
                context.coordinator.shownDocument = document.identity
                controller.show(document)
                documentChanged = true
            }
        } else if context.coordinator.shownDocument != nil {
            context.coordinator.shownDocument = nil
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

        if documentChanged || context.coordinator.commentMarks != commentMarks
            || context.coordinator.isReview != isReview {
            context.coordinator.commentMarks = commentMarks
            context.coordinator.isReview = isReview
            controller.setCommentMarks(commentMarks, column: isReview)
        }

        // Окно у строки — тоже по номеру запроса, один раз. После смены
        // документа — на следующем витке, когда текст уже разложен.
        if let popover, popover.seq != context.coordinator.appliedPopover {
            context.coordinator.appliedPopover = popover.seq
            if let content = popoverContent(popover) {
                if documentChanged {
                    DispatchQueue.main.async { controller.presentPopover(line: popover.line, content: content) }
                } else {
                    controller.presentPopover(line: popover.line, content: content)
                }
            }
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
        var shownDocument: String?
        var fontSize: CGFloat = 12.5
        var appliedReveal: Int = -1
        var lineChanges: [LineDiff.Change] = []
        var commentMarks: [Int: CommentMark] = [:]
        var isReview = false
        var appliedPopover = 0
        var occurrenceSignature: Int = 0
        var appliedFocus: Int = 0
    }
}
