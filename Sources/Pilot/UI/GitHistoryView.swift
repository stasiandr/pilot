import SwiftUI
import AppKit

/// История: слева лог с графом веток, справа — выбранный коммит, его
/// файлы и дифф. Сверху фильтры: ветка, текст или хэш, автор, путь.
struct GitHistoryView: View {
    let workspace: Workspace
    @ObservedObject var history: GitHistoryModel
    @ObservedObject var client: GitClient
    @State private var newBranchFrom: GitCommitInfo?
    @State private var rebaseBase: GitCommitInfo?
    @State private var confirmRevert: GitCommitInfo?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if let comparison = history.comparison {
                comparisonBar(comparison)
                Divider()
                HSplitView {
                    fileList(history.comparisonFiles, revision: comparison.target)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                    PatchView(patch: history.selectedFile == nil ? GitFilePatch() : history.filePatch)
                        .frame(minWidth: 420, maxWidth: .infinity)
                }
            } else {
                HSplitView {
                    log
                        .frame(minWidth: 460, idealWidth: 620, maxWidth: .infinity)
                    details
                        .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity)
                }
            }
        }
        .onAppear { history.open(repository: client.repository) }
        .sheet(item: $newBranchFrom) { commit in
            BranchNameSheet(title: L("Новая ветка от \(commit.shortHash)"), initial: "") { name in
                client.createBranch(name, from: commit.hash)
            }
        }
        .sheet(item: $rebaseBase) { base in
            RebaseEditor(client: client, base: base)
        }
        .confirmationDialog(L("Отменить коммит новым коммитом?"),
                            isPresented: Binding(get: { confirmRevert != nil }, set: { if !$0 { confirmRevert = nil } }),
                            presenting: confirmRevert) { commit in
            Button("Revert") { client.revert(commit) }
        } message: { commit in
            Text(commit.subject)
        }
    }

    // MARK: - Фильтры

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button(GitHistoryModel.Scope.current.title) { history.filter.scope = .current }
                Button(GitHistoryModel.Scope.all.title) { history.filter.scope = .all }
                Divider()
                ForEach(client.localBranches.prefix(30)) { branch in
                    Button(branch.name) { history.filter.scope = .ref(branch.name) }
                }
            } label: {
                Label(history.filter.scope.title, systemImage: "arrow.triangle.branch")
            }
            .fixedSize()
            SearchField(text: $history.filter.text, prompt: L("Сообщение или хэш"))
                .frame(minWidth: 160, maxWidth: 320)
            SearchField(text: $history.filter.author, prompt: L("Автор"))
                .frame(minWidth: 100, maxWidth: 180)
            if let path = history.filter.path {
                chip(history.filter.lines.map { L("\((path as NSString).lastPathComponent), строки \($0.lowerBound)–\($0.upperBound)") }
                     ?? path) {
                    history.filter.path = nil
                    history.filter.lines = nil
                }
            }
            Spacer()
            if history.isLoading { ProgressView().controlSize(.small) }
            Button { history.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L("Обновить"))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func chip(_ text: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text").font(.system(size: 10))
            Text(text).lineLimit(1).truncationMode(.head)
            Button(action: clear) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .frame(maxWidth: 320)
    }

    private func comparisonBar(_ comparison: GitHistoryModel.Comparison) -> some View {
        HStack {
            Image(systemName: "arrow.left.arrow.right")
            Text(L("Что есть в \(comparison.target) и нет в \(comparison.base)")).fontWeight(.medium)
            Text(L("файлов: \(history.comparisonFiles.count)")).foregroundStyle(.secondary)
            Spacer()
            Button(L("Закрыть сравнение")) { history.comparison = nil }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - Лог

    private var log: some View {
        List(selection: $history.selection) {
            ForEach(Array(history.commits.enumerated()), id: \.element.hash) { index, commit in
                CommitRow(commit: commit, row: index < history.rows.count ? history.rows[index] : nil)
                    .tag(commit.hash)
                    .contextMenu { commitMenu(commit) }
                    .onAppear {
                        if index == history.commits.count - 1 { history.loadMore() }
                    }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, CommitRow.height)
        .overlay {
            if let error = history.error {
                Text(error).foregroundStyle(Color(nsColor: Theme.diagnosticError))
            } else if !history.isLoading && history.commits.isEmpty {
                Text(L("Коммитов не найдено")).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func commitMenu(_ commit: GitCommitInfo) -> some View {
        Button(L("Копировать хэш")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.hash, forType: .string)
        }
        Divider()
        Button(L("Новая ветка отсюда…")) { newBranchFrom = commit }
        Button(L("Сравнить с текущим состоянием")) {
            history.comparison = GitHistoryModel.Comparison(base: commit.hash, target: "HEAD")
        }
        Divider()
        Button("Cherry-pick") { client.cherryPick(commit) }
            .disabled(commit.isMerge)
        // Revert слияния не предлагаем: во многих командах он запрещён, и
        // после него ветку нельзя влить повторно.
        if !commit.isMerge {
            Button(L("Revert — отменить новым коммитом…")) { confirmRevert = commit }
        }
        Divider()
        Button(L("Интерактивный rebase отсюда…")) { rebaseBase = commit }
            .help(L("Переписать коммиты после этого — только неотправленные"))
        Menu(L("Сдвинуть ветку сюда")) {
            Button(L("Soft — правки подготовлены")) { client.reset(to: commit, mode: .soft) }
            Button(L("Mixed — правки в рабочей копии")) { client.reset(to: commit, mode: .mixed) }
        }
    }

    // MARK: - Коммит

    @ViewBuilder
    private var details: some View {
        if let details = history.details {
            VSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    CommitHeader(details: details)
                    Divider()
                    fileList(details.files, revision: details.commit.hash)
                }
                .frame(minHeight: 160, idealHeight: 260)
                PatchView(patch: history.selectedFile == nil ? GitFilePatch() : history.filePatch)
                    .frame(minHeight: 200)
            }
        } else if history.selection != nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(L("Выберите коммит")).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileList(_ files: [GitChangedFile], revision: String) -> some View {
        List(selection: $history.selectedFile) {
            ForEach(files) { file in
                ChangedFileRow(letter: file.kind.letter, color: ChangeBadge.color(file.kind),
                               name: file.fileName, directory: file.directory,
                               detail: file.originalPath.map { "← " + ($0 as NSString).lastPathComponent })
                    .tag(file.path)
                    .contextMenu {
                        Button(L("Открыть эту версию")) { openVersion(file.path, revision: revision) }
                            .disabled(file.kind == .deleted)
                        Button(L("Открыть в редакторе")) {
                            if let repository = client.repository {
                                workspace.open(file: repository.appendingPathComponent(file.path))
                                workspace.bringToFront()
                            }
                        }
                        Button(L("История файла")) { history.filter.path = file.path; history.filter.lines = nil }
                    }
            }
        }
        .listStyle(.plain)
    }

    private func openVersion(_ path: String, revision: String) {
        Task {
            guard let text = await history.text(of: path, at: revision) else {
                client.error = L("Не удалось прочитать \(path) в \(String(revision.prefix(8)))")
                return
            }
            workspace.openRevision(path: path, revision: revision, text: text)
        }
    }
}

// MARK: - Строка лога

private struct CommitRow: View {
    static let height: CGFloat = 24
    let commit: GitCommitInfo
    let row: GitGraphRow?

    var body: some View {
        HStack(spacing: 6) {
            if let row {
                GraphCell(row: row).frame(width: GraphCell.width(for: row), height: Self.height)
            }
            ForEach(commit.refs.prefix(4), id: \.self) { ref in
                RefBadge(ref: ref)
            }
            Text(commit.subject)
                .lineLimit(1)
                .foregroundStyle(commit.isMerge ? .secondary : .primary)
            Spacer(minLength: 8)
            Text(commit.author)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 140, alignment: .trailing)
            Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 118, alignment: .trailing)
            Text(commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .frame(height: Self.height)
    }
}

/// Метка ветки или тега у коммита.
private struct RefBadge: View {
    let ref: String

    var body: some View {
        let isHead = ref.hasPrefix("HEAD")
        let isTag = ref.hasPrefix("tag: ")
        let isRemote = ref.contains("/") && !isHead
        let text = ref.replacingOccurrences(of: "HEAD -> ", with: "").replacingOccurrences(of: "tag: ", with: "")
        HStack(spacing: 3) {
            Image(systemName: isTag ? "tag" : isRemote ? "cloud" : "arrow.triangle.branch")
                .font(.system(size: 8))
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10, weight: isHead ? .semibold : .regular))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill((isHead ? Color.accentColor : isTag ? Color.orange : Color.secondary).opacity(0.2)))
        .fixedSize()
    }
}

/// Кусок графа в строке: линии сверху в точку, из точки вниз, сквозные.
struct GraphCell: View {
    static let lane: CGFloat = 12
    /// Дальше — не рисуем: на 7 тыс. веток граф шире окна.
    static let maxLanes = 24

    let row: GitGraphRow

    static func width(for row: GitGraphRow) -> CGFloat {
        CGFloat(min(row.width, maxLanes)) * lane + 4
    }

    static let palette: [Color] = [
        Color(red: 0.36, green: 0.62, blue: 0.98), Color(red: 0.95, green: 0.55, blue: 0.25),
        Color(red: 0.40, green: 0.78, blue: 0.45), Color(red: 0.85, green: 0.40, blue: 0.75),
        Color(red: 0.95, green: 0.78, blue: 0.25), Color(red: 0.40, green: 0.80, blue: 0.85),
        Color(red: 0.90, green: 0.35, blue: 0.40), Color(red: 0.62, green: 0.55, blue: 0.95),
    ]

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(min(lane, Self.maxLanes - 1)) * Self.lane + Self.lane / 2 + 2 }
            func color(_ index: Int) -> Color { Self.palette[index % Self.palette.count] }
            for line in row.top {
                var path = Path()
                path.move(to: CGPoint(x: x(line.from), y: 0))
                if line.from == line.to {
                    path.addLine(to: CGPoint(x: x(line.to), y: mid))
                } else {
                    path.addCurve(to: CGPoint(x: x(line.to), y: mid),
                                  control1: CGPoint(x: x(line.from), y: mid * 0.7),
                                  control2: CGPoint(x: x(line.to), y: mid * 0.3))
                }
                context.stroke(path, with: .color(color(line.color)), lineWidth: 1.6)
            }
            for line in row.bottom {
                var path = Path()
                path.move(to: CGPoint(x: x(line.from), y: mid))
                if line.from == line.to {
                    path.addLine(to: CGPoint(x: x(line.to), y: size.height))
                } else {
                    path.addCurve(to: CGPoint(x: x(line.to), y: size.height),
                                  control1: CGPoint(x: x(line.from), y: mid + mid * 0.7),
                                  control2: CGPoint(x: x(line.to), y: mid + mid * 0.3))
                }
                context.stroke(path, with: .color(color(line.color)), lineWidth: 1.6)
            }
            let dot = CGRect(x: x(row.column) - 4, y: mid - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dot), with: .color(color(row.color)))
            context.stroke(Path(ellipseIn: dot), with: .color(Color(nsColor: Theme.swiftUIEditorBackground)), lineWidth: 1.2)
        }
    }
}

