import SwiftUI
import AppKit

/// Окно проекта для `Pilot --render-inspector … --window 1496x938`. Навигатор
/// и редактор здесь — заглушки, а колонка инспектора (`unityInspector`, как в
/// RootView), тулбар с кнопкой пары, полоса вкладок окна и консоль Unity —
/// настоящие. Так видно то, чего не видно в одной форме: как колонка встаёт
/// под тулбар и вкладки и что делается в узком окне пары.
struct InspectorWindowPreview<Form: View>: View {
    let form: Form
    let pairLabel: String?
    let console: Bool
    @State private var presented = true

    var body: some View {
        NavigationSplitView {
            List(0..<40, id: \.self) { Text("File\($0).cs") }
                .navigationSplitViewColumnWidth(min: 275, ideal: 280, max: 480)
        } detail: {
            VStack(spacing: 0) {
                HStack { Text("Prefab.prefab"); Text("Script.cs").foregroundStyle(.secondary); Spacer() }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Color(nsColor: Theme.chromeBackground))
                ScrollView {
                    Text((0..<80).map { "  m_Field\($0): {fileID: 0}" }.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if console {
                    UnityConsolePanel(console: UnityConsole(url: URL(fileURLWithPath: "/nonexistent")),
                                      open: { _, _, _ in })
                }
                HStack { Text("Unity YAML"); Spacer(); Text("Line: 1   Column: 1") }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(height: 24)
            }
            .background(Color(nsColor: Theme.editorBackground).ignoresSafeArea())
            .unityInspector(isPresented: $presented) { form }
            .toolbar(id: "pilot.inspector-preview") {
                ToolbarItem(id: "title", placement: .automatic) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("clm-client").font(.system(size: 13, weight: .semibold))
                        Text("develop").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(id: "run", placement: .automatic) {
                    Button { } label: { Label("Run", systemImage: "play.fill") }
                }
                ToolbarItem(id: "stop", placement: .automatic) {
                    Button { } label: { Label("Stop", systemImage: "stop.fill") }
                }
                ToolbarItem(id: "target", placement: .automatic) {
                    Menu { Button("Unity Editor") {} } label: { Text("Unity Editor") }
                }
                ToolbarItem(id: "pair", placement: .automatic) {
                    if let pairLabel {
                        Button { } label: {
                            Label(pairLabel, systemImage: "arrow.left.arrow.right").labelStyle(.titleAndIcon)
                        }
                    }
                }
                ToolbarItem(id: "search", placement: .automatic) {
                    Button { } label: { Label("Search", systemImage: "magnifyingglass") }
                }
                ToolbarItem(id: "inspector", placement: .automatic) {
                    Button { presented.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                }
            }
            .pilotTransparentToolbar()
        }
        .frame(minWidth: 860, minHeight: 520)
    }
}

extension HeadlessInspector {
    /// Окно с тулбаром, как у проекта, — тоже невидимое. Снимок — вместе с
    /// рамкой окна: тулбаром и полосой вкладок.
    static func renderWindow<Form: View>(_ form: Form, size: CGSize, compact: Bool, tabs: Bool,
                                         pair: String?, console: Bool) -> Data? {
        let window = OffscreenWindow(size: size, titled: true)
        window.toolbarStyle = compact ? .unifiedCompact : .unified
        window.titleVisibility = .hidden
        let controller = NSHostingController(rootView: InspectorWindowPreview(form: form, pairLabel: pair,
                                                                              console: console)
            .environment(\.colorScheme, Theme.current.isDark ? .dark : .light))
        controller.sceneBridgingOptions = .all
        window.contentViewController = controller
        window.toolbar?.autosavesConfiguration = false
        window.setContentSize(size)
        // Полоса вкладок — как у пары проектов вкладками одного окна.
        window.tabbingMode = tabs ? .preferred : .disallowed
        if tabs { window.toggleTabBar(nil) }
        guard let frame = window.contentView?.superview else { return nil }
        settle(frame)
        log("окно \(Int(size.width))×\(Int(size.height)): рамка сверху "
            + "\(Int(size.height - window.contentLayoutRect.maxY)) pt")
        let data = snapshot(frame, scale: 1)
        if tabs { window.toggleTabBar(nil) }
        return data
    }
}
