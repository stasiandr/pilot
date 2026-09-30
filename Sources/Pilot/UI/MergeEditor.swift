import SwiftUI
import AppKit

// Слияние, как в Rider: три редактора рядом — наша версия, результат, их
// версия, — с подсветкой, номерами строк и общей прокруткой. Изменения
// подсвечены по видам, соответствующие куски соединены лентами, на лентах —
// ≫ и ≪ (применить сторону) и × (оставить как было). Результат — обычный
// текст: его можно править где угодно, границы кусков едут вместе с правкой.

// MARK: - Модель

@MainActor
final class MergeEditorModel: ObservableObject {
    enum Side { case ours, theirs }

    /// Что стало с куском.
    enum State: Equatable {
        /// Никто не трогал.
        case stable
        /// Правка одной стороны (или одинаковая у обеих) — уже в результате.
        case applied
        /// Обе стороны по-разному — ждёт решения.
        case unresolved
        /// Решён: взяты стороны (обе — по порядку нажатия), оставлена база
        /// или поправлен руками.
        case resolved
    }

    struct Part {
        var chunk: Merge3.Chunk
        var state: State
        var ours: NSRange
        var theirs: NSRange
        var result: NSRange
        /// Какие стороны уже в результате — вторая добавляется после первой.
        var taken: [Side] = []

        var isChange: Bool { state != .stable }
    }

    let oursStorage = NSTextStorage()
    let theirsStorage = NSTextStorage()
    let resultStorage = NSTextStorage()
    @Published private(set) var parts: [Part] = []
    /// Растёт на каждое изменение кусков — виды перерисовывают подсветку и ленты.
    @Published private(set) var revision = 0
    /// Куда прокрутить: номер куска и счётчик запроса.
    @Published private(set) var reveal: (part: Int, seq: Int)?
    @Published private(set) var currentConflict: Int?
    let trailingNewline: Bool
    let spec: LanguageSpec?
    private var applyingProgrammatic = false
    private var revealSeq = 0

