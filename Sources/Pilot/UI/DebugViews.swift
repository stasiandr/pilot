import SwiftUI
import AppKit

// MARK: - Тулбар

/// Кнопки отладки в тулбаре: без сессии — «жук» с выбором цели, в сессии —
/// продолжить или приостановить, три шага и стоп, как в Xcode.
struct DebugToolbarControls: View {
    @ObservedObject var debug: DebugService

    var body: some View {
        if debug.isActive {
            DebugControlButtons(debug: debug)
        } else {
            Button { debug.openTargetPicker() } label: {
                Label("Отладка", systemImage: "ladybug")
            }
            .help(KeymapStore.shared.help("Начать отладку", .debugStart))
            .popover(isPresented: Binding(get: { debug.isTargetPickerOpen },
                                          set: { debug.isTargetPickerOpen = $0 }),
                     arrowEdge: .bottom) {
                DebugTargetPicker(debug: debug)
                    .preferredColorScheme(.dark)
            }
        }
    }
}

struct DebugControlButtons: View {
    @ObservedObject var debug: DebugService
    var compact = false

    var body: some View {
        if debug.isPaused {
            button("Продолжить", "play.fill", .debugContinue) { debug.resume() }
        } else {
            button("Приостановить", "pause.fill", .debugPause) { debug.pause() }
                .disabled(debug.state != .running)
        }
        button("Шаг с обходом", "arrow.turn.down.right", .stepOver) { debug.step(.over) }
            .disabled(!debug.isPaused)
        button("Шаг с заходом", "arrow.down.to.line", .stepInto) { debug.step(.into) }
            .disabled(!debug.isPaused)
        button("Шаг с выходом", "arrow.up.to.line", .stepOut) { debug.step(.out) }
            .disabled(!debug.isPaused)
        button("Остановить отладку", "stop.fill", .debugStop) { debug.stop() }
    }

    private func button(_ title: String, _ symbol: String, _ command: EditorCommand,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if compact {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 18)
            } else {
                Label(title, systemImage: symbol)
            }
        }
        .buttonStyle(compact ? AnyButtonStyle(.borderless) : AnyButtonStyle(.automatic))
        .help(KeymapStore.shared.help(title, command))
    }
}

/// `ButtonStyle` разных типов в одном тернарном выражении.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Выбор цели

struct DebugTargetPicker: View {
    @ObservedObject var debug: DebugService
    @State private var address = "127.0.0.1:56000"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Отладка").font(.headline)
                Spacer()
                if debug.isDiscovering {
                    ProgressView().controlSize(.small)
                } else {
                    Button { debug.discoverTargets() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Искать ещё раз")
                }
            }

            if debug.targets.isEmpty, !debug.isDiscovering {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(debug.targets) { target in
                Button { debug.start(target) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: target.symbol)
                            .frame(width: 20)
                            .foregroundStyle(target.isUnity ? Color(nsColor: Theme.unityEvent) : .accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.title)
                            Text(target.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(target == debug.targets.first ? 0.08 : 0)))
            }

            if debug.isUnityProject {
                Divider()
                Text("Сборка по адресу — Android через `adb forward tcp:56000 tcp:56000`")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("host:port", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connectToAddress)
                    Button("Подключиться", action: connectToAddress)
                        .disabled(parsedAddress == nil)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        // Return — первая цель, как в палитре.
        .background {
            Button("") { if let first = debug.targets.first { debug.start(first) } }
                .keyboardShortcut(.defaultAction)
                .hidden()
        }
    }

    private var emptyText: String {
        if debug.isUnityProject {
            return "Редактор Unity с этим проектом не запущен, а Development-сборок со Script Debugging в сети не слышно."
        }
        return "Не нашлось ни проекта .NET с OutputType Exe, ни запущенного процесса из этой папки."
    }

    private var parsedAddress: (String, Int)? {
        let parts = address.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port), !parts[0].isEmpty else { return nil }
        return (String(parts[0]), port)
    }

    private func connectToAddress() {
        guard let (host, port) = parsedAddress else { return }
        debug.start(.unityRemote(host: host == "localhost" ? "127.0.0.1" : host, port: port))
    }
}

// MARK: - Панель

