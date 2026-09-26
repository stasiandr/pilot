import SwiftUI
import AppKit

/// Лог сервера в консоли запуска: события Serilog списком, как консоль Unity.
/// Слева — время, уровень и сообщение с подсвеченными значениями, справа —
/// выбранное целиком: свойства и стек, строки стека кликабельны.
struct ServerLogView: View {
    @ObservedObject var store: ServerLogStore
    /// Корень проекта — от него относительные пути в стеке.
    let root: URL?
    let open: (URL, Int) -> Void

    @AppStorage("pilot.serverLog.errors") private var showsErrors = true
    @AppStorage("pilot.serverLog.warnings") private var showsWarnings = true
    @AppStorage("pilot.serverLog.info") private var showsInfo = true
    @AppStorage("pilot.serverLog.debug") private var showsDebug = true
    @AppStorage("pilot.serverLog.output") private var showsOutput = true
    @AppStorage("pilot.serverLog.collapse") private var collapses = false
    @State private var search = ""
    @State private var selection: Int?

    private struct Row: Identifiable {
        var entry: ServerLogEntry
        var count: Int
        var id: Int { entry.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
            content
        }
    }

    // MARK: - Фильтры

    private var filters: some View {
        var counts: [ServerLogEntry.Level: Int] = [:]
        for entry in store.entries { counts[entry.level, default: 0] += 1 }
        return HStack(spacing: 8) {
            levelToggle($showsErrors, icon: "xmark.octagon.fill", color: Theme.diagnosticError,
                        count: (counts[.fatal] ?? 0) + (counts[.error] ?? 0), help: L("Ошибки и исключения"))
            levelToggle($showsWarnings, icon: "exclamationmark.triangle.fill", color: Theme.diagnosticWarning,
                        count: counts[.warning] ?? 0, help: L("Предупреждения"))
            levelToggle($showsInfo, icon: "info.circle.fill", color: Theme.assetLink,
                        count: counts[.info] ?? 0, help: "Information")
            levelToggle($showsDebug, icon: "ladybug.fill", color: Theme.foldMarker,
                        count: (counts[.debug] ?? 0) + (counts[.verbose] ?? 0), help: "Debug, Verbose")
            levelToggle($showsOutput, icon: "terminal.fill", color: Theme.foldMarker,
                        count: counts[.output] ?? 0, help: L("Вывод процесса мимо логгера: сборка, Console.WriteLine"))
            Toggle(isOn: $collapses) { Text(L("Свернуть повторы")) }
                .toggleStyle(.button)
                .help(L("Одинаковые сообщения — одной строкой со счётчиком"))
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(L("Фильтр"), text: $search).textFieldStyle(.plain).frame(width: 160)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    private func levelToggle(_ isOn: Binding<Bool>, icon: String, color: NSColor, count: Int, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).foregroundStyle(Color(nsColor: color))
                Text(count > 9999 ? "9999+" : String(count)).monospacedDigit()
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(isOn.wrappedValue ? Color(nsColor: Theme.separator) : .clear))
            .opacity(isOn.wrappedValue ? 1 : 0.45)
        }
        .help(help)
    }

    private func isShown(_ level: ServerLogEntry.Level) -> Bool {
        switch level {
        case .fatal, .error: return showsErrors
        case .warning: return showsWarnings
        case .info: return showsInfo
        case .debug, .verbose: return showsDebug
        case .output: return showsOutput
        }
    }

    private var rows: [Row] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let visible = store.entries.filter { entry in
            isShown(entry.level) && (needle.isEmpty || entry.searchText.localizedCaseInsensitiveContains(needle))
        }
        guard collapses else { return visible.map { Row(entry: $0, count: 1) } }
        var order: [String] = []
        var grouped: [String: Row] = [:]
        for entry in visible {
            let key = entry.collapseKey
            if grouped[key] == nil { order.append(key); grouped[key] = Row(entry: entry, count: 0) }
            grouped[key]!.count += 1
        }
        return order.compactMap { grouped[$0] }
    }

    // MARK: - События

    private var content: some View {
        let rows = self.rows
        let selected = selection.flatMap { id in store.entries.first { $0.id == id } }
        return HSplitView {
            ScrollViewReader { proxy in
                List(rows, selection: $selection) { row in
                    ServerLogRow(entry: row.entry, count: row.count)
                        .tag(row.id)
                        .id(row.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 18)
                .onChange(of: store.entries.last) { _, _ in
                    // Держимся низа, пока ничего не выбрано.
                    if selection == nil, let id = rows.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    let picked = store.entries.filter { ids.contains($0.id) }
                    let single = picked.count == 1 ? picked.first : nil
                    Button(L("Перейти к записи лога")) { single.flatMap(logURL).map { open($0.url, $0.line) } }
                        .disabled(single.flatMap(logURL) == nil)
                    Button(L("Перейти к месту ошибки")) { single.flatMap(errorURL).map { open($0.url, $0.line) } }
                        .disabled(single.flatMap(errorURL) == nil)
                    Divider()
                    Button(L("Скопировать")) { copy(picked) }
                        .disabled(picked.isEmpty)
                } primaryAction: { ids in
                    if let id = ids.first, let entry = store.entries.first(where: { $0.id == id }) { go(entry) }
                }
                .overlay {
                    if rows.isEmpty {
                        Text(store.entries.isEmpty ? L("Сообщений пока нет") : L("Всё скрыто фильтрами"))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(minWidth: 360, idealWidth: 640)
            detail(selected)
                .frame(minWidth: 240, idealWidth: 340)
        }
    }

    @ViewBuilder
    private func detail(_ entry: ServerLogEntry?) -> some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        LevelIcon(level: entry.level)
                        Text(entry.level.name).fontWeight(.medium)
                        if let time = entry.time { Text(time).foregroundStyle(.secondary) }
                        if let source = entry.properties.first(where: { $0.name == "SourceContext" })?.value {
                            Text(source).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    Text(ServerLogRow.highlighted(entry))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let site = logURL(entry) {
                        placeLink(L("Записано"), url: site.url, line: site.line)
                    }
                    if let place = errorURL(entry) {
                        placeLink(L("Место ошибки"), url: place.url, line: place.line)
                    }
                    if !entry.properties.isEmpty {
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                            ForEach(entry.properties, id: \.name) { property in
                                GridRow {
                                    Text(property.name)
                                        .foregroundStyle(Color(nsColor: Theme.foldMarker))
                                    Text(property.value)
                                        .foregroundStyle(Color(nsColor: Theme.color(.string)))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                    if let exception = entry.exception {
                        Divider()
                        exceptionView(exception)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(L("Выберите сообщение — здесь будут свойства и стек; двойной клик — к строке, которая его записала, или к месту ошибки"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Исключение как его печатает .NET: заголовки красным, кадры своего кода —
    /// ссылками, рантайм и служебные строки — приглушённо.
    private func exceptionView(_ exception: String) -> some View {
        let lines = exception.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let frame = ServerLogParser.frame(line) {
                    frameView(frame)
                } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("--- ") {
                    Text(line.trimmingCharacters(in: .whitespaces))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(line.trimmingCharacters(in: .whitespaces))
                        .foregroundStyle(Color(nsColor: Theme.diagnosticError))
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    @ViewBuilder
    private func frameView(_ frame: ServerLogFrame) -> some View {
        if let path = frame.path, let line = frame.line, let url = fileURL(for: path) {
            Button { open(url, line) } label: {
                (Text(frame.text.hasPrefix("at ") ? String(frame.text.dropFirst(3)) : frame.text)
                    + Text("  \((path as NSString).lastPathComponent):\(line)").foregroundColor(.secondary))
                    .foregroundStyle(Color(nsColor: frame.isFramework ? Theme.foldMarker : Theme.assetLink))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .help("\(path):\(line)")
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        } else {
            Text(frame.text.hasPrefix("at ") ? String(frame.text.dropFirst(3)) : frame.text)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.leading, 12)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileURL(for path: String) -> URL? {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if let root {
            url = root.appendingPathComponent(path)
        } else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
    }

    /// Двойной клик: у события с исключением — туда, где оно случилось,
    /// у остальных — к вызову логгера, который его написал.
    private func go(_ entry: ServerLogEntry) {
        guard let place = errorURL(entry) ?? logURL(entry) else { NSSound.beep(); return }
        open(place.url, place.line)
    }

    private func errorURL(_ entry: ServerLogEntry) -> (url: URL, line: Int)? {
        guard let location = entry.location, let url = fileURL(for: location.path) else { return nil }
        return (url, location.line)
    }

    private func logURL(_ entry: ServerLogEntry) -> (url: URL, line: Int)? {
        guard let site = store.sites.site(for: entry), let url = fileURL(for: site.path) else { return nil }
        return (url, site.line)
    }

    /// `Записано  StartUp.cs:62` — ссылкой.
    private func placeLink(_ label: String, url: URL, line: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Button { open(url, line) } label: {
                Text("\(url.lastPathComponent):\(line)")
                    .foregroundStyle(Color(nsColor: Theme.assetLink))
            }
            .buttonStyle(.plain)
            .help(root.map { url.path.replacingOccurrences(of: $0.path + "/", with: "") } ?? url.path)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func copy(_ entries: [ServerLogEntry]) {
        let text = entries.map { entry -> String in
            var head = [entry.time, entry.level == .output ? nil : entry.level.short].compactMap { $0 }
            head.append(entry.message)
            var lines = [head.joined(separator: " ")]
            if !entry.extraProperties.isEmpty {
                lines[0] += "  " + entry.extraProperties.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
            }
            if let exception = entry.exception { lines.append(exception) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Строка списка: `12:34:56.789 ⓘ [Source] Сообщение  key=value  ×3`.
private struct ServerLogRow: View {
    let entry: ServerLogEntry
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.time ?? "            ")
                .foregroundStyle(.tertiary)
            if entry.level == .output {
                Text(entry.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                LevelIcon(level: entry.level)
                line
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if count > 1 {
                Text(String(count))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color(nsColor: Theme.separator)))
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var line: Text {
        var text = Text("")
        if let source = entry.source {
            text = text + Text("[\(source)] ").foregroundColor(Color(nsColor: Theme.foldMarker))
        }
        text = text + Text(Self.highlighted(entry, firstLineOnly: true))
        let extras = entry.extraProperties
        if !extras.isEmpty {
            var tail = AttributedString("   ")
            for (i, property) in extras.enumerated() {
                var key = AttributedString((i > 0 ? " " : "") + property.name + "=")
                key.foregroundColor = Color(nsColor: Theme.foldMarker)
                var value = AttributedString(property.value)
                value.foregroundColor = Color(nsColor: Theme.color(.string)).opacity(0.8)
                tail += key + value
            }
            text = text + Text(tail)
        }
        if let exception = entry.exceptionTitle {
            text = text + Text("   " + exception).foregroundColor(Color(nsColor: Theme.diagnosticError))
        }
        return text
    }

    /// Сообщение, в котором подставленные значения выделены цветом.
    static func highlighted(_ entry: ServerLogEntry, firstLineOnly: Bool = false) -> AttributedString {
        let message = firstLineOnly ? entry.title : entry.message
        var result = AttributedString(message)
        let base: Color = entry.level.isProblem ? Color(nsColor: Theme.diagnosticError)
            : entry.level >= .debug ? .secondary : .primary
        result.foregroundColor = base
        let utf16 = message.utf16
        for range in entry.values where range.upperBound <= utf16.count {
            guard let lower = utf16.index(utf16.startIndex, offsetBy: range.lowerBound, limitedBy: utf16.endIndex)
                    .flatMap({ String.Index($0, within: message) }),
                  let upper = utf16.index(utf16.startIndex, offsetBy: range.upperBound, limitedBy: utf16.endIndex)
                    .flatMap({ String.Index($0, within: message) }),
                  let from = AttributedString.Index(lower, within: result),
                  let to = AttributedString.Index(upper, within: result) else { continue }
            result[from..<to].foregroundColor = Color(nsColor: Theme.color(.string))
        }
        return result
    }
}

private struct LevelIcon: View {
    let level: ServerLogEntry.Level

    var body: some View {
        switch level {
        case .fatal:
            Image(systemName: "flame.fill").foregroundStyle(Color(nsColor: Theme.diagnosticError))
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(nsColor: Theme.diagnosticError))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
        case .info:
            Image(systemName: "info.circle.fill").foregroundStyle(Color(nsColor: Theme.assetLink))
        case .debug, .verbose:
            Image(systemName: "ladybug").foregroundStyle(Color(nsColor: Theme.foldMarker))
        case .output:
            Image(systemName: "terminal").foregroundStyle(.tertiary)
        }
    }
}

extension ServerLogEntry.Level {
    /// Как в тексте Serilog: `INF`, `WRN`.
    var short: String {
        switch self {
        case .fatal: return "FTL"
        case .error: return "ERR"
        case .warning: return "WRN"
        case .info: return "INF"
        case .debug: return "DBG"
        case .verbose: return "VRB"
        case .output: return "OUT"
        }
    }

    var name: String {
        switch self {
        case .fatal: return "Fatal"
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Information"
        case .debug: return "Debug"
        case .verbose: return "Verbose"
        case .output: return "Output"
        }
    }
}
