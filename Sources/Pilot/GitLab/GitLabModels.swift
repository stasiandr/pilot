import Foundation

// Модели ответов GitLab REST API v4. Берём только поля, которые нужны
// для ревью, — остальное декодер молча пропускает. Всё, чего может не быть
// (в старых версиях GitLab или в особых состояниях MR), — опционально.

struct GLUser: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var username: String
    var name: String
}

struct GLDiffRefs: Codable, Equatable, Sendable {
    var baseSha: String
    var headSha: String
    var startSha: String
}

struct GLMergeRequest: Codable, Identifiable, Equatable, Sendable {
    var id: Int
    var iid: Int
    var title: String
    var description: String?
    var state: String
    var draft: Bool?
    var author: GLUser
    var reviewers: [GLUser]?
    var assignees: [GLUser]?
    var sourceBranch: String
    var targetBranch: String
    var webUrl: String
    var sha: String?
    var updatedAt: Date?
    var userNotesCount: Int?
    /// Есть только в ответе на запрос одного MR, в списке его нет.
    var diffRefs: GLDiffRefs?
    var hasConflicts: Bool?
    var labels: [String]?

    var isDraft: Bool { draft ?? false }
    var reference: String { "!\(iid)" }
    var isOpen: Bool { state == "opened" }
}

/// Один файл из `…/merge_requests/:iid/diffs`.
struct GLDiff: Codable, Equatable, Sendable {
    var oldPath: String
    var newPath: String
    /// Unified diff без заголовков `---`/`+++`; пустой, если дифф слишком
    /// большой (`tooLarge`) или свёрнут (`collapsed`).
    var diff: String
    var newFile: Bool
    var renamedFile: Bool
    var deletedFile: Bool
    var tooLarge: Bool?
    var collapsed: Bool?
}

/// Куда привязан комментарий к коду. Номера строк — с единицы.
/// У добавленной строки есть только `newLine`, у удалённой — только
/// `oldLine`, у неизменённой — обе.
struct GLPosition: Codable, Equatable, Sendable {
    var baseSha: String?
    var startSha: String?
    var headSha: String?
    var oldPath: String?
    var newPath: String?
    var positionType: String?
    var oldLine: Int?
    var newLine: Int?
}

struct GLNote: Codable, Identifiable, Equatable, Sendable {
    var id: Int
    var type: String?
    var body: String
    var author: GLUser
    var createdAt: Date?
    var system: Bool
    var resolvable: Bool?
    var resolved: Bool?
    var position: GLPosition?
}

/// Тред: первая заметка и ответы. У обычного комментария к MR без
/// привязки к строке `individualNote == true` и заметка одна.
struct GLDiscussion: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var individualNote: Bool
    var notes: [GLNote]

    /// Заметки людей — системные («добавил коммит», «изменил описание»)
    /// в ревью только шумят.
    var humanNotes: [GLNote] { notes.filter { !$0.system } }
    var position: GLPosition? { notes.first?.position }
    var isSystem: Bool { humanNotes.isEmpty }
    var isResolvable: Bool { notes.contains { $0.resolvable == true } }
    var isResolved: Bool {
        let resolvable = notes.filter { $0.resolvable == true }
        return !resolvable.isEmpty && resolvable.allSatisfy { $0.resolved == true }
    }
}

struct GLApprovals: Codable, Equatable, Sendable {
    struct Approver: Codable, Equatable, Sendable { var user: GLUser }
    var approvedBy: [Approver]?
    var approved: Bool?
    var approvalsLeft: Int?

    func isApproved(by user: GLUser?) -> Bool {
        guard let user else { return false }
        return approvedBy?.contains { $0.user.id == user.id } ?? false
    }
}

enum GitLabJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Дата: \(text)")
        }
        return decoder
    }()

    /// GitLab отдаёт ISO 8601 то с долями секунды, то без.
    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
