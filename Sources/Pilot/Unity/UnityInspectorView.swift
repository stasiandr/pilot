import SwiftUI
import AppKit

/// Инспектор Unity: объект под курсором — GameObject со всеми компонентами,
/// вложенный префаб или ScriptableObject — в виде формы, как в редакторе Unity.
///
/// Текст остаётся источником правды: инспектор — это другой взгляд на тот же
/// файл. Правка точечно меняет значение в тексте и сразу пишется на диск;
/// ⌘Z отменяет её так же точечно.
struct UnityInspectorView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.undoManager) private var undoManager
    /// Режим отладки — как Debug-инспектор Unity: видны служебные поля.
    @AppStorage("pilot.inspectorDebug") private var debug = false
    /// Раскрытые структуры и списки, свёрнутые компоненты. Живут вне
    /// содержимого, поэтому переживают перечитывание файла после правки.
    @State private var expanded: Set<String> = []
    @State private var collapsed: Set<Int64> = []

    var body: some View {
        Group {
            if let document = workspace.document, let file = document.unityFile,
               let content = UnityInspector.content(file: file, model: document.model,
                                                    caret: workspace.caretOffset,
                                                    resolve: { workspace.unity.assets?.displayName(for: $0) }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        header(content, file: file)
                        ForEach(Array(content.sections.enumerated()), id: \.element.id) { index, section in
                            sectionView(section, focused: index == content.focusedSection,
                                        file: file, document: document)
                        }
                    }
                    .padding(12)
                }
                .disabled(workspace.isApplyingEdit)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Поставьте курсор на объект сцены, префаба или ассета")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { debug.toggle() } label: {
                    Image(systemName: debug ? "ladybug.fill" : "ladybug")
                }
                .help("Отладка: показать служебные поля, как Debug-инспектор Unity")
            }
        }
    }

    // MARK: - Шапка

    @ViewBuilder
    private func header(_ content: UnityInspectorContent, file: UnityYAMLFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !content.path.isEmpty {
                breadcrumbs(content.path)
            }
            HStack(spacing: 8) {
                Image(systemName: icon(for: content.kind))
                    .foregroundStyle(Color(nsColor: Theme.unityEvent))
                if let active = content.active?.value.scalar {
                    Toggle("", isOn: toggleBinding(active, name: "Активность"))
                        .labelsHidden().toggleStyle(.checkbox)
                        .help("Active — m_IsActive")
                }
                if let name = content.name?.value.scalar, !name.multiline {
                    CommitField(value: name.text, numeric: false, prominent: true) { text in
                        commit(UnityEdits.scalar(name, text: text, numeric: false), name: "Переименование")
                    }
                } else {
                    Text(content.title).font(.system(size: 13, weight: .semibold))
                }
            }
            if content.tag != nil || content.layer != nil {
                HStack(spacing: 6) {
                    if let tag = content.tag?.value.scalar {
                        Text("Tag").font(.system(size: 11)).foregroundStyle(.secondary)
                        CommitField(value: tag.text, numeric: false) { text in
                            commit(UnityEdits.scalar(tag, text: text, numeric: false), name: "Тег")
                        }
                    }
                    if let layer = content.layer?.value.scalar {
                        Text("Layer").font(.system(size: 11)).foregroundStyle(.secondary)
                        CommitField(value: layer.text, numeric: true) { text in
                            commit(UnityEdits.scalar(layer, text: text, numeric: true), name: "Слой")
                        }
                        .frame(width: 44)
                    }
                }
            }
            if let source = content.source {
                assetLink(label: content.kind == .prefabInstance ? "Префаб" : "Скрипт", guid: source, fileID: nil)
            }
            if !content.children.isEmpty {
                let key = "children"
                DisclosureGroup(isExpanded: expansion(key)) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(content.children.enumerated()), id: \.offset) { _, child in
                            Button { reveal(child) } label: {
                                Label(child.name, systemImage: child.isPrefab ? "cube.transparent" : "cube")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.leading, 4)
                } label: {
                    Text("Дети · \(content.children.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 2)
    }

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
    private func sectionView(_ section: UnityInspectorContent.Section, focused: Bool,
                             file: UnityYAMLFile, document: LoadedDocument) -> some View {
        let isCollapsed = collapsed.contains(section.fileID)
        let context = RowContext(
            script: section.script,
            info: workspace.unity.scriptInfo(for: section.script),
            unity: workspace.unity, file: file,
            commit: { edit, name in commit(edit, name: name) },
            commitMany: { edits, name in commit(edits, name: name) },
            reveal: { workspace.revealUnityObject(fileID: $0) },
            openAsset: { workspace.openUnityAsset(guid: $0, fileID: $1) },
            expansion: { expansion($0) },
            isExpanded: { expanded.contains($0) })

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if isCollapsed { collapsed.remove(section.fileID) } else { collapsed.insert(section.fileID) }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                }
                .buttonStyle(.plain)
                Image(systemName: section.script != nil ? "chevron.left.forwardslash.chevron.right"
                                                        : "puzzlepiece.extension")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let enabled = section.enabled?.value.scalar, section.typeName != "PrefabInstance" {
                    Toggle("", isOn: toggleBinding(enabled, name: "Включение компонента"))
                        .labelsHidden().toggleStyle(.checkbox)
                }
                Button { workspace.revealUnityObject(fileID: section.fileID) } label: {
                    Text(section.title).font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Показать в тексте")
                Spacer(minLength: 0)
                if let script = section.script, section.typeName != "PrefabInstance" {
                    Button { workspace.openUnityAsset(guid: script) } label: {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Открыть скрипт")
                }
            }
            if !isCollapsed {
                let properties = debug ? section.allProperties : section.properties
                if section.isTransform && !debug {
                    TransformRows(properties: section.allProperties, context: context)
                    ForEach(properties.filter { !TransformRows.keys.contains($0.key) }, id: \.line) { property in
                        PropertyRow(property: property, path: "\(section.fileID)", depth: 0, context: context)
                    }
                } else if properties.isEmpty {
                    Text("Нет полей").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    ForEach(properties, id: \.line) { property in
                        PropertyRow(property: property, path: "\(section.fileID)", depth: 0, context: context)
                    }
                }
            }
        }
        .padding(8)
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
        workspace.applyUnityEdits(edits, undoManager: undoManager, actionName: name)
    }

    private func toggleBinding(_ scalar: UnityScalar, name: String) -> Binding<Bool> {
        Binding(get: { scalar.raw == "1" },
                set: { commit(UnityEdits.scalar(scalar, text: $0 ? "1" : "0", numeric: true), name: name) })
    }

    private func reveal(_ link: UnityInspectorContent.Link) {
        workspace.revealUnityObject(fileID: link.fileID)
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    private func assetLink(label: String, guid: UnityGUID, fileID: Int64?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            AssetButton(guid: guid, fileID: fileID, unity: workspace.unity) {
                workspace.openUnityAsset(guid: guid, fileID: fileID)
            }
        }
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
    var commit: (UnityEdit?, String) -> Void
    var commitMany: ([UnityEdit], String) -> Void
    var reveal: (Int64) -> Void
    var openAsset: (UnityGUID, Int64?) -> Void
    var expansion: (String) -> Binding<Bool>
    var isExpanded: (String) -> Bool

    static let labelWidth: CGFloat = 118

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

struct PropertyRow: View {
    let property: UnityProperty
    /// Путь от компонента — ключ состояния «раскрыто».
    let path: String
    let depth: Int
    let context: RowContext
    var label: String? = nil

    private var key: String { path + "/" + property.key }
    private var title: String { label ?? property.displayName }

    var body: some View {
        switch property.value {
        case .scalar(let scalar):
            row { scalarEditor(scalar) }
        case .flow(let fields):
            row { flowEditor(fields) }
        case .mapping(let children):
            DisclosureGroup(isExpanded: context.expansion(key)) {
                if context.isExpanded(key) {
                    ForEach(children, id: \.line) { child in
                        PropertyRow(property: child, path: key, depth: depth + 1, context: context)
                    }
                }
            } label: {
                Text(title).font(.system(size: 11))
            }
        case .sequence(let items):
            DisclosureGroup(isExpanded: context.expansion(key)) {
                if context.isExpanded(key) {
                    ForEach(Array(items.enumerated()), id: \.element.line) { index, item in
                        PropertyRow(property: item, path: key, depth: depth + 1, context: context,
                                    label: "Element \(index)")
                    }
                }
            } label: {
                HStack {
                    Text(title).font(.system(size: 11))
                    Spacer()
                    Text("\(items.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: max(60, RowContext.labelWidth - CGFloat(depth) * 12), alignment: .leading)
                .help(property.key)
            content()
        }
    }

    @ViewBuilder
    private func scalarEditor(_ scalar: UnityScalar) -> some View {
        if scalar.multiline || scalar.raw.count > 160 {
            Text(scalar.raw.count > 160 ? "\(scalar.text.prefix(60))… (\(scalar.raw.count) симв.)" : scalar.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .help("Многострочные и очень длинные значения правятся в тексте")
        } else {
            switch context.editor(for: property.key, scalar: scalar) {
            case .toggle:
                Toggle("", isOn: Binding(
                    get: { scalar.raw == "1" || scalar.raw == "true" },
                    set: { context.commit(UnityEdits.scalar(scalar, text: $0 ? "1" : "0", numeric: true), title) }))
                    .labelsHidden().toggleStyle(.checkbox)
                Spacer(minLength: 0)
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
            case .number:
                CommitField(value: scalar.text, numeric: true) { text in
                    let edit = UnityEdits.scalar(scalar, text: text, numeric: true)
                    context.commit(edit, title)
                    return edit != nil || UnityNumber.parse(text) != nil
                }
            case .text:
                CommitField(value: scalar.text, numeric: false) { text in
                    context.commit(UnityEdits.scalar(scalar, text: text, numeric: false), title)
                    return true
                }
            }
        }
    }

    @ViewBuilder
    private func flowEditor(_ fields: [UnityFlowField]) -> some View {
        if let reference = property.value.reference {
            ReferenceView(fileID: reference.fileID, guid: reference.guid, context: context)
        } else if Set(fields.map(\.key)).isSubset(of: ["x", "y", "z", "w"]) || Set(fields.map(\.key)) == ["r", "g", "b", "a"] {
            HStack(spacing: 4) {
                if Set(fields.map(\.key)) == ["r", "g", "b", "a"] { ColorSwatch(fields: fields) }
                ForEach(fields, id: \.key) { field in
                    NumberCell(field: field, title: title, context: context)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(fields, id: \.key) { field in
                    HStack(spacing: 4) {
                        Text(field.key).font(.system(size: 10)).foregroundStyle(.tertiary)
                        CommitField(value: field.raw, numeric: Double(field.raw) != nil) { text in
                            let edit = Double(field.raw) != nil ? UnityEdits.number(field, text: text) : nil
                            context.commit(edit, title)
                            return edit != nil
                        }
                    }
                }
            }
        }
    }
}

/// Одна компонента вектора или цвета с подписью оси.
private struct NumberCell: View {
    let field: UnityFlowField
    let title: String
    let context: RowContext

    var body: some View {
        HStack(spacing: 2) {
            Text(field.key.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(axisColor)
            CommitField(value: field.raw, numeric: true) { text in
                let edit = UnityEdits.number(field, text: text)
                context.commit(edit, title)
                return edit != nil || UnityNumber.parse(text) != nil
            }
        }
    }

    private var axisColor: Color {
        switch field.key {
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Rotation").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: RowContext.labelWidth, alignment: .leading)
                HStack(spacing: 4) {
                    ForEach(["x", "y", "z"], id: \.self) { axis in
                        HStack(spacing: 2) {
                            Text(axis.uppercased()).font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(axis == "x" ? .red.opacity(0.8) : axis == "y" ? .green.opacity(0.8) : .blue.opacity(0.9))
                            CommitField(value: UnityNumber.format(component(euler, axis)), numeric: true) { text in
                                guard let value = UnityNumber.parse(text) else { return false }
                                var e = euler
                                switch axis {
                                case "x": e.x = value
                                case "y": e.y = value
                                default:  e.z = value
                                }
                                context.commitMany(UnityEdits.rotation(of: properties, euler: e), "Поворот")
                                return true
                            }
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
            Button { context.reveal(fileID) } label: {
                Label(context.file.describe(objectAt: index, resolve: { context.unity.assets?.displayName(for: $0) }),
                      systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.head)
            }
            .buttonStyle(.link)
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
            Text("Встроенный ресурс").font(.system(size: 11)).foregroundStyle(.tertiary)
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
                .help("Ассета с GUID \(guid) в проекте нет")
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
