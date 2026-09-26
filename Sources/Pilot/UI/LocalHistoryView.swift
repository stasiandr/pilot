import SwiftUI
import AppKit

/// Локальная история файла: слева версии, справа — чем выбранная версия
/// отличается от того, что сейчас в редакторе. Любой кусок можно вернуть,
/// или всю версию целиком; это обычная правка — ⌘Z её отменяет, а
/// записывается она, как всегда, по ⌘S.
struct LocalHistoryView: View {
    @ObservedObject var workspace: Workspace
    let file: LocalHistoryFile
    @Environment(\.dismiss) private var dismiss

    @State private var versions: [HistoryVersion] = []
    @State private var selection: String?
    @State private var versionText: String?
    @State private var current = ""
    @State private var hunks: [HistoryDiff.Hunk] = []
    @State private var loaded = false

    private var selected: HistoryVersion? { versions.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text(L("Локальная история: \(file.path)"))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L("Закрыть")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            HSplitView {
                versionList
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                diffPane
                    .frame(minWidth: 480)
            }
        }
        .frame(minWidth: 860, idealWidth: 1000, minHeight: 520, idealHeight: 680)
        .background(Color(nsColor: Theme.editorBackground))
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
        .onAppear(perform: load)
        .onChange(of: selection) { _, _ in loadVersion() }
    }

    // MARK: - Версии

    private var versionList: some View {
        List(selection: $selection) {
            ForEach(versions) { version in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.relative(version.date))
                    HStack(spacing: 6) {
                        Label(reasonTitle(version.reason), systemImage: reasonIcon(version.reason))
                        Text(Theme.count(version.lines, "строка", "строки", "строк"))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(version.id)
                .help(Self.absolute(version.date))
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if loaded && versions.isEmpty {
                VStack(spacing: 6) {
                    Text(L("Версий пока нет")).foregroundStyle(.secondary)
                    Text(L("Они появятся при сохранении и когда файл поменяют снаружи"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }

    private func reasonTitle(_ reason: HistoryVersion.Reason) -> String {
        switch reason {
        case .original: return L("до правок")
        case .saved: return L("сохранено")
        case .external: return L("изменён снаружи")
        case .discarded: return L("до отката")
        }
    }

    private func reasonIcon(_ reason: HistoryVersion.Reason) -> String {
        switch reason {
        case .original: return "doc"
        case .saved: return "square.and.arrow.down"
        case .external: return "arrow.triangle.2.circlepath"
        case .discarded: return "arrow.uturn.backward"
        }
    }

    // MARK: - Различия

    @ViewBuilder
    private var diffPane: some View {
        if let version = selected, let old = versionText {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(L("Версия \(Self.absolute(version.date)) → сейчас"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hunks.isEmpty {
                        Text(L("Совпадает с тем, что в редакторе")).foregroundStyle(.secondary)
                    } else {
                        Text(Theme.count(hunks.count, "отличие", "отличия", "отличий")).foregroundStyle(.secondary)
                        Button(L("Восстановить эту версию")) { restore(old) }
                            .disabled(!canEdit)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(hunks) { hunk in
                            HunkView(hunk: hunk, old: HistoryDiff.lines(old), new: HistoryDiff.lines(current),
                                     canRevert: canEdit) { revert(hunk, old: old) }
                        }
                    }
                    .padding(12)
                }
            }
        } else {
            Text(versions.isEmpty ? "" : L("Выберите версию"))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Вернуть можно, пока файл открыт в редакторе и его можно править.
    private var canEdit: Bool {
        workspace.buffer?.url == file.url && workspace.buffer?.isReadOnly == false
    }

    // MARK: - Действия

    private func load() {
        guard let history = workspace.localHistory else { loaded = true; return }
        let path = file.path
        workspace.localHistoryQueue.async {
            let found = history.versions(of: path)
            DispatchQueue.main.async {
                versions = found
                loaded = true
                // Самая свежая версия, отличная от текущего текста, — обычно её и ищут.
                selection = found.first?.id
            }
        }
    }

    private func loadVersion() {
        guard let version = selected, let history = workspace.localHistory else { versionText = nil; return }
        workspace.localHistoryQueue.async {
            let text = history.text(of: version)
            DispatchQueue.main.async {
                guard selection == version.id else { return }
                versionText = text
                refreshDiff()
            }
        }
    }

    private func refreshDiff() {
        current = workspace.buffer?.url == file.url ? (workspace.buffer?.storage.string ?? "")
            : ((try? String(contentsOf: file.url, encoding: .utf8)) ?? "")
        hunks = versionText.map { HistoryDiff.hunks(old: $0, new: current) } ?? []
    }

    private func revert(_ hunk: HistoryDiff.Hunk, old: String) {
        let edit = HistoryDiff.revert(hunk, old: old, new: current)
        apply(edit, action: L("Вернуть кусок из истории"))
    }

    private func restore(_ old: String) {
        apply(HistoryDiff.difference(from: current, to: old), action: L("Восстановить версию из истории"))
    }

    private func apply(_ edit: (range: NSRange, text: String), action: String) {
        guard workspace.applyEdits([UnityEdit(range: edit.range, text: edit.text)], to: file.url, actionName: action) else {
            NSSound.beep()
            return
        }
        // Правку применяет редактор на следующем проходе — тогда и сравним заново.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { refreshDiff() }
    }

    // MARK: - Даты

    private static func locale() -> Locale {
        Locale(identifier: Localization.current == .ru ? "ru_RU" : "en_US")
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

/// Кусок различий: что было в версии (−) и что сейчас (+), с парой строк
/// вокруг для ориентира.
private struct HunkView: View {
    let hunk: HistoryDiff.Hunk
    let old: [String]
    let new: [String]
    let canRevert: Bool
    let revert: () -> Void

    private static let context = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Строки \(hunk.new.lowerBound + 1)–\(max(hunk.new.lowerBound + 1, hunk.new.upperBound))"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Вернуть кусок"), action: revert)
                    .controlSize(.small)
                    .disabled(!canRevert)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: Theme.chromeBackground))
            let before = max(0, hunk.new.lowerBound - Self.context)..<hunk.new.lowerBound
            let after = hunk.new.upperBound..<min(new.count, hunk.new.upperBound + Self.context)
            ForEach(before, id: \.self) { line(new[$0], mark: " ", number: $0) }
            ForEach(hunk.old.clamped(to: 0..<old.count), id: \.self) { i in
                line(old[i], mark: "−", number: nil)
                    .background(Color(nsColor: Theme.gitDeleted).opacity(0.14))
            }
            ForEach(hunk.new.clamped(to: 0..<new.count), id: \.self) { i in
                line(new[i], mark: "+", number: i)
                    .background(Color(nsColor: Theme.gitAdded).opacity(0.14))
            }
            ForEach(after, id: \.self) { line(new[$0], mark: " ", number: $0) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Theme.separator)))
    }

    private func line(_ text: String, mark: String, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number.map { String($0 + 1) } ?? "")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(mark).foregroundStyle(.secondary)
            Text(text.isEmpty ? " " : text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
    }
}
