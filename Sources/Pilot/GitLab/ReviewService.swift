import SwiftUI
import AppKit

/// Файл из MR: сырой дифф от GitLab и он же, разобранный.
struct ReviewFile: Identifiable, Equatable, Sendable {
    let raw: GLDiff
    let diff: UnifiedDiff

    var id: String { raw.newPath }
    var path: String { raw.deletedFile ? raw.oldPath : raw.newPath }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    /// Буква как в `git status`: A добавлен, D удалён, R переименован, M изменён.
    var letter: String {
        if raw.newFile { return "A" }
        if raw.deletedFile { return "D" }
        if raw.renamedFile { return "R" }
        return "M"
    }

    /// Дифф не пришёл целиком — полосок не будет, только сам файл.
    var isDiffMissing: Bool { raw.diff.isEmpty && !raw.newFile && !raw.deletedFile }
}

/// Открытый на ревью MR.
struct ActiveReview: Equatable {
    var mr: GLMergeRequest
    var refs: GLDiffRefs
    var files: [ReviewFile]
    var discussions: [GLDiscussion]
    var approvals: GLApprovals?
    /// Просмотренные файлы — локальная пометка, в GitLab не уходит.
    var viewed: Set<String>

    func file(id: String) -> ReviewFile? { files.first { $0.id == id } }

    /// Треды к строкам этого файла, по строке показа (с нуля).
    func threads(in file: ReviewFile) -> [Int: [GLDiscussion]] {
        var result: [Int: [GLDiscussion]] = [:]
        for discussion in discussions where !discussion.isSystem {
            guard let position = discussion.position, belongs(position, to: file),
                  let line = displayLine(position, in: file) else { continue }
            result[line, default: []].append(discussion)
        }
        return result
    }

    /// Треды к MR целиком, не к строкам.
    var generalThreads: [GLDiscussion] {
        discussions.filter { !$0.isSystem && $0.position == nil }
    }

    func threadCount(in file: ReviewFile) -> (total: Int, open: Int) {
        let all = threads(in: file).values.flatMap { $0 }
        return (all.count, all.filter { $0.isResolvable && !$0.isResolved }.count)
    }

    /// Комментарий оставлен к старой версии MR — строка могла уехать.
    func isOutdated(_ discussion: GLDiscussion) -> Bool {
        guard let head = discussion.position?.headSha else { return false }
        return head != refs.headSha
    }

    private func belongs(_ position: GLPosition, to file: ReviewFile) -> Bool {
        if file.raw.deletedFile { return position.oldPath == file.raw.oldPath }
        return position.newPath == file.raw.newPath
    }

    private func displayLine(_ position: GLPosition, in file: ReviewFile) -> Int? {
        // Удалённый файл показывается в старой версии — там считаем по старым строкам.
        if file.raw.deletedFile { return position.oldLine.map { $0 - 1 } }
        return file.diff.displayLine(for: position)
    }

    var reviewedCount: Int { files.filter { viewed.contains($0.id) }.count }
}

/// Ревью MR из GitLab для открытого проекта.
///
/// Как git и LSP, никогда не блокирует интерфейс: всё сетевое — в фоне,
/// а просмотр и навигация по коду работают, пока MR ещё грузится.
@MainActor
final class ReviewService: ObservableObject {

    enum Phase: Equatable {
        /// Проект не из GitLab или не под git.
        case unavailable(String)
        /// Токена для хоста нет — нужно подключиться.
        case disconnected
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var remote: GitLabRemote?
    /// Хост API; обычно совпадает с хостом remote.
    @Published private(set) var apiHost: String?
    @Published private(set) var phase: Phase = .unavailable("Откройте проект")
    @Published private(set) var me: GLUser?
    @Published private(set) var mergeRequests: [GLMergeRequest] = []
    @Published private(set) var active: ActiveReview?
    /// Какой MR сейчас грузится.
    @Published private(set) var openingIID: Int?
    /// Последняя ошибка действия (комментарий, апрув) — показывается в панели.
    @Published var actionError: String?
    @Published var isConnectSheetPresented = false

    private(set) var repository: URL?
    private var client: GitLabClient?
    private var activated = false
    /// Содержимое файлов по «ревизия:путь» — ревизии неизменны, кэш не устаревает.
    private var contents: [String: String] = [:]
    private var listTask: Task<Void, Never>?

