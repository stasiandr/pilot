import SwiftUI
import AppKit

/// Вкладка навигатора «Изменения»: коммит, не уходя из редактора. Файл —
/// кликом в редактор, где изменённые блоки подготавливаются и
/// откатываются прямо с колонки номеров; галочка — весь файл; внизу —
/// сообщение и коммит. Дифф по кускам и строкам — в окне git (⌘K).
struct ChangesNavigator: View {
    let workspace: Workspace
    @ObservedObject var commits: GitCommitService
    @FocusState private var messageFocused: Bool
    @State private var selection: String?

    var body: some View {
        if commits.repository == nil {
            Text(L("Проект не в git-репозитории"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                list
                Divider()
                CommitComposer(commits: commits, messageFocused: $messageFocused, height: 64, compact: true)
                    .padding(10)
            }
            .onAppear { commits.refresh() }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if !commits.tree.staged.isEmpty {
                Section {
                    ForEach(commits.tree.staged) { change in row(change, staged: true) }
                } header: {
                    header(L("Подготовлено"), count: commits.tree.staged.count, action: L("Убрать все")) { commits.unstageAll() }
                }
            }
            Section {
                ForEach(commits.tree.unstaged) { change in row(change, staged: false) }
            } header: {
                header(L("Изменения"), count: commits.tree.unstaged.count,
                       action: commits.tree.unstaged.isEmpty ? nil : L("Подготовить все")) { commits.stageAll() }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
        .onChange(of: selection) { _, id in
            guard let id else { return }
            let path = String(id.dropLast(2))
            if let change = commits.tree.changes.first(where: { $0.path == path }) { open(change) }
        }
        .onKeyPress(.space) {
            guard let id = selection else { return .ignored }
            let staged = id.hasSuffix("#s")
            let path = String(id.dropLast(2))
            staged ? commits.unstage([path]) : commits.stage([path])
            return .handled
        }
        .overlay {
            if commits.isLoaded && commits.tree.changes.isEmpty {
                Text(L("Рабочая копия чистая")).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
    }

    private func header(_ title: String, count: Int, action: String?, perform: @escaping () -> Void) -> some View {
        HStack {
            Text("\(title) \(count)")
            Spacer()
            if let action {
                Button(action, action: perform).buttonStyle(.borderless).font(.system(size: 10))
            }
        }
    }

    private func row(_ change: GitChange, staged: Bool) -> some View {
        HStack(spacing: 5) {
            Button {
                staged ? commits.unstage([change.path]) : commits.stage([change.path])
            } label: {
                Image(systemName: staged ? "checkmark.square.fill" : "square")
                    .foregroundStyle(staged ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(change.isConflicted)
            let kind = staged ? change.staged : change.unstaged
            ChangedFileRow(letter: change.isConflicted ? "U" : change.isUntracked ? "?" : (kind?.letter ?? "M"),
                           color: change.isConflicted ? Theme.gitConflicted : change.isUntracked ? Theme.gitAdded : ChangeBadge.color(kind),
                           name: change.fileName, directory: change.directory)
        }
        .font(.system(size: 12))
        .tag("\(change.path)#\(staged ? "s" : "u")")
        .contextMenu {
            if change.isConflicted {
                Button(L("Разрешить конфликт…")) { workspace.openMerge(path: change.path) }
            } else if staged {
                Button(L("Убрать из коммита")) { commits.unstage([change.path]) }
            } else {
                Button(L("Подготовить к коммиту")) { commits.stage([change.path]) }
            }
            Button(L("Дифф в окне git")) {
                commits.selection = GitCommitService.Selection(path: change.path, staged: staged)
                workspace.openGitWindow(tab: .commit)
            }
            Button(L("История файла")) { workspace.showHistory(path: change.path) }
                .disabled(change.isUntracked)
        }
    }

    private func open(_ change: GitChange) {
        guard let repository = commits.repository else { return }
        if change.isConflicted {
            workspace.openMerge(path: change.path)
            return
        }
        guard change.staged != .deleted, change.unstaged != .deleted else { return }
        workspace.navigate(to: NavTarget(url: repository.appendingPathComponent(change.path), range: nil), preview: true)
    }
}
