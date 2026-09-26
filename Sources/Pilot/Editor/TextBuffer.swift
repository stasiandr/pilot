import AppKit

/// Открытый в редакторе файл.
///
/// У каждого буфера свой NSTextStorage и своя история отмены: переключился
/// на другой файл и вернулся — правки и ⌘Z на месте. Синтаксическая модель
/// правится вместе с текстом, инкрементально, в том же вызове — подсветка,
/// позиции для языкового сервера и структура файла всегда видят тот же
/// текст, что и экран.
@MainActor
final class TextBuffer: NSObject, NSTextStorageDelegate {

    private(set) var document: LoadedDocument
    let storage: NSTextStorage
    let undoManager = UndoManager()

    /// Единица отступа и перевод строки — такие, как уже приняты в файле.
    let indentUnit: String
    let lineEnding: String

    /// Размер шрифта, которым сейчас набран текст: при показе буфера
    /// с другим размером шрифт переставляется.
    var fontSize: CGFloat
    /// Что было на экране, когда ушли на другую вкладку. nil — буфер
    /// ещё не показывали: откроется с начала.
    var viewState: ViewState?
    /// Где был курсор, когда ушли на другой файл.
    var lastCaret: Int { viewState?.selection.location ?? 0 }
    /// Когда вкладку последний раз делали активной. По этому порядку ходит
    /// ⌃Tab, и по нему же выбирается, какую вкладку закрыть сверх лимита.
    var lastActivated = 0

    /// Прокрутка — первой видимой строкой, а не координатой: раскладка
    /// ленивая, и координата далёкой строки до раскладки — лишь оценка.
    struct ViewState {
        var selection: NSRange
        var topLine: Int
        /// На сколько точек первая видимая строка уехала за верхний край.
        var topOffset: CGFloat
        var scrollX: CGFloat
    }

    /// Свёрнутые куски — то, что спрятано, в UTF-16. Живут с буфером:
    /// ушёл на другую вкладку и вернулся — свёрнуто, как было.
    var folded: [NSRange] = []

    private(set) var isDirty = false
    private var savedUnits: [UInt16]

    /// Правка: `range` — в координатах текста до неё (так её ждёт LSP).
    var onEdit: ((TextBuffer, LSPRange, String) -> Void)?
    var onDirtyChange: ((TextBuffer) -> Void)?
    /// Та же правка для редактора, в координатах после неё: `range` — новый
    /// текст, `delta` — изменение длины, с `settled` токены прежние.
    /// Приходит посреди обработки правки: только запомнить, не рисовать.
    var onDisplayEdit: ((_ range: NSRange, _ delta: Int, _ settled: Int) -> Void)?

    var url: URL { document.url }
    var model: SyntaxModel { document.model }
    /// Версия файла из коммита (ревью MR): правок в ней не бывает,
    /// и сохранять её поверх рабочей копии нельзя.
    var isReviewVersion: Bool { document.revision != nil }
    /// Править нечего: версия из MR, код, полученный из сборки или от jadx,
    /// картинка или модель.
    var isReadOnly: Bool {
        isReviewVersion || document.decompiled != nil || document.media != nil || isGenerated
    }
    /// Код генератора исходников: его перепишет следующая компиляция, так
    /// что правка пропала бы. Спрашиваем Rustlyn один раз, при открытии.
    let isGenerated: Bool
    /// Вкладку можно вернуть после перезапуска: и файл, и сборка лежат на
    /// своих местах. Версия из MR — нет: её коммит ещё надо найти; класс
    /// от jadx — тоже: его путь внутри архива, а не на диске.
    var isRestorable: Bool { !isReviewVersion && document.decompiled != .jadx }
    /// Markdown показан исходником, а не свёрстанным.
    var showsMarkdownSource = false
    /// Прокрутка свёрстанного Markdown — чтобы вернуться на то же место.
    var markdownScroll: Double = 0

    init(document: LoadedDocument, fontSize: CGFloat) {
        self.document = document
        self.fontSize = fontSize
        let units = document.model.units
        savedUnits = units
        indentUnit = EditingRules.indentUnit(in: units)
        lineEnding = EditingRules.lineEnding(in: units)
        isGenerated = document.revision == nil && document.decompiled == nil
            && Rustlyn.session(for: document.url)?.isGenerated(document.url) == true
        storage = NSTextStorage(string: document.text, attributes: [
            .font: Theme.editorFont(size: fontSize),
            .foregroundColor: Theme.color(.plain),
        ])
        super.init()
        storage.delegate = self
        fixAttributesAhead()
    }

    // MARK: - Атрибуты текста

    private var fixGeneration = 0

    /// NSTextStorage «чинит» атрибуты — подбирает шрифт под символы — лениво,
    /// при первом обращении. Пока в тексте остаётся непочиненный кусок,
    /// каждая правка обходится TextKit в проход по нему: на файле в 10 000
    /// строк это больше миллисекунды на букву. Поэтому чиним весь текст
    /// заранее — кусками между событиями, чтобы не задержать ни открытие,
    /// ни набор. Звать и после смены шрифта: она снова всё «ломает».
    func fixAttributesAhead() {
        fixGeneration += 1
        fixAttributes(from: 0, generation: fixGeneration)
    }