    init(chunks: [Merge3.Chunk], trailingNewline: Bool, fileName: String) {
        self.trailingNewline = trailingNewline
        spec = Languages.detect(filename: fileName)
        var ours = "", theirs = "", result = ""
        func block(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }
        for chunk in chunks {
            let o = block(chunk.ours), t = block(chunk.theirs), r = block(chunk.automatic)
            let state: State
            switch chunk.kind {
            case .stable: state = .stable
            case .changed: state = .applied
            case .conflict: state = .unresolved
            }
            parts.append(Part(chunk: chunk, state: state,
                              ours: NSRange(location: (ours as NSString).length, length: (o as NSString).length),
                              theirs: NSRange(location: (theirs as NSString).length, length: (t as NSString).length),
                              result: NSRange(location: (result as NSString).length, length: (r as NSString).length)))
            ours += o; theirs += t; result += r
        }
        let font = Theme.editorFont(size: 12)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.color(.plain)]
        oursStorage.setAttributedString(NSAttributedString(string: ours, attributes: plain))
        theirsStorage.setAttributedString(NSAttributedString(string: theirs, attributes: plain))
        resultStorage.setAttributedString(NSAttributedString(string: result, attributes: plain))
        for storage in [oursStorage, theirsStorage, resultStorage] { colorize(storage) }
        currentConflict = parts.firstIndex { $0.state == .unresolved }
    }

    var conflictCount: Int { parts.filter { $0.chunk.isConflict }.count }
    var unresolvedCount: Int { parts.filter { $0.state == .unresolved }.count }
    var changeCount: Int { parts.filter { $0.chunk.kind != .stable && !$0.chunk.isConflict }.count }

    /// Итоговый текст — как его запишем в файл.
    var resultText: String {
        var text = resultStorage.string
        if !trailingNewline, text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    // MARK: Решения

    /// ≫ или ≪: сторона в результат. Уже взята другая — эта добавляется
    /// после неё (обе), как в Rider.
    func apply(_ side: Side, to index: Int) {
        guard parts.indices.contains(index), parts[index].isChange, !parts[index].taken.contains(side) else { return }
        let part = parts[index]
        let source = side == .ours ? oursStorage : theirsStorage
        let range = side == .ours ? part.ours : part.theirs
        let text = (source.string as NSString).substring(with: range)
        // Первая сторона заменяет то, что в куске; вторая — дописывается после.
        let target = part.taken.isEmpty ? part.result : NSRange(location: NSMaxRange(part.result), length: 0)
        replaceResult(target, with: text, in: index)
        parts[index].taken.append(side)
        parts[index].state = .resolved
        changed()
        if part.state == .unresolved { moveToNextConflict(after: index) }
    }

    /// ×: оставить базу — ни одной из сторон.
    func ignore(_ index: Int) {
        guard parts.indices.contains(index), parts[index].isChange else { return }
        let base = parts[index].chunk.base.map { $0 + "\n" }.joined()
        let wasUnresolved = parts[index].state == .unresolved
        replaceResult(parts[index].result, with: base, in: index)
        parts[index].taken = []
        parts[index].state = .resolved
        changed()
        if wasUnresolved { moveToNextConflict(after: index) }
    }

    /// Волшебная палочка: то, что решается без человека.
    @discardableResult
    func resolveSimple() -> Int {
        var count = 0
        for index in parts.indices where parts[index].state == .unresolved {
            guard let lines = Merge3.autoResolve(parts[index].chunk) else { continue }
            replaceResult(parts[index].result, with: lines.map { $0 + "\n" }.joined(), in: index)
            parts[index].state = .resolved
            count += 1
        }
        if count > 0 { changed() }
        return count
    }

    /// «Принять левое / правое»: весь файл — одной стороной.
    func acceptAll(_ side: Side) {
        let storage = side == .ours ? oursStorage : theirsStorage
        applyingProgrammatic = true
        resultStorage.replaceCharacters(in: NSRange(location: 0, length: resultStorage.length), with: storage.string)
        applyingProgrammatic = false
        for index in parts.indices {
            parts[index].result = side == .ours ? parts[index].ours : parts[index].theirs
            if parts[index].isChange { parts[index].state = .resolved; parts[index].taken = [side] }
        }
        colorize(resultStorage)
        changed()
    }

    private func replaceResult(_ range: NSRange, with text: String, in index: Int) {
        applyingProgrammatic = true
        resultStorage.replaceCharacters(in: range, with: text)
        applyingProgrammatic = false
        // Заменяли внутри куска (весь или пустое место в конце) — он вырос на разницу.
        let delta = (text as NSString).length - range.length
        parts[index].result.length += delta
        for other in parts.indices where other > index {
            parts[other].result.location += delta
        }
        colorize(resultStorage)
    }

    /// Человек поправил результат: границы кусков едут, кусок, который
    /// правили, считается решённым.
    func resultEdited(_ edited: NSRange, delta: Int) {
        guard !applyingProgrammatic else { return }
        let oldEnd = NSMaxRange(edited) - delta
        let start = edited.location
        for index in parts.indices {
            var range = parts[index].result
            let end = NSMaxRange(range)
            if oldEnd < range.location || (oldEnd == range.location && range.length > 0 && start == oldEnd) {
                range.location += delta                              // правка выше куска
            } else if start > end || (start == end && range.length > 0) {
                continue                                             // ниже
            } else {
                let newStart = min(range.location, start)
                let newEnd = max(end + delta, NSMaxRange(edited))
                range = NSRange(location: newStart, length: max(0, newEnd - newStart))
                if parts[index].state == .unresolved { parts[index].state = .resolved }
            }
            parts[index].result = range
        }
        scheduleColorize()
        changed()
    }

    // MARK: Переходы

    func moveToNextConflict(after index: Int? = nil) {
        let start = index ?? currentConflict ?? -1
        let unresolved = parts.indices.filter { parts[$0].state == .unresolved }
        guard let next = unresolved.first(where: { $0 > start }) ?? unresolved.first else { return }
        select(next)
    }

    func moveToPreviousConflict() {
        let start = currentConflict ?? parts.count
        let unresolved = parts.indices.filter { parts[$0].state == .unresolved }
        guard let previous = unresolved.last(where: { $0 < start }) ?? unresolved.last else { return }
        select(previous)
    }

    func select(_ index: Int) {
        currentConflict = index
        revealSeq += 1
        reveal = (index, revealSeq)
    }

    private func changed() { revision &+= 1 }

    // MARK: Подсветка синтаксиса

    private var colorizePending = false

    private func scheduleColorize() {
        guard !colorizePending else { return }
        colorizePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.colorizePending = false
            self.colorize(self.resultStorage)
        }
    }

    /// Токены — тем же лексером, что в редакторе. Только цвет, текст не
    /// трогается, и границы кусков от этого не едут.
    func colorize(_ storage: NSTextStorage) {
        let text = storage.string
        let model = SyntaxModel(text: text, spec: spec)
        guard model.lineCount > 0 else { return }
        let tokens = model.colorKinds(model.tokens(fromLine: 0, toLine: model.lineCount - 1))
        let length = storage.length
        applyingProgrammatic = true
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: Theme.color(.plain), range: NSRange(location: 0, length: length))
        for token in tokens {
            let range = NSRange(location: Int(token.start), length: Int(token.length))
            guard NSMaxRange(range) <= length else { continue }
            storage.addAttribute(.foregroundColor, value: Theme.color(token.kind), range: range)
        }
        storage.endEditing()
        applyingProgrammatic = false
    }

    // MARK: Цвета

    enum Mark { case none, added, deleted, modified, conflict }

    /// Как подсвечен кусок в колонке: у стороны — что она сделала с базой,
    /// у результата — как у конфликта или у применённой стороны.
    func mark(of part: Part, in pane: Pane) -> Mark {
        if part.state == .stable { return .none }
        if part.chunk.isConflict { return .conflict }
        let lines: [String]
        switch pane {
        case .ours: lines = part.chunk.ours
        case .theirs: lines = part.chunk.theirs
        case .result: lines = part.chunk.automatic
        }
        if lines == part.chunk.base { return .none }
        if part.chunk.base.isEmpty { return .added }
        if lines.isEmpty { return .deleted }
        return .modified
    }

    enum Pane { case ours, result, theirs }

    func range(of part: Part, in pane: Pane) -> NSRange {
        switch pane {
        case .ours: return part.ours
        case .theirs: return part.theirs
        case .result: return part.result
        }
    }

    static func color(_ mark: Mark, faded: Bool) -> NSColor {
        let alpha: CGFloat = faded ? 0.08 : 0.22
        switch mark {
        case .none: return .clear
        case .added: return Theme.gitAdded.withAlphaComponent(alpha)
        case .deleted: return NSColor.systemGray.withAlphaComponent(faded ? 0.12 : 0.3)
        case .modified: return NSColor.systemBlue.withAlphaComponent(alpha)
        case .conflict: return NSColor.systemRed.withAlphaComponent(faded ? 0.10 : 0.26)
        }
    }
}

