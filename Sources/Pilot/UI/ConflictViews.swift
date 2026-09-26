import SwiftUI
import AppKit

/// Кнопки у строки `<<<<<<<`, как «Accept Current | Accept Incoming» в
/// VS Code: стоят прямо в тексте, после метки маркера.
struct ConflictStrip: View {
    let conflict: MergeConflict
    let onChoose: (ConflictChoice) -> Void

    var body: some View {
        let current = label(conflict.currentLabel, "HEAD")
        let incoming = label(conflict.incomingLabel, L("другая ветка"))
        return HStack(spacing: 2) {
            button(L("Текущее"), .current, color: Theme.gitAdded,
                   help: L("Оставить текущее (\(current)) · ⌃⌥⌘←"))
            separator
            button(L("Входящее"), .incoming, color: Theme.gitRenamed,
                   help: L("Взять входящее (\(incoming)) · ⌃⌥⌘→"))
            separator
            button(L("Оба"), .both, color: nil, help: L("Оставить оба варианта: сначала текущее, потом входящее"))
            if conflict.base != nil {
                separator
                button(L("База"), .base, color: nil, help: L("Вернуть общего предка — отбросить обе стороны"))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color(nsColor: Theme.editorBackground).opacity(0.92)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        .fixedSize()
    }

    private var separator: some View {
        Text("·").foregroundStyle(.quaternary)
    }

    private func button(_ title: String, _ choice: ConflictChoice, color: NSColor?, help: String) -> some View {
        Button { onChoose(choice) } label: {
            Text(title).foregroundStyle(color.map { Color(nsColor: $0) } ?? .secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func label(_ text: String, _ fallback: String) -> String {
        text.isEmpty ? fallback : text
    }
}

/// Полоса над редактором, пока в файле есть конфликты или git ещё
/// считает его конфликтным.
struct ConflictBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let conflicts = workspace.conflicts
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(Color(nsColor: Theme.gitConflicted))
            if conflicts.isEmpty {
                Text(L("Конфликтов в файле не осталось"))
                Spacer(minLength: 8)
                if let error = workspace.conflictError {
                    Text(error).foregroundStyle(.orange).lineLimit(1)
                }
                Button(L("Сохранить и отметить решённым")) { workspace.markConflictsResolved() }
                    .help(L("Сохранить файл и выполнить git add — для git это и значит «конфликт решён»"))
            } else {
                let index = workspace.conflictIndexNearCaret
                Text(index.map { L("Конфликт \($0 + 1) из \(conflicts.count)") }
                     ?? Theme.count(conflicts.count, "конфликт", "конфликта", "конфликтов"))
                    .monospacedDigit()
                Button { workspace.jumpToConflict(-1) } label: { Image(systemName: "chevron.up") }
                    .help(KeymapStore.shared.help(L("Предыдущий конфликт"), .previousConflict))
                Button { workspace.jumpToConflict(1) } label: { Image(systemName: "chevron.down") }
                    .help(KeymapStore.shared.help(L("Следующий конфликт"), .nextConflict))
                Spacer(minLength: 8)
                if let error = workspace.conflictError {
                    Text(error).foregroundStyle(.orange).lineLimit(1)
                }
                Button(L("Все текущие")) { workspace.acceptAllConflicts(.current) }
                    .help(L("Во всех конфликтах файла оставить текущее"))
                Button(L("Все входящие")) { workspace.acceptAllConflicts(.incoming) }
                    .help(L("Во всех конфликтах файла взять входящее"))
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color(nsColor: Theme.gitConflicted).opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
    }
}
