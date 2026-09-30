import SwiftUI
import AppKit

/// Все конфликты слияния — по очереди, от первого до последнего: слева
/// список файлов с отметками, справа слияние выбранного (код, объекты,
/// ключи, картинки — какое ему подходит). Решил — окно переходит к
/// следующему; решены все — «Завершить слияние».
@MainActor
final class ConflictsModel: ObservableObject {
    /// Все файлы, что были в конфликте за это слияние, — в порядке файлов.
    @Published private(set) var files: [String] = []
    /// Какие из них ещё в конфликте.
    @Published private(set) var unresolved: Set<String> = []
    @Published var selection: String?
    @Published private(set) var loaded = false
    @Published var error: String?
    /// Список файлов слева: полезен, но на длинном слиянии занимает место.
    @Published var showsSidebar = true
    private(set) var repository: URL?

    var resolvedCount: Int { files.count - unresolved.count }
    var isDone: Bool { loaded && !files.isEmpty && unresolved.isEmpty }

    func open(repository: URL?) {
        if repository != self.repository {
            self.repository = repository
            files = []
            unresolved = []
            selection = nil
        }
        refresh()
    }

    /// Перечитать, что в конфликте. Новое слияние (прежние файлы решены
    /// и закоммичены, а конфликты другие) — список начинается заново.
    func refresh() {
        guard let repository else { return }
        Task {
            let current = await Task.detached { () -> [String] in
                guard let output = Git.run(["diff", "--name-only", "-z", "--diff-filter=U"], in: repository),
                      output.status == 0 else { return [] }
                return output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            }.value
            let fresh = Set(current)
            if !fresh.isEmpty, unresolved.isEmpty, fresh.isDisjoint(with: files) { files = [] }
            var all = files
            for path in current where !all.contains(path) { all.append(path) }
            all.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            if all != files { files = all }
            if fresh != unresolved { unresolved = fresh }
            loaded = true
            if selection == nil || (selection != "__done__" && !files.contains(selection!)) {
                selection = files.first { unresolved.contains($0) } ?? files.first
            }
        }
    }

    /// Файл решён — к следующему нерешённому (после него, потом с начала).
    func advance(after path: String) {
        guard let repository else { return }
        Task {
            let current = await Task.detached { () -> Set<String> in
                guard let output = Git.run(["diff", "--name-only", "-z", "--diff-filter=U"], in: repository),
                      output.status == 0 else { return [] }
                return Set(output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
            }.value
            unresolved = current
            let index = files.firstIndex(of: path) ?? -1
            let next = files[(index + 1)...].first { current.contains($0) } ?? files.first { current.contains($0) }
            // Решены все — к завершению слияния.
            selection = next ?? "__done__"
        }
    }

    /// Весь файл — одной стороной (`checkout --ours/--theirs` и `add`).
    func takeWhole(_ path: String, ours: Bool) {
        guard let repository else { return }
        Task {
            let result = await Task.detached { () -> Git.Result? in
                guard let checkout = Git.execute(["checkout", ours ? "--ours" : "--theirs", "--", path], in: repository),
                      checkout.succeeded else { return nil }
                return Git.execute(["add", "--", path], in: repository)
            }.value
            if result?.succeeded != true { error = L("Не удалось взять версию \((path as NSString).lastPathComponent)") }
            advance(after: path)
        }
    }

    /// Вернуть файлу конфликт, чтобы решить заново (`checkout -m`).
    func reopen(_ path: String) {
        guard let repository else { return }
        Task {
            let result = await Task.detached { Git.execute(["checkout", "-m", "--", path], in: repository) }.value
            if result?.succeeded != true { error = result?.message ?? L("Не удалось запустить git") }
            refresh()
            selection = path
        }
    }
}

struct ConflictsWindow: View {
    static let sceneID = "conflicts"
    let rootPath: String?
    @ObservedObject private var language = LanguageStore.shared

