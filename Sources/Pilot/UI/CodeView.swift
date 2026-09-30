import SwiftUI
import AppKit

// MARK: - Загрузка файла

struct LoadedDocument: Sendable {
    /// Меняется только вслед за самим файлом — см. `moved(to:)`.
    private(set) var url: URL
    let model: SyntaxModel
    let languageName: String
    /// Структура файла для навигации. Строится здесь же, в фоне,
    /// и пересобирается после правок.
    var outline: [OutlineItem]
    /// В ней же файл и сохраняется.
    let encoding: String.Encoding
    /// Коммит, из которого взят текст; nil — файл с диска. Ревью MR
    /// показывает файл в версии MR: она не совпадает с рабочей копией,
    /// поэтому такой документ только для чтения и никогда не сохраняется.
    var revision: String? = nil
    /// Текст не из исходника, а из сборки; nil — обычный файл.
    var decompiled: Decompiled? = nil
    /// Сцена, префаб или другой сериализованный ассет Unity — разобранный.
    var unityFile: UnityYAMLFile? = nil
    /// Её иерархия: GameObject'ы и вложенные префабы — для дерева проекта.
    var unityHierarchy: UnityHierarchy? = nil
    /// Версия модели, по которой построены структура и `unityFile`. Текст
    /// правят, разбор догоняет с задержкой — пока версии не совпали,
    /// позициям из разбора верить нельзя.
    var semanticsVersion: Int = 0
    /// Картинка, модель, шрифт или PDF: текста нет, вместо редактора — просмотр.
    var media: MediaKind? = nil
    /// Подсказки первого экрана и места счётчиков использований, посчитанные
    /// при чтении файла, — чтобы первый же кадр был с ними и строки потом не
    /// ехали (см. `Workspace.earlyInsights`). nil — не C# или проект ещё не
    /// скомпилирован.
    var insights: RustlynInsights? = nil

    /// Разбор соответствует тексту — по нему можно править и переходить.
    var isSemanticsFresh: Bool { semanticsVersion == model.version }

    /// Текущий текст. Берётся из модели: она правится вместе с редактором.
    var text: String { model.text }

    /// Тот же документ по новому пути: файл переименовали вслед за типом,
    /// а текст, разбор и всё посчитанное остались прежними.
    func moved(to url: URL) -> LoadedDocument {
        var moved = self
        moved.url = url
        return moved
    }

    /// Откуда взялся C#, которого в проекте нет.
    enum Decompiled: Sendable, Equatable {
        /// Объявления, собранные по метаданным открытой `.dll`. Компилятор
        /// про такой текст как про исходник не знает: на диске по этому
        /// пути лежит сборка, а не код.
        case assembly
        /// IL одного метода, прочитанный Rustlyn по запросу. Не C# и не
        /// притворяется им: это инструкции с разрешёнными именами.
        case methodBody(name: String)
        /// Класс или ресурс из APK, JAR или DEX, декомпилированный jadx:
        /// путь ведёт внутрь архива, на диске такого файла нет.
        case jadx
    }

