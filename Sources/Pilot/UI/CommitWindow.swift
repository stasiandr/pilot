import SwiftUI
import AppKit

/// Вкладка «Коммит» панели git: слева подготовленное и нет, под ними —
/// сообщение; справа — дифф выбранного файла, куски и строки которого
/// подготавливаются по одному.
struct CommitView: View {
    let workspace: Workspace
    @ObservedObject var commits: GitCommitService
    @FocusState private var messageFocused: Bool
    @State private var confirmDiscard: GitChange?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                branchBar
                Divider()
                fileList
                Divider()
                composer
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 560)
            CommitDiffPane(commits: commits, resolve: { workspace.openMerge(path: $0) })
                .frame(minWidth: 480, maxWidth: .infinity)
        }
        .onAppear {
            commits.refresh()
            messageFocused = true
        }
        // Вернулись из терминала — там могли закоммитить или переключить ветку.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            commits.refresh()
        }
        .confirmationDialog(L("Откатить правки в «\(confirmDiscard?.fileName ?? "")»?"),
                            isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                            presenting: confirmDiscard) { change in
            Button(change.isUntracked ? L("В Корзину") : L("Откатить"), role: .destructive) { commits.discard(change) }
        } message: { change in
            Text(change.isUntracked
                 ? L("Новый файл уйдёт в Корзину.")
                 : L("Неподготовленные правки пропадут; текущий текст останется в локальной истории (⌃⌥H)."))
        }
    }

    // MARK: - Ветка

    private var branchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text(commits.tree.branch ?? commits.tree.head.map { String($0.prefix(7)) } ?? L("без коммитов"))
                .fontWeight(.medium)
                .lineLimit(1)
            if commits.tree.ahead > 0 {
                Text("↑\(commits.tree.ahead)").foregroundStyle(Color(nsColor: Theme.gitAdded))
                    .help(L("Коммитов, которых нет на сервере"))
            }
            if commits.tree.behind > 0 {
                Text("↓\(commits.tree.behind)").foregroundStyle(Color(nsColor: Theme.gitModified))
                    .help(L("Коммитов на сервере, которых нет здесь"))
            }
            Spacer()
            if commits.tree.ahead > 0 || (commits.tree.upstream == nil && commits.tree.branch != nil && commits.tree.head != nil) {
                Button(L("Отправить коммиты")) { commits.push() }
                    .disabled(commits.isCommitting)
                    .help(commits.tree.upstream == nil ? L("Создать ветку на сервере и отправить") : "git push")
            }
            Button { commits.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L("Обновить"))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    // MARK: - Файлы

    private var fileList: some View {
        List(selection: $commits.selection) {
            Section {
                ForEach(commits.tree.staged) { change in
                    row(change, staged: true)
                }
            } header: {
                sectionHeader(L("Подготовлено"), count: commits.tree.staged.count,
                              action: L("Убрать все"), enabled: !commits.tree.staged.isEmpty) { commits.unstageAll() }
            }
            Section {
                ForEach(commits.tree.unstaged) { change in
                    row(change, staged: false)
                }
            } header: {
                sectionHeader(L("Изменения"), count: commits.tree.unstaged.count,
                              action: L("Подготовить все"), enabled: !commits.tree.unstaged.isEmpty) { commits.stageAll() }
            }
        }
        .listStyle(.sidebar)
        // Пробел — подготовить или убрать выбранный файл, как в Rider.
        .onKeyPress(.space) {
            guard let selection = commits.selection else { return .ignored }
            selection.staged ? commits.unstage([selection.path]) : commits.stage([selection.path])
            return .handled
        }
        .overlay {
            if commits.isLoaded && commits.tree.changes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                    Text(L("Рабочая копия чистая")).foregroundStyle(.secondary)
                }
            } else if !commits.isLoaded {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, action: String, enabled: Bool,
                               perform: @escaping () -> Void) -> some View {
        HStack {
            Text("\(title) \(count)")
            Spacer()
            Button(action, action: perform)
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(!enabled)
        }
    }

    private func row(_ change: GitChange, staged: Bool) -> some View {
        let selection = GitCommitService.Selection(path: change.path, staged: staged)
        return HStack(spacing: 6) {
            Button {
                staged ? commits.unstage([change.path]) : commits.stage([change.path])
            } label: {
                Image(systemName: staged ? "checkmark.square.fill" : "square")
                    .foregroundStyle(staged ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(staged ? L("Убрать из коммита") : L("Подготовить к коммиту"))
            .disabled(change.isConflicted)
            ChangedFileRow(letter: letter(change, staged: staged), color: color(change, staged: staged),
                           name: change.fileName, directory: change.directory)
        }
        .tag(selection)
        .contextMenu {
            if staged {
                Button(L("Убрать из коммита")) { commits.unstage([change.path]) }
            } else if change.isConflicted {
                Button(L("Разрешить конфликт…")) { workspace.openMerge(path: change.path) }
            } else {
                Button(L("Подготовить к коммиту")) { commits.stage([change.path]) }
                Button(L("Откатить правки…")) { confirmDiscard = change }
            }
            Divider()
            Button(L("Открыть в редакторе")) { open(change) }
                .disabled(change.staged == .deleted || change.unstaged == .deleted)
            Button(L("История файла")) { workspace.showHistory(path: change.path) }
                .disabled(change.isUntracked)
            Button(L("Показать в Finder")) {
                if let repository = commits.repository {
                    NSWorkspace.shared.activateFileViewerSelecting([repository.appendingPathComponent(change.path)])
                }
            }
        }
    }

    private func letter(_ change: GitChange, staged: Bool) -> String {
        if change.isConflicted { return "U" }
        if change.isUntracked { return "?" }
        return (staged ? change.staged : change.unstaged)?.letter ?? "M"
    }

    private func color(_ change: GitChange, staged: Bool) -> NSColor {
        if change.isConflicted { return Theme.gitConflicted }
        if change.isUntracked { return Theme.gitAdded }
        return ChangeBadge.color(staged ? change.staged : change.unstaged)
    }

    private func open(_ change: GitChange) {
        guard let repository = commits.repository else { return }
        workspace.open(file: repository.appendingPathComponent(change.path))
        workspace.bringToFront()
    }

    // MARK: - Сообщение

    private var composer: some View {
        // Панель низкая: поле — на три строки, список файлов важнее.
        CommitComposer(commits: commits, messageFocused: $messageFocused, height: 56, compact: true)
            .padding(10)
    }
}

/// Сообщение и кнопки коммита. Общее у окна и вкладки навигатора.
struct CommitComposer: View {
    @ObservedObject var commits: GitCommitService
    var messageFocused: FocusState<Bool>.Binding
    var height: CGFloat
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $commits.message)
                    .font(.system(size: 12))
                    .focused(messageFocused)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if commits.message.isEmpty {
                    Text(L("Сообщение коммита"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.chromeBackground)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Theme.separator)))

            HStack {
                Toggle(compact ? L("Amend") : L("Изменить последний коммит"), isOn: $commits.amend)
                    .toggleStyle(.checkbox)
                    .disabled(commits.tree.head == nil || commits.isCommitting)
                    .help(L("Изменить последний коммит"))
                Spacer()
                let length = CommitMessage.summary(commits.message).count
                if length > CommitMessage.summaryLimit {
                    Text("\(length)/\(CommitMessage.summaryLimit)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
                        .help(L("Первая строка длиннее, чем удобно читать в git log"))
                }
            }

            metaWarnings

            HStack {
                Menu {
                    Button(L("Закоммитить и отправить")) { commits.commit(andPush: true) }
                        .keyboardShortcut(.return, modifiers: [.command, .option])
                        .disabled(!commits.canCommit)
                    Divider()
                    fixupMenu
                } label: {
                    Text(compact ? "…" : L("Ещё"))
                }
                .fixedSize()
                .onAppear { commits.loadRecentCommits() }
                Spacer()
                Button(commitTitle) { commits.commit(andPush: false) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!commits.canCommit)
                    .help(commits.commitsEverything
                          ? L("Ничего не подготовлено — в коммит пойдут все изменения")
                          : L("В коммит пойдёт подготовленное"))
            }

            status
        }
    }

    private var commitTitle: String {
        if commits.amend { return L("Изменить коммит") }
        if commits.commitsEverything, !commits.tree.unstaged.isEmpty {
            return L("Закоммитить всё (\(commits.tree.unstaged.count))")
        }
        return L("Закоммитить")
    }

    /// Fixup — в коммит, которого ещё нет на сервере. Со вливанием —
    /// сразу переписать ветку (`rebase --autosquash`).
    @ViewBuilder
    private var fixupMenu: some View {
        if commits.tree.staged.isEmpty {
            Text(L("Fixup: сначала подготовьте правки"))
        } else if commits.recentCommits.isEmpty {
            Text(L("Fixup: нет неотправленных коммитов"))
        } else {
            Menu(L("Fixup в коммит")) {
                ForEach(commits.recentCommits.prefix(15)) { commit in
                    Button("\(commit.shortHash)  \(commit.subject)") { commits.commit(andPush: false, fixup: commit) }
                }
            }
            Menu(L("Влить в коммит (fixup + autosquash)")) {
                ForEach(commits.recentCommits.prefix(15)) { commit in
                    Button("\(commit.shortHash)  \(commit.subject)") {
                        commits.commit(andPush: false, fixup: commit, autosquash: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var metaWarnings: some View {
        if !commits.metaProblems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(commits.metaProblems.prefix(4), id: \.self) { problem in
                    Label(problem.kind == .assetWithoutMeta
                          ? L("\((problem.path as NSString).lastPathComponent) — без своего .meta")
                          : L("\((problem.path as NSString).lastPathComponent) — .meta без ассета"),
                          systemImage: "exclamationmark.triangle")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if commits.metaProblems.count > 4 {
                    Text(L("… и ещё \(commits.metaProblems.count - 4)"))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
            .help(L("Ассет без .meta у коллег получит новый GUID, и ссылки на него порвутся; .meta без ассета Unity удалит"))
        }
    }

    /// Высота строки состояния постоянная: «Подготовка…» после каждого
    /// клика иначе сдвигала бы список файлов.
    private var status: some View {
        statusContent.frame(maxWidth: .infinity, minHeight: 16, maxHeight: 90, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: commits.error != nil)
    }

    @ViewBuilder
    private var statusContent: some View {
        if let busy = commits.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(busy).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        } else if let error = commits.error {
            ScrollView {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: Theme.diagnosticError))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
        } else if let notice = commits.notice {
            Label(notice, systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.gitAdded))
                .lineLimit(2)
        }
    }
}

// MARK: - Дифф

/// Дифф выбранного файла в окне коммита. Клавиши, как в Magit:
/// ↑↓ или j/k — между кусками, s — подготовить кусок или выбранные
/// строки, u — убрать, x — откатить, Esc — снять выбор строк.
struct CommitDiffPane: View {
    @ObservedObject var commits: GitCommitService
    /// Файл в конфликте — в окно слияния.
    var resolve: ((String) -> Void)? = nil
    @AppStorage(DiffLayout.key) private var layout = DiffLayout.unified
    @State private var focusedHunk = 0
    @FocusState private var focused: Bool
    @State private var confirmDiscard: GitFilePatch.Hunk?

    var body: some View {
        if let selection = commits.selection {
            VStack(spacing: 0) {
                HStack {
                    Text(selection.path)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    Spacer()
                    Text(selection.staged ? L("подготовлено") : L("не подготовлено"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    DiffLayoutPicker(layout: $layout)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                Divider()
                content(selection)
                if layout == .unified, commits.patch?.hunks.isEmpty == false,
                   commits.tree.changes.first(where: { $0.path == selection.path })?.isConflicted != true {
                    Divider()
                    Text(selection.staged
                         ? L("j/k — куски  ·  клик, ⇧клик — строки  ·  u — убрать из коммита")
                         : L("j/k — куски  ·  клик, ⇧клик — строки  ·  s — подготовить  ·  x — откатить"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(height: 22)
                }
            }
            .confirmationDialog(L("Откатить этот кусок?"),
                                isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                                presenting: confirmDiscard) { hunk in
                Button(L("Откатить"), role: .destructive) { commits.discard(hunk) }
            } message: { _ in
                Text(L("Правки пропадут из файла; прежний текст останется в локальной истории (⌃⌥H)."))
            }
        } else {
            Text(L("Выберите файл"))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ selection: GitCommitService.Selection) -> some View {
        if commits.tree.changes.first(where: { $0.path == selection.path })?.isConflicted == true {
            // Дифф конфликта — комбинированный (`@@@`): кусками его не
            // подготовить, решают его в окне слияния.
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                Text(L("Файл в конфликте")).foregroundStyle(.secondary)
                if let resolve {
                    Button(L("Слияние в три колонки…")) { resolve(selection.path) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text = commits.untrackedText {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(text.components(separatedBy: "\n").prefix(3000).enumerated()), id: \.offset) { i, line in
                        DiffLine(text: "+" + line, number: i + 1)
                    }
                }
                .padding(12)
            }
        } else if let patch = commits.patch {
            if patch.isBinary {
                placeholder(L("Двоичный файл — показать нечего"))
            } else if patch.hunks.isEmpty {
                placeholder(L("Отличий нет"))
            } else if layout == .sideBySide {
                SideBySideView(rows: SideBySideRow.rows(patch))
            } else {
                hunks(patch, staged: selection.staged)
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hunks(_ patch: GitFilePatch, staged: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(patch.hunks.enumerated()), id: \.element.id) { index, hunk in
                        HunkCard(hunk: hunk, selectedLines: commits.selectedLines[hunk.id] ?? [],
                                 focused: focused && index == focusedHunk,
                                 onLineClick: { line, extend in
                                     focusedHunk = index
                                     focused = true
                                     commits.toggleLine(line, in: hunk, extend: extend)
                                 }) {
                            let lines = commits.selectedLines[hunk.id]?.isEmpty == false
                            if !staged {
                                Button(lines ? L("Откатить строки") : L("Откатить")) { confirmDiscard = hunk }
                                    .controlSize(.small)
                            }
                            Button(staged ? (lines ? L("Убрать строки") : L("Убрать кусок"))
                                          : (lines ? L("Подготовить строки") : L("Подготовить кусок"))) {
                                commits.toggle(hunk)
                            }
                            .controlSize(.small)
                        }
                        .id(hunk.id)
                    }
                }
                .padding(12)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(characters: .init(charactersIn: "jksuxJK")) { press in
                handle(press.characters, patch: patch, staged: staged, proxy: proxy)
            }
            .onKeyPress(.downArrow) { handle("j", patch: patch, staged: staged, proxy: proxy) }
            .onKeyPress(.upArrow) { handle("k", patch: patch, staged: staged, proxy: proxy) }
            .onKeyPress(.escape) {
                commits.selectedLines = [:]
                return .handled
            }
            .onChange(of: patch.hunks.count) { _, count in focusedHunk = min(focusedHunk, max(0, count - 1)) }
        }
    }

    private func handle(_ key: String, patch: GitFilePatch, staged: Bool, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !patch.hunks.isEmpty else { return .ignored }
        let hunk = patch.hunks[min(focusedHunk, patch.hunks.count - 1)]
        switch key.lowercased() {
        case "j":
            focusedHunk = min(focusedHunk + 1, patch.hunks.count - 1)
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(patch.hunks[focusedHunk].id, anchor: .top) }
        case "k":
            focusedHunk = max(focusedHunk - 1, 0)
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(patch.hunks[focusedHunk].id, anchor: .top) }
        case "s":
            guard !staged else { return .ignored }
            commits.toggle(hunk)
        case "u":
            guard staged else { return .ignored }
            commits.toggle(hunk)
        case "x":
            guard !staged else { return .ignored }
            confirmDiscard = hunk
        default:
            return .ignored
        }
        return .handled
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
