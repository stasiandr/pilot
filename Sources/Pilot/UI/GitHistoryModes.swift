import SwiftUI
import AppKit

/// «Моя ветка»: что в ней сверх основной, что уже на сервере, откуда она
/// отошла и насколько основная ушла вперёд. Остальная история не нужна,
/// чтобы ответить на главный вопрос — что будет в моём MR.
struct MineHistoryList: View {
    let workspace: Workspace
    @ObservedObject var history: GitHistoryModel
    @ObservedObject var client: GitClient
    @ObservedObject var commits: GitCommitService

    var body: some View {
        if let overview = history.overview {
            VStack(spacing: 0) {
                header(overview)
                Divider()
                list(overview)
            }
        } else if let error = history.error {
            Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ overview: GitHistoryModel.BranchOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                Text(overview.branch ?? L("HEAD отсоединён")).font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if !overview.onMain, overview.behind > 0 {
                    Button(L("Влить \(overview.mainName)")) { client.merge(overview.mainRef) }
                        .help(L("Догнать основную ветку слиянием"))
                    Button(L("Перенести на \(overview.mainName)")) { client.rebase(onto: overview.mainRef) }
                        .help(L("Rebase — только если коммиты ветки ещё не отправлены"))
                }
            }
            Text(summary(overview))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .disabled(client.busy != nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func summary(_ overview: GitHistoryModel.BranchOverview) -> String {
        let unpushed = overview.commits.filter { overview.unpushed.contains($0.hash) }.count
        var parts: [String] = []
        if overview.onMain {
            parts.append(L("Основная ветка"))
            parts.append(unpushed > 0 ? L("не отправлено: \(unpushed)") : L("всё отправлено"))
        } else {
            let own = overview.commits.filter { !$0.isBackMerge(main: overview.mainRef) }.count
            parts.append(L("своих коммитов: \(own)"))
            if unpushed > 0 { parts.append(L("не отправлено: \(unpushed)")) }
            if let fork = overview.forkPoint {
                parts.append(L("от \(overview.mainName) \(fork.date.formatted(.relative(presentation: .named)))"))
            }
            parts.append(overview.behind > 0 ? L("\(overview.mainName) ушла вперёд на \(overview.behind)")
                                             : L("\(overview.mainName) не ушла вперёд"))
        }
        return parts.joined(separator: " · ")
    }

    private func list(_ overview: GitHistoryModel.BranchOverview) -> some View {
        List(selection: $history.selection) {
            if !commits.tree.changes.isEmpty {
                Button { client.windowTab = .commit } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil.circle").foregroundStyle(Color(nsColor: Theme.gitModified))
                            .frame(width: 18)
                        Text(L("Незакоммиченные изменения: \(commits.tree.changes.count)"))
                        Spacer()
                        Text(L("к коммиту →")).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            }
            Section {
                if overview.commits.isEmpty {
                    Text(overview.onMain ? L("Неотправленных коммитов нет")
                                         : L("Своих коммитов нет — ветка совпадает с \(overview.mainName)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
                ForEach(overview.commits) { commit in
                    MineCommitRow(commit: commit, unpushed: overview.unpushed.contains(commit.hash),
                                  backMerge: commit.isBackMerge(main: overview.mainRef), mainName: overview.mainName)
                        .tag(commit.hash)
                        .contextMenu { CommitMenu(workspace: workspace, history: history, client: client, commit: commit) }
                }
                if let fork = overview.forkPoint, !overview.onMain {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.left.up").foregroundStyle(.secondary).frame(width: 18)
                        Text(L("отходит от \(overview.mainName):")).foregroundStyle(.secondary)
                        Text(fork.subject).lineLimit(1)
                        Spacer()
                        Text(fork.shortHash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12))
                    .tag(fork.hash)
                }
            }
            if !overview.others.isEmpty {
                Section(L("Другие мои ветки")) {
                    ForEach(overview.others) { branch in
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 18)
                            Text(branch.name).lineLimit(1).truncationMode(.middle)
                            if branch.ahead > 0 {
                                Text("↑\(branch.ahead)").foregroundStyle(Color(nsColor: Theme.gitAdded))
                                    .help(L("Коммитов сверх \(overview.mainName)"))
                            }
                            if branch.behind > 0 {
                                Text("↓\(branch.behind)").foregroundStyle(.tertiary)
                                    .help(L("На сколько \(overview.mainName) ушла вперёд"))
                            }
                            Spacer()
                            Text(branch.date.formatted(.relative(presentation: .named)))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                        .selectionDisabled()
                        .onTapGesture(count: 2) { checkout(branch.name) }
                        .contextMenu {
                            Button(L("Переключиться")) { checkout(branch.name) }
                            Button(L("Сравнить с \(overview.mainName)")) {
                                history.comparison = GitHistoryModel.Comparison(base: overview.mainRef, target: branch.name)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func checkout(_ name: String) {
        if let branch = client.localBranches.first(where: { $0.name == name }) { client.checkout(branch) }
    }
}

private struct MineCommitRow: View {
    let commit: GitCommitInfo
    let unpushed: Bool
    let backMerge: Bool
    let mainName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: backMerge ? "arrow.down.right.circle" : unpushed ? "arrow.up.circle.fill" : "checkmark.circle")
                .foregroundStyle(backMerge ? AnyShapeStyle(.tertiary)
                                 : unpushed ? AnyShapeStyle(Color(nsColor: Theme.gitAdded)) : AnyShapeStyle(.secondary))
                .frame(width: 18)
                .help(backMerge ? L("\(mainName) влита в ветку") : unpushed ? L("Ещё не на сервере") : L("Уже на сервере"))
            if backMerge {
                Text(L("влита \(mainName)")).foregroundStyle(.tertiary)
            } else {
                Text(commit.subject).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(commit.author).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .trailing)
            Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
            Text(commit.shortHash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).fixedSize()
        }
        .font(.system(size: 12))
    }
}

/// «По MR»: основная ветка по первому родителю — каждое слияние MR одной
/// строкой (задача, заголовок, ветка, номер), раскрывается в свои коммиты
/// без обратных слияний. Коммиты прямо в основную — обычной строкой.
struct MainlineHistoryList: View {
    let workspace: Workspace
    @ObservedObject var history: GitHistoryModel
    @ObservedObject var client: GitClient

    var body: some View {
        List(selection: $history.selection) {
            ForEach(Array(history.mainline.enumerated()), id: \.element.id) { index, entry in
                MainlineRow(entry: entry, expanded: history.expanded.contains(entry.id),
                            toggle: { toggle(entry.id) },
                            openRequest: { workspace.openMergeRequest(iid: $0) })
                    .tag(entry.id)
                    .contextMenu { CommitMenu(workspace: workspace, history: history, client: client, commit: entry.commit) }
                    .onAppear { if index == history.mainline.count - 1 { history.loadMore() } }
                if history.expanded.contains(entry.id) {
                    if let children = history.children[entry.id] {
                        ForEach(children) { commit in
                            HStack(spacing: 8) {
                                Text(commit.subject).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(commit.author).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: 120, alignment: .trailing)
                                Text(commit.shortHash).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary).fixedSize()
                            }
                            .font(.system(size: 12))
                            .padding(.leading, 34)
                            .tag(commit.hash)
                            .contextMenu { CommitMenu(workspace: workspace, history: history, client: client, commit: commit) }
                        }
                        if let hidden = history.hiddenBackMerges[entry.id], hidden > 0 {
                            Text(L("обратных слияний скрыто: \(hidden)"))
                                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 34)
                                .selectionDisabled()
                        }
                    } else {
                        ProgressView().controlSize(.mini).padding(.leading, 34).selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if let error = history.error {
                Text(error).foregroundStyle(.secondary)
            } else if !history.isLoading && history.mainline.isEmpty {
                Text(L("Ничего не найдено")).foregroundStyle(.tertiary)
            }
        }
        // → и ← раскрывают и сворачивают выбранный MR, как в дереве.
        .onKeyPress(.rightArrow) { setExpanded(true) }
        .onKeyPress(.leftArrow) { setExpanded(false) }
    }

    private func toggle(_ id: String) {
        if history.expanded.contains(id) { history.expanded.remove(id) } else { history.expanded.insert(id) }
    }

    private func setExpanded(_ value: Bool) -> KeyPress.Result {
        guard let id = history.selection, history.mainline.contains(where: { $0.id == id && $0.commit.isMerge }) else {
            return .ignored
        }
        if value { history.expanded.insert(id) } else { history.expanded.remove(id) }
        return .handled
    }
}

private struct MainlineRow: View {
    let entry: GitHistoryModel.MainlineEntry
    let expanded: Bool
    let toggle: () -> Void
    let openRequest: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if entry.commit.isMerge {
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary).frame(width: 14)
            }
            if let task = entry.request?.task {
                Text(task)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let request = entry.request {
                    Text(request.branch).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let iid = entry.request?.iid {
                Button { openRequest(iid) } label: { Text(verbatim: "!\(iid)") }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .help(L("Открыть MR в ревью"))
            }
            Text(entry.commit.author).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .trailing)
            Text(entry.commit.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
        }
        .font(.system(size: 12))
        .padding(.vertical, 1)
    }

    /// Заголовок MR; без него — тема коммита (прямой коммит в основную).
    private var title: String {
        guard let request = entry.request else { return entry.commit.subject }
        guard var title = request.title else { return request.branch }
        // «OST-21643 - Фракции…» — ключ уже на метке, в заголовке он лишний.
        if let task = request.task, title.hasPrefix(task) {
            title = String(title.dropFirst(task.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -:—"))
        }
        return title.isEmpty ? request.branch : title
    }
}

/// Действия с коммитом — одинаковые во всех режимах истории.
struct CommitMenu: View {
    let workspace: Workspace
    @ObservedObject var history: GitHistoryModel
    @ObservedObject var client: GitClient
    let commit: GitCommitInfo

    var body: some View {
        Button(L("Копировать хэш")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.hash, forType: .string)
        }
        Divider()
        Button(L("Новая ветка отсюда…")) { history.newBranchFrom = commit }
        Button(L("Сравнить с текущим состоянием")) {
            history.comparison = GitHistoryModel.Comparison(base: commit.hash, target: "HEAD")
        }
        Divider()
        Button("Cherry-pick") { client.cherryPick(commit) }
            .disabled(commit.isMerge)
        // Revert слияния не предлагаем: во многих командах он запрещён, и
        // после него ветку нельзя влить повторно.
        if !commit.isMerge {
            Button(L("Revert — отменить новым коммитом…")) { history.confirmRevert = commit }
        }
        Divider()
        Button(L("Интерактивный rebase отсюда…")) { history.rebaseBase = commit }
        Menu(L("Сдвинуть ветку сюда")) {
            Button(L("Soft — правки подготовлены")) { client.reset(to: commit, mode: .soft) }
            Button(L("Mixed — правки в рабочей копии")) { client.reset(to: commit, mode: .mixed) }
        }
    }
}
