import SwiftUI
import AppKit

/// Ветки слева от лога, как в панели Git у Rider: поиск, HEAD, основная
/// ветка, локальные и удалённые — по папкам (`feature/…`, `fix/…`).
/// Клик — лог этой ветки, двойной клик — переключиться, правый — действия.
/// HEAD открывает «Мою ветку», основная — историю по MR.
struct GitBranchTree: View {
    let workspace: Workspace
    @ObservedObject var client: GitClient
    @ObservedObject var history: GitHistoryModel
    @State private var query = ""
    @State private var expanded: Set<String> = ["local"]
    @State private var newBranchFrom: GitBranch?
    @State private var renaming: GitBranch?
    @State private var confirmDelete: GitBranch?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(L("Ветка или тег"), text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.chromeBackground)))
            .padding(6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty { tree } else { found }
                }
                .padding(.bottom, 8)
            }
        }
        .sheet(item: $newBranchFrom) { branch in
            BranchNameSheet(title: L("Новая ветка от \(branch.name)"), initial: "") { name in
                client.createBranch(name, from: branch.isCurrent ? nil : branch.name)
            }
        }
        .sheet(item: $renaming) { branch in
            BranchNameSheet(title: L("Переименовать \(branch.name)"), initial: branch.name) { name in
                client.renameBranch(branch, to: name)
            }
        }
        .confirmationDialog(L("Удалить ветку \(confirmDelete?.name ?? "")?"),
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { branch in
            Button(L("Удалить"), role: .destructive) { client.deleteBranch(branch) }
        } message: { _ in
            Text(L("Только локальную; на сервере ветка останется."))
        }
    }

    // MARK: - Дерево

    @ViewBuilder
    private var tree: some View {
        special(L("HEAD (текущая ветка)"), icon: "scope", selected: isMine) {
            history.show(scope: .current, mode: .mine)
        }
        special(L("Основная — по MR"), icon: "list.bullet.rectangle", selected: isMainline) {
            history.show(scope: .current, mode: .mainline)
        }
        special(L("Все ветки — граф"), icon: "point.3.connected.trianglepath.dotted",
                selected: history.mode == .graph && history.filter.scope == .all) {
            history.show(scope: .all, mode: .graph)
        }
        group(L("Локальные"), id: "local", branches: client.localBranches)
        group(L("Удалённые"), id: "remote", branches: client.remoteBranches)
    }

    /// Поиск — плоским списком: на 7,5 тыс. веток дерево ни к чему.
    @ViewBuilder
    private var found: some View {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let matches = client.branches.filter { branch in words.allSatisfy { branch.name.lowercased().contains($0) } }
        ForEach(matches.prefix(300)) { branch in
            row(branch, title: branch.name, indent: 0)
        }
        if matches.isEmpty {
            Text(L("Не найдено")).font(.system(size: 11)).foregroundStyle(.tertiary).padding(10)
        }
    }

    private var isMine: Bool { history.mode == .mine }
    private var isMainline: Bool { history.mode == .mainline && history.filter.scope == .current }

    private func special(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(selected ? Color.accentColor.opacity(0.25) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Раздел: ветки без папки — сразу, остальные — по первой части имени.
    @ViewBuilder
    private func group(_ title: String, id: String, branches: [GitBranch]) -> some View {
        disclosure(title, id: id, indent: 0, count: branches.count)
        if expanded.contains(id) {
            let prefixLength = id == "remote" ? 1 : 0
            let folders = Self.folders(branches, skip: prefixLength)
            ForEach(folders.loose) { branch in
                row(branch, title: Self.tail(branch.name, skip: prefixLength), indent: 1)
            }
            ForEach(folders.named, id: \.name) { folder in
                let folderID = id + "/" + folder.name
                disclosure(folder.name, id: folderID, indent: 1, count: folder.branches.count)
                if expanded.contains(folderID) {
                    ForEach(folder.branches.prefix(500)) { branch in
                        row(branch, title: Self.tail(branch.name, skip: prefixLength + 1), indent: 2)
                    }
                }
            }
        }
    }

    private func disclosure(_ title: String, id: String, indent: Int, count: Int) -> some View {
        Button {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded.contains(id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                    .foregroundStyle(.secondary)
                Image(systemName: indent == 0 ? "tray.2" : "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                Spacer()
                Text("\(count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, weight: indent == 0 ? .medium : .regular))
            .padding(.leading, 8 + CGFloat(indent) * 14)
            .padding(.trailing, 8)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ branch: GitBranch, title: String, indent: Int) -> some View {
        let selected = history.mode == .graph && history.filter.scope == .ref(branch.name)
        return HStack(spacing: 5) {
            Image(systemName: branch.isCurrent ? "checkmark" : branch.isRemote ? "cloud" : "arrow.triangle.branch")
                .font(.system(size: 10))
                .frame(width: 12)
                .foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
            Text(title)
                .fontWeight(branch.isCurrent ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            if branch.ahead > 0 { Text("↑\(branch.ahead)").foregroundStyle(Color(nsColor: Theme.gitAdded)) }
            if branch.behind > 0 { Text("↓\(branch.behind)").foregroundStyle(Color(nsColor: Theme.gitModified)) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.leading, 8 + CGFloat(indent) * 14 + 10)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .help(branch.name + "\n" + branch.subject)
        // Одиночный клик — сразу: пара onTapGesture(count: 2) + onTapGesture
        // ждёт, не будет ли второго, и лог ветки открывался с задержкой.
        .onTapGesture { history.show(scope: .ref(branch.name), mode: .graph) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { client.checkout(branch) })
        .contextMenu { menu(branch) }
    }

    @ViewBuilder
    private func menu(_ branch: GitBranch) -> some View {
        if !branch.isCurrent {
            Button(L("Переключиться")) { client.checkout(branch) }
        }
        Button(L("Новая ветка отсюда…")) { newBranchFrom = branch }
        Divider()
        if !branch.isCurrent, let current = client.currentBranch {
            Button(L("Влить \(branch.name) в \(current.name)")) { client.merge(branch.name) }
            Button(L("Перенести \(current.name) на \(branch.name) (rebase)")) { client.rebase(onto: branch.name) }
            Button(L("Сравнить с \(current.name)")) {
                history.comparison = GitHistoryModel.Comparison(base: "HEAD", target: branch.name)
            }
            Divider()
        }
        if !branch.isRemote {
            Button(L("Переименовать…")) { renaming = branch }
            if !branch.isCurrent {
                Button(L("Удалить…"), role: .destructive) { confirmDelete = branch }
            }
        }
    }

    // MARK: - Папки

    struct Folder { var name: String; var branches: [GitBranch] }

    /// Ветки по первой части имени после `skip` частей (у удалённых — `origin`).
    static func folders(_ branches: [GitBranch], skip: Int) -> (loose: [GitBranch], named: [Folder]) {
        var loose: [GitBranch] = []
        var named: [String: [GitBranch]] = [:]
        for branch in branches {
            let parts = branch.name.split(separator: "/", omittingEmptySubsequences: false).dropFirst(skip)
            if parts.count > 1, let first = parts.first {
                named[String(first), default: []].append(branch)
            } else {
                loose.append(branch)
            }
        }
        let folders = named.map { Folder(name: $0.key, branches: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (loose.sorted { ($0.isCurrent ? 0 : 1, $0.name) < ($1.isCurrent ? 0 : 1, $1.name) }, folders)
    }

    static func tail(_ name: String, skip: Int) -> String {
        name.split(separator: "/", omittingEmptySubsequences: false).dropFirst(skip).joined(separator: "/")
    }
}
