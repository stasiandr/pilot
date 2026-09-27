import AppKit
import SwiftUI

/// Что показывает окно подсказки у текста.
enum InfoContent {
    /// Ошибки в этом месте — почему оно подчёркнуто — и документация имени:
    /// мышь над ним, ⌃J, ⌘F1 (там — только ошибки). `fix` — строка о том,
    /// чем их исправит ⌘., если есть чем.
    case documentation(RustlynDocumentation?, problems: [RustlynDiagnostic], fix: String? = nil)
    /// Перегрузки набираемого вызова: подходящая выделена, параметр под
    /// курсором — жирным.
    case signatures(RustlynSignatures)
}

/// Окно подсказки над текстом: документация, ошибка, сигнатура вызова.
/// Своё окно, как у списка дополнений: поверх текста, без фокуса, и не
/// обрезается краем редактора.
final class InfoPopup {

    final class Model: ObservableObject {
        @Published var content: InfoContent?
    }

    let model = Model()
    private var panel: NSPanel?
    private var hosting: NSHostingView<InfoView>?

    static let maxWidth: CGFloat = 560

    var isVisible: Bool { panel?.isVisible == true }
    /// Что показано сейчас — чтобы подсказку параметров не прятала мышь,
    /// а документацию — набор.
    private(set) var isSignatureHelp = false

    /// `anchor` — прямоугольник строки на экране. Сигнатура встаёт над
    /// строкой, чтобы не спорить со списком дополнений под ней;
    /// документация — под, как всплывающие подсказки везде.
    func show(_ content: InfoContent, anchor: NSRect, parent: NSWindow) {
        model.content = content
        if case .signatures = content { isSignatureHelp = true } else { isSignatureHelp = false }
        let panel = self.panel ?? makePanel()
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        size.width = min(size.width, Self.maxWidth)
        let above = isSignatureHelp
        var frame = NSRect(x: anchor.minX - 8,
                           y: above ? anchor.maxY + 4 : anchor.minY - size.height - 4,
                           width: size.width, height: size.height)
        if let screen = parent.screen?.visibleFrame {
            if frame.maxY > screen.maxY { frame.origin.y = anchor.minY - size.height - 4 }
            if frame.minY < screen.minY { frame.origin.y = anchor.maxY + 4 }
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        isSignatureHelp = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        // Мышь сквозь окно: оно под курсором не должно мешать ни наведению,
        // ни клику по тексту под ним.
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: InfoView(model: model))
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }
}

// MARK: - Вид

struct InfoView: View {
    @ObservedObject var model: InfoPopup.Model

    var body: some View {
        Group {
            switch model.content {
            case .documentation(let documentation, let problems, let fix):
                DocumentationView(documentation: documentation, problems: problems, fix: fix)
            case .signatures(let signatures):
                SignaturesView(signatures: signatures)
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: InfoPopup.maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .pilotMaterial(.menu, cornerRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

private struct DocumentationView: View {
    let documentation: RustlynDocumentation?
    let problems: [RustlynDiagnostic]
    let fix: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: problem.severity.symbolName)
                        .foregroundStyle(Color(nsColor: problem.severity.color))
                    Text(problem.message).font(.system(size: 12))
                    // Код — моноширинным, как в тексте; имя источника — обычным.
                    Text(problem.origin)
                        .font(.system(size: 10, design: problem.origin == problem.code ? .monospaced : .default))
                        .foregroundStyle(.tertiary)
                }
            }
            if let fix {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text(fix)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            if let documentation {
                if !problems.isEmpty { Divider().opacity(0.4) }
                Text(documentation.signature)
                    .font(Font(Theme.editorFont(size: 12)))
                    .textSelection(.enabled)
                if !documentation.container.isEmpty {
                    Text(L("в \(documentation.container)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !documentation.summary.isEmpty {
                    Text(documentation.summary)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                }
                if !documentation.parameters.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(documentation.parameters.enumerated()), id: \.offset) { _, parameter in
                            (Text(parameter.name).font(Font(Theme.editorFont(size: 11.5))).bold()
                             + Text(" — " + parameter.text).font(.system(size: 11.5)))
                        }
                    }
                    .padding(.top, 2)
                }
                if !documentation.returns.isEmpty {
                    (Text(L("Возвращает: ")).bold() + Text(documentation.returns))
                        .font(.system(size: 11.5))
                }
            }
        }
    }
}

// MARK: - Как выглядит ошибка

extension RustlynDiagnostic.Severity {
    /// Цвет волны под текстом и значка в окне подсказки — один на двоих.
    var color: NSColor {
        switch self {
        case .error: return Theme.diagnosticError
        case .warning: return Theme.diagnosticWarning
        case .info, .hidden: return Theme.foldMarker
        }
    }

    var symbolName: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info, .hidden: return "info.circle.fill"
        }
    }
}

extension RustlynDiagnostic {
    /// Замечание сверки с парой (`PairQueries.pairDiagnostics`), а не компилятора.
    var isPairCheck: Bool { code == "PAIR" }

    /// Подпись справа от сообщения: код компилятора (`CS0103`), а где кода,
    /// понятного человеку, нет, — кто так считает.
    var origin: String {
        if isPairCheck { return L("сверка с парой") }
        return code.isEmpty ? "Rustlyn" : code
    }
}

private struct SignaturesView: View {
    let signatures: RustlynSignatures

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(signatures.items.enumerated()), id: \.offset) { index, item in
                label(item, active: index == signatures.active)
                    .opacity(index == signatures.active ? 1 : 0.55)
            }
        }
    }

    /// Подпись, в которой параметр под курсором выделен.
    private func label(_ item: RustlynSignature, active: Bool) -> Text {
        let font = Font(Theme.editorFont(size: 12))
        let text = item.label as NSString
        guard active, item.parameters.indices.contains(signatures.parameter) else {
            return Text(item.label).font(font)
        }
        let range = item.parameters[signatures.parameter]
        guard NSMaxRange(range) <= text.length else { return Text(item.label).font(font) }
        let before = text.substring(to: range.location)
        let parameter = text.substring(with: range)
        let after = text.substring(from: NSMaxRange(range))
        return Text(before).font(font)
            + Text(parameter).font(font).bold().foregroundColor(.accentColor)
            + Text(after).font(font)
    }
}
