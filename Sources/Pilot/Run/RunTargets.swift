import Foundation

/// То, что запускает кнопка ▶: строка для shell пользователя, папка и
/// добавочные переменные окружения. Строкой, а не массивом аргументов:
/// так её можно показать в консоли и переписать руками в `.pilot/run.json`.
struct RunTarget: Hashable, Identifiable {
    var name: String
    var command: String
    /// От корня проекта; пусто — сам корень.
    var directory: String = ""
    var environment: [String: String] = [:]

    var id: String { name }
}

/// Откуда Pilot берёт цели запуска. Сначала то, что описано руками
/// в `.pilot/run.json`, потом приложения .NET: у проекта `<OutputType>Exe`,
/// и это не тесты. Первым среди них — проект, названный как решение
/// (`Server.sln` → `Server.csproj`): обычно его и запускают.
enum RunTargets {
    static let configPath = ".pilot/run.json"

    /// Обход неглубокий: .csproj лежат в двух-трёх уровнях от решения,
    /// а в `node_modules` и `Library` Unity их искать незачем.
    static let maxDepth = 4
    static let skippedDirectories: Set<String> = [
        "bin", "obj", "node_modules", "Library", "Temp", "Logs", "Packages", "packages", "build", "Build",
    ]

    static func discover(root: URL) -> [RunTarget] {
        var configured: [RunTarget] = []
        if let data = try? Data(contentsOf: root.appendingPathComponent(configPath)) {
            configured = parseConfig(data) ?? []
        }
        let (projects, solutions) = scan(root: root)
        var dotnet: [RunTarget] = []
        for path in projects {
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { continue }
            if let target = dotnetTarget(projectPath: path, contents: text) { dotnet.append(target) }
        }
        return merge(configured: configured, dotnet: order(dotnet, solutions: solutions))
    }

    /// Что поменялось на диске настолько, что список целей стоит собрать заново.
    static func isRelevant(_ path: String) -> Bool {
        path.hasSuffix(".csproj") || path.hasSuffix(".sln") || path.hasSuffix("/" + configPath)
    }

    // MARK: - .pilot/run.json

