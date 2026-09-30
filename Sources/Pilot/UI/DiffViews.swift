import SwiftUI
import AppKit

// Дифф: строка, кусок с выбором строк, патч целиком — одной колонкой или
// двумя. Общее для окна коммита, истории, stash и сравнения веток.

/// Как показывать дифф. Выбор один на всё приложение.
enum DiffLayout: String, CaseIterable {
    case unified, sideBySide

    static let key = "pilot.diffLayout"

    var title: String {
        switch self {
        case .unified: return L("Одной колонкой")
        case .sideBySide: return L("Две колонки")
        }
    }

    var icon: String {
        switch self {
        case .unified: return "rectangle"
        case .sideBySide: return "rectangle.split.2x1"
        }
    }
}

struct DiffLayoutPicker: View {
    @Binding var layout: DiffLayout

    var body: some View {
        Picker("", selection: $layout) {
            ForEach(DiffLayout.allCases, id: \.self) { layout in
                Image(systemName: layout.icon).help(layout.title).tag(layout)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

struct DiffLine: View {
    let text: String
    let number: Int?
    var oldNumber: Int? = nil
    var showsOldNumber = false
    var selected = false

    var body: some View {
        let marker = text.first
        HStack(alignment: .top, spacing: 6) {
            if showsOldNumber {
                Text(oldNumber.map(String.init) ?? "")
                    .frame(width: 40, alignment: .trailing)
                    .foregroundStyle(.tertiary)
            }
            Text(number.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(marker == "\\" ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(DiffLine.background(marker, selected: selected))
    }

    static func background(_ marker: Character?, selected: Bool = false) -> Color {
        if selected { return Color.accentColor.opacity(0.32) }
        switch marker {
        case "+": return Color(nsColor: Theme.gitAdded).opacity(0.14)
        case "-": return Color(nsColor: Theme.gitDeleted).opacity(0.14)
        default: return .clear
        }
    }
}

/// Кусок диффа. С `actions` — кнопки и выбор строк кликом (⇧ — диапазон),
/// как в Magit: подготовить можно и кусок, и отдельные строки.
struct HunkCard<Actions: View>: View {
    let hunk: GitFilePatch.Hunk
    var selectedLines: Set<Int> = []
    var focused = false
    var onLineClick: ((Int, Bool) -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(hunk.header)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !selectedLines.isEmpty {
                    Text(L("строк выбрано: \(selectedLines.count)"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
                Text("+\(hunk.additions) −\(hunk.deletions)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                actions()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: Theme.chromeBackground))
            ForEach(Array(numbered.enumerated()), id: \.offset) { index, item in
                DiffLine(text: item.text, number: item.number, oldNumber: item.old, showsOldNumber: true,
                         selected: selectedLines.contains(index))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onLineClick?(index, NSEvent.modifierFlags.contains(.shift))
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(focused ? Color.accentColor : Color(nsColor: Theme.separator), lineWidth: focused ? 1.5 : 1))
    }

    /// Номера строк обеих сторон: у удалённой — только старый, у добавленной — только новый.
    private var numbered: [(text: String, number: Int?, old: Int?)] {
        var new = hunk.newStart, old = hunk.oldStart
        return hunk.lines.map { text in
            switch text.first {
            case "-":
                defer { old += 1 }
                return (text, nil, old)
            case "+":
                defer { new += 1 }
                return (text, new, nil)
            case "\\":
                return (text, nil, nil)
            default:
                defer { new += 1; old += 1 }
                return (text, new, old)
            }
        }
    }
}

extension HunkCard where Actions == EmptyView {
    init(hunk: GitFilePatch.Hunk) {
        self.init(hunk: hunk, actions: { EmptyView() })
    }
}

/// Патч только для чтения: история, stash, сравнение веток.
struct PatchView: View {
    let patch: GitFilePatch?
    @AppStorage(DiffLayout.key) private var layout = DiffLayout.unified

    var body: some View {
        if let patch {
            if patch.isBinary {
                placeholder(L("Двоичный файл — показать нечего"))
            } else if patch.hunks.isEmpty {
                placeholder(L("Отличий нет"))
            } else if layout == .sideBySide {
                SideBySideView(rows: SideBySideRow.rows(patch))
            } else {
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(patch.hunks) { hunk in HunkCard(hunk: hunk) }
                    }
                    .padding(12)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Две колонки: слева старое, справа новое, изменённые строки — напротив.
struct SideBySideView: View {
    let rows: [SideBySideRow]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if row.kind == .separator {
                        Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1).padding(.vertical, 6)
                    } else {
                        HStack(spacing: 0) {
                            cell(number: row.oldNumber, text: row.old, marker: row.kind == .context ? nil : "-")
                            Rectangle().fill(Color(nsColor: Theme.separator)).frame(width: 1)
                            cell(number: row.newNumber, text: row.new, marker: row.kind == .context ? nil : "+")
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func cell(number: Int?, text: String?, marker: Character?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(text.map { $0.isEmpty ? " " : $0 } ?? " ")
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity)
        .background(text == nil ? Color(nsColor: Theme.separator).opacity(0.25) : DiffLine.background(marker))
    }
}

/// Буква и цвет вида изменения — одинаково во всех списках файлов.
enum ChangeBadge {
    static func color(_ kind: GitChange.Kind?) -> NSColor {
        switch kind {
        case .added: return Theme.gitAdded
        case .deleted: return Theme.gitDeleted
        case .renamed: return Theme.gitRenamed
        default: return Theme.gitModified
        }
    }
}

/// Строка файла в списке: буква вида, имя, папка.
struct ChangedFileRow: View {
    let letter: String
    let color: NSColor
    let name: String
    let directory: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: color))
                .frame(width: 12)
            Text(name).lineLimit(1)
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(directory)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}
