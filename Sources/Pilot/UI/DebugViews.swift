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
                    .preferredColorScheme(Theme.current.isDark ? .dark : .light)
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

/// Нижняя панель отладки: слева стек, справа переменные, консоль программы
/// или сообщения отладчика — как вкладки Debugger, Console и Debug Output в Rider.
struct DebugPanel: View {
    @ObservedObject var debug: DebugService
    /// Корень проекта и переход к месту — для лога программы, как у консоли ▶.
    let root: URL?
    let open: (URL, Int) -> Void
    @AppStorage("pilot.debugPanelHeight") private var height: Double = 240
    /// 0 — переменные, 1 — консоль программы, 2 — сообщения отладчика.
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
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(get: { shownTab }, set: { tab = $0 })) {
                            Text(L("Переменные")).tag(0)
                            if showsProgram { Text(L("Консоль")).tag(1) }
                            Text(L("Отладчик")).tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer(minLength: 8)
                        if shownTab == 1 { programControls }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    switch shownTab {
                    case 0: DebugVariablesView(debug: debug)
                    case 1: ProgramOutputView(output: debug.output, root: root, open: open)
                    default: DebugConsoleView(console: debug.console)
                    }
                }
            }
        }
        .frame(height: CGFloat(height))
        .background(Color(nsColor: Theme.swiftUIEditorBackground))
        // Итог и ошибки сборки — в выводе программы; где его нет — у отладчика.
        .onChange(of: debug.lastError) { _, error in if error != nil { tab = showsProgram ? 1 : 2 } }
    }

    /// Консоль программы есть, только когда Pilot запускал её сам (.NET):
    /// к Unity и к работающему процессу подключаются, их вывод идёт мимо.
    private var showsProgram: Bool { debug.lastTarget?.hasProgramOutput == true }

    /// Выбранная вкладка; консоли у этой сессии нет — сообщения отладчика.
    private var shownTab: Int { tab == 1 && !showsProgram ? 2 : min(max(tab, 0), 2) }

    /// «Лог | Вывод» и 🗑 — те же, что в шапке консоли ▶.
    private var programControls: some View {
        HStack(spacing: 8) {
            ProgramOutputModePicker(logs: debug.output.serverLog)
            Button { debug.output.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(L("Очистить"))
        }
        .font(.system(size: 11))
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
                                    loading: debug.expanded.contains(row.variable.id) && debug.children[row.variable.id] == nil,
                                    canEdit: debug.isPaused && row.variable.isEditable,
                                    toggle: { debug.toggleExpanded(row.variable) },
                                    commit: { await debug.setVariable(row.variable, to: $0) })
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
    let canEdit: Bool
    let toggle: () -> Void
    /// Записать набранное; ответ — ошибка или nil.
    let commit: (String) async -> String?

    @State private var draft: String?
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

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
                    .foregroundStyle(Color(nsColor: Theme.swiftUIColor(.plain)))
                Text("=").foregroundStyle(.tertiary)
            }
            if draft != nil {
                TextField("", text: Binding(get: { draft ?? "" }, set: { draft = $0; error = nil }))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand { draft = nil; error = nil }
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(error == nil ? Color.accentColor : Color(nsColor: Theme.diagnosticError), lineWidth: 1))
                    .disabled(saving)
                if saving { ProgressView().controlSize(.mini) }
                if let error {
                    Text(error)
                        .foregroundStyle(Color(nsColor: Theme.diagnosticError))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                }
            } else if isClickable {
                valueText
            } else {
                // Кликом тут ничего не сделать — пусть значение выделяется
                // и копируется по частям.
                valueText.textSelection(.enabled)
            }
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
        // Клик в любом месте строки: узел раскрывается (править его — двойным
        // кликом), у листа раскрывать нечего — он правится. Выделения текста
        // у таких строк нет, чтобы оно не забирало клик у значения. Пока поле
        // открыто, клики — его: строка их не ловит и черновик не сбрасывает.
        .gesture(TapGesture(count: 2).onEnded { beginEditing() },
                 including: draft == nil && canEdit && variable.children > 0 ? .all : .subviews)
        .gesture(TapGesture().onEnded { click() }, including: draft == nil && isClickable ? .all : .subviews)
        .contextMenu {
            if canEdit {
                Button("Изменить значение") { beginEditing() }
                Divider()
            }
            Button("Скопировать значение") { copy(variable.value) }
            Button("Скопировать имя") { copy(variable.name) }
        }
        .help(helpText)
        .onChange(of: canEdit) { _, can in if !can { draft = nil; error = nil } }
        .onChange(of: focused) { _, isFocused in
            // Ушли из поля, ничего не поменяв, — оно закрывается: открывается
            // оно одним кликом, и иначе забытые поля копились бы по списку.
            guard !isFocused, !saving, let draft, draft == Self.editableText(variable.value) else { return }
            self.draft = nil
            error = nil
        }
    }

    private var valueText: some View {
        Text(variable.value)
            .foregroundStyle(Color(nsColor: valueColor))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Клик по строке что-то делает: раскрывает узел или правит значение.
    private var isClickable: Bool { variable.children > 0 || canEdit }

    private func click() {
        if variable.children > 0 { toggle() } else if canEdit { beginEditing() }
    }

    private var helpText: String {
        guard canEdit else { return variable.value }
        return variable.value + "\n" + (variable.children > 0 ? L("Двойной клик — изменить") : L("Клик — изменить"))
    }

    private func beginEditing() {
        draft = Self.editableText(variable.value)
        error = nil
        DispatchQueue.main.async { focused = true }
    }

    private func save() {
        guard let text = draft, !saving else { return }
        if text == Self.editableText(variable.value) {
            draft = nil
            return
        }
        saving = true
        Task {
            let failure = await commit(text)
            saving = false
            if let failure {
                error = failure
                focused = true
            } else {
                draft = nil
            }
        }
    }

    /// Показанное — в то, что можно отдать обратно как C#: у символа Mono
    /// пишет код и сам знак (`97 'a'`), у перечисления — имя типа.
    static func editableText(_ shown: String) -> String {
        if let quote = shown.firstIndex(of: "'"), shown.hasSuffix("'"),
           Int(shown[..<quote].trimmingCharacters(in: .whitespaces)) != nil {
            return String(shown[quote...])
        }
        if let paren = shown.firstIndex(of: "("), shown.hasSuffix(")"),
           let number = Int64(shown[..<paren].trimmingCharacters(in: .whitespaces)) {
            return String(number)
        }
        return shown
    }

    private var valueColor: NSColor {
        let value = variable.value
        if value.hasPrefix("\"") { return Theme.color(.string) }
        if value == "null" || value == "true" || value == "false" { return Theme.color(.keyword) }
        if let first = value.first, first.isNumber || first == "-" { return Theme.color(.number) }
        return Theme.swiftUIColor(.plain)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Условие точки останова

/// Окно у номера строки: условие точки на C#. Enter — сохранить,
/// пустое — точка без условия.
struct BreakpointConditionEditor: View {
    let line: Int
    let hasBreakpoint: Bool
    let commit: (String?) -> Void
    let cancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(line: Int, condition: String, hasBreakpoint: Bool,
         commit: @escaping (String?) -> Void, cancel: @escaping () -> Void) {
        self.line = line
        self.hasBreakpoint = hasBreakpoint
        self.commit = commit
        self.cancel = cancel
        _text = State(initialValue: condition)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasBreakpoint ? "Условие точки на строке \(line + 1)" : "Условная точка на строке \(line + 1)")
                .font(.headline)
            TextField("например: i == 10 && name != null", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onSubmit { commit(text) }
                .onExitCommand(perform: cancel)
            Text("Остановится, только когда выражение истинно. У Unity его считает Pilot: переменные, поля, индексы, сравнения и арифметика — без вызовов методов и свойств.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if hasBreakpoint, !text.isEmpty {
                    Button("Без условия") { commit(nil) }
                }
                Spacer()
                Button("Отмена", action: cancel)
                Button(hasBreakpoint ? "Готово" : "Поставить") { commit(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasBreakpoint && text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { DispatchQueue.main.async { focused = true } }
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