    /// ```json
    /// { "targets": [ { "name": "Server", "command": "dotnet run --project Server",
    ///                  "cwd": "", "env": { "SERVER_NAME": "local" } } ] }
    /// ```
    /// Можно и просто массивом целей. `command` — строка для shell или
    /// массив аргументов. Цель без имени или команды пропускается.
    static func parseConfig(_ data: Data) -> [RunTarget]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list: [Any]
        if let object = json as? [String: Any], let targets = object["targets"] as? [Any] {
            list = targets
        } else if let array = json as? [Any] {
            list = array
        } else {
            return nil
        }
        return list.compactMap { item in
            guard let object = item as? [String: Any],
                  let name = object["name"] as? String, !name.isEmpty else { return nil }
            let command: String
            if let line = object["command"] as? String {
                command = line
            } else if let args = object["command"] as? [String], !args.isEmpty {
                command = args.map(shellQuoted).joined(separator: " ")
            } else {
                return nil
            }
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let directory = (object["cwd"] as? String) ?? (object["directory"] as? String) ?? ""
            var environment: [String: String] = [:]
            for (key, value) in (object["env"] as? [String: Any]) ?? [:] {
                if let string = value as? String { environment[key] = string }
                else if let number = value as? NSNumber { environment[key] = number.stringValue }
            }
            return RunTarget(name: name, command: command, directory: directory, environment: environment)
        }
    }

    /// Файл, с которого удобно начать: найденные цели, уже записанные так,
    /// как Pilot их запустил бы.
    static func configTemplate(for targets: [RunTarget]) -> String {
        let entries = targets.map { target -> [String: Any] in
            var entry: [String: Any] = ["name": target.name, "command": target.command]
            if !target.directory.isEmpty { entry["cwd"] = target.directory }
            entry["env"] = target.environment
            return entry
        }
        let object: [String: Any] = ["targets": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{ \"targets\": [] }\n" }
        return text + "\n"
    }

    // MARK: - .NET

    /// nil — библиотека, тесты или не .NET вовсе.
    static func dotnetTarget(projectPath: String, contents: String) -> RunTarget? {
        guard let outputType = element("OutputType", in: contents)?.lowercased(),
              outputType == "exe" || outputType == "winexe" else { return nil }
        if contents.contains("Microsoft.NET.Test.Sdk")
            || element("IsTestProject", in: contents)?.lowercased() == "true" { return nil }

        var command = "dotnet run --project " + shellQuoted(projectPath)
        if let configuration = macConfiguration(element("Configurations", in: contents)) {
            command += " -c " + shellQuoted(configuration)
        }
        let file = (projectPath as NSString).lastPathComponent
        let name = (file as NSString).deletingPathExtension
        return RunTarget(name: name, command: command)
    }

    /// У проектов, которые собирают и под Windows, и под Unix, бывают свои
    /// конфигурации для второго: `Debug UNIX`, `Debug Mac`. Без них
    /// `dotnet run` взял бы `Debug` — сборку под Windows.
    static func macConfiguration(_ list: String?) -> String? {
        guard let list else { return nil }
        let names = list.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let markers = ["unix", "mac", "osx", "posix"]
        return names.first { name in
            let lower = name.lowercased()
            return lower.hasPrefix("debug") && markers.contains { lower.contains($0) }
        }
    }

    /// Проект, названный как решение, — первым; дальше мельче и по имени.
    /// Одинаковые имена в разных папках различаются папкой.
    static func order(_ targets: [RunTarget], solutions: [String]) -> [RunTarget] {
        let solutionNames = Set(solutions.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        func depth(_ t: RunTarget) -> Int { projectPath(of: t)?.split(separator: "/").count ?? 0 }
        let sorted = targets.sorted { a, b in
            let aMain = solutionNames.contains(a.name), bMain = solutionNames.contains(b.name)
            if aMain != bMain { return aMain }
            if depth(a) != depth(b) { return depth(a) < depth(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var seen: [String: Int] = [:]
        for t in sorted { seen[t.name, default: 0] += 1 }
        return sorted.map { t in
            guard seen[t.name, default: 0] > 1, let path = projectPath(of: t) else { return t }
            var renamed = t
            renamed.name = "\(t.name) (\((path as NSString).deletingLastPathComponent))"
            return renamed
        }
    }

    /// Описанное руками главнее: цель с тем же именем заменяет найденную.
    static func merge(configured: [RunTarget], dotnet: [RunTarget]) -> [RunTarget] {
        let names = Set(configured.map(\.name))
        return configured + dotnet.filter { !names.contains($0.name) }
    }

    private static func projectPath(of target: RunTarget) -> String? {
        guard let range = target.command.range(of: "--project ") else { return nil }
        let rest = target.command[range.upperBound...]
        let quoted = rest.hasPrefix("'")
        let body = quoted ? rest.dropFirst() : rest
        let end = body.firstIndex(of: quoted ? "'" : " ") ?? body.endIndex
        return String(body[..<end])
    }

    /// Первое `<name>значение</name>` — .csproj читается как текст:
    /// XML-парсер ради трёх полей был бы и медленнее, и строже, чем надо.
    static func element(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>", options: .caseInsensitive),
              let close = text.range(of: "</\(name)>", options: .caseInsensitive,
                                     range: open.upperBound..<text.endIndex) else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Обход

    /// Пути от корня: проекты и решения.
    static func scan(root: URL) -> (projects: [String], solutions: [String]) {
        var projects: [String] = [], solutions: [String] = []
        let fm = FileManager.default
        func walk(_ relative: String, depth: Int) {
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = relative.isEmpty ? name : relative + "/" + name
                if name.hasSuffix(".csproj") { projects.append(path); continue }
                if name.hasSuffix(".sln") { solutions.append(path); continue }
                guard depth < maxDepth, !skippedDirectories.contains(name) else { continue }
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    walk(path, depth: depth + 1)
                }
            }
        }
        walk("", depth: 1)
        return (projects, solutions)
    }
}

/// Вывод процесса в текст для консоли. Куски приходят как попало: буква
/// UTF-8 или escape-последовательность цвета могут разорваться между
/// двумя чтениями — недописанный хвост ждёт следующего куска.
struct ConsoleDecoder {
    private var pending: [UInt8] = []

    mutating func feed(_ data: Data) -> String {
        var bytes = pending + data
        pending = []
        let keep = incompleteTail(bytes)
        if keep > 0 {
            pending = Array(bytes.suffix(keep))
            bytes.removeLast(keep)
        }
        return Self.clean(String(decoding: bytes, as: UTF8.self))
    }

    /// Остаток, который выпустить пока нельзя: начатая буква UTF-8 или
    /// начатая escape-последовательность.
    private func incompleteTail(_ bytes: [UInt8]) -> Int {
        var tail = 0
        // Буква UTF-8: ведущий байт, за которым меньше продолжений, чем он обещает.
        var i = bytes.count - 1
        var continuation = 0
        while i >= 0, bytes.count - i <= 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 { continuation += 1; i -= 1; continue }
            let need = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : b >= 0xC0 ? 1 : 0
            if need > continuation { tail = continuation + 1 }
            break
        }
        // ESC без завершающего байта в последних 32 байтах.
        if let esc = bytes.suffix(32).lastIndex(of: 0x1B) {
            let sequence = bytes[esc...]
            if !Self.isComplete(Array(sequence)) { tail = max(tail, bytes.count - esc) }
        }
        return tail
    }

    private static func isComplete(_ sequence: [UInt8]) -> Bool {
        guard sequence.count >= 2 else { return false }
        switch sequence[1] {
        case UInt8(ascii: "["):
            return sequence.dropFirst(2).contains { (0x40...0x7E).contains($0) }
        case UInt8(ascii: "]"):
            return sequence.contains(0x07) || sequence.dropFirst(2).contains(UInt8(ascii: "\\"))
        default:
            return true
        }
    }

    /// Цвета и прочие управляющие последовательности убираются; `\r\n` —
    /// перевод строки, одинокий `\r` (строка прогресса) — тоже.
    static func clean(_ text: String) -> String {
        guard text.contains("\u{1B}") || text.contains("\r") else { return text }
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var lookahead: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let l = lookahead { lookahead = nil; return l }
            return scalars.next()
        }
        while let c = next() {
            switch c {
            case "\u{1B}":
                guard let kind = next() else { break }
                if kind == "[" {
                    while let s = next(), !(0x40...0x7E).contains(s.value) {}
                } else if kind == "]" {
                    while let s = next() {
                        if s == "\u{07}" { break }
                        if s == "\u{1B}" { _ = next(); break }
                    }
                }
            case "\r":
                let following = next()
                out.append("\n")
                if let following, following != "\n" { lookahead = following }
            default:
                out.append(c)
            }
        }
        return String(out)
    }
}
