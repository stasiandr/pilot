import SwiftUI
import AppKit

/// Инспектор Unity: объект под курсором — GameObject со всеми компонентами,
/// вложенный префаб или ScriptableObject — в виде формы, как в редакторе Unity.
///
/// Текст остаётся источником правды: инспектор — это другой взгляд на тот же
/// файл. Правка точечно меняет значение в тексте редактора — как набор:
/// файл становится несохранённым, ⌘Z в редакторе её отменяет.
struct UnityInspectorView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let document = workspace.document, let file = document.unityFile,
           let content = UnityInspector.content(file: file, model: document.model,
                                                caret: workspace.caretOffset,
                                                resolve: { workspace.unity.assets?.displayName(for: $0) }) {
            UnityInspectorForm(content: content, file: file,
                               parsing: !document.isSemanticsFresh, readOnly: document.revision != nil,
                               unity: workspace.unity, actions: UnityInspectorActions(workspace: workspace))
        } else {
            UnityInspectorForm.placeholder
        }
    }
}

/// Что инспектор делает по щелчку и по правке. У окна — воркспейс; без окна
/// (`HeadlessInspector`) — запись в stdout.
@MainActor
struct UnityInspectorActions {
    var commit: ([UnityEdit], String) -> Void
    var reveal: (Int64) -> Void
    var openAsset: (UnityGUID, Int64?) -> Void
}

extension UnityInspectorActions {
    init(workspace: Workspace) {
        commit = { workspace.applyUnityEdits($0, actionName: $1) }
        reveal = { workspace.revealUnityObject(fileID: $0) }
        openAsset = { workspace.openUnityAsset(guid: $0, fileID: $1) }
    }
}

// MARK: - Колонка в окне

extension View {
    /// Инспектор Unity справа от редактора — один и тот же у окна проекта и у
    /// `HeadlessInspector --window`: без окна проверяется ровно то, что в нём.
    ///
    /// Если навигатор, минимальная ширина редактора и колонка не влезают в
    /// окно, SwiftUI раскладывает сплит шире окна и центрирует: навигатор
    /// уезжает за левый край, инспектор — за правый, вместе с полями и
    /// кнопками. Обернуть редактор, чтобы он ужимался, здесь нельзя — с
    /// обёрткой (`frame(minWidth:)`, свой `Layout`) macOS 26–27 сбивает
    /// подложки тулбара над колонками. Поэтому ширину не диктуют сами нижние
    /// панели редактора: см. `UnityConsolePanel`.
    func unityInspector<Inspector: View>(isPresented: Binding<Bool>,
                                         @ViewBuilder content: () -> Inspector) -> some View {
        inspector(isPresented: isPresented) {
            content().inspectorColumnWidth(min: 260, ideal: 330, max: 600)
        }
    }
}

// MARK: - Форма

/// Сама форма: шапка объекта и компоненты. Отдельно от воркспейса, чтобы её
/// можно было нарисовать и без окна (`HeadlessInspector`) — тем же кодом.
struct UnityInspectorForm: View {
    let content: UnityInspectorContent
    let file: UnityYAMLFile
    /// Текст правили, а разбор ещё не догнал: позиции полей устарели.
    let parsing: Bool
    /// Версия файла из мерж-реквеста.
    let readOnly: Bool
    let unity: UnityService
    let actions: UnityInspectorActions

    /// Режим отладки — как Debug-инспектор Unity: видны служебные поля.
    @AppStorage("pilot.inspectorDebug") private var debug = false
    /// Раскрытые структуры и списки, свёрнутые компоненты. Живут вне
    /// содержимого, поэтому переживают перечитывание файла после правки.
    @State private var expanded: Set<String>
    @State private var collapsed: Set<Int64> = []
    /// Ширина колонки: от неё ширина подписей, как в Unity.
    @State private var width: CGFloat = 330
    /// Сколько сверху колонку закрывают тулбар и вкладки окна; `nil` — ещё не мерили.
    @State private var chromeTop: CGFloat?

