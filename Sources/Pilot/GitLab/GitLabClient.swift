import Foundation

enum GitLabError: LocalizedError, Equatable {
    case unauthorized
    case forbidden(String)
    case notFound
    case http(Int, String)
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:         return "GitLab не принял токен — возможно, он отозван или истёк"
        case .forbidden(let what):  return "Нет прав: \(what)"
        case .notFound:             return "Не найдено — проект или MR недоступны с этим токеном"
        case .http(let code, let message): return "GitLab ответил \(code): \(message)"
        case .network(let why):     return "Нет связи с GitLab: \(why)"
        case .decoding(let why):    return "Непонятный ответ GitLab: \(why)"
        }
    }
}

/// Тонкий клиент REST API v4. Токен уходит в заголовке `PRIVATE-TOKEN`
/// и больше нигде не появляется — ни в URL, ни в логах.
struct GitLabClient: Sendable {
    let host: String
    let token: String

    private var base: String { "https://\(host)/api/v4" }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    // MARK: - Запросы

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let (data, _) = try await perform("GET", path, query: query)
        return try decode(data)
    }

    /// Все страницы списка: GitLab отдаёт не больше 100 элементов за раз
    /// и пишет номер следующей страницы в `x-next-page`.
    func getAll<T: Decodable>(_ path: String, query: [String: String] = [:], limit: Int = 2000) async throws -> [T] {
        var all: [T] = []
        var page = "1"
        while true {
            var q = query
            q["per_page"] = "100"
            q["page"] = page
            let (data, response) = try await perform("GET", path, query: q)
            all += try decode([T].self, data)
            guard let next = response.value(forHTTPHeaderField: "x-next-page"), !next.isEmpty,
                  all.count < limit else { break }
            page = next
        }
        return all
    }

    @discardableResult
    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        let (data, _) = try await perform(method, path, body: body)
        return try decode(data)
    }

    func sendIgnoringResult(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        _ = try await perform(method, path, body: body)
    }

    func raw(_ path: String, query: [String: String] = [:]) async throws -> Data {
        try await perform("GET", path, query: query).0
    }

    // MARK: - Транспорт

    private func perform(_ method: String, _ path: String, query: [String: String] = [:],
                         body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        // Путь уже закодирован (`projects/group%2Fapp/…`) — URLComponents
        // оставляет его как есть, кодирует только параметры.
        guard var components = URLComponents(string: base + path) else {
            throw GitLabError.network("неверный адрес \(host)")
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw GitLabError.network("неверный адрес \(host)") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw GitLabError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GitLabError.network("нет ответа") }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401:       throw GitLabError.unauthorized
        case 403:       throw GitLabError.forbidden(Self.message(in: data) ?? "\(method) \(path)")
        case 404:       throw GitLabError.notFound
        default:        throw GitLabError.http(http.statusCode, Self.message(in: data) ?? "")
        }
    }

    /// GitLab кладёт текст ошибки в `message` (строкой, массивом или
    /// словарём полей) или в `error`.
    private static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8)
        }
        let value = object["message"] ?? object["error"]
        if let text = value as? String { return text }
        if let list = value as? [String] { return list.joined(separator: "; ") }
        if let fields = value as? [String: Any] {
            return fields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
        }
        return nil
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try decode(T.self, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try GitLabJSON.decoder.decode(type, from: data)
        } catch {
            throw GitLabError.decoding(String(describing: error))
        }
    }
}

// MARK: - Методы API, нужные для ревью

extension GitLabClient {
    private func mrPath(_ project: GitLabRemote, _ iid: Int) -> String {
        "/projects/\(project.encodedProject)/merge_requests/\(iid)"
    }

    func currentUser() async throws -> GLUser {
        try await get("/user")
    }

    func openMergeRequests(_ project: GitLabRemote) async throws -> [GLMergeRequest] {
        try await getAll("/projects/\(project.encodedProject)/merge_requests",
                         query: ["state": "opened", "order_by": "updated_at", "sort": "desc"], limit: 300)
    }

    func mergeRequest(_ project: GitLabRemote, iid: Int) async throws -> GLMergeRequest {
        try await get(mrPath(project, iid))
    }

    func diffs(_ project: GitLabRemote, iid: Int) async throws -> [GLDiff] {
        try await getAll(mrPath(project, iid) + "/diffs")
    }

    func discussions(_ project: GitLabRemote, iid: Int) async throws -> [GLDiscussion] {
        try await getAll(mrPath(project, iid) + "/discussions")
    }

    func approvals(_ project: GitLabRemote, iid: Int) async throws -> GLApprovals {
        try await get(mrPath(project, iid) + "/approvals")
    }

    /// Файл на конкретной ревизии — когда в локальном репозитории её нет.
    func rawFile(_ project: GitLabRemote, path: String, ref: String) async throws -> Data {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: GitLabRemote.unreserved) ?? path
        return try await raw("/projects/\(project.encodedProject)/repository/files/\(encoded)/raw",
                             query: ["ref": ref])
    }

    /// Новый тред. С `position` — к строке кода, без — к MR целиком.
    func createDiscussion(_ project: GitLabRemote, iid: Int, body: String,
                          position: [String: Any]?) async throws -> GLDiscussion {
        var payload: [String: Any] = ["body": body]
        if let position { payload["position"] = position }
        return try await send("POST", mrPath(project, iid) + "/discussions", body: payload)
    }

    func reply(_ project: GitLabRemote, iid: Int, discussion: String, body: String) async throws -> GLNote {
        try await send("POST", mrPath(project, iid) + "/discussions/\(discussion)/notes", body: ["body": body])
    }

    func setResolved(_ project: GitLabRemote, iid: Int, discussion: String, resolved: Bool) async throws -> GLDiscussion {
        try await send("PUT", mrPath(project, iid) + "/discussions/\(discussion)", body: ["resolved": resolved])
    }

    /// `sha` защищает от апрува не той версии: если в MR успели запушить,
    /// GitLab откажет, и ревьюер увидит, что смотрел устаревший код.
    func approve(_ project: GitLabRemote, iid: Int, sha: String?) async throws {
        try await sendIgnoringResult("POST", mrPath(project, iid) + "/approve",
                                     body: sha.map { ["sha": $0] })
    }

    func unapprove(_ project: GitLabRemote, iid: Int) async throws {
        try await sendIgnoringResult("POST", mrPath(project, iid) + "/unapprove")
    }
}
