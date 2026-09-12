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
    func flintGlass(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.flintMaterial(.hudWindow, cornerRadius: cornerRadius)
        }
        #else
        self.flintMaterial(.hudWindow, cornerRadius: cornerRadius)
        #endif
    }

    /// Интерактивный стеклянный элемент (реагирует на курсор).
    @ViewBuilder
    func flintGlassInteractive(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.flintMaterial(.selection, cornerRadius: cornerRadius)
        }
        #else
        self.flintMaterial(.selection, cornerRadius: cornerRadius)
        #endif
    }

    func flintMaterial(_ material: NSVisualEffectView.Material, cornerRadius: CGFloat) -> some View {
        self.background(VisualEffectBackground(material: material))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Группирующий контейнер: на macOS 26 соседние стеклянные элементы
/// внутри него корректно сливаются друг с другом.
struct FlintGlassGroup<Content: View>: View {
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