    enum LoadError: Error, LocalizedError {
        case tooLarge(Int)
        case binary
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                return L("Файл слишком большой (\(size))")
            case .binary:
                return L("Бинарный файл — предпросмотр недоступен")
            case .unreadable(let why):
                return L("Не удалось прочитать файл: \(why)")
            }
        }
    }

    /// Порог, после которого просмотр отключается. 64 МБ — заведомо больше
    /// любого исходника; такие файлы в репозитории почти всегда бинарные.
    static let maxBytes = 64 * 1024 * 1024

    static func load(url: URL, unity: UnityContext? = nil) throws -> LoadedDocument {
        // Сборка .NET — не текст: вместо байтов показываем её объявления.
        if AssemblySource.isAssembly(url) {
            var document = make(url: url, text: try AssemblySource.text(of: url), encoding: .utf8,
                                revision: nil, unity: nil, spec: Languages.csharp)
            document.decompiled = .assembly
            return document
        }
        if let media = MediaKind(filename: url.lastPathComponent) {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw LoadError.unreadable(L("нет доступа к файлу"))
            }
            return LoadedDocument(url: url, model: SyntaxModel(text: "", spec: nil),
                                  languageName: media.title, outline: [], encoding: .utf8, media: media)
        }
        let (text, encoding) = try readTextAndEncoding(url: url, maxBytes: maxBytes)
        return make(url: url, text: text, encoding: encoding, revision: nil, unity: unity)
    }

    /// Текст, которого нет ни на диске, ни в коммите: IL метода.
    ///
    /// `revision` здесь не версия из git, а то, что отличает эту вкладку от
    /// вкладки самой сборки: у них один путь, и без него вторая нашлась бы
    /// вместо первой. Языка нет намеренно — IL не C#, и красить его как C#
    /// значило бы называть `ldfld` типом.
    static func methodBody(assembly url: URL, token: UInt32, name: String,
                           text: String) -> LoadedDocument {
        let model = SyntaxModel(text: text, spec: nil)
        var document = LoadedDocument(url: url, model: model, languageName: "IL",
                                      outline: [], encoding: .utf8,
                                      revision: "il:\(token)")
        document.decompiled = .methodBody(name: name)
        return document
    }

    /// Файл из коммита — для ревью MR: те же проверки, что и с диска.
    static func make(url: URL, data: Data, revision: String?) throws -> LoadedDocument {
        let (text, encoding) = try decodeText(data, maxBytes: maxBytes)
        return make(url: url, text: text, encoding: encoding, revision: revision, unity: nil)
    }

    private static func make(url: URL, text: String, encoding: String.Encoding,
                             revision: String?, unity: UnityContext?,
                             spec forced: LanguageSpec? = nil) -> LoadedDocument {
        let spec = forced ?? Languages.detect(filename: url.lastPathComponent)
        let model = SyntaxModel(text: text, spec: spec)
        // Файл только что прочитан, значит он совпадает с тем, что на диске,
        // — и про C# дальше отвечает Rustlyn: подсветка, структура, переходы.
        //
        // Файл из коммита (ревью MR) сюда не попадает: `revision` говорит,
        // что текст не с диска, а Rustlyn читает именно диск. Показывать
        // структуру одной версии поверх текста другой — хуже, чем показать
        // структуру от своего разбора.
        if revision == nil, let rustlyn = Rustlyn.session(for: url), Rustlyn.understands(url) {
            if rustlyn.open(url) {
                model.useRustlyn(for: url, session: rustlyn)
                // Расставить точки возврата лексера по всему файлу, чтобы
                // прыжок в конец стоил столько же, сколько прокрутка. Фоном:
                // на файле в 200 000 строк это доли секунды, а первый экран
                // уже нарисован.
                let warming = url
                DispatchQueue.global(qos: .utility).async { rustlyn.warm(warming) }
            }
        }
        let outline = OutlineBuilder.build(model: model)
        let semantics = UnitySemantics.analyze(model: model, lexicalOutline: outline, context: unity)
        return LoadedDocument(url: url, model: model,
                              languageName: spec?.name ?? "Plain Text",
                              outline: semantics?.outline ?? outline, encoding: encoding,
                              revision: revision, unityFile: semantics?.serialized,
                              unityHierarchy: semantics?.hierarchy,
                              semanticsVersion: model.version)
    }

    /// Декомпилированный класс или ресурс архива: текст даёт jadx.
    static func decompiled(url: URL, text: String) -> LoadedDocument {
        var document = make(url: url, text: text, encoding: .utf8, revision: nil, unity: nil)
        document.decompiled = .jadx
        return document
    }

    /// Текст файла с теми же проверками, что и при открытии: размер,
    /// бинарность, кодировка. Нужен и предпросмотру в палитре.
    static func readText(url: URL, maxBytes: Int) throws -> String {
        try readTextAndEncoding(url: url, maxBytes: maxBytes).0
    }

    static func readTextAndEncoding(url: URL, maxBytes: Int) throws -> (String, String.Encoding) {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        return try decodeText(data, maxBytes: maxBytes)
    }

    private static func decodeText(_ data: Data, maxBytes: Int) throws -> (String, String.Encoding) {
        if data.count > maxBytes { throw LoadError.tooLarge(data.count) }

        // Эвристика бинарности: NUL в первых 8 КБ.
        let probe = data.prefix(8192)
        if probe.contains(0) { throw LoadError.binary }

        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        // фолбэк, чтобы не падать на legacy-кодировках
        if let s = String(data: data, encoding: .isoLatin1) { return (s, .isoLatin1) }
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

/// Правки инспектора Unity, которые редактор должен применить к своему
/// тексту. Номер — чтобы одну и ту же просьбу не выполнить дважды.
struct TextEditRequest {
    var seq: Int
    weak var buffer: TextBuffer?
    var edits: [UnityEdit]
    var actionName: String
}

// MARK: - NSTextView с подсветкой только видимой области

extension NSLayoutManager {
    /// Строка текста — без места над ней, отведённого под счётчик
    /// использований: полоса текущей строки и номер в гаттере — по ней.
    func textLineRect(forGlyphAt glyph: Int) -> NSRect {
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard used.height > 0, used.minY > fragment.minY else { return fragment }
        return NSRect(x: fragment.minX, y: used.minY, width: fragment.width, height: fragment.maxY - used.minY)
    }
}

final class CodeTextView: NSTextView {
    /// ⌘+клик по символу — переход к определению.
    var onCommandClick: ((Int) -> Void)?
    /// ⌘ зажат, и мышь над символом `index`: клик по нему, скорее всего,
    /// будет. `nil` — ⌘ отпустили или мышь ушла из текста.
    var onCommandHover: ((Int?) -> Void)?
    /// ⌘ был зажат на прошлом событии — чтобы заметить, что его отпустили.
    private var commandHeld = false

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let held = event.modifierFlags.contains(.command)
        guard held != commandHeld else { return }
        commandHeld = held
        guard held, let window else {
            onCommandHover?(nil)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        onCommandHover?(visibleRect.contains(point) ? character(at: point) : nil)
    }

    /// Человек сам взялся за текст: клавиша, клик, фокус ушёл в другое поле.
    /// Переход, который ещё «встаёт», после этого больше не держится (см. Landing).
    var onUserInput: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onUserInput?()
        super.rightMouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onUserInput?() }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        onUserInput?()
        // Нажатие — не наведение: окно подсказки, открытое мышью, прячется
        // и не появится, пока мышь снова не сдвинется.
        onHover?(nil)
        let clicked = convert(event.locationInWindow, from: nil)
        if let folded = foldedRanges.first(where: { placeholderRect(for: $0)?.contains(clicked) == true }) {
            onUnfold?(folded)
            return
        }
        if let lens = codeLenses.first(where: { lensRect(for: $0)?.contains(clicked) == true }) {
            onLens?(lens.target)
            return
        }
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
            return
        }
        for lens in visibleLenses() {
            if let rect = lensRect(for: lens) { addCursorRect(rect, cursor: .pointingHand) }
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
            rect = layout.textLineRect(forGlyphAt: glyph)
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
        drawConflictBands(in: dirtyRect)
        drawExecutionBand(in: dirtyRect)
        currentLineRect = lineHighlightRect()
        if let line = currentLineRect, line.intersects(dirtyRect) {
            Theme.currentLine.setFill()
            line.intersection(dirtyRect).intersection(bounds).fill()
        }
        super.draw(dirtyRect)
        drawRemovedLines(in: dirtyRect)
        drawPlaceholders(in: dirtyRect)
        drawInlayHints(in: dirtyRect)
        drawGhost(in: dirtyRect)
        drawCodeLenses(in: dirtyRect)
        drawDiagnostics(in: dirtyRect)
    }

    // MARK: Перерисовка пачкой

    /// Прямоугольник, накопленный за перекраску; nil — копить не просим.
    private var batchedDisplay: NSRect?

    /// Каждый временный атрибут зовёт setNeedsDisplay, а NSTextView на
    /// каждый ещё и доводит раскладку видимой области — перекраска тысячи
    /// токенов обходилась в тысячу таких проходов. Копим прямоугольник
    /// и отдаём его одним вызовом.
    func batchingDisplay(_ body: () -> Void) {
        guard batchedDisplay == nil else { return body() }
        batchedDisplay = .null
        body()
        let rect = batchedDisplay ?? .null
        batchedDisplay = nil
        if !rect.isNull { super.setNeedsDisplay(rect, avoidAdditionalLayout: false) }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        if let batched = batchedDisplay {
            batchedDisplay = batched.union(rect)
            return
        }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    // MARK: Отладка

    /// Строка, на которой остановлена программа: полоса на всю ширину
    /// под текстом, как в Xcode. Символы строки — от начала до перевода.
    var executionRange: NSRange? {
        didSet { if executionRange != oldValue { needsDisplay = true } }
    }

    private func drawExecutionBand(in dirtyRect: NSRect) {
        guard let range = executionRange, let layout = layoutManager, let container = textContainer,
              let storage = textStorage else { return }
        var rect: NSRect
        if range.location >= storage.length {
            rect = layout.extraLineFragmentRect
        } else {
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: max(range.length, 1)),
                                           actualCharacterRange: nil)
            rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect = rect.union(layout.textLineRect(forGlyphAt: glyphs.location))
        }
        rect.origin.x = 0
        rect.origin.y += textContainerOrigin.y
        rect.size.width = max(bounds.width, visibleRect.maxX)
        guard rect.intersects(dirtyRect) else { return }
        Theme.debugExecutionLine.setFill()
        rect.intersection(dirtyRect).intersection(bounds).fill()
    }

    // MARK: Конфликты слияния

    /// Полосы под блоками конфликта: текущее, база, входящее, маркеры.
    /// Диапазоны — в символах текста; на всю ширину, как текущая строка.
    var conflictBands: [(range: NSRange, color: NSColor)] = [] {
        didSet { needsDisplay = true }
    }

    private func drawConflictBands(in dirtyRect: NSRect) {
        guard !conflictBands.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        // Только то, что видно: у файла-лога с сотней конфликтов считать
        // прямоугольники для всех на каждой отрисовке незачем.
        let visibleGlyphs = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        let visible = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        for band in conflictBands where band.range.length > 0 {
            guard NSIntersectionRange(band.range, visible).length > 0
                    || NSLocationInRange(band.range.location, visible) else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: band.range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x = 0
            rect.origin.y += textContainerOrigin.y
            rect.size.width = max(bounds.width, visibleRect.maxX)
            guard rect.intersects(dirtyRect) else { continue }
            band.color.setFill()
            rect.intersection(dirtyRect).fill()
        }
    }

    // MARK: Контекстное меню

    /// Задан — в меню текста появляется «Комментировать строку».
    var onCommentLine: ((Int) -> Void)?
    /// Пункты в начало меню текста для символа под мышью (не под курсором):
    /// позиция — его буква. Пусто — пунктов нет.
    var textMenuActions: ((Int) -> [ContextAction])?

    override func menu(for event: NSEvent) -> NSMenu? {
        // Меню — не наведение: окно подсказки под мышью ему только мешает.
        onHover?(nil)
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        var top: [NSMenuItem] = []
        if let textMenuActions, let index = character(at: point) {
            let actions = textMenuActions(index)
            if !actions.isEmpty {
                top += actions.map { ContextMenuItem($0) as NSMenuItem }
                top.append(.separator())
            }
        }
        if onCommentLine != nil {
            let item = NSMenuItem(title: L("Комментировать строку…"), action: #selector(commentFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = characterIndexForInsertion(at: point)
            top += [item, .separator()]
        }
        for (position, item) in top.enumerated() { menu.insertItem(item, at: position) }
        return menu
    }

    @objc private func commentFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onCommentLine?(index)
    }

    // MARK: Правила ввода

    /// Задаются при показе буфера: у каждого файла свои.
    var indentUnit = "    "
    var lineEnding = "\n"
    var lineCommentToken: String?
    var colonOpensBlock = false
    /// Парные скобки и кавычки при наборе (см. AutoPairs). В Markdown и
    /// простом тексте выключены: там `(` и `"` — просто знаки.
    var autoPairs = false
    var autoPairQuotes: Set<Character> = []
    /// ⌥Esc и «Esc без списка» — показать варианты дополнения.
    var onCompletionRequest: (() -> Void)?

    /// Return: отступ как у текущей строки, после `{` — глубже,
    /// `{|}` раскрывается в три строки.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        let startLine = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefix = ns.substring(with: NSRange(location: startLine.location,
                                                length: selection.location - startLine.location))
        let end = NSMaxRange(selection)
        let endLine = ns.lineRange(for: NSRange(location: end, length: 0))
        var contentEnd = NSMaxRange(endLine)
        while contentEnd > end, ns.character(at: contentEnd - 1) == 0x0A || ns.character(at: contentEnd - 1) == 0x0D {
            contentEnd -= 1
        }
        let suffix = ns.substring(with: NSRange(location: end, length: contentEnd - end))
        let insertion = EditingRules.newline(linePrefix: prefix, lineSuffix: suffix,
                                             indentUnit: indentUnit, lineEnding: lineEnding,
                                             colonOpensBlock: colonOpensBlock)
        insertText(insertion.text, replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + insertion.caret, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Tab: с выделением на несколько строк — сдвиг строк, иначе отступ.
    override func insertTab(_ sender: Any?) {
        if selectionSpansLines {
            transformSelectedLines { EditingRules.indent($0, unit: indentUnit) }
        } else {
            insertText(indentUnit, replacementRange: selectedRange())
        }
    }

    override func insertBacktab(_ sender: Any?) {
        transformSelectedLines { EditingRules.outdent($0, unit: indentUnit) }
    }

    /// Backspace в отступе стирает до предыдущей позиции табуляции.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if autoPairs, let edit = AutoPairs.deletingBackward(in: string as NSString, selection: selection,
                                                            quotes: autoPairQuotes) {
            replace(edit.range, with: edit.text)
            setSelectedRange(edit.selection)
            return
        }
        guard selection.length == 0, selection.location > 0 else { return super.deleteBackward(sender) }
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefix = ns.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let width = EditingRules.backspaceWidth(linePrefix: prefix, indentUnit: indentUnit)
        guard width > 1 else { return super.deleteBackward(sender) }
        replace(NSRange(location: selection.location - width, length: width), with: "")
    }

    /// `}` в пустой строке встаёт под парную `{`, как в Xcode.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        // Только набранное с клавиатуры: вставка из буфера и дополнение
        // приходят сюда же, и их скобки парными делать не надо.
        if autoPairs, let text, !hasMarkedText(), selectedRanges.count == 1,
           NSApp.currentEvent?.type == .keyDown,
           replacementRange.location == NSNotFound || replacementRange == selectedRange(),
           let edit = AutoPairs.typing(text, in: string as NSString, selection: selectedRange(),
                                       quotes: autoPairQuotes) {
            replace(edit.range, with: edit.text)
            setSelectedRange(edit.selection)
            scrollRangeToVisible(edit.selection)
            return
        }
        if text == "}", let storage = textStorage {
            let target = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            let ns = storage.string as NSString
            let line = ns.lineRange(for: NSRange(location: target.location, length: 0))
            let prefixRange = NSRange(location: line.location, length: target.location - line.location)
            let prefix = ns.substring(with: prefixRange)
            if !prefix.isEmpty, prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                var units = [UInt16](repeating: 0, count: target.location)
                ns.getCharacters(&units, range: NSRange(location: 0, length: target.location))
                let indent = EditingRules.closingBraceIndent(in: units, before: line.location)
                    ?? String(prefix.dropLast(EditingRules.dedentBeforeClosing(linePrefix: prefix, indentUnit: indentUnit)))
                if indent != prefix {
                    super.insertText(indent + "}", replacementRange: NSRange(
                        location: line.location, length: NSMaxRange(target) - line.location))
                    return
                }
            }
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func complete(_ sender: Any?) {
        onCompletionRequest?()
    }

    /// ⌘/ — закомментировать или раскомментировать строки выделения.
    @objc func toggleLineComment(_ sender: Any?) {
        guard let token = lineCommentToken else { NSSound.beep(); return }
        transformSelectedLines { EditingRules.toggleComment($0, token: token) }
    }

    /// Правка с отменой: через shouldChangeText/didChangeText, как при наборе.
    func replace(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        replaceCharacters(in: range, with: text)
        didChangeText()
    }

    private var selectionSpansLines: Bool {
        let selection = selectedRange()
        guard selection.length > 0 else { return false }
        return (string as NSString).rangeOfCharacter(from: .newlines, options: [], range: selection).location != NSNotFound
    }

    /// Применяет преобразование к строкам, которые задевает выделение,
    /// одной правкой — одним шагом отмены.
    private func transformSelectedLines(_ transform: ([String]) -> [String]) {
        let ns = string as NSString
        var selection = selectedRange()
        // Выделение, кончающееся в начале строки, эту строку не захватывает.
        if selection.length > 0, ns.character(at: NSMaxRange(selection) - 1) == 0x0A { selection.length -= 1 }
        let range = ns.lineRange(for: selection)
        let block = ns.substring(with: range) as NSString
        let terminator = block.hasSuffix("\r\n") ? "\r\n" : (block.hasSuffix("\n") ? "\n" : "")
        let body = block.substring(to: block.length - (terminator as NSString).length)
        let separator = body.contains("\r\n") ? "\r\n" : "\n"
        let lines = body.components(separatedBy: separator)
        let newBody = transform(lines).joined(separator: separator)
        guard newBody != body else { return }
        replace(range, with: newBody + terminator)
        setSelectedRange(NSRange(location: range.location, length: (newBody as NSString).length))
    }

    // MARK: Строки целиком

    /// ⌘D, ⌘⌫, ⌥⇧↑, ⌥⇧↓ — из меню, через цепочку ответчиков.
    @objc func duplicateLines(_ sender: Any?) {
        applyLineEdit(LineEditing.duplicate(string as NSString, selection: selectedRange()))
    }

    @objc func deleteLines(_ sender: Any?) {
        applyLineEdit(LineEditing.deleteLines(string as NSString, selection: selectedRange()))
    }

    @objc func moveLinesUp(_ sender: Any?) {
        applyLineEdit(LineEditing.moveLines(string as NSString, selection: selectedRange(), up: true))
    }

    @objc func moveLinesDown(_ sender: Any?) {
        applyLineEdit(LineEditing.moveLines(string as NSString, selection: selectedRange(), up: false))
    }

    /// ⌃⇧J — склеить строки.
    @objc func joinLines(_ sender: Any?) {
        applyLineEdit(LineEditing.joinLines(string as NSString, selection: selectedRange()))
    }

    /// ⌘⇧U — заглавные ↔ строчные: выделение или слово под курсором.
    @objc func toggleCase(_ sender: Any?) {
        applyLineEdit(LineEditing.toggleCase(string as NSString, selection: selectedRange()))
    }

    // MARK: Строка целиком в буфере обмена

    /// Метка на скопированной без выделения строке: такая вставляется
    /// целиком над строкой курсора, а не посреди неё — как в Rider и VS Code.
    static let wholeLineType = NSPasteboard.PasteboardType("dev.pilot.whole-line")

    /// ⌘C без выделения — вся строка курсора.
    override func copy(_ sender: Any?) {
        guard selectedRange().length == 0, selectedRanges.count == 1, !string.isEmpty else { return super.copy(sender) }
        copyWholeLines()
    }

    /// ⌘X без выделения — строка уходит в буфер и из текста.
    override func cut(_ sender: Any?) {
        guard selectedRange().length == 0, selectedRanges.count == 1, !string.isEmpty else { return super.cut(sender) }
        guard isEditable else { return copy(sender) }
        copyWholeLines()
        applyLineEdit(LineEditing.deleteLines(string as NSString, selection: selectedRange()))
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard isEditable, selectedRange().length == 0, selectedRanges.count == 1,
              pasteboard.data(forType: Self.wholeLineType) != nil,
              var text = pasteboard.string(forType: .string) else { return super.paste(sender) }
        let ns = string as NSString
        let caret = selectedRange().location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        // Строка скопирована из другого файла — перевод строки как у этого.
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        if lineEnding != "\n" { text = text.replacingOccurrences(of: "\n", with: lineEnding) }
        breakUndoCoalescing()
        replace(NSRange(location: line.location, length: 0), with: text)
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: caret + (text as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    private func copyWholeLines() {
        let ns = string as NSString
        var text = ns.substring(with: LineEditing.lineBlock(ns, selection: selectedRange()))
        if !(text.hasSuffix("\n") || text.hasSuffix("\r")) { text += lineEnding }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.wholeLineType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.wholeLineType)
    }

    /// Одна правка — один шаг ⌘Z, отдельно от набора вокруг.
    private func applyLineEdit(_ edit: LineEditing.Edit?) {
        guard isEditable, let edit else { NSSound.beep(); return }
        breakUndoCoalescing()
        replace(edit.range, with: edit.text)
        breakUndoCoalescing()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    // MARK: Расширение выделения

    /// Шаги ⌃W для C# — синтаксическое дерево Rustlyn; `nil` — текстом.
    var selectionSteps: ((NSRange) -> [NSRange]?)?
    /// Выделения до расширения: ⌃⇧W возвращает их по одному.
    private var expansion: [NSRange] = []
    /// Что выделили сами: другое выделение — история расширений ни при чём.
    private var expandedTo: NSRange?

    @objc func extendSelection(_ sender: Any?) {
        let current = selectedRange()
        if expandedTo != current { expansion = [] }
        let steps = selectionSteps?(current) ?? SelectionSteps.around(string as NSString, selection: current)
        let wider = { (range: NSRange) in
            range.location <= current.location && NSMaxRange(range) >= NSMaxRange(current)
                && range.length > current.length && NSMaxRange(range) <= (self.string as NSString).length
        }
        // Дерево знает не всё (комментарий в конце файла, текст вне кода):
        // тогда — шагами по тексту.
        guard let next = steps.first(where: wider)
                ?? SelectionSteps.around(string as NSString, selection: current).first(where: wider) else {
            NSSound.beep()
            return
        }
        expansion.append(current)
        expandedTo = next
        setSelectedRange(next)
        scrollRangeToVisible(next)
    }

    @objc func shrinkSelection(_ sender: Any?) {
        guard expandedTo == selectedRange(), let previous = expansion.popLast() else {
            NSSound.beep()
            return
        }
        expandedTo = previous
        setSelectedRange(previous)
    }

    // MARK: Подсказки

    /// ⌃J — документация имени под курсором; ⇧⌘Space — сигнатура вызова;
    /// ⌘F1 — почему подчёркнуто там, где курсор.
    var onQuickDocumentation: (() -> Void)?
    var onParameterInfo: (() -> Void)?
    var onProblemDescription: (() -> Void)?
    /// Мышь над символом `index` — на каждом её движении; ушла с текста или
    /// нажата кнопка — `nil`. Остановилась ли она, решает получатель.
    var onHover: ((Int?) -> Void)?
    /// Нажата клавиша — до того, как текст её разберёт.
    var onKeyDown: ((NSEvent) -> Void)?

    @objc func showQuickDocumentation(_ sender: Any?) { onQuickDocumentation?() }
    @objc func showParameterInfo(_ sender: Any?) { onParameterInfo?() }
    /// «Описание ошибки» (⌘F1, ShowErrorDescription в Rider) — пункт меню
    /// шлёт его первому ответчику, как и ⌃J.
    @objc func showProblemDescription(_ sender: Any?) { onProblemDescription?() }

    override func keyDown(with event: NSEvent) {
        onUserInput?()
        onKeyDown?(event)
        super.keyDown(with: event)
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                         .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoverLens(at: point)
        let index = character(at: point)
        onHover?(index)
        // ⌘ могли зажать и отпустить, пока фокус был не у текста.
        let held = event.modifierFlags.contains(.command)
        if held || commandHeld {
            commandHeld = held
            onCommandHover?(held ? index : nil)
        }
    }

    /// Символ под точкой; `nil` — мимо текста.
    private func character(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -1, dy: -1).contains(inContainer) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverLens(at: nil)
        onHover?(nil)
        onCommandHover?(nil)
    }

    // MARK: Ошибки

    /// Ошибки файла — волной под текстом. Диапазоны едут вместе с правками,
    /// пока не придут свежие.
    var diagnostics: [RustlynDiagnostic] = [] {
        didSet { if diagnostics != oldValue { needsDisplay = true } }
    }

    private func drawDiagnostics(in dirtyRect: NSRect) {
        guard !diagnostics.isEmpty, let layout = layoutManager, let container = textContainer,
              let length = textStorage?.length, length > 0 else { return }
        let visibleGlyphs = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        let visible = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let origin = textContainerOrigin
        // Предупреждения первыми: ошибка поверх, если они в одном месте.
        for diagnostic in diagnostics.sorted(by: { $0.severity.rawValue < $1.severity.rawValue }) {
            // Пустой диапазон (пропущенная `;`) — волна под символом перед ним.
            let range = diagnostic.underline(textLength: length)
            guard NSIntersectionRange(range, visible).length > 0 || NSLocationInRange(range.location, visible)
            else { continue }
            let color = diagnostic.severity.color
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs,
                                           withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                let line = rect.offsetBy(dx: origin.x, dy: origin.y)
                guard line.intersects(dirtyRect.insetBy(dx: 0, dy: -4)), line.width > 0 else { return }
                Self.squiggle(from: line.minX, to: max(line.maxX, line.minX + 4), baseline: line.maxY - 1.5, color: color)
            }
        }
    }

    /// Волна, как у проверки орфографии, но цветом ошибки.
    private static func squiggle(from start: CGFloat, to end: CGFloat, baseline: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        let step: CGFloat = 2.5
        var x = start
        var up = true
        path.move(to: NSPoint(x: x, y: baseline))
        while x < end {
            x = min(end, x + step)
            path.line(to: NSPoint(x: x, y: baseline + (up ? -1.5 : 0)))
            up.toggle()
        }
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }

    // MARK: Свёрнутое

    /// Что спрятано сейчас; вместо каждого — рамка «⋯».
    var foldedRanges: [NSRange] = [] {
        didSet { if foldedRanges != oldValue { needsDisplay = true } }
    }
    /// Клик по «⋯» — развернуть.
    var onUnfold: ((NSRange) -> Void)?
    /// ⌥⌘← ⌥⌘→ и с ⇧ — всё.
    var onFoldCommand: ((FoldCommand) -> Void)?

    enum FoldCommand { case fold, unfold, foldAll, unfoldAll }

    @objc func foldAtCaret(_ sender: Any?) { onFoldCommand?(.fold) }
    @objc func unfoldAtCaret(_ sender: Any?) { onFoldCommand?(.unfold) }
    @objc func foldAll(_ sender: Any?) { onFoldCommand?(.foldAll) }
    @objc func unfoldAll(_ sender: Any?) { onFoldCommand?(.unfoldAll) }

    /// Где рамка «⋯» свёрнутого куска — на месте первого спрятанного символа,
    /// которому раскладка дала ширину.
    func placeholderRect(for folded: NSRange) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer,
              folded.location < (textStorage?.length ?? 0) else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: folded.location)
        var rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return rect.insetBy(dx: 1, dy: 2)
    }

    private func drawPlaceholders(in dirtyRect: NSRect) {
        guard !foldedRanges.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.editorFont(size: 12),
            .foregroundColor: Theme.foldMarker,
        ]
        for folded in foldedRanges {
            guard let rect = placeholderRect(for: folded), rect.intersects(dirtyRect), rect.width > 2 else { continue }
            let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            Theme.foldMarker.withAlphaComponent(0.18).setFill()
            box.fill()
            Theme.foldMarker.withAlphaComponent(0.6).setStroke()
            box.lineWidth = 0.5
            box.stroke()
            let dots = "⋯" as NSString
            let size = dots.size(withAttributes: attributes)
            dots.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                      withAttributes: attributes)
        }
    }

    // MARK: Подсказки в строках

    /// Подсказка, как в Rider: `count:` перед аргументом, `int` у `var`.
    /// В тексте её нет — раскладка ставит перед символом `position` лишний
    /// управляющий глиф шириной `width`, а рисуем её здесь, поверх.
    struct InlayHint: Equatable {
        var position: Int
        var label: String
        var width: CGFloat
        /// Зазоры до плашки слева и справа — внутри `width`.
        var leading: CGFloat
        var trailing: CGFloat
    }

    /// По возрастанию позиции: раскладка ищет в них двоичным поиском.
    var inlayHints: [InlayHint] = [] {
        didSet { if inlayHints != oldValue { needsDisplay = true } }
    }
    var hintFont = Theme.editorFont(size: 11)

    /// Индекс первой подсказки с позицией не меньше `index`.
    func firstInlayHint(atOrAfter index: Int) -> Int {
        var lo = 0, hi = inlayHints.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if inlayHints[mid].position < index { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func inlayHint(at index: Int) -> InlayHint? {
        let i = firstInlayHint(atOrAfter: index)
        return i < inlayHints.count && inlayHints[i].position == index ? inlayHints[i] : nil
    }

    /// Видимые символы — подсказки и счётчики рисуются только для них.
    private func visibleCharacters() -> NSRange? {
        guard let layout = layoutManager, let container = textContainer,
              let length = textStorage?.length, length > 0 else { return nil }
        let rect = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    private func drawInlayHints(in dirtyRect: NSRect) {
        guard !inlayHints.isEmpty, let layout = layoutManager, let container = textContainer,
              let visible = visibleCharacters() else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: hintFont, .foregroundColor: Theme.inlayHintText]
        let origin = textContainerOrigin
        var i = firstInlayHint(atOrAfter: visible.location)
        while i < inlayHints.count, inlayHints[i].position <= NSMaxRange(visible) {
            let hint = inlayHints[i]
            i += 1
            let glyph = layout.glyphIndexForCharacter(at: hint.position)
            // Свёрнутое: глифа-зазора нет, рисовать некуда.
            guard layout.propertyForGlyph(at: glyph).contains(.controlCharacter),
                  !foldedRanges.contains(where: { NSLocationInRange(hint.position, $0) }) else { continue }
            let x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minX
            let line = layout.textLineRect(forGlyphAt: glyph)
            let pill = NSRect(x: origin.x + x + hint.leading, y: origin.y + line.minY + 1.5,
                              width: hint.width - hint.leading - hint.trailing, height: line.height - 3)
            guard pill.intersects(dirtyRect), pill.width > 0 else { continue }
            Theme.inlayHintBackground.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
            let label = hint.label as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2),
                       withAttributes: attributes)
        }
    }

    // MARK: Удалённые строки ревью

    /// Строки, которые MR удалил, — красным над строкой, с которой начинается
    /// изменение, как в диффе GitLab. В тексте их нет: место под них даёт
    /// раскладка отступом перед абзацем `anchor`, над счётчиком использований.
    struct RemovedBlock: Equatable {
        /// Начало строки, над которой блок.
        var anchor: Int
        var lines: [String]
    }

    var removedBlocks: [RemovedBlock] = [] {
        didSet {
            guard removedBlocks != oldValue else { return }
            removedLineCounts = Dictionary(removedBlocks.map { ($0.anchor, $0.lines.count) }, uniquingKeysWith: +)
            needsDisplay = true
        }
    }
    /// Сколько удалённых строк над началом строки — для раскладки.
    private(set) var removedLineCounts: [Int: Int] = [:]

    private func drawRemovedLines(in dirtyRect: NSRect) {
        guard !removedBlocks.isEmpty, let layout = layoutManager, let font,
              let length = textStorage?.length, length > 0, let visible = visibleCharacters() else { return }
        let height = layout.defaultLineHeight(for: font)
        let origin = textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.removedLineText]
        let padding = textContainer?.lineFragmentPadding ?? 0
        // Блок над первой видимой строкой может быть виден, хотя его строка — нет.
        let from = max(0, visible.location - 1), to = NSMaxRange(visible) + 1
        for block in removedBlocks where block.anchor >= from && block.anchor <= to && block.anchor < length {
            let fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: block.anchor),
                                                   effectiveRange: nil)
            let band = NSRect(x: 0, y: origin.y + fragment.minY, width: bounds.width,
                              height: CGFloat(block.lines.count) * height)
            guard band.intersects(dirtyRect) else { continue }
            Theme.removedLineBackground.setFill()
            band.intersection(dirtyRect).fill()
            for (i, text) in block.lines.enumerated() {
                let y = band.minY + CGFloat(i) * height
                guard y < dirtyRect.maxY, y + height > dirtyRect.minY else { continue }
                (text.replacingOccurrences(of: "\t", with: "    ") as NSString)
                    .draw(at: NSPoint(x: origin.x + padding, y: y), withAttributes: attributes)
            }
        }
    }

    // MARK: Подсказка Copilot

    /// Серый текст у курсора, как в VS Code: первая строка — сразу за
    /// курсором, остальные — в месте, которое раскладка даёт под строкой.
    /// В тексте его нет, пока подсказку не приняли.
    struct Ghost: Equatable {
        /// Где курсор.
        var position: Int
        /// Первая строка — то, что встанет между курсором и концом строки.
        var inline: String
        /// Середина строки: ширина зазора, который раскладка ставит перед
        /// `position`, чтобы хвост строки отъехал вправо. У конца строки — 0.
        var gap: CGFloat
        var lines: [String]
        /// Начало следующей строки — над ней место под `lines`.
        var anchor: Int?
        var space: CGFloat
    }

    var ghost: Ghost? {
        didSet { if ghost != oldValue { needsDisplay = true } }
    }

    private func drawGhost(in dirtyRect: NSRect) {
        guard let ghost, let layout = layoutManager, let container = textContainer,
              let storage = textStorage, let font else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.inlayHintText]
        let origin = textContainerOrigin
        let length = storage.length
        // Точка курсора: левый край его символа — или правый край последнего.
        var x: CGFloat
        var line: NSRect
        if ghost.position < length {
            let glyph = layout.glyphIndexForCharacter(at: ghost.position)
            x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minX
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else if length > 0, (storage.string as NSString).character(at: length - 1) != 0x0A {
            let glyph = layout.glyphIndexForCharacter(at: length - 1)
            x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            line = layout.extraLineFragmentRect
            x = container.lineFragmentPadding
        }
        // Место под счётчик над строкой — не часть самой строки.
        let height = layout.defaultLineHeight(for: font)
        let baseline = NSRect(x: 0, y: line.maxY - height, width: line.width, height: height)
        (ghost.inline as NSString).draw(at: NSPoint(x: origin.x + x, y: origin.y + baseline.minY),
                                        withAttributes: attributes)
        for (i, text) in ghost.lines.enumerated() {
            let y = origin.y + line.maxY + CGFloat(i) * height
            guard y < dirtyRect.maxY, y + height > dirtyRect.minY else { continue }
            (text as NSString).draw(at: NSPoint(x: origin.x + container.lineFragmentPadding, y: y),
                                    withAttributes: attributes)
        }
    }

    // MARK: Счётчики использований

    /// «3 использования» над объявлением, как Code Vision в Rider. Место
    /// под строку даёт раскладка — отступом перед абзацем `anchor`.
    struct CodeLens: Equatable {
        /// Начало строки, над которой счётчик: объявление или его атрибуты.
        var anchor: Int
        /// Первый символ объявления — с него начинается подпись.
        var indent: Int
        /// Имя в объявлении — клик ищет его использования.
        var target: Int
        var title: String
    }

    /// По возрастанию `anchor`.
    var codeLenses: [CodeLens] = [] {
        didSet {
            guard codeLenses != oldValue else { return }
            lensAnchors = Set(codeLenses.map(\.anchor))
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private(set) var lensAnchors: Set<Int> = []
    var lensFont = NSFont.systemFont(ofSize: 10.5)
    /// Высота места над строкой.
    var lensSpace: CGFloat = 14
    var onLens: ((Int) -> Void)?

    private func visibleLenses() -> ArraySlice<CodeLens> {
        guard !codeLenses.isEmpty, let visible = visibleCharacters() else { return [] }
        // Место под счётчик — над строкой: строка чуть ниже экрана тоже в счёт.
        let lo = codeLenses.firstIndex { $0.anchor >= visible.location } ?? codeLenses.endIndex
        let hi = codeLenses[lo...].firstIndex { $0.anchor > NSMaxRange(visible) + 1 } ?? codeLenses.endIndex
        return codeLenses[lo..<hi]
    }

    /// Где подпись счётчика — для отрисовки и клика. `nil` — место над
    /// строкой не отведено (строка свёрнута, раскладка не дошла).
    func lensRect(for lens: CodeLens) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer,
              let length = textStorage?.length, lens.anchor < length, lens.indent < length else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: lens.anchor)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let line = layout.textLineRect(forGlyphAt: glyph)
        let space = line.minY - fragment.minY
        guard space >= lensSpace - 1 else { return nil }
        let indentGlyph = layout.glyphIndexForCharacter(at: lens.indent)
        let x = layout.boundingRect(forGlyphRange: NSRange(location: indentGlyph, length: 1), in: container).minX
        let size = (lens.title as NSString).size(withAttributes: [.font: lensFont])
        let origin = textContainerOrigin
        return NSRect(x: origin.x + x, y: origin.y + line.minY - size.height - 1,
                      width: ceil(size.width), height: ceil(size.height))
    }

    private func drawCodeLenses(in dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: lensFont, .foregroundColor: Theme.codeLensText]
        let hovered: [NSAttributedString.Key: Any] = [.font: lensFont, .foregroundColor: Theme.codeLensHover]
        for lens in visibleLenses() {
            guard let rect = lensRect(for: lens), rect.intersects(dirtyRect) else { continue }
            (lens.title as NSString).draw(at: rect.origin,
                                          withAttributes: lens.anchor == hoveredLens ? hovered : attributes)
        }
    }

    /// Счётчик под мышью — подсвечен, как ссылка: по нему можно кликнуть.
    private var hoveredLens: Int?

    private func hoverLens(at point: NSPoint?) {
        let lens = point.flatMap { point in visibleLenses().first { lensRect(for: $0)?.contains(point) == true } }
        guard lens?.anchor != hoveredLens else { return }
        for old in codeLenses where old.anchor == hoveredLens {
            if let rect = lensRect(for: old) { setNeedsDisplay(rect) }
        }
        hoveredLens = lens?.anchor
        if let lens, let rect = lensRect(for: lens) { setNeedsDisplay(rect) }
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

/// Пункт меню ⌘.: выполняет своё действие сам, без цепочки ответчиков.
private final class ContextMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ action: ContextAction) {
        handler = action.perform
        super.init(title: action.title, action: #selector(run), keyEquivalent: action.shortcut?.key ?? "")
        target = self
        keyEquivalentModifierMask = action.shortcut?.modifiers ?? []
        image = NSImage(systemSymbolName: action.icon, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) не нужен") }

    @objc private func run() { handler() }
}

/// На macOS 26 NSScrollView кладёт клип-вью под вертикальную линейку —
/// она «плавает» над текстом, и начало строк прячется за гаттером.
/// Возвращаем классическую раскладку: текст начинается справа от линейки.
final class CodeScrollView: NSScrollView {
    /// Колесо и трекпад: прокручивает человек (см. Landing).
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }

    override func tile() {
        super.tile()
        guard rulersVisible, let ruler = verticalRulerView else { return }
        let edge = ruler.frame.maxX
        var clip = contentView.frame
        guard clip.minX < edge else { return }
        clip.size.width -= edge - clip.minX
        clip.origin.x = edge
        contentView.frame = clip
        // Текст не уже клипа: иначе полоса текущей строки обрывалась бы
        // на ширину линейки раньше правого края.
        if let text = documentView as? NSTextView {
            text.minSize = NSSize(width: clip.width, height: text.minSize.height)
            if text.frame.width < clip.width {
                text.setFrameSize(NSSize(width: clip.width, height: text.frame.height))
            }
        }
    }
}

