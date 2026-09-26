import Foundation

/// Пакет из поиска nuget.org.
struct NuGetPackage: Identifiable, Hashable {
    var id: String
    var version: String
    var description: String
    var authors: String
    var totalDownloads: Int
    var verified: Bool
    var projectURL: URL?
    var iconURL: URL?
    /// Все опубликованные версии, от новой к старой.
    var versions: [NuGetVersion]

    var latest: NuGetVersion? { NuGetVersion(version) }
}

/// Лента nuget.org по протоколу v3: поиск и список версий. Адреса служб
/// берутся из индекса ленты, как делает сам NuGet, — и на случай, если
/// индекс не ответит, есть известные.
actor NuGetClient {
    static let shared = NuGetClient()

    static let serviceIndex = URL(string: "https://api.nuget.org/v3/index.json")!
    private static let fallbackSearch = URL(string: "https://azuresearch-usnc.nuget.org/query")!
    private static let fallbackPackages = URL(string: "https://api.nuget.org/v3-flatcontainer/")!

    private var searchService: URL?
    private var packageBase: URL?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Pilot"]
        return URLSession(configuration: config)
    }()

    enum Failure: LocalizedError {
        case status(Int)
        var errorDescription: String? {
            switch self {
            case .status(let code): return "nuget.org: HTTP \(code)"
            }
        }
    }

    /// `take` — сколько в ответе; `prerelease` — и предварительные версии.
    func search(_ query: String, prerelease: Bool, skip: Int = 0, take: Int = 40) async throws -> [NuGetPackage] {
        let base = await services().search
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "take", value: String(take)),
            URLQueryItem(name: "prerelease", value: prerelease ? "true" : "false"),
            URLQueryItem(name: "semVerLevel", value: "2.0.0"),
        ]
        let data = try await fetch(components.url!)
        return Self.parseSearch(data)
    }

    /// Точно этот пакет — для установленных: описание и версии.
    func package(_ id: String) async throws -> NuGetPackage? {
        let found = try await search("packageid:" + id, prerelease: true, take: 1)
        return found.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Все версии, включая предварительные и скрытые из поиска.
    func versions(_ id: String) async throws -> [NuGetVersion] {
        let base = await services().packages
        let url = base.appendingPathComponent(id.lowercased()).appendingPathComponent("index.json")
        let data = try await fetch(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["versions"] as? [String] else { return [] }
        return list.compactMap(NuGetVersion.init).sorted(by: >)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await Self.session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.status(http.statusCode)
        }
        return data
    }

    private func services() async -> (search: URL, packages: URL) {
        if let searchService, let packageBase { return (searchService, packageBase) }
        if let data = try? await fetch(Self.serviceIndex) {
            let found = Self.parseServiceIndex(data)
            searchService = found.search
            packageBase = found.packages
        }
        return (searchService ?? Self.fallbackSearch, packageBase ?? Self.fallbackPackages)
    }

    // MARK: - Разбор

    static func parseServiceIndex(_ data: Data) -> (search: URL?, packages: URL?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = object["resources"] as? [[String: Any]] else { return (nil, nil) }
        func first(_ prefix: String) -> URL? {
            resources.lazy
                .filter { ($0["@type"] as? String)?.hasPrefix(prefix) == true }
                .compactMap { ($0["@id"] as? String).flatMap(URL.init(string:)) }
                .first
        }
        var packages = first("PackageBaseAddress")
        // `appendingPathComponent` дописывает к последней части пути —
        // адрес ленты должен кончаться на `/`.
        if let base = packages, !base.absoluteString.hasSuffix("/") {
            packages = URL(string: base.absoluteString + "/")
        }
        return (first("SearchQueryService"), packages)
    }

    static func parseSearch(_ data: Data) -> [NuGetPackage] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let version = item["version"] as? String else { return nil }
            // `authors` — то строка, то массив строк.
            let authors = (item["authors"] as? [String])?.joined(separator: ", ") ?? (item["authors"] as? String) ?? ""
            let versions = ((item["versions"] as? [[String: Any]]) ?? [])
                .compactMap { ($0["version"] as? String).flatMap(NuGetVersion.init) }
                .sorted(by: >)
            return NuGetPackage(
                id: id, version: version,
                description: (item["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                authors: authors,
                totalDownloads: (item["totalDownloads"] as? NSNumber)?.intValue ?? 0,
                verified: item["verified"] as? Bool ?? false,
                projectURL: (item["projectUrl"] as? String).flatMap(URL.init(string:)),
                iconURL: (item["iconUrl"] as? String).flatMap(URL.init(string:)),
                versions: versions)
        }
    }
}
