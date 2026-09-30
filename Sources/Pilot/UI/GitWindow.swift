import SwiftUI
import AppKit

/// Панель git под редактором, как панель Git в Rider: вкладки «Коммит»,
/// «Лог» (слева ветки, дальше история, файлы и дифф), «Stash» и
/// «Консоль» — команды, которые выполнил Pilot. Высоту тянут за верхний
/// край, как консоль запуска.
struct GitPanel: View {
    let workspace: Workspace
    @ObservedObject var client: GitClient
    @AppStorage("pilot.gitPanelHeight") private var height: Double = 340
    @State private var dragStart: Double?
    /// Без окна (`--render-git`) высота задаётся снаружи.
    var fixedHeight: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            GitOperationBar(workspace: workspace, client: client)
            if let tuning = client.tuning, !tuning.isComplete {
                TuningBanner(client: client, state: tuning)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: fixedHeight ?? height)
        .background(Color(nsColor: Theme.swiftUIEditorBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
        .overlay(alignment: .top) { resizeHandle }
        .onAppear {
            client.refresh()
            if client.windowTab == .history { workspace.gitHistory.open(repository: client.repository) }
        }
        .onChange(of: client.windowTab) { _, tab in
            if tab == .history { workspace.gitHistory.open(repository: client.repository) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            client.refresh()
            client.refreshOperation()
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

    private var header: some View {
        HStack(spacing: 4) {
            Text("Git").font(.system(size: 12, weight: .semibold)).padding(.trailing, 6)
            ForEach(GitWindowTab.allCases, id: \.self) { tab in
                let selected = client.windowTab == tab
                Button { client.windowTab = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 12))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(selected ? Color.accentColor.opacity(0.22) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(selected ? Color.accentColor.opacity(0.6) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 12)
            // Что делается и чем кончилось — в шапке, одной строкой: строка
            // снизу появлялась и пропадала и дёргала всю панель.
            GitClientStatus(client: client, compact: true)
            Button { client.fetch() } label: { Image(systemName: "arrow.down.circle") }
                .help(L("Получить с сервера") + " — git fetch --all --prune")
            Button { client.pull() } label: { Image(systemName: "arrow.down.to.line") }
                .help(KeymapStore.shared.help(L("Обновить ветку (pull)"), .pull))
            Button { client.push() } label: { Image(systemName: "arrow.up.circle") }
                .help(KeymapStore.shared.help(L("Отправить (push)"), .push))
            Divider().frame(height: 14).padding(.horizontal, 4)
            Button { workspace.showsGitPanel = false } label: { Image(systemName: "xmark") }
                .help(KeymapStore.shared.help(L("Скрыть панель git"), .gitLog))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    /// Коммит и лог не пересоздаются при переключении вкладок — только
    /// прячутся: иначе разделители колонок возвращались бы на место, а
    /// списки мигали бы пустыми, пока git отвечает заново.
    private var content: some View {
        ZStack {
            CommitView(workspace: workspace, commits: workspace.commits)
                .opacity(client.windowTab == .commit ? 1 : 0)
                .allowsHitTesting(client.windowTab == .commit)
                .accessibilityHidden(client.windowTab != .commit)
            HSplitView {
                GitBranchTree(workspace: workspace, client: client, history: workspace.gitHistory)
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 320)
                GitHistoryView(workspace: workspace, history: workspace.gitHistory, client: client)
                    .frame(minWidth: 600, maxWidth: .infinity)
            }
            .opacity(client.windowTab == .history ? 1 : 0)
            .allowsHitTesting(client.windowTab == .history)
            .accessibilityHidden(client.windowTab != .history)
            switch client.windowTab {
            case .stash: GitStashView(client: client)
            case .journal: GitJournalView(client: client)
            case .commit, .history: EmptyView()
            }
        }
    }

    /// Полоска у верхнего края: тянешь — панель выше, редактор ниже.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? height
                    dragStart = start
                    height = min(max(start - value.translation.height, 140), 1200)
                }
                .onEnded { _ in dragStart = nil })
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
            // Одной строкой: панель низкая, а баннер — не главное в ней.
            HStack(spacing: 8) {
                Image(systemName: "hare").foregroundStyle(Color.accentColor)
                Text(L("Большой репозиторий")).fontWeight(.medium)
                Text(L("Включить fsmonitor, кэш неотслеживаемых, split index и commit-graph: git status и запись индекса станут в разы быстрее и в терминале."))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(L("Включить fsmonitor, кэш неотслеживаемых, split index и commit-graph: git status и запись индекса станут в разы быстрее и в терминале."))
                Spacer(minLength: 8)
                Button(L("Не сейчас")) { dismissed = client.repository?.path ?? "" }
                    .buttonStyle(.borderless)
                Button(L("Ускорить")) { client.enableTuning() }
                    .controlSize(.small)
                    .disabled(client.busy != nil)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Color.accentColor.opacity(0.08))
        }
    }
}

struct GitClientStatus: View {
    @ObservedObject var client: GitClient
    /// Одной строкой в шапке панели: длинная ошибка — в подсказке и в консоли.
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            if let busy = client.busy {
                ProgressView().controlSize(.mini)
                Text(busy).foregroundStyle(.secondary).lineLimit(1)
            } else if let error = client.error {
                Image(systemName: "xmark.octagon").foregroundStyle(Color(nsColor: Theme.diagnosticError))
                Text(compact ? error.replacingOccurrences(of: "\n", with: " ") : error)
                    .font(.system(size: 11, design: compact ? .default : .monospaced))
                    .foregroundStyle(Color(nsColor: Theme.diagnosticError))
                    .textSelection(.enabled)
                    .lineLimit(compact ? 1 : 4)
                    .truncationMode(.tail)
                    .help(error)
                Button(L("Консоль")) { client.windowTab = .journal }.controlSize(.small)
                Button { client.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            } else if let notice = client.notice {
                Image(systemName: "checkmark.circle").foregroundStyle(Color(nsColor: Theme.gitAdded))
                Text(notice).foregroundStyle(.secondary).lineLimit(1)
            }
            if !compact { Spacer(minLength: 0) }
        }
        .font(.system(size: 11))
        .padding(.horizontal, compact ? 0 : 12)
        .padding(.vertical, compact ? 0 : 6)
        .frame(maxWidth: compact ? 520 : nil, alignment: .trailing)
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
                Group {
                    if let path = selectedFile, MediaKind(filename: path) != nil, let repository, let stash = selected {
                        MediaCompareView(repository: repository, path: path,
                                         before: .init(title: L("До"), revision: .commit(stash.ref + "^1")),
                                         after: .init(title: stash.ref, revision: .commit(stash.ref)))
                    } else {
                        PatchView(patch: selectedFile == nil ? GitFilePatch() : patch)
                    }
                }
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
