import Foundation

/// Строка стека .NET: `at Server.Foo.Bar() in /src/Server/Foo.cs:line 42`.
struct ServerLogFrame: Hashable {
    var text: String
    /// Как записан в стеке: у `dotnet run` — абсолютный путь на этой машине.
    var path: String?
    /// С единицы, как в стеке.
    var line: Int?

    /// Код рантайма и библиотек: к нему переходить незачем.
    var isFramework: Bool {
        let method = text.hasPrefix("at ") ? text.dropFirst(3) : Substring(text)
        return ["System.", "Microsoft.", "Serilog.", "Sentry.", "Npgsql.", "MySqlConnector."].contains { method.hasPrefix($0) }
    }
}

/// Одно событие лога сервера — или строка вывода процесса, которая событием не была.
struct ServerLogEntry: Identifiable, Hashable {
    /// Уровни Serilog и `output` — всё, что процесс напечатал мимо логгера:
    /// `dotnet build`, `Console.WriteLine`.
    enum Level: Int, CaseIterable, Comparable {
        case fatal, error, warning, info, debug, verbose, output
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var isProblem: Bool { self == .fatal || self == .error }
    }

    var id: Int
    var level: Level
    /// Время в часовом поясе этой машины: `12:34:56.789`; у вывода нет.
    var time: String?
    var message: String
    /// Где в `message` подставленные значения — в UTF-16, чтобы подсветить их в строке.
    var values: [Range<Int>] = []
    /// Свойства события кроме служебных `@…`: имя → значение, строки — как есть,
    /// остальное — компактным JSON. По имени.
    var properties: [Property] = []
    /// Имена свойств, которые уже видны в тексте сообщения.
    var inMessage: Set<String> = []
    /// Исключение целиком, как его напечатал .NET.
    var exception: String?
    var frames: [ServerLogFrame] = []
    /// `@i` — хеш шаблона сообщения: по нему находится вызов логгера в коде.
    var eventID: UInt32?
    /// `@mt` — сам шаблон, если сервер его пишет.
    var template: String?

    struct Property: Hashable {
        var name: String
        var value: String
    }

    var title: String {
        String(message.prefix { $0 != "\n" })
    }

    /// Свойства, которых в тексте сообщения нет, — их показываем рядом.
    var extraProperties: [Property] {
        properties.filter { !inMessage.contains($0.name) && $0.name != "SourceContext" }
    }

    /// `Server.Networking.UdpServer` → `UdpServer`.
    var source: String? {
        guard let context = properties.first(where: { $0.name == "SourceContext" })?.value else { return nil }
        return context.split(separator: ".").last.map(String.init)
    }

    /// Заголовок исключения: `System.InvalidOperationException: …`. Если он
    /// уже есть в тексте сообщения (`Log.Error("Failed: " + e)`) — nil,
    /// повторять незачем.
    var exceptionTitle: String? {
        guard let exception else { return nil }
        let header = exception.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.hasPrefix("at ") && !$0.hasPrefix("--- ") }
        guard let header, !header.isEmpty, !message.contains(header) else { return nil }
        return header.hasPrefix("---> ") ? String(header.dropFirst(5)) : header
    }

    /// Одинаковые события сворачиваются в одно со счётчиком.
    var collapseKey: String {
        "\(level.rawValue)|\(message)|\(exceptionTitle ?? "")|\(frames.first?.text ?? "")"
    }

    /// Где случилась ошибка: первый кадр из кода проекта. У .NET первыми
    /// идут кадры самого внутреннего исключения — того, что бросили первым.
    var location: (path: String, line: Int)? {
        let frame = frames.first { !$0.isFramework && $0.path != nil && $0.line != nil }
            ?? frames.first { $0.path != nil && $0.line != nil }
        guard let frame, let path = frame.path, let line = frame.line else { return nil }
        return (path, line)
    }

    /// Для поиска и копирования: всё, что видно в консоли, одним текстом.
    var searchText: String {
        var parts = [message]
        parts += properties.map { "\($0.name)=\($0.value)" }
        if let exception { parts.append(exception) }
        return parts.joined(separator: "\n")
    }
}

