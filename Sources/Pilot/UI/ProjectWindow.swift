import SwiftUI
import AppKit

/// Окно проекта. Воркспейс — свой у каждого окна: индекс, компиляция, git,
/// вкладки. Меню видит его через `focusedSceneObject`, пока окно впереди.
struct ProjectWindow: View {
    @StateObject private var workspace = Workspace()
    @ObservedObject private var language = LanguageStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Язык сменился — интерфейс окна строится заново; проект остаётся.
        RootView(workspace: workspace)
            .id(language.current)
            .focusedSceneObject(workspace)
            .animation(.easeOut(duration: 0.07), value: workspace.isPaletteOpen)
            // Путь из командной строки открывается, когда окно уже есть:
            // оно должно появиться мгновенно, а индексация идёт фоном.
            .background(WindowReader { window in
                ProjectWindows.shared.openWindow = openWindow
                workspace.attach(to: window)
            })
    }
}

/// NSWindow, в котором оказался SwiftUI-вид.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Со следующего хода: SwiftUI ещё собирает окно, а открытие
            // проекта меняет его состояние.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                self.onWindow?(window)
            }
        }
    }
}
