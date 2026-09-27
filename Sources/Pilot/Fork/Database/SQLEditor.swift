import SwiftUI
import AppKit

/// Что выделено в редакторе — чтобы ⌘↩ выполнил только это.
final class SQLEditorState {
    weak var textView: NSTextView?

    var selectedText: String? {
        guard let view = textView else { return nil }
        let range = view.selectedRange()
        guard range.length > 0 else { return nil }
        return (view.string as NSString).substring(with: range)
    }
}

/// SQL-редактор окна базы — тот же редактор кода, что и в проекте
/// (`CodeViewController`): подсветка по цветовой схеме, номера строк, ⌘/,
/// парные скобки и кавычки, список дополнения со стрелками, Return, Tab и Esc.
///
/// Текст живёт в `TextBuffer` без файла на диске: у буфера своя история ⌘Z,
/// а наружу текст уходит строкой (`DatabaseBrowser.sql` его и сохраняет).
/// Варианты дополнения даёт `completions` — по модели текста и позиции.
struct SQLEditor: NSViewControllerRepresentable {
    @Binding var text: String
    let state: SQLEditorState
    let fontSize: CGFloat
    let completions: (SyntaxModel, Int) async -> CompletionList?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSViewController(context: Context) -> CodeViewController {
        let coordinator = context.coordinator
        let controller = CodeViewController()
        controller.loadViewIfNeeded()
        // Буфер — сразу размером редактора по умолчанию: так `show` не
        // перенабирает его шрифтом, а нужный размер ставит `setFontSize`.
        let buffer = TextBuffer(document: Self.document(text), fontSize: Workspace.defaultFontSize)
        buffer.onEdit = { [weak coordinator] buffer, _, _ in coordinator?.edited(buffer) }
        coordinator.buffer = buffer
        // «.» — столбцы таблицы или псевдонима, «`» — имя в кавычках.
        controller.completionTriggers = [".", "`"]
        controller.requestCompletions = { [weak buffer, weak coordinator] offset, _, _ in
            guard let buffer, let coordinator else { return nil }
            return await coordinator.parent.completions(buffer.model, offset)
        }
        controller.show(buffer)
        coordinator.fontSize = fontSize
        if fontSize != Workspace.defaultFontSize { controller.setFontSize(fontSize) }
        let textView = (controller.view as? NSScrollView)?.documentView as? NSTextView
        state.textView = textView
        coordinator.attach(controller, textView: textView)
        return controller
    }

    func updateNSViewController(_ controller: CodeViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.fontSize != fontSize {
            coordinator.fontSize = fontSize
            controller.setFontSize(fontSize)
        }
        // Текст поменяли снаружи: двойной щелчок по таблице, «Данные», «DDL».
        if let buffer = coordinator.buffer, buffer.storage.string != text {
            coordinator.replace(with: text, in: controller)
        }
    }

    static func dismantleNSViewController(_ controller: CodeViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Редактор занимает, что дают: иначе SwiftUI выспрашивал бы размеры
    /// у скролла и линейки через Auto Layout на каждом проходе раскладки.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: CodeViewController,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    /// Документ без файла: путь буферу нужен как имя, на диск его не пишут.
    private static func document(_ text: String) -> LoadedDocument {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Pilot Database Console.sql")
        return LoadedDocument(url: url, model: SyntaxModel(text: text, spec: SQLDialect.mariadb),
                              languageName: SQLDialect.mariadb.name, outline: [], encoding: .utf8)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SQLEditor
        var buffer: TextBuffer?
        var fontSize: CGFloat = 0
        private weak var controller: CodeViewController?
        private weak var textView: NSTextView?
        private var keyMonitor: Any?
        /// Правка пришла в текст, а текстовое поле о ней не сообщило.
        private var repaintPending = false

        init(_ parent: SQLEditor) { self.parent = parent }

        deinit {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            NotificationCenter.default.removeObserver(self)
        }

        func attach(_ controller: CodeViewController, textView: NSTextView?) {
            self.controller = controller
            self.textView = textView
            installKeyMonitor()
            NotificationCenter.default.addObserver(self, selector: #selector(textViewChanged),
                                                   name: NSText.didChangeNotification, object: textView)
        }

        func detach() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            NotificationCenter.default.removeObserver(self)
        }

        /// Правка в редакторе — в строку запроса.
        ///
        /// Редактор перекрашивает текст по сообщению текстового поля. Правки
        /// мимо него — замена запроса и её ⌘Z — такого сообщения не шлют:
        /// их перекрашиваем сами, когда правка уляжется.
        func edited(_ buffer: TextBuffer) {
            let text = buffer.storage.string
            if parent.text != text { parent.text = text }
            repaintPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.repaintPending else { return }
                self.repaintPending = false
                self.controller?.invalidateDecorations()
            }
        }

        @objc private func textViewChanged() {
            repaintPending = false
        }

        /// Текст заменили снаружи — одной правкой: вернуть прежний запрос можно ⌘Z.
        func replace(with text: String, in controller: CodeViewController) {
            guard let buffer else { return }
            textView?.breakUndoCoalescing()
            buffer.applyEdits([(NSRange(location: 0, length: buffer.storage.length), text)],
                              actionName: L("Замена запроса"))
            textView?.breakUndoCoalescing()
            let end = NSRange(location: (text as NSString).length, length: 0)
            textView?.setSelectedRange(end)
            textView?.scrollRangeToVisible(end)
            // Хранилище правили мимо текстового поля — перекрасить видимое сразу.
            repaintPending = false
            controller.invalidateDecorations()
        }

        /// ⌃Space — список дополнения, как в Rider и DataGrip. ⌥Esc и Esc
        /// открывают его и так: это пункт меню и сам редактор.
        private func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let textView = self?.textView, event.window === textView.window,
                      textView.window?.firstResponder === textView,
                      event.keyCode == 49,   // пробел
                      event.modifierFlags.intersection([.command, .option, .control, .shift]) == .control
                else { return event }
                textView.complete(nil)
                return nil
            }
        }
    }
}
