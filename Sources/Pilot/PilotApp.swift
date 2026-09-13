import SwiftUI
import AppKit

@main
struct PilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        Window("Pilot", id: "main") {
            RootView(workspace: workspace)
                .task {
                    delegate.workspace = workspace
                    // Путь из командной строки открываем после первого кадра:
                    // окно должно появиться мгновенно, а индексация идёт фоном.
                    // Без пути остаётся стартовый экран с выбором проекта.
                    workspace.start()
                }
                .animation(.easeOut(duration: 0.14), value: workspace.isPaletteOpen)
        }
        // Заголовок рисуем сами — с веткой git, как в Xcode.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 720)
        .commands {
            SidebarCommands()   // «Показать/скрыть боковую панель», ⌃⌘S
            CommandGroup(replacing: .newItem) {
                Button("Открыть папку…") { workspace.promptForFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Открыть недавний") {
                    ForEach(workspace.recentRoots, id: \.path) { url in
                        Button("\(url.lastPathComponent) — \((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)") {
                            workspace.open(root: url)
                        }
                    }
                }
                .disabled(workspace.recentRoots.isEmpty)
                Button("Закрыть проект") { workspace.closeProject() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(workspace.root == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Сохранить") { workspace.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!workspace.isCurrentDirty)
                Button("Сохранить все") { workspace.saveAll() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(workspace.unsavedCount == 0)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                // Уходит первому ответчику — тексту редактора, если фокус в нём.
                Button("Закомментировать строки") {
                    NSApp.sendAction(#selector(CodeTextView.toggleLineComment(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
                Button("Показать варианты") {
                    NSApp.sendAction(#selector(NSTextView.complete(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.escape, modifiers: .option)
            }
            CommandGroup(after: .toolbar) {
                Button("Перейти к файлу…") { workspace.openPalette(mode: .files) }
                    .keyboardShortcut("p", modifiers: .command)
                // Двойной Shift меню назначить не умеет — его ловит
                // DoubleShiftMonitor, а здесь он только подписан.
                Button("Найти класс…  ⇧⇧") { workspace.openClassSearch() }
                Button("Структура файла…") { workspace.openPalette(mode: .outline) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Символ в проекте…") { workspace.openPalette(mode: .symbols) }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!workspace.canSearchSymbols)
                Divider()
                Button("Следующее объявление") { workspace.jumpToMember(1) }
                    .keyboardShortcut(.downArrow, modifiers: .control)
                Button("Предыдущее объявление") { workspace.jumpToMember(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .control)
                Button("Следующее вхождение") { workspace.jumpToOccurrence(1) }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                Button("Предыдущее вхождение") { workspace.jumpToOccurrence(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Divider()
                Button("Изменённые файлы…") { workspace.openPalette(mode: .changes) }
                    .keyboardShortcut("g", modifiers: [.control, .shift])
                    .disabled(workspace.git.repository == nil)
                Button("Следующее изменение") { workspace.jumpToChange(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .option])
                Button("Предыдущее изменение") { workspace.jumpToChange(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .option])
                Divider()
                // Не требует LSP: пока сервер не готов, отвечает быстрый
                // навигатор по индексу объявлений проекта.
                Button("Перейти к объявлению") {
                    workspace.goToDefinition(at: workspace.caretOffset)
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Найти использования") {
                    workspace.findReferences(at: workspace.caretOffset)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(workspace.document == nil)
                Divider()
                Button("Назад") { workspace.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!workspace.canGoBack)
                Button("Вперёд") { workspace.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!workspace.canGoForward)
                Divider()
                Button("Крупнее") { workspace.fontSize += 1 }
                    .keyboardShortcut("=", modifiers: .command)   // ⌘+ без Shift
                Button("Мельче") { workspace.fontSize -= 1 }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Исходный размер") { workspace.fontSize = 12.5 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Чтобы при выходе спросить про несохранённые правки.
    weak var workspace: Workspace?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace?.confirmUnsavedChanges() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Палитра — Catppuccin Macchiato, тёмная; ставим до появления окна,
        // чтобы не мигнуть светлым хромом.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
