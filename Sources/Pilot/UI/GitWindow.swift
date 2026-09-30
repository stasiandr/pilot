import SwiftUI
import AppKit

/// Окно git: вкладки сверху, под ними — полосы незаконченной операции и
/// ускорения большого репозитория, снизу — что делается и чем кончилось.
struct GitWindowView: View {
    let workspace: Workspace
    @ObservedObject var client: GitClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            GitOperationBar(workspace: workspace, client: client)
            if let tuning = client.tuning, !tuning.isComplete {
                TuningBanner(client: client, state: tuning)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if client.busy != nil || client.error != nil || client.notice != nil {
                Divider()
                GitClientStatus(client: client)
            }
        }
        .background(Color(nsColor: Theme.swiftUIEditorBackground))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $client.windowTab) {
                    ForEach(GitWindowTab.allCases, id: \.self) { tab in
                        Label(tab.title, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { client.fetch() } label: { Label(L("Получить"), systemImage: "arrow.down.circle") }
                    .help("git fetch --all --prune")
                Button { client.pull() } label: { Label(L("Обновить ветку"), systemImage: "arrow.down.to.line") }
                    .help("git pull --autostash")
                Button { client.push() } label: { Label(L("Отправить"), systemImage: "arrow.up.circle") }
                    .help("git push")
            }
        }
        .onAppear { client.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            client.refresh()
            client.refreshOperation()
        }
        .background {
            Button("") { dismiss() }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
            // ⌘1…⌘5 — вкладки.
            ForEach(Array(GitWindowTab.allCases.enumerated()), id: \.offset) { index, tab in
                Button("") { client.windowTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .hidden()
            }
        }
        .alert(client.offer?.message ?? "", isPresented: Binding(get: { client.offer != nil },
                                                                 set: { if !$0 { client.offer = nil } }),
               presenting: client.offer) { offer in
            switch offer.kind {
            case .stashAndSwitch:
                Button(L("Спрятать правки и переключить")) { client.accept(offer) }
            case .forceDelete:
                Button(L("Удалить"), role: .destructive) { client.accept(offer) }
            }
            Button(L("Отмена"), role: .cancel) { client.offer = nil }
        } message: { offer in
            switch offer.kind {
            case .stashAndSwitch:
                Text(L("Правки уйдут в stash, ветка переключится, и они вернутся. Если не лягут — останутся в stash."))
            case .forceDelete:
                Text(L("Коммиты можно будет найти только через reflog."))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch client.windowTab {
        case .commit: CommitView(workspace: workspace, commits: workspace.commits)
        case .history: GitHistoryView(workspace: workspace, history: workspace.gitHistory, client: client)
        case .branches: GitBranchesView(workspace: workspace, client: client)
        case .stash: GitStashView(client: client)
        case .journal: GitJournalView(client: client)
        }
    }
}

// MARK: - Полосы

/// Идёт слияние, rebase или cherry-pick: продолжить, прервать, пропустить.
/// Над редактором — та же полоса: конфликт решают там.
struct GitOperationBar: View {
    let workspace: Workspace
    @ObservedObject var client: GitClient

    var body: some View {
        if let operation = client.operation {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(Color(nsColor: Theme.gitConflicted))
                Text(operation.title).fontWeight(.medium)
                let conflicts = workspace.git.conflictedCount
                if conflicts > 0 {
                    Text(L("конфликтов: \(conflicts)")).foregroundStyle(Color(nsColor: Theme.gitConflicted))
                    Button(L("Разрешить…")) { workspace.openNextConflict() }
                }
                Spacer()
                if operation != .merge {
                    Button(L("Пропустить коммит")) { client.skipCommit() }
                        .disabled(client.busy != nil)
                }
                Button(L("Прервать")) { client.abortOperation() }
                    .disabled(client.busy != nil)
                    .help(L("Вернуть всё, как было до начала"))
                Button(L("Продолжить")) { client.continueOperation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(client.busy != nil || conflicts > 0)
                    .help(conflicts > 0 ? L("Сначала разрешите конфликты") : "")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: Theme.gitConflicted).opacity(0.12))
        }
    }
}

/// Большой репозиторий, а fsmonitor, split index или commit-graph не
/// включены постоянно. Pilot и так передаёт их своим командам, но
/// терминал и запись индекса без них медленнее.
private struct TuningBanner: View {
    @ObservedObject var client: GitClient
    let state: Git.Tuning.State
    @AppStorage("pilot.git.tuningDismissed") private var dismissed = ""

    var body: some View {
        if dismissed != client.repository?.path {
            HStack(spacing: 10) {
                Image(systemName: "hare").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Большой репозиторий")).fontWeight(.medium)
                    Text(L("Включить fsmonitor, кэш неотслеживаемых, split index и commit-graph: git status и запись индекса станут в разы быстрее и в терминале."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L("Не сейчас")) { dismissed = client.repository?.path ?? "" }
                Button(L("Ускорить")) { client.enableTuning() }
                    .buttonStyle(.borderedProminent)
                    .disabled(client.busy != nil)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
        }
    }
}

struct GitClientStatus: View {
    @ObservedObject var client: GitClient

    var body: some View {
        HStack(spacing: 6) {
            if let busy = client.busy {
                ProgressView().controlSize(.mini)
                Text(busy).foregroundStyle(.secondary)
            } else if let error = client.error {
                Image(systemName: "xmark.octagon").foregroundStyle(Color(nsColor: Theme.diagnosticError))
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: Theme.diagnosticError))
                    .textSelection(.enabled)
                    .lineLimit(4)
                Spacer()
                Button(L("Журнал")) { client.windowTab = .journal }.controlSize(.small)
                Button { client.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            } else if let notice = client.notice {
                Image(systemName: "checkmark.circle").foregroundStyle(Color(nsColor: Theme.gitAdded))
                Text(notice).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Stash

struct GitStashView: View {
    @ObservedObject var client: GitClient
    @State private var selection: String?
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var files: [GitChangedFile] = []
    @State private var selectedFile: String?
    @State private var patch: GitFilePatch?
    @State private var confirmDrop: GitStash?

    private var selected: GitStash? { client.stashes.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L("Что прячем (необязательно)"), text: $message)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    HStack {
                        Toggle(L("С новыми файлами"), isOn: $includeUntracked).toggleStyle(.checkbox)
                        Spacer()
                        Button(L("Спрятать правки"), action: save).disabled(client.busy != nil)
                    }
                }
                .font(.system(size: 12))
                .padding(12)
                Divider()
                List(selection: $selection) {
                    ForEach(client.stashes) { stash in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stash.message).lineLimit(1)
                            Text("\(stash.ref) · \(stash.date.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .tag(stash.id)
                        .contextMenu {
                            Button(L("Достать (pop)")) { client.applyStash(stash, pop: true) }
                            Button(L("Применить, оставив в stash")) { client.applyStash(stash, pop: false) }
                            Divider()
                            Button(L("Удалить…"), role: .destructive) { confirmDrop = stash }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if client.stashes.isEmpty {
                        Text(L("Ничего не спрятано")).foregroundStyle(.tertiary)
                    }
                }
                if let selected {
                    Divider()
                    HStack {
                        Button(L("Удалить…")) { confirmDrop = selected }
                        Spacer()
                        Button(L("Применить")) { client.applyStash(selected, pop: false) }
                        Button(L("Достать")) { client.applyStash(selected, pop: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(client.busy != nil)
                    .padding(10)
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)

            HSplitView {
                List(selection: $selectedFile) {
                    ForEach(files) { file in
                        ChangedFileRow(letter: file.kind.letter, color: ChangeBadge.color(file.kind),
                                       name: file.fileName, directory: file.directory)
                            .tag(file.path)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 400)
                PatchView(patch: selectedFile == nil ? GitFilePatch() : patch)
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
        }
        .onChange(of: selection) { _, _ in loadFiles() }
        .onChange(of: selectedFile) { _, _ in loadPatch() }
        .confirmationDialog(L("Удалить спрятанное?"), isPresented: Binding(get: { confirmDrop != nil },
                                                                          set: { if !$0 { confirmDrop = nil } }),
                            presenting: confirmDrop) { stash in
            Button(L("Удалить"), role: .destructive) { client.dropStash(stash) }
        } message: { stash in
            Text(stash.message)
        }
    }

    private func save() {
        client.stash(message: message, includeUntracked: includeUntracked)
        message = ""
    }

    private func loadFiles() {
        files = []
        selectedFile = nil
        guard let repository = client.repository, let stash = selected else { return }
        Task {
            let result = await Task.detached {
                Git.run(["stash", "show", "--name-status", "-z", "-M", "--include-untracked", stash.ref], in: repository)
                    .map { GitChangedFile.parse($0.stdout) } ?? []
            }.value
            guard selection == stash.id else { return }
            files = result
            selectedFile = result.first?.path
        }
    }

    private func loadPatch() {
        patch = nil
        guard let repository, let stash = selected, let path = selectedFile else { return }
        Task {
            let result = await Task.detached {
                // Новый файл в stash лежит в третьем родителе (^3), остальные — против первого.
                var output = Git.run(["diff", "--no-color", "--no-ext-diff", "-U3", "\(stash.ref)^1", stash.ref, "--", path],
                                     in: repository)
                if output.map({ $0.stdout.isEmpty }) ?? true {
                    output = Git.run(["show", "--format=", "--no-color", "-U3", "\(stash.ref)^3", "--", path], in: repository)
                }
                return output.map { GitFilePatch.parse(String(decoding: $0.stdout, as: UTF8.self)) }
            }.value
            guard selectedFile == path else { return }
            patch = result
        }
    }

    private var repository: URL? { client.repository }
}

// MARK: - Журнал

/// Что Pilot делал с репозиторием: команды, коды, вывод — в том числе
/// хуков коммита.
struct GitJournalView: View {
    @ObservedObject var client: GitClient
    @State private var selection: Int?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(client.journal.reversed()) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(Color(nsColor: entry.succeeded ? Theme.gitAdded : Theme.diagnosticError))
                        Text(entry.command)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.2f s", entry.duration))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .tag(entry.id)
                }
            }
            .frame(minWidth: 420)
            .overlay {
                if client.journal.isEmpty {
                    Text(L("Pilot ещё ничего не менял в этом репозитории")).foregroundStyle(.tertiary)
                }
            }
            ScrollView {
                if let entry = client.journal.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Text(L("Код выхода: \(entry.status)")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(entry.output.isEmpty ? L("(без вывода)") : entry.output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                } else {
                    Text(L("Выберите команду")).foregroundStyle(.tertiary).padding()
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity)
        }
    }
}
