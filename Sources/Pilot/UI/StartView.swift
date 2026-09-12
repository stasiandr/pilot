import SwiftUI
import AppKit

/// Стартовый экран: выбор из недавних проектов.
///
/// Молча открывать последний проект удобно, только пока он один. Когда
/// переключаешься между двумя-тремя, выбор на старте стоит одно нажатие,
/// а не поход в меню и ожидание индексации ненужного проекта.
struct StartView: View {
    @ObservedObject var workspace: Workspace
    @State private var selection = 0
    @State private var keyMonitor: Any?

    /// Девять — столько, сколько достаётся через ⌘1…⌘9.
    private var projects: [URL] { Array(workspace.recentRoots.prefix(9)) }

    var body: some View {
        VStack(spacing: 28) {
            header
            if !projects.isEmpty {
                projectList
            }
            footer
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { selection = 0; installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: projects.count) { _, count in
            selection = max(0, min(selection, count - 1))
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 5) {
                Text("Pilot").font(.system(size: 26, weight: .semibold))
                Text(projects.isEmpty ? "Откройте папку проекта, чтобы начать"
                                      : "Выберите проект")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Список проектов

    private var projectList: some View {
        VStack(spacing: 1) {
            ForEach(Array(projects.enumerated()), id: \.element.path) { index, url in
                ProjectRow(url: url, shortcut: index + 1, isSelected: index == selection)
                    .contentShape(Rectangle())
                    .onHover { if $0 { selection = index } }
                    .onTapGesture { workspace.open(root: url) }
                    .contextMenu {
                        Button("Открыть") { workspace.open(root: url) }
                        Button("Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        Divider()
                        Button("Убрать из списка") { workspace.forgetRecent(url) }
                    }
            }
        }
        .padding(6)
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button("Открыть папку…") { workspace.promptForFolder() }
                .controlSize(.large)
            Text(projects.isEmpty ? "⌘O" : "↑↓ выбрать · ⏎ открыть · ⌘1–9 · ⌘O другая папка")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Клавиатура
    //
    // Поля ввода здесь нет, фокусу SwiftUI держаться не за что, поэтому,
    // как и в палитре, — локальный монитор клавиш.

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Не перехватываем ничего у модальных окон (выбор папки)
            // и у палитры, если её открыли поверх стартового экрана.
            guard NSApp.modalWindow == nil, !(event.window is NSPanel),
                  !workspace.isPaletteOpen, !projects.isEmpty else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, let ch = event.charactersIgnoringModifiers,
               let digit = Int(ch), (1...projects.count).contains(digit) {
                workspace.open(root: projects[digit - 1])
                return nil
            }
            guard flags.isDisjoint(with: [.command, .control, .option]) else { return event }

            switch event.keyCode {
            case 126:                                              // ↑
                selection = max(0, selection - 1); return nil
            case 125:                                              // ↓
                selection = min(projects.count - 1, selection + 1); return nil
            case 36, 76:                                           // Return
                workspace.open(root: projects[selection]); return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Строка проекта

private struct ProjectRow: View {
    let url: URL
    let shortcut: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(parentPath)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75))
                                                : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            Text("⌘\(shortcut)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75))
                                            : AnyShapeStyle(.quaternary))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    private var parentPath: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