// MARK: - Вид

struct MergeEditor: NSViewRepresentable {
    @ObservedObject var model: MergeEditorModel

    func makeNSView(context: Context) -> MergeEditorView {
        MergeEditorView(model: model)
    }

    func updateNSView(_ view: MergeEditorView, context: Context) {
        view.refresh()
        if let reveal = model.reveal, reveal.seq != view.appliedReveal {
            view.appliedReveal = reveal.seq
            view.reveal(part: reveal.part)
        }
    }
}

/// Три колонки и две ленты между ними. Раскладка — своя, без NSSplitView:
/// колонки равные, как в Rider, ленты — фиксированной ширины.
final class MergeEditorView: NSView, NSTextStorageDelegate {
    let model: MergeEditorModel
    private let panes: [MergePane]
    private let leftStrip: MergeConnectorView
    private let rightStrip: MergeConnectorView
    private var syncing = false
    var appliedReveal = 0
    static let stripWidth: CGFloat = 46

    init(model: MergeEditorModel) {
        self.model = model
        panes = [MergePane(storage: model.oursStorage, editable: false, pane: .ours),
                 MergePane(storage: model.resultStorage, editable: true, pane: .result),
                 MergePane(storage: model.theirsStorage, editable: false, pane: .theirs)]
        leftStrip = MergeConnectorView(side: .ours)
        rightStrip = MergeConnectorView(side: .theirs)
        super.init(frame: .zero)
        for pane in panes {
            pane.model = model
            addSubview(pane.scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView)
            pane.scrollView.contentView.postsBoundsChangedNotifications = true
        }
        leftStrip.editor = self
        rightStrip.editor = self
        addSubview(leftStrip)
        addSubview(rightStrip)
        // С macOS 14 виды не обрезаются по границам сами — ленты вылезали на кнопки под редактором.
        clipsToBounds = true
        leftStrip.clipsToBounds = true
        rightStrip.clipsToBounds = true
        model.resultStorage.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    var oursPane: MergePane { panes[0] }
    var resultPane: MergePane { panes[1] }
    var theirsPane: MergePane { panes[2] }

    override func layout() {
        super.layout()

        let strip = Self.stripWidth
        let column = max(100, (bounds.width - 2 * strip) / 3)
        oursPane.scrollView.frame = NSRect(x: 0, y: 0, width: column, height: bounds.height)
        leftStrip.frame = NSRect(x: column, y: 0, width: strip, height: bounds.height)
        resultPane.scrollView.frame = NSRect(x: column + strip, y: 0, width: column, height: bounds.height)
        rightStrip.frame = NSRect(x: 2 * column + strip, y: 0, width: strip, height: bounds.height)
        theirsPane.scrollView.frame = NSRect(x: 2 * column + 2 * strip, y: 0,
                                             width: bounds.width - 2 * column - 2 * strip, height: bounds.height)
        // Текст — не уже и не ниже видимой части колонки, иначе ему негде рисоваться.
        for pane in panes {
            let size = pane.scrollView.contentSize
            pane.textView.minSize = NSSize(width: size.width, height: size.height)
            if pane.textView.frame.width < size.width || pane.textView.frame.height < size.height {
                pane.textView.setFrameSize(NSSize(width: max(size.width, pane.textView.frame.width),
                                                  height: max(size.height, pane.textView.frame.height)))
            }
            pane.textView.sizeToFit()
            // Текст задан, пока вид ещё не был в прокрутке, и NSTextView
            // вырос вверх — начало ушло в минус на высоту текста.
            if pane.textView.frame.origin != .zero { pane.textView.setFrameOrigin(.zero) }
        }
        // Первый раз колонки выравниваются по результату — без прокрутки
        // они стояли бы каждая сама по себе.
        if !aligned, bounds.width > 0 {
            aligned = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let first = self.model.currentConflict { self.reveal(part: first) } else { self.align(to: self.resultPane) }
            }
        }
    }

