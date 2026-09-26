import SwiftUI
import AppKit

/// Окно обозревателя базы: подключение, дерево баз и таблиц, SQL и результат.
struct DatabaseWindow: View {
    static let sceneID = "database"

    @ObservedObject private var browser = DatabaseBrowser.shared
    @ObservedObject private var language = LanguageStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editor = SQLEditorState()

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
                VSplitView {
                    SQLEditor(text: $browser.sql, state: editor) { run() }
                        .frame(minHeight: 90, idealHeight: 180)
                    results
                        .frame(minHeight: 160)
                }
                .frame(minWidth: 480)
            }
        }
        .background(Color(nsColor: Theme.editorBackground))
        .navigationTitle(L("База данных"))
        .frame(minWidth: 820, minHeight: 480)
        .id(language.current)
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
        .background {
            Button("") { dismiss() }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
        }
    }

    /// Выделенный текст, а без выделения — весь редактор.
    private func run() {
        browser.execute(editor.selectedText ?? browser.sql)
    }

    // MARK: Подключение

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.secondary)
            TextField(L("Хост"), text: $browser.options.host)
                .frame(width: 140)
            TextField(L("Порт"), value: $browser.options.port, format: .number.grouping(.never))
                .frame(width: 60)
            TextField(L("Пользователь"), text: $browser.options.user)
                .frame(width: 110)
            SecureField(L("Пароль"), text: $browser.options.password)
                .frame(width: 120)
            TextField(L("Имя базы"), text: $browser.options.database)
                .frame(width: 120)
            if browser.isRemote {
                Label(L("Удалённый сервер"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(L("Запросы уходят не на эту машину — осторожнее с UPDATE и DELETE"))
            }
            Spacer()
            stateView
            switch browser.state {
            case .connected, .connecting:
                Button(L("Отключиться")) { browser.disconnect() }
            default:
                Button(L("Подключиться")) { browser.connect() }
                    .keyboardShortcut(.defaultAction)
            }
            Menu {
                Button(L("Контейнер MariaDB из Docker")) {
                    browser.connect(to: MariaDBContainer.shared.connectionOptions)
                }
            } label: {
                Image(systemName: "shippingbox")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Подставить подключение"))
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var stateView: some View {
        switch browser.state {
        case .disconnected:
            EmptyView()
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected(let version):
            Text(version).font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: 320, alignment: .trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: Дерево

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Базы")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(!browser.isConnected)
                    .help(L("Обновить"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            List {
                ForEach(browser.schemas) { schema in
                    SchemaRow(schema: schema, browser: browser)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if !browser.isConnected {
                    Text(L("Нет подключения")).foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(nsColor: Theme.chromeBackground))
    }

    // MARK: Результат

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    run()
                } label: {
                    Label(L("Выполнить"), systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!browser.isConnected || browser.isRunning)
                .help(L("⌘↩ — выделенное или весь текст"))
                if browser.isRunning {
                    Button(L("Остановить")) { browser.cancel() }
                    ProgressView().controlSize(.small)
                }
                if let schema = browser.currentSchema {
                    Text("USE \(schema)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if let outcome = browser.outcome {
                    let sets = outcome.results.indices
                    if sets.count > 1 {
                        Picker("", selection: $browser.selectedResult) {
                            ForEach(sets, id: \.self) { i in Text(L("Результат \(String(i + 1))")).tag(i) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(summary(outcome)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            resultBody
        }
    }

    @ViewBuilder
    private var resultBody: some View {
        if let outcome = browser.outcome {
            if let error = outcome.error, outcome.results.isEmpty || browser.selectedResult >= outcome.results.count {
                message(error, color: .red)
            } else if outcome.results.indices.contains(browser.selectedResult) {
                let result = outcome.results[browser.selectedResult]
                if result.isResultSet {
                    ResultGrid(result: result)
                } else {
                    message(L("Затронуто строк: \(String(result.affectedRows))")
                            + (result.lastInsertID > 0 ? " · LAST_INSERT_ID = \(result.lastInsertID)" : "")
                            + (result.info.isEmpty ? "" : "\n" + result.info), color: .secondary)
                }
                if let error = outcome.error {
                    Divider()
                    Text(error).foregroundStyle(.red).padding(8).textSelection(.enabled)
                }
            } else {
                message(L("Готово"), color: .secondary)
            }
        } else {
            message(L("⌘↩ — выполнить запрос. Двойной щелчок по таблице — её строки."), color: .secondary)
        }
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
    }

    private func summary(_ outcome: DatabaseBrowser.Outcome) -> String {
        let time = outcome.elapsed < 1 ? "\(Int(outcome.elapsed * 1000)) ms"
                                       : String(format: "%.2f s", outcome.elapsed)
        guard outcome.results.indices.contains(browser.selectedResult) else { return time }
        let result = outcome.results[browser.selectedResult]
        guard result.isResultSet else { return time }
        let rows = result.totalRows > result.rows.count
            ? L("показаны \(result.rows.count.formatted()) из \(result.totalRows.formatted())")
            : Localization.count(result.totalRows, "запись", "записи", "записей")
        return rows + " · " + time
    }
}

private struct SchemaRow: View {
    let schema: DatabaseBrowser.Schema
    @ObservedObject var browser: DatabaseBrowser
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let tables = schema.tables {
                if tables.isEmpty {
                    Text(L("Таблиц нет")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(tables) { table in
                    TableRow(table: table, browser: browser)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cylinder")
                    .foregroundStyle(schema.name == browser.currentSchema ? Color.accentColor : .secondary)
                Text(schema.name)
                    .fontWeight(schema.name == browser.currentSchema ? .semibold : .regular)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { browser.use(schema.name) }
            .contextMenu {
                Button(L("Сделать текущей (USE)")) { browser.use(schema.name) }
            }
        }
        .onChange(of: expanded) { _, open in
            if open && schema.tables == nil { Task { await browser.loadTables(schema.name) } }
        }
        .onAppear {
            if schema.name == browser.currentSchema { expanded = true }
        }
    }
}

private struct TableRow: View {
    let table: DatabaseBrowser.Table
    @ObservedObject var browser: DatabaseBrowser

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: table.isView ? "eye" : "tablecells")
                .foregroundStyle(.secondary)
            Text(table.name).lineLimit(1)
            Spacer()
            if let rows = table.rows {
                Text("~\(rows.formatted())").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { browser.openData(table) }
        .contextMenu {
            Button(L("Данные")) { browser.openData(table) }
            Button(L("Столбцы")) { browser.openStructure(table) }
            Button(L("DDL")) { browser.openDDL(table) }
            Divider()
            Button(L("Скопировать имя")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(table.name, forType: .string)
            }
        }
    }
}

// MARK: - SQL-редактор

/// Что выделено в редакторе — чтобы ⌘↩ выполнил только это.
final class SQLEditorState {
    weak var textView: NSTextView?

    var selectedText: String? {
        guard let view = textView else { return nil }
        let range = view.selectedRange()
        guard range.length > 0 else { return nil }
        return (view.string as NSString).substring(with: range)
    }
}

struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    let state: SQLEditorState
    let run: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let view = scroll.documentView as! NSTextView
        view.font = Theme.editorFont(size: 13)
        view.textColor = NSColor.labelColor
        view.insertionPointColor = NSColor.labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.string = text
        view.delegate = context.coordinator
        state.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let view = scroll.documentView as! NSTextView
        state.textView = view
        if view.string != text {
            view.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor

        init(_ parent: SQLEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

// MARK: - Таблица результата

/// Сетка строк результата. NSTableView, а не SwiftUI Table: столбцы
/// у каждой выборки свои, а строк бывает десять тысяч.
struct ResultGrid: NSViewRepresentable {
    let result: MySQLConnection.Result

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = CopyingTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.style = .plain
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.coordinator = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        context.coordinator.show(result)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.show(result)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private(set) var result = MySQLConnection.Result()
        private var shownColumns: [String] = []
        private var shownRows = -1
        private let font = Theme.editorFont(size: 12)

        func show(_ result: MySQLConnection.Result) {
            guard let table else { return }
            let names = result.columns.map(\.name)
            let same = names == shownColumns && result.rows.count == shownRows
                && result.rows.first == self.result.rows.first && result.rows.last == self.result.rows.last
            self.result = result
            guard !same else { return }
            shownColumns = names
            shownRows = result.rows.count
            for column in table.tableColumns { table.removeTableColumn(column) }
            let sample = result.rows.prefix(60)
            for (i, column) in result.columns.enumerated() {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
                c.title = column.name
                c.headerToolTip = column.table.isEmpty ? column.name : column.table + "." + column.name
                let longest = sample.map { min(($0[i] ?? "NULL").count, 60) }.max() ?? 0
                c.width = CGFloat(max(column.name.count + 2, longest, 4)) * 7.4 + 12
                c.minWidth = 30
                c.maxWidth = 2000
                table.addTableColumn(c)
            }
            table.reloadData()
            table.scrollRowToVisible(0)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { result.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue),
                  row < result.rows.count, index < result.columns.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = id
                f.lineBreakMode = .byTruncatingTail
                f.font = font
                return f
            }()
            if let value = result.rows[row][index] {
                // Переводы строк в ячейке — одной строкой, целиком видно в подсказке.
                field.stringValue = value.count > 500 ? String(value.prefix(500)) + "…" : value
                field.textColor = NSColor.labelColor
                field.toolTip = value.count > 40 || value.contains("\n") ? String(value.prefix(4000)) : nil
            } else {
                field.stringValue = "NULL"
                field.textColor = .tertiaryLabelColor
                field.toolTip = nil
            }
            field.alignment = result.columns[index].isNumeric ? .right : .left
            return field
        }

        /// Выделенные строки — через табуляцию, как их примет таблица или редактор.
        func copyRows(_ rows: IndexSet, header: Bool) -> String {
            var lines: [String] = []
            if header { lines.append(result.columns.map(\.name).joined(separator: "\t")) }
            for row in rows where row < result.rows.count {
                lines.append(result.rows[row].map { $0 ?? "NULL" }.joined(separator: "\t"))
            }
            return lines.joined(separator: "\n")
        }
    }

    final class CopyingTableView: NSTableView {
        weak var coordinator: Coordinator?

        @objc func copy(_ sender: Any?) {
            guard let coordinator, !selectedRowIndexes.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(coordinator.copyRows(selectedRowIndexes, header: false), forType: .string)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            let row = self.row(at: point), column = self.column(at: point)
            if row >= 0 && !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let menu = NSMenu()
            if row >= 0, column >= 0, let coordinator, row < coordinator.result.rows.count,
               let index = Int(tableColumns[column].identifier.rawValue) {
                let value = coordinator.result.rows[row][index] ?? "NULL"
                let item = NSMenuItem(title: L("Скопировать значение"), action: #selector(copyValue(_:)), keyEquivalent: "")
                item.representedObject = value
                item.target = self
                menu.addItem(item)
            }
            let rows = NSMenuItem(title: L("Скопировать строки"), action: #selector(copy(_:)), keyEquivalent: "c")
            rows.target = self
            menu.addItem(rows)
            let withHeader = NSMenuItem(title: L("Скопировать с заголовком"), action: #selector(copyWithHeader(_:)), keyEquivalent: "")
            withHeader.target = self
            menu.addItem(withHeader)
            return menu
        }

        @objc private func copyValue(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }

        @objc private func copyWithHeader(_ sender: Any?) {
            guard let coordinator, !selectedRowIndexes.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(coordinator.copyRows(selectedRowIndexes, header: true), forType: .string)
        }
    }
}