/// Вторая половина той же истории: система считает, что линейка всё ещё
/// лежит поверх текста, и даёт клип-вью отступ слева на её ширину. С ним
/// свайп трекпадом свободно уводит текст на 44 точки вправо, в пустоту,
/// а программная прокрутка встаёт на bounds.x = −44. Раз клип уже справа
/// от линейки, отступ слева ему не нужен; нижний и правый — под полосы
/// прокрутки — остаются.
final class CodeClipView: NSClipView {
    override var contentInsets: NSEdgeInsets {
        get { super.contentInsets }
        set {
            var insets = newValue
            insets.left = 0
            super.contentInsets = insets
        }
    }
}

final class CodeViewController: NSViewController, NSTextViewDelegate {

    /// Курсор поехал — обновляем позицию, от неё зависят все запросы к LSP.
    /// Приходит выделение целиком: с выделенного начинают поиск.
    var onCaretChange: ((NSRange) -> Void)?
    /// ⌘+клик по символу.
    var onGoToDefinition: ((Int) -> Void)?
    /// ⌘ зажат, и мышь остановилась на символе: клик по нему, скорее всего,
    /// будет — пусть готовятся заранее. `nil` — ⌘ отпустили или мышь ушла.
    var onCommandHover: ((Int?) -> Void)?
    /// Варианты дополнения в позиции: `trigger` — символ, открывший список
    /// (например «.»), `retrigger` — переспросить при неполном списке.
    var requestCompletions: ((_ offset: Int, _ trigger: String?, _ retrigger: Bool) async -> CompletionList?)?
    /// Символы, после которых список открывается сам.
    var completionTriggers: Set<String> = ["."]
    /// Подсказка Copilot у курсора и что сказать серверу о её судьбе.
    var requestSuggestion: ((Int) async -> CopilotSuggestion?)?
    var onSuggestionShown: ((CopilotSuggestion) -> Void)?
    var onSuggestionAccepted: ((CopilotSuggestion) -> Void)?
    /// Клик по номеру строки — показать, что с ней: удалённое, треды ревью.
    var onLineClick: ((Int) -> Void)? {
        didSet { if isViewLoaded { applyLineHandlers() } }
    }
    /// «Комментировать строку» в меню текста; nil — пункта нет.
    var onCommentLine: ((Int) -> Void)? {
        didSet { if isViewLoaded { applyLineHandlers() } }
    }
    /// Клик по самому номеру строки — точка останова; nil — как onLineClick.
    var onBreakpointClick: ((Int) -> Void)? {
        didSet { if isViewLoaded { applyLineHandlers() } }
    }
    /// Условие точки на строке (правый клик по номеру); nil — условий нет.
    var onBreakpointCondition: ((Int, String?) -> Void)? {
        didSet { if isViewLoaded { applyLineHandlers() } }
    }
    /// Что можно сделать в позиции — для меню ⌘. Правку текста
    /// (комментарий, дополнение) меню добавляет само.
    var contextActions: ((Int) -> [ContextActionGroup])?
    /// Пункты в начало меню правого клика для символа под мышью.
    var textMenuActions: ((Int) -> [ContextAction])? {
        didSet { if isViewLoaded { textView.textMenuActions = textMenuActions } }
    }
    /// Исправления и рефакторинги Rustlyn для выделения — их ждут до показа меню.
    var codeActions: ((NSRange) async -> [ContextActionGroup])?

    /// Документация имени в позиции (⌃J, наведение мышью) и перегрузки
    /// вызова, в скобках которого курсор. `nil` — ответить нечем.
    var requestDocumentation: ((Int) async -> RustlynDocumentation?)?
    var requestSignatures: ((Int) async -> RustlynSignatures?)?
    /// Шаги ⌃W по синтаксическому дереву — для C#.
    var selectionSteps: ((NSRange) -> [NSRange]?)? {
        didSet { if isViewLoaded { textView.selectionSteps = selectionSteps } }
    }

    private let scrollView = CodeScrollView()
    private var textView: CodeTextView!
    private var ruler: LineNumberRuler?
    private var popover: NSPopover?

    /// Обработчики приходят из SwiftUI и до создания вьюх, и после.
    private func applyLineHandlers() {
        ruler?.onLineClick = onLineClick
        ruler?.onBlameClick = onBlameClick
        ruler?.onBreakpointClick = onBreakpointClick
        ruler?.onBreakpointContext = onBreakpointCondition == nil ? nil : { [weak self] line in
            self?.editBreakpointCondition(line)
        }
        textView.onCommentLine = onCommentLine.map { handler in
            { [weak self] offset in
                guard let self, let model = self.model else { return }
                handler(model.line(containing: min(offset, max(0, model.units.count - 1))))
            }
        }
    }

    private var buffer: TextBuffer?
    private var model: SyntaxModel? { buffer?.model }
    /// Смысловые украшения; перечитываются через `invalidateDecorations()`.
    var decorator: CodeDecorator?
    private var fontSize: CGFloat = 12.5
    private var isApplying = false
    /// Идёт `highlightVisible` — второй раз, изнутри раскладки, в неё не входим.
    private var isHighlighting = false
    /// Идёт подмена хранилища: покрашенное сейчас она же и сотрёт.
    private var isReplacingStorage = false
    /// Перекраска после правки уже назначена на следующий виток.
    private var repaintScheduled = false
    /// Покрашенный участок текста. В символах, а не строках: временные
    /// атрибуты едут вместе с текстом, и участок сдвигается вслед за правками.
    private var painted: NSRange?
    /// Правленый текст, ещё не перекрашенный, — вместе с тем, что за правкой
    /// разобралось по-новому (после открытого `/*`, например).
    private var unpainted: NSRange?
    private var occurrences: [NSRange] = []
    /// Ошибки файла, сдвинутые вслед за правками.
    fileprivate var diagnostics: [RustlynDiagnostic] = []
    fileprivate let info = InfoPopup()
    fileprivate var signatureTask: Task<Void, Never>?
    fileprivate var documentationTask: Task<Void, Never>?
    fileprivate var hoverTask: Task<Void, Never>?
    /// Окно подсказки открыто наведением мыши: его прячет уход мыши, а не
    /// движение курсора.
    fileprivate var hoverShown = false
    /// О каком куске текста окно, открытое мышью: пока она над ним, окно стоит.
    fileprivate var hoverRange: NSRange?
    /// Ошибка, которую оно объясняет первой: ⌘. при открытом окне — о ней.
    fileprivate var hoverProblem: NSRange?
    /// Слово под мышью с зажатым ⌘ и отложенный рассказ о нём.
    fileprivate var commandHoverWord: NSRange?
    fileprivate var commandHoverTask: Task<Void, Never>?
    fileprivate var foldRegions: [FoldRegion] = []
    fileprivate var foldWork: DispatchWorkItem?
    /// Подсказки и счётчики, как пришли: при смене шрифта раскладываются заново.
    fileprivate var insights = RustlynInsights()
    /// Клик по счётчику использований — позиция имени.
    var onLensClick: ((Int) -> Void)?

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
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // Редактор кода: никакой «умной» типографики и автозамен.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = font
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.caret
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.typingAttributes = [.font: font, .foregroundColor: Theme.color(.plain)]
        textView.textContainerInset = NSSize(width: 4, height: 10)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self
        textView.onCommandClick = { [weak self] index in
            // Клик уже здесь: отложенное «мышь над словом» опоздало, а после
            // перехода в другой файл его позиция была бы в чужом тексте.
            self?.commandHoverTask?.cancel()
            self?.onGoToDefinition?(index)
        }
        textView.onCommandHover = { [weak self] index in self?.commandHovered(index) }
        textView.onCompletionRequest = { [weak self] in
            self?.requestCompletion(trigger: nil, manual: true)
        }
        textView.onQuickDocumentation = { [weak self] in self?.showDocumentation() }
        textView.onParameterInfo = { [weak self] in self?.requestSignatureHelp(manual: true) }
        textView.onProblemDescription = { [weak self] in self?.showProblemDescription() }
        textView.onHover = { [weak self] index in self?.hovered(index) }
        textView.onKeyDown = { [weak self] event in self?.keyPressed(event) }
        textView.onUnfold = { [weak self] range in self?.unfold(range) }
        textView.onFoldCommand = { [weak self] command in self?.fold(command) }
        textView.onLens = { [weak self] target in self?.onLensClick?(target) }
        textView.selectionSteps = selectionSteps
        textView.textMenuActions = textMenuActions
        textView.onUserInput = { [weak self] in self?.cancelLanding() }
        scrollView.onUserScroll = { [weak self] in self?.cancelLanding() }
        layout.delegate = self

        scrollView.contentView = CodeClipView()
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
        ruler.onFoldClick = { [weak self] line in self?.toggleFold(line: line) }
        applyLineHandlers()

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // Клип вырос — закрыли панель снизу, растянули окно, новый редактор
        // получил размер: границы клипа при этом не сдвигаются, boundsDidChange
        // не приходит, а строк на экране стало больше, чем покрашено с запасом.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportResized),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(colorSchemeChanged), name: ThemeStore.didChange, object: nil)
        // Бегунок и трекпад — тоже прокрутка человеком.
        NotificationCenter.default.addObserver(
            self, selector: #selector(userScrolled), name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView)

        popup.onPick = { [weak self] index in self?.acceptCompletion(index) }

        self.view = scrollView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Ушли в другое приложение или окно — список дополнений закрываем.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResigned),
            name: NSWindow.didResignKeyNotification, object: view.window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func focusText() {
        view.window?.makeFirstResponder(textView)
    }