    private var aligned = false

    /// Остальные колонки — напротив тех же кусков, что в `source`.
    private func align(to source: MergePane) {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let top = source.scrollView.contentView.bounds.minY
        guard let (index, fraction) = source.part(atY: top) else { return }
        for pane in panes where pane !== source {
            let rect = pane.rect(ofPart: index)
            let y = rect.minY + fraction * rect.height - (source.rect(ofPart: index).minY + fraction * source.rect(ofPart: index).height - top)
            pane.scrollView.contentView.scroll(to: NSPoint(x: pane.scrollView.contentView.bounds.minX, y: max(0, y)))
            pane.scrollView.reflectScrolledClipView(pane.scrollView.contentView)
        }
        leftStrip.needsDisplay = true
        rightStrip.needsDisplay = true
    }

    func refresh() {
        for pane in panes { pane.textView.needsDisplay = true }
        leftStrip.needsDisplay = true
        rightStrip.needsDisplay = true
    }

    // MARK: Правки результата

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { model.resultEdited(editedRange, delta: delta) }
    }

    // MARK: Общая прокрутка

    /// Прокрутили одну колонку — остальные встают так, чтобы напротив были
    /// те же куски: верхний видимый кусок и доля внутри него.
    @objc private func scrolled(_ note: Notification) {
        guard let clip = note.object as? NSClipView,
              let source = panes.first(where: { $0.scrollView.contentView === clip }) else { return }
        align(to: source)
    }

    /// Кусок — посередине результата, остальные следом.
    func reveal(part index: Int) {
        let rect = resultPane.rect(ofPart: index)
        let visible = resultPane.scrollView.contentView.bounds.height
        let y = max(0, rect.midY - visible / 2)
        resultPane.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        resultPane.scrollView.reflectScrolledClipView(resultPane.scrollView.contentView)
        align(to: resultPane)
        if model.parts.indices.contains(index) {
            let range = model.parts[index].result
            resultPane.textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
        refresh()
    }

    // MARK: Для лент

    /// Рамка куска в колонке — в координатах ленты.
    func stripRect(part index: Int, pane: MergeEditorModel.Pane, in strip: NSView) -> NSRect {
        let source = pane == .ours ? oursPane : pane == .theirs ? theirsPane : resultPane
        let rect = source.rect(ofPart: index)
        return strip.convert(rect, from: source.textView)
    }
}

