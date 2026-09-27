import AppKit

/// Смысловые действия Rustlyn: лампочка ⌥↩ (исправления и рефакторинги),
/// форматирование, иерархии вызовов и типов.
extension Workspace {
    // MARK: - Лампочка

    /// Исправления и рефакторинги у курсора или для выделения — пунктами
    /// меню ⌥↩. Rustlyn считает их по скомпилированному проекту; меню ждёт
    /// ответа не дольше пары секунд, а без ответа показывается без них.
    func codeActionGroups(selection: NSRange) async -> [ContextActionGroup] {
        guard let buffer, !buffer.isReadOnly, Rustlyn.understands(buffer.url), let rustlyn else { return [] }
        var groups: [ContextActionGroup] = []
        let format = ContextAction(
            title: selection.length > 0 ? L("Форматировать выделение") : L("Форматировать файл"),
            icon: "text.alignleft",
            shortcut: KeymapStore.shared.menuShortcut(.formatCode)) { [weak self] in
            self?.formatCode(selection: selection)
        }
        guard compiler.isReady else {
            return [ContextActionGroup(title: nil, actions: [format])]
        }
        let url = buffer.url
        let text = buffer.model.text
        let actions = await withDeadline(seconds: 2.5) { [referenceQueue] finish in
            referenceQueue.async { finish(rustlyn.codeActions(url, range: selection, text: text)) }
        } ?? nil

        // «Generate overrides...» и прочие с многоточием ждут диалога выбора;
        // без него Rustlyn берёт всё подряд — вплоть до `Finalize`. Пока
        // диалогов нет, таких пунктов нет и в меню.
        let all = (actions ?? []).filter { !$0.title.hasSuffix("...") && !$0.title.hasSuffix("…") }
        let fixes = all.filter { $0.kind == .quickFix }
        let refactorings = all.filter { $0.kind != .quickFix }
        let perform = { [weak self] (action: RustlynCodeAction) in
            self?.applyCodeAction(action, url: url, askedText: text)
        }
        if !fixes.isEmpty {
            groups.append(ContextActionGroup(title: L("Исправления"), actions: fixes.map { action in
                ContextAction(title: action.title, icon: "wand.and.stars") { perform(action) }
            }, leading: true))
            // Одно исправление — во всём файле или проекте, как Fix All у Roslyn.
            var codes: [String] = []
            for fix in fixes where !fix.fixes.isEmpty && !codes.contains(fix.fixes) { codes.append(fix.fixes) }
            let everywhere = codes.flatMap { code in [
                ContextAction(title: L("\(code): исправить во всём файле"), icon: "doc.badge.gearshape") { [weak self] in
                    self?.fixAll(code: code, inProject: false)
                },
                ContextAction(title: L("\(code): исправить во всём проекте"), icon: "folder.badge.gearshape") { [weak self] in
                    self?.fixAll(code: code, inProject: true)
                },
            ] }
            if !everywhere.isEmpty { groups.append(ContextActionGroup(title: nil, actions: everywhere, leading: true)) }
        }
        var refactor = refactorings.map { action in
            ContextAction(title: action.title, icon: Self.icon(for: action.kind)) { perform(action) }
        }
        refactor.append(format)
        groups.append(ContextActionGroup(title: L("Рефакторинги"), actions: refactor))
        return groups
    }

    private static func icon(for kind: RustlynCodeAction.Kind) -> String {
        switch kind {
        case .quickFix: return "wand.and.stars"
        case .refactor: return "arrow.triangle.2.circlepath"
        case .extract: return "rectangle.portrait.and.arrow.right"
        case .inline: return "arrow.down.right.and.arrow.up.left"
        case .rewrite: return "pencil"
        case .organize: return "list.bullet"
        case .generate: return "plus.square.on.square"
        }
    }

    /// Правки действия — туда, где их посчитали. Открытый файл должен быть
    /// тем же текстом, с которым спрашивали; прочие открытые вкладки с
    /// несохранённым пропускаются: для них Rustlyn считал по сохранённому.
    func applyCodeAction(_ action: RustlynCodeAction, url: URL, askedText: String) {
        applyEdits(action.edits, files: action.files, actionName: action.title, asked: url, askedText: askedText)
    }

