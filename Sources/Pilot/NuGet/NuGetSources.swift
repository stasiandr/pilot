import Foundation

/// Лента пакетов из NuGet.Config — та же, которой пользуются `dotnet restore`,
/// Rider и Visual Studio.
struct NuGetSource: Identifiable, Hashable, Sendable {
    var name: String
    /// Адрес `index.json` ленты v3 (или папка с пакетами).
    var url: String
    var isEnabled = true
    var username: String?
    /// Только `ClearTextPassword`: зашифрованный `Password` NuGet умеет
    /// только в Windows.
    var password: String?
    /// Файл, где лента объявлена.
    var configFile: URL?

    var id: String { name.lowercased() }
    var hasCredentials: Bool { !(username ?? "").isEmpty && !(password ?? "").isEmpty }
    var isNuGetOrg: Bool { URL(string: url)?.host?.lowercased() == "api.nuget.org" }
    /// Лента по http(s), а не папка на диске.
    var isRemote: Bool { url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") }
}

/// NuGet.Config: откуда `dotnet` берёт ленты пакетов и пароли к ним.
///
/// Файлы действуют все сразу: пользовательский `~/.nuget/NuGet/NuGet.Config`
/// и `nuget.config` в папках от корня диска до проекта. Ближний к проекту
/// перекрывает дальний, `<clear />` отбрасывает ленты дальних файлов.
///
/// Пишет Pilot только в пользовательский файл: пароль в файле репозитория
/// ушёл бы в git. Ленту, объявленную в репозитории, это не мешает: пароли
/// NuGet ищет по имени ленты во всех файлах.
///
/// Без AppKit — проверяется тестами ядра.
enum NuGetConfig {
    static var userFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nuget/NuGet/NuGet.Config")
    }

    /// Файлы от дальнего к ближнему: пользовательский, затем папки от корня
    /// диска до `root`.
    static func files(for root: URL?) -> [URL] {
        var chain: [URL] = []
        var directory = root?.standardizedFileURL
        while let current = directory {
            if let name = (try? FileManager.default.contentsOfDirectory(atPath: current.path))?
                .first(where: { $0.lowercased() == "nuget.config" }) {
                chain.append(current.appendingPathComponent(name))
            }
            let parent = current.deletingLastPathComponent()
            directory = parent.path == current.path ? nil : parent
        }
        let user = userFile
        let local = chain.reversed().filter { $0.standardizedFileURL.path != user.standardizedFileURL.path }
        return (FileManager.default.fileExists(atPath: user.path) ? [user] : []) + local
    }

    /// Ленты, которые увидит `dotnet restore` в `root`.
    static func sources(for root: URL?) -> [NuGetSource] {
        merged(files(for: root).compactMap { file in
            (try? Data(contentsOf: file)).map { (file, $0) }
        })
    }

