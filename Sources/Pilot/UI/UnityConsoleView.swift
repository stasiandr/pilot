import SwiftUI
import AppKit

/// Консоль Unity под редактором, как окно Console в самой Unity: слева
/// сообщения с фильтрами по уровню, справа — выбранное целиком со стеком.
/// Строки стека и места ошибок компиляции кликабельны.
struct UnityConsolePanel: View {
    @ObservedObject var console: UnityConsole
    let open: (URL, Int, Int?) -> Void

    @AppStorage("pilot.unityConsoleHeight") private var height: Double = 240
    @AppStorage("pilot.unityConsole.errors") private var showsErrors = true
    @AppStorage("pilot.unityConsole.warnings") private var showsWarnings = true
    @AppStorage("pilot.unityConsole.info") private var showsInfo = true
    @AppStorage("pilot.unityConsole.system") private var showsSystem = false
    @AppStorage("pilot.unityConsole.collapse") private var collapses = false
    @State private var search = ""
    @State private var selection: Int?
    @State private var dragStart: Double?

    /// Строка списка: сообщение и сколько раз оно повторилось.
    private struct Row: Identifiable {
        var entry: UnityLogEntry
        var count: Int
        var id: Int { entry.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
            if console.isForeign {
                foreignNotice
            } else if console.isMissing {
                notice(L("Unity ещё не писала Editor.log"), UnityLog.editorLog.path)
            } else {
                content
            }
        }
        .frame(height: CGFloat(height))
        .background(Color(nsColor: Theme.chromeBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
        .overlay(alignment: .top) { resizeHandle }
    }

    // MARK: - Шапка

    private var header: some View {
        let counts = Dictionary(grouping: console.isForeign ? [] : console.entries, by: \.level).mapValues(\.count)
        return HStack(spacing: 8) {
            Image(systemName: "cube.fill")
                .foregroundStyle(Color(nsColor: Theme.unityEvent))
            Text(L("Консоль Unity")).fontWeight(.medium).foregroundStyle(.primary)
            Divider().frame(height: 14)
            levelToggle($showsErrors, icon: "xmark.octagon.fill", color: Theme.diagnosticError,
                        count: counts[.error] ?? 0, help: L("Ошибки и исключения"))
            levelToggle($showsWarnings, icon: "exclamationmark.triangle.fill", color: Theme.diagnosticWarning,
                        count: counts[.warning] ?? 0, help: L("Предупреждения"))
            levelToggle($showsInfo, icon: "info.circle.fill", color: Theme.assetLink,
                        count: counts[.info] ?? 0, help: "Debug.Log")
            levelToggle($showsSystem, icon: "gearshape.fill", color: Theme.foldMarker,
                        count: counts[.system] ?? 0, help: L("Служебный вывод редактора"))
            Toggle(isOn: $collapses) { Text(L("Свернуть повторы")) }
                .toggleStyle(.button)
                .help(L("Одинаковые сообщения — одной строкой со счётчиком"))
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(L("Фильтр"), text: $search).textFieldStyle(.plain).frame(width: 150)
            }
            Button { console.clear(); selection = nil } label: { Image(systemName: "trash") }
                .help(L("Очистить"))
            Button { console.isVisible = false } label: { Image(systemName: "xmark") }
                .help(KeymapStore.shared.help(L("Скрыть консоль Unity"), .unityConsole))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func levelToggle(_ isOn: Binding<Bool>, icon: String, color: NSColor, count: Int, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).foregroundStyle(Color(nsColor: color))
                Text(count > 999 ? "999+" : String(count)).monospacedDigit()
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(isOn.wrappedValue ? Color(nsColor: Theme.separator) : .clear))
            .opacity(isOn.wrappedValue ? 1 : 0.45)
        }
        .help(help)
    }

    // MARK: - Сообщения