    /// Действие панели поиска. Показ панели сам отдаёт фокус её полю.
    func performFind(_ action: NSTextFinder.Action) {
        // Поиск сам ведёт выделение — место перехода больше не держим.
        cancelLanding()
        let clip = scrollView.contentView
        let insetBefore = clip.contentInsets.top
        func perform(_ action: NSTextFinder.Action) {
            let sender = NSMenuItem()
            sender.tag = action.rawValue
            textView.performTextFinderAction(sender)
        }
        // Выделенное — сразу в поле, как в Rider: ⌘F по выделенному слову
        // ищет его. Выделенный блок кода запросом не бывает.
        let selection = textView.selectedRange()
        if action == .showFindInterface || action == .showReplaceInterface,
           selection.length > 0, selection.length <= 256,
           !(textView.string as NSString).substring(with: selection).contains(where: \.isNewline) {
            perform(.setSearchString)
        }
        perform(action)
        // На macOS 26 панель не раздвигает текст, а ложится поверх него
        // отступом клипа, и первая строка файла пряталась под ней. Сдвигаем
        // текст на её высоту: видно ровно то же, что и до ⌘F.
        let delta = clip.contentInsets.top - insetBefore
        if delta > 0 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY - delta))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: - Показ буфера

    /// У каждого буфера свой NSTextStorage: подменяем его под layout manager,
    /// а не переписываем текст — так правки и история отмены остаются
    /// с файлом, пока смотрим другие.
    ///
    /// Возвращает место перехода (`buffer.landing`), на котором вкладка
    /// показана; nil — перехода не было.
    @discardableResult
    func show(_ buffer: TextBuffer) -> NSRange? {
        saveViewState()
        cancelLanding()
        self.buffer?.onDisplayEdit = nil
        self.buffer?.onDisplayRecolor = nil
        hideCompletion()
        closePopover()
        commandHovered(nil)   // слово под мышью было в прежнем тексте
        self.buffer = buffer
        painted = nil
        unpainted = nil
        buffer.onDisplayEdit = { [weak self] range, delta, settled in
            self?.textEdited(range, delta: delta, settled: settled)
        }
        buffer.onDisplayRecolor = { [weak self] in self?.invalidateDecorations() }
        // Версия файла из MR — только для чтения: её правки некуда сохранить.
        textView.isEditable = !buffer.isReadOnly

        let font = Theme.editorFont(size: fontSize)
        if buffer.fontSize != fontSize {
            isApplying = true
            buffer.storage.addAttribute(.font, value: font,
                                        range: NSRange(location: 0, length: buffer.storage.length))
            isApplying = false
            buffer.fontSize = fontSize
            buffer.fixAttributesAhead()
        }
        // Свёрнутое — до подмены хранилища: глифы нового текста строятся с
        // оглядкой на него, а старое сюда не относится.
        // Подсказки прошлого файла — тоже до подмены: к новому тексту они
        // не относятся, а свои придут после проверки.
        insights = RustlynInsights()
        textView.inlayHints = []
        dropGhost()
        textView.codeLenses = []
        textView.foldedRanges = buffer.folded
        ruler?.hiddenRanges = buffer.folded
        replaceStorage(with: buffer.storage)
        // Подмена хранилища выделение не трогает: оно остаётся от прошлого
        // файла и может лежать за концом этого. Первое же чтение атрибутов
        // по нему (typingAttributes → updateFontPanel) — NSRangeException,
        // поэтому ставим выделение раньше всего остального.
        // Вкладку, открытую переходом, — на месте перехода; где уже были —
        // ровно как её оставили; новую — с начала (см. Landing.start).
        let length = buffer.storage.length
        let target = buffer.landing.map { Self.clamped(buffer.model.nsRange(for: $0), to: length) }
        // Место перехода теперь держит редактор; вкладке оно больше не нужно.
        buffer.landing = nil
        let start = Landing.start(target: target, hasSaved: buffer.viewState != nil)
        switch start {
        case .target(let range):
            textView.setSelectedRange(range)
        case .saved:
            textView.setSelectedRange(Self.clamped(buffer.viewState?.selection ?? NSRange(), to: length))
        case .top:
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        textView.breakUndoCoalescing()
        textView.typingAttributes = [.font: font, .foregroundColor: Theme.color(.plain)]
        textView.indentUnit = buffer.indentUnit
        textView.lineEnding = buffer.lineEnding
        textView.lineCommentToken = buffer.model.spec?.lineComments.first.map { String(decoding: $0, as: UTF8.self) }
        textView.colonOpensBlock = buffer.model.spec?.indentBased ?? false
        let spec = buffer.model.spec
        textView.autoPairs = spec != nil && spec?.name != "Markdown"
        textView.autoPairQuotes = AutoPairs.quotes(for: spec)

        dismissInfo()
        info.hide()
        diagnostics = []
        textView.diagnostics = []
        ruler?.setDiagnostics([])
        foldRegions = []
        ruler?.foldRegions = [:]
        applyFolded(buffer.folded, invalidate: false)
        scheduleFoldRegions(delay: 0)

        ruler?.model = buffer.model
        rulerLineCount = buffer.model.lineCount
        ruler?.eventLines = Self.gutterMarkers(for: buffer.document)
        ruler?.invalidateWidth()
        switch start {
        case .target(let range):
            land(on: range)
        case .saved:
            if let state = buffer.viewState {
                scroll(toLine: state.topLine, offset: state.topOffset, x: state.scrollX)
                // Высота текста после подмены хранилища досчитывается не сразу,
                // и далёкая строка могла упереться в старую. Второй проход, когда
                // раскладка дошла, почти всегда ничего не двигает. Переход,
                // пришедший тем временем, важнее — его место не трогаем.
                DispatchQueue.main.async { [weak self, weak buffer] in
                    guard let self, let buffer, self.buffer === buffer, self.landing == nil else { return }
                    self.scroll(toLine: state.topLine, offset: state.topOffset, x: state.scrollX)
                }
            }
        case .top:
            textView.scroll(NSPoint(x: 0, y: 0))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        }
        ruler?.currentLine = buffer.model.line(containing: min(textView.selectedRange().location,
                                                               max(0, buffer.model.units.count - 1)))
        highlightVisible()
        textView.updateCurrentLineHighlight()
        EditorStability.shared?.shown(self)
        return target
    }

    /// Диапазон, подрезанный по длине текста.
    static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        return NSRange(location: location, length: max(0, min(range.length, length - location)))
    }

    /// Подсветка живёт во временных атрибутах раскладки, а не в тексте:
    /// они привязаны к позициям, и чужой файл не должен их унаследовать.
    ///
    /// Подмена меняет высоту текста, клип об этом сообщает — и
    /// `highlightVisible` звался прямо изнутри неё: красил новый текст,
    /// запоминал покрашенное, а следующая строка здесь цвета стирала. Экран
    /// оставался без подсветки, а редактор считал его покрашенным — до
    /// прокрутки или правки. Бывало это не всегда: только если высота текста
    /// у файлов разная. Поэтому пока идёт подмена, не красим, а покрашенным
    /// после неё не считается ничего.
    private func replaceStorage(with storage: NSTextStorage) {
        guard let layout = textView.layoutManager else { return }
        isReplacingStorage = true
        defer {
            isReplacingStorage = false
            painted = nil
            unpainted = nil
        }
        clearTemporaryAttributes(layout)
        layout.replaceTextStorage(storage)
        clearTemporaryAttributes(layout)
    }

    private func clearTemporaryAttributes(_ layout: NSLayoutManager) {
        let length = layout.textStorage?.length ?? 0
        if length > 0 { layout.setTemporaryAttributes([:], forCharacterRange: NSRange(location: 0, length: length)) }
    }

    /// Запоминает, что было на экране: выделение и первую видимую строку.
    func saveViewState() {
        guard let buffer, let layout = textView.layoutManager, let container = textView.textContainer
        else { return }
        let bounds = scrollView.contentView.bounds
        let y = max(0, bounds.minY - textView.textContainerInset.height)
        var topLine = 0
        var topOffset: CGFloat = 0
        if buffer.storage.length > 0 {
            let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
            let character = layout.characterIndexForGlyph(at: glyph)
            topLine = buffer.model.line(containing: min(character, max(0, buffer.model.units.count - 1)))
            let lineGlyph = layout.glyphIndexForCharacter(at: Int(buffer.model.lineStarts[topLine]))
            topOffset = y - layout.lineFragmentRect(forGlyphAt: lineGlyph, effectiveRange: nil).minY
        }
        buffer.viewState = TextBuffer.ViewState(selection: textView.selectedRange(), topLine: topLine,
                                                topOffset: max(0, topOffset), scrollX: bounds.minX)
    }

    /// Ставит строку к верхнему краю. Как и `scrollCentering`, уточняет
    /// позицию после раскладки: до неё координата далёкой строки — оценка.
    private func scroll(toLine line: Int, offset: CGFloat, x: CGFloat) {
        guard let model, let layout = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return }
        let line = max(0, min(line, model.lineCount - 1))
        let character = min(Int(model.lineStarts[line]), storage.length - 1)
        let clip = scrollView.contentView
        for _ in 0..<4 {
            let glyph = layout.glyphIndexForCharacter(at: character)
            layout.ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let target = NSPoint(x: x, y: max(0, rect.minY + textView.textContainerInset.height + offset))
            if abs(clip.bounds.origin.y - target.y) < 1, abs(clip.bounds.origin.x - target.x) < 1 { break }
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
            layout.ensureLayout(forBoundingRect: clip.bounds, in: container)
        }
        highlightVisible()
    }

    /// Разбор файла обновился (правка, индекс ассетов) — перекрашиваем
    /// ссылки и значки, текст не трогаем.
    func invalidateDecorations() {
        if let buffer { ruler?.eventLines = Self.gutterMarkers(for: buffer.document) }
        ruler?.needsDisplay = true
        painted = nil
        highlightVisible()
    }

    /// Значки в колонке номеров: методы, которые вызывает движок.
    private static func gutterMarkers(for doc: LoadedDocument) -> Set<Int> {
        Set(doc.outline.lazy.filter { $0.kind == .unityMessage }.map(\.line))
    }

    /// Правки инспектора — через текстовое поле, как если бы их набрали:
    /// так они попадают в ту же историю ⌘Z, помечают файл несохранённым
    /// и уходят языковому серверу обычным путём. Одна группа отмены на
    /// всю правку: поворот — это семь чисел, а отменяется одним ⌘Z.
    @discardableResult
    func apply(_ request: TextEditRequest) -> Bool {
        guard let buffer, request.buffer === buffer, let storage = textView.textStorage,
              UnityEdits.validate(request.edits, in: storage.string as NSString) else { return false }
        cancelLanding()
        let undo = textView.undoManager
        // Не набор: дополнение на `0.5` открываться не должно.
        isApplyingCompletion = true
        defer { isApplyingCompletion = false }
        textView.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        // С конца к началу: ранние диапазоны не сдвигаются от поздних правок.
        for edit in request.edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard textView.shouldChangeText(in: edit.range, replacementString: edit.text) else { continue }
            storage.replaceCharacters(in: edit.range, with: edit.text)
            textView.didChangeText()
        }
        undo?.setActionName(request.actionName)
        undo?.endUndoGrouping()
        textView.breakUndoCoalescing()
        return true
    }

    func showEmpty() {
        saveViewState()
        cancelLanding()
        self.buffer?.onDisplayEdit = nil
        self.buffer?.onDisplayRecolor = nil
        hideCompletion()
        closePopover()
        commandHovered(nil)   // слово под мышью было в прежнем тексте
        buffer = nil
        dismissInfo()
        info.hide()
        diagnostics = []
        textView.diagnostics = []
        // Подсказки прошлого файла — не отсюда; раскладку нового хранилища
        // TextKit строит с нуля, так что просто забываем.
        insights = RustlynInsights()
        textView.inlayHints = []
        dropGhost()
        textView.codeLenses = []
        textView.foldedRanges = []
        ruler?.hiddenRanges = []
        ruler?.foldRegions = [:]
        ruler?.setDiagnostics([])
        // Пустое хранилище вместо стирания текста: буфер мог остаться
        // в памяти с несохранёнными правками.
        replaceStorage(with: NSTextStorage())
        ruler?.model = nil
        ruler?.eventLines = []
        ruler?.setChanges([])
        ruler?.setCommentMarks([:], column: false)
        ruler?.blame = nil
    }

    /// Точки останова в гаттере.
    func setBreakpoints(_ marks: [Int: BreakpointMark]) {
        ruler?.breakpoints = marks
    }

    /// Строка, где стоит программа: стрелка в гаттере и полоса под текстом.
    /// Прокрутку к ней делает переход редактора, а не эта отметка.
    func setExecutionLine(_ line: Int?) {
        ruler?.executionLine = line
        guard let line, let model, line < model.lineCount else {
            textView.executionRange = nil
            return
        }
        let range = model.lineRange(line)
        textView.executionRange = NSRange(location: range.lowerBound, length: range.count)
    }

    /// Треды ревью — значками у строк. `column` оставляет под них место
    /// и тогда, когда тредов ещё нет: иначе гаттер дёргался бы от первого.
    func setCommentMarks(_ marks: [Int: CommentMark], column: Bool) {
        ruler?.setCommentMarks(marks, column: column)
    }

    /// Авторы строк слева от номеров; nil — колонки нет.
    func setBlame(_ blame: BlameColumn?) {
        ruler?.blame = blame
    }

    /// Клик по автору строки.
    var onBlameClick: ((Int) -> Void)? {
        didSet { if isViewLoaded { ruler?.onBlameClick = onBlameClick } }
    }

    // MARK: - Всплывающее окно у строки

    /// Окно рядом с номером строки: что было удалено, треды, новый комментарий.
    func presentPopover(line: Int, content: AnyView) {
        closePopover()
        guard let ruler, ruler.rect(forLine: line) != nil else { return }
        scrollLineIntoView(line)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        // Прямоугольник — после прокрутки: строка могла сдвинуться.
        guard let rect = ruler.rect(forLine: line) else { return }
        popover.show(relativeTo: rect, of: ruler, preferredEdge: .maxX)
        self.popover = popover
    }

    func closePopover() {
        popover?.close()
        popover = nil
    }

    /// Окно условия точки у номера строки. Точки ещё нет — встанет с условием.
    private func editBreakpointCondition(_ line: Int) {
        guard let onBreakpointCondition else { return }
        let mark = ruler?.breakpoints[line]
        let editor = BreakpointConditionEditor(
            line: line, condition: mark?.condition ?? "", hasBreakpoint: mark != nil,
            commit: { [weak self] text in
                onBreakpointCondition(line, text)
                self?.closePopover()
            },
            cancel: { [weak self] in self?.closePopover() })
        presentPopover(line: line,
                       content: AnyView(editor.preferredColorScheme(Theme.current.isDark ? .dark : .light)))
    }

    // MARK: - Конфликты слияния

    private var conflicts: [MergeConflict] = []
    /// Кнопки «принять» у строк `<<<<<<<`, по строке маркера.
    private var conflictStrips: [Int: NSHostingView<ConflictStrip>] = [:]

    func setConflicts(_ fresh: [MergeConflict]) {
        conflicts = fresh
        guard let model else {
            textView.conflictBands = []
            removeConflictStrips()
            return
        }
        var bands: [(range: NSRange, color: NSColor)] = []
        func band(_ lines: Range<Int>, _ color: NSColor) {
            guard !lines.isEmpty, lines.upperBound <= model.lineCount else { return }
            let from = model.lineRange(lines.lowerBound).lowerBound
            let to = model.lineRange(lines.upperBound - 1).upperBound
            bands.append((NSRange(location: from, length: to - from), color))
        }
        for conflict in fresh {
            band(conflict.start..<(conflict.start + 1), Theme.conflictMarker)
            band(conflict.current, Theme.conflictCurrent)
            if let base = conflict.base {
                band(base..<(base + 1), Theme.conflictMarker)
                band(conflict.common ?? base..<base, Theme.conflictBase)
            }
            band(conflict.separator..<(conflict.separator + 1), Theme.conflictMarker)
            band(conflict.incoming, Theme.conflictIncoming)
            band(conflict.end..<(conflict.end + 1), Theme.conflictMarker)
        }
        textView.conflictBands = bands
        layoutConflictStrips()
    }

    private func removeConflictStrips() {
        conflictStrips.values.forEach { $0.removeFromSuperview() }
        conflictStrips = [:]
    }

    /// Кнопки — подвиды текста: прокручиваются вместе с ним сами. Место
    /// пересчитываем, когда могла сдвинуться раскладка: правка, шрифт,
    /// прокрутка к ещё не разложенным строкам.
    private func layoutConflictStrips() {
        guard let buffer, !buffer.isReadOnly, let layout = textView.layoutManager else {
            removeConflictStrips()
            return
        }
        let model = buffer.model
        let starts = Set(conflicts.map(\.start))
        for (line, strip) in conflictStrips where !starts.contains(line) {
            strip.removeFromSuperview()
            conflictStrips[line] = nil
        }
        for conflict in conflicts where conflict.start < model.lineCount {
            let lineStart = model.lineRange(conflict.start).lowerBound
            guard lineStart < buffer.storage.length else { continue }
            let glyph = layout.glyphIndexForCharacter(at: lineStart)
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let fragment = layout.textLineRect(forGlyphAt: glyph)

            let content = ConflictStrip(conflict: conflict) { [weak self] choice in
                self?.applyConflictAction(start: conflict.start, choice: choice)
            }
            let strip: NSHostingView<ConflictStrip>
            if let existing = conflictStrips[conflict.start] {
                strip = existing
                strip.rootView = content
            } else {
                strip = NSHostingView(rootView: content)
                textView.addSubview(strip)
                conflictStrips[conflict.start] = strip
            }
            let size = strip.fittingSize
            let origin = textView.textContainerOrigin
            strip.frame = NSRect(x: origin.x + used.maxX + 16,
                                 y: origin.y + fragment.minY + (fragment.height - size.height) / 2,
                                 width: size.width, height: size.height)
        }
    }

    /// Правка — через редактор, как если бы её набрали: попадает в ⌘Z,
    /// модель и языковой сервер узнают о ней обычным путём. Конфликты
    /// ищутся заново по текущему тексту — переданный номер строки мог
    /// устареть на одну правку.
    func applyConflictAction(start: Int?, choice: ConflictChoice) {
        guard let buffer, !buffer.isReadOnly else { return }
        let fresh = MergeConflicts.find(in: buffer.model)
        let targets = start.map { line in fresh.filter { $0.start == line } } ?? fresh
        guard !targets.isEmpty else { NSSound.beep(); return }
        cancelLanding()
        var caret = 0
        // Снизу вверх: правка ниже не сдвигает строки выше.
        for conflict in targets.sorted(by: { $0.start > $1.start }) {
            let (range, text) = MergeConflicts.resolution(of: conflict, choice: choice, in: buffer.model)
            textView.replace(range, with: text)
            caret = range.location
        }
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        view.window?.makeFirstResponder(textView)
    }

    private func scrollLineIntoView(_ line: Int) {
        guard let model, line < model.lineCount else { return }
        textView.scrollRangeToVisible(NSRange(location: Int(model.lineStarts[line]), length: 0))
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        buffer?.undoManager
    }

    // MARK: - Курсор и правки

    func textViewDidChangeSelection(_ notification: Notification) {
        if textView.updateCurrentLineHighlight() { ruler?.needsDisplay = true }
        if let model {
            ruler?.currentLine = model.line(containing: min(textView.selectedRange().location,
                                                            max(0, model.units.count - 1)))
        }
        if popup.isVisible && !isCaretInSession { hideCompletion() }
        // Курсор ушёл от серого текста — подсказка больше не к месту. После
        // набора сюда приходят раньше textDidChange, поэтому решаем на
        // следующем витке, когда подсказка уже сдвинута за курсором.
        if textView.ghost != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, let ghost = self.textView.ghost else { return }
                let selection = self.textView.selectedRange()
                if selection.length > 0 || selection.location != ghost.position { self.dropGhost() }
            }
        }
        caretMovedForHelpers()
        onCaretChange?(textView.selectedRange())
    }

    /// Что сейчас набирают — нужно, чтобы решить, открывать ли дополнение.
    private var pendingInput: String?
    /// Сколько строк было, когда гаттер рисовали после правки.
    private var rulerLineCount = 0

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                  replacementString: String?) -> Bool {
        let undoing = buffer?.undoManager.isUndoing == true || buffer?.undoManager.isRedoing == true
        pendingInput = undoing || isApplyingCompletion ? nil : replacementString
        return true
    }

    /// Текст уже в модели (TextBuffer правит её в том же вызове) — осталось
    /// перекрасить видимое и решить судьбу списка дополнений.
    func textDidChange(_ notification: Notification) {
        // Окно об ошибке или имени — уже не о том тексте.
        dismissInfo()
        repaintEdited()
        highlightVisible(toolTips: false)
        // Номера и пометки у строк сдвигаются, только когда меняется число
        // строк; буква внутри строки гаттер не трогает.
        if let model, model.lineCount != rulerLineCount {
            rulerLineCount = model.lineCount
            if String(model.lineCount).count != ruler?.digits { ruler?.invalidateWidth() }
            ruler?.needsDisplay = true
        }

        let input = pendingInput
        pendingInput = nil
        completionAfterEdit(input)
        suggestionAfterEdit(input)
    }

    /// Клавиши, пока открыт список: стрелки ходят по нему, Return и Tab
    /// вставляют, Esc закрывает. Esc без списка — открывает его, как в Xcode.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if popup.isVisible {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):        moveCompletion(-1); return true
            case #selector(NSResponder.moveDown(_:)):      moveCompletion(1); return true
            case #selector(NSResponder.pageUp(_:)),
                 #selector(NSResponder.scrollPageUp(_:)):  moveCompletion(-CompletionPopup.maxVisibleRows); return true
            case #selector(NSResponder.pageDown(_:)),
                 #selector(NSResponder.scrollPageDown(_:)): moveCompletion(CompletionPopup.maxVisibleRows); return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):     acceptCompletion(selectedRow); return true
            case #selector(NSResponder.cancelOperation(_:)): hideCompletion(); return true
            default: return false
            }
        }
        // Окно об ошибке или документации: Esc прячет его, и только.
        if selector == #selector(NSResponder.cancelOperation(_:)), info.isVisible, !info.isSignatureHelp {
            dismissInfo()
            return true
        }
        // Серый текст Copilot: Tab — принять, Esc — убрать.
        if self.textView.ghost != nil {
            switch selector {
            case #selector(NSResponder.insertTab(_:)): acceptSuggestion(); return true
            case #selector(NSResponder.cancelOperation(_:)): dropGhost(); return true
            default: break
            }
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            requestCompletion(trigger: nil, manual: true)
            return true
        }
        return false
    }

    // MARK: - Подсказка Copilot

    private var suggestion: CopilotSuggestion?
    private var suggestionTask: Task<Void, Never>?
    /// Растёт с каждой правкой: ответ на запрос по старому тексту не нужен.
    private var editGeneration = 0

    /// После набора — подсказка. Набранное совпало с началом серого текста —
    /// подсказка остаётся и сдвигается, как в VS Code; иначе — новая.
    private func suggestionAfterEdit(_ input: String?) {
        editGeneration += 1
        suggestionTask?.cancel()
        guard let input, requestSuggestion != nil else {
            dropGhost()
            return
        }
        if var current = suggestion, !input.contains("\n"), let model {
            let caret = textView.selectedRange().location
            if current.range.end.line == model.position(at: caret).line {
                current.range.end.character += input.utf16.count
            }
            if show(current) { return }
        }
        dropGhost()
        guard !popup.isVisible else { return }
        let generation = editGeneration
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, let request = self.requestSuggestion else { return }
            let selection = self.textView.selectedRange()
            guard selection.length == 0 else { return }
            guard let found = await request(selection.location), !Task.isCancelled,
                  generation == self.editGeneration, !self.popup.isVisible,
                  self.textView.selectedRange() == selection else { return }
            if self.show(found) { self.onSuggestionShown?(found) }
        }
    }

    /// Показать подсказку у курсора. false — она сюда не ложится: набрано
    /// не то, что она продолжает, или хвост строки с ней не сходится.
    @discardableResult
    private func show(_ found: CopilotSuggestion) -> Bool {
        guard let model, let storage = textView.textStorage, let font = textView.font else { return false }
        let text = storage.string as NSString
        let caret = textView.selectedRange().location
        let range = model.nsRange(for: found.range)
        guard range.location <= caret, NSMaxRange(range) >= caret || found.range.end.line == model.position(at: caret).line
        else { return false }
        let end = max(caret, NSMaxRange(range))
        let typed = text.substring(with: NSRange(location: range.location, length: caret - range.location))
        let insert = found.insertText as NSString
        guard insert.length > typed.utf16.count, found.insertText.hasPrefix(typed) else { return false }
        let remaining = insert.substring(from: typed.utf16.count)
        var lines = remaining.components(separatedBy: "\n")
        let first = lines.removeFirst()

        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        var lineEnd = NSMaxRange(lineRange)
        if lineEnd > lineRange.location, text.character(at: lineEnd - 1) == 0x0A { lineEnd -= 1 }
        let replaced = text.substring(with: NSRange(location: caret, length: min(end, lineEnd) - caret))
        let afterRange = text.substring(with: NSRange(location: min(end, lineEnd), length: lineEnd - min(end, lineEnd)))
        let blank = { (s: String) in s.allSatisfy { $0 == " " || $0 == "\t" } }

        var inline = first
        if lines.isEmpty {
            // Хвост, который подсказка заменяет, — её же конец: рисуем только
            // середину, хвост остаётся настоящим текстом.
            if !replaced.isEmpty, first.hasSuffix(replaced) {
                inline = String(first.dropLast(replaced.count))
            } else if !blank(replaced) {
                return false
            }
        } else if !blank(replaced + afterRange) {
            // Многострочная — только у конца строки: иначе её строки встали
            // бы между кодом.
            return false
        }
        let tailIsCode = !blank(text.substring(with: NSRange(location: caret, length: lineEnd - caret)))
        let gap = tailIsCode && !inline.isEmpty
            ? ceil((inline as NSString).size(withAttributes: [.font: font]).width) : 0
        let height = textView.layoutManager?.defaultLineHeight(for: font) ?? 16
        let anchor = lineEnd < text.length ? lineEnd + 1 : nil
        let ghost = CodeTextView.Ghost(position: caret, inline: inline, gap: gap, lines: lines,
                                       anchor: lines.isEmpty ? nil : anchor,
                                       space: CGFloat(lines.count) * height)
        let old = textView.ghost
        suggestion = found
        textView.ghost = ghost
        invalidateGhostLayout(old)
        invalidateGhostLayout(ghost)
        return true
    }

    private func dropGhost() {
        suggestionTask?.cancel()
        suggestion = nil
        guard let old = textView.ghost else { return }
        textView.ghost = nil
        invalidateGhostLayout(old)
    }

    /// Зазор и место под строками — дело раскладки: пересчитать там, где они.
    private func invalidateGhostLayout(_ ghost: CodeTextView.Ghost?) {
        guard let ghost, let layout = textView.layoutManager, let length = textView.textStorage?.length,
              length > 0 else { return }
        let whole = NSRange(location: 0, length: length)
        if ghost.gap > 0 {
            let at = NSIntersectionRange(NSRange(location: ghost.position, length: 1), whole)
            if at.length > 0 {
                layout.invalidateGlyphs(forCharacterRange: at, changeInLength: 0, actualCharacterRange: nil)
                layout.invalidateLayout(forCharacterRange: at, actualCharacterRange: nil)
            }
        }
        if let anchor = ghost.anchor {
            let at = NSIntersectionRange(NSRange(location: anchor, length: 1), whole)
            if at.length > 0 { layout.invalidateLayout(forCharacterRange: at, actualCharacterRange: nil) }
        }
        textView.needsDisplay = true
    }

    /// Tab: подсказка встаёт в текст одной правкой — одним ⌘Z.
    private func acceptSuggestion() {
        guard let found = suggestion, let model, let storage = textView.textStorage else { return }
        let caret = textView.selectedRange().location
        var range = model.nsRange(for: found.range)
        range.length = max(NSMaxRange(range), caret) - range.location
        dropGhost()
        isApplyingCompletion = true
        defer { isApplyingCompletion = false }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: found.insertText) else { return }
        storage.replaceCharacters(in: range, with: found.insertText)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Подсказка Copilot"))
        textView.breakUndoCoalescing()
        textView.setSelectedRange(NSRange(location: range.location + (found.insertText as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        onSuggestionAccepted?(found)
    }

    // MARK: - Меню действий (⌘.)

    /// Нативное меню прямо под курсором: на macOS 26 оно само стеклянное,
    /// стрелки, Return, Esc и поиск по первым буквам — штатные.
    func presentContextActions() {
        guard view.window != nil, let buffer else { return }
        cancelLanding()
        hideCompletion()
        // Окно ошибки под мышью обещает «⌘. — исправить»: меню — о ней, и
        // курсор встаёт на неё, как если бы по ней щёлкнули.
        if hoverShown, info.isVisible, !info.isSignatureHelp, let problem = hoverProblem {
            let caret = textView.selectedRange()
            if caret.length > 0 || caret.location < problem.location || caret.location > NSMaxRange(problem) {
                let location = min(problem.location, textView.textStorage?.length ?? 0)
                textView.setSelectedRange(NSRange(location: location, length: 0))
            }
        }
        dismissInfo()
        let selection = textView.selectedRange()
        guard let codeActions else {
            showContextMenu(extra: [], selection: selection)
            return
        }
        // Меню ждёт Rustlyn; курсор за это время мог уйти или вкладка смениться.
        Task { @MainActor [weak self] in
            let extra = await codeActions(selection)
            guard let self, self.buffer === buffer, self.textView.selectedRange() == selection else { return }
            self.showContextMenu(extra: extra, selection: selection)
        }
    }

    private func showContextMenu(extra: [ContextActionGroup], selection: NSRange) {
        guard let window = view.window, let buffer else { return }
        let caret = selection.location
        var groups = extra.filter(\.leading)
        groups += contextActions?(caret) ?? []
        groups += extra.filter { !$0.leading }
        groups.append(ContextActionGroup(title: nil, actions: editingActions(readOnly: buffer.isReadOnly)))

        let menu = NSMenu()
        menu.autoenablesItems = false
        for group in groups where !group.actions.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            if let title = group.title { menu.addItem(.sectionHeader(title: title)) }
            for action in group.actions { menu.addItem(ContextMenuItem(action)) }
        }
        guard menu.numberOfItems > 0 else { NSSound.beep(); return }

        // Курсор мог уехать за край экрана — меню у невидимой строки ни к чему.
        let caretRange = NSRange(location: caret, length: 0)
        var rect = textView.convert(window.convertFromScreen(
            textView.firstRect(forCharacterRange: caretRange, actualRange: nil)), from: nil)
        if !textView.visibleRect.intersects(rect.insetBy(dx: 0, dy: -1)) {
            textView.scrollRangeToVisible(caretRange)
            rect = textView.convert(window.convertFromScreen(
                textView.firstRect(forCharacterRange: caretRange, actualRange: nil)), from: nil)
        }

        // Меню, открытое с клавиатуры, встаёт без выделения — и Return
        // ничего не делает. Стрелка вниз выделяет первый пункт; шлём её,
        // когда меню уже ведёт клавиатуру, — иначе её может забрать текст.
        let arrow = KeyShortcut(NSDownArrowFunctionKey, []).key
        let windowNumber = window.windowNumber
        let tracking = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: menu, queue: nil) { _ in
            guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: windowNumber, context: nil, characters: arrow,
                                              charactersIgnoringModifiers: arrow, isARepeat: false,
                                              keyCode: 125) else { return }
            NSApp.postEvent(down, atStart: false)
        }
        defer { NotificationCenter.default.removeObserver(tracking) }
        // Вьюха перевёрнутая: maxY — низ строки.
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: textView)
    }

    private func editingActions(readOnly: Bool) -> [ContextAction] {
        guard !readOnly else { return [] }
        var actions: [ContextAction] = []
        if textView.lineCommentToken != nil {
            actions.append(ContextAction(title: L("Закомментировать строки"), icon: "text.line.first.and.arrowtriangle.forward",
                                         shortcut: KeymapStore.shared.menuShortcut(.toggleComment)) { [weak self] in
                self?.textView.toggleLineComment(nil)
            })
        }
        actions.append(ContextAction(title: L("Показать варианты"), icon: "list.bullet.rectangle",
                                     shortcut: KeymapStore.shared.menuShortcut(.showCompletions)) { [weak self] in
            self?.requestCompletion(trigger: nil, manual: true)
        })
        return actions
    }

    // MARK: - Автодополнение

    private struct CompletionSession {
        /// Начало слова, которое дополняем.
        var anchor: Int
        /// Где стоял курсор, когда спрашивали: правки сервера — от этой точки.
        var requestOffset: Int
        var list: CompletionList
        var manual: Bool
    }

    private let popup = CompletionPopup()
    private var session: CompletionSession?
    private var filtered: [Int] = []
    private var selectedRow = 0
    /// Выделенный вариант — по имени, а не по номеру: номера смысла не
    /// имеют, когда сервер прислал новый список.
    private var selectedLabel: String?
    private var completionTask: Task<Void, Never>?
    private var isApplyingCompletion = false
    /// Больше строк в список не кладём: дальше человек всё равно допечатает.
    private let maxRows = 200

    private var caret: Int { textView.selectedRange().location }

    /// Начало идентификатора, в конце которого стоит курсор.
    private func wordStart(before offset: Int) -> Int {
        guard let model else { return offset }
        var i = min(offset, model.units.count)
        while i > 0, WordCompletion.isIdentPart(model.units[i - 1]) { i -= 1 }
        return i
    }

    /// Курсор ещё в дополняемом слове — список можно оставить.
    private var isCaretInSession: Bool {
        guard let session else { return false }
        let caret = self.caret
        return textView.selectedRange().length == 0 && caret >= session.anchor && wordStart(before: caret) == session.anchor
    }

    private func completionAfterEdit(_ input: String?) {
        // Скобка и запятая открывают подсказку параметров; закрывающая —
        // переспрашивает: курсор мог выйти во внешний вызов или из всех.
        if let input, input.hasSuffix("(") || input.hasSuffix(",") || (info.isSignatureHelp && input.hasSuffix(")")) {
            requestSignatureHelp(manual: false)
        }
        guard let input, !input.isEmpty else {
            // Стирание, вставка из буфера, отмена: список подстраиваем
            // или закрываем, но сами не открываем.
            if popup.isVisible { isCaretInSession ? refilter() : hideCompletion() }
            return
        }
        let typedWord = input.utf16.allSatisfy(WordCompletion.isIdentPart)
        if completionTriggers.contains(where: { input.hasSuffix($0) }) {
            requestCompletion(trigger: String(input.suffix(1)), manual: false)
        } else if typedWord && input.utf16.count <= 2 {
            if popup.isVisible, isCaretInSession, let session, !session.list.isIncomplete {
                refilter()
            } else {
                requestCompletion(trigger: nil, manual: false, delay: popup.isVisible ? 0 : 90_000_000,
                                  retrigger: popup.isVisible)
            }
        } else {
            hideCompletion()
        }
    }

    private func requestCompletion(trigger: String?, manual: Bool, delay: UInt64 = 0, retrigger: Bool = false) {
        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled, let request = self.requestCompletions else { return }
            let offset = self.caret
            let anchor = self.wordStart(before: offset)
            guard let list = await request(offset, trigger, retrigger), !Task.isCancelled else { return }
            // Пока ждали ответ, курсор мог уйти из слова.
            guard self.wordStart(before: self.caret) == anchor, self.caret >= anchor else { return }
            self.session = CompletionSession(anchor: anchor, requestOffset: offset, list: list,
                                             manual: manual || trigger != nil)
            self.refilter()
        }
    }

    private func refilter() {
        guard let session, let model, let window = view.window else { return hideCompletion() }
        let caret = self.caret
        let prefix = String(decoding: model.units[session.anchor..<max(session.anchor, caret)], as: UTF16.self)
        let items = session.list.items

        // Без сервера и без явной просьбы — не раньше двух букв: иначе список
        // слов выскакивал бы на каждую первую букву.
        let fromWords = items.allSatisfy { $0.edit == nil && $0.kind == 1 || $0.kind == 14 }
        if !session.manual && prefix.utf16.count < (fromWords ? 2 : 1) { return hideCompletion(keepSession: true) }

        filtered = Array(CompletionRanking.rank(items, prefix: prefix).prefix(maxRows))
        // Набрали слово целиком — дополнять нечего.
        if filtered.isEmpty || (filtered.count == 1 && items[filtered[0]].matchText == prefix) {
            return hideCompletion(keepSession: true)
        }
        selectedRow = selectedLabel.flatMap { label in filtered.firstIndex { items[$0].label == label } } ?? 0
        selectedLabel = items[filtered[selectedRow]].label

        let anchorRect = textView.firstRect(forCharacterRange: NSRange(location: session.anchor, length: 0),
                                            actualRange: nil)
        popup.show(rows: filtered.map { items[$0] }, selection: selectedRow, anchor: anchorRect, parent: window)
    }

    private func moveCompletion(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedRow = max(0, min(filtered.count - 1, selectedRow + delta))
        selectedLabel = session.map { $0.list.items[filtered[selectedRow]].label }
        popup.select(selectedRow)
    }

    private func hideCompletion(keepSession: Bool = false) {
        popup.hide()
        if !keepSession {
            session = nil
            selectedLabel = nil
            completionTask?.cancel()
        }
    }

    @objc private func windowResigned() {
        hideCompletion()
        dismissInfo()
        info.hide()
    }

    /// Вставка варианта. Правку сервера растягиваем на то, что успели
    /// допечатать после запроса; сниппет раскрываем и выделяем первую
    /// заглушку; сопутствующие правки (импорты) — выше по файлу, после
    /// основной, чтобы не сдвинуть её координаты.
    private func acceptCompletion(_ row: Int) {
        guard let session, let model, filtered.indices.contains(row) else { return hideCompletion() }
        let item = session.list.items[filtered[row]]
        let caret = self.caret
        let typed = caret - session.requestOffset

        var range: NSRange
        if let edit = item.edit {
            let start = model.offset(at: edit.range.start)
            var end = model.offset(at: edit.range.end)
            if end >= session.requestOffset { end = max(caret, end + typed) }
            range = NSRange(location: min(start, caret), length: max(0, end - min(start, caret)))
        } else {
            range = NSRange(location: session.anchor, length: max(0, caret - session.anchor))
        }
        let expansion = item.isSnippet ? Snippet.expand(item.textToInsert)
                                       : Snippet.Expansion(text: item.textToInsert, selection: nil)
        let additional = item.additionalEdits
            .map { (model.nsRange(for: $0.range), $0.newText) }
            .filter { NSMaxRange($0.0) <= range.location }
            .sorted { $0.0.location > $1.0.location }

        hideCompletion()
        isApplyingCompletion = true
        textView.breakUndoCoalescing()
        textView.replace(range, with: expansion.text)
        var shift = 0
        for (extra, text) in additional {
            textView.replace(extra, with: text)
            shift += (text as NSString).length - extra.length
        }
        isApplyingCompletion = false

        let base = range.location + shift
        let selection = expansion.selection.map { NSRange(location: base + $0.location, length: $0.length) }
            ?? NSRange(location: base + (expansion.text as NSString).length, length: 0)
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
    }

    // MARK: - Переходы (см. Landing)

    /// Переход, который ещё «встаёт»: его место держится, пока человек сам
    /// не тронул текст, а экран не перестал сдвигаться без него.
    private var landing: Landing?
    /// Номер перехода: проверки прежнего не трогают новый.
    private var landingToken = 0
    /// Экран двигаем мы сами — это не повод проверять место.
    private var isPlacing = false
    private var landingCheckQueued = false

    /// Часы для Landing: монотонные, в секундах.
    private var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Запас над и под целью: у самого края строку легко не заметить.
    private var revealMargin: CGFloat {
        2 * (textView.layoutManager?.defaultLineHeight(for: textView.font ?? Theme.editorFont(size: fontSize)) ?? 15)
    }

    func isShowing(_ buffer: TextBuffer) -> Bool { self.buffer === buffer }

    /// Переход в показанном файле: выделить, показать, коротко подсветить.
    /// Без вспышки после перехода глазами не найти, куда именно попал.
    func reveal(range: NSRange) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let safe = Self.clamped(range, to: storage.length)
        land(on: safe)
        onCaretChange?(safe)
    }

    /// Встать на место перехода и держать его. После перехода раскладка
    /// досчитывает высоту текста, SwiftUI даёт вьюхе размер, вкладка
    /// восстанавливает свою прокрутку, над строками появляются счётчики —
    /// поэтому место проверяется на следующих витках и, если его увели,
    /// ставится снова. Клавиша, клик, прокрутка колесом или правка текста
    /// это прекращают: с человеком не спорим.
    private func land(on range: NSRange) {
        landingToken += 1
        landing = Landing(range: range, now: clock)
        place(range)
        flash(range)
        let token = landingToken
        for delay in Landing.checkDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.landingToken == token else { return }
                self.checkLanding()
            }
        }
    }

    /// Выделить и показать — без вспышки. Видна цель — экран не двигается;
    /// нет — она посередине, как в Rider.
    private func place(_ range: NSRange) {
        isPlacing = true
        defer { isPlacing = false }
        if textView.selectedRange() != range { textView.setSelectedRange(range) }
        if !isOnScreen(range) { scrollCentering(range) }
        highlightVisible()
    }

    private func checkLanding() {
        guard var landing else { return }
        guard let storage = textView.textStorage, NSMaxRange(landing.range) <= storage.length else {
            self.landing = nil
            return
        }
        if landing.needsFix(selection: textView.selectedRange(), onScreen: isOnScreen(landing.range)) {
            place(landing.range)
        }
        self.landing = landing.isOver(now: clock) ? nil : landing
    }

    /// Человек взялся за текст сам, сменили вкладку, правят текст — место
    /// перехода больше не держим.
    private func cancelLanding() {
        guard landing != nil else { return }
        landing = nil
        landingToken += 1
    }

    @objc private func userScrolled() { cancelLanding() }

    /// Экран сдвинулся не от нас: на следующем витке — на месте ли переход.
    private func landingMayHaveMoved() {
        guard landing != nil, !isPlacing, !landingCheckQueued else { return }
        landingCheckQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.landingCheckQueued = false
            self.checkLanding()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Вьюха получила размер (только что создана, сверху появилась полоса):
        // место перехода могло оказаться за краем.
        landingMayHaveMoved()
    }

    /// Цель видна с запасом (см. Landing.isVisible) — и по вертикали, и по
    /// горизонтали. Пустая вьюха (ещё без текста) — считаем, что видна.
    private func isOnScreen(_ range: NSRange) -> Bool {
        guard let rect = targetRect(for: range) else { return true }
        let clip = scrollView.contentView
        let bounds = clip.bounds
        let insets = clip.contentInsets
        let top = bounds.minY + insets.top
        let visible = top...max(top, bounds.maxY - insets.bottom)
        let width = bounds.width - insets.right
        return Landing.isVisible(target: rect.minY...max(rect.minY, rect.maxY), visible: visible, margin: revealMargin)
            && rect.minX >= bounds.minX && Self.shownEnd(of: rect, width: width) <= bounds.minX + width
    }

    /// Докуда цели должно быть видно по горизонтали: длинную (строка во всю
    /// ширину) целиком не показать — хватит её начала.
    private static func shownEnd(of rect: NSRect, width: CGFloat) -> CGFloat {
        min(rect.maxX, rect.minX + width / 2)
    }

    /// Куда поставить клип, чтобы цель была посередине (Landing.centeredTop);
    /// nil — она уже там. По горизонтали: строка до цели помещается от
    /// левого края — к краю; цель и так видна — где есть; нет — на трети ширины.
    private func centeredOrigin(for range: NSRange) -> NSPoint? {
        guard let rect = targetRect(for: range) else { return nil }
        let clip = scrollView.contentView
        let bounds = clip.bounds
        let insets = clip.contentInsets
        let height = max(0, bounds.height - insets.top - insets.bottom)
        let width = bounds.width - insets.right
        let top = Landing.centeredTop(target: rect.minY...max(rect.minY, rect.maxY), height: height, margin: revealMargin)
        let end = Self.shownEnd(of: rect, width: width)
        var x = bounds.minX
        if end <= width {
            x = 0
        } else if rect.minX < bounds.minX || end > bounds.minX + width {
            x = max(0, rect.minX - width / 3)
        }
        let origin = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: x, y: top - insets.top), size: bounds.size)).origin
        if abs(origin.x - bounds.minX) < 1, abs(origin.y - bounds.minY) < 1 { return nil }
        return origin
    }

    /// Цель в координатах текста; пустая (курсор) — её место в строке.
    private func targetRect(for range: NSRange) -> NSRect? {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return nil }
        // Курсор за последним символом — у пустого диапазона там нет глифа.
        let chars = range.location < storage.length ? range : NSRange(location: storage.length - 1, length: 1)
        let glyphs = layout.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
        layout.ensureLayout(forGlyphRange: glyphs)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }

    /// Цель — посередине. Раскладка ленивая, и позиция далёкой строки до
    /// раскладки — лишь оценка: прокрутишь по ней, строки выше разложатся
    /// по-настоящему, и на экране окажется другое место. Поэтому уточняем:
    /// прокрутили, разложили видимое, пересчитали — пара итераций сходится.
    private func scrollCentering(_ range: NSRange) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            textView.scrollRangeToVisible(range)
            return
        }
        let clip = scrollView.contentView
        for _ in 0..<4 {
            guard let origin = centeredOrigin(for: range) else { break }
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            layout.ensureLayout(forBoundingRect: clip.bounds, in: container)
        }
    }

    private func flash(_ range: NSRange) {
        guard range.length > 0, let layout = textView.layoutManager else { return }
        flashToken += 1
        let token = flashToken
        layout.addTemporaryAttribute(.backgroundColor,
                                     value: NSColor.findHighlightColor.withAlphaComponent(0.55),
                                     forCharacterRange: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.flashToken == token,
                  let layout = self.textView.layoutManager,
                  let length = layout.textStorage?.length else { return }
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            if clamped.length > 0 { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clamped) }
            // Вспышка могла закрыть вхождения — перекрашиваем видимое.
            self.painted = nil
            self.highlightVisible()
        }
    }

    private var flashToken = 0

    @objc private func viewportChanged() {
        // Текст поехал из-под окна — и из-под мыши.
        dismissInfo()
        highlightVisible()
        ruler?.needsDisplay = true
        if !conflicts.isEmpty { layoutConflictStrips() }
        if popup.isVisible { hideCompletion(keepSession: true) }
        landingMayHaveMoved()
    }

    @objc private func viewportResized() {
        highlightVisible()
    }

    /// Сменили цветовую схему. Обычный текст и фон перекрасятся сами —
    /// цвета у них динамические; остальное здесь запомнено заранее:
    /// курсор и выделение у самого NSTextView, токены — временными
    /// атрибутами раскладки, полосы конфликтов — готовыми цветами.
    @objc private func colorSchemeChanged() {
        textView.insertionPointColor = Theme.caret
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.typingAttributes[.foregroundColor] = Theme.color(.plain)
        if !conflicts.isEmpty { setConflicts(conflicts) }
        painted = nil
        highlightVisible()
        textView.needsDisplay = true
        ruler?.needsDisplay = true
    }

    /// Удалённые строки ревью MR: номер новой строки, над которой они, и сами строки.
    func setRemovedLines(_ removed: [RemovedLines]) {
        guard let model, let layout = textView.layoutManager, let storage = textView.textStorage else { return }
        let length = storage.length
        let lineCount = model.lineStarts.count
        // Удалённое в конце файла — над последней строкой: ниже неё места нет.
        let blocks = removed.compactMap { item -> CodeTextView.RemovedBlock? in
            guard !item.lines.isEmpty, lineCount > 0 else { return nil }
            let anchor = Int(model.lineStarts[min(max(0, item.line), lineCount - 1)])
            return anchor < length ? .init(anchor: anchor, lines: item.lines) : nil
        }
        let old = Set(textView.removedBlocks.map(\.anchor))
        guard blocks != textView.removedBlocks else { return }
        let changed = old.union(blocks.map(\.anchor))
        // Место над строками выше экрана сдвинуло бы текст — держим верхнюю строку.
        saveViewState()
        textView.removedBlocks = blocks
        for anchor in changed where anchor < length {
            layout.invalidateLayout(forCharacterRange: NSRange(location: anchor, length: 1), actualCharacterRange: nil)
        }
        if let state = buffer?.viewState {
            scroll(toLine: state.topLine, offset: state.topOffset, x: state.scrollX)
        }
        textView.needsDisplay = true
        ruler?.needsDisplay = true
    }

    /// Отличия от HEAD — полосками в колонке номеров.
    func setLineChanges(_ changes: [LineDiff.Change]) {
        ruler?.setChanges(changes)
    }

    /// Вхождения красим не все сразу, а вместе с остальной подсветкой —
    /// то есть только в видимой области. Иначе на файле с тысячами
    /// совпадений каждый скролл упирался бы в применение атрибутов.
    /// Здесь — только в уже покрашенном, остальное докрасит `highlightVisible`.
    /// Снимаем и ставим фон точечно, на самих словах: слово под курсором
    /// меняется на каждой букве, и перерисовывать ради него весь экран незачем.
    func setOccurrences(_ ranges: [NSRange]) {
        let old = occurrences
        occurrences = ranges
        guard !(old.isEmpty && ranges.isEmpty), let painted, let layout = textView.layoutManager,
              let length = layout.textStorage?.length else { return }
        let area = NSIntersectionRange(painted, NSRange(location: 0, length: length))
        guard area.length > 0 else { return }
        textView.batchingDisplay {
            for occurrence in old {
                let r = NSIntersectionRange(occurrence, area)
                if r.length > 0 { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
            }
            for occurrence in ranges where NSIntersectionRange(occurrence, area).length > 0
                && NSMaxRange(occurrence) <= length {
                layout.addTemporaryAttribute(.backgroundColor, value: Theme.occurrenceHighlight,
                                             forCharacterRange: occurrence)
            }
        }
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = max(8, min(32, size))
        let font = Theme.editorFont(size: fontSize)
        textView.typingAttributes[.font] = font
        // Номера строк — и у редактора, которому ещё нечего показать: размер
        // ему ставят до первого файла (см. CodeView.updateNSViewController).
        ruler?.font = font
        ruler?.invalidateWidth()
        guard let buffer, buffer.storage.length > 0 else { return }
        isApplying = true
        buffer.storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: buffer.storage.length))
        isApplying = false
        buffer.fontSize = fontSize
        buffer.fixAttributesAhead()
        painted = nil
        applyInsights()
        highlightVisible()
        textView.updateCurrentLineHighlight()
        if !conflicts.isEmpty { layoutConflictStrips() }
    }

    /// Красит только те строки, что попали в видимую область (+ запас).
    ///
    /// Цвета, подчёркивания и фон — временными атрибутами раскладки, а не
    /// атрибутами текста. На раскладку они не влияют, и TextKit только
    /// перерисовывает строки. Атрибут текста — это правка: TextKit заново
    /// «чинит» шрифты, строит глифы и раскладку всех перекрашенных строк
    /// и пересчитывает размер вью, и на файле в 10 000 строк каждая буква
    /// стоила десятки миллисекунд.
    ///
    /// `toolTips: false` — после правки текста: подсказки (единственное,
    /// что остаётся в тексте) сдвинулись вместе с ним, а разбор, по которому
    /// их ставить, ещё не догнал правку — обновятся с ним.
    ///
    /// Какие строки на экране, спрашиваем по разложенному тексту (см.
    /// `charactersOnScreen`): по оценке после прыжка бегунком красились не те
    /// строки, и экран оставался без подсветки до следующей прокрутки.
    private func highlightVisible(toolTips: Bool = true) {
        // Раскладка видимого ниже уточняет высоту текста, клип от этого
        // сдвигается и зовёт сюда снова — изнутри раскладки. Вложенный вызов
        // пропускаем: этот и так спросит видимое заново, когда она закончится.
        guard !isApplying, !isHighlighting, !isReplacingStorage,
              let model, model.spec != nil,
              let storage = textView.textStorage,
              storage.length > 0 else { return }
        isHighlighting = true
        defer { isHighlighting = false }

        guard let charRange = textView.charactersOnScreen() else { return }

        let pad = 40   // запас строк сверху и снизу, чтобы скролл был плавным
        let firstLine = max(0, model.line(containing: charRange.location) - pad)
        let lastLine = min(model.lineCount - 1,
                           model.line(containing: min(NSMaxRange(charRange), max(0, model.units.count - 1))) + pad)
        guard firstLine <= lastLine else { return }

        // Уже покрашено — второй раз не тратимся.
        if let painted, let wanted = textRange(lines: firstLine...lastLine),
           NSIntersectionRange(painted, wanted) == wanted { return }

        if let range = paint(lines: firstLine...lastLine, afterEdit: !toolTips) { painted = range }
    }

    /// Правка текста — ещё посреди её обработки, так что только считаем:
    /// сдвигаем покрашенное и запоминаем, что перекрасить.
    private func textEdited(_ range: NSRange, delta: Int, settled: Int) {
        // Текст правят (набор, ⌘Z, перечитан с диска) — место перехода могло
        // сдвинуться, и держать его по старым позициям нельзя.
        cancelLanding()
        let oldLength = range.length - delta
        painted = painted.map { Self.shift($0, byEditAt: range.location, from: oldLength, to: range.length) }
        // Фон вхождений уехал вместе с текстом — пусть и они: снимать его
        // будут по этим позициям.
        if !occurrences.isEmpty {
            occurrences = occurrences.map { Self.shift($0, byEditAt: range.location, from: oldLength, to: range.length) }
        }
        shiftHelpers(byEditAt: range.location, from: oldLength, to: range.length)
        let from = model.map { $0.lineRange($0.line(containing: range.location)).lowerBound } ?? range.location
        let fresh = NSRange(location: from, length: max(settled, NSMaxRange(range)) - from)
        unpainted = unpainted.map {
            NSUnionRange(Self.shift($0, byEditAt: range.location, from: oldLength, to: range.length), fresh)
        } ?? fresh
        scheduleRepaintAfterEdit()
    }

    /// Набор перекрашивает `textDidChange`. Правки мимо поля ввода — файл
    /// перечитан с диска, форматирование, переименование, их отмена — туда не
    /// приходят: новый текст стоял без цвета, пока разбор не догонит правку,
    /// а на большом файле это заметная пауза. Поэтому на следующем витке
    /// перекрашиваем то, что осталось неперекрашенным, — видимое заново:
    /// правка могла быть любого размера и сдвинуть экран на другие строки.
    /// После набора `textDidChange` успевает раньше, и здесь нечего делать.
    private func scheduleRepaintAfterEdit() {
        guard !repaintScheduled else { return }
        repaintScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.repaintScheduled = false
            guard self.unpainted != nil else { return }
            self.unpainted = nil
            self.painted = nil
            self.highlightVisible(toolTips: false)
        }
    }

    /// Куда уедет участок текста, когда `length` символов с `location`
    /// заменят на `newLength`. Задетый правкой — растягивается на весь новый текст.
    static func shift(_ r: NSRange, byEditAt location: Int, from length: Int, to newLength: Int) -> NSRange {
        if NSMaxRange(r) <= location { return r }
        if r.location >= location + length {
            return NSRange(location: r.location + newLength - length, length: r.length)
        }
        let start = min(r.location, location)
        let end = max(NSMaxRange(r) + newLength - length, location + newLength)
        return NSRange(location: start, length: end - start)
    }

    /// После правки перекрашиваем только задетые строки, и только если они
    /// были покрашены: иначе их докрасит `highlightVisible`, когда покажутся.
    /// Набор буквы — одна строка вместо всего экрана: меньше и красить,
    /// и перерисовывать.
    private func repaintEdited() {
        guard let edited = unpainted else { return }
        unpainted = nil
        guard !isApplying, let painted, let model, model.spec != nil else { return }
        let range = NSIntersectionRange(edited, painted)
        guard range.length > 0 else { return }
        let first = model.line(containing: range.location)
        let last = model.line(containing: NSMaxRange(range) - 1)
        paint(lines: first...last, afterEdit: true)
    }

    private func textRange(lines: ClosedRange<Int>) -> NSRange? {
        guard let model, let storage = textView.textStorage else { return nil }
        let start = Int(model.lineStarts[lines.lowerBound])
        let end = lines.upperBound + 1 < model.lineCount ? Int(model.lineStarts[lines.upperBound + 1]) : storage.length
        let range = NSRange(location: start, length: max(0, min(end, storage.length) - start))
        return range.length > 0 ? range : nil
    }

    /// Красит строки целиком: лексер начинает с состояния на входе в строку.
    /// `afterEdit` — разбор отстаёт от текста: вхождения и подсказки по нему
    /// врут, их не трогаем (вхождения после правки и так сбрасываются).
    ///
    /// Токены — `colorTokens`: у C# это раскраска Rustlyn, перенесённая через
    /// правки, поэтому перекраска после правки (строки или всего экрана, когда
    /// догонит разбор) кладёт на нетронутый текст ровно те же цвета.
    @discardableResult
    private func paint(lines: ClosedRange<Int>, afterEdit: Bool) -> NSRange? {
        guard let model, let storage = textView.textStorage, let layout = textView.layoutManager,
              let range = textRange(lines: lines) else { return nil }
        let tokens = model.colorTokens(fromLine: lines.lowerBound, toLine: lines.upperBound)

        var tips: [(range: NSRange, text: String)] = []
        textView.batchingDisplay {
            // Прежние цвета, подчёркивания и фон — одним вызовом; обычный текст
            // берёт цвет из самого текста, так что красим только остальное.
            layout.setTemporaryAttributes([:], forCharacterRange: range)
            for t in tokens where t.kind != .plain {
                let r = NSRange(location: Int(t.start), length: Int(t.length))
                guard r.location >= 0, NSMaxRange(r) <= storage.length, r.length > 0 else { continue }
                layout.addTemporaryAttribute(.foregroundColor, value: Theme.color(t.kind), forCharacterRange: r)
            }
            if let decorator, let document = buffer?.document {
                for d in decorator(document, range) {
                    guard d.range.length > 0, NSMaxRange(d.range) <= storage.length else { continue }
                    if let color = d.color {
                        layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: d.range)
                    }
                    if d.underline {
                        layout.addTemporaryAttribute(.underlineStyle,
                                                     value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                                     forCharacterRange: d.range)
                    }
                    if let tip = d.toolTip { tips.append((d.range, tip)) }
                }
            }
            guard !afterEdit else { return }
            for occurrence in occurrences {
                guard NSIntersectionRange(occurrence, range).length > 0,
                      NSMaxRange(occurrence) <= storage.length else { continue }
                layout.addTemporaryAttribute(.backgroundColor, value: Theme.occurrenceHighlight,
                                             forCharacterRange: occurrence)
            }
        }
        if !afterEdit { applyToolTips(tips, in: range, storage: storage) }
        return range
    }

    /// Подсказки временными атрибутами не сделать — они остаются в тексте.
    /// Правка текста дорогая (см. `highlightVisible`), поэтому трогаем его,
    /// только если подсказки на этом участке и правда другие.
    private func applyToolTips(_ tips: [(range: NSRange, text: String)], in range: NSRange,
                               storage: NSTextStorage) {
        let wanted = tips
            .map { (range: NSIntersectionRange($0.range, range), text: $0.text) }
            .filter { $0.range.length > 0 }
            .sorted { $0.range.location < $1.range.location }
        var existing: [(range: NSRange, text: String)] = []
        storage.enumerateAttribute(.toolTip, in: range) { value, r, _ in
            if let text = value as? String { existing.append((r, text)) }
        }
        guard !wanted.elementsEqual(existing, by: { $0.range == $1.range && $0.text == $1.text }) else { return }
        isApplying = true
        storage.beginEditing()
        storage.removeAttribute(.toolTip, range: range)
        for tip in wanted { storage.addAttribute(.toolTip, value: tip.text, range: tip.range) }
        storage.endEditing()
        isApplying = false
    }
}