/// Колонка: текст с подсветкой кусков и номерами строк.
@MainActor
final class MergePane {
    let scrollView = NSScrollView()
    let textView: MergeTextView
    let pane: MergeEditorModel.Pane
    weak var model: MergeEditorModel?

    init(storage: NSTextStorage, editable: Bool, pane: MergeEditorModel.Pane) {
        self.pane = pane
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 1e7, height: 1e7))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        textView = MergeTextView(frame: .zero, textContainer: container)
        textView.pane = pane
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = editable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = Theme.editorFont(size: 12)
        textView.typingAttributes = [.font: Theme.editorFont(size: 12), .foregroundColor: Theme.color(.plain)]
        textView.backgroundColor = Theme.editorBackground
        textView.insertionPointColor = Theme.color(.plain)
        // Слева — место под номера строк: их рисует сам текст, отдельная
        // линейка у NSScrollView наезжала на начало строк.
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textContainer?.lineFragmentPadding = MergeTextView.gutter
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: 1e7, height: 1e7)
        textView.autoresizingMask = []
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        textView.owner = self
    }

    /// Прямоугольник строк куска в координатах текста. Пустой кусок —
    /// полоска нулевой высоты там, где он был бы.
    func rect(ofPart index: Int) -> NSRect {
        guard let model, model.parts.indices.contains(index),
              let layout = textView.layoutManager, let container = textView.textContainer else { return .zero }
        let range = model.range(of: model.parts[index], in: pane)
        let inset = textView.textContainerInset
        let length = textView.string.utf16.count
        if range.length == 0 {
            let y: CGFloat
            if range.location >= length {
                let extra = layout.extraLineFragmentRect
                y = extra == .zero ? textView.bounds.height - inset.height : extra.minY
            } else {
                y = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil).minY
            }
            return NSRect(x: 0, y: y + inset.height, width: textView.bounds.width, height: 0)
        }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layout.lineFragmentRect(forGlyphAt: max(glyphs.location, NSMaxRange(glyphs) - 1), effectiveRange: nil)
        rect.origin.y = first.minY
        rect.size.height = last.maxY - first.minY
        return NSRect(x: 0, y: rect.minY + inset.height, width: textView.bounds.width, height: rect.height)
    }

    /// Какой кусок на высоте `y` и насколько глубоко в нём (0…1).
    func part(atY y: CGFloat) -> (Int, CGFloat)? {
        guard let model else { return nil }
        for index in model.parts.indices {
            let rect = rect(ofPart: index)
            if y < rect.maxY || index == model.parts.count - 1 {
                let fraction = rect.height > 0 ? min(1, max(0, (y - rect.minY) / rect.height)) : 0
                return (index, fraction)
            }
        }
        return nil
    }
}

