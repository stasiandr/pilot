import Foundation

/// Пакет из поиска по лентам.
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
    /// Имя ленты, где нашёлся.
    var source = "nuget.org"
    var isFromNuGetOrg = true

    var latest: NuGetVersion? { NuGetVersion(version) }
}

/// Ленты проекта по протоколу v3: поиск и список версий по всем включённым
/// сразу. Свой у каждого окна NuGet: у проектов бывают свои nuget.config.
actor NuGetClient {
    private var feeds: [NuGetFeed] = [NuGetFeed(source: NuGetClient.nugetOrg)]

    static let nugetOrg = NuGetSource(name: "nuget.org", url: NuGetFeed.nugetOrgIndex.absoluteString)

    /// Ленты из NuGet.Config. Без единой — nuget.org, как у `dotnet`.
    func setSources(_ sources: [NuGetSource]) {
        let wanted = sources.isEmpty ? [Self.nugetOrg] : sources.filter { $0.isEnabled && $0.isRemote }
        feeds = wanted.map { source in feeds.first { $0.source == source } ?? NuGetFeed(source: source) }
    }

    /// Найденное во всех лентах: сначала свои, потом nuget.org — свои пакеты
    /// там и ищут. Пакет из нескольких лент — один, версии складываются.
    /// `failures` — какие ленты не ответили и почему.
    func search(_ query: String, prerelease: Bool, take: Int = 40)
        async -> (packages: [NuGetPackage], failures: [String]) {
        let ordered = feeds.filter { !$0.source.isNuGetOrg } + feeds.filter { $0.source.isNuGetOrg }
        var found: [Int: [NuGetPackage]] = [:]
        var failures: [Int: String] = [:]
        await withTaskGroup(of: (Int, Result<[NuGetPackage], Error>).self) { group in
            for (index, feed) in ordered.enumerated() {
                group.addTask {
                    do { return (index, .success(try await feed.search(query, prerelease: prerelease, take: take))) }
                    catch { return (index, .failure(error)) }
                }
            }
            for await (index, result) in group {
                switch result {
                case .success(let packages): found[index] = packages
                case .failure(let error): failures[index] = error.localizedDescription
                }
            }
        }
        var merged: [NuGetPackage] = []
        for index in ordered.indices {
            for package in found[index] ?? [] {
                if let existing = merged.firstIndex(where: { $0.id.caseInsensitiveCompare(package.id) == .orderedSame }) {
                    merged[existing].versions = Array(Set(merged[existing].versions + package.versions)).sorted(by: >)
                } else {
                    merged.append(package)
                }
            }
        }
        return (merged, ordered.indices.compactMap { failures[$0] })
    }

    /// Точно этот пакет — для установленных: описание и версии. Из первой
    /// ленты, где он есть.
    func package(_ id: String) async -> NuGetPackage? {
        let ordered = feeds.filter { !$0.source.isNuGetOrg } + feeds.filter { $0.source.isNuGetOrg }
        for feed in ordered {
            if let found = try? await feed.package(id) { return found }
        }
        return nil
    }

    /// Все версии из всех лент, включая предварительные и скрытые из поиска.
    /// nil — ни одна лента не ответила.
    func versions(_ id: String) async -> [NuGetVersion]? {
        let feeds = self.feeds
        var all: Set<NuGetVersion> = []
        var answered = false
        await withTaskGroup(of: [NuGetVersion]?.self) { group in
            for feed in feeds { group.addTask { try? await feed.versions(id) } }
            for await found in group {
                guard let found else { continue }
                answered = true
                all.formUnion(found)
            }
        }
        return answered ? all.sorted(by: >) : nil
    }
}

