import Foundation

/// Какой проект GitLab стоит за репозиторием — по адресу его remote.
///
/// Хост из remote — это хост git, а не API: у self-hosted GitLab они обычно
/// совпадают, но SSH может жить на отдельном имени. Поэтому хост API
/// пользователь может поправить при подключении, а здесь — лишь догадка.
struct GitLabRemote: Equatable, Sendable {
    var host: String
    /// `group/subgroup/project` — без `.git` и без слешей по краям.
    var projectPath: String

    /// Путь проекта в URL API: GitLab принимает его вместо числового id,
    /// если слеши закодированы (`group%2Fproject`).
    var encodedProject: String {
        projectPath.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? projectPath
    }

    var webURL: URL? { URL(string: "https://\(host)/\(projectPath)") }

    /// Символы, которые в сегменте пути URL не кодируются. Слеш — кодируется.
    static let unreserved = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// Разбирает три формы адреса:
    /// `git@host:group/project.git`, `ssh://git@host:2222/group/project.git`
    /// и `https://host/group/project.git` (с логином и паролем в адресе тоже).
    static func parse(_ remote: String) -> GitLabRemote? {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var host: String
        var path: String
        if text.contains("://") {
            guard let url = URLComponents(string: text), let urlHost = url.host, !urlHost.isEmpty else { return nil }
            host = urlHost
            path = url.path
        } else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            // scp-подобная форма: [user@]host:path
            let authority = text[..<colon]
            host = String(authority.split(separator: "@").last ?? authority)
            path = String(text[text.index(after: colon)...])
        } else {
            return nil   // локальный путь
        }

        host = host.lowercased()
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // У проекта GitLab минимум два сегмента: владелец и имя.
        guard !host.isEmpty, path.split(separator: "/").count >= 2 else { return nil }
        return GitLabRemote(host: host, projectPath: path)
    }
}