// MARK: - Ошибки, подсказки, сворачивание

/// Часть окна подсказки, пришедшая из фона после того, как окно показано.
private enum InfoPart: Sendable {
    case documentation(RustlynDocumentation?)
    /// Первое исправление, которое предложит ⌘.; `nil` — исправлять нечем.
    case fix(String?)
}

// MARK: - Кадр для замера стабильности (EditorStability)

extension CodeViewController {
    /// Что сейчас на экране — для `EditorStability`: где стоит каждая видимая
    /// строка (в координатах прокрутки, как её видит глаз), где кончается,
    /// какого цвета её символы и какой над ней счётчик. Видимое
    /// раскладывается, как его разложит отрисовка.
    func stabilityFrame(colors palette: inout [NSColor]) -> EditorFrame? {
        guard let buffer, let model = self.model, let layout = textView.layoutManager,
              let storage = textView.textStorage, storage.length > 0,
              let visible = textView.charactersOnScreen() else { return nil }
        let clip = scrollView.contentView.bounds
        let origin = textView.textContainerOrigin
        let left = textView.convert(NSPoint(x: origin.x, y: 0), to: scrollView).x
        let units = model.units
        let length = min(storage.length, units.count)
        let lenses = Dictionary(textView.codeLenses.compactMap { lens in
            textView.lensRect(for: lens) == nil ? nil : (lens.anchor, lens.title)
        }, uniquingKeysWith: { a, _ in a })

        func colorIndex(_ color: NSColor?) -> UInt8 {
            guard let color else { return 0 }
            if let i = palette.firstIndex(where: { $0 == color }) { return UInt8(min(i + 1, 254)) }
            palette.append(color)
            return UInt8(min(palette.count, 254))
        }

        var frame = EditorFrame(buffer: ObjectIdentifier(buffer), height: clip.height, width: clip.width)
        let firstLine = model.line(containing: visible.location)
        let lastLine = model.line(containing: min(max(visible.location, NSMaxRange(visible) - 1), max(0, units.count - 1)))
        guard firstLine <= lastLine else { return frame }
        for line in firstLine...lastLine {
            let range = model.lineRange(line)
            let start = range.lowerBound
            guard start < length, textView.foldedRanges.allSatisfy({ !NSLocationInRange(start, $0) }) else { continue }
            var end = min(range.upperBound, length)
            while end > start, units[end - 1] == 0x0A || units[end - 1] == 0x0D { end -= 1 }
            let glyph = layout.glyphIndexForCharacter(at: start)
            let text = layout.textLineRect(forGlyphAt: glyph)
            let y = text.minY + origin.y - clip.minY
            guard y + text.height > 0, y < clip.height else { continue }
            var endX = left
            if end > start {
                let lastGlyph = layout.glyphIndexForCharacter(at: end - 1)
                endX = left + layout.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxX - clip.minX
            }
            var colors = [UInt8](repeating: 255, count: end - start)
            var i = start
            while i < end {
                var run = NSRange()
                let color = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: i,
                                                      longestEffectiveRange: &run,
                                                      in: NSRange(location: i, length: end - i)) as? NSColor
                let index = colorIndex(color)
                let upper = min(end, max(i + 1, NSMaxRange(run)))
                for j in i..<upper where units[j] != 0x20 && units[j] != 0x09 { colors[j - start] = index }
                i = upper
            }
            var hash = Hasher()
            hash.combine(units[start..<end].count)
            for u in units[start..<end] { hash.combine(u) }
            frame.lines[line] = .init(y: y, left: left, endX: endX, text: hash.finalize(), colors: colors,
                                      lens: lenses[start])
        }
        return frame
    }

    /// Цвета, которые `paint` положил бы на строки сейчас: токены и
    /// украшения — для проверки, что на экране именно они.
    func expectedColors(line: Int, colors palette: [NSColor]) -> [UInt8]? {
        guard let model, let storage = textView.textStorage, line < model.lineCount else { return nil }
        let range = model.lineRange(line)
        let length = min(storage.length, model.units.count)
        var end = min(range.upperBound, length)
        let start = range.lowerBound
        guard start < end else { return [] }
        while end > start, model.units[end - 1] == 0x0A || model.units[end - 1] == 0x0D { end -= 1 }
        var colors: [NSColor?] = Array(repeating: nil, count: end - start)
        func put(_ r: NSRange, _ color: NSColor) {
            let lower = max(r.location, start), upper = min(NSMaxRange(r), end)
            guard lower < upper else { return }
            for j in lower..<upper { colors[j - start] = color }
        }
        for t in model.colorTokens(fromLine: line, toLine: line) where t.kind != .plain {
            put(NSRange(location: Int(t.start), length: Int(t.length)), Theme.color(t.kind))
        }
        if let decorator, let document = buffer?.document {
            for d in decorator(document, NSRange(location: start, length: end - start)) {
                if let color = d.color { put(d.range, color) }
            }
        }
        return (start..<end).map { j in
            let unit = model.units[j]
            guard unit != 0x20, unit != 0x09 else { return 255 }
            guard let color = colors[j - start] else { return 0 }
            guard let i = palette.firstIndex(where: { $0 == color }) else { return 254 }
            return UInt8(min(i + 1, 254))
        }
    }

    /// Показанный буфер — чей кадр снимает замер.
    var shownBuffer: TextBuffer? { buffer }
}