    private var rows: [Row] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let visible = console.entries.filter { entry in
            switch entry.level {
            case .error: guard showsErrors else { return false }
            case .warning: guard showsWarnings else { return false }
            case .info: guard showsInfo else { return false }
            case .system: guard showsSystem else { return false }
            }
            return needle.isEmpty || entry.message.localizedCaseInsensitiveContains(needle)
                || (entry.path?.localizedCaseInsensitiveContains(needle) ?? false)
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

    private var content: some View {
        let rows = self.rows
        let selected = selection.flatMap { id in console.entries.first { $0.id == id } }
        return HSplitView {
            ScrollViewReader { proxy in
                List(rows, selection: $selection) { row in
                    EntryRow(entry: row.entry, count: row.count)
                        .tag(row.id)
                        .id(row.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: console.entries.last?.id) { _, id in
                    // Держимся низа, пока ничего не выбрано, — как Unity.
                    if selection == nil, let id = rows.last?.id ?? id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    let picked = console.entries.filter { ids.contains($0.id) }
                    Button(L("Скопировать")) { copy(picked) }
                        .disabled(picked.isEmpty)
                } primaryAction: { ids in
                    if let id = ids.first, let entry = console.entries.first(where: { $0.id == id }) { go(entry) }
                }
                .overlay {
                    if rows.isEmpty {
                        Text(console.entries.isEmpty ? L("Сообщений пока нет") : L("Всё скрыто фильтрами"))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 520)
            detail(selected)
                .frame(minWidth: 260)
        }
    }

    @ViewBuilder
    private func detail(_ entry: UnityLogEntry?) -> some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.message)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let path = entry.path, let line = entry.line {
                        link("\(path):\(line)", path: path, line: line, column: entry.column, dim: false)
                    }
                    if !entry.frames.isEmpty {
                        Divider()
                        ForEach(Array(entry.frames.enumerated()), id: \.offset) { _, frame in
                            if let path = frame.path, let line = frame.line, console.fileURL(for: path) != nil {
                                link(frame.text, path: path, line: line, column: nil, dim: frame.isEngine)
                            } else {
                                Text(frame.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(L("Выберите сообщение — здесь будет стек; двойной клик — к месту в коде"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func link(_ text: String, path: String, line: Int, column: Int?, dim: Bool) -> some View {
        Button {
            if let url = console.fileURL(for: path) { open(url, line, column) }
        } label: {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: dim ? Theme.foldMarker : Theme.assetLink))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    private func go(_ entry: UnityLogEntry) {
        guard let location = entry.location, let url = console.fileURL(for: location.path) else { NSSound.beep(); return }
        open(url, location.line, location.column)
    }

    private func copy(_ entries: [UnityLogEntry]) {
        let text = entries.map { entry in
            ([entry.path.map { "\($0)(\(entry.line ?? 0),\(entry.column ?? 0)): \(entry.code ?? "")" }]
                .compactMap { $0 } + [entry.message] + entry.frames.map(\.text)).joined(separator: "\n")
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Другой проект

    private var foreignNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("Editor.log сейчас пишет другой проект"))
                .foregroundStyle(.secondary)
            Text(console.foreignProject ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(L("Показать всё равно")) { console.showsForeign = true }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notice(_ title: String, _ hint: String) -> some View {
        VStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(hint).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Полоска у верхнего края: тянешь — консоль выше, редактор ниже.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? height
                    dragStart = start
                    height = min(max(start - value.translation.height, 100), 900)
                }
                .onEnded { _ in dragStart = nil })
    }
}

private struct EntryRow: View {
    let entry: UnityLogEntry
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.code.map { "\($0): \(entry.title)" } ?? entry.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
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
        .font(.system(size: 11))
        .foregroundStyle(entry.level == .system ? .secondary : .primary)
    }

    private var subtitle: String? {
        if let path = entry.path, let line = entry.line { return "\(path):\(line)" }
        return entry.location.map { "\($0.path):\($0.line)" }
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.level {
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(nsColor: Theme.diagnosticError))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
        case .info:
            Image(systemName: "info.circle.fill").foregroundStyle(Color(nsColor: Theme.assetLink))
        case .system:
            Image(systemName: "gearshape").foregroundStyle(.tertiary)
        }
    }
}
