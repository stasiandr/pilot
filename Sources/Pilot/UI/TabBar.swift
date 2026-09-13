import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Вкладки открытых файлов над jump bar, как в Xcode. Клик — перейти,
/// крестик или ⌘W — закрыть, перетаскиванием меняется порядок.
struct TabBar: View {
    @ObservedObject var workspace: Workspace
    /// Вкладка, которую сейчас тащат.
    @State private var dragged: TextBuffer?

    var body: some View {
        let tabs = workspace.tabs
        let paths = tabs.map { workspace.relativePath(for: $0.url) }
        let details = Tabs.details(forPaths: paths)
        let active = workspace.buffer.map(ObjectIdentifier.init)

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(tabs.enumerated()), id: \.element.tabID) { index, tab in
                        TabItem(tab: tab,
                                path: paths[index],
                                detail: details[index],
                                isActive: tab.tabID == active,
                                isDirty: tab.isDirty,
                                onSelect: { workspace.selectTab(tab) },
                                onClose: { workspace.closeTab(tab) })
                            .contextMenu { menu(for: tab, at: index, path: paths[index]) }
                            .onDrag {
                                dragged = tab
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(forTypeIdentifier: UTType.pilotTab.identifier,
                                                                    visibility: .ownProcess) { done in
                                    done(Data(), nil)
                                    return nil
                                }
                                return provider
                            }
                            .onDrop(of: [.pilotTab], delegate: TabDropDelegate(
                                target: tab, workspace: workspace, dragged: $dragged))
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
            }
            .onChange(of: active) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .frame(height: 30)
        .background(Color(nsColor: Theme.editorBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func menu(for tab: TextBuffer, at index: Int, path: String) -> some View {
        Button("Закрыть вкладку") { workspace.closeTab(tab) }
        Button("Закрыть другие вкладки") { workspace.closeOtherTabs(tab) }
            .disabled(workspace.tabs.count < 2)
        Button("Закрыть вкладки справа") { workspace.closeTabsToTheRight(of: tab) }
            .disabled(index == workspace.tabs.count - 1)
        Divider()
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([tab.url]) }
            .disabled(tab.isReadOnly)
        Button("Скопировать путь") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}

private struct TabItem: View {
    let tab: TextBuffer
    let path: String
    /// Папка — у одноимённых файлов, чтобы их различить.
    let detail: String?
    let isActive: Bool
    let isDirty: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        let name = tab.url.lastPathComponent
        let icon = Theme.fileIcon(forName: name)
        HStack(spacing: 5) {
            Image(systemName: icon.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: icon.color))
                .accessibilityHidden(true)
            Text(Tabs.shortened(name))
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if let detail {
                Text(Tabs.shortened(detail, limit: 28))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if tab.isReadOnly {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.reviewThread))
                    .help("Версия из мерж-реквеста — только для чтения")
            }
            closeSlot
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .help(path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(name + (isDirty ? ", не сохранено" : ""))
    }

    private var background: Color {
        if isActive { return Color(nsColor: Theme.tabActive) }
        return hovering ? Color(nsColor: Theme.tabHover) : .clear
    }

    /// Несохранённое — точкой; под курсором она уступает место крестику,
    /// у активной вкладки крестик виден всегда.
    private var closeSlot: some View {
        ZStack {
            if hovering || (isActive && !isDirty) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(hoveringClose ? 0.12 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringClose = $0 }
                .help("Закрыть вкладку (⌘W)")
            } else if isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .help("Есть несохранённые изменения (⌘S)")
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Перетаскивание: вкладки расступаются, пока над ними ведут.
private struct TabDropDelegate: DropDelegate {
    let target: TextBuffer
    let workspace: Workspace
    @Binding var dragged: TextBuffer?

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged !== target else { return }
        withAnimation(.easeOut(duration: 0.12)) { workspace.moveTab(dragged, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

private extension UTType {
    /// Вкладку можно бросить только на другую вкладку — не в текст и не в Finder.
    static let pilotTab = UTType(importedAs: "dev.local.pilot.tab", conformingTo: .data)
}

extension TextBuffer {
    var tabID: ObjectIdentifier { ObjectIdentifier(self) }
}
