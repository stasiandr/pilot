import SwiftUI
import AppKit

/// Окна графов значения: у каждого графа своё, рядом с окном проекта.
@MainActor
enum ValueGraphWindows {
    private static var open: [NSWindow] = []

    static func show(_ graph: ValueGraph) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("Откуда: \(graph.title)")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ValueGraphScreen(graph: graph))
        window.center()
        window.makeKeyAndOrderFront(nil)
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { open.removeAll { $0 === window } }
        }
    }
}

struct ValueGraphScreen: View {
    @ObservedObject var graph: ValueGraph
    @State private var fitRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                Text(L("Откуда берётся \(graph.title)"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("Показать всё")) { fitRequest += 1 }
                    .controlSize(.small)
                Text(L("«Кто пишет» — раскрыть · двойной клик — к коду · щипок — масштаб"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Color(nsColor: Theme.chromeBackground))
            Divider()
            GeometryReader { geometry in
                // Граф уже окна — прижат к правому краю: там исходное значение.
                let layout = GraphLayout(graph, minWidth: geometry.size.width)
                GraphScrollView(size: layout.size, fitRequest: fitRequest) {
                    GraphCanvas(graph: graph, layout: layout)
                }
            }
        }
        .background(Color(nsColor: Theme.editorBackground))
        .onChange(of: graph.settled) { _, settled in
            if settled { fitRequest += 1 }
        }
    }
}

// MARK: - Раскладка

/// Колонки по глубине: исходное значение справа, источники левее — поток
/// идёт слева направо. Узел колонки встаёт напротив тех, в кого он течёт,
/// и не налезает на соседа.
struct GraphLayout {
    var frames: [String: CGRect] = [:]
    var size: CGSize = .zero

    static let margin: CGFloat = 40
    static let columnGap: CGFloat = 90
    static let rowGap: CGFloat = 18

    @MainActor
    init(_ graph: ValueGraph, minWidth: CGFloat = 0) {
        let nodes = graph.order.compactMap { graph.nodes[$0] }
        let maxDepth = nodes.map(\.depth).max() ?? 0
        var widths: [CGFloat] = []
        for depth in 0...maxDepth {
            widths.append(nodes.filter { $0.depth == depth }.map { Self.width(of: $0) }.max() ?? 260)
        }
        // Самая глубокая колонка — у левого края.
        var columnX = [CGFloat](repeating: 0, count: maxDepth + 1)
        var x = Self.margin
        for depth in stride(from: maxDepth, through: 0, by: -1) {
            columnX[depth] = x
            x += widths[depth] + Self.columnGap
        }
        x -= Self.columnGap
        // В кого узел течёт: ребро from → to, «to» правее.
        var targets: [String: [String]] = [:]
        for edge in graph.edges { targets[edge.from, default: []].append(edge.to) }

        var bottom: CGFloat = Self.margin
        for depth in 0...maxDepth {
            struct Slot { var order: Int; var node: ValueGraph.Node; var center: CGFloat }
            var slots: [Slot] = []
            for (order, node) in nodes.enumerated() where node.depth == depth {
                let centers: [CGFloat] = (targets[node.id] ?? []).compactMap { frames[$0]?.midY }
                let sum: CGFloat = centers.reduce(0, +)
                let center: CGFloat = centers.isEmpty ? CGFloat(order) * 40 : sum / CGFloat(centers.count)
                slots.append(Slot(order: order, node: node, center: center))
            }
            slots.sort { $0.center == $1.center ? $0.order < $1.order : $0.center < $1.center }
            var next = Self.margin
            for slot in slots {
                let node = slot.node
                let center = slot.center
                let height = Self.height(of: node)
                let top = max(next, center - height / 2)
                frames[node.id] = CGRect(x: columnX[depth], y: top, width: Self.width(of: node), height: height)
                next = top + height + Self.rowGap
            }
            bottom = max(bottom, next)
        }
        size = CGSize(width: x + Self.margin, height: bottom + Self.margin)
        if size.width < minWidth {
            let shift = minWidth - size.width
            for (id, frame) in frames { frames[id] = frame.offsetBy(dx: shift, dy: 0) }
            size.width = minWidth
        }
    }

    static func width(of node: ValueGraph.Node) -> CGFloat {
        switch node.kind {
        case .site:
            let longest = (node.showsFull ? node.fullPreview : node.preview).map(\.text.count).max() ?? 40
            return min(760, max(380, CGFloat(longest) * 7.3 + 70))
        case .value, .component: return min(460, max(270, CGFloat(node.title.count) * 7.6 + 80))
        case .network, .arrival, .condition: return 260
        case .call, .parameter, .unknown: return 240
        }
    }

    static func height(of node: ValueGraph.Node) -> CGFloat {
        var height: CGFloat = 46
        if !node.preview.isEmpty {
            let lines = node.showsFull ? node.fullPreview.count : node.preview.count
            height += CGFloat(lines) * 16 + (node.fullPreview.count > node.preview.count ? 36 : 14)
        }
        if node.note != nil { height += 18 }
        if case .failed = node.state { height += 34 }
        if node.isExpandable, node.state == .collapsed { height += 30 }
        return height
    }
}

// MARK: - Холст