extension CodeViewController: NSLayoutManagerDelegate {

    // MARK: Ошибки

    /// Свежие ошибки файла: волна в тексте, значок у строки.
    func setDiagnostics(_ fresh: [RustlynDiagnostic]) {
        diagnostics = fresh
        textView.diagnostics = fresh
        guard let model else {
            ruler?.setDiagnostics([])
            return
        }
        var lines: [Int: RustlynDiagnostic.Severity] = [:]
        for diagnostic in fresh where diagnostic.range.location <= model.units.count {
            let line = model.line(containing: min(diagnostic.range.location, max(0, model.units.count - 1)))
            if (lines[line]?.rawValue ?? 0) < diagnostic.severity.rawValue { lines[line] = diagnostic.severity }
        }
        ruler?.setDiagnostics(lines.map { ($0.key, $0.value) })
    }

    /// Правка сдвигает всё, что привязано к местам в тексте: ошибки до
    /// следующей проверки, свёрнутое — пока его не задели. Задетое правкой
    /// свёрнутое разворачивается: править невидимое нельзя.
    fileprivate func shiftHelpers(byEditAt location: Int, from oldLength: Int, to newLength: Int) {
        if !diagnostics.isEmpty {
            diagnostics = diagnostics.map { diagnostic in
                var moved = diagnostic
                moved.range = Self.shift(diagnostic.range, byEditAt: location, from: oldLength, to: newLength)
                return moved
            }
            textView.diagnostics = diagnostics
        }
        shiftInsights(byEditAt: location, from: oldLength, to: newLength)
        scheduleFoldRegions(delay: 0.4)
        guard let buffer, !buffer.folded.isEmpty else { return }
        var kept: [NSRange] = []
        for folded in buffer.folded {
            if NSMaxRange(folded) <= location {
                kept.append(folded)
            } else if folded.location >= location + oldLength {
                kept.append(NSRange(location: folded.location + newLength - oldLength, length: folded.length))
            }
            // Иначе правка внутри или на краю — разворачиваем.
        }
        if kept != buffer.folded {
            // Посреди обработки правки раскладку не трогаем — после неё.
            DispatchQueue.main.async { [weak self, weak buffer] in
                guard let self, let buffer, self.buffer === buffer else { return }
                self.applyFolded(kept, invalidate: true)
            }
        }
    }

    // MARK: Подсказки в строках и счётчики использований

    /// Свежие подсказки и счётчики файла.
    func setInsights(_ fresh: RustlynInsights) {
        insights = fresh
        applyInsights()
    }

    /// Подсказки — в зазоры раскладки, счётчики — над строками. Раскладку
    /// трогаем только там, где что-то появилось, пропало или стало шире.
    fileprivate func applyInsights() {
        guard let model, let layout = textView.layoutManager, let storage = textView.textStorage else { return }
        let length = min(storage.length, model.units.count)
        let units = model.units

        let hintFont = Theme.editorFont(size: (fontSize * 0.85).rounded(.down))
        let hintAttributes: [NSAttributedString.Key: Any] = [.font: hintFont]
        var hints: [CodeTextView.InlayHint] = []
        for hint in insights.hints.sorted(by: { $0.position < $1.position }) {
            // Перед переводом строки или табом зазор не вставить: у них свой
            // управляющий глиф, и раскладка их не различит.
            guard hint.position > 0, hint.position < length, !hint.label.isEmpty,
                  units[hint.position] != 0x0A, units[hint.position] != 0x0D, units[hint.position] != 0x09
            else { continue }
            let leading: CGFloat = hint.paddingLeft ? 4 : 1
            let trailing: CGFloat = hint.paddingRight ? 4 : 1
            let text = ceil((hint.label as NSString).size(withAttributes: hintAttributes).width)
            let width = text + 8 + leading + trailing
            // Две в одном месте — одной плашкой.
            if var last = hints.last, last.position == hint.position {
                last.label += " " + hint.label
                last.width += text + 4
                hints[hints.count - 1] = last
                continue
            }
            hints.append(.init(position: hint.position, label: hint.label, width: width,
                               leading: leading, trailing: trailing))
        }

        var lenses: [CodeTextView.CodeLens] = []
        for lens in insights.lenses where lens.range.location < length {
            var line = model.line(containing: lens.range.location)
            let indent = firstNonBlank(line: line)
            // Атрибуты над объявлением — счётчик над ними, как в Rider.
            while line > 0 {
                let first = firstNonBlank(line: line - 1)
                guard first < length, units[first] == 0x5B /* [ */ else { break }
                line -= 1
            }
            let anchor = Int(model.lineStarts[line])
            // Два объявления в строке — один счётчик, первого.
            guard lenses.last?.anchor != anchor, anchor < length else { continue }
            lenses.append(.init(anchor: anchor, indent: indent, target: lens.range.location,
                                title: Self.usagesTitle(lens.count)))
        }
        lenses.sort { $0.anchor < $1.anchor }

        let lensFont = NSFont.systemFont(ofSize: max(8, (fontSize * 0.82).rounded(.down)))
        let lensSpace = ceil(layout.defaultLineHeight(for: lensFont)) + 2

        // Что изменилось для раскладки: зазоры — по позиции и ширине,
        // места над строками — по началу строки.
        let oldWidths = Dictionary(textView.inlayHints.map { ($0.position, $0.width) }, uniquingKeysWith: { a, _ in a })
        let newWidths = Dictionary(hints.map { ($0.position, $0.width) }, uniquingKeysWith: { a, _ in a })
        let changedHints = Set(oldWidths.keys).union(newWidths.keys).filter { oldWidths[$0] != newWidths[$0] }
        let oldAnchors = textView.lensAnchors
        let newAnchors = Set(lenses.map(\.anchor))
        let changedAnchors = lensSpace != textView.lensSpace ? oldAnchors.union(newAnchors)
            : oldAnchors.symmetricDifference(newAnchors)

        // Места над строками выше экрана сдвинут текст — держим на месте
        // строку, что сверху. А пока встаёт переход — строку перехода: места
        // над строками между верхом экрана и ею увели бы её вниз, за край, и
        // проверка перехода догоняла бы её прокруткой уже на глазах.
        let keepTop = !changedAnchors.isEmpty
        let held = keepTop ? landing.flatMap { landing in
            lineTop(landing.range.location).map { (landing.range.location, $0 - scrollView.contentView.bounds.minY) }
        } : nil
        if keepTop, held == nil { saveViewState() }

        textView.hintFont = hintFont
        textView.lensFont = lensFont
        textView.lensSpace = lensSpace
        textView.inlayHints = hints
        textView.codeLenses = lenses

        let total = storage.length
        func invalidate(_ positions: [Int], glyphs: Bool) {
            guard !positions.isEmpty, total > 0 else { return }
            // Много мест разом — одним диапазоном: раскладка всё равно ленивая.
            let ranges: [NSRange] = positions.count > 64
                ? [NSRange(location: positions.min()!, length: positions.max()! - positions.min()! + 1)]
                : positions.map { NSRange(location: $0, length: 1) }
            for range in ranges {
                let clipped = NSIntersectionRange(range, NSRange(location: 0, length: total))
                guard clipped.length > 0 else { continue }
                if glyphs {
                    layout.invalidateGlyphs(forCharacterRange: clipped, changeInLength: 0, actualCharacterRange: nil)
                }
                layout.invalidateLayout(forCharacterRange: clipped, actualCharacterRange: nil)
            }
        }
        invalidate(Array(changedHints), glyphs: true)
        invalidate(Array(changedAnchors), glyphs: false)
        guard !changedHints.isEmpty || !changedAnchors.isEmpty else { return }
        if let (location, offset) = held, let top = lineTop(location) {
            let clip = scrollView.contentView
            let target = NSPoint(x: clip.bounds.minX, y: max(0, top - offset))
            if abs(clip.bounds.minY - target.y) >= 1 {
                clip.scroll(to: target)
                scrollView.reflectScrolledClipView(clip)
            }
            highlightVisible()
        } else if keepTop, let state = buffer?.viewState {
            scroll(toLine: state.topLine, offset: state.topOffset, x: state.scrollX)
        }
        textView.needsDisplay = true
        ruler?.needsDisplay = true
    }