    /// Файлы — от дальнего к ближнему.
    static func merged(_ files: [(URL, Data)]) -> [NuGetSource] {
        var sources: [NuGetSource] = []
        var credentials: [String: (username: String?, password: String?)] = [:]
        var disabled: [String: Bool] = [:]
        for (file, data) in files {
            guard let document = try? XMLDocument(data: data), let root = document.rootElement() else { continue }
            for section in root.elements(forName: "packageSources") {
                for element in section.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                    switch element.name {
                    case "clear":
                        sources.removeAll()
                    case "add":
                        guard let key = element.attribute(forName: "key")?.stringValue,
                              let value = element.attribute(forName: "value")?.stringValue else { continue }
                        let source = NuGetSource(name: key, url: value, configFile: file)
                        if let index = sources.firstIndex(where: { $0.id == source.id }) {
                            sources[index] = source
                        } else {
                            sources.append(source)
                        }
                    case "remove":
                        if let key = element.attribute(forName: "key")?.stringValue {
                            sources.removeAll { $0.id == key.lowercased() }
                        }
                    default:
                        break
                    }
                }
            }
            for section in root.elements(forName: "packageSourceCredentials") {
                for element in section.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                    guard let name = element.name else { continue }
                    let values = settings(of: element)
                    credentials[decodeName(name).lowercased()] = (values["username"], values["cleartextpassword"])
                }
            }
            for section in root.elements(forName: "disabledPackageSources") {
                for element in section.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                    if element.name == "clear" { disabled.removeAll(); continue }
                    guard element.name == "add", let key = element.attribute(forName: "key")?.stringValue else { continue }
                    disabled[key.lowercased()] = element.attribute(forName: "value")?.stringValue?.lowercased() == "true"
                }
            }
        }
        return sources.map { source in
            var source = source
            source.isEnabled = disabled[source.id] != true
            if let found = credentials[source.id] {
                source.username = found.username
                source.password = found.password
            }
            return source
        }
    }

    /// `<add key="…" value="…" />` внутри элемента — словарём, ключи строчными.
    private static func settings(of element: XMLElement) -> [String: String] {
        var result: [String: String] = [:]
        for item in element.elements(forName: "add") {
            if let key = item.attribute(forName: "key")?.stringValue,
               let value = item.attribute(forName: "value")?.stringValue {
                result[key.lowercased()] = value
            }
        }
        return result
    }

    // MARK: - Правка

    enum EditError: LocalizedError {
        case unreadable
        var errorDescription: String? { L("NuGet.Config не разобрать как XML") }
    }

    /// Добавить ленту или поменять её адрес. `credentials`: nil — пароль не
    /// трогать, пустой логин — убрать. `url` nil — только пароль: сама
    /// лента объявлена в другом файле.
    static func upserting(name: String, url: String?, credentials: (username: String, password: String)?,
                          in data: Data?) throws -> Data {
        let document = try self.document(data)
        let root = document.rootElement()!
        if let url {
            let sources = section("packageSources", in: root)
            if let existing = entry(name, in: sources) {
                existing.attribute(forName: "value")?.stringValue = url
            } else {
                let add = XMLElement(name: "add")
                add.addAttribute(XMLNode.attribute(withName: "key", stringValue: name) as! XMLNode)
                add.addAttribute(XMLNode.attribute(withName: "value", stringValue: url) as! XMLNode)
                if url.lowercased().hasSuffix("index.json") {
                    add.addAttribute(XMLNode.attribute(withName: "protocolVersion", stringValue: "3") as! XMLNode)
                }
                sources.addChild(add)
            }
        }
        if let credentials {
            let section = self.section("packageSourceCredentials", in: root)
            for element in section.children?.compactMap({ $0 as? XMLElement }) ?? []
            where element.name.map(decodeName)?.lowercased() == name.lowercased() {
                element.detach()
            }
            if !credentials.username.isEmpty {
                let element = XMLElement(name: encodeName(name))
                for (key, value) in [("Username", credentials.username), ("ClearTextPassword", credentials.password)] {
                    let add = XMLElement(name: "add")
                    add.addAttribute(XMLNode.attribute(withName: "key", stringValue: key) as! XMLNode)
                    add.addAttribute(XMLNode.attribute(withName: "value", stringValue: value) as! XMLNode)
                    element.addChild(add)
                }
                section.addChild(element)
            }
            if section.childCount == 0 { section.detach() }
        }
        return document.xmlData(options: [.nodePrettyPrint])
    }

    /// Убрать ленту вместе с паролем и отметкой «выключена».
    static func removing(name: String, from data: Data) throws -> Data {
        let document = try self.document(data)
        let root = document.rootElement()!
        for sources in root.elements(forName: "packageSources") {
            entry(name, in: sources)?.detach()
        }
        for section in root.elements(forName: "packageSourceCredentials") {
            for element in section.children?.compactMap({ $0 as? XMLElement }) ?? []
            where element.name.map(decodeName)?.lowercased() == name.lowercased() {
                element.detach()
            }
        }
        for section in root.elements(forName: "disabledPackageSources") {
            entry(name, in: section)?.detach()
        }
        return document.xmlData(options: [.nodePrettyPrint])
    }

    /// Выключенная лента остаётся в списке, но `dotnet` её не спрашивает.
    static func settingEnabled(_ enabled: Bool, name: String, in data: Data?) throws -> Data {
        let document = try self.document(data)
        let root = document.rootElement()!
        let section = self.section("disabledPackageSources", in: root)
        entry(name, in: section)?.detach()
        if !enabled {
            let add = XMLElement(name: "add")
            add.addAttribute(XMLNode.attribute(withName: "key", stringValue: name) as! XMLNode)
            add.addAttribute(XMLNode.attribute(withName: "value", stringValue: "true") as! XMLNode)
            section.addChild(add)
        }
        if section.childCount == 0 { section.detach() }
        return document.xmlData(options: [.nodePrettyPrint])
    }

    private static func document(_ data: Data?) throws -> XMLDocument {
        if let data, !data.isEmpty {
            guard let document = try? XMLDocument(data: data), document.rootElement()?.name == "configuration" else {
                throw EditError.unreadable
            }
            return document
        }
        let document = XMLDocument(rootElement: XMLElement(name: "configuration"))
        document.version = "1.0"
        document.characterEncoding = "utf-8"
        return document
    }

    private static func section(_ name: String, in root: XMLElement) -> XMLElement {
        if let existing = root.elements(forName: name).first { return existing }
        let element = XMLElement(name: name)
        root.addChild(element)
        return element
    }

    private static func entry(_ key: String, in section: XMLElement) -> XMLElement? {
        section.elements(forName: "add").first {
            $0.attribute(forName: "key")?.stringValue?.lowercased() == key.lowercased()
        }
    }

    // MARK: - Имена элементов

    /// Имя ленты — имя XML-элемента в `packageSourceCredentials`: пробел и
    /// прочее недопустимое NuGet пишет как `_x0020_` (XmlConvert).
    static func encodeName(_ name: String) -> String {
        var result = ""
        for (index, scalar) in name.unicodeScalars.enumerated() {
            let char = Character(scalar)
            let allowed = char.isLetter || char == "_" || (index > 0 && (char.isNumber || char == "-" || char == "."))
            result += allowed ? String(char) : String(format: "_x%04X_", scalar.value)
        }
        return result
    }

    static func decodeName(_ name: String) -> String {
        guard name.contains("_x") else { return name }
        var result = ""
        var rest = Substring(name)
        while let range = rest.range(of: "_x") {
            result += rest[..<range.lowerBound]
            let after = rest[range.upperBound...]
            if after.count >= 5, after[after.index(after.startIndex, offsetBy: 4)] == "_",
               let code = UInt32(after.prefix(4), radix: 16), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
                rest = after.dropFirst(5)
            } else {
                result += "_x"
                rest = after
            }
        }
        return result + rest
    }
}
