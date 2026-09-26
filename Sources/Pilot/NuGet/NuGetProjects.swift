import Foundation

/// Версия пакета NuGet: `1.2.3`, `1.2.3.4`, `2.0.0-beta.1+sha`. Сравнение —
/// как у NuGet: числа по порядку (недостающие — нули), релиз старше любой
/// своей предварительной, метки сравниваются по частям через точку —
/// числовые как числа и младше буквенных. Всё после `+` не учитывается.
struct NuGetVersion: Comparable, Hashable, CustomStringConvertible {
    let numbers: [Int]
    let prerelease: [String]
    /// Как написано — таким и уходит в `dotnet add … --version`.
    let text: String

    var isPrerelease: Bool { !prerelease.isEmpty }
    var description: String { text }

    init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespaces)
        let core = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let release = parts.first, !release.isEmpty else { return nil }
        let numbers = release.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.map { $0! }
        self.prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        guard parts.count == 1 || !prerelease.isEmpty else { return nil }
        self.text = text
    }

    static func == (a: NuGetVersion, b: NuGetVersion) -> Bool {
        compare(a, b) == .orderedSame
    }

    func hash(into hasher: inout Hasher) {
        var trimmed = numbers
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease.map { $0.lowercased() })
    }

    static func < (a: NuGetVersion, b: NuGetVersion) -> Bool {
        compare(a, b) == .orderedAscending
    }

    private static func compare(_ a: NuGetVersion, _ b: NuGetVersion) -> ComparisonResult {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        if a.prerelease.isEmpty != b.prerelease.isEmpty {
            return a.prerelease.isEmpty ? .orderedDescending : .orderedAscending
        }
        for i in 0..<max(a.prerelease.count, b.prerelease.count) {
            guard i < a.prerelease.count else { return .orderedAscending }
            guard i < b.prerelease.count else { return .orderedDescending }
            let x = a.prerelease[i], y = b.prerelease[i]
            switch (Int(x), Int(y)) {
            case let (m?, n?):
                if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            case (nil, nil):
                let order = x.compare(y, options: .caseInsensitive)
                if order != .orderedSame { return order }
            }
        }
        return .orderedSame
    }

    /// Что предложить обновлением к `current`: самая новая стабильная, а если
    /// и так стоит предварительная — самая новая вообще. nil — новее нет.
    static func update(for current: NuGetVersion, among versions: [NuGetVersion]) -> NuGetVersion? {
        let candidates = current.isPrerelease ? versions : versions.filter { !$0.isPrerelease }
        guard let newest = candidates.max(), newest > current else { return nil }
        return newest
    }
}

/// Пакет, на который ссылается проект.
struct NuGetReference: Hashable {
    var id: String
    /// Как записано: `13.0.3`, диапазон `[1.0,2.0)`, `$(Version)`. nil —
    /// версии в проекте нет (её задаёт Directory.Packages.props).
    var version: String?
    /// Версия из Directory.Packages.props — централизованное управление.
    var isCentral = false

    /// Версия, с которой можно сравнивать: точная, без диапазона и свойств.
    var resolved: NuGetVersion? {
        guard var text = version?.trimmingCharacters(in: .whitespaces) else { return nil }
        // `[1.2.3]` — ровно эта версия.
        if text.hasPrefix("["), text.hasSuffix("]"), !text.contains(",") {
            text = String(text.dropFirst().dropLast())
        }
        return NuGetVersion(text)
    }
}

/// Проект .NET в SDK-стиле и его пакеты.
struct NuGetProject: Identifiable, Hashable {
    /// От корня: `Server/Server.csproj`.
    var path: String
    var references: [NuGetReference]
    /// `net8.0`, `netstandard2.1;net8.0`.
    var frameworks: String?

    var id: String { path }
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    func reference(_ id: String) -> NuGetReference? {
        references.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
}

/// Проекты и их пакеты — из текста .csproj и Directory.Packages.props.
/// Правит их не Pilot, а `dotnet add/remove package`: он знает про
/// централизованные версии, условия и restore.
enum NuGetProjects {
    static let centralFile = "Directory.Packages.props"

    static func discover(root: URL) -> [NuGetProject] {
        let (paths, _) = RunTargets.scan(root: root)
        var central: [String: [String: String]] = [:]
        return paths.compactMap { path in
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8),
                  isSDKStyle(text) else { return nil }
            let directory = (path as NSString).deletingLastPathComponent
            let versions: [String: String]
            if let cached = central[directory] {
                versions = cached
            } else {
                versions = centralVersions(for: directory, root: root)
                central[directory] = versions
            }
            var references = packageReferences(in: text)
            for i in references.indices where references[i].version == nil {
                if let version = versions[references[i].id.lowercased()] {
                    references[i].version = version
                    references[i].isCentral = true
                }
            }
            let frameworks = RunTargets.element("TargetFrameworks", in: text) ?? RunTargets.element("TargetFramework", in: text)
            return NuGetProject(path: path, references: references, frameworks: frameworks)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Что поменялось на диске настолько, что пакеты стоит перечитать.
    static func isRelevant(_ path: String) -> Bool {
        path.hasSuffix(".csproj") || path.hasSuffix("/" + centralFile) || path.hasSuffix(".props")
    }

    /// `<Project Sdk="Microsoft.NET.Sdk">`. Проекты Unity — старого вида:
    /// их генерирует редактор, и пакеты NuGet в них не ставят.
    static func isSDKStyle(_ text: String) -> Bool {
        guard let open = text.range(of: "<Project") else { return false }
        let tagEnd = text[open.upperBound...].firstIndex(of: ">") ?? text.endIndex
        return text[open.upperBound..<tagEnd].contains("Sdk=") || text.contains("<Sdk ")
    }

    /// `<PackageReference Include="Id" Version="1.0" />` и та же ссылка
    /// с `<Version>` внутри. `Update=` не добавляет пакет — пропускается.
    static func packageReferences(in text: String) -> [NuGetReference] {
        let plain = withoutComments(text)
        var out: [NuGetReference] = []
        for element in elements(named: "PackageReference", in: plain) {
            guard let id = element.attributes["include"], !id.isEmpty else { continue }
            let version = element.attributes["version"] ?? element.attributes["versionoverride"]
                ?? element.body.flatMap { RunTargets.element("Version", in: $0) }
            if !out.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
                out.append(NuGetReference(id: id, version: version))
            }
        }
        return out
    }

