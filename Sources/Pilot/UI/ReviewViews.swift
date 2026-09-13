import SwiftUI
import AppKit

// MARK: - Вкладка «Ревью» в навигаторе

struct ReviewNavigator: View {
    @ObservedObject var workspace: Workspace
    private var review: ReviewService { workspace.review }

    var body: some View {
        content
            .onAppear { review.activate() }
            .sheet(isPresented: Binding(get: { review.isConnectSheetPresented },
                                        set: { review.isConnectSheetPresented = $0 })) {
                ConnectGitLabView(review: review)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch review.phase {
        case .unavailable(let why):
            ReviewPlaceholder(icon: "arrow.triangle.pull", text: why)
        case .disconnected:
            connectPrompt
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why):
            VStack(spacing: 10) {
                ReviewPlaceholder(icon: "exclamationmark.triangle", text: why)
                Button("Повторить") { review.refreshList() }
            }
            .frame(maxHeight: .infinity)
        case .ready:
            if review.active != nil {
                MergeRequestDetail(workspace: workspace)
            } else {
                MergeRequestList(workspace: workspace)
            }
        }
    }

    private var connectPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ревью мерж-реквестов\n\(review.remote?.projectPath ?? "")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let error = review.actionError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Button("Подключить GitLab…") { review.isConnectSheetPresented = true }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReviewPlaceholder: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Список MR

struct MergeRequestList: View {
    @ObservedObject var workspace: Workspace
    private var review: ReviewService { workspace.review }

