import SwiftUI
import AppKit

/// Окно коммита проекта, как Commit в Rider: слева подготовленное и нет,
/// под ними — сообщение; справа — дифф выбранного файла, куски которого
/// подготавливаются по одному.
struct CommitWindow: View {
    static let sceneID = "commit"

    let rootPath: String?
    @ObservedObject private var language = LanguageStore.shared

    var body: some View {
        Group {
            if let workspace = ProjectWindows.shared.workspaces.first(where: { $0.root?.path == rootPath }) {
                CommitView(workspace: workspace, commits: workspace.commits)
                    .navigationTitle(L("Коммит — \(workspace.root?.lastPathComponent ?? "")"))
            } else {
                Text(L("Проект этого окна закрыт"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(L("Коммит"))
            }
        }
        .id(language.current)
        .frame(minWidth: 900, minHeight: 540)
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
    }
}

struct CommitView: View {
    let workspace: Workspace
    @ObservedObject var commits: GitCommitService
    @Environment(\.dismiss) private var dismiss
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
            DiffPane(commits: commits)
                .frame(minWidth: 480, maxWidth: .infinity)
        }
        .background(Color(nsColor: Theme.editorBackground))
        .onAppear {
            commits.refresh()
            messageFocused = true
        }
        // Вернулись из терминала — там могли закоммитить или переключить ветку.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            commits.refresh()
        }
        .background {
            Button("") { dismiss() }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
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
                    .disabled(commits.busy != nil)
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
                .disabled(!enabled || commits.busy != nil)
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
            .disabled(commits.busy != nil)
            Text(letter(change, staged: staged))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: color(change, staged: staged)))
                .frame(width: 12)
            Text(change.fileName).lineLimit(1)
            Text(change.directory)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .tag(selection)
        .contextMenu {
            if staged {
                Button(L("Убрать из коммита")) { commits.unstage([change.path]) }
            } else {
                Button(L("Подготовить к коммиту")) { commits.stage([change.path]) }
                if !change.isConflicted {
                    Button(L("Откатить правки…")) { confirmDiscard = change }
                }
            }
            Divider()
            Button(L("Открыть в редакторе")) { open(change) }
                .disabled(change.staged == .deleted || change.unstaged == .deleted)
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
        switch staged ? change.staged : change.unstaged {
        case .added: return Theme.gitAdded
        case .deleted: return Theme.gitDeleted
        case .renamed: return Theme.gitRenamed
        default: return Theme.gitModified
        }
    }

    private func open(_ change: GitChange) {
        guard let repository = commits.repository else { return }
        workspace.open(file: repository.appendingPathComponent(change.path))
        workspace.bringToFront()
    }

    // MARK: - Сообщение

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $commits.message)
                    .font(.system(size: 12))
                    .focused($messageFocused)
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
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.chromeBackground)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Theme.separator)))

            HStack {
                Toggle(L("Изменить последний коммит"), isOn: $commits.amend)
                    .toggleStyle(.checkbox)
                    .disabled(commits.tree.head == nil || commits.busy != nil)
                Spacer()
                let length = CommitMessage.summary(commits.message).count
                if length > CommitMessage.summaryLimit {
                    Text("\(length)/\(CommitMessage.summaryLimit)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
                        .help(L("Первая строка длиннее, чем удобно читать в git log"))
                }
            }

            HStack {
                Button(L("Закоммитить и отправить")) { commits.commit(andPush: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(!commits.canCommit)
                Spacer()
                Button(commits.amend ? L("Изменить коммит") : L("Закоммитить")) { commits.commit(andPush: false) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!commits.canCommit)
            }

            status
        }
        .padding(12)
    }

    @ViewBuilder
    private var status: some View {
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

private struct DiffPane: View {
    @ObservedObject var commits: GitCommitService

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
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                Divider()
                content(selection)
            }
        } else {
            Text(L("Выберите файл"))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ selection: GitCommitService.Selection) -> some View {
        if let text = commits.untrackedText {
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
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(patch.hunks) { hunk in
                            HunkCard(hunk: hunk, staged: selection.staged, busy: commits.busy != nil) {
                                commits.toggle(hunk)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HunkCard: View {
    let hunk: GitFilePatch.Hunk
    let staged: Bool
    let busy: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.header)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("+\(hunk.additions) −\(hunk.deletions)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button(staged ? L("Убрать кусок") : L("Подготовить кусок"), action: toggle)
                    .controlSize(.small)
                    .disabled(busy)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: Theme.chromeBackground))
            ForEach(Array(numbered.enumerated()), id: \.offset) { _, item in
                DiffLine(text: item.text, number: item.number)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Theme.separator)))
    }

    /// Номера строк нового текста — у удалённых строк номера нет.
    private var numbered: [(text: String, number: Int?)] {
        var line = hunk.newStart
        return hunk.lines.map { text in
            if text.hasPrefix("-") || text.hasPrefix("\\") { return (text, nil) }
            defer { line += 1 }
            return (text, line)
        }
    }
}

private struct DiffLine: View {
    let text: String
    let number: Int?

    var body: some View {
        let marker = text.first
        HStack(alignment: .top, spacing: 6) {
            Text(number.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(marker == "\\" ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(background(marker))
    }

    private func background(_ marker: Character?) -> Color {
        switch marker {
        case "+": return Color(nsColor: Theme.gitAdded).opacity(0.14)
        case "-": return Color(nsColor: Theme.gitDeleted).opacity(0.14)
        default: return .clear
        }
    }
}