    /// Верх текста строки с символом `location` в координатах текст-вида —
    /// после раскладки этой строки.
    private func lineTop(_ location: Int) -> CGFloat? {
        guard let layout = textView.layoutManager, let storage = textView.textStorage,
              storage.length > 0 else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: min(location, storage.length - 1))
        layout.ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
        return layout.textLineRect(forGlyphAt: glyph).minY + textView.textContainerOrigin.y
    }

    /// Первый символ строки — не пробел и не таб; пустая — её конец.
    private func firstNonBlank(line: Int) -> Int {
        guard let model else { return 0 }
        let range = model.lineRange(line)
        var i = range.lowerBound
        while i < range.upperBound, i < model.units.count, model.units[i] == 0x20 || model.units[i] == 0x09 { i += 1 }
        return i
    }

    /// «3 использования», «нет использований»; не сосчитано — «… использований»:
    /// место под счётчик уже отведено, число придёт после поиска по проекту.
    static func usagesTitle(_ count: Int?) -> String {
        guard let count else {
            return "… " + Localization.word(for: 5, "использование", "использования", "использований")
        }
        guard count > 0 else { return L("нет использований") }
        return Localization.count(count, "использование", "использования", "использований", grouped: false)
    }

    /// Правка сдвигает подсказки и счётчики до следующей проверки; задетые
    /// ею — пропадают. Раскладку задетого TextKit и так построит заново.
    fileprivate func shiftInsights(byEditAt location: Int, from oldLength: Int, to newLength: Int) {
        let delta = newLength - oldLength
        func moved(_ position: Int) -> Int? {
            if position < location { return position }
            if position >= location + oldLength { return position + delta }
            return nil
        }
        if !textView.inlayHints.isEmpty {
            textView.inlayHints = textView.inlayHints.compactMap { hint in
                var hint = hint
                guard let position = moved(hint.position) else { return nil }
                hint.position = position
                return hint
            }
        }
        guard !textView.codeLenses.isEmpty else { return }
        let text = textView.textStorage?.string as NSString?
        textView.codeLenses = textView.codeLenses.compactMap { lens in
            var lens = lens
            guard let target = moved(lens.target), let indent = moved(lens.indent) else { return nil }
            lens.target = target
            lens.indent = indent
            if lens.anchor == location, oldLength == 0 {
                // Вставка в начало строки: счётчик остаётся над строкой, куда
                // уехало объявление, — после последнего вставленного перевода.
                let inserted = text?.substring(with: NSRange(location: location, length: newLength)) ?? ""
                if let newline = inserted.utf16.lastIndex(of: 0x0A) {
                    lens.anchor = location + inserted.utf16.distance(from: inserted.utf16.startIndex, to: newline) + 1
                }
            } else {
                guard let anchor = moved(lens.anchor) else { return nil }
                lens.anchor = anchor
            }
            return lens
        }
    }

    // MARK: Подсказки

    /// Курсор сдвинулся: подсказку параметров переспрашиваем (курсор мог
    /// выйти из скобок), документацию — прячем. Курсор в свёрнутом —
    /// разворачиваем.
    fileprivate func caretMovedForHelpers() {
        let selection = textView.selectedRange()
        if let buffer, let hidden = buffer.folded.first(where: {
            NSIntersectionRange($0, selection).length > 0
                || (selection.location > $0.location && selection.location < NSMaxRange($0))
        }) {
            unfold(hidden)
        }
        if info.isVisible && info.isSignatureHelp {
            requestSignatureHelp(manual: false, delay: 80_000_000)
        } else if !hoverShown {
            // Окно с клавиатуры (⌃J, ⌘F1) — о месте, где курсор был: и
            // показанное, и ещё не дождавшееся ответа.
            dismissInfo()
        }
    }

    fileprivate func requestSignatureHelp(manual: Bool, delay: UInt64 = 0) {
        signatureTask?.cancel()
        guard let request = requestSignatures else { return }
        signatureTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled else { return }
            let offset = self.textView.selectedRange().location
            let found = await request(offset)
            guard !Task.isCancelled, self.textView.selectedRange().location == offset else { return }
            guard let found, let window = self.view.window else {
                if self.info.isSignatureHelp || manual { self.info.hide() }
                if manual { NSSound.beep() }
                return
            }
            // Окно одно: ошибки и документация, что ещё дорисовывались, ему не нужны.
            self.dismissInfo()
            self.info.show(.signatures(found), anchor: self.lineRect(at: offset), parent: window)
        }
    }

    /// ⌃J: документация имени у курсора, а над ней — почему это место
    /// подчёркнуто, если оно подчёркнуто.
    fileprivate func showDocumentation() {
        cancelInfoWork()
        let selection = textView.selectedRange()
        let problems = RustlynDiagnostic.at(caret: selection.location, in: diagnostics, textLength: textLength)
        documentationTask = presentInfo(problems: problems, documentationAt: selection.location, fixesAt: selection,
                                        anchor: selection.location, hover: nil, beepIfEmpty: true)
    }

    /// ⌘F1, «Описание ошибки» (ShowErrorDescription в Rider): почему
    /// подчёркнуто там, где курсор, — то же окно, что под мышью.
    fileprivate func showProblemDescription() {
        let selection = textView.selectedRange()
        let problems = RustlynDiagnostic.at(caret: selection.location, in: diagnostics, textLength: textLength)
        guard !problems.isEmpty else { NSSound.beep(); return }
        cancelInfoWork()
        // Курсор мог уехать за край экрана — окно у невидимой строки ни к чему.
        textView.scrollRangeToVisible(NSRange(location: selection.location, length: 0))
        documentationTask = presentInfo(problems: problems, documentationAt: nil, fixesAt: selection,
                                        anchor: selection.location, hover: nil)
    }

    /// Мышь над символом `index` (`nil` — ушла с текста или нажата кнопка).
    /// Остановилась над подчёркнутым или над именем — через полсекунды, как
    /// в Rider, окно: почему подчёркнуто и что это за имя. Пока мышь
    /// движется, окна нет; ушла с того, о чём окно, — окно прячется.
    fileprivate func hovered(_ index: Int?) {
        if let index, hoverShown, info.isVisible, !info.isSignatureHelp,
           let range = hoverRange, NSLocationInRange(index, range) { return }
        cancelHover()
        guard let index else { return }
        // Не над словом и не над ошибкой — показывать нечего.
        guard wordRange(at: index) != nil
                || !RustlynDiagnostic.under(index, in: diagnostics, textLength: textLength).isEmpty else { return }
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled else { return }
            self.showHover(at: index)
        }
    }

    /// Мышь остановилась над `index`: ошибки под ней — сразу, документация
    /// имени и исправление — следом.
    private func showHover(at index: Int) {
        // Кнопка нажата — выделяют, а не читают; список дополнений и
        // сигнатура вызова важнее.
        guard NSEvent.pressedMouseButtons == 0, !popup.isVisible, !info.isSignatureHelp,
              view.window?.isKeyWindow == true else { return }
        let length = textLength
        let problems = RustlynDiagnostic.under(index, in: diagnostics, textLength: length)
        let word = wordRange(at: index)
        guard word != nil || !problems.isEmpty else { return }
        // Окно стоит, пока мышь над этим словом или над волной любой из ошибок.
        var area = word ?? problems[0].underline(textLength: length)
        for problem in problems { area = NSUnionRange(area, problem.underline(textLength: length)) }
        // Окно с клавиатуры уступает место — и его дорисовка тоже.
        cancelInfoWork()
        hoverTask = presentInfo(problems: problems, documentationAt: word == nil ? nil : index,
                                fixesAt: problems.first.map { NSRange(location: $0.range.location, length: 0) },
                                anchor: index, hover: area)
    }

    /// Окно об ошибках и имени: ошибки — сразу, документация и исправление —
    /// как ответят; окно при этом дорастает вниз, строка над ним открыта.
    /// `fixesAt` — где ⌘. будет искать исправления; `hover` — о каком куске
    /// текста окно, открытое мышью (`nil` — открыто с клавиатуры). Отдаёт
    /// задачу дорисовки: её отмена — и отмена того, что ещё не показано.
    private func presentInfo(problems: [RustlynDiagnostic], documentationAt offset: Int?, fixesAt fixRange: NSRange?,
                             anchor: Int, hover: NSRange?, beepIfEmpty: Bool = false) -> Task<Void, Never> {
        if !problems.isEmpty {
            showInfo(documentation: nil, problems: problems, fix: nil, anchor: anchor, hover: hover)
        }
        // Исправления бывают только у компилятора, не у сверки с парой.
        let fixRange = problems.contains { !$0.isPairCheck } ? fixRange : nil
        return Task { @MainActor [weak self] in
            guard let self else { return }
            var documentation: RustlynDocumentation?
            var fix: String?
            var shown = !problems.isEmpty
            await withTaskGroup(of: InfoPart.self) { group in
                if let offset {
                    group.addTask { .documentation(await self.fetchDocumentation(at: offset)) }
                }
                if let fixRange {
                    group.addTask { .fix(await self.firstFix(at: fixRange)) }
                }
                for await part in group {
                    switch part {
                    case .documentation(let found):
                        documentation = found
                        guard found != nil else { continue }
                    case .fix(let title):
                        fix = title.map(Self.fixHint)
                        guard fix != nil, shown else { continue }
                    }
                    // Окно успели спрятать или занять сигнатурой — не воскрешаем.
                    guard !Task.isCancelled, !shown || (self.info.isVisible && !self.info.isSignatureHelp)
                    else { continue }
                    self.showInfo(documentation: documentation, problems: problems, fix: fix,
                                  anchor: anchor, hover: hover)
                    shown = true
                }
            }
            if beepIfEmpty, !shown, !Task.isCancelled { NSSound.beep() }
        }
    }

    private func showInfo(documentation: RustlynDocumentation?, problems: [RustlynDiagnostic], fix: String?,
                          anchor: Int, hover: NSRange?) {
        guard let window = view.window else { return }
        hoverShown = hover != nil
        hoverRange = hover
        hoverProblem = hover == nil ? nil : problems.first?.range
        info.show(.documentation(documentation, problems: problems, fix: fix),
                  anchor: lineRect(at: anchor), parent: window)
    }

    private func fetchDocumentation(at offset: Int) async -> RustlynDocumentation? {
        guard let requestDocumentation else { return nil }
        return await requestDocumentation(offset)
    }

    /// Первое исправление, которое предложит ⌘. в этом месте: раздел
    /// исправлений в меню — первый из ведущих (`ContextActionGroup.leading`).
    private func firstFix(at range: NSRange) async -> String? {
        guard let codeActions else { return nil }
        let groups = await codeActions(range)
        return groups.first(where: \.leading)?.actions.first?.title
    }

    /// «⌘. — исправить: Add using System.Linq».
    private static func fixHint(_ title: String) -> String {
        let keys = KeymapStore.shared.display(.contextActions)
        let how = keys.isEmpty ? EditorCommand.contextActions.title : keys
        return L("\(how) — исправить: \(title)")
    }

    /// Клавиша — человек вернулся к клавиатуре: окно, открытое мышью, прочь,
    /// и остановки мыши больше не ждём. Открытое окно Esc прячет в
    /// `doCommandBy` — там же он и не открывает после этого дополнение.
    fileprivate func keyPressed(_ event: NSEvent) {
        if hoverShown, event.charactersIgnoringModifiers == KeyShortcut.escape { return }
        cancelHover()
    }

    /// Мышь ушла или занялась другим: остановки не ждём, окно, открытое
    /// ею, прячем. Окно с клавиатуры не трогаем.
    fileprivate func cancelHover() {
        hoverTask?.cancel()
        hoverTask = nil
        guard hoverShown else { return }
        hoverShown = false
        hoverRange = nil
        hoverProblem = nil
        if info.isVisible && !info.isSignatureHelp { info.hide() }
    }

    /// Мышь с зажатым ⌘ остановилась на слове — говорим о нём после короткой
    /// паузы: проносясь над текстом, мышь задела бы десяток слов.
    fileprivate func commandHovered(_ index: Int?) {
        guard let index else {
            commandHoverTask?.cancel()
            commandHoverTask = nil
            guard commandHoverWord != nil else { return }
            commandHoverWord = nil
            onCommandHover?(nil)
            return
        }
        let word = wordRange(at: index)
        guard word != commandHoverWord else { return }
        guard let word else {
            // Над пробелом или скобкой: сказанное остаётся — мышь могла лишь
            // соскользнуть с имени, — а несказанное отменяется.
            if let pending = commandHoverTask {
                pending.cancel()
                commandHoverTask = nil
                commandHoverWord = nil
            }
            return
        }
        commandHoverWord = word
        commandHoverTask?.cancel()
        commandHoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            self.commandHoverTask = nil
            self.onCommandHover?(index)
        }
    }

    /// То, что ещё дорисовывает окно об ошибках и документации, — прочь;
    /// само окно стоит, пока его не заменит новое.
    private func cancelInfoWork() {
        documentationTask?.cancel()
        documentationTask = nil
        hoverTask?.cancel()
        hoverTask = nil
    }

    /// Окно об ошибках и документации — прочь, как бы его ни открыли, вместе
    /// с тем, что его ещё дорисовывает. Сигнатуру вызова не трогает.
    fileprivate func dismissInfo() {
        cancelInfoWork()
        cancelHover()
        if info.isVisible && !info.isSignatureHelp { info.hide() }
    }

    private var textLength: Int { textView.textStorage?.length ?? 0 }

    private func wordRange(at index: Int) -> NSRange? {
        guard let model, index < model.units.count, WordCompletion.isIdentPart(model.units[index]) else { return nil }
        var start = index, end = index
        while start > 0, WordCompletion.isIdentPart(model.units[start - 1]) { start -= 1 }
        while end < model.units.count, WordCompletion.isIdentPart(model.units[end]) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Строка текста на экране — к ней прикрепляется окно подсказки.
    private func lineRect(at offset: Int) -> NSRect {
        // firstRect отдаёт прямоугольник уже в координатах экрана.
        let length = textView.textStorage?.length ?? 0
        return textView.firstRect(forCharacterRange: NSRange(location: min(offset, length), length: 0),
                                  actualRange: nil)
    }

    // MARK: Сворачивание

    /// Что можно свернуть — считается в фоне по снимку модели, после паузы
    /// в наборе.
    fileprivate func scheduleFoldRegions(delay: Double) {
        foldWork?.cancel()
        guard let buffer, buffer.model.spec != nil else { return }
        let work = DispatchWorkItem { [weak self, weak buffer] in
            guard let self, let buffer, self.buffer === buffer else { return }
            let snapshot = buffer.model.snapshot()
            DispatchQueue.global(qos: .utility).async { [weak self, weak buffer] in
                let regions = FoldRegions.compute(snapshot)
                DispatchQueue.main.async {
                    guard let self, let buffer, self.buffer === buffer,
                          buffer.model.version == snapshot.version else { return }
                    self.foldRegions = regions
                    self.ruler?.foldRegions = Dictionary(regions.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
                }
            }
        }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Стрелка в гаттере: свернуть или развернуть кусок, что начинается на строке.
    func toggleFold(line: Int) {
        guard let region = foldRegions.first(where: { $0.line == line }), let buffer else { return }
        if buffer.folded.contains(region.hidden) {
            unfold(region.hidden)
        } else {
            foldRegion(region)
        }
    }

    fileprivate func fold(_ command: CodeTextView.FoldCommand) {
        guard let model, let buffer else { return }
        let caretLine = model.line(containing: min(textView.selectedRange().location, max(0, model.units.count - 1)))
        switch command {
        case .fold:
            // Самый внутренний кусок, в котором курсор.
            guard let region = foldRegions
                .filter({ $0.line <= caretLine && caretLine <= $0.endLine && !buffer.folded.contains($0.hidden) })
                .max(by: { $0.line < $1.line }) else { return NSSound.beep() }
            foldRegion(region)
        case .unfold:
            guard let hidden = buffer.folded.first(where: { model.line(containing: $0.location) == caretLine }) else {
                return NSSound.beep()
            }
            unfold(hidden)
        case .foldAll:
            // Второй уровень: тела методов, а не весь класс и не пространство
            // имён. В файле без вложенности — первый.
            func depth(_ region: FoldRegion) -> Int {
                foldRegions.filter { $0 != region && $0.hidden.location <= region.hidden.location
                    && NSMaxRange(region.hidden) <= NSMaxRange($0.hidden) }.count
            }
            let depths = foldRegions.map { ($0, depth($0)) }
            let deepest = depths.map(\.1).max() ?? 0
            let level = min(1, deepest)
            applyFolded(depths.filter { $0.1 == level }.map(\.0.hidden), invalidate: true)
        case .unfoldAll:
            applyFolded([], invalidate: true)
        }
    }

    private func foldRegion(_ region: FoldRegion) {
        guard let buffer else { return }
        // Свёрнутое внутри — часть свёрнутого теперь.
        var folded = buffer.folded.filter {
            !($0.location >= region.hidden.location && NSMaxRange($0) <= NSMaxRange(region.hidden))
        }
        folded.append(region.hidden)
        // Курсор внутри — на строку свёрнутого, иначе он тут же развернёт.
        let selection = textView.selectedRange()
        if NSIntersectionRange(selection, region.hidden).length > 0
            || (selection.location > region.hidden.location && selection.location < NSMaxRange(region.hidden)) {
            textView.setSelectedRange(NSRange(location: region.hidden.location, length: 0))
        }
        applyFolded(folded, invalidate: true)
    }

    fileprivate func unfold(_ range: NSRange) {
        guard let buffer else { return }
        applyFolded(buffer.folded.filter { $0 != range }, invalidate: true, touched: [range])
    }

    /// Новое свёрнутое — буферу, тексту, гаттеру; раскладку заданных мест —
    /// заново.
    fileprivate func applyFolded(_ folded: [NSRange], invalidate: Bool, touched: [NSRange] = []) {
        guard let buffer, let layout = textView.layoutManager else { return }
        let length = buffer.storage.length
        let valid = folded.filter { NSMaxRange($0) <= length && $0.length > 0 }.sorted { $0.location < $1.location }
        let changed = Set(valid.map { [$0.location, $0.length] })
            .symmetricDifference(buffer.folded.map { [$0.location, $0.length] })
            .map { NSRange(location: $0[0], length: $0[1]) } + touched
        buffer.folded = valid
        textView.foldedRanges = valid
        ruler?.hiddenRanges = valid
        guard invalidate, length > 0 else { return }
        for range in changed {
            let start = max(0, range.location - 1)
            let widened = NSRange(location: start, length: min(length, NSMaxRange(range) + 1) - start)
            layout.invalidateGlyphs(forCharacterRange: widened, changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: widened, actualCharacterRange: nil)
        }
        textView.needsDisplay = true
        ruler?.needsDisplay = true
        highlightVisible()
    }

    /// Свёрнутое, в котором символ `index`.
    fileprivate func foldedRange(containing index: Int) -> NSRange? {
        let folded = textView.foldedRanges
        var lo = 0, hi = folded.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let range = folded[mid]
            if index < range.location { hi = mid - 1 }
            else if index >= NSMaxRange(range) { lo = mid + 1 }
            else { return range }
        }
        return nil
    }

    // MARK: Делегат раскладки: как прячется свёрнутое

    /// Спрятанные символы — без глифов; первый — управляющий: ему раскладка
    /// даст ширину рамки «⋯».
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                   shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                                   properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                                   characterIndexes charIndexes: UnsafePointer<Int>,
                                   font aFont: NSFont,
                                   forGlyphRange glyphRange: NSRange) -> Int {
        MainActor.assumeIsolated {
            let hasFolds = !textView.foldedRanges.isEmpty
            var hints = textView.inlayHints
            // Зазор под серый текст Copilot — такой же лишний глиф, что у
            // подсказки в строке.
            if let ghost = textView.ghost, ghost.gap > 0, textView.inlayHint(at: ghost.position) == nil {
                let gap = CodeTextView.InlayHint(position: ghost.position, label: "", width: ghost.gap,
                                                 leading: 0, trailing: 0)
                hints.insert(gap, at: textView.firstInlayHint(atOrAfter: ghost.position))
            }
            guard hasFolds || !hints.isEmpty, glyphRange.length > 0 else { return 0 }
            var nextHint: Int = {
                var lo = 0, hi = hints.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if hints[mid].position < charIndexes[0] { lo = mid + 1 } else { hi = mid }
                }
                return lo
            }()
            var outGlyphs: [CGGlyph] = []
            var properties: [NSLayoutManager.GlyphProperty] = []
            var characters: [Int] = []
            outGlyphs.reserveCapacity(glyphRange.length)
            properties.reserveCapacity(glyphRange.length)
            characters.reserveCapacity(glyphRange.length)
            var changed = false
            for i in 0..<glyphRange.length {
                let character = charIndexes[i]
                var property = props[i]
                let hidden = hasFolds ? foldedRange(containing: character) : nil
                if let hidden {
                    property = character == hidden.location ? .controlCharacter : .null
                    changed = true
                }
                // Подсказка — лишним управляющим глифом перед первым глифом
                // символа: ему раскладка даст ширину плашки.
                while nextHint < hints.count, hints[nextHint].position < character { nextHint += 1 }
                if hidden == nil, nextHint < hints.count, hints[nextHint].position == character,
                   i == 0 || charIndexes[i - 1] != character,
                   !props[i].contains(.controlCharacter) {
                    outGlyphs.append(0)
                    properties.append(.controlCharacter)
                    characters.append(character)
                    changed = true
                }
                outGlyphs.append(glyphs[i])
                properties.append(property)
                characters.append(character)
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(outGlyphs, properties: properties, characterIndexes: characters,
                                    font: aFont, forGlyphRange: NSRange(location: glyphRange.location,
                                                                        length: outGlyphs.count))
            return glyphRange.length
        }
    }

    /// Переводы строк внутри свёрнутого строк не ломают; первый символ —
    /// пробел шириной с рамку.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                   shouldUse action: NSLayoutManager.ControlCharacterAction,
                                   forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        MainActor.assumeIsolated {
            guard let hidden = foldedRange(containing: charIndex) else {
                return textView.inlayHint(at: charIndex) != nil || ghostGap(at: charIndex) != nil ? .whitespace : action
            }
            return charIndex == hidden.location ? .whitespace : .zeroAdvancement
        }
    }

    nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                   boundingBoxForControlGlyphAt glyphIndex: Int,
                                   for textContainer: NSTextContainer,
                                   proposedLineFragment proposedRect: NSRect,
                                   glyphPosition: NSPoint,
                                   characterIndex charIndex: Int) -> NSRect {
        MainActor.assumeIsolated {
            if foldedRange(containing: charIndex) == nil, let hint = textView.inlayHint(at: charIndex) {
                return NSRect(x: glyphPosition.x, y: 0, width: hint.width, height: proposedRect.height)
            }
            if foldedRange(containing: charIndex) == nil, let gap = ghostGap(at: charIndex) {
                return NSRect(x: glyphPosition.x, y: 0, width: gap, height: proposedRect.height)
            }
            let font = textView.font ?? Theme.editorFont(size: 12)
            let width = (" ⋯ " as NSString).size(withAttributes: [.font: font]).width + 6
            return NSRect(x: glyphPosition.x, y: 0, width: width, height: proposedRect.height)
        }
    }

    /// Место над строкой под счётчик использований.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                   paragraphSpacingBeforeGlyphAt glyphIndex: Int,
                                   withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        MainActor.assumeIsolated {
            let ghost = textView.ghost
            let removed = textView.removedLineCounts
            guard !textView.lensAnchors.isEmpty || ghost?.anchor != nil || !removed.isEmpty else { return 0 }
            let character = layoutManager.characterIndexForGlyph(at: glyphIndex)
            var space: CGFloat = textView.lensAnchors.contains(character) ? textView.lensSpace : 0
            // Удалённые строки ревью — над счётчиком, в верху отведённого места.
            if let count = removed[character], let font = textView.font {
                space += CGFloat(count) * layoutManager.defaultLineHeight(for: font)
            }
            // Строки подсказки Copilot — между строкой курсора и следующей.
            if let ghost, ghost.anchor == character { space += ghost.space }
            return space
        }
    }

    /// Ширина зазора под серый текст перед символом `index`, если он там.
    private func ghostGap(at index: Int) -> CGFloat? {
        guard let ghost = textView.ghost, ghost.gap > 0, ghost.position == index,
              textView.inlayHint(at: index) == nil else { return nil }
        return ghost.gap
    }
}

// MARK: - Колонка с номерами строк

