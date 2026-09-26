import SwiftUI
import AppKit

/// Список вариантов дополнения под курсором — стеклянная панель, как в Xcode 26.
///
/// Это отдельное окно, дочернее к главному: так список может вылезти за край
/// редактора и не обрезается скроллом. Ключевым оно не становится — клавиатура
/// остаётся у текста, а стрелки, Return, Tab и Esc разбирает CodeViewController.
@MainActor
final class CompletionPopup {

    final class Model: ObservableObject {
        @Published var rows: [CompletionItem] = []
        @Published var selection = 0
    }

    let model = Model()
    var onPick: ((Int) -> Void)?

    private var panel: NSPanel?

    static let rowHeight: CGFloat = 24
    static let maxVisibleRows = 9
    static let width: CGFloat = 480

    var isVisible: Bool { panel?.isVisible == true }

    /// `anchor` — прямоугольник начала слова на экране: список встаёт под ним
    /// так, чтобы текст вариантов шёл ровно под набираемым словом.
    func show(rows: [CompletionItem], selection: Int, anchor: NSRect, parent: NSWindow) {
        model.rows = rows
        model.selection = selection

        let panel = self.panel ?? makePanel()
        let height = CGFloat(min(rows.count, Self.maxVisibleRows)) * Self.rowHeight + 12
        var frame = NSRect(x: anchor.minX - 36, y: anchor.minY - height - 3,
                           width: Self.width, height: height)
        if let screen = parent.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = anchor.maxY + 3 }   // снизу тесно — над строкой
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func select(_ index: Int) {
        model.selection = index
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
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
        panel.contentView = NSHostingView(rootView: CompletionListView(model: model) { [weak self] index in
            self?.onPick?(index)
        })
        self.panel = panel
        return panel
    }
}

// MARK: - Вид списка

private struct CompletionListView: View {
    @ObservedObject var model: CompletionPopup.Model
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: model.rows.count > CompletionPopup.maxVisibleRows) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { index, item in
                        CompletionRowView(item: item, isSelected: index == model.selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(index) }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { _, index in proxy.scrollTo(index) }
            .onChange(of: model.rows.count) { _, _ in proxy.scrollTo(model.selection) }
        }
        // Системный материал меню, а не SwiftUI-стекло: список живёт в своём
        // прозрачном окне, и размывать ему надо то, что под окном, — это
        // умеет только NSVisualEffectView с blendingMode .behindWindow.
        .pilotMaterial(.menu, cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

private struct CompletionRowView: View {
    let item: CompletionItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            let badge = Theme.completionBadge(kind: item.kind)
            Text(badge.letter)
                .font(.system(size: badge.letter.count > 1 ? 8 : 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color(nsColor: Theme.badgeText))
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color(nsColor: badge.color)))

            Text(item.label)
                .font(Font(Theme.editorFont(size: 12.5)))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)

            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: CompletionPopup.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.9))
            }
        }
    }
}
