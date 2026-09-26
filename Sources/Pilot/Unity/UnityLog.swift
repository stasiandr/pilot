import Foundation

/// Строка стека: `Foo:Start () (at Assets/Scripts/Foo.cs:12)` или, у
/// исключений Mono, `at Foo.Start () [0x0001] in /abs/Foo.cs:12`.
struct UnityLogFrame: Hashable {
    var text: String
    /// Как записан: от корня проекта Unity (`Assets/…`, `./Library/…`) или абсолютный.
    var path: String?
    /// С единицы, как в логе.
    var line: Int?

    /// Свой логгер проекта — `Logs.Log:Info`, `UnityConsoleSink:Print`: вести
    /// нужно туда, откуда его позвали, как делает «Jump to caller» в Rider.
    var isLogging: Bool {
        let head = text.prefix { $0 != " " && $0 != "(" }
        return head.split(whereSeparator: { $0 == "." || $0 == ":" }).contains { part in
            part == "Log" || part == "Logs" || part == "Logging" || part.hasSuffix("Logger") || part.hasSuffix("LogSink")
                || part.hasSuffix("LogHandler")
        }
    }

    /// Код самой Unity и `Debug.Log…` — к ним переходить незачем.
    var isEngine: Bool {
        text.hasPrefix("UnityEngine.") || text.hasPrefix("UnityEditor.")
            || path.map { $0.contains("PackageCache/com.unity.") || $0.hasPrefix("/Users/bokken/") } ?? true
    }
}

/// Одно сообщение `Editor.log`: `Debug.Log`, исключение, ошибка компиляции
/// или служебный вывод самой Unity.
struct UnityLogEntry: Identifiable, Hashable {
    enum Level: Int, CaseIterable, Comparable {
        case error, warning, info, system
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    var id: Int
    var level: Level
    /// Текст сообщения без стека; первая строка — заголовок в списке.
    var message: String
    var frames: [UnityLogFrame] = []
    /// Ошибка компиляции: `CS0103` и место.
    var code: String?
    var path: String?
    var line: Int?
    var column: Int?

    var title: String {
        String(message.prefix { $0 != "\n" })
    }

    /// Одинаковые сообщения сворачиваются в одно со счётчиком — как «Collapse» в Unity.
    var collapseKey: String {
        "\(level.rawValue)|\(message)|\(frames.first?.text ?? "")|\(path ?? ""):\(line ?? 0)"
    }

    /// Куда вести по двойному клику: место ошибки компиляции или первый
    /// кадр стека из кода проекта.
    var location: (path: String, line: Int, column: Int?)? {
        if let path, let line { return (path, line, column) }
        let own = frames.filter { !$0.isEngine && $0.path != nil && $0.line != nil }
        if let frame = own.first(where: { !$0.isLogging }) ?? own.first
            ?? frames.first(where: { $0.path != nil && $0.line != nil }) {
            return (frame.path!, frame.line!, nil)
        }
        return nil
    }
}

/// Разбор `~/Library/Logs/Unity/Editor.log`. Unity пишет сообщение, под ним
/// стек и пустую строку; ошибки компилятора — строкой `File.cs(12,5): error CSxxxx: …`;
/// всё остальное — служебный вывод редактора.
enum UnityLog {
    /// Лог редактора на macOS. Один на все открытые Unity: какой проект
    /// в нём пишет, видно по шапке.
    static var editorLog: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Unity/Editor.log")
    }

