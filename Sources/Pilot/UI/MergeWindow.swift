import SwiftUI
import AppKit

/// Окно слияния файла, как в Rider: слева наша версия, справа их, в
/// середине результат. Куски, которые правила одна сторона, уже слиты;
/// спорные решаются кнопками (← наша, → их, обе) или правкой текста.
/// Палочка решает то, что решается без человека.
struct MergeWindow: View {
    static let sceneID = "merge"

    /// `корень проекта` + `\n` + `путь от корня репозитория`.
    let target: String?
    @ObservedObject private var language = LanguageStore.shared

    var body: some View {
        Group {
            if let target, let resolved = resolve(target),
               let session = resolved.workspace.mergeSession(for: resolved.path) {
                MergeView(workspace: resolved.workspace, session: session)
                    .navigationTitle(L("Слияние — \((resolved.path as NSString).lastPathComponent)"))
            } else {
                Text(L("Проект этого окна закрыт"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(language.current)
        .frame(minWidth: 1000, minHeight: 560)
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
    }

    private func resolve(_ target: String) -> (workspace: Workspace, path: String)? {
        let parts = target.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let workspace = ProjectWindows.shared.workspaces.first(where: { $0.root?.path == parts[0] }) else { return nil }
        return (workspace, parts[1])
    }
}

struct MergeView: View {
    let workspace: Workspace
    @ObservedObject var session: MergeSession
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .text
    @State private var notice: String?
    @State private var picks: [String: UnityMerge.Pick] = [:]
    @State private var confirmUnresolved = false

    enum Mode: Hashable { case objects, text }

    var body: some View {
        VStack(spacing: 0) {
            if let editor = session.editor {
                // Счётчики и кнопки смотрят на сам редактор: его решения
                // сессию не меняют, и без этого «нерешено: 5» не убывало.
                EditorObserver(editor: editor) {
                    toolbar(editor)
                    Divider()
                    if mode == .objects, let objects = session.objects {
                        UnityObjectMergeView(session: session, result: objects, picks: $picks,
                                             resolve: { workspace.unity.assets?.displayName(for: $0) })
                    } else {
                        headers
                        Divider()
                        MergeEditor(model: editor)
                    }
                    Divider()
                    footer(editor)
                }
            } else if session.isBinary {
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text(L("Двоичный файл — слить его нельзя, только взять одну версию целиком"))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(L("Взять нашу: \(session.oursName)")) { finish { await session.takeWhole(true) } }
                        Button(L("Взять их: \(session.theirsName)")) { finish { await session.takeWhole(false) } }
                    }
                    .disabled(session.busy)
                    if let error = session.error {
                        Text(error).foregroundStyle(Color(nsColor: Theme.diagnosticError)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.error {
                Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: Theme.swiftUIEditorBackground))
        .onAppear { if !session.isLoaded { session.load() } }
        .onChange(of: session.objects != nil) { _, hasObjects in if hasObjects { mode = .objects } }
        .background {
            Button("") { dismiss() }.keyboardShortcut("w", modifiers: .command).hidden()
        }
        .confirmationDialog(L("Не все конфликты решены"), isPresented: $confirmUnresolved) {
            Button(L("Сохранить как есть")) { save() }
        } message: {
            Text(mode == .objects ? L("В нерешённых спорах останется наша сторона.")
                                  : L("В нерешённых кусках останется текст общего предка."))
        }
    }

    // MARK: - Верх

    private func toolbar(_ editor: MergeEditorModel) -> some View {
        HStack(spacing: 8) {
            if session.objects != nil {
                Picker("", selection: $mode) {
                    Text(L("По объектам")).tag(Mode.objects)
                    Text(L("Текстом")).tag(Mode.text)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(L("По объектам — споры по свойствам GameObject'ов и компонентов; текстом — три колонки, как для кода"))
            }
            if mode == .text || session.objects == nil {
                Button { editor.moveToPreviousConflict() } label: { Image(systemName: "chevron.up") }
                    .help(L("Предыдущий конфликт"))
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button { editor.moveToNextConflict() } label: { Image(systemName: "chevron.down") }
                    .help(L("Следующий конфликт"))
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button {
                    let count = editor.resolveSimple()
                    notice = count == 0 ? L("Само не решается ничего") : L("Решено само: \(count)")
                } label: {
                    Label(L("Решить простые"), systemImage: "wand.and.stars")
                }
                .help(L("Разница только в пробелах, вставки в одно место с обеих сторон"))
            }
            if session.yamlMerge != nil {
                Button("UnityYAMLMerge") { finish { await session.runYAMLMerge() } }
                    .help(L("Слить сцену или префаб по объектам — инструментом Unity"))
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            Spacer()
            Text(summary(editor)).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func summary(_ editor: MergeEditorModel) -> String {
        if mode == .objects, let objects = session.objects {
            let open = objects.conflicts.filter { picks[$0.id] == nil }.count
            return L("Слито само: \(objects.fromOurs + objects.fromTheirs) · споров: \(objects.conflicts.count), нерешено: \(open)")
        }
        return L("Изменений: \(editor.changeCount) · конфликтов: \(editor.conflictCount), нерешено: \(editor.unresolvedCount)")
    }

    private var headers: some View {
        HStack(spacing: 0) {
            column(L("Наша: \(session.oursName)"), missing: session.missing.ours)
            Color.clear.frame(width: MergeEditorView.stripWidth)
            column(L("Результат"), missing: false)
            Color.clear.frame(width: MergeEditorView.stripWidth)
            column(session.theirsName.isEmpty ? L("Их версия") : L("Их: \(session.theirsName)"),
                   missing: session.missing.theirs)
        }
        .font(.system(size: 12, weight: .medium))
        .frame(height: 26)
    }

    private func column(_ title: String, missing: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).truncationMode(.middle)
            if missing { Text(L("— файл удалён")).foregroundStyle(Color(nsColor: Theme.gitDeleted)) }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Низ

    private func footer(_ editor: MergeEditorModel) -> some View {
        HStack(spacing: 8) {
            if mode == .objects, let objects = session.objects {
                Button(L("Все — наши")) { for c in objects.conflicts { picks[c.id] = .ours } }
                Button(L("Все — их")) { for c in objects.conflicts { picks[c.id] = .theirs } }
            } else {
                Button(L("Принять левое")) { editor.acceptAll(.ours) }
                    .help(L("Весь файл — нашей версией"))
                Button(L("Принять правое")) { editor.acceptAll(.theirs) }
                    .help(L("Весь файл — их версией"))
            }
            if let error = session.error {
                Text(error).foregroundStyle(Color(nsColor: Theme.diagnosticError)).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            if session.busy { ProgressView().controlSize(.small) }
            Button(L("Отмена")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Применить")) {
                if unresolved(editor) > 0 { confirmUnresolved = true } else { save() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(session.busy)
            .help(L("Записать результат и отметить файл решённым"))
        }
        .font(.system(size: 12))
        .padding(10)
    }

    private func unresolved(_ editor: MergeEditorModel) -> Int {
        if mode == .objects, let objects = session.objects {
            return objects.conflicts.filter { picks[$0.id] == nil }.count
        }
        return editor.unresolvedCount
    }

    private func save() {
        let text = mode == .objects ? session.objects?.text(picks) : nil
        finish { await session.save(text: text, markResolved: true) }
    }

    private func finish(_ action: @escaping () async -> Bool) {
        Task {
            if await action() {
                workspace.mergeFinished(path: session.path)
                dismiss()
            }
        }
    }
}

/// Перерисовывает содержимое на каждое изменение редактора.
private struct EditorObserver<Content: View>: View {
    @ObservedObject var editor: MergeEditorModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
    }
}

// MARK: - По объектам

/// Сцена или префаб: споры списком, по объектам иерархии. У каждого —
/// значение с нашей стороны и с их, выбор — кнопкой. Всё, что правила
/// одна сторона, уже слито и сюда не попадает.
struct UnityObjectMergeView: View {
    @ObservedObject var session: MergeSession
    let result: UnityMerge.Result
    @Binding var picks: [String: UnityMerge.Pick]
    let resolve: UnityYAMLFile.Resolver
    @State private var names: [Int64: String] = [:]

    var body: some View {
        if result.conflicts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color(nsColor: Theme.gitAdded))
                Text(L("Споров нет — всё слилось по объектам само")).foregroundStyle(.secondary)
                Text(L("Слито само: \(result.fromOurs) наших правок и \(result.fromTheirs) их"))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.fileID) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "cube").foregroundStyle(.secondary)
                                Text(verbatim: names[group.fileID] ?? "&\(group.fileID)").font(.system(size: 13, weight: .semibold))
                                Text(verbatim: "&\(group.fileID)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                            ForEach(group.conflicts) { conflict in
                                row(conflict)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .task(id: result.conflicts.count) { names = await objectNames() }
        }
    }

    private struct Group { var fileID: Int64; var conflicts: [UnityMerge.Conflict] }

    private var groups: [Group] {
        var order: [Int64] = []
        var byID: [Int64: [UnityMerge.Conflict]] = [:]
        for conflict in result.conflicts {
            if byID[conflict.fileID] == nil { order.append(conflict.fileID) }
            byID[conflict.fileID, default: []].append(conflict)
        }
        return order.map { Group(fileID: $0, conflicts: byID[$0] ?? []) }
    }

    private func row(_ conflict: UnityMerge.Conflict) -> some View {
        let pick = picks[conflict.id]
        return HStack(alignment: .top, spacing: 10) {
            Text(title(conflict))
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 220, alignment: .leading)
                .lineLimit(2)
            side(L("Наше"), value: conflict.ours, chosen: pick == .ours) { picks[conflict.id] = .ours }
            side(L("Их"), value: conflict.theirs, chosen: pick == .theirs) { picks[conflict.id] = .theirs }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(pick == nil ? Color.red.opacity(0.08) : Color(nsColor: Theme.chromeBackground)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(pick == nil ? Color.red.opacity(0.35) : Color(nsColor: Theme.separator)))
    }

    private func title(_ conflict: UnityMerge.Conflict) -> String {
        switch conflict.kind {
        case .property: return conflict.property
        case .deletedByOurs: return L("объект удалён у нас, у них изменён")
        case .deletedByTheirs: return L("объект удалён у них, у нас изменён")
        }
    }

    private func side(_ label: String, value: [String]?, chosen: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen ? Color.accentColor : .secondary)
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(value == nil ? L("— удалено —") : UnityMerge.display(value))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(chosen ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Имена объектов: `Player / Body › PlayerController` — по нашей версии,
    /// а удалённых у нас — по их.
    private func objectNames() async -> [Int64: String] {
        let repository = session.repository, path = session.path
        let ids = Set(result.conflicts.map(\.fileID))
        let texts = await Task.detached { () -> [String] in
            [2, 3].compactMap { stage in
                Git.run(["show", ":\(stage):\(path)"], in: repository).map { String(decoding: $0.stdout, as: UTF8.self) }
            }
        }.value
        var names: [Int64: String] = [:]
        for text in texts {
            guard let file = UnityYAMLFile.parse(Array(text.utf16)) else { continue }
            for id in ids where names[id] == nil {
                if let index = file.index(ofFileID: id) { names[id] = file.describe(objectAt: index, resolve: resolve) }
            }
        }
        return names
    }
}
