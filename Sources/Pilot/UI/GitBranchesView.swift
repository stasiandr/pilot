import SwiftUI
import AppKit

/// Список веток с поиском: локальные, затем удалённые. Без запроса —
/// все локальные и последние удалённые; с запросом — подходящие по
/// словам (`feat ui` найдёт `feature/new-ui`).
struct BranchList<MenuContent: View>: View {
    @ObservedObject var client: GitClient
    let query: String
    @Binding var selection: String?
    let limit: Int
    let activate: (GitBranch) -> Void
    @ViewBuilder let menu: (GitBranch) -> MenuContent

    var body: some View {
        let (local, remote) = filtered
        List(selection: $selection) {
            Section(L("Локальные")) {
                ForEach(local) { branch in row(branch) }
            }
            if !remote.isEmpty {
                Section(query.isEmpty ? L("Удалённые — недавние") : L("Удалённые")) {
                    ForEach(remote) { branch in row(branch) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if client.branches.isEmpty { ProgressView().controlSize(.small) }
        }
    }

    private var filtered: ([GitBranch], [GitBranch]) {
        let words = query.lowercased().split(separator: " ").map(String.init)
        func matches(_ branch: GitBranch) -> Bool {
            let name = branch.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        // Текущая — первой, дальше по дате (for-each-ref уже отсортировал).
        let local = client.localBranches.filter(matches).sorted { $0.isCurrent && !$1.isCurrent }
        let localNames = Set(client.localBranches.map(\.name))
        let remote = client.remoteBranches.lazy
            .filter { !localNames.contains($0.localName) || !query.isEmpty }
            .filter(matches)
            .prefix(query.isEmpty ? 40 : limit)
        return (Array(local), Array(remote))
    }

    private func row(_ branch: GitBranch) -> some View {
        HStack(spacing: 6) {
            Image(systemName: branch.isCurrent ? "checkmark" : branch.isRemote ? "cloud" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
                .frame(width: 14)
            Text(branch.name)
                .fontWeight(branch.isCurrent ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            if branch.ahead > 0 {
                Text("↑\(branch.ahead)").foregroundStyle(Color(nsColor: Theme.gitAdded))
            }
            if branch.behind > 0 {
                Text("↓\(branch.behind)").foregroundStyle(Color(nsColor: Theme.gitModified))
            }
            if branch.upstreamGone {
                Text(L("на сервере удалена")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(branch.date.formatted(.relative(presentation: .named)))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .tag(branch.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { activate(branch) }
        .contextMenu { menu(branch) }
    }
}

/// Попап веток из статус-строки, как «Git Branches» в Rider: поиск сразу
/// в фокусе, Return — переключиться, имя, которого нет, — создать ветку.
struct BranchPopover: View {
    let workspace: Workspace
    @ObservedObject var client: GitClient
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(L("Ветка — найти или создать"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .padding(10)
            BranchList(client: client, query: query, selection: $selection, limit: 80) { branch in
                client.checkout(branch)
                dismiss()
            } menu: { branch in
                Button(L("Переключиться")) { client.checkout(branch); dismiss() }
                    .disabled(branch.isCurrent)
                Button(L("Влить в текущую")) { client.merge(branch.name); dismiss() }
                    .disabled(branch.isCurrent)
            }
            .frame(height: 320)
            Divider()
            HStack(spacing: 8) {
                if canCreate {
                    Button(L("Создать «\(query)»")) { client.createBranch(query); dismiss() }
                }
                Spacer()
                Button { client.fetch() } label: { Image(systemName: "arrow.down.circle") }
                    .help(L("Получить с сервера"))
                Button { client.pull(); dismiss() } label: { Image(systemName: "arrow.down.to.line") }
                    .help(L("Обновить ветку (pull)"))
                Button { client.push(); dismiss() } label: { Image(systemName: "arrow.up.circle") }
                    .help(L("Отправить (push)"))
                Button(L("Панель git…")) {
                    workspace.openGitPanel(tab: .history)
                    dismiss()
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(10)
            if client.busy != nil || client.error != nil {
                Divider()
                GitClientStatus(client: client)
            }
        }
        .frame(width: 420)
        .onAppear {
            client.refresh()
            focused = true
        }
    }

    private var canCreate: Bool {
        GitBranch.isValidName(query) && !client.branches.contains { $0.name == query || $0.localName == query }
    }

    private func submit() {
        if let selection, let branch = client.branches.first(where: { $0.id == selection }) {
            client.checkout(branch)
            dismiss()
            return
        }
        let words = query.lowercased().split(separator: " ").map(String.init)
        if let branch = client.branches.first(where: { branch in words.allSatisfy { branch.name.lowercased().contains($0) } }),
           !words.isEmpty {
            if !branch.isCurrent { client.checkout(branch) }
            dismiss()
        } else if canCreate {
            client.createBranch(query)
            dismiss()
        }
    }
}