    /// `<PackageVersion Include="Id" Version="1.0" />` — ключи в нижнем регистре:
    /// идентификаторы NuGet регистр не различают.
    static func packageVersions(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        for element in elements(named: "PackageVersion", in: withoutComments(text)) {
            guard let id = element.attributes["include"] ?? element.attributes["update"],
                  let version = element.attributes["version"]
                    ?? element.body.flatMap({ RunTargets.element("Version", in: $0) }) else { continue }
            out[id.lowercased()] = version
        }
        return out
    }

    /// MSBuild берёт ближайший Directory.Packages.props вверх от проекта.
    static func centralVersions(for directory: String, root: URL) -> [String: String] {
        var components = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        while true {
            let relative = (components + [centralFile]).joined(separator: "/")
            if let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) {
                return packageVersions(in: text)
            }
            guard !components.isEmpty else { return [:] }
            components.removeLast()
        }
    }

    // MARK: - Разбор

    struct Element {
        /// Имена — в нижнем регистре: MSBuild их регистр не различает.
        var attributes: [String: String]
        /// Между открывающим и закрывающим тегом; nil — тег закрыт сам (`/>`).
        var body: String?
    }

    static func elements(named name: String, in text: String) -> [Element] {
        var out: [Element] = []
        var cursor = text.startIndex
        while let open = text.range(of: "<" + name, options: .caseInsensitive, range: cursor..<text.endIndex) {
            cursor = open.upperBound
            // `<PackageReferences>` — другой тег.
            guard cursor < text.endIndex, text[cursor].isWhitespace || text[cursor] == "/" || text[cursor] == ">" else { continue }
            guard let close = tagEnd(in: text, from: cursor) else { break }
            let inside = text[cursor..<close]
            let selfClosing = inside.hasSuffix("/")
            let attributes = parseAttributes(String(selfClosing ? inside.dropLast() : inside))
            cursor = text.index(after: close)
            var body: String?
            if !selfClosing {
                if let end = text.range(of: "</" + name, options: .caseInsensitive, range: cursor..<text.endIndex) {
                    body = String(text[cursor..<end.lowerBound])
                    cursor = end.upperBound
                } else {
                    body = ""
                }
            }
            out.append(Element(attributes: attributes, body: body))
        }
        return out
    }

    /// `>` тега, не считая стоящих в кавычках значений атрибутов.
    private static func tagEnd(in text: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i = text.index(after: i)
        }
        return nil
    }

    static func parseAttributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var name = ""
            while i < chars.count, chars[i] != "=", !chars[i].isWhitespace { name.append(chars[i]); i += 1 }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count, chars[i] == "=" else { if !name.isEmpty { continue } else { i += 1; continue } }
            i += 1
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count, chars[i] == "\"" || chars[i] == "'" else { continue }
            let quote = chars[i]
            i += 1
            var value = ""
            while i < chars.count, chars[i] != quote { value.append(chars[i]); i += 1 }
            i += 1
            if !name.isEmpty { out[name.lowercased()] = unescape(value) }
        }
        return out
    }

    private static func unescape(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func withoutComments(_ text: String) -> String {
        guard text.contains("<!--") else { return text }
        var out = ""
        var cursor = text.startIndex
        while let open = text.range(of: "<!--", range: cursor..<text.endIndex) {
            out += text[cursor..<open.lowerBound]
            guard let close = text.range(of: "-->", range: open.upperBound..<text.endIndex) else { return out }
            cursor = close.upperBound
        }
        return out + text[cursor...]
    }

    // MARK: - Команды

    /// `dotnet add 'App/App.csproj' package Id --version 1.0`. Без версии
    /// dotnet берёт последнюю стабильную.
    static func addCommand(project: String, id: String, version: String?) -> String {
        var command = "dotnet add " + RunTargets.shellQuoted(project) + " package " + RunTargets.shellQuoted(id)
        if let version { command += " --version " + RunTargets.shellQuoted(version) }
        return command
    }

    static func removeCommand(project: String, id: String) -> String {
        "dotnet remove " + RunTargets.shellQuoted(project) + " package " + RunTargets.shellQuoted(id)
    }
}
