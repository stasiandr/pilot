import SwiftUI
import AppKit

/// Liquid Glass доступен только в SDK macOS 26. Чтобы проект собирался и
/// старым Xcode, и работал на macOS 14/15, защита двойная:
///   * `#if compiler(>=6.2)` — есть ли вообще символ в SDK (Xcode 26 = Swift 6.2);
///   * `#available(macOS 26, *)` — есть ли он в рантайме на этой машине.
/// Фолбэк — NSVisualEffectView, штатный нативный материал.
extension View {

    /// Стеклянная панель (палитра, поповеры).
    @ViewBuilder
    func pilotGlass(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.pilotMaterial(.hudWindow, cornerRadius: cornerRadius)
        }
        #else
        self.pilotMaterial(.hudWindow, cornerRadius: cornerRadius)
        #endif
    }

    /// Интерактивный стеклянный элемент (реагирует на курсор).
    @ViewBuilder
    func pilotGlassInteractive(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.pilotMaterial(.selection, cornerRadius: cornerRadius)
        }
        #else
        self.pilotMaterial(.selection, cornerRadius: cornerRadius)
        #endif
    }

    /// Стеклянная кнопка. `prominent` — залитая акцентом, для главного действия.
    @ViewBuilder
    func pilotGlassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }

    /// Тулбар без собственной подложки: над редактором видна его же тема,
    /// и стеклянные капсулы висят прямо над кодом — как в Xcode 26.
    @ViewBuilder
    func pilotTransparentToolbar() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }

    /// Панель у края прокручиваемого списка. На macOS 26 — safeAreaBar:
    /// содержимое под ней мягко размывается, как под фильтром в Xcode.
    @ViewBuilder
    func pilotEdgeBar<Bar: View>(_ edge: VerticalEdge, @ViewBuilder bar: () -> Bar) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.safeAreaBar(edge: edge, spacing: 0, content: bar)
        } else {
            self.safeAreaInset(edge: edge, spacing: 0, content: bar)
        }
        #else
        self.safeAreaInset(edge: edge, spacing: 0, content: bar)
        #endif
    }

    func pilotMaterial(_ material: NSVisualEffectView.Material, cornerRadius: CGFloat) -> some View {
        self.background(VisualEffectBackground(material: material))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Группирующий контейнер: на macOS 26 соседние стеклянные элементы
/// внутри него корректно сливаются друг с другом.
struct PilotGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension ToolbarContent {
    /// Элемент тулбара без стеклянной подложки. На macOS 26 каждый элемент
    /// по умолчанию сидит в стеклянной капсуле — заголовку окна она не нужна,
    /// в Xcode его текст лежит прямо на тулбаре.
    @ToolbarContentBuilder
    func pilotWithoutGlassBackground() -> some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}
