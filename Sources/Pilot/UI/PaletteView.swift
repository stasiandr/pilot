import SwiftUI
import AppKit

/// Палитра. Один компонент на все режимы: единый поиск (⌘P, ⇧⇧, ⌘T, ⇧⌘F),
/// структура файла (⌘⇧O), использования (⌘R) — отличаются только
/// источником строк.
///
/// Рядом с результатами — предпросмотр выбранной строки. В широком окне
/// он справа от списка, в узком — под ним.
struct PaletteView: View {
    @ObservedObject var workspace: Workspace
    /// Сколько места под палитрой: от этого зависит, куда встанет предпросмотр.
    var available: CGSize = .zero
    @StateObject private var preview = PreviewLoader()
    @AppStorage("pilot.palettePreview") private var previewEnabled = true
    /// Строку выделили мышью: она и так на виду, а прокрутка к центру
    /// увела бы из-под курсора и второй клик двойного попал бы в соседнюю.
    @State private var selectedByClick = false

    var body: some View {
        PilotGlassGroup(spacing: 14) {
            VStack(spacing: 0) {
                queryField
                if workspace.paletteMode == .search { scopeBar }
                if workspace.paletteMode == .generated, !workspace.items.isEmpty,
                   !workspace.generatedStatus.isEmpty { generatedStatusLine }
                if !workspace.items.isEmpty || showsPreview {
                    Divider().opacity(0.35)
                    results
                } else if shouldShowEmptyState {
                    emptyState
                }
            }
            .frame(width: paletteWidth)
            .pilotGlass(cornerRadius: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.30), radius: 40, y: 18)
        }
        .onAppear { refreshPreview() }
        .onChange(of: selectedTarget) { _, _ in refreshPreview() }
        .onChange(of: previewEnabled) { _, _ in refreshPreview() }
    }

    // MARK: - Раскладка

    private var showsPreview: Bool { previewEnabled && (!workspace.items.isEmpty || awaitsUsages) }

    /// Использования ищутся долго, и палитра открыта со спиннером: она сразу
    /// того размера, какой будет со списком и предпросмотром, — иначе,
    /// открывшись узкой, раздувалась бы под пришедшие строки.
    private var awaitsUsages: Bool {
        workspace.paletteMode == .references && workspace.paletteBusy && workspace.items.isEmpty
    }

    /// Предпросмотр справа, если окно позволяет; иначе — под списком.
    private var isWide: Bool { available.width == 0 || available.width >= 1060 }

    private var paletteWidth: CGFloat {
        guard showsPreview else { return 660 }
        let room = available.width == 0 ? 1240 : available.width - 64
        return max(620, min(isWide ? 1240 : 760, room))
    }

    /// Высота под результаты и предпросмотр: сверху палитру подпирает
    /// отступ от тулбара и поле ввода, снизу нужен воздух.
    private var bodyHeight: CGFloat {
        let room = available.height == 0 ? 460 : available.height - 60 - 56 - 40
        return max(260, min(460, room))
    }

    @ViewBuilder
    private var results: some View {
        if !showsPreview {
            resultList(height: resultListHeight)
        } else if isWide {
            HStack(spacing: 0) {
                resultList(height: bodyHeight)
                    .frame(width: min(520, max(400, paletteWidth * 0.42)))
                Divider().opacity(0.35)
                previewPane
            }
            .frame(height: bodyHeight)
        } else {
            let listHeight = awaitsUsages ? bodyHeight * 0.42 : min(resultListHeight, bodyHeight * 0.42)
            resultList(height: listHeight)
            Divider().opacity(0.35)
            previewPane.frame(height: bodyHeight - listHeight)
        }
    }

    private var previewPane: some View {
        PalettePreview(loader: preview, root: workspace.root,
                       onOpen: { workspace.activateSelection() })
    }

    private var selectedTarget: NavTarget? {
        guard workspace.items.indices.contains(workspace.selection) else { return nil }
        return workspace.items[workspace.selection].target
    }

    private func refreshPreview() {
        guard previewEnabled else { return }
        preview.show(selectedTarget, document: workspace.document, archive: workspace.archive.session)
    }

    private var shouldShowEmptyState: Bool {
        if workspace.paletteBusy { return true }
        if workspace.paletteMode == .search {
            let scope = workspace.searchScope
            return !workspace.query.isEmpty || (scope != .everything && scope != .files)
        }
        return true
    }

    // MARK: - Поле ввода

    private var queryField: some View {
        HStack(spacing: 10) {
            Image(systemName: workspace.paletteMode == .search
                  ? workspace.searchScope.icon : workspace.paletteMode.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            // Return, стрелки и Esc ловит PaletteKeyMonitor.
            PaletteQueryField(text: $workspace.query, placeholder: placeholder)

            if workspace.paletteBusy || isIndexingForMode {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            counter
            Button { previewEnabled.toggle() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13))
                    .foregroundStyle(previewEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(previewEnabled ? L("Скрыть предпросмотр") : L("Показать предпросмотр"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var placeholder: String {
        if workspace.paletteMode == .search { return workspace.searchScope.placeholder }
        return workspace.paletteMode == .assetUsages && !workspace.usagesTitle.isEmpty
            ? L("Где используется \(workspace.usagesTitle)")
            : workspace.paletteMode.placeholder
    }

    // MARK: - Фильтр поиска

    /// Всё, файлы, типы, символы, текст. Фильтр — не другой поиск, а сужение
    /// этого: набранное остаётся. Те же сочетания, что открывают палитру,
    /// переключают его, пока она открыта, а Tab и ⇧Tab — на соседний по кругу.
    private var scopeBar: some View {
        HStack(spacing: 6) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                let selected = workspace.searchScope == scope
                Button { workspace.setSearchScope(scope) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: scope.icon).font(.system(size: 10, weight: .medium))
                        Text(scope.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background {
                        Capsule().fill(selected ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.06))
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(Self.scopeHelp(scope))
            }
            Spacer()
            // Вторая половина пары — не фильтр, а добавка: искать и в ней.
            if let label = workspace.partnerLabel {
                let on = workspace.searchIncludesPair
                Button { workspace.searchIncludesPair.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 10, weight: .medium))
                        Text("+ \(label)").font(.system(size: 11, weight: on ? .semibold : .regular))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background {
                        Capsule().fill(on ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.06))
                    }
                    .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(KeymapStore.shared.help(L("Искать и в \(label)"), .pairSearch))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private static func scopeHelp(_ scope: SearchScope) -> String {
        switch scope {
        case .everything: return L("Всё сразу, по смыслу запроса (⌘P, ⇧⇧)")
        case .files:      return L("Только файлы (⌘P ещё раз)")
        case .types:      return L("Только типы, в том числе из сборок (⇧⇧ ещё раз)")
        case .symbols:    return L("Типы и их члены (⌘T)")
        case .text:       return L("Текст в файлах проекта (⇧⌘F)")
        }
    }

    private var isIndexingForMode: Bool {
        switch workspace.paletteMode {
        case .search:
            switch workspace.searchScope {
            case .files, .text: return workspace.isIndexing
            case .everything, .types: return workspace.isIndexing || workspace.isTypeIndexing
            case .symbols: return workspace.symbolIndex == nil && !workspace.lsp.isReady
            }
        case .outline, .references, .declarations, .implementations, .changes, .assetUsages, .recentLocations,
             .counterparts, .contract, .mirrors, .generated: return false
        }
    }

    @ViewBuilder
    private var counter: some View {
        switch workspace.paletteMode {
        case .search where workspace.query.isEmpty && workspace.searchScope == .files:
            Text("\(workspace.fileCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help(L("Файлов в индексе"))
        case .search where workspace.query.isEmpty && workspace.searchScope == .types:
            Text("\(workspace.typeCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help(L("Типов в индексе"))
        case .search, .references, .declarations, .implementations, .outline, .changes, .assetUsages, .recentLocations,
             .counterparts, .contract, .mirrors, .generated:
            if !workspace.items.isEmpty {
                Text("\(workspace.items.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Сгенерированный код: от какого времени список и не устарел ли он.
    private var generatedStatusLine: some View {
        HStack {
            Text(workspace.generatedStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        HStack {
            Text(emptyMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private var emptyMessage: String {
        if workspace.paletteBusy {
            return workspace.paletteMode == .generated && !workspace.generatedStatus.isEmpty
                ? workspace.generatedStatus : L("Ищу…")
        }
        switch workspace.paletteMode {
        case .search:
            return searchEmptyMessage
        case .references:
            return L("Использований не найдено")
        case .declarations:
            return L("Ничего не найдено")
        case .implementations:
            return workspace.symbolIndex == nil
                ? L("Собираю объявления проекта…")
                : L("Ни наследников, ни переопределений не нашлось")
        case .outline:
            return workspace.document == nil
                ? L("Сначала откройте файл")
                : L("В этом файле объявлений не найдено")
        case .changes:
            if workspace.git.repository == nil { return L("Проект не под git") }
            return workspace.query.isEmpty ? L("Изменений нет — всё закоммичено") : L("Ничего не найдено")
        case .recentLocations:
            return workspace.query.isEmpty
                ? L("Здесь будут места, где вы были и что правили")
                : L("Ничего не найдено")
        case .assetUsages:
            return workspace.query.isEmpty
                ? L("На \(workspace.usagesTitle) не ссылается ни одна сцена, префаб или ассет")
                : L("Ничего не найдено")
        case .counterparts:
            return L("Во второй половине пары ничего не нашлось")
        case .contract:
            return workspace.query.isEmpty ? L("Датаграммы клиента и сервера сходятся") : L("Ничего не найдено")
        case .mirrors:
            return workspace.query.isEmpty ? L("Зеркальные файлы одинаковы в обеих половинах") : L("Ничего не найдено")
        case .generated:
            return workspace.query.isEmpty
                ? (workspace.generatedStatus.isEmpty ? L("Для типов этого файла генераторы ничего не написали")
                                                     : workspace.generatedStatus)
                : L("Ничего не найдено")
        }
    }

    private var searchEmptyMessage: String {
        let query = workspace.query.trimmingCharacters(in: .whitespaces)
        switch workspace.searchScope {
        case .everything, .files:
            return L("Ничего не найдено")
        case .types:
            if !query.isEmpty { return L("Ничего не найдено") }
            if workspace.isTypeIndexing && workspace.typeCount == 0 { return L("Собираю типы проекта…") }
            return L("Начните вводить имя типа — можно заглавными: USvc → UserService")
        case .symbols:
            if !workspace.canSearchSymbols { return L("Собираю символы проекта…") }
            if !query.isEmpty { return L("Ничего не найдено") }
            return L("Начните вводить имя символа")
        case .text:
            return query.isEmpty ? L("Начните вводить текст — ищу по всем файлам проекта") : L("Ничего не найдено")
        }
    }

    // MARK: - Результаты

    private func resultList(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(workspace.items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isSelected: index == workspace.selection)
                            .id(index)
                            .contentShape(Rectangle())
                            // Клик выделяет — видно предпросмотр, двойной открывает.
                            // Не onTapGesture(count: 2): одиночный ждал бы второго.
                            .onTapGesture {
                                selectedByClick = index != workspace.selection
                                workspace.selection = index
                                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                    workspace.activateSelection()
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(height: height)
            .overlay(alignment: .topLeading) { if awaitsUsages { emptyState } }
            .onChange(of: workspace.selection) { _, new in
                if selectedByClick { selectedByClick = false; return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// ScrollView сам по себе занимает всю предложенную высоту, и с одним
    /// результатом стеклянная панель висела бы полупустой. Поэтому высоту
    /// считаем по строкам: однострочная ~29 pt, с подписью ~43 pt.
    private var resultListHeight: CGFloat {
        let rowHeight: CGFloat = workspace.items.first?.secondary?.isEmpty == false ? 43 : 29
        return min(420, CGFloat(workspace.items.count) * rowHeight + 16)
    }
}

// MARK: - Поле запроса

/// Своё поле, а не SwiftUI TextField: курсор должен стоять в нём с того
/// момента, как поле попало в окно. @FocusState из onAppear ставил его
/// позже, и первые буквы после ⌘P или ⇧⇧ уходили в редактор.
struct PaletteQueryField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }

    final class Field: NSTextField {
        /// Поле открытой палитры — его ищет PaletteKeyMonitor.
        static weak var current: Field?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                if Field.current === self { Field.current = nil }
                return
            }
            Field.current = self
            window.makeFirstResponder(self)
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            // NSTextField при фокусе выделяет всё, и набранное до появления
            // поля стёрла бы следующая буква. Курсор — в конец.
            currentEditor()?.selectedRange = NSRange(location: stringValue.utf16.count, length: 0)
            return true
        }
    }
}

// MARK: - Строка результата

struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(iconStyle)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 1) {
                styledPrimary
                    .lineLimit(1)
                    .truncationMode(.head)
                if let secondary = item.secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75))
                                                    : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        // «Контейнер · путь/к/Файлу.cs»: важны оба конца,
                        // поэтому режем середину, а не начало.
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            if let pair = item.pairLabel {
                pairTag(pair)
            }
            if let trailing = item.trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75))
                                                : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
            }
        }
        // Вторая половина пары — ещё и полоской её цвета у левого края:
        // свои и чужие строки различимы, даже не читая меток.
        .overlay(alignment: .leading) {
            if item.pairLabel != nil {
                Capsule()
                    .fill(pairColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .padding(.leading, 2)
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    /// Метка второй половины пары: `server`, `client`. На выделенной строке —
    /// сплошная: полупрозрачная потерялась бы на цвете выделения.
    private func pairTag(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(isSelected ? pairColor : pairColor.opacity(0.2)))
            .foregroundStyle(isSelected ? Color(nsColor: Theme.badgeText) : pairColor)
            .fixedSize()
    }

    private var pairColor: Color { Color(nsColor: Theme.pairProject) }

    /// Файлы — цветной иконкой, как в навигаторе; остальное приглушённо.
    private var iconStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.primary) }
        let file = Theme.fileIcon(forName: (item.primary as NSString).lastPathComponent)
        if file.symbol == item.icon { return AnyShapeStyle(Color(nsColor: file.color)) }
        return AnyShapeStyle(.secondary)
    }

    /// Собираем строку отрезками: совпавшие символы выделены,
    /// путь к файлу приглушён относительно имени.
    private var styledPrimary: Text {
        guard !item.positions.isEmpty else { return Text(item.primary) }

        let matched = Set(item.positions.map { Int($0) })
        var result = Text("")
        var utf8Index = 0
        var runText = ""
        var runMatched = false
        var runInName = false
        var started = false

        func flush() {
            guard !runText.isEmpty else { return }
            var t = Text(runText)
            if runMatched {
                t = t.bold()
                if !isSelected { t = t.foregroundColor(.accentColor) }
            } else if !runInName && !isSelected {
                // Путь во второй половине пары — на ступень тише своего.
                t = item.pairLabel == nil ? t.foregroundColor(.secondary) : t.foregroundStyle(.tertiary)
            }
            result = result + t
            runText = ""
        }

        for ch in item.primary {
            let width = String(ch).utf8.count
            let isMatched = matched.contains(utf8Index)
            let inName = utf8Index >= item.nameOffset
            if !started || isMatched != runMatched || inName != runInName {
                flush()
                runMatched = isMatched
                runInName = inName
                started = true
            }
            runText.append(ch)
            utf8Index += width
        }
        flush()
        return result
    }
}
