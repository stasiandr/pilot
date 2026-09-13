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

    private(set) var isDirty = false
    private var savedUnits: [UInt16]

    /// Правка: `range` — в координатах текста до неё (так её ждёт LSP).
    var onEdit: ((TextBuffer, LSPRange, String) -> Void)?
    var onDirtyChange: ((TextBuffer) -> Void)?

    var url: URL { document.url }
    var model: SyntaxModel { document.model }
    /// Версия файла из коммита (ревью MR): правок в ней не бывает,
    /// и сохранять её поверх рабочей копии нельзя.
    var isReadOnly: Bool { document.revision != nil }

    init(document: LoadedDocument, fontSize: CGFloat) {
        self.document = document
        self.fontSize = fontSize
        let units = document.model.units
        savedUnits = units
        indentUnit = EditingRules.indentUnit(in: units)
        lineEnding = EditingRules.lineEnding(in: units)
        storage = NSTextStorage(string: document.text, attributes: [
            .font: Theme.editorFont(size: fontSize),
            .foregroundColor: Theme.color(.plain),
        ])
        super.init()
        storage.delegate = self
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
        model.replace(oldRange, with: replacement)

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