/// Нижняя панель отладки: слева стек, справа переменные или вывод.
struct DebugPanel: View {
    @ObservedObject var debug: DebugService
    @AppStorage("pilot.debugPanelHeight") private var height: Double = 240
    @AppStorage("pilot.debugPanelTab") private var tab = 0
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            header
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
            HStack(spacing: 0) {
                DebugFramesView(debug: debug)
                    .frame(width: 280)
                Rectangle().fill(Color(nsColor: Theme.separator)).frame(width: 1)
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("Переменные").tag(0)
                        Text("Вывод").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .padding(.vertical, 5)
                    if tab == 0 {
                        DebugVariablesView(debug: debug)
                    } else {
                        DebugConsoleView(console: debug.console)
                    }
                }
            }
        }
        .frame(height: CGFloat(height))
        .background(Color(nsColor: Theme.editorBackground))
        .onChange(of: debug.lastError) { _, error in if error != nil { tab = 1 } }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: Theme.separator))
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? height
                    if dragStart == nil { dragStart = height }
                    height = min(max(start - value.translation.height, 120), 700)
                }
                .onEnded { _ in dragStart = nil })
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(debug.sessionTitle ?? "Отладка").font(.system(size: 12, weight: .semibold))
            statusText
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if debug.isActive {
                HStack(spacing: 2) { DebugControlButtons(debug: debug, compact: true) }
            } else {
                if let target = debug.lastTarget {
                    Button { debug.start(target) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Ещё раз: \(target.title)")
                }
                Button { debug.isPanelVisible = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Скрыть панель")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch debug.state {
        case .starting:
            ProgressView().controlSize(.mini)
        case .running:
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color(nsColor: Theme.debugExecution))
        case .paused:
            Image(systemName: "pause.circle.fill").font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.breakpoint))
        case .idle:
            Image(systemName: "ladybug").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch debug.state {
        case .starting(let text): Text(text)
        case .running: Text("Выполняется")
        case .paused: Text(debug.stopReason ?? "Остановлено")
        case .idle:
            if let error = debug.lastError {
                Text(error).foregroundStyle(Color(nsColor: Theme.diagnosticError))
                    .help(error)
            } else {
                Text("Сессия завершена")
            }
        }
    }
}

// MARK: - Стек

struct DebugFramesView: View {
    @ObservedObject var debug: DebugService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if debug.threads.count > 1 {
                Menu {
                    ForEach(debug.threads) { thread in
                        Button(thread.name) { debug.selectThread(thread.id) }
                    }
                } label: {
                    Text(debug.threads.first { $0.id == debug.thread }?.name ?? "Поток")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(debug.frames.enumerated()), id: \.offset) { index, frame in
                        frameRow(frame, index: index)
                    }
                }
                .padding(.vertical, 2)
            }
            if debug.frames.isEmpty {
                Text(debug.isPaused ? "Стек загружается…" : (debug.isActive ? "Стек виден на остановке" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func frameRow(_ frame: DebugFrame, index: Int) -> some View {
        let selected = index == debug.frameIndex
        return Button { debug.selectFrame(index) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(frame.name)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(frame.file == nil ? .tertiary : .primary)
                if let file = frame.file, let line = frame.line {
                    Text("\(file.lastPathComponent):\(line + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selected ? Color(nsColor: Theme.tabActive) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(frame.file?.path ?? "Нет исходника")
    }
}

// MARK: - Переменные

struct DebugVariablesView: View {
    @ObservedObject var debug: DebugService

    private struct Row: Identifiable {
        var variable: DebugVariable
        var depth: Int
        var id: String { variable.id }
    }

    /// Дерево в плоский список: у раскрытых узлов — их загруженные дети.
    private var rows: [Row] {
        var result: [Row] = []
        func walk(_ list: [DebugVariable], _ depth: Int) {
            for variable in list {
                result.append(Row(variable: variable, depth: depth))
                if debug.expanded.contains(variable.id), let kids = debug.children[variable.id], depth < 30 {
                    walk(kids, depth + 1)
                }
            }
        }
        walk(debug.variables, 0)
        return result
    }

    var body: some View {
        if debug.variables.isEmpty {
            Text(debug.isPaused ? "Нет переменных" : (debug.isActive ? "Переменные видны на остановке" : ""))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        VariableRow(variable: row.variable, depth: row.depth,
                                    expanded: debug.expanded.contains(row.variable.id),
                                    loading: debug.expanded.contains(row.variable.id) && debug.children[row.variable.id] == nil) {
                            debug.toggleExpanded(row.variable)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct VariableRow: View {
    let variable: DebugVariable
    let depth: Int
    let expanded: Bool
    let loading: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if variable.children > 0 {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            if !variable.name.isEmpty {
                Text(variable.name)
                    .foregroundStyle(Color(nsColor: Theme.color(.plain)))
                Text("=").foregroundStyle(.tertiary)
            }
            Text(variable.value)
                .foregroundStyle(Color(nsColor: valueColor))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            if loading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 8)
            if !variable.type.isEmpty {
                Text(variable.type)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 8)
        .frame(height: 19)
        .contentShape(Rectangle())
        .onTapGesture { if variable.children > 0 { toggle() } }
        .contextMenu {
            Button("Скопировать значение") { copy(variable.value) }
            Button("Скопировать имя") { copy(variable.name) }
        }
        .help(variable.value)
    }

    private var valueColor: NSColor {
        let value = variable.value
        if value.hasPrefix("\"") { return Theme.color(.string) }
        if value == "null" || value == "true" || value == "false" { return Theme.color(.keyword) }
        if let first = value.first, first.isNumber || first == "-" { return Theme.color(.number) }
        return Theme.color(.plain)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Вывод

struct DebugConsoleView: View {
    @ObservedObject var console: DebugConsole

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(console.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.isError ? Color(nsColor: Theme.diagnosticError) : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: console.lines.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .contextMenu {
                Button("Скопировать всё") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(console.text, forType: .string)
                }
                Button("Очистить") { console.clear() }
            }
        }
    }
}