    var body: some View {
        Group {
            if let workspace = ProjectWindows.shared.workspaces.first(where: { $0.root?.path == rootPath }) {
                ConflictsView(workspace: workspace, model: workspace.conflictsModel, client: workspace.gitClient)
                    .navigationTitle(L("Конфликты — \(workspace.root?.lastPathComponent ?? "")"))
            } else {
                Text(L("Проект этого окна закрыт")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(language.current)
        .frame(minWidth: 1100, minHeight: 600)
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
    }
}

struct ConflictsView: View {
    let workspace: Workspace
    @ObservedObject var model: ConflictsModel
    @ObservedObject var client: GitClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HSplitView {
            if model.showsSidebar {
                sidebar.frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
            }
            detail.frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.showsSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    .help(model.showsSidebar ? L("Скрыть список файлов") : L("Показать список файлов"))
            }
            if !model.showsSidebar {
                ToolbarItem(placement: .navigation) { fileMenu }
            }
        }
        .background(Color(nsColor: Theme.swiftUIEditorBackground))
        .onAppear { model.open(repository: workspace.git.repository) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .background {
            Button("") { dismiss() }.keyboardShortcut("w", modifiers: .command).hidden()
        }
    }

    // MARK: - Список

    /// Список скрыт — файл и прогресс в заголовке, переход к любому файлу меню.
    private var fileMenu: some View {
        Menu {
            ForEach(model.files, id: \.self) { path in
                Button { model.selection = path } label: {
                    Label((path as NSString).lastPathComponent,
                          systemImage: model.unresolved.contains(path) ? "exclamationmark.triangle" : "checkmark.circle")
                }
            }
            if model.isDone {
                Divider()
                Button(L("Завершить")) { model.selection = "__done__" }
            }
        } label: {
            let name = model.selection.flatMap { $0 == "__done__" ? L("Завершить") : ($0 as NSString).lastPathComponent }
            Text(verbatim: "\(name ?? "") · " + L("Решено \(model.resolvedCount) из \(model.files.count)"))
        }
        .fixedSize()
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(client.operation?.title ?? L("Конфликты")).font(.system(size: 13, weight: .semibold))
                ProgressView(value: Double(model.resolvedCount), total: Double(max(model.files.count, 1)))
                Text(L("Решено \(model.resolvedCount) из \(model.files.count)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            List(selection: $model.selection) {
                ForEach(model.files, id: \.self) { path in
                    row(path).tag(path)
                }
                if model.isDone {
                    Label(L("Завершить"), systemImage: "flag.checkered")
                        .foregroundStyle(Color(nsColor: Theme.gitAdded))
                        .tag("__done__")
                }
            }
            .listStyle(.sidebar)
            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.diagnosticError))
                    .padding(8).lineLimit(3)
            }
        }
    }

    private func row(_ path: String) -> some View {
        let open = model.unresolved.contains(path)
        return HStack(spacing: 6) {
            Image(systemName: open ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(open ? Color(nsColor: Theme.gitConflicted) : Color(nsColor: Theme.gitAdded))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).lineLimit(1)
                Text(Self.kind(of: path)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .contextMenu {
            if open {
                Button(L("Взять наше целиком")) { model.takeWhole(path, ours: true) }
                Button(L("Взять их целиком")) { model.takeWhole(path, ours: false) }
            } else {
                Button(L("Решить заново")) { model.reopen(path) }
            }
            Divider()
            Button(L("Открыть в редакторе")) {
                if let repository = model.repository {
                    workspace.open(file: repository.appendingPathComponent(path))
                    workspace.bringToFront()
                }
            }
        }
    }

    /// Каким слиянием откроется: так понятно, что ждать.
    static func kind(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if MediaKind(filename: name) != nil { return L("картинка или модель — выбрать сторону") }
        if MergeSession.isUnityYAML(path) { return L("сцена или префаб — по объектам") }
        if (name as NSString).pathExtension.lowercased() == "json" { return L("JSON — по ключам") }
        return (path as NSString).deletingLastPathComponent
    }

    // MARK: - Справа

    @ViewBuilder
    private var detail: some View {
        if !model.loaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.files.isEmpty {
            done(nothing: true)
        } else if model.selection == "__done__" || (model.isDone && model.selection == nil) {
            done(nothing: false)
        } else if let path = model.selection, model.unresolved.contains(path),
                  let session = workspace.mergeSession(for: path) {
            MergeView(workspace: workspace, session: session, onDone: { model.advance(after: path) })
                .id(path)
        } else if let path = model.selection {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color(nsColor: Theme.gitAdded))
                Text(L("\((path as NSString).lastPathComponent) — решён")).foregroundStyle(.secondary)
                HStack {
                    Button(L("Решить заново")) { model.reopen(path) }
                    if model.isDone { Button(L("К завершению")) { model.selection = "__done__" }.buttonStyle(.borderedProminent) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(L("Выберите файл")).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func done(nothing: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 40))
                .foregroundStyle(Color(nsColor: Theme.gitAdded))
            Text(nothing ? L("Конфликтов нет") : L("Все конфликты решены")).font(.system(size: 16, weight: .semibold))
            if !nothing {
                Text(L("Файлов: \(model.files.count). Осталось закоммитить слияние."))
                    .foregroundStyle(.secondary)
            }
            if let operation = client.operation {
                Button(operation == .merge ? L("Завершить слияние") : L("Продолжить")) {
                    client.continueOperation()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(client.busy != nil || !model.unresolved.isEmpty)
            }
            if let error = client.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.diagnosticError))
                    .textSelection(.enabled).lineLimit(4)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { client.refreshOperation() }
    }
}
