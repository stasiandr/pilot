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

/// Релиз на GitHub — то, что из ответа `releases/latest` нужно обновлению.
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

    /// Разбор ответа API. Тег не версия — релиз не наш формат, его не предлагаем.
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