    var body: some View {
        let listing = review.listing
        let searching = !review.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
        List {
            ForEach(listing.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { mr in
                        Button { workspace.openReview(mr) } label: { row(mr) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !listing.found.isEmpty || review.isSearching {
                Section {
                    ForEach(listing.found) { mr in
                        Button { workspace.openReview(mr) } label: { row(mr) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Ещё в GitLab")
                        if review.isSearching { ProgressView().controlSize(.mini) }
                    }
                }
            }
            if searching {
                if listing.isEmpty && !review.isSearching {
                    Text("Ничего не найдено")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            } else if review.mergeRequests.isEmpty {
                Text("Открытых мерж-реквестов нет")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            if let error = review.actionError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func row(_ mr: GLMergeRequest) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !mr.isOpen { StateBadge(state: mr.state) }
                if mr.isDraft { DraftBadge() }
                Text(mr.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(mr.reference).monospacedDigit()
                Text(mr.author.name).lineLimit(1)
                if let updated = mr.updatedAt { Text(ReviewFormat.ago(updated)).lineLimit(1) }
                Spacer(minLength: 4)
                if review.openingIID == mr.iid {
                    ProgressView().controlSize(.mini)
                } else if let notes = mr.userNotesCount, notes > 0 {
                    Label("\(notes)", systemImage: "text.bubble").labelStyle(.titleAndIcon)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let me = review.me {
                Text("@\(me.username)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { review.refreshList() } label: { Image(systemName: "arrow.clockwise") }
                .help("Обновить список")
            Menu {
                Button("Сменить токен…") { review.isConnectSheetPresented = true }
                Button("Отключить GitLab", role: .destructive) { review.disconnect() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct DraftBadge: View {
    var body: some View {
        Text("Черновик")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

/// Слитый или закрытый MR — такие попадают в список только из поиска.
struct StateBadge: View {
    let state: String

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }

    private var title: String {
        switch state {
        case "merged": return "Слит"
        case "closed": return "Закрыт"
        case "locked": return "Заблокирован"
        default:       return state
        }
    }

    private var color: Color {
        switch state {
        case "merged": return Color(nsColor: Theme.reviewMerged)
        case "closed": return Color(nsColor: Theme.gitDeleted)
        default:       return .secondary
        }
    }
}

// MARK: - Открытый MR

struct MergeRequestDetail: View {
    @ObservedObject var workspace: Workspace
    private var review: ReviewService { workspace.review }

    var body: some View {
        if let active = review.active {
            List(selection: selection) {
                Section { header(active) }
                Section("Файлы · просмотрено \(active.reviewedCount) из \(active.files.count)") {
                    ForEach(active.files) { file in
                        ReviewFileRow(file: file, active: active,
                                      toggleViewed: { review.toggleViewed(file) })
                            .tag(file.id)
                    }
                }
                Section("Обсуждение") {
                    ForEach(active.generalThreads) { thread in
                        ThreadCard(discussion: thread, review: review)
                            .listRowSeparator(.hidden)
                    }
                    CommentComposer(placeholder: "Комментарий к мерж-реквесту…") { body in
                        try await review.commentOnMergeRequest(body: body)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { workspace.currentReviewFile?.id },
                set: { id in
                    guard let id, let file = review.active?.file(id: id) else { return }
                    workspace.open(reviewFile: file)
                })
    }

    private func header(_ active: ActiveReview) -> some View {
        let mr = active.mr
        return VStack(alignment: .leading, spacing: 6) {
            Button { workspace.closeReview() } label: {
                Label("Все мерж-реквесты", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !mr.isOpen { StateBadge(state: mr.state) }
                if mr.isDraft { DraftBadge() }
                Text(mr.title).font(.system(size: 13, weight: .semibold)).lineLimit(3)
            }
            Text("\(mr.reference) · \(mr.author.name)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("\(mr.sourceBranch) → \(mr.targetBranch)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                ApproveButton(review: review)
                Button { Task { await review.refreshActive() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить треды и апрувы")
                if let url = URL(string: mr.webUrl) {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                        .help("Открыть в GitLab")
                }
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)

            if let approvers = active.approvals?.approvedBy, !approvers.isEmpty {
                Text("Апрувы: " + approvers.map(\.user.name).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = review.actionError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ReviewFileRow: View {
    let file: ReviewFile
    let active: ActiveReview
    let toggleViewed: () -> Void

    var body: some View {
        let threads = active.threadCount(in: file)
        HStack(spacing: 6) {
            Text(file.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: color))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name).font(.system(size: 12)).lineLimit(1)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if threads.total > 0 {
                Label("\(threads.total)", systemImage: threads.open > 0 ? "text.bubble.fill" : "checkmark.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(threads.open > 0 ? Color(nsColor: Theme.reviewThread) : .secondary)
            }
            if !file.isDiffMissing {
                HStack(spacing: 2) {
                    Text("+\(file.diff.additions)").foregroundStyle(Color(nsColor: Theme.gitAdded))
                    Text("−\(file.diff.deletions)").foregroundStyle(Color(nsColor: Theme.gitDeleted))
                }
                .font(.system(size: 10, design: .monospaced))
            }
            Button(action: toggleViewed) {
                Image(systemName: active.viewed.contains(file.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(active.viewed.contains(file.id) ? Color(nsColor: Theme.gitAdded) : .secondary)
            }
            .buttonStyle(.plain)
            .help("Просмотрен")
        }
        .opacity(active.viewed.contains(file.id) ? 0.6 : 1)
    }

    private var color: NSColor {
        switch file.letter {
        case "A": return Theme.gitAdded
        case "D": return Theme.gitDeleted
        case "R": return Theme.gitRenamed
        default:  return Theme.gitModified
        }
    }
}

struct ApproveButton: View {
    @ObservedObject var review: ReviewService
    @State private var busy = false

    var body: some View {
        let approved = review.isApprovedByMe
        Button {
            busy = true
            Task { await review.toggleApproval(); busy = false }
        } label: {
            Label(approved ? "Апрувнуто" : "Апрув", systemImage: approved ? "checkmark.seal.fill" : "checkmark.seal")
                .foregroundStyle(approved ? Color(nsColor: Theme.gitAdded) : .primary)
        }
        .disabled(busy)
        .help(approved ? "Отозвать апрув" : "Одобрить эту версию MR")
    }
}

// MARK: - Полоса ревью над редактором

struct ReviewBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let active = workspace.review.active {
            let file = workspace.currentReviewFile
            let index = file.flatMap { current in active.files.firstIndex { $0.id == current.id } }
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.pull")
                    .foregroundStyle(Color(nsColor: Theme.reviewThread))
                Text(active.mr.reference).monospacedDigit().foregroundStyle(.secondary)
                Text(active.mr.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let file, let index {
                    if file.raw.deletedFile {
                        Text("Файл удалён").foregroundStyle(Color(nsColor: Theme.gitDeleted))
                    } else if file.isDiffMissing {
                        Text("Дифф слишком большой").foregroundStyle(.secondary)
                    }
                    Text("\(index + 1) из \(active.files.count)").monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        workspace.review.toggleViewed(file)
                    } label: {
                        Label("Просмотрен", systemImage: active.viewed.contains(file.id) ? "checkmark.circle.fill" : "circle")
                    }
                    .help("Отметить файл просмотренным")
                } else if workspace.document != nil {
                    Text("рабочая копия").foregroundStyle(.tertiary)
                }
                Button { workspace.openAdjacentReviewFile(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Предыдущий файл MR (⌥⌘↑)")
                Button { workspace.openAdjacentReviewFile(1) } label: { Image(systemName: "chevron.down") }
                    .help("Следующий файл MR (⌥⌘↓)")
                ApproveButton(review: workspace.review)
                Button { workspace.closeReview() } label: { Image(systemName: "xmark") }
                    .help("Закончить ревью")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(nsColor: Theme.reviewThread).opacity(0.08))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
            }
        }
    }
}

// MARK: - Окно у строки

/// Что с этой строкой: что было на её месте, какие треды, новый комментарий.
struct LineInspector: View {
    @ObservedObject var workspace: Workspace
    let line: Int
    let compose: Bool
    /// Высота содержимого: окно растёт вместе с тредом, но не выше 560 pt —
    /// дальше прокрутка. ScrollView сам своей высоты не знает.
    @State private var contentHeight: CGFloat = 80

    var body: some View {
        let threads = workspace.threads(atLine: line)
        let file = workspace.currentReviewFile
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Строка \(line + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let removed = workspace.removedLines(at: line) {
                    RemovedLinesView(lines: removed, fontSize: workspace.fontSize)
                }
                ForEach(threads) { thread in
                    ThreadCard(discussion: thread, review: workspace.review,
                               outdated: workspace.review.active?.isOutdated(thread) ?? false)
                }
                if let file {
                    CommentComposer(placeholder: threads.isEmpty ? "Комментарий к строке…" : "Новый тред к строке…",
                                    autofocus: compose || threads.isEmpty) { body in
                        try await workspace.review.comment(on: file, line: line, body: body)
                    }
                }
            }
            .padding(12)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(width: 480, height: min(max(contentHeight, 40), 560))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct RemovedLinesView: View {
    let lines: [String]
    let fontSize: CGFloat
    private let limit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lines.count == 1 ? "Было:" : "Было (\(lines.count) строк):")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { _, text in
                        Text("− " + (text.isEmpty ? " " : text))
                            .font(Font(Theme.editorFont(size: fontSize - 0.5)))
                            .foregroundStyle(Color(nsColor: Theme.removedLineText))
                            .fixedSize()
                    }
                    if lines.count > limit {
                        Text("… ещё \(lines.count - limit)").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.removedLineBackground)))
            .textSelection(.enabled)
        }
    }
}

// MARK: - Тред

struct ThreadCard: View {
    let discussion: GLDiscussion
    @ObservedObject var review: ReviewService
    var outdated = false
    @State private var replying = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if outdated {
                Label("К предыдущей версии MR — строка могла сдвинуться", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(discussion.humanNotes) { note in
                NoteRow(note: note)
            }
            HStack(spacing: 12) {
                Button(replying ? "Отмена" : "Ответить") { replying.toggle() }
                if discussion.isResolvable {
                    Button(discussion.isResolved ? "Открыть снова" : "Решить") { toggleResolved() }
                        .disabled(busy)
                }
                Spacer()
                if discussion.isResolved {
                    Label("Решён", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: Theme.gitAdded))
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
            if replying {
                CommentComposer(placeholder: "Ответ…", submitTitle: "Ответить", autofocus: true) { body in
                    try await review.reply(to: discussion, body: body)
                    replying = false
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        .opacity(discussion.isResolved && !replying ? 0.7 : 1)
    }

    private func toggleResolved() {
        busy = true
        error = nil
        Task {
            do { try await review.setResolved(discussion, !discussion.isResolved) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct NoteRow: View {
    let note: GLNote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(note.author.name).font(.system(size: 11, weight: .semibold))
                if let created = note.createdAt {
                    Text(ReviewFormat.ago(created))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help(ReviewFormat.full(created))
                }
            }
            Text(ReviewFormat.markdown(note.body))
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Поле для комментария

struct CommentComposer: View {
    let placeholder: String
    var submitTitle = "Отправить"
    var autofocus = false
    let onSubmit: (String) async throws -> Void

    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 54, maxHeight: 160)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text("Markdown · ⌘↩").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if sending { ProgressView().controlSize(.mini) }
                Button(submitTitle) { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmed.isEmpty || sending)
            }
        }
        .onAppear { if autofocus { focused = true } }
    }

    private func submit() {
        let body = trimmed
        guard !body.isEmpty else { return }
        sending = true
        error = nil
        Task {
            do {
                try await onSubmit(body)
                text = ""
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

// MARK: - Подключение

struct ConnectGitLabView: View {
    @ObservedObject var review: ReviewService
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    private var tokenPage: URL? {
        URL(string: "https://\(host)/-/user_settings/personal_access_tokens?name=Pilot&scopes=api")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Подключение к GitLab").font(.system(size: 15, weight: .semibold))
            Text("Pilot ходит в API GitLab с вашим Personal Access Token. Токен хранится в связке ключей macOS и уходит только на указанный хост. Для комментариев и апрувов нужны права api.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Хост").foregroundStyle(.secondary)
                    TextField("gitlab.com", text: $host).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Токен").foregroundStyle(.secondary)
                    SecureField("glpat-…", text: $token).textFieldStyle(.roundedBorder)
                }
            }
            .font(.system(size: 12))

            if let tokenPage, !host.isEmpty {
                Link("Создать токен в GitLab ↗", destination: tokenPage).font(.system(size: 12))
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Подключить") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || host.isEmpty || token.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { host = review.apiHost ?? review.remote?.host ?? "gitlab.com" }
    }

    private func connect() {
        busy = true
        error = nil
        Task {
            do {
                try await review.connect(host: host, token: token)
                token = ""
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Форматирование

enum ReviewFormat {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    static func ago(_ date: Date) -> String { relative.localizedString(for: date, relativeTo: Date()) }
    static func full(_ date: Date) -> String { fullFormatter.string(from: date) }

    /// Комментарии GitLab — это Markdown. Разметку строк (жирный, код, ссылки)
    /// показываем как есть, переносы — сохраняем; блоки вроде таблиц
    /// остаются текстом.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