struct GraphCanvas: View {
    @ObservedObject var graph: ValueGraph
    let layout: GraphLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in graph.edges {
                    guard let from = layout.frames[edge.from], let to = layout.frames[edge.to] else { continue }
                    // Источник левее — линия из его правого края в левый край цели.
                    let start = CGPoint(x: from.maxX, y: from.midY)
                    let end = CGPoint(x: to.minX, y: to.midY)
                    var path = Path()
                    path.move(to: start)
                    let bend = max(40, abs(end.x - start.x) / 2)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y),
                                  control2: CGPoint(x: end.x - bend, y: end.y))
                    let color: Color
                    let dash: [CGFloat]
                    switch edge.kind {
                    case .data: color = Color.secondary.opacity(0.7); dash = []
                    case .network: color = .orange; dash = [6, 4]
                    case .condition: color = Color.purple.opacity(0.7); dash = [2, 3]
                    }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dash))
                    // Стрелка у цели.
                    var head = Path()
                    head.move(to: end)
                    head.addLine(to: CGPoint(x: end.x - 7, y: end.y - 4))
                    head.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
                    head.closeSubpath()
                    context.fill(head, with: .color(color))
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)

            ForEach(graph.order, id: \.self) { id in
                if let node = graph.nodes[id], let frame = layout.frames[id] {
                    GraphNodeView(graph: graph, node: node)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.18), value: graph.order)
    }
}

struct GraphNodeView: View {
    @ObservedObject var graph: ValueGraph
    let node: ValueGraph.Node

    private var isSelected: Bool { graph.selection == node.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(node.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if node.url != nil, node.line != nil {
                    Button { graph.open(node.id) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L("Открыть в редакторе"))
                }
            }
            if !node.preview.isEmpty { code }
            if let note = node.note {
                Text(note)
                    .font(.system(size: 10.5))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            state
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: Theme.chromeBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Color.accentColor : tint.opacity(0.55), lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(count: 2) { graph.open(node.id) }
        .onTapGesture { graph.selection = node.id }
    }

    @ViewBuilder
    private var code: some View {
        let lines = node.showsFull ? node.fullPreview : node.preview
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                let number = line.number
                HStack(spacing: 8) {
                    Text("\(number + 1)")
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, alignment: .trailing)
                    Text(Self.highlighted(line))
                        .opacity(number == node.line ? 1 : 0.75)
                        .lineLimit(1)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(number == node.line ? Color.accentColor.opacity(0.14) : .clear)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Theme.editorBackground)))
        if !node.fullPreview.isEmpty, node.fullPreview.count > node.preview.count {
            Button(node.showsFull ? L("Свернуть") : L("Весь метод")) { graph.togglePreview(node.id) }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
    }

    /// Цвета токенов — те же, что в редакторе.
    private static func highlighted(_ line: FilePreview.Line) -> AttributedString {
        guard !line.segments.isEmpty else { return AttributedString(" ") }
        var result = AttributedString()
        for segment in line.segments {
            var part = AttributedString(segment.text.replacingOccurrences(of: "\t", with: "    "))
            part.foregroundColor = Color(nsColor: Theme.color(segment.kind))
            result += part
        }
        return result
    }

    @ViewBuilder
    private var state: some View {
        switch node.state {
        case .collapsed where node.isExpandable:
            Button { graph.expand(node.id) } label: {
                Label(expandTitle, systemImage: "plus.circle")
            }
            .controlSize(.small)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("Ищу записи…")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .failed(let why):
            Text(why)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private var expandTitle: String {
        switch node.kind {
        case .component: return L("Где появляется и убирается")
        case .arrival: return L("Где её шлют")
        case .call: return L("Что возвращает")
        case .parameter: return L("Кто передаёт")
        default: return L("Кто пишет")
        }
    }

    private var icon: String {
        switch node.kind {
        case .value: return "tag"
        case .component: return "cube"
        case .site: return "pencil"
        case .condition: return "line.3.horizontal.decrease.circle"
        case .arrival: return "tray.and.arrow.down"
        case .network: return "antenna.radiowaves.left.and.right"
        case .call: return "function"
        case .parameter: return "arrow.down.to.line"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Цвет проекта: своя половина — синяя, вторая — оранжевая.
    private var tint: Color {
        switch node.kind {
        case .network: return .orange
        case .condition, .arrival: return .purple
        case .unknown: return .gray
        default: return node.project.path == graph.nodes[graph.rootID]?.project.path ? .blue : .orange
        }
    }
}

// MARK: - Прокрутка и масштаб

/// Штатная прокрутка AppKit: инерция, полосы, щипок и ⌘колесо — масштаб.
struct GraphScrollView<Content: View>: NSViewRepresentable {
    let size: CGSize
    var fitRequest = 0
    @ViewBuilder let content: () -> Content

    final class Coordinator { var placed = false; var fitRequest = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 2
        scroll.drawsBackground = false
        let host = NSHostingView(rootView: content())
        host.frame = NSRect(origin: .zero, size: size)
        scroll.documentView = host
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let host = scroll.documentView as? NSHostingView<Content> else { return }
        host.rootView = content()
        // «Показать всё»: весь граф в окне, но не крупнее натурального.
        if fitRequest != context.coordinator.fitRequest {
            context.coordinator.fitRequest = fitRequest
            let visible = scroll.contentView.frame.size
            let scale = min(1, visible.width / max(1, size.width), visible.height / max(1, size.height))
            scroll.setMagnification(max(scroll.minMagnification, scale), centeredAt: NSPoint(x: size.width / 2, y: size.height / 2))
        }
        let old = host.frame.size
        guard old != size else { return }
        host.frame.size = size
        // Исходное значение — у правого края: граф растёт влево, и то, на
        // что смотрели, должно остаться на месте.
        let clip = scroll.contentView
        if !context.coordinator.placed {
            context.coordinator.placed = true
            DispatchQueue.main.async {
                clip.scroll(to: NSPoint(x: max(0, size.width - clip.bounds.width), y: 0))
                scroll.reflectScrolledClipView(clip)
            }
        } else if size.width != old.width {
            var origin = clip.bounds.origin
            let widest = max(0, size.width - clip.bounds.width)
            origin.x = min(max(0, origin.x + size.width - old.width), widest)
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
