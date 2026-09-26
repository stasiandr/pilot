import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Откуда брать настройки Rider: его папка на этом маке или `settings.zip`
/// из File → Manage IDE Settings → Export Settings.
@MainActor
enum RiderImportSource {
    struct Loaded: Identifiable {
        let id = UUID()
        let settings: RiderSettings
        /// Что выбрали — для заголовка: `settings.zip`, `Rider2025.2`.
        let name: String
    }

    /// Папка настроек самого нового Rider на этом маке.
    static func installedFolder() -> URL? {
        guard let jetbrains = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JetBrains", isDirectory: true) else { return nil }
        return newestRider(in: jetbrains)
    }

    /// Выбрать папку или архив и прочитать. `nil` — передумали; что не так
    /// с выбранным, уже сказано.
    static func choose() -> Loaded? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "settings.zip из Rider (File → Manage IDE Settings → Export Settings) или папка его настроек"
        panel.prompt = "Выбрать"
        let installed = installedFolder()
        panel.directoryURL = installed?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return Loaded(settings: try load(url), name: url.lastPathComponent)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не получилось прочитать настройки Rider"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func load(_ url: URL) throws -> RiderSettings {
        guard url.pathExtension.lowercased() == "zip" else {
            if let settings = settings(in: url) { return settings }
            throw Failure(errorDescription: "В «\(url.lastPathComponent)» нет ни options/, ни keymaps/ — это не настройки Rider.")
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilot-rider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", url.path, temp.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw Failure(errorDescription: "Архив «\(url.lastPathComponent)» не распаковался.")
        }
        // RiderSettings читает всё сразу, так что папку можно удалять.
        if let settings = settings(in: temp) { return settings }
        throw Failure(errorDescription: "В «\(url.lastPathComponent)» нет настроек Rider. Нужен архив из File → Manage IDE Settings → Export Settings.")
    }

    /// Сама папка, а если это папка повыше (`JetBrains/`, архив с папкой
    /// внутри) — самая новая из вложенных.
    private static func settings(in folder: URL) -> RiderSettings? {
        if let settings = RiderSettings(folder: folder) { return settings }
        let children = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let preferred = newestRider(in: folder).map { [$0] } ?? []
        for child in preferred + children.sorted(by: newer) {
            if let settings = RiderSettings(folder: child) { return settings }
        }
        return nil
    }

    private static func newestRider(in folder: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Rider") }
            .sorted(by: newer)
            .first
    }

    /// `Rider2025.2` новее `Rider2025.10`? Нет — сравниваем как числа.
    private static func newer(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent.compare(b.lastPathComponent, options: .numeric) == .orderedDescending
    }
}

/// Что изменится после импорта — прежде чем менять.
struct RiderImportSheet: View {
    let loaded: RiderImportSource.Loaded
    @ObservedObject var store: KeymapStore
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    @State private var takeKeys = true
    @State private var takeFontSize = true
    @State private var takeCodeVision = true
    @State private var showsKept = false

    private var settings: RiderSettings { loaded.settings }
    private var result: RiderImport.KeymapResult { settings.keymap(over: store.keymap) }

    var body: some View {
        let result = result
        let changes = result.entries.filter {
            if case .kept = $0.outcome { return false }
            if case .same = $0.outcome { return false }
            return true
        }
        let kept = result.entries.filter { if case .kept = $0.outcome { return true } else { return false } }
        let same = result.entries.count - changes.count - kept.count

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Импорт из Rider").font(.headline)
                Text(loaded.name).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Toggle(isOn: $takeKeys) {
                Text("Сочетания клавиш — раскладка «\(settings.activeKeymap)»")
            }
            if let missing = result.missingKeymap {
                Label("Раскладки «\(missing)» в Pilot нет: переносятся только изменения поверх неё.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            List {
                Section("Изменится — \(changes.count)" + (same > 0 ? ", ещё \(same) уже совпадают" : "")) {
                    ForEach(changes, id: \.command) { entry in
                        row(entry)
                    }
                }
                Section {
                    if showsKept {
                        ForEach(kept, id: \.command) { entry in
                            row(entry)
                        }
                    }
                } header: {
                    Button {
                        showsKept.toggle()
                    } label: {
                        Label("Не перенесено — \(kept.count)", systemImage: showsKept ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
            .disabled(!takeKeys)
            .opacity(takeKeys ? 1 : 0.5)

            if let size = settings.fontSize {
                Toggle("Размер шрифта: \(format(workspace.fontSize)) → \(format(CGFloat(size)))", isOn: $takeFontSize)
                    .disabled(CGFloat(size) == workspace.fontSize)
            }
            if let codeVision = settings.codeVision {
                Toggle("Счётчики использований над объявлениями: " + (codeVision ? "показывать" : "не показывать"),
                       isOn: $takeCodeVision)
                    .disabled(codeVision == workspace.showsCodeLens)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Импортировать") {
                    apply(result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }

    private func row(_ entry: RiderImport.Entry) -> some View {
        HStack(spacing: 8) {
            Text(entry.command.title)
            Spacer()
            switch entry.outcome {
            case .assigned(let shortcut, let was):
                keys(was?.display ?? "—").foregroundStyle(.secondary)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                keys(shortcut.display)
            case .yielded(let shortcut, let owner):
                keys(shortcut.display).foregroundStyle(.secondary).strikethrough()
                Text("→ «\(owner.title)»").font(.system(size: 11)).foregroundStyle(.secondary)
            case .same(let shortcut):
                keys(shortcut.display)
            case .kept(let reason):
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func keys(_ text: String) -> Text {
        Text(text).font(.system(size: 12, design: .monospaced))
    }

    private func format(_ size: CGFloat) -> String {
        size.rounded() == size ? "\(Int(size))" : String(format: "%.1f", Double(size))
    }

    private func apply(_ result: RiderImport.KeymapResult) {
        if takeKeys { store.replace(with: result.keymap) }
        if takeFontSize, let size = settings.fontSize { workspace.setFontSize(CGFloat(size)) }
        if takeCodeVision, let codeVision = settings.codeVision { workspace.showsCodeLens = codeVision }
    }
}