    init() {
        // Вернулись в Pilot — возможно, в MR ответили или запушили.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOnActivation() }
        }
    }

    // MARK: - Проект

    func workspaceChanged(to root: URL?) {
        listTask?.cancel()
        remote = nil
        apiHost = nil
        client = nil
        me = nil
        mergeRequests = []
        active = nil
        openingIID = nil
        actionError = nil
        contents = [:]
        activated = false
        repository = root.flatMap { Git.repositoryRoot(for: $0.resolvingSymlinksInPath()) }
        guard let repository else {
            phase = .unavailable(root == nil ? "Откройте проект" : "Проект не под git")
            return
        }
        phase = .loading
        Task.detached(priority: .utility) { [weak self] in
            let url = Self.remoteURL(in: repository)
            await self?.adoptRemote(url, repository: repository)
        }
    }

    private func adoptRemote(_ url: String?, repository: URL) {
        guard self.repository == repository else { return }
        guard let url, let parsed = GitLabRemote.parse(url) else {
            phase = .unavailable("У репозитория нет remote на GitLab")
            return
        }
        remote = parsed
        apiHost = Self.savedAPIHost(for: parsed.host) ?? parsed.host
        phase = .disconnected
        if activated { connectWithSavedToken() }
    }

    /// origin, а если его нет — первый remote.
    nonisolated private static func remoteURL(in repository: URL) -> String? {
        if let origin = Git.run(["remote", "get-url", "origin"], in: repository), origin.status == 0 {
            return String(decoding: origin.stdout, as: UTF8.self)
        }
        guard let list = Git.run(["remote"], in: repository), list.status == 0,
              let first = String(decoding: list.stdout, as: UTF8.self).split(separator: "\n").first,
              let url = Git.run(["remote", "get-url", String(first)], in: repository), url.status == 0
        else { return nil }
        return String(decoding: url.stdout, as: UTF8.self)
    }

    /// Панель ревью открыли впервые. Токен читается только сейчас, а не при
    /// открытии проекта: чтение связки ключей может спросить разрешение,
    /// и спрашивать его у того, кто пришёл просто читать код, незачем.
    func activate() {
        guard !activated else { return }
        activated = true
        if phase == .disconnected { connectWithSavedToken() }
    }

    private func connectWithSavedToken() {
        guard let host = apiHost else { return }
        phase = .loading
        Task.detached(priority: .userInitiated) { [weak self] in
            let token = TokenStore.token(for: host)
            await self?.adoptToken(token, host: host)
        }
    }

    private func adoptToken(_ token: String?, host: String) {
        guard apiHost == host else { return }
        guard let token else { phase = .disconnected; return }
        client = GitLabClient(host: host, token: token)
        refreshList()
    }

    // MARK: - Подключение

    /// Проверяет токен запросом `/user` и только тогда кладёт его в связку ключей.
    func connect(host rawHost: String, token rawToken: String) async throws {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = GitLabClient(host: host, token: token)
        let user = try await candidate.currentUser()
        try TokenStore.save(token, for: host)
        if let remote, host != remote.host {
            UserDefaults.standard.set(host, forKey: Self.hostKey(remote.host))
        }
        apiHost = host
        client = candidate
        me = user
        activated = true
        refreshList()
    }

    func disconnect() {
        if let apiHost { TokenStore.delete(host: apiHost) }
        client = nil
        me = nil
        mergeRequests = []
        active = nil
        phase = remote == nil ? phase : .disconnected
    }

    private static func hostKey(_ remoteHost: String) -> String { "pilot.gitlab.apiHost.\(remoteHost)" }

    private static func savedAPIHost(for remoteHost: String) -> String? {
        UserDefaults.standard.string(forKey: hostKey(remoteHost))
    }

    // MARK: - Список MR