    private func fixAttributes(from start: Int, generation: Int) {
        // Кусок — около 2 мс работы.
        let chunk = 65_536
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
            guard let self, self.fixGeneration == generation else { return }
            let length = self.storage.length
            guard start < length else { return }
            let end = min(length, start + chunk)
            self.storage.ensureAttributesAreFixed(in: NSRange(location: start, length: end - start))
            self.fixAttributes(from: end, generation: generation)
        }
    }

    func setOutline(_ outline: [OutlineItem]) {
        document.outline = outline
    }

    /// Разбор устарел не из-за правки (например, дособрался индекс GUID):
    /// вкладка переразберёт файл, когда на неё вернутся.
    func invalidateSemantics() {
        document.semanticsVersion = -1
    }

    /// Структура и разбор Unity вместе с версией модели, по которой они
    /// построены: пока текст её не догнал, позициям разбора не верим.
    func setSemantics(outline: [OutlineItem], unityFile: UnityYAMLFile?, hierarchy: UnityHierarchy?,
                      version: Int) {
        document.outline = outline
        document.unityFile = unityFile
        document.unityHierarchy = hierarchy
        document.semanticsVersion = version
    }

    // MARK: - Правки

    /// Сюда приходит любая правка текста: набор, вставка, ⌘Z, дополнение.
    /// Смена цвета при подсветке тоже приходит, но без `.editedCharacters`.
    nonisolated func textStorage(_ textStorage: NSTextStorage,
                                 didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange,
                                 changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { apply(editedRange, delta) }
    }

    private func apply(_ editedRange: NSRange, _ delta: Int) {
        // Несколько правок внутри одного beginEditing сливаются в общий
        // диапазон — для модели это та же правка, просто пошире.
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let model = document.model
        let range = LSPRange(start: model.position(at: oldRange.location),
                             end: model.position(at: NSMaxRange(oldRange)))

        var replacement = [UInt16](repeating: 0, count: editedRange.length)
        (storage.string as NSString).getCharacters(&replacement, range: editedRange)
        let settled = model.replace(oldRange, with: replacement)

        onDisplayEdit?(editedRange, delta, settled)
        onEdit?(self, range, String(decoding: replacement, as: UTF16.self))
        updateDirty()
    }

    /// Сравнение с сохранённым текстом, а не счётчик правок: отменил всё
    /// через ⌘Z — файл снова чистый, как в Xcode. Длина почти всегда
    /// отличается, так что обычно это одно сравнение чисел.
    private func updateDirty() {
        let dirty = document.model.units != savedUnits
        guard dirty != isDirty else { return }
        isDirty = dirty
        onDirtyChange?(self)
    }

    // MARK: - Правки не из редактора

    /// Правки текста, которые пришли не с клавиатуры, — переименование по
    /// всему проекту. Одним шагом ⌘Z, и в той же истории, что набор: это
    /// тот же менеджер отмены, которым пользуется редактор.
    func applyEdits(_ edits: [(range: NSRange, text: String)], actionName: String) {
        let valid = edits.filter { NSMaxRange($0.range) <= storage.length }
            .sorted { $0.range.location > $1.range.location }
        guard !valid.isEmpty, !isReadOnly else { return }
        // Что вернуть при отмене: те же места, но в координатах после правки.
        var inverse: [(range: NSRange, text: String)] = []
        var shift = 0
        for edit in valid.reversed() {
            let old = (storage.string as NSString).substring(with: edit.range)
            let length = (edit.text as NSString).length
            inverse.append((NSRange(location: edit.range.location + shift, length: length), old))
            shift += length - edit.range.length
        }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { buffer in
            MainActor.assumeIsolated { buffer.applyEdits(inverse, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        for edit in valid {
            storage.replaceCharacters(in: edit.range, with: edit.text)
        }
    }

    // MARK: - Файл поменяли снаружи

    /// Файл переписали не мы — checkout, другой редактор, генератор: текст —
    /// тот, что теперь на диске, и буфер снова чистый.
    ///
    /// Заменяется только отличающаяся середина: каретка, прокрутка и свёрнутое
    /// вне неё остаются на месте. Одним шагом ⌘Z — вернуть прежний текст
    /// можно, как после любой правки. Сгенерированный код, открытый только
    /// для чтения, перечитывается тоже: его и переписывает генератор.
    func reload(from text: String) {
        let old = storage.string as NSString
        let new = text as NSString
        let oldLength = old.length, newLength = new.length
        var prefix = 0
        while prefix < min(oldLength, newLength),
              old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(oldLength, newLength) - prefix,
              old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: oldLength - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
        if range.length > 0 || !replacement.isEmpty {
            if isReadOnly {
                storage.replaceCharacters(in: range, with: replacement)
                undoManager.removeAllActions()
            } else {
                applyEdits([(range, replacement)], actionName: L("Изменение на диске"))
            }
        }
        savedUnits = document.model.units
        updateDirty()
    }

    // MARK: - Сохранение

    enum SaveError: LocalizedError {
        case write(String)
        var errorDescription: String? {
            switch self { case .write(let why): return why }
        }
    }

    /// Пишем атомарно (через временный файл), а права восстанавливаем:
    /// иначе у скрипта после сохранения пропал бы бит исполнения.
    /// Если текст не ложится в исходную кодировку — сохраняем в UTF-8.
    func save() throws {
        guard !isReadOnly else { return }
        let text = storage.string
        let data = text.data(using: document.encoding) ?? Data(text.utf8)
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SaveError.write(error.localizedDescription)
        }
        if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        savedUnits = document.model.units
        updateDirty()
    }
}