private struct CommitHeader: View {
    let details: GitHistoryModel.Details

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(details.body)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Text(details.commit.author).fontWeight(.medium)
                    Text(details.commit.email).foregroundStyle(.secondary)
                    Text(details.commit.date.formatted(date: .long, time: .shortened)).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                HStack(spacing: 10) {
                    Text(details.commit.hash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    if details.commit.isMerge {
                        Text(L("слияние: файлы — против первого родителя"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(maxHeight: 150)
    }
}

// MARK: - Мелочи

/// Поле поиска с лупой и крестиком.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            // Лог перечитывается по Return, а не на каждую букву: на большом
            // репозитории каждый запрос — git log.
            TextField(prompt, text: $draft)
                .textFieldStyle(.plain)
                .onSubmit { text = draft }
            if !draft.isEmpty {
                Button { draft = ""; text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.chromeBackground)))
        .onAppear { draft = text }
        .onChange(of: text) { _, value in draft = value }
    }
}

/// Имя ветки: поле и проверка по мере набора.
struct BranchNameSheet: View {
    let title: String
    let initial: String
    let perform: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(L("Имя ветки"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            if !name.isEmpty && !GitBranch.isValidName(name) {
                Text(L("Так ветку назвать нельзя")).font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.diagnosticError))
            }
            HStack {
                Spacer()
                Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Создать"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!GitBranch.isValidName(name))
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = initial
            focused = true
        }
    }

    private func submit() {
        guard GitBranch.isValidName(name) else { return }
        perform(name)
        dismiss()
    }
}