final class LineNumberRuler: NSRulerView, NSViewToolTipOwner {
    weak var textView: NSTextView?
    var model: SyntaxModel?
    var font: NSFont = Theme.editorFont(size: 11)
    /// Строки со значком слева от номера — методы-сообщения Unity.
    var eventLines: Set<Int> = [] {
        didSet { if eventLines != oldValue { needsDisplay = true } }
    }
    /// Цвет значка — из схемы, поэтому картинку помним вместе с ней:
    /// сменили схему — строим заново.
    private var marker: (scheme: String, image: NSImage?)?
    private var markerImage: NSImage? {
        if let marker, marker.scheme == Theme.current.id { return marker.image }
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(.init(paletteColors: [Theme.unityEvent]))
        let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: L("Сообщение Unity"))?
            .withSymbolConfiguration(config)
        marker = (Theme.current.id, image)
        return image
    }
    /// Строка с курсором: её номер ярче, а полоса продолжается в гаттер.
    var currentLine = 0 {
        didSet { if currentLine != oldValue { needsDisplay = true } }
    }
    /// Точки останова — ярлык под номером строки, как в Xcode.
    var breakpoints: [Int: BreakpointMark] = [:] {
        didSet { if breakpoints != oldValue { needsDisplay = true; updateBreakpointTips() } }
    }
    /// Где стоит программа — зелёная стрелка поверх номера.
    var executionLine: Int? {
        didSet { if executionLine != oldValue { needsDisplay = true } }
    }
    var onBreakpointClick: ((Int) -> Void)?
    /// Правый клик (или ⌃-клик) по номеру — условие точки.
    var onBreakpointContext: ((Int) -> Void)?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) { fatalError() }

    /// Сколько цифр в номере последней строки — при каком числе
    /// ширина колонки считалась в последний раз.
    private(set) var digits = 0

    func invalidateWidth() {
        digits = String(model?.lineCount ?? 0).count
        ruleThickness = CGFloat(max(3, digits)) * 8.0 + 20 + Self.foldColumn
            + (hasCommentColumn ? Self.commentColumn : 0) + blameWidth
        needsDisplay = true
    }

    // MARK: Сворачивание и ошибки

    /// Между номером и текстом — место под стрелку сворачивания.
    static let foldColumn: CGFloat = 12
    /// Что сворачивается, по строке, где у куска стрелка.
    var foldRegions: [Int: FoldRegion] = [:] {
        didSet { needsDisplay = true }
    }
    /// Спрятанное: строки внутри не рисуются.
    var hiddenRanges: [NSRange] = [] {
        didSet { if hiddenRanges != oldValue { needsDisplay = true } }
    }
    var onFoldClick: ((Int) -> Void)?
    /// Строки с ошибками — номер цветом ошибки.
    private var problemLines: [Int: RustlynDiagnostic.Severity] = [:]

    func setDiagnostics(_ lines: [(Int, RustlynDiagnostic.Severity)]) {
        let fresh = Dictionary(lines, uniquingKeysWith: { a, b in a.rawValue >= b.rawValue ? a : b })
        guard fresh != problemLines else { return }
        problemLines = fresh
        needsDisplay = true
    }

    private func drawFoldArrow(folded: Bool, top: CGFloat, height: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        guard let image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down",
                                  accessibilityDescription: folded ? L("Развернуть") : L("Свернуть"))?
            .withSymbolConfiguration(config) else { return }
        let tint = Theme.foldMarker.withAlphaComponent(folded ? 1 : 0.55)
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        let x = ruleThickness - 6 - Self.foldColumn / 2 - size.width / 2
        tinted.draw(in: NSRect(origin: NSPoint(x: x, y: top + (height - size.height) / 2), size: size))
    }

    // MARK: Треды ревью

    /// Слева от номеров — место под значок треда.
    private static let commentColumn: CGFloat = 16
    private var hasCommentColumn = false
    private var commentMarks: [Int: CommentMark] = [:]
    var onLineClick: ((Int) -> Void)?

    // MARK: Авторы строк

    /// Колонка авторов слева; nil — выключена.
    var blame: BlameColumn? {
        didSet {
            guard blame != oldValue else { return }
            if (blame == nil) != (oldValue == nil) { invalidateWidth() } else { needsDisplay = true }
        }
    }
    /// Клик по автору строки — её коммит.
    var onBlameClick: ((Int) -> Void)?
    private var blameWidth: CGFloat { blame == nil ? 0 : Self.blameColumn }
    private static let blameColumn: CGFloat = 150
    /// Всё, что левее номеров: авторы и значки тредов ревью.
    private var leftColumns: CGFloat { blameWidth + (hasCommentColumn ? Self.commentColumn : 0) }

    private func drawBlame(line: Int, top: CGFloat, height: CGFloat, showsLabel: Bool) {
        guard let blame, let commit = blame.commit(atLine: line) else { return }
        let freshness = blame.freshness[commit]
        Theme.gitModified.withAlphaComponent(0.05 + 0.20 * freshness).setFill()
        NSRect(x: 0, y: top, width: blameWidth - 4, height: height).fill()
        guard showsLabel else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(9, font.pointSize - 2)),
            .foregroundColor: Theme.gutterText,
        ]
        let label = blame.labels[commit] as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(in: NSRect(x: 4, y: top + (height - size.height) / 2, width: blameWidth - 10, height: size.height),
                   withAttributes: attributes)
    }

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
        tinted.draw(in: NSRect(origin: NSPoint(x: blameWidth + 3, y: top + (height - size.height) / 2), size: size))
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
            lineRect = layout.textLineRect(forGlyphAt: layout.glyphIndexForCharacter(at: start))
        }
        let origin = convert(NSPoint.zero, from: textView)
        let y = origin.y + textView.textContainerInset.height + lineRect.minY
        return NSRect(x: 0, y: y, width: ruleThickness, height: max(lineRect.height, 1))
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x < ruleThickness - Self.foldColumn - 8, let onBreakpointContext, let line = line(at: point) else {
            super.rightMouseDown(with: event)
            return
        }
        onBreakpointContext(line)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < blameWidth, let onBlameClick, let line = line(at: point) {
            onBlameClick(line)
            return
        }
        // Стрелка сворачивания — справа, у самого текста.
        if point.x >= ruleThickness - Self.foldColumn - 8, let onFoldClick,
           let line = line(at: point), foldRegions[line] != nil {
            onFoldClick(line)
            return
        }
        // Сам номер — точка останова; полоска изменений у текста и всё,
        // что справа, — окно строки, как было.
        if point.x < ruleThickness - Self.foldColumn - 8, let line = line(at: point) {
            if event.modifierFlags.contains(.control), let onBreakpointContext {
                onBreakpointContext(line)
                return
            }
            if let onBreakpointClick {
                onBreakpointClick(line)
                return
            }
        }
        guard let onLineClick, let line = line(at: point) else {
            super.mouseDown(with: event)
            return
        }
        onLineClick(line)
    }

    /// Почему точка не встала — подсказкой при наведении. Одна область на
    /// всю линейку, текст — по строке под курсором: строки прокручиваются,
    /// а линейка нет.
    private func updateBreakpointTips() {
        removeAllToolTips()
        if breakpoints.values.contains(where: { $0.message != nil || $0.condition != nil }) {
            addToolTip(bounds, owner: self, userData: nil)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateBreakpointTips()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let line = line(at: point), let mark = breakpoints[line] else { return "" }
        let condition = mark.condition.map { L("Условие: \($0)") }
        return [condition, mark.message].compactMap { $0 }.joined(separator: "\n")
    }

    /// Ярлык точки: прямоугольник со стрелкой вправо под номером строки.
    /// Не вставшая у отладчика — бледная, с контуром.
    private func drawBreakpoint(_ mark: BreakpointMark, top: CGFloat, height: CGFloat) {
        let left: CGFloat = leftColumns + 2
        let right = ruleThickness - Self.foldColumn - 3
        let rect = NSRect(x: left, y: top + 1, width: right - left, height: max(height - 2, 8))
        let path = Self.tabPath(rect)
        if mark.verified {
            Theme.breakpoint.setFill()
            path.fill()
        } else {
            Theme.breakpoint.withAlphaComponent(0.3).setFill()
            path.fill()
            Theme.breakpoint.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        // Условная — белая точка слева, как у Rider.
        if mark.condition != nil {
            let d = min(5, rect.height - 4)
            Theme.breakpointText.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 3, y: rect.midY - d / 2, width: d, height: d)).fill()
        }
    }

    private func drawExecutionArrow(top: CGFloat, height: CGFloat) {
        let right = ruleThickness - Self.foldColumn - 1
        let left = right - max(14, (ruleThickness - Self.foldColumn) * 0.55)
        let rect = NSRect(x: left, y: top + 1, width: right - left, height: max(height - 2, 8))
        Theme.debugExecution.setFill()
        Self.tabPath(rect).fill()
    }

    private static func tabPath(_ rect: NSRect) -> NSBezierPath {
        let tip = min(rect.height / 2, 6)
        let path = NSBezierPath()
        let radius: CGFloat = 2
        path.move(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - tip, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX - tip, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
                       startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                       startAngle: 180, endAngle: 270)
        path.close()
        return path
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

        let problemAttrs: [RustlynDiagnostic.Severity: [NSAttributedString.Key: Any]] = [
            .error: [.font: font, .foregroundColor: Theme.diagnosticError],
            .warning: [.font: font, .foregroundColor: Theme.diagnosticWarning],
        ]

        var line = firstLine
        while line < model.lineCount {
            let lineStart = Int(model.lineStarts[line])
            if lineStart > NSMaxRange(charRange) { break }
            // Строка внутри свёрнутого не видна: дальше — со строки после него.
            if let hidden = hiddenRanges.first(where: { lineStart > $0.location && lineStart <= NSMaxRange($0) }) {
                line = model.line(containing: min(NSMaxRange(hidden), max(0, model.units.count - 1))) + 1
                continue
            }

            let glyphIdx = layout.glyphIndexForCharacter(at: lineStart)
            let lineRect = layout.textLineRect(forGlyphAt: glyphIdx)

            let y = origin.y + inset + lineRect.minY
            let isCurrent = line == currentLine
            if isCurrent, highlight != nil {
                Theme.currentLine.setFill()
                NSRect(x: 0, y: y, width: ruleThickness, height: lineRect.height).fill()
            }
            if blame != nil {
                // Подпись — у первой строки куска одного коммита и у первой видимой.
                let previous = line > firstLine ? blame?.commit(atLine: line - 1) : nil
                drawBlame(line: line, top: y, height: lineRect.height,
                          showsLabel: line == firstLine || previous != blame?.commit(atLine: line))
            }
            let mark = breakpoints[line]
            if let mark { drawBreakpoint(mark, top: y, height: lineRect.height) }
            let executing = executionLine == line
            if executing { drawExecutionArrow(top: y, height: lineRect.height) }
            let label = String(line + 1) as NSString
            var labelAttrs = problemLines[line].flatMap { problemAttrs[$0] } ?? (isCurrent ? currentAttrs : attrs)
            if mark?.verified == true || executing {
                labelAttrs = [.font: font, .foregroundColor: Theme.breakpointText]
            }
            let size = label.size(withAttributes: labelAttrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8 - Self.foldColumn,
                                   y: y + (lineRect.height - size.height) / 2),
                       withAttributes: labelAttrs)
            if let region = foldRegions[line] {
                drawFoldArrow(folded: hiddenRanges.contains(region.hidden), top: y, height: lineRect.height)
            }
            if eventLines.contains(line), let image = markerImage {
                let side = image.size
                // Правее колонки комментариев ревью, если она есть.
                let x: CGFloat = leftColumns + 4
                image.draw(in: NSRect(x: x, y: y + (lineRect.height - side.height) / 2,
                                      width: side.width, height: side.height))
            }
            if hasCommentColumn, let mark = commentMarks[line] {
                drawCommentMark(mark, top: y, height: lineRect.height)
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

/// Значок треда ревью у строки: открытый ярче, решённый — приглушён.
struct CommentMark: Equatable {
    var count: Int
    var open: Bool
}

// MARK: - Мост в SwiftUI

struct CodeView: NSViewControllerRepresentable {
    let buffer: TextBuffer?
    let fontSize: CGFloat
    let reveal: Workspace.RevealRequest?
    let occurrences: [NSRange]
    let lineChanges: [LineDiff.Change]
    /// Удалённые строки ревью MR — прямо в тексте; пусто вне ревью.
    var removedLines: [RemovedLines] = []
    var commentMarks: [Int: CommentMark] = [:]
    /// Авторы строк у номеров; nil — выключено.
    var blame: BlameColumn? = nil
    var onBlameClick: ((Int) -> Void)? = nil
    /// Документ из ревью: под значки тредов в гаттере всегда есть место.
    var isReview = false
    var popover: Workspace.LinePopoverRequest? = nil
    var popoverContent: (Workspace.LinePopoverRequest) -> AnyView? = { _ in nil }
    var conflicts: [MergeConflict] = []
    var conflictAction: Workspace.ConflictActionRequest? = nil
    let focusRequest: Int
    var findRequest: Workspace.FindRequest? = nil
    /// ⌘. — номер запроса меню действий у курсора.
    var contextActionsRequest = 0
    let completionTriggers: [String]
    /// Смысловые украшения и их версия: сменилась — перекрашиваем.
    var decorator: CodeDecorator? = nil
    var decorationsVersion: Int = 0
    /// Правки инспектора Unity к применению.
    var editRequest: TextEditRequest? = nil
    let onCaretChange: (NSRange) -> Void
    let onGoToDefinition: (Int) -> Void
    /// ⌘ над символом — клик по нему, скорее всего, будет.
    var onCommandHover: ((Int?) -> Void)? = nil
    var onLineClick: ((Int) -> Void)? = nil
    var onCommentLine: ((Int) -> Void)? = nil
    /// Точки останова файла, строка выполнения и клик по номеру строки.
    var breakpoints: [Int: BreakpointMark] = [:]
    var executionLine: Int? = nil
    var onBreakpointClick: ((Int) -> Void)? = nil
    var onBreakpointCondition: ((Int, String?) -> Void)? = nil
    var contextActions: ((Int) -> [ContextActionGroup])? = nil
    var codeActions: ((NSRange) async -> [ContextActionGroup])? = nil
    /// Пункты меню правого клика для символа под мышью.
    var textMenuActions: ((Int) -> [ContextAction])? = nil
    let requestCompletions: (Int, String?, Bool) async -> CompletionList?
    /// Подсказка Copilot у курсора; nil — Copilot выключен.
    var requestSuggestion: ((Int) async -> CopilotSuggestion?)? = nil
    var onSuggestionShown: ((CopilotSuggestion) -> Void)? = nil
    var onSuggestionAccepted: ((CopilotSuggestion) -> Void)? = nil
    /// Ошибки показанного файла и их версия: сменилась — перерисовываем.
    var diagnostics: [RustlynDiagnostic] = []
    var diagnosticsVersion = 0
    /// Подсказки в строках и счётчики использований — так же, по версии.
    var insights = RustlynInsights()
    var insightsVersion = 0
    /// Клик по «N использований»: позиция имени в объявлении.
    var onLensClick: ((Int) -> Void)? = nil
    var requestDocumentation: ((Int) async -> RustlynDocumentation?)? = nil
    var requestSignatures: ((Int) async -> RustlynSignatures?)? = nil
    var selectionSteps: ((NSRange) -> [NSRange]?)? = nil

    func makeNSViewController(context: Context) -> CodeViewController {
        let controller = CodeViewController()
        controller.onCaretChange = onCaretChange
        controller.onGoToDefinition = onGoToDefinition
        controller.onCommandHover = onCommandHover
        controller.onLineClick = onLineClick
        controller.onCommentLine = onCommentLine
        controller.onBreakpointClick = onBreakpointClick
        controller.onBreakpointCondition = onBreakpointCondition
        controller.onBlameClick = onBlameClick
        return controller
    }

    func updateNSViewController(_ controller: CodeViewController, context: Context) {
        controller.onCaretChange = onCaretChange
        controller.onGoToDefinition = onGoToDefinition
        controller.onCommandHover = onCommandHover
        controller.onLineClick = onLineClick
        controller.onCommentLine = onCommentLine
        controller.onBreakpointClick = onBreakpointClick
        controller.onBreakpointCondition = onBreakpointCondition
        controller.onBlameClick = onBlameClick
        controller.contextActions = contextActions
        controller.codeActions = codeActions
        controller.textMenuActions = textMenuActions
        controller.requestCompletions = requestCompletions
        controller.requestSuggestion = requestSuggestion
        controller.onSuggestionShown = onSuggestionShown
        controller.onSuggestionAccepted = onSuggestionAccepted
        controller.requestDocumentation = requestDocumentation
        controller.requestSignatures = requestSignatures
        controller.selectionSteps = selectionSteps
        controller.onLensClick = onLensClick
        // «.» — всегда: и без сервера после точки ждёшь список членов.
        controller.completionTriggers = Set(completionTriggers).union(["."])
        controller.decorator = decorator

        // Шрифт — до показа буфера: только что созданный редактор иначе
        // набрал бы файл своим размером по умолчанию, а следом ещё раз
        // настоящим — и место перехода, поставленное между ними, уехало бы.
        if context.coordinator.fontSize != fontSize {
            context.coordinator.fontSize = fontSize
            controller.setFontSize(fontSize)
        }

        // Буфер сравниваем по идентичности: тот же файл, перечитанный
        // с диска, — уже другой буфер.
        var documentChanged = false
        // Место перехода, на котором вкладку сейчас показали.
        var landed: NSRange?
        if let buffer {
            if context.coordinator.shown !== buffer {
                context.coordinator.shown = buffer
                landed = controller.show(buffer)
                documentChanged = true
            }
        } else if context.coordinator.shown != nil {
            context.coordinator.shown = nil
            controller.showEmpty()
        }

        // Разбор обновился — ссылки и значки перекрашиваются.
        let semantics = buffer?.document.semanticsVersion ?? -1
        if !documentChanged, context.coordinator.decorationsVersion != decorationsVersion
            || context.coordinator.semanticsVersion != semantics {
            controller.invalidateDecorations()
        }
        context.coordinator.decorationsVersion = decorationsVersion
        context.coordinator.semanticsVersion = semantics

        if documentChanged || context.coordinator.diagnosticsVersion != diagnosticsVersion {
            context.coordinator.diagnosticsVersion = diagnosticsVersion
            controller.setDiagnostics(diagnostics)
        }
        if documentChanged || context.coordinator.insightsVersion != insightsVersion {
            context.coordinator.insightsVersion = insightsVersion
            controller.setInsights(insights)
        }

        if let editRequest, editRequest.seq != context.coordinator.appliedEdit {
            context.coordinator.appliedEdit = editRequest.seq
            controller.apply(editRequest)
        }

        if documentChanged || context.coordinator.occurrenceSignature != occurrenceSignature {
            context.coordinator.occurrenceSignature = occurrenceSignature
            controller.setOccurrences(occurrences)
        }

        // Блоков изменений — единицы, сравнить массивы целиком дёшево.
        if documentChanged || context.coordinator.removedLines != removedLines {
            context.coordinator.removedLines = removedLines
            controller.setRemovedLines(removedLines)
        }
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

        if documentChanged || context.coordinator.blame != blame {
            context.coordinator.blame = blame
            controller.setBlame(blame)
        }

        if documentChanged || context.coordinator.breakpoints != breakpoints {
            context.coordinator.breakpoints = breakpoints
            controller.setBreakpoints(breakpoints)
        }
        if documentChanged || context.coordinator.executionLine != executionLine {
            context.coordinator.executionLine = executionLine
            controller.setExecutionLine(executionLine)
        }

        if documentChanged || context.coordinator.conflicts != conflicts {
            context.coordinator.conflicts = conflicts
            controller.setConflicts(conflicts)
        }

        if let conflictAction, conflictAction.seq != context.coordinator.appliedConflictAction {
            context.coordinator.appliedConflictAction = conflictAction.seq
            // Правка тут же публикует новые конфликты и позицию курсора, а
            // публиковать изнутри обновления вью SwiftUI не даёт.
            DispatchQueue.main.async {
                controller.applyConflictAction(start: conflictAction.start, choice: conflictAction.choice)
            }
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
        // чтобы повторный прыжок в то же место тоже сработал. Раскладку,
        // которая дойдёт позже, редактор догонит сам: он держит место, пока
        // переход не встанет (Landing). Вкладку, только что показанную на
        // этом самом месте (`buffer.landing`), не трогаем.
        if let reveal, let buffer, reveal.seq != context.coordinator.appliedReveal {
            context.coordinator.appliedReveal = reveal.seq
            let range = reveal.range.map { buffer.model.nsRange(for: $0) }
                ?? NSRange(location: 0, length: 0)
            if landed == range {
                // Уже на месте.
            } else if documentChanged {
                // Документ только что заменён, а переход пришёл не с ним
                // (объявление в тексте сборки ищется после показа): на
                // следующем витке — чтобы курсор не публиковался посреди
                // обновления вьюхи. Второй проход восстановления вкладки
                // встал в очередь раньше и его не перебьёт.
                DispatchQueue.main.async { [weak buffer] in
                    guard let buffer, controller.isShowing(buffer) else { return }
                    controller.reveal(range: range)
                }
            } else {
                controller.reveal(range: range)
            }
        }

        if focusRequest != context.coordinator.appliedFocus {
            context.coordinator.appliedFocus = focusRequest
            // Вьюха могла только что появиться и ещё не попасть в окно.
            DispatchQueue.main.async { controller.focusText() }
        }

        // После фокуса и тоже в следующем витке: ⌘F из палитры закрывает её,
        // и фокус сперва уходит в текст, а уже потом — в поле поиска.
        if let findRequest, findRequest.seq != context.coordinator.appliedFind {
            context.coordinator.appliedFind = findRequest.seq
            DispatchQueue.main.async { controller.performFind(findRequest.action) }
        }

        // Меню модальное — не изнутри обновления вью. Фокус мог быть
        // в дереве или палитре: меню всё равно о тексте, отдаём фокус ему.
        if contextActionsRequest != context.coordinator.appliedContextActions {
            context.coordinator.appliedContextActions = contextActionsRequest
            DispatchQueue.main.async {
                controller.focusText()
                controller.presentContextActions()
            }
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

    /// Редактор занимает всё, что ему дают. Без этого SwiftUI на каждом
    /// проходе раскладки выспрашивал бы размеры у AppKit через Auto Layout
    /// по всему дереву скролла, текста и линейки — а пока выезжает панель,
    /// раскладка идёт каждый кадр.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: CodeViewController,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        // Редактор пересоздан (после экрана «нет файла») — старый ⌘F
        // не должен открыть панель поиска сам по себе.
        coordinator.appliedFind = findRequest?.seq ?? 0
        coordinator.appliedContextActions = contextActionsRequest
        return coordinator
    }

    /// Редактор убирают совсем — например, вместо текста сообщение «файл
    /// не открыть». Вкладка должна вернуться туда же, где её оставили.
    static func dismantleNSViewController(_ controller: CodeViewController, coordinator: Coordinator) {
        controller.saveViewState()
    }

    final class Coordinator {
        weak var shown: TextBuffer?
        var fontSize: CGFloat = 12.5
        var appliedReveal: Int = -1
        var lineChanges: [LineDiff.Change] = []
        var removedLines: [RemovedLines] = []
        var commentMarks: [Int: CommentMark] = [:]
        var blame: BlameColumn?
        var isReview = false
        var appliedPopover = 0
        var conflicts: [MergeConflict] = []
        var breakpoints: [Int: BreakpointMark] = [:]
        var executionLine: Int?
        var appliedConflictAction = 0
        var occurrenceSignature: Int = 0
        var appliedFocus: Int = 0
        var appliedFind = 0
        var appliedContextActions = 0
        var decorationsVersion = 0
        var semanticsVersion = -1
        var appliedEdit = -1
        var diagnosticsVersion = -1
        var insightsVersion = -1
    }
}

/// Удалённые строки одного блока диффа: над какой новой строкой (с нуля) их
/// показать и что в них было.
struct RemovedLines: Equatable {
    var line: Int
    var lines: [String]
}
