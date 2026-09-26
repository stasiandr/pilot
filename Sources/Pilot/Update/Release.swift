import Foundation

/// Версия Pilot: `0.2.1` из `CFBundleShortVersionString` и тег релиза `v0.2.1`.
/// Недостающие числа — нули: `0.2` и `0.2.0` одна и та же версия.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let parts: [Int]

    init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let numbers = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = numbers.map { $0! }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    private static func padded(_ a: AppVersion, _ b: AppVersion) -> ([Int], [Int]) {
        let n = max(a.parts.count, b.parts.count)
        return (a.parts + Array(repeating: 0, count: n - a.parts.count),
                b.parts + Array(repeating: 0, count: n - b.parts.count))
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        let (x, y) = padded(a, b)
        return x == y
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let (x, y) = padded(a, b)
        return x.lexicographicallyPrecedes(y)
    }
}

/// Откуда сборка берёт обновления — строка `PilotUpdateSource` в Info.plist:
///
/// * `github:owner/repo` — GitHub Releases, без токена (публичный репозиторий);
/// * `gitlab:host/group/project` — GitLab Releases; токен — тот же, что Pilot
///   хранит для ревью мерж-реквестов на этом хосте. Так форк для своей
///   команды обновляется из её GitLab, а не из апстрима.
enum UpdateSource: Equatable, Sendable {
    case github(repository: String)
    case gitlab(host: String, project: String)

    init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let path = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        switch parts[0] {
        case "github":
            guard path.split(separator: "/").count == 2 else { return nil }
            self = .github(repository: path)
        case "gitlab":
            let pieces = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard pieces.count == 2, !pieces[1].isEmpty else { return nil }
            self = .gitlab(host: pieces[0], project: pieces[1])
        default:
            return nil
        }
    }

    /// Последний релиз.
    var latestURL: URL {
        switch self {
        case .github(let repository):
            return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        case .gitlab(let host, let project):
            let encoded = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? project
            return URL(string: "https://\(host)/api/v4/projects/\(encoded)/releases/permalink/latest")!
        }
    }

    /// Страница релизов — если в ответе своей нет.
    var releasesPage: URL {
        switch self {
        case .github(let repository): return URL(string: "https://github.com/\(repository)/releases/latest")!
        case .gitlab(let host, let project): return URL(string: "https://\(host)/\(project)/-/releases")!
        }
    }

    /// Хост, чей токен нужен; у GitHub — никакого.
    var tokenHost: String? {
        if case .gitlab(let host, _) = self { return host }
        return nil
    }
}

/// Релиз — то, что из ответа API о последнем релизе нужно обновлению.
struct ReleaseInfo: Equatable, Sendable {
    let version: AppVersion
    /// Страница релиза: что нового и ручное скачивание.
    let page: URL
    let notes: String
    /// Zip со сборкой под эту архитектуру; нет — обновиться можно только руками.
    let archive: URL?

    /// Архитектура в имени архива — как её пишет `dist.sh` (`uname -m`).
    static var currentArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// Разбор ответа GitLab (`releases/permalink/latest`): архивы — ссылки
    /// в `assets.links`.
    static func parseGitLab(_ data: Data, arch: String = currentArch) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let version = AppVersion(tag),
              let page = ((json["_links"] as? [String: Any])?["self"] as? String).flatMap(URL.init(string:))
        else { return nil }
        if json["upcoming_release"] as? Bool == true { return nil }
        let links = (json["assets"] as? [String: Any])?["links"] as? [[String: Any]] ?? []
        let archive = links.first { ($0["name"] as? String)?.hasSuffix("-\(arch).zip") == true }
            .flatMap { ($0["direct_asset_url"] as? String) ?? ($0["url"] as? String) }
            .flatMap(URL.init(string:))
        return ReleaseInfo(version: version, page: page, notes: json["description"] as? String ?? "", archive: archive)
    }

    /// Разбор ответа GitHub. Тег не версия — релиз не наш формат, его не предлагаем.
    static func parse(_ data: Data, arch: String = currentArch) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let version = AppVersion(tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let archive = assets.first { ($0["name"] as? String)?.hasSuffix("-\(arch).zip") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        return ReleaseInfo(version: version, page: page, notes: json["body"] as? String ?? "", archive: archive)
    }
}
