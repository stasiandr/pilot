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

        let text: String
        if let s = String(data: data, encoding: .utf8) {
            text = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            text = s   // фолбэк, чтобы не падать на legacy-кодировках
        } else {
            throw LoadError.binary
        }

        let spec = Languages.detect(filename: url.lastPathComponent)
        let model = SyntaxModel(text: text, spec: spec)
        let outline = OutlineBuilder.build(model: model)
        return LoadedDocument(url: url, text: text, model: model,
                              languageName: spec?.name ?? "Plain Text",
                              outline: outline)
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Не перехватываем Cmd+P и Cmd+F — их обрабатывает окно.
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "p" || key == "o" { return false }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class CodeViewController: NSViewController, NSTextViewDelegate {

    /// Курсор поехал — обновляем позицию, от неё зависят все запросы к LSP.
    var onCaretChange: ((Int) -> Void)?
    /// ⌘+клик по символу.
    var onGoToDefinition: ((Int) -> Void)?
    private let scrollView = NSScrollView()
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
    private func scrollCentering(_ range: NSRange) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            textView.scrollRangeToVisible(range)
            return
        }
        let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.y += textView.textContainerInset.height

        let visibleHeight = scrollView.contentView.bounds.height
        let targetY = max(0, rect.midY - visibleHeight / 3)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
        ruler?.invalidateWidth()
        highlightVisible()
    }

    func showEmpty() {
        model = nil
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

        var line = firstLine
        while line < model.lineCount {
            let lineStart = Int(model.lineStarts[line])
            if lineStart > NSMaxRange(charRange) { break }

            let glyphIdx = layout.glyphIndexForCharacter(at: lineStart)
            var effective = NSRange()
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &effective)

            let y = origin.y + inset + lineRect.minY
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8,
                                   y: y + (lineRect.height - size.height) / 2),
                       withAttributes: attrs)
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

        var documentChanged = false
        if let document {
            if context.coordinator.shownURL != document.url {
                context.coordinator.shownURL = document.url
                controller.show(document)
                documentChanged = true
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
    }
}