/// Одна лента v3. Адреса служб берутся из её `index.json`, как делает сам
/// NuGet, — у nuget.org на случай, если индекс не ответит, есть известные.
/// Логин и пароль — Basic-авторизацией, как у `dotnet`.
actor NuGetFeed {
    let source: NuGetSource

    static let nugetOrgIndex = URL(string: "https://api.nuget.org/v3/index.json")!
    private static let fallbackSearch = URL(string: "https://azuresearch-usnc.nuget.org/query")!
    private static let fallbackPackages = URL(string: "https://api.nuget.org/v3-flatcontainer/")!

    private var searchService: URL?
    private var packageBase: URL?
    /// Индекс уже прочитан: служб, которых в нём нет, и не будет.
    private var resolved = false

    init(source: NuGetSource) {
        self.source = source
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Pilot"]
        return URLSession(configuration: config)
    }()

    enum Failure: LocalizedError {
        case unauthorized(String)
        case status(String, Int)
        case noSearch(String)
        var errorDescription: String? {
            switch self {
            case .unauthorized(let name): return L("\(name): нужен логин и токен")
            case .status(let name, let code): return "\(name): HTTP \(code)"
            case .noSearch(let name): return L("\(name): лента не умеет искать")
            }
        }
    }

    /// `take` — сколько в ответе; `prerelease` — и предварительные версии.
    func search(_ query: String, prerelease: Bool, skip: Int = 0, take: Int = 40) async throws -> [NuGetPackage] {
        guard let base = try await services().search else { throw Failure.noSearch(source.name) }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "take", value: String(take)),
            URLQueryItem(name: "prerelease", value: prerelease ? "true" : "false"),
            URLQueryItem(name: "semVerLevel", value: "2.0.0"),
        ]
        let data = try await fetch(components.url!)
        return NuGetClient.parseSearch(data, source: source)
    }

    /// Точно этот пакет. `packageid:` понимает nuget.org; другие ленты ищут
    /// по тексту — тогда из найденного берём совпадающий по имени.
    func package(_ id: String) async throws -> NuGetPackage? {
        func exact(_ list: [NuGetPackage]) -> NuGetPackage? {
            list.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        }
        if let found = exact(try await search("packageid:" + id, prerelease: true, take: 1)) { return found }
        guard !source.isNuGetOrg else { return nil }
        return exact(try await search(id, prerelease: true, take: 20))
    }

    /// Все версии пакета в ленте; пакета нет — пусто.
    func versions(_ id: String) async throws -> [NuGetVersion] {
        guard let base = try await services().packages else { return [] }
        let url = base.appendingPathComponent(id.lowercased()).appendingPathComponent("index.json")
        let data: Data
        do {
            data = try await fetch(url)
        } catch Failure.status(_, 404) {
            return []
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["versions"] as? [String] else { return [] }
        return list.compactMap(NuGetVersion.init).sorted(by: >)
    }

    /// Отвечает ли лента с этими логином и паролем: для проверки в окне.
    /// Одного индекса мало — GitLab отдаёт его и без логина, а пускать
    /// не пускает: спрашиваем поиск.
    func check() async throws {
        resolved = false
        let found = try await services(strict: true)
        if found.search != nil {
            _ = try await search("", prerelease: false, take: 1)
        } else if found.packages != nil {
            _ = try await versions("pilot.source.check")
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        if source.hasCredentials, let username = source.username, let password = source.password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw Failure.unauthorized(source.name) }
            throw Failure.status(source.name, http.statusCode)
        }
        return data
    }

    private func services(strict: Bool = false) async throws -> (search: URL?, packages: URL?) {
        if !resolved {
            let index = URL(string: source.url) ?? Self.nugetOrgIndex
            do {
                let found = NuGetClient.parseServiceIndex(try await fetch(index))
                searchService = found.search
                packageBase = found.packages
                resolved = true
            } catch {
            // Без индекса nuget.org всё равно ответит по известным адресам;
            // чужая лента — нет, и её ошибку лучше показать.
                if strict || !source.isNuGetOrg { throw error }
            }
        }
        if source.isNuGetOrg {
            return (searchService ?? Self.fallbackSearch, packageBase ?? Self.fallbackPackages)
        }
        return (searchService, packageBase)
    }
}

extension NuGetClient {
    // MARK: - Разбор

    nonisolated static func parseServiceIndex(_ data: Data) -> (search: URL?, packages: URL?) {
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

    nonisolated static func parseSearch(_ data: Data, source: NuGetSource = NuGetClient.nugetOrg) -> [NuGetPackage] {
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
                versions: versions,
                source: source.name,
                isFromNuGetOrg: source.isNuGetOrg)
        }
    }
}
