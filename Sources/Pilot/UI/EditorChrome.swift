import SwiftUI
import AppKit

/// Сколько места над кодом занимает окно. Как Compact Mode в Rider.
/// Тулбар остаётся всегда: в нём проект, ветка, активность и ▶.
enum EditorChrome: String, CaseIterable {
    /// Тулбар с проектом, веткой и активностью, вкладки, jump bar.
    case regular
    /// То же, но ниже: компактный тулбар, проект и ветка в одну строку.
    case compact

    static let key = "pilot.editorChrome"
    /// Путь к файлу над редактором (jump bar).
    static let jumpBarKey = "pilot.showsJumpBar"
    /// Полоса вкладок окон macOS с названиями проектов.
    static let projectTabsKey = "pilot.showsProjectTabs"

    var title: String {
        switch self {
        case .regular:  return L("Обычная")
        case .compact:  return L("Компактная")
        }
    }

    var isCompact: Bool { self != .regular }
}

/// Окно под выбранный режим. SwiftUI задаёт стиль тулбара один раз на
/// сцену (`windowToolbarStyle`), а режим меняют без перезапуска — поэтому
/// окно переключаем сами, через AppKit.
struct WindowChrome: NSViewRepresentable {
    let chrome: EditorChrome
    let projectTabs: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.chrome = chrome
        probe.projectTabs = projectTabs
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.chrome = chrome
        probe.projectTabs = projectTabs
        probe.apply()
    }

    final class Probe: NSView {
        var chrome = EditorChrome.regular
        var projectTabs = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            let style: NSWindow.ToolbarStyle = chrome.isCompact ? .unifiedCompact : .unified
            if window.toolbarStyle != style { window.toolbarStyle = style }
            // Вкладки проектов — штатные вкладки окон macOS. Выключены — новый
            // проект открывается своим окном; вкладкой — только по кнопке пары.
            // Уже собранные вкладки .disallowed не разбирает.
            let mode: NSWindow.TabbingMode = projectTabs ? .preferred : .disallowed
            if window.tabbingMode != mode { window.tabbingMode = mode }
            // Полоса — только когда в окне больше одного проекта: одну
            // вкладку не рисуем. Дальше macOS сам показывает её со второй
            // вкладкой и прячет, когда вкладка снова одна, — если полосу
            // не включили насильно, что здесь и снимаем.
            if let group = window.tabGroup, group.isTabBarVisible, group.windows.count <= 1 {
                window.toggleTabBar(nil)
            }
        }
    }
}

/// Настройки → Окно: всё, что над кодом.
struct WindowSettingsView: View {
    @AppStorage(EditorChrome.key) private var chrome = EditorChrome.regular
    @AppStorage(EditorChrome.jumpBarKey) private var showsJumpBar = true
    @AppStorage(EditorChrome.projectTabsKey) private var showsProjectTabs = false

    var body: some View {
        Form {
            Picker(L("Верхняя панель"), selection: $chrome) {
                ForEach(EditorChrome.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent(L("Кнопки на панели")) {
                Button(L("Настроить…")) { Self.customizeToolbar() }
            }
            Toggle(L("Путь к файлу над редактором"), isOn: $showsJumpBar)
            Toggle(L("Вкладки проектов"), isOn: $showsProjectTabs)
            Text(L("Проекты открываются вкладками одного окна; полоса с названиями — когда их больше одного. Выключено — каждый проект в своём окне, а вторая половина пары — вкладкой по своей кнопке."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 280)
    }

    /// Окно настройки тулбара — у окна проекта: у настроек своего тулбара нет.
    @MainActor
    static func customizeToolbar() {
        let windows = ProjectWindows.shared
        guard let window = (windows.front ?? windows.workspaces.first)?.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.toolbar?.runCustomizationPalette(nil)
    }
}