    init(content: UnityInspectorContent, file: UnityYAMLFile, parsing: Bool, readOnly: Bool,
         unity: UnityService, actions: UnityInspectorActions, expanded: Set<String> = []) {
        self.content = content
        self.file = file
        self.parsing = parsing
        self.readOnly = readOnly
        self.unity = unity
        self.actions = actions
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        // Пока разбор не догнал текст, позиции полей устарели и писать по ним
        // нельзя — это доли секунды; версия из мерж-реквеста — только для
        // чтения. Но ходить по ссылкам, раскрывать и сворачивать можно всегда:
        // раньше выключалась вся форма, и в ревью списки и ссылки не открывались.
        let editable = !parsing && !readOnly
        let metrics = RowMetrics(formWidth: width)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    header(editable: editable)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if parsing {
                        ProgressView().controlSize(.mini)
                    }
                    debugToggle
                }
                ForEach(Array(content.sections.enumerated()), id: \.element.id) { index, section in
                    sectionView(section, focused: index == content.focusedSection, editable: editable,
                                metrics: metrics)
                }
            }
            .padding(RowMetrics.formPadding)
            .padding(.top, chromeTop ?? 0)
        }
        // Отступ сверху под тулбар и вкладки окна — свой, измеренный: см.
        // WindowChromeProbe. Пока не измерен — как решит SwiftUI.
        .ignoresSafeArea(.container, edges: chromeTop == nil ? [] : .top)
        .background(WindowChromeProbe(top: $chromeTop).ignoresSafeArea(.container, edges: .top))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Ключи всех раскрывающихся групп объекта — «раскрыть всё» без окна.
    /// Ключ строится так же, как в `PropertyRow`: путь от компонента.
    static func expansionKeys(of content: UnityInspectorContent, debug: Bool) -> Set<String> {
        var keys: Set<String> = content.children.isEmpty ? [] : ["children"]
        func collect(_ property: UnityProperty, path: String) {
            switch property.value {
            case .mapping(let children), .sequence(let children):
                let key = path + "/" + property.key
                keys.insert(key)
                children.forEach { collect($0, path: key) }
            case .scalar, .flow:
                break
            }
        }
        for section in content.sections {
            (debug ? section.allProperties : section.properties).forEach { collect($0, path: "\(section.fileID)") }
        }
        return keys
    }

    static var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("Поставьте курсор на объект сцены, префаба или ассета"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Шапка

    /// Жучок в углу инспектора, как Debug-режим в Unity: видны служебные поля.
    private var debugToggle: some View {
        Button { debug.toggle() } label: {
            Image(systemName: debug ? "ladybug.fill" : "ladybug")
                .font(.system(size: 12))
                .foregroundStyle(debug ? AnyShapeStyle(Color(nsColor: Theme.unityEvent)) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Отладка"))
        .help(L("Отладка: показать служебные поля, как Debug-инспектор Unity"))
    }

    @ViewBuilder
    private func header(editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !content.path.isEmpty {
                breadcrumbs(content.path)
            }
            HStack(spacing: 8) {
                Image(systemName: icon(for: content.kind))
                    .foregroundStyle(Color(nsColor: Theme.unityEvent))
                if let active = content.active?.value.scalar {
                    Toggle("", isOn: toggleBinding(active, name: L("Активность")))
                        .labelsHidden().toggleStyle(.checkbox)
                        .disabled(!editable)
                        .help("Active — m_IsActive")
                }
                if let name = content.name?.value.scalar, !name.multiline {
                    CommitField(value: name.text, numeric: false, prominent: true) { text in
                        commit(UnityEdits.scalar(name, text: text, numeric: false), name: L("Переименование"))
                    }
                    .disabled(!editable)
                } else {
                    Text(content.title).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .help(content.title)
                }
            }
            if content.tag != nil || content.layer != nil {
                HStack(spacing: 6) {
                    if let tag = content.tag?.value.scalar {
                        Text("Tag").font(.system(size: 11)).foregroundStyle(.secondary)
                        CommitField(value: tag.text, numeric: false) { text in
                            commit(UnityEdits.scalar(tag, text: text, numeric: false), name: L("Тег"))
                        }
                    }
                    if let layer = content.layer?.value.scalar {
                        Text("Layer").font(.system(size: 11)).foregroundStyle(.secondary)
                        CommitField(value: layer.text, numeric: true) { text in
                            commit(UnityEdits.scalar(layer, text: text, numeric: true), name: L("Слой"))
                        }
                        .frame(width: 44)
                    }
                }
                .disabled(!editable)
            }
            if let source = content.source {
                assetLink(label: content.kind == .prefabInstance ? L("Префаб") : L("Скрипт"), guid: source, fileID: nil)
            }
            if !content.children.isEmpty {
                Foldout(title: L("Дети · \(content.children.count)"), isExpanded: expansion("children")) {
                    ForEach(Array(content.children.enumerated()), id: \.offset) { _, child in
                        Button { reveal(child) } label: {
                            Label(child.name, systemImage: child.isPrefab ? "cube.transparent" : "cube")
                                .font(.system(size: 11))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        .help(child.name)
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    /// Путь от корня. Прокручен к концу: ближние предки нужнее, чем корень.
    private func breadcrumbs(_ path: [UnityInspectorContent.Link]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(path.enumerated()), id: \.offset) { _, link in
                    Button(link.name) { reveal(link) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .defaultScrollAnchor(.trailing)
    }

    private func icon(for kind: UnityInspectorContent.Kind) -> String {
        switch kind {
        case .gameObject:     return "cube.fill"
        case .prefabInstance: return "cube.transparent.fill"
        case .asset:          return "doc.badge.gearshape.fill"
        }
    }

    // MARK: - Компонент

    @ViewBuilder
    private func sectionView(_ section: UnityInspectorContent.Section, focused: Bool, editable: Bool,
                             metrics: RowMetrics) -> some View {
        let isCollapsed = collapsed.contains(section.fileID)
        let context = RowContext(
            script: section.script,
            info: unity.scriptInfo(for: section.script),
            unity: unity, file: file,
            editable: editable, metrics: metrics,
            commit: { edit, name in commit(edit, name: name) },
            commitMany: { edits, name in commit(edits, name: name) },
            reveal: actions.reveal,
            openAsset: actions.openAsset,
            expansion: { expansion($0) })

        let toggleCollapsed = {
            if isCollapsed { collapsed.remove(section.fileID) } else { collapsed.insert(section.fileID) }
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: toggleCollapsed) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -4)
                Image(systemName: section.script != nil ? "chevron.left.forwardslash.chevron.right"
                                                        : "puzzlepiece.extension")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let enabled = section.enabled?.value.scalar, section.typeName != "PrefabInstance" {
                    Toggle("", isOn: toggleBinding(enabled, name: L("Включение компонента")))
                        .labelsHidden().toggleStyle(.checkbox)
                        .disabled(!editable)
                }
                // Длинное имя скрипта — в одну строку: кнопка скрипта справа
                // не должна уезжать, а целиком имя — в подсказке.
                Button { actions.reveal(section.fileID) } label: {
                    Text(section.title).font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help(section.title + "\n" + L("Показать в тексте"))
                Spacer(minLength: 0)
                if let script = section.script, section.typeName != "PrefabInstance" {
                    Button { actions.openAsset(script, nil) } label: {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help(L("Открыть скрипт"))
                }
            }
            // Сворачивается кликом по пустому месту шапки, а не только по стрелке.
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleCollapsed)
            if !isCollapsed {
                let properties = debug ? section.allProperties : section.properties
                if section.isTransform && !debug {
                    TransformRows(properties: section.allProperties, context: context)
                    ForEach(properties.filter { !TransformRows.keys.contains($0.key) }, id: \.line) { property in
                        PropertyRow(property: property, path: "\(section.fileID)", depth: 0, context: context)
                    }
                } else if properties.isEmpty {
                    Text(L("Нет полей")).font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    ForEach(properties, id: \.line) { property in
                        PropertyRow(property: property, path: "\(section.fileID)", depth: 0, context: context)
                    }
                }
            }
        }
        .padding(RowMetrics.sectionPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(focused ? Color(nsColor: Theme.unityEvent).opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color(nsColor: Theme.unityEvent).opacity(0.45) : .clear, lineWidth: 1))
    }

    // MARK: - Действия

    private func commit(_ edit: UnityEdit?, name: String) {
        guard let edit else { return }
        commit([edit], name: name)
    }

    private func commit(_ edits: [UnityEdit], name: String) {
        guard !edits.isEmpty else { return }
        actions.commit(edits, name)
    }

    private func toggleBinding(_ scalar: UnityScalar, name: String) -> Binding<Bool> {
        Binding(get: { scalar.raw == "1" },
                set: { commit(UnityEdits.scalar(scalar, text: $0 ? "1" : "0", numeric: true), name: name) })
    }

    private func reveal(_ link: UnityInspectorContent.Link) {
        actions.reveal(link.fileID)
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    private func assetLink(label: String, guid: UnityGUID, fileID: Int64?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            AssetButton(guid: guid, fileID: fileID, unity: unity) {
                actions.openAsset(guid, fileID)
            }
        }
    }
}

// MARK: - Колонки строк

/// Колонки строк, как в инспекторе Unity: подписи — чуть меньше половины
/// ширины, но не уже 84 и не шире 180 pt. Значения всех уровней стоят в одну
/// колонку: вложенная строка сдвинута на отступ и ровно на него же короче
/// её подпись. Раньше подпись была шириной 118 pt при любой ширине: в узкой
/// колонке векторам оставалось по 8 pt на поле, а вложенные значения
/// съезжали влево на 12 pt за уровень.
struct RowMetrics {
    static let formPadding: CGFloat = 12
    static let sectionPadding: CGFloat = 8
    static let spacing: CGFloat = 6
    /// Сдвиг вложенного уровня.
    static let indent: CGFloat = 12

    /// Ширина строки верхнего уровня внутри компонента.
    let rowWidth: CGFloat
    let labelWidth: CGFloat

    init(formWidth: CGFloat) {
        rowWidth = max(0, formWidth - 2 * Self.formPadding - 2 * Self.sectionPadding)
        labelWidth = min(max((rowWidth * 0.42).rounded(), 84), 180)
    }

    /// Места под значение — одно и то же на любом уровне вложенности.
    var valueWidth: CGFloat { max(0, rowWidth - labelWidth - Self.spacing) }

    func labelWidth(depth: Int) -> CGFloat { max(36, labelWidth - CGFloat(depth) * Self.indent) }

    /// Сколько нужно вектору или цвету (`AxisFields`): поле с подписью оси
    /// должно показывать хотя бы «-0.125». Уже — значение уходит на строку
    /// под подписью.
    static func axisWidth(cells: Int, swatch: Bool) -> CGFloat {
        CGFloat(cells) * 48 + CGFloat(max(0, cells - 1)) * 4 + (swatch ? 20 : 0)
    }
}

// MARK: - Контекст строк

/// Всё, что нужно строке поля: типы из скрипта, резолв ссылок и действия.
@MainActor
struct RowContext {
    var script: UnityGUID?
    var info: UnityCSharp.ScriptInfo?
    var unity: UnityService
    var file: UnityYAMLFile
    /// Можно ли сейчас править: разбор свежий и файл не из мерж-реквеста.
    /// Ссылки и раскрытие от этого не зависят.
    var editable: Bool
    var metrics: RowMetrics
    var commit: (UnityEdit?, String) -> Void
    var commitMany: ([UnityEdit], String) -> Void
    var reveal: (Int64) -> Void
    var openAsset: (UnityGUID, Int64?) -> Void
    var expansion: (String) -> Binding<Bool>

    enum Editor {
        case toggle
        case choice([UnityCSharp.EnumMember])
        case number
        case text
    }

    /// Как показывать скаляр: bool и enum узнаются по типу поля в скрипте,
    /// у встроенных компонентов — по имени.
    func editor(for key: String, scalar: UnityScalar) -> Editor {
        let type = info?.type(ofKey: key)
        if type == "bool" { return .toggle }
        if let type, !Self.numericTypes.contains(type), type != "string",
           let members = unity.enumMembers(type, script: script) {
            return .choice(members)
        }
        if type == nil, UnityInspector.looksBoolean(key, scalar) { return .toggle }
        if let type { return Self.numericTypes.contains(type) ? .number : (type == "string" ? .text : fallback(scalar)) }
        return fallback(scalar)
    }

    private func fallback(_ scalar: UnityScalar) -> Editor { scalar.number != nil ? .number : .text }

    static let numericTypes: Set<String> = ["int", "float", "double", "long", "short", "byte", "uint",
                                            "ulong", "ushort", "sbyte", "decimal"]
}

// MARK: - Строка поля

/// Подпись и значение в две колонки. Значению, которому колонки мало
/// (вектор в узком инспекторе), — своя строка под подписью, как в Unity в
/// узком окне. Не влезшая подпись обрезается, целиком она в подсказке.
struct FieldRow<Value: View>: View {
    let title: String
    let help: String
    let depth: Int
    let metrics: RowMetrics
    var minValueWidth: CGFloat = 0
    @ViewBuilder var value: Value

    var body: some View {
        if metrics.valueWidth >= minValueWidth {
            HStack(alignment: .firstTextBaseline, spacing: RowMetrics.spacing) {
                label.frame(width: metrics.labelWidth(depth: depth), alignment: .leading)
                value.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                label
                value.padding(.leading, RowMetrics.indent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var label: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(help)
    }
}

/// Подпись раскрывающейся группы, по которой можно щёлкнуть целиком:
/// у DisclosureGroup на macOS раскрывает только стрелка, а она крошечная.
/// Инспектор теперь раскрывает свои группы через `Foldout`, а этой подписью
/// пользуются Настройки → Кэши.
struct DisclosureLabel<Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: Label

    var body: some View {
        Button { isExpanded.toggle() } label: {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Раскрывающаяся группа: список, вложенная структура, дети объекта.
/// Щёлкается вся строка, а не только стрелка. Содержимое — со сдвигом на
/// уровень и прижато влево: `DisclosureGroup` ставил короткие строки
/// («None», флажки, ссылки на детей) посередине, и они прыгали по ширине.
struct Foldout<Content: View>: View {
    let title: String
    var help: String = ""
    var count: Int? = nil
    @Binding var isExpanded: Bool
    /// Строится, только когда группа раскрыта: списки бывают на тысячи элементов.
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let count {
                        Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) { content() }
                    .padding(.leading, RowMetrics.indent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct PropertyRow: View {
    let property: UnityProperty
    /// Путь от компонента — ключ состояния «раскрыто».
    let path: String
    let depth: Int
    let context: RowContext
    var label: String? = nil

    private var key: String { path + "/" + property.key }
    private var title: String { label ?? property.displayName }
    /// Подпись могла не влезть — в подсказке она целиком и ключ из файла.
    private var help: String { title == property.key ? title : title + "\n" + property.key }

    var body: some View {
        switch property.value {
        case .scalar(let scalar):
            FieldRow(title: title, help: help, depth: depth, metrics: context.metrics) {
                scalarEditor(scalar)
            }
        case .flow(let fields):
            flowRow(fields)
        case .mapping(let children):
            Foldout(title: title, help: help, isExpanded: context.expansion(key)) {
                ForEach(children, id: \.line) { child in
                    PropertyRow(property: child, path: key, depth: depth + 1, context: context)
                }
            }
        case .sequence(let items):
            Foldout(title: title, help: help, count: items.count, isExpanded: context.expansion(key)) {
                ForEach(Array(items.enumerated()), id: \.element.line) { index, item in
                    PropertyRow(property: item, path: key, depth: depth + 1, context: context,
                                label: "Element \(index)")
                }
            }
        }
    }

    @ViewBuilder
    private func scalarEditor(_ scalar: UnityScalar) -> some View {
        if scalar.multiline || scalar.raw.count > 160 {
            Text(scalar.raw.count > 160 ? L("\(scalar.text.prefix(60))… (\(scalar.raw.count) симв.)") : scalar.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .help(L("Многострочные и очень длинные значения правятся в тексте"))
        } else {
            switch context.editor(for: property.key, scalar: scalar) {
            case .toggle:
                Toggle("", isOn: Binding(
                    get: { scalar.raw == "1" || scalar.raw == "true" },
                    set: { context.commit(UnityEdits.scalar(scalar, text: $0 ? "1" : "0", numeric: true), title) }))
                    .labelsHidden().toggleStyle(.checkbox)
                    .disabled(!context.editable)
            case .choice(let members):
                Picker("", selection: Binding(
                    get: { Int(scalar.raw) ?? Int.min },
                    set: { context.commit(UnityEdits.scalar(scalar, text: String($0), numeric: true), title) })) {
                    if !members.contains(where: { String($0.value) == scalar.raw }) {
                        Text(scalar.raw).tag(Int(scalar.raw) ?? Int.min)
                    }
                    ForEach(members, id: \.value) { member in
                        Text(member.name).tag(member.value)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .disabled(!context.editable)
            case .number:
                CommitField(value: scalar.text, numeric: true) { text in
                    let edit = UnityEdits.scalar(scalar, text: text, numeric: true)
                    context.commit(edit, title)
                    return edit != nil || UnityNumber.parse(text) != nil
                }
                .disabled(!context.editable)
            case .text:
                CommitField(value: scalar.text, numeric: false) { text in
                    context.commit(UnityEdits.scalar(scalar, text: text, numeric: false), title)
                    return true
                }
                .disabled(!context.editable)
            }
        }
    }

    @ViewBuilder
    private func flowRow(_ fields: [UnityFlowField]) -> some View {
        let keys = Set(fields.map(\.key))
        if let reference = property.value.reference {
            FieldRow(title: title, help: help, depth: depth, metrics: context.metrics) {
                ReferenceView(fileID: reference.fileID, guid: reference.guid, context: context)
            }
        } else if keys.isSubset(of: ["x", "y", "z", "w"]) || keys == ["r", "g", "b", "a"] {
            let color = keys == ["r", "g", "b", "a"]
            FieldRow(title: title, help: help, depth: depth, metrics: context.metrics,
                     minValueWidth: RowMetrics.axisWidth(cells: fields.count, swatch: color)) {
                AxisFields(swatch: color ? fields : nil) {
                    ForEach(fields, id: \.key) { field in
                        AxisField(axis: field.key, value: field.raw, editable: context.editable) { text in
                            let edit = UnityEdits.number(field, text: text)
                            context.commit(edit, title)
                            return edit != nil || UnityNumber.parse(text) != nil
                        }
                    }
                }
            }
        } else {
            FieldRow(title: title, help: help, depth: depth, metrics: context.metrics) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fields, id: \.key) { field in
                        HStack(spacing: 4) {
                            Text(field.key).font(.system(size: 10)).foregroundStyle(.tertiary)
                                .lineLimit(1)
                            CommitField(value: field.raw, numeric: Double(field.raw) != nil) { text in
                                let edit = Double(field.raw) != nil ? UnityEdits.number(field, text: text) : nil
                                context.commit(edit, title)
                                return edit != nil
                            }
                            .disabled(!context.editable)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Векторы и цвета

/// Компоненты вектора или цвета в одну строку — поровну места каждой.
struct AxisFields<Cells: View>: View {
    /// У цвета перед полями — образец.
    var swatch: [UnityFlowField]? = nil
    @ViewBuilder var cells: Cells

    var body: some View {
        HStack(spacing: 4) {
            if let swatch { ColorSwatch(fields: swatch) }
            cells
        }
    }
}

/// Одна компонента вектора или цвета с подписью оси.
struct AxisField: View {
    let axis: String
    let value: String
    let editable: Bool
    let commit: (String) -> Bool

    var body: some View {
        HStack(spacing: 2) {
            Text(axis.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(axisColor)
                .frame(minWidth: 7)
            CommitField(value: value, numeric: true, onCommit: commit)
                .disabled(!editable)
        }
        .frame(maxWidth: .infinity)
    }

    private var axisColor: Color {
        switch axis {
        case "x", "r": return .red.opacity(0.8)
        case "y", "g": return .green.opacity(0.8)
        case "z", "b": return .blue.opacity(0.9)
        default:       return .secondary
        }
    }
}

private struct ColorSwatch: View {
    let fields: [UnityFlowField]

    var body: some View {
        let value = { (key: String) in Double(fields.first { $0.key == key }?.raw ?? "") ?? 0 }
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(.sRGB, red: value("r"), green: value("g"), blue: value("b"), opacity: max(value("a"), 0.15)))
            .frame(width: 16, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.2)))
    }
}

// MARK: - Transform

/// Position, Rotation и Scale — как в Unity: поворот углами Эйлера,
/// а в файл пишется кватернион (и подсказка углов, если она там есть).
struct TransformRows: View {
    static let keys: Set<String> = ["m_LocalPosition", "m_LocalRotation", "m_LocalScale", "m_LocalEulerAnglesHint"]

    let properties: [UnityProperty]
    let context: RowContext

    var body: some View {
        if let position = properties.first(where: { $0.key == "m_LocalPosition" }) {
            PropertyRow(property: position, path: "t", depth: 0, context: context, label: "Position")
        }
        if let rotation = properties.first(where: { $0.key == "m_LocalRotation" })?.value.flowFields {
            let euler = eulerAngles(rotation)
            FieldRow(title: "Rotation", help: "Rotation\nm_LocalRotation", depth: 0, metrics: context.metrics,
                     minValueWidth: RowMetrics.axisWidth(cells: 3, swatch: false)) {
                AxisFields {
                    ForEach(["x", "y", "z"], id: \.self) { axis in
                        AxisField(axis: axis, value: UnityNumber.format(component(euler, axis)),
                                  editable: context.editable) { text in
                            guard let value = UnityNumber.parse(text) else { return false }
                            var e = euler
                            switch axis {
                            case "x": e.x = value
                            case "y": e.y = value
                            default:  e.z = value
                            }
                            context.commitMany(UnityEdits.rotation(of: properties, euler: e), L("Поворот"))
                            return true
                        }
                    }
                }
            }
        }
        if let scale = properties.first(where: { $0.key == "m_LocalScale" }) {
            PropertyRow(property: scale, path: "t", depth: 0, context: context, label: "Scale")
        }
    }

    /// Подсказка углов из файла, если она совпадает с кватернионом: так
    /// сохраняются введённые в Unity -90 или 370. Иначе — считаем сами.
    private func eulerAngles(_ q: [UnityFlowField]) -> (x: Double, y: Double, z: Double) {
        let v = { (key: String) in Double(q.first { $0.key == key }?.raw ?? "") ?? 0 }
        let (x, y, z, w) = (v("x"), v("y"), v("z"), v("w"))
        if let hint = properties.first(where: { $0.key == "m_LocalEulerAnglesHint" })?.value.flowFields {
            let h = { (key: String) in Double(hint.first { $0.key == key }?.raw ?? "") ?? 0 }
            let e = (x: h("x"), y: h("y"), z: h("z"))
            let fromHint = UnityRotation.quaternion(x: e.x, y: e.y, z: e.z)
            if abs(abs(fromHint.x * x + fromHint.y * y + fromHint.z * z + fromHint.w * w) - 1) < 1e-4 { return e }
        }
        return UnityRotation.euler(x: x, y: y, z: z, w: w)
    }

    private func component(_ e: (x: Double, y: Double, z: Double), _ axis: String) -> Double {
        axis == "x" ? e.x : axis == "y" ? e.y : e.z
    }
}

// MARK: - Ссылки

struct ReferenceView: View {
    let fileID: Int64
    let guid: UnityGUID?
    let context: RowContext

    var body: some View {
        if let guid {
            AssetButton(guid: guid, fileID: fileID, unity: context.unity) { context.openAsset(guid, fileID) }
        } else if fileID == 0 {
            Text("None").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else if let index = context.file.index(ofFileID: fileID) {
            // Путь обрезается с начала: важнее, чем он кончается, — объект и компонент.
            let description = context.file.describe(objectAt: index,
                                                    resolve: { context.unity.assets?.displayName(for: $0) })
            Button { context.reveal(fileID) } label: {
                Label(description, systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.head)
            }
            .buttonStyle(.link)
            .help(description)
        } else {
            Text("Missing (&\(fileID))").font(.system(size: 11)).foregroundStyle(Color(nsColor: Theme.brokenLink))
        }
    }
}

struct AssetButton: View {
    let guid: UnityGUID
    let fileID: Int64?
    let unity: UnityService
    let action: () -> Void

    var body: some View {
        if guid.isBuiltin {
            Text(L("Встроенный ресурс")).font(.system(size: 11)).foregroundStyle(.tertiary)
        } else if let path = unity.assets?.path(for: guid) {
            Button(action: action) {
                Label((path as NSString).lastPathComponent,
                      systemImage: Workspace.icon(forPath: path))
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help(UnityProjectInfo.prettyPath(path))
        } else if unity.assets == nil {
            Text(guid.description.prefix(8) + "…").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        } else {
            Text("Missing").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.brokenLink))
                .help(L("Ассета с GUID \(guid) в проекте нет"))
        }
    }
}

// MARK: - Поле ввода

/// Поле, которое пишет значение по Return или при потере фокуса — как в
/// Unity. Некорректный ввод откатывается.
struct CommitField: View {
    let value: String
    let numeric: Bool
    var prominent = false
    /// `false` — ввод не принят, вернуть прежнее значение.
    let onCommit: (String) -> Bool

    @State private var text: String
    @FocusState private var focused: Bool

    init(value: String, numeric: Bool, prominent: Bool = false, onCommit: @escaping (String) -> Bool) {
        self.value = value
        self.numeric = numeric
        self.prominent = prominent
        self.onCommit = onCommit
        _text = State(initialValue: value)
    }

    init(value: String, numeric: Bool, prominent: Bool = false, onCommit: @escaping (String) -> Void) {
        self.init(value: value, numeric: numeric, prominent: prominent) { text in onCommit(text); return true }
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(prominent ? .system(size: 13, weight: .semibold)
                            : .system(size: 11, design: numeric ? .monospaced : .default))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: value) { _, newValue in text = newValue }
    }

    private func commit() {
        guard text != value else { return }
        if !onCommit(text) {
            NSSound.beep()
            text = value
        }
    }
}

// MARK: - Отступ под тулбар

/// Сколько сверху вид закрывают тулбар и полоса вкладок окна — по самому
/// окну, а не по безопасной зоне SwiftUI.
///
/// Колонка `.inspector` (macOS 26–27) отступает от тулбара дважды: кладёт
/// содержимое ниже тулбара и ещё раз отдаёт ту же высоту в безопасную зону,
/// и `ScrollView` отступает снова. Над формой висела пустая полоса ростом в
/// тулбар, а с полосой вкладок окна — пара проектов вкладками — ещё выше.
/// Поэтому форма безопасную зону сверху не слушает, а отступ берёт отсюда:
/// насколько настоящий верх колонки заходит выше `contentLayoutRect` окна.
/// Меряется от самого окна, так что отступ выйдет верным и там, где SwiftUI
/// отступает один раз, и там, где колонка под тулбар не заходит вовсе.
private struct WindowChromeProbe: NSViewRepresentable {
    @Binding var top: CGFloat?

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        let top = $top
        probe.report = { value in
            // Не посреди обновления вьюхи.
            DispatchQueue.main.async {
                if top.wrappedValue.map({ abs($0 - value) > 0.5 }) ?? true { top.wrappedValue = value }
            }
        }
        probe.measure()
    }

    final class Probe: NSView {
        var report: ((CGFloat) -> Void)?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Полоса вкладок появляется со второй вкладкой, тулбар меняет
            // высоту с режимом окна — об этом скажет само окно.
            observation = window?.observe(\.contentLayoutRect) { [weak self] _, _ in
                DispatchQueue.main.async { self?.measure() }
            }
            measure()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            measure()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            measure()
        }

        func measure() {
            guard let window, let report, !bounds.isEmpty else { return }
            let frame = convert(bounds, to: nil)
            report(max(0, frame.maxY - window.contentLayoutRect.maxY))
        }

        /// Щелчки — сквозь него.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
