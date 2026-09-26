import SwiftUI
import AppKit

/// Консоль под редактором, как область отладки Xcode: вывод запущенной
/// цели. Высоту тянут за верхний край, и она переживает перезапуск.
struct RunConsole: View {
    @ObservedObject var run: RunService
    @AppStorage("pilot.consoleHeight") private var height: Double = 220
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            ConsoleTextView(log: run.log)
        }
        .frame(height: height)
        .background(Color(nsColor: Theme.chromeBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
        .overlay(alignment: .top) { resizeHandle }
    }

    private var header: some View {
        HStack(spacing: 8) {
            stateIcon
            Text(run.current?.name ?? "Консоль")
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            Text(stateText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button { run.log.clear() } label: { Image(systemName: "trash") }
                .help("Очистить")
            if run.isRunning {
                Button { run.stop() } label: { Image(systemName: "stop.fill") }
                    .help(KeymapStore.shared.help("Остановить", .stop))
                    .disabled(run.state == .stopping)
            } else {
                Button { run.run() } label: { Image(systemName: "play.fill") }
                    .help(KeymapStore.shared.help("Запустить ещё раз", .run))
                    .disabled(run.selected == nil)
            }
            Button { run.showsConsole = false } label: { Image(systemName: "xmark") }
                .help(KeymapStore.shared.help("Скрыть консоль", .toggleConsole))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch run.state {
        case .running:
            Circle().fill(Color(nsColor: Theme.gitAdded)).frame(width: 7, height: 7)
        case .stopping:
            ProgressView().controlSize(.mini)
        case .exited(let code):
            Image(systemName: code == 0 ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(code == 0 ? Color(nsColor: Theme.gitAdded) : Color(nsColor: Theme.diagnosticError))
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color(nsColor: Theme.diagnosticError))
        case .idle:
            Image(systemName: "terminal").foregroundStyle(.secondary)
        }
    }

    private var stateText: String {
        switch run.state {
        case .idle: return ""
        case .running: return "работает"
        case .stopping: return "останавливается…"
        case .exited(let code): return code == 0 ? "завершилось" : "код \(code)"
        case .failed(let message): return message
        }
    }

    /// Полоска у верхнего края: тянешь — консоль выше, редактор ниже.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? height
                    dragStart = start
                    height = min(max(start - value.translation.height, 80), 900)
                }
                .onEnded { _ in dragStart = nil })
    }
}

/// Текст вывода — NSTextView: дописывается кусками, выделяется и копируется,
/// ищется ⌘F. Прокрутка держится у низа, пока её не увели вверх.
struct ConsoleTextView: NSViewRepresentable {
    let log: RunLog

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.usesFindBar = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.textContainer?.widthTracksTextView = true
        context.coordinator.attach(text, scroll: scroll, log: log)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.attach(view.documentView as! NSTextView, scroll: view, log: log)
    }

    @MainActor
    final class Coordinator {
        private weak var text: NSTextView?
        private weak var scroll: NSScrollView?
        private weak var log: RunLog?

        private var attributes: [NSAttributedString.Key: Any] {
            [.font: Theme.editorFont(size: 11.5),
             .foregroundColor: Theme.color(.plain)]
        }

        func attach(_ text: NSTextView, scroll: NSScrollView, log: RunLog) {
            guard self.text !== text || self.log !== log else { return }
            self.text = text
            self.scroll = scroll
            self.log = log
            log.onAppend = { [weak self] chunk in self?.append(chunk) }
            log.onReset = { [weak self] in self?.reload() }
            reload()
        }

        private func reload() {
            guard let text, let log else { return }
            text.textStorage?.setAttributedString(NSAttributedString(string: log.text, attributes: attributes))
            text.scrollToEndOfDocument(nil)
        }

        private func append(_ chunk: String) {
            guard let text, let storage = text.textStorage else { return }
            let follow = isAtBottom
            storage.append(NSAttributedString(string: chunk, attributes: attributes))
            if follow { text.scrollToEndOfDocument(nil) }
        }

        private var isAtBottom: Bool {
            guard let scroll, let document = scroll.documentView else { return true }
            let visible = scroll.contentView.documentVisibleRect
            return visible.maxY >= document.bounds.height - 24
        }
    }
}