/// Разбор вывода сервера. Serilog пишет в консоль либо по JSON-объекту на
/// строку (CLEF: `RenderedCompactJsonFormatter`, `CompactJsonFormatter`),
/// либо текстом по шаблону `[12:34:56 INF] Сообщение` и исключением
/// следующими строками. Всё прочее — вывод процесса как есть.
///
/// Куски приходят как попало, строка может разорваться между ними:
/// недописанная ждёт следующего куска или `finish()`.
struct ServerLogParser {
    var timeZone: TimeZone = .current
    private(set) var nextID = 0
    private var pending = ""
    /// Последнее событие, к которому ещё могут дописываться строки исключения.
    private var open: ServerLogEntry?

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    /// Новые события по порядку. Текстовое событие может дополниться стеком
    /// следующими строками — тогда оно придёт ещё раз с тем же `id`, и его
    /// надо заменить: ждать, пока сервер напишет что-то ещё, нельзя —
    /// последняя строка простаивающего сервера так и не показалась бы.
    mutating func feed(_ text: String) -> [ServerLogEntry] {
        pending += text
        // `\r\n` для Swift — одна буква, отдельно от `\n`.
        guard let lastNewline = pending.lastIndex(where: Self.isLineBreak) else { return [] }
        let complete = pending[..<lastNewline]
        pending = String(pending[pending.index(after: lastNewline)...])
        var out: [ServerLogEntry] = []
        for line in complete.split(omittingEmptySubsequences: false, whereSeparator: Self.isLineBreak) {
            consume(String(line), into: &out)
        }
        if let open, out.last?.id != open.id { out.append(open) }
        return out
    }

    /// Процесс завершился: недописанная строка и открытое событие — наружу.
    mutating func finish() -> [ServerLogEntry] {
        var out: [ServerLogEntry] = []
        if !pending.isEmpty {
            consume(pending, into: &out)
            pending = ""
        }
        if let open { out.append(open) }
        open = nil
        return out
    }

    private static func isLineBreak(_ c: Character) -> Bool { c == "\n" || c == "\r\n" }

    private mutating func consume(_ line: String, into out: inout [ServerLogEntry]) {
        if var entry = open, Self.continuesException(line, of: entry) {
            entry.exception = (entry.exception.map { $0 + "\n" } ?? "") + line
            if let frame = Self.frame(line) { entry.frames.append(frame) }
            open = entry
            return
        }
        if let entry = open { out.append(entry) }
        open = nil
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        if var entry = Self.parseJSON(line, timeZone: timeZone) ?? Self.parseText(line) {
            entry.id = nextID
            nextID += 1
            // Текстовое событие ещё может получить стек следующими строками.
            if entry.exception == nil, !line.hasPrefix("{") { open = entry } else { out.append(entry) }
            return
        }
        // `Unhandled exception. System.X: …` от рантайма или `Console.WriteLine(e)`:
        // стек следующими строками — одним событием с ним.
        if Self.isExceptionHeader(line) {
            open = ServerLogEntry(id: nextID, level: line.hasPrefix("Unhandled exception.") ? .fatal : .error, message: line)
            nextID += 1
            return
        }
        out.append(ServerLogEntry(id: nextID, level: .output, message: line))
        nextID += 1
    }

    /// `System.InvalidOperationException: …`, в том числе после `Unhandled exception. `.
    static func isExceptionHeader(_ line: String) -> Bool {
        var text = Substring(line)
        if text.hasPrefix("Unhandled exception. ") { text = text.dropFirst("Unhandled exception. ".count) }
        guard let colon = text.firstIndex(of: ":") else { return false }
        let type = text[..<colon]
        return type.contains(".") && !type.contains(" ") && (type.hasSuffix("Exception") || type.hasSuffix("Error"))
    }