    /// Проект, чей это лог: `-projectpath` в аргументах командной строки
    /// в шапке или «Successfully changed project path to:».
    static func projectPath(inHeader text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.caseInsensitiveCompare("-projectpath") == .orderedSame, i + 1 < lines.count {
                let value = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, !value.hasPrefix("-") { return value }
            }
            if let range = trimmed.range(of: "Successfully changed project path to:") {
                let value = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Сообщения из куска лога. Кусок — целые блоки: до пустой строки.
    static func parse(_ text: String, firstID: Int = 0) -> [UnityLogEntry] {
        var parser = Parser(nextID: firstID)
        return parser.parse(text)
    }

    /// Разбор кусками, как лог дописывается. Помнит, чем кончился прошлый
    /// кусок: сообщение после хвоста `(Filename: …)` начинается с начала
    /// блока, а после служебного вывода — только последней строкой перед
    /// стеком: пустой строки между ними Unity не пишет.
    struct Parser {
        var nextID = 0
        /// В начале не знаем, что было перед куском, — осторожно: сообщение
        /// только строка перед стеком, остальное служебное.
        var afterMessage = false

        mutating func parse(_ text: String) -> [UnityLogEntry] {
            var out: [UnityLogEntry] = []
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            for block in normalized.components(separatedBy: "\n\n") {
                let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                guard !lines.isEmpty else { continue }
                // `(Filename: Assets/X.cs Line: 12)` — хвост сообщения над ним.
                if lines.count == 1, lines[0].hasPrefix("(Filename:") {
                    afterMessage = true
                    continue
                }
                let found = UnityLog.entries(in: lines, wholeBlockIsMessage: afterMessage)
                afterMessage = found.last.map { !$0.frames.isEmpty } ?? false
                for var entry in found {
                    entry.id = nextID
                    nextID += 1
                    out.append(entry)
                }
            }
            return out
        }
    }

    fileprivate static func entries(in lines: [String], wholeBlockIsMessage: Bool) -> [UnityLogEntry] {
        // Ошибки компилятора — каждая сама по себе; остальное в блоке — служебное.
        if lines.contains(where: { compileDiagnostic($0) != nil }) {
            var out: [UnityLogEntry] = []
            var rest: [String] = []
            func flushRest() {
                if !rest.isEmpty { out.append(UnityLogEntry(id: 0, level: .system, message: rest.joined(separator: "\n"))) }
                rest = []
            }
            for line in lines {
                if let diagnostic = compileDiagnostic(line) {
                    flushRest()
                    out.append(diagnostic)
                } else {
                    rest.append(line)
                }
            }
            flushRest()
            return out
        }

        guard let firstFrame = lines.indices.dropFirst().first(where: { isFrame(lines[$0]) }) else {
            let level: UnityLogEntry.Level = isException(lines[0]) ? .error : .system
            return [UnityLogEntry(id: 0, level: level, message: lines.joined(separator: "\n"))]
        }
        let frames = lines[firstFrame...].map(frame)
        var head = Array(lines[..<firstFrame])
        var out: [UnityLogEntry] = []
        if !wholeBlockIsMessage, head.count > 1 {
            out.append(UnityLogEntry(id: 0, level: .system, message: head.dropLast().joined(separator: "\n")))
            head = [head.last!]
        }
        out.append(UnityLogEntry(id: 0, level: level(message: head[0], frames: frames),
                                 message: head.joined(separator: "\n"), frames: frames))
        return out
    }

    private static func level(message: String, frames: [UnityLogFrame]) -> UnityLogEntry.Level {
        // По вызову `Debug.Log…` в стеке; `Logger:Log` над ним — общий для всех уровней.
        for f in frames where f.text.hasPrefix("UnityEngine.Debug:") {
            let call = f.text
            if call.contains(":LogError") || call.contains(":LogException") || call.contains(":LogAssertion") { return .error }
            if call.contains(":LogWarning") { return .warning }
            if call.contains(":Log") { return .info }
        }
        return isException(message) ? .error : .info
    }

    /// `NullReferenceException: …`, `System.InvalidOperationException: …`.
    static func isException(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let head = line[..<colon]
        return !head.contains(" ") && (head.hasSuffix("Exception") || head.hasSuffix("Error"))
    }

    /// Строка стека: `Namespace.Type:Method (args)` — у Unity двоеточие между
    /// типом и методом, — `at Type.Method () …` у Mono или `… (at path:line)`.
    /// Строго: `[Licensing::Module] Connected (PId: 1)` — не кадр.
    static func isFrame(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(")"), t.range(of: #" \(at .+:\d+\)$"#, options: .regularExpression) != nil { return true }
        if t.hasPrefix("at "), t.contains("(") { return true }
        return t.range(of: framePattern, options: .regularExpression) != nil
    }

    /// `Type:Method (`, `Ns.Type`1:<Lambda>b__0 (`, `Type:.ctor (`.
    private static let framePattern = #"^[A-Za-z_][\w.`<>+,\[\]]*:[\w.`<>|$]+ \("#

    private static let atPattern = try! NSRegularExpression(pattern: #"\(at (.+):(\d+)\)\s*$"#)
    private static let monoPattern = try! NSRegularExpression(pattern: #" in (.+):(\d+)\s*$"#)

    static func frame(_ line: String) -> UnityLogFrame {
        let text = line.trimmingCharacters(in: .whitespaces)
        let ns = text as NSString
        for pattern in [atPattern, monoPattern] {
            if let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: match.range(at: 1))
                if path == "<filename unknown>" || path.hasPrefix("<") { break }
                return UnityLogFrame(text: text, path: path, line: Int(ns.substring(with: match.range(at: 2))))
            }
        }
        return UnityLogFrame(text: text, path: nil, line: nil)
    }

    private static let diagnosticPattern = try! NSRegularExpression(
        pattern: #"^(.+\.cs)\((\d+),(\d+)\): (error|warning) (\w+): (.*)$"#)

    /// `Assets/Foo.cs(12,5): error CS1002: ; expected`.
    static func compileDiagnostic(_ line: String) -> UnityLogEntry? {
        let ns = line as NSString
        guard let m = diagnosticPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        return UnityLogEntry(id: 0, level: group(4) == "error" ? .error : .warning,
                             message: group(6), code: group(5), path: group(1),
                             line: Int(group(2)), column: Int(group(3)))
    }
}