/// Текст колонки: под строками кусков — фон во всю ширину, как в Rider.
final class MergeTextView: NSTextView {
    var pane: MergeEditorModel.Pane = .result
    weak var owner: MergePane?
    /// Ширина колонки номеров — отступ первой буквы строки.
    static let gutter: CGFloat = 40

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawHighlights(in: rect)
        drawLineNumbers(in: rect)
    }

    /// Номера строк — в левом поле самого текста.
    private func drawLineNumbers(in rect: NSRect) {
        guard let layout = layoutManager, let container = textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let string = self.string as NSString
        var number = 1
        string.enumerateSubstrings(in: NSRange(location: 0, length: chars.location),
                                   options: [.byLines, .substringNotRequired]) { _, _, _, _ in number += 1 }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Theme.gutterText,
        ]
        var index = chars.location
        repeat {
            let line = string.lineRange(for: NSRange(location: min(index, string.length), length: 0))
            let fragment = index < string.length
                ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil)
                : layout.extraLineFragmentRect
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: textContainerInset.width + Self.gutter - size.width - 10,
                                   y: textContainerInset.height + fragment.minY + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            number += 1
            if NSMaxRange(line) <= index { break }
            index = NSMaxRange(line)
        } while index < NSMaxRange(chars) && index < string.length
    }

    private func drawHighlights(in rect: NSRect) {
        MainActor.assumeIsolated {
            guard let owner, let model = owner.model else { return }
            for (index, part) in model.parts.enumerated() where part.isChange {
                let mark = model.mark(of: part, in: pane)
                guard mark != .none || part.chunk.isConflict else { continue }
                let faded = part.state == .resolved || part.state == .applied && pane == .result
                var frame = owner.rect(ofPart: index)
                frame.size.width = max(bounds.width, frame.width)
                guard frame.intersects(rect.insetBy(dx: 0, dy: -2)) || frame.height == 0 else { continue }
                let color = MergeEditorModel.color(mark == .none ? .modified : mark, faded: faded)
                if frame.height == 0 {
                    color.withAlphaComponent(0.8).setFill()
                    NSRect(x: 0, y: frame.minY - 1, width: frame.width, height: 2).fill()
                } else {
                    color.setFill()
                    frame.fill()
                }
                if model.currentConflict == index, part.state == .unresolved {
                    NSColor.systemRed.withAlphaComponent(0.7).setStroke()
                    let path = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
    }
}

/// Лента между колонкой стороны и результатом: полосы от куска к куску и
/// кнопки у края стороны — ≫ (или ≪) применить и × оставить как было.
final class MergeConnectorView: NSView {
    let side: MergeEditorModel.Side
    weak var editor: MergeEditorView?
    private var buttons: [(rect: NSRect, part: Int, ignore: Bool)] = []

    init(side: MergeEditorModel.Side) {
        self.side = side
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        MainActor.assumeIsolated { drawBands() }
    }

    @MainActor
    private func drawBands() {
        guard let editor else { return }
        let model = editor.model
        let sidePane: MergeEditorModel.Pane = side == .ours ? .ours : .theirs
        buttons = []
        for (index, part) in model.parts.enumerated() where part.isChange {
            let mark = model.mark(of: part, in: sidePane)
            guard mark != .none || part.chunk.isConflict else { continue }
            let a = editor.stripRect(part: index, pane: sidePane, in: self)
            let b = editor.stripRect(part: index, pane: .result, in: self)
            guard max(a.maxY, b.maxY) >= 0, min(a.minY, b.minY) <= bounds.height else { continue }
            let faded = part.state == .resolved || part.state == .applied
            let color = MergeEditorModel.color(mark == .none ? .modified : mark, faded: faded)
            // Сторона у левого края ленты для наших и у правого для их.
            let (left, right) = side == .ours ? (a, b) : (b, a)
            let w = bounds.width
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: left.minY))
            path.curve(to: NSPoint(x: w, y: right.minY), controlPoint1: NSPoint(x: w / 2, y: left.minY),
                       controlPoint2: NSPoint(x: w / 2, y: right.minY))
            path.line(to: NSPoint(x: w, y: right.maxY))
            path.curve(to: NSPoint(x: 0, y: left.maxY), controlPoint1: NSPoint(x: w / 2, y: right.maxY),
                       controlPoint2: NSPoint(x: w / 2, y: left.maxY))
            path.close()
            color.setFill()
            path.fill()
            color.withAlphaComponent(min(1, color.alphaComponent * 2.5)).setStroke()
            path.lineWidth = 0.8
            path.stroke()

            // Кнопки — пока из этой стороны в результате ещё не взято.
            guard !part.taken.contains(side), !(part.state == .applied && mark != .none) || part.chunk.isConflict else { continue }
            let y = a.minY + max(0, (min(a.height, 18) - 16) / 2)
            let applyRect = NSRect(x: side == .ours ? 2 : w - 20, y: y, width: 18, height: 16)
            let ignoreRect = NSRect(x: side == .ours ? 22 : w - 38, y: y, width: 16, height: 16)
            draw(side == .ours ? "≫" : "≪", in: applyRect, strong: true)
            buttons.append((applyRect, index, false))
            if part.state == .unresolved || part.state == .applied {
                draw("×", in: ignoreRect, strong: false)
                buttons.append((ignoreRect, index, true))
            }
        }
    }

    private func draw(_ glyph: String, in rect: NSRect, strong: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: strong ? 15 : 13, weight: .heavy),
            .foregroundColor: strong ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
        ]
        let text = glyph as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = buttons.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) else {
            super.mouseDown(with: event)
            return
        }
        MainActor.assumeIsolated {
            guard let editor else { return }
            if hit.ignore { editor.model.ignore(hit.part) } else { editor.model.apply(side, to: hit.part) }
        }
    }

    override func resetCursorRects() {
        for button in buttons { addCursorRect(button.rect, cursor: .pointingHand) }
    }
}