    /// Строки исключения под текстовым событием: заголовок сразу под ним,
    /// дальше кадры `at …`, `---> Inner`, `--- End of …`.
    private static func continuesException(_ line: String, of entry: ServerLogEntry) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("at ") && line.first == " " { return true }
        if trimmed.hasPrefix("--->") || (trimmed.hasPrefix("--- ") && trimmed.hasSuffix("---")) { return true }
        // `System.InvalidOperationException: …` — только первой строкой после события.
        if entry.exception == nil, let colon = trimmed.firstIndex(of: ":") {
            let type = trimmed[..<colon]
            return !type.contains(" ") && (type.hasSuffix("Exception") || type.hasSuffix("Error"))
        }
        return false
    }

    // MARK: - Текст: `[12:34:56 INF] Сообщение`

    private static let textLevels: [String: ServerLogEntry.Level] = [
        "VRB": .verbose, "DBG": .debug, "INF": .info, "WRN": .warning, "ERR": .error, "FTL": .fatal,
    ]

    static func parseText(_ line: String) -> ServerLogEntry? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let head = line[line.index(after: line.startIndex)..<close].split(separator: " ")
        guard head.count == 2, let level = textLevels[String(head[1])],
              head[0].count >= 8, head[0].allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." }) else { return nil }
        var message = line[line.index(after: close)...]
        if message.hasPrefix(" ") { message = message.dropFirst() }
        return ServerLogEntry(id: 0, level: level, time: String(head[0]), message: String(message))
    }

    // MARK: - CLEF

    private static let clefLevels: [String: ServerLogEntry.Level] = [
        "Verbose": .verbose, "Debug": .debug, "Information": .info,
        "Warning": .warning, "Error": .error, "Fatal": .fatal,
    ]

    static func parseJSON(_ line: String, timeZone: TimeZone = .current) -> ServerLogEntry? {
        guard line.hasPrefix("{"), line.hasSuffix("}"),
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["@t"] is String, object["@m"] != nil || object["@mt"] != nil else { return nil }

        var raw: [String: Any] = [:]
        for (key, value) in object where !key.hasPrefix("@") || key.hasPrefix("@@") {
            raw[key.hasPrefix("@@") ? String(key.dropFirst()) : key] = value
        }

        var entry = ServerLogEntry(id: 0, level: clefLevels[object["@l"] as? String ?? "Information"] ?? .info, message: "")
        entry.time = (object["@t"] as? String).flatMap { clockTime($0, timeZone: timeZone) }
        entry.properties = raw.keys.sorted().map { .init(name: $0, value: display(raw[$0]!)) }

        entry.eventID = (object["@i"] as? String).flatMap { UInt32($0, radix: 16) }
        entry.template = object["@mt"] as? String
        if let template = entry.template {
            (entry.message, entry.values, entry.inMessage) = render(template: template, properties: raw)
        } else if let rendered = object["@m"] as? String {
            (entry.message, entry.values, entry.inMessage) = unquote(rendered: rendered, properties: raw)
        }

        if let exception = object["@x"] as? String, !exception.isEmpty {
            entry.exception = exception.replacingOccurrences(of: "\r\n", with: "\n")
            entry.frames = entry.exception!.split(separator: "\n").compactMap { frame(String($0)) }
        } else {
            splitStack(&entry)
        }
        return entry
    }

    /// Стек прямо в тексте: `Log.Error("Failed: " + e)`, `Log.Error(e.ToString())`,
    /// `$"… {exception}"`. Сообщение — до первой строки стека, остальное — исключение.
    static func splitStack(_ entry: inout ServerLogEntry) {
        let lines = entry.message.components(separatedBy: "\n")
        guard lines.count > 1, let start = lines.indices.dropFirst().first(where: { i in
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            return (trimmed.hasPrefix("at ") && lines[i].first == " ") || trimmed.hasPrefix("---> ") || isExceptionHeader(trimmed)
        }) else { return }
        let message = lines[..<start].joined(separator: "\n")
        let stack = lines[start...].joined(separator: "\n")
        entry.frames = lines[start...].compactMap { frame($0) }
        guard !entry.frames.isEmpty else { return }
        entry.message = message
        entry.exception = stack
        let length = message.utf16.count
        entry.values = entry.values.filter { $0.upperBound <= length }
    }

    /// `2026-09-26T20:15:03.5312345Z` → `23:15:03.531` в поясе этой машины.
    static func clockTime(_ stamp: String, timeZone: TimeZone) -> String? {
        let scalars = Array(stamp.utf8)
        guard scalars.count >= 19 else { return nil }
        var rest = stamp.dropFirst(19)
        var millis = 0
        if rest.hasPrefix(".") {
            let digits = rest.dropFirst().prefix { $0.isNumber }
            millis = Int((digits + "000").prefix(3)) ?? 0
            rest = rest.dropFirst(1 + digits.count)
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: String(stamp.prefix(19)) + (rest.isEmpty ? "Z" : String(rest))) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis)
    }

    /// `RenderedCompactJsonFormatter` отдаёт готовый текст, где строки в
    /// кавычках: `Player "stas" joined`. Кавычки снимаем, а подставленные
    /// значения находим по свойствам — их подсветит консоль.
    static func unquote(rendered: String, properties: [String: Any]) -> (String, [Range<Int>], Set<String>) {
        var matches: [(range: Range<String.Index>, text: String, name: String)] = []
        for name in properties.keys.sorted() {
            let value = properties[name]!
            let needle: String, text: String, wholeWord: Bool
            if let string = value as? String {
                needle = "\"" + string.replacingOccurrences(of: "\"", with: "\\\"") + "\""
                text = string
                wholeWord = false
            } else if value is NSNumber {
                needle = serilogText(value)
                text = needle
                wholeWord = true
            } else {
                continue
            }
            if let range = firstFree(needle, in: rendered, taken: matches.map(\.range), wholeWord: wholeWord) {
                matches.append((range, text, name))
            }
        }
        matches.sort { $0.range.lowerBound < $1.range.lowerBound }
        var out = ""
        var values: [Range<Int>] = []
        var cursor = rendered.startIndex
        for match in matches {
            out += rendered[cursor..<match.range.lowerBound]
            let start = out.utf16.count
            out += match.text
            values.append(start..<out.utf16.count)
            cursor = match.range.upperBound
        }
        out += rendered[cursor...]
        return (out, values, Set(matches.map(\.name)))
    }

    /// `CompactJsonFormatter` отдаёт шаблон и свойства отдельно: подставляем сами,
    /// строки — без кавычек.
    static func render(template: String, properties: [String: Any]) -> (String, [Range<Int>], Set<String>) {
        var out = ""
        var values: [Range<Int>] = []
        var used: Set<String> = []
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            let next = template.index(after: i)
            if (c == "{" || c == "}"), next < template.endIndex, template[next] == c {
                out.append(c)
                i = template.index(after: next)
                continue
            }
            if c == "{", let close = template[next...].firstIndex(of: "}") {
                var name = Substring(template[next..<close])
                if name.hasPrefix("@") || name.hasPrefix("$") { name = name.dropFirst() }
                if let cut = name.firstIndex(where: { $0 == ":" || $0 == "," }) { name = name[..<cut] }
                if let value = properties[String(name)] {
                    let text = display(value)
                    let start = out.utf16.count
                    out += text
                    values.append(start..<out.utf16.count)
                    used.insert(String(name))
                } else {
                    out += template[i...close]
                }
                i = template.index(after: close)
                continue
            }
            out.append(c)
            i = next
        }
        return (out, values, used)
    }

    private static func firstFree(_ needle: String, in text: String, taken: [Range<String.Index>],
                                  wholeWord: Bool = false) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        var from = text.startIndex
        while let range = text.range(of: needle, range: from..<text.endIndex) {
            let overlaps = taken.contains { $0.overlaps(range) }
            let isWord = !wholeWord || (
                (range.lowerBound == text.startIndex || !isWordCharacter(text[text.index(before: range.lowerBound)]))
                && (range.upperBound == text.endIndex || !isWordCharacter(text[range.upperBound])))
            if !overlaps && isWord { return range }
            from = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }

    private static func utf16Range(_ range: Range<String.Index>, in text: String) -> Range<Int> {
        let lower = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        return lower..<(lower + text.utf16.distance(from: range.lowerBound, to: range.upperBound))
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Как Serilog печатает значение в сообщении: `True`, а не `true`.
    private static func serilogText(_ value: Any) -> String {
        if isBool(value) { return (value as! NSNumber).boolValue ? "True" : "False" }
        return display(value)
    }

    /// Строка — как есть, `null` — словом, остальное — компактным JSON.
    static func display(_ value: Any) -> String {
        if let string = value as? String { return string }
        if value is NSNull { return "null" }
        if isBool(value) { return (value as! NSNumber).boolValue ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return text
    }

    // MARK: - Стек

    /// `   at Server.Foo.Bar() in /src/Server/Foo.cs:line 42`.
    static func frame(_ line: String) -> ServerLogFrame? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("at ") else { return nil }
        guard let marker = text.range(of: " in ", options: .backwards),
              let lineMarker = text.range(of: ":line ", options: .backwards, range: marker.upperBound..<text.endIndex),
              let number = Int(text[lineMarker.upperBound...].prefix { $0.isNumber }) else {
            return ServerLogFrame(text: text)
        }
        return ServerLogFrame(text: text, path: String(text[marker.upperBound..<lineMarker.lowerBound]), line: number)
    }
}