    private func applyEdits(_ edits: [RustlynFileEdit], files: [RustlynFileMove], actionName: String,
                            asked: URL, askedText: String) {
        guard !edits.isEmpty || !files.isEmpty else {
            showNotice(L("«\(actionName)»: менять нечего"))
            return
        }
        let asked = asked.standardizedFileURL
        let outcome = applyProjectEdits(edits, files: files, actionName: actionName) { [weak self] url, _, current in
            if url == asked { return current as String == askedText }
            if let tab = self?.tab(for: url, revision: nil), tab.isDirty { return false }
            return true
        }
        if !outcome.skipped.isEmpty {
            let list = outcome.skipped.map(\.lastPathComponent).sorted().joined(separator: ", ")
            showNotice(L("«\(actionName)»: не применено к \(list) — текст изменился, повторите"))
        } else if outcome.files > 1 {
            showNotice(L("«\(actionName)»: \(Theme.count(outcome.files, "файл", "файла", "файлов"))"))
        }
    }

    /// Исправление диагностики `code` во всём файле или проекте.
    func fixAll(code: String, inProject: Bool) {
        guard let buffer, let rustlyn else { return }
        let url = buffer.url, text = buffer.model.text
        showNotice(L("Исправляю \(code)…"))
        referenceQueue.async { [weak self] in
            let result = rustlyn.fixAll(url, code: code, inProject: inProject, text: text)
            let reason = result == nil ? rustlyn.lastError : ""
            Task { @MainActor in
                guard let self else { return }
                guard let result else {
                    self.showNotice(L("Не удалось исправить \(code): \(reason)"))
                    return
                }
                self.applyEdits(result.edits, files: result.files, actionName: L("Исправить \(code)"),
                                asked: url, askedText: text)
            }
        }
    }

    // MARK: - Форматирование

    /// ⌥⌘L: весь файл или строки выделения — по правилам Roslyn и
    /// `.editorconfig`. Только синтаксис, миллисекунды, поэтому сразу.
    func formatCode(selection: NSRange? = nil) {
        guard let buffer, !buffer.isReadOnly else { NSSound.beep(); return }
        guard Rustlyn.understands(buffer.url), let rustlyn else {
            showNotice(L("Форматирование пока только для C#"))
            return
        }
        let url = buffer.url, text = buffer.model.text
        let result: RustlynEdits?
        if let selection, selection.length > 0 {
            result = rustlyn.formatRange(url, range: selection, text: text)
        } else {
            result = rustlyn.formatDocument(url, text: text)
        }
        guard let result else {
            showNotice(L("Не удалось отформатировать: \(rustlyn.lastError)"))
            return
        }
        let edits = result.edits.filter { $0.url.standardizedFileURL == url.standardizedFileURL }
            .map { (range: $0.range, text: $0.text) }
        guard !edits.isEmpty else {
            showNotice(L("Уже отформатировано"))
            return
        }
        buffer.applyEdits(edits, actionName: L("Форматирование"))
    }

    // MARK: - Иерархии

    /// ⌃⌥⇧H: кто вызывает метод под курсором и что вызывает он сам.
    func showCallHierarchy() { showHierarchy(.calls) }

    /// ⌃H: базовые типы и наследники типа под курсором.
    func showTypeHierarchy() { showHierarchy(.types) }

    private func showHierarchy(_ kind: HierarchyModel.Kind) {
        guard let buffer, Rustlyn.understands(buffer.url), let rustlyn else {
            showNotice(L("Иерархия пока только для C#"))
            return
        }
        guard compiler.isReady else {
            showNotice(L("Rustlyn ещё компилирует проект — иерархия будет через несколько секунд"))
            return
        }
        let url = buffer.url, text = buffer.model.text, offset = caretOffset
        referenceQueue.async { [weak self] in
            let root = kind == .calls
                ? rustlyn.callHierarchy(url, offset: offset, text: text)
                : rustlyn.typeHierarchy(url, offset: offset, text: text)
            let reason = root == nil ? rustlyn.lastError : ""
            Task { @MainActor in
                guard let self else { return }
                guard let root else {
                    self.showNotice(kind == .calls
                        ? L("Под курсором нет метода, свойства или поля") + (reason.isEmpty ? "" : ": \(reason)")
                        : L("Под курсором нет типа") + (reason.isEmpty ? "" : ": \(reason)"))
                    return
                }
                self.hierarchy = HierarchyModel(kind: kind, root: root, rustlyn: rustlyn, queue: self.referenceQueue)
                self.navigatorTab = .hierarchy
                self.showsSidebar = true
            }
        }
    }
}

/// Ответ фоновой работы, но не позже `seconds`: опоздавший — `nil`.
@MainActor
func withDeadline<T>(seconds: Double, _ work: @escaping (@escaping (T) -> Void) -> Void) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = ResumeOnce(continuation)
        work { value in once.resume(value) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
    }
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func resume(_ value: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