    func refreshList() {
        guard let client, let remote else { return }
        if mergeRequests.isEmpty { phase = .loading }
        let needsUser = me == nil
        listTask?.cancel()
        listTask = Task { [weak self] in
            do {
                let list = try await client.openMergeRequests(remote)
                let fetchedUser = needsUser ? try await client.currentUser() : nil
                guard let self, !Task.isCancelled else { return }
                if let fetchedUser { self.me = fetchedUser }
                self.mergeRequests = list
                self.phase = .ready
            } catch {
                self?.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        if (error as? GitLabError) == .unauthorized {
            client = nil
            phase = .disconnected
            actionError = error.localizedDescription
        } else {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Разбивка для списка: сначала то, что ждёт моего ревью.
    var sections: [(title: String, items: [GLMergeRequest])] {
        guard let me else { return [("Открытые", mergeRequests)] }
        let mine = mergeRequests.filter { $0.author.id == me.id }
        let toReview = mergeRequests.filter { mr in
            mr.author.id != me.id && (mr.reviewers ?? []).contains { $0.id == me.id }
        }
        let rest = mergeRequests.filter { mr in
            !mine.contains(where: { $0.id == mr.id }) && !toReview.contains(where: { $0.id == mr.id })
        }
        return [("Жду моего ревью", toReview), ("Мои", mine), ("Остальные", rest)].filter { !$0.items.isEmpty }
    }

    // MARK: - Открытый MR

    func open(_ mr: GLMergeRequest) async {
        guard let client, let remote else { return }
        openingIID = mr.iid
        actionError = nil
        defer { if openingIID == mr.iid { openingIID = nil } }
        do {
            async let detail = client.mergeRequest(remote, iid: mr.iid)
            async let diffs = client.diffs(remote, iid: mr.iid)
            async let discussions = client.discussions(remote, iid: mr.iid)
            async let approvals = try? client.approvals(remote, iid: mr.iid)
            let full = try await detail
            guard let refs = full.diffRefs else {
                actionError = "У MR нет версии для сравнения — возможно, в нём ещё нет коммитов"
                return
            }
            let files = try await diffs
                .map { ReviewFile(raw: $0, diff: UnifiedDiff.parse($0.diff)) }
            let review = ActiveReview(mr: full, refs: refs, files: files,
                                      discussions: try await discussions,
                                      approvals: await approvals,
                                      viewed: loadViewed(remote: remote, mr: full, head: refs.headSha))
            guard openingIID == mr.iid else { return }
            active = review
        } catch {
            actionError = error.localizedDescription
            if (error as? GitLabError) == .unauthorized { fail(error) }
        }
    }

    func close() {
        active = nil
        refreshList()
    }

    /// Треды и апрувы меняются часто, дифф — только при пуше в MR.
    func refreshActive() async {
        guard let client, let remote, let current = active else { return }
        let iid = current.mr.iid
        do {
            let detail = try await client.mergeRequest(remote, iid: iid)
            async let discussions = client.discussions(remote, iid: iid)
            async let approvals = try? client.approvals(remote, iid: iid)
            if let refs = detail.diffRefs, refs.headSha != current.refs.headSha {
                // Запушили — перечитываем дифф, отметки «просмотрено» сбрасываются.
                let files = try await client.diffs(remote, iid: iid)
                    .map { ReviewFile(raw: $0, diff: UnifiedDiff.parse($0.diff)) }
                guard active?.mr.iid == iid else { return }
                active = ActiveReview(mr: detail, refs: refs, files: files,
                                      discussions: try await discussions, approvals: await approvals,
                                      viewed: loadViewed(remote: remote, mr: detail, head: refs.headSha))
            } else {
                let fresh = try await discussions
                let freshApprovals = await approvals
                guard active?.mr.iid == iid else { return }
                active?.mr = detail
                active?.discussions = fresh
                if let freshApprovals { active?.approvals = freshApprovals }
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func refreshOnActivation() {
        guard client != nil else { return }
        if active != nil {
            Task { await refreshActive() }
        } else if phase == .ready {
            refreshList()
        }
    }

    // MARK: - Просмотренные файлы

    private func viewedKey(remote: GitLabRemote, mr: GLMergeRequest, head: String) -> String {
        "pilot.review.viewed.\(remote.host)/\(remote.projectPath)!\(mr.iid)@\(head)"
    }

    private func loadViewed(remote: GitLabRemote, mr: GLMergeRequest, head: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: viewedKey(remote: remote, mr: mr, head: head)) ?? [])
    }

    func toggleViewed(_ file: ReviewFile) {
        guard let remote, var review = active else { return }
        if review.viewed.contains(file.id) { review.viewed.remove(file.id) } else { review.viewed.insert(file.id) }
        active = review
        UserDefaults.standard.set(Array(review.viewed),
                                  forKey: viewedKey(remote: remote, mr: review.mr, head: review.refs.headSha))
    }

    // MARK: - Содержимое файлов

    /// Файл в той версии, что в MR: новый и изменённый — с головы MR,
    /// удалённый — с базы. Сначала из локального репозитория (если коммит
    /// уже скачан — мгновенно), иначе — через API.
    func loadDocument(for file: ReviewFile) async throws -> LoadedDocument {
        guard let review = active, let repository else { throw GitLabError.notFound }
        let sha = file.raw.deletedFile ? review.refs.baseSha : review.refs.headSha
        let path = file.path
        let key = "\(sha):\(path)"
        let text: String
        if let cached = contents[key] {
            text = cached
        } else {
            text = try await fetchContent(sha: sha, path: path, repository: repository)
            contents[key] = text
        }
        let url = repository.appendingPathComponent(path)
        return try await Task.detached(priority: .userInitiated) {
            try LoadedDocument.make(url: url, data: Data(text.utf8), revision: sha)
        }.value
    }

    private func fetchContent(sha: String, path: String, repository: URL) async throws -> String {
        let local = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let output = Git.run(["cat-file", "blob", "\(sha):\(path)"], in: repository),
                  output.status == 0 else { return nil }
            return output.stdout
        }.value
        let data: Data
        if let local {
            data = local
        } else {
            guard let client, let remote else { throw GitLabError.unauthorized }
            data = try await client.rawFile(remote, path: path, ref: sha)
        }
        if data.prefix(8192).contains(0) { throw LoadedDocument.LoadError.binary }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Действия

    /// Комментарий к строке. `line` — строка показанного текста (с нуля).
    func comment(on file: ReviewFile, line: Int, body: String) async throws {
        guard let client, let remote, let review = active else { throw GitLabError.unauthorized }
        var position: [String: Any] = [
            "position_type": "text",
            "base_sha": review.refs.baseSha,
            "start_sha": review.refs.startSha,
            "head_sha": review.refs.headSha,
            "old_path": file.raw.oldPath,
            "new_path": file.raw.newPath,
        ]
        if file.raw.deletedFile {
            position["old_line"] = line + 1
        } else {
            let lines = file.diff.commentLines(forNewLine: line)
            position["new_line"] = lines.new
            if let old = lines.old { position["old_line"] = old }
        }
        let created = try await client.createDiscussion(remote, iid: review.mr.iid, body: body, position: position)
        active?.discussions.append(created)
    }

    func commentOnMergeRequest(body: String) async throws {
        guard let client, let remote, let review = active else { throw GitLabError.unauthorized }
        let created = try await client.createDiscussion(remote, iid: review.mr.iid, body: body, position: nil)
        active?.discussions.append(created)
    }

    func reply(to discussion: GLDiscussion, body: String) async throws {
        guard let client, let remote, let review = active else { throw GitLabError.unauthorized }
        let note = try await client.reply(remote, iid: review.mr.iid, discussion: discussion.id, body: body)
        if let index = active?.discussions.firstIndex(where: { $0.id == discussion.id }) {
            active?.discussions[index].notes.append(note)
        }
    }

    func setResolved(_ discussion: GLDiscussion, _ resolved: Bool) async throws {
        guard let client, let remote, let review = active else { throw GitLabError.unauthorized }
        let updated = try await client.setResolved(remote, iid: review.mr.iid,
                                                   discussion: discussion.id, resolved: resolved)
        if let index = active?.discussions.firstIndex(where: { $0.id == discussion.id }) {
            active?.discussions[index] = updated
        }
    }

    var isApprovedByMe: Bool { active?.approvals?.isApproved(by: me) ?? false }

    func toggleApproval() async {
        guard let client, let remote, let review = active else { return }
        actionError = nil
        do {
            if isApprovedByMe {
                try await client.unapprove(remote, iid: review.mr.iid)
            } else {
                try await client.approve(remote, iid: review.mr.iid, sha: review.refs.headSha)
            }
            active?.approvals = try await client.approvals(remote, iid: review.mr.iid)
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Навигация по файлам

    func adjacentFile(to id: String?, direction: Int) -> ReviewFile? {
        guard let files = active?.files, !files.isEmpty else { return nil }
        guard let id, let index = files.firstIndex(where: { $0.id == id }) else {
            return direction > 0 ? files.first : files.last
        }
        let next = index + direction
        return files.indices.contains(next) ? files[next] : nil
    }
}
