import AppKit
import SwiftUI

/// Настройки → Сочетания клавиш. Команды по разделам, у каждой её сочетание:
/// клик — и следующее нажатие станет новым, `⌫` — снять, `⎋` — передумать.
struct KeymapSettingsView: View {
    @ObservedObject var store: KeymapStore
    @ObservedObject var workspace: Workspace
    @StateObject private var recorder = KeyRecorder()
    @State private var filter = ""
    @State private var riderImport: RiderImportSource.Loaded?

    private var visible: [EditorCommand] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return EditorCommand.allCases }
        return EditorCommand.allCases.filter { command in
            command.title.lowercased().contains(query)
                || (store.keymap.shortcut(for: command)?.display.lowercased().contains(query) ?? false)
                || command.rawValue.contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(L("Команда или сочетание"), text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button(L("Импорт из Rider…")) {
                    recorder.stop()
                    riderImport = RiderImportSource.choose()
                }
                .help(L("Сочетания, размер шрифта и счётчики использований из settings.zip или папки настроек Rider"))
                Button(L("Сбросить всё")) { store.resetAll() }
                    .disabled(store.keymap.overrides.isEmpty)
                Button {
                    if let url = store.revealableFile() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help(L("Показать keybindings.json в Finder — его можно править руками и носить с собой"))
            }
            .padding(12)

            List {
                ForEach(EditorCommand.groups, id: \.self) { group in
                    let commands = visible.filter { $0.group == group }
                    if !commands.isEmpty {
                        Section(group) {
                            ForEach(commands, id: \.self) { command in
                                row(command)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Text(L("⇧⇧, ⌃Tab, ⌃- / ⌃⇧- и боковые кнопки мыши работают всегда, в дополнение к назначенному."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 640, height: 580)
        .onAppear { store.reload() }
        .sheet(item: $riderImport) { loaded in
            RiderImportSheet(loaded: loaded, store: store, workspace: workspace)
        }
        .onDisappear { recorder.stop() }
    }

    private func row(_ command: EditorCommand) -> some View {
        let conflicts = store.keymap.conflicts(for: command)
        let recording = recorder.command == command
        let conflictNames = conflicts.map { L("«\($0.title)»") }.joined(separator: ", ")
        let defaultShortcut = command.defaultShortcut?.display ?? L("без сочетания")
        return HStack(spacing: 8) {
            Text(command.title)
            Spacer()
            if !conflicts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(L("То же сочетание у \(conflictNames) — сработает одно из них"))
            }
            Button {
                recording ? recorder.stop() : recorder.start(command, store: store)
            } label: {
                Text(recording ? L("Нажмите сочетание…") : (store.keymap.shortcut(for: command)?.display ?? "—"))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 130)
            }
            .buttonStyle(.bordered)
            .tint(recording ? Color.accentColor : nil)
            .help(L("Клик — записать новое сочетание; ⌫ — убрать, ⎋ — отменить"))
            Button {
                store.reset(command)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .opacity(store.keymap.isCustomized(command) ? 1 : 0)
            .disabled(!store.keymap.isCustomized(command))
            .help(L("Вернуть: \(defaultShortcut)"))
        }
    }
}

/// Запись сочетания: следующее нажатие достаётся не меню и не тексту, а
/// настройке. Пока идёт запись, пункты меню не срабатывают.
@MainActor
final class KeyRecorder: ObservableObject {
    @Published private(set) var command: EditorCommand?
    private var monitor: Any?

    func start(_ command: EditorCommand, store: KeymapStore) {
        stop()
        self.command = command
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak store] event in
            guard let self, let store, let command = self.command else { return event }
            self.handle(event, for: command, store: store)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        command = nil
    }

    private func handle(_ event: NSEvent, for command: EditorCommand, store: KeymapStore) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty && event.keyCode == 53 {          // ⎋ — передумал
            stop()
            return
        }
        if flags.isEmpty && event.keyCode == 51 {          // ⌫ — без сочетания
            store.set(nil, for: command)
            stop()
            return
        }
        guard let shortcut = KeymapStore.shortcut(from: event),
              !shortcut.needsModifier || shortcut.hasModifier else {
            // Буква без модификатора — её нельзя будет набрать. Ждём дальше.
            NSSound.beep()
            return
        }
        stop()
        if let other = store.keymap.command(using: shortcut, except: command) {
            // Не из обработчика нажатия: модальное окно там завело бы свой
            // цикл событий посреди чужого.
            DispatchQueue.main.async { Self.resolve(shortcut, for: command, takenBy: other, store: store) }
            return
        }
        store.set(shortcut, for: command)
    }

    private static func resolve(_ shortcut: Shortcut, for command: EditorCommand, takenBy other: EditorCommand,
                                store: KeymapStore) {
        let alert = NSAlert()
        alert.messageText = L("\(shortcut.display) уже у «\(other.title)»")
        alert.informativeText = L("Забрать сочетание у той команды или оставить у обеих? С двумя сработает только одна.")
        alert.addButton(withTitle: L("Забрать"))
        alert.addButton(withTitle: L("Оставить у обеих"))
        alert.addButton(withTitle: L("Отмена"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.set(nil, for: other)
            store.set(shortcut, for: command)
        case .alertSecondButtonReturn:
            store.set(shortcut, for: command)
        default:
            break
        }
    }
}
