import SwiftUI
import AppKit

/// Окно слияния файла, как в Rider: слева наша версия, справа их, в
/// середине результат. Куски, которые правила одна сторона, уже слиты;
/// спорные решаются кнопками (← наша, → их, обе) или правкой текста.
/// Палочка решает то, что решается без человека.
struct MergeWindow: View {
    static let sceneID = "merge"

    /// `корень проекта` + `\n` + `путь от корня репозитория`.
    let target: String?
    @ObservedObject private var language = LanguageStore.shared

    var body: some View {
        Group {
            if let target, let resolved = resolve(target),
               let session = resolved.workspace.mergeSession(for: resolved.path) {
                MergeView(workspace: resolved.workspace, session: session)
                    .navigationTitle(L("Слияние — \((resolved.path as NSString).lastPathComponent)"))
            } else {
                Text(L("Проект этого окна закрыт"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(language.current)
        .frame(minWidth: 1000, minHeight: 560)
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
    }

    private func resolve(_ target: String) -> (workspace: Workspace, path: String)? {
        let parts = target.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let workspace = ProjectWindows.shared.workspaces.first(where: { $0.root?.path == parts[0] }) else { return nil }
        return (workspace, parts[1])
    }
}

struct MergeView: View {
    let workspace: Workspace
    @ObservedObject var session: MergeSession
    @Environment(\.dismiss) private var dismiss
    @State private var current = 0
    @State private var editing: Int?
    @State private var draft = ""
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !session.isLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chunkList
            }
            Divider()
            footer
        }
        .background(Color(nsColor: Theme.swiftUIEditorBackground))
        .onAppear {
            if !session.isLoaded { session.load() }
        }
        .background {
            Button("") { dismiss() }.keyboardShortcut("w", modifiers: .command).hidden()
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            column(L("Наша версия (текущая ветка)"), missing: session.missing.ours)
            column(L("Результат"), missing: false)
            column(L("Их версия (вливаемая)"), missing: session.missing.theirs)
        }
        .font(.system(size: 12, weight: .medium))
        .frame(height: 30)
    }

    private func column(_ title: String, missing: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if missing { Text(L("— файл удалён")).foregroundStyle(Color(nsColor: Theme.gitDeleted)) }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Куски

    private var chunkList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(session.chunks.enumerated()), id: \.offset) { index, chunk in
                        chunkRow(index, chunk)
                            .id(index)
                    }
                }
            }
            .onChange(of: current) { _, value in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(value, anchor: .center) }
            }
            .onAppear {
                if let first = session.conflictIndices.first {
                    current = first
                    DispatchQueue.main.async { proxy.scrollTo(first, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private func chunkRow(_ index: Int, _ chunk: Merge3.Chunk) -> some View {
        switch chunk.kind {
        case .stable:
            StableChunk(lines: chunk.base)
        case .changed(let side):
            HStack(alignment: .top, spacing: 0) {
                lines(chunk.ours, tint: side == .theirs ? nil : Theme.gitAdded)
                divider
                lines(chunk.automatic, tint: Theme.gitAdded)
                divider
                lines(chunk.theirs, tint: side == .ours ? nil : Theme.gitAdded)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .conflict:
            conflictRow(index, chunk)
        }
    }

    private func conflictRow(_ index: Int, _ chunk: Merge3.Chunk) -> some View {
        let resolved = session.resolutions[index]
        let isCurrent = current == index
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    lines(chunk.ours, tint: Theme.gitConflicted)
                    Button { session.resolve(index, .ours); advance(from: index) } label: {
                        Label(L("Взять"), systemImage: "arrow.right")
                    }
                    .controlSize(.small)
                    .padding(4)
                }
                divider
                VStack(spacing: 0) {
                    if editing == index {
                        TextEditor(text: $draft)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(minHeight: 80)
                        HStack {
                            Button(L("Отмена")) { editing = nil }
                            Button(L("Готово")) {
                                session.setText(index, draft)
                                editing = nil
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .controlSize(.small)
                        .padding(4)
                    } else if let resolved {
                        lines(resolved, tint: Theme.gitAdded)
                        HStack {
                            Button(L("Править")) { startEditing(index) }
                            Button(L("Сбросить")) { session.unresolve(index) }
                        }
                        .controlSize(.small)
                        .padding(4)
                    } else {
                        lines(chunk.base, tint: nil, dimmed: true)
                        HStack(spacing: 4) {
                            Button(L("Обе")) { session.resolve(index, .oursThenTheirs); advance(from: index) }
                                .help(L("Сначала наша, потом их"))
                            Button(L("Их, потом наша")) { session.resolve(index, .theirsThenOurs); advance(from: index) }
                            Button(L("Править")) { startEditing(index) }
                            if Merge3.autoResolve(chunk) != nil {
                                Button { session.resolutions[index] = Merge3.autoResolve(chunk); advance(from: index) } label: {
                                    Image(systemName: "wand.and.stars")
                                }
                                .help(L("Решить автоматически"))
                            }
                        }
                        .controlSize(.small)
                        .padding(4)
                    }
                }
                divider
                VStack(alignment: .leading, spacing: 0) {
                    lines(chunk.theirs, tint: Theme.gitConflicted)
                    Button { session.resolve(index, .theirs); advance(from: index) } label: {
                        Label(L("Взять"), systemImage: "arrow.left")
                    }
                    .controlSize(.small)
                    .padding(4)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .overlay(Rectangle().stroke(isCurrent ? Color.accentColor : Color(nsColor: Theme.gitConflicted).opacity(0.5),
                                    lineWidth: isCurrent ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { current = index }
    }

    private var divider: some View {
        Rectangle().fill(Color(nsColor: Theme.separator)).frame(width: 1)
    }

    private func lines(_ lines: [String], tint: NSColor?, dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                Text(" ").font(.system(size: 11.5, design: .monospaced))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(dimmed ? .tertiary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.map { Color(nsColor: $0).opacity(0.12) } ?? .clear)
        .textSelection(.enabled)
    }

    private func startEditing(_ index: Int) {
        draft = session.lines(of: index).joined(separator: "\n")
        editing = index
        current = index
    }

    /// К следующему нерешённому.
    private func advance(from index: Int) {
        let conflicts = session.conflictIndices
        if let next = conflicts.first(where: { $0 > index && session.resolutions[$0] == nil })
            ?? conflicts.first(where: { session.resolutions[$0] == nil }) {
            current = next
        }
    }

    // MARK: - Низ

    private var footer: some View {
        HStack(spacing: 8) {
            let total = session.conflictIndices.count
            Text(session.unresolvedCount == 0 ? L("Все конфликты решены") : L("Нерешено: \(session.unresolvedCount) из \(total)"))
                .foregroundStyle(session.unresolvedCount == 0 ? Color(nsColor: Theme.gitAdded) : .secondary)
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .help(L("Предыдущий конфликт"))
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .help(L("Следующий конфликт"))
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button {
                let count = session.autoResolve()
                notice = count == 0 ? L("Само не решается ничего") : L("Решено само: \(count)")
            } label: {
                Label(L("Решить простые"), systemImage: "wand.and.stars")
            }
            .help(L("Разница только в пробелах, вставки в одно место с обеих сторон"))
            Menu(L("Все оставшиеся…")) {
                Button(L("Нашей версией")) { session.resolveAll(.ours) }
                Button(L("Их версией")) { session.resolveAll(.theirs) }
                Divider()
                Button(L("Взять наш файл целиком")) { finish { await session.takeWhole(true) } }
                Button(L("Взять их файл целиком")) { finish { await session.takeWhole(false) } }
            }
            .fixedSize()
            if session.yamlMerge != nil {
                Button("UnityYAMLMerge") { finish { await session.runYAMLMerge() } }
                    .help(L("Слить сцену или префаб по объектам — инструментом Unity"))
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            if let error = session.error {
                Text(error).foregroundStyle(Color(nsColor: Theme.diagnosticError)).lineLimit(3).textSelection(.enabled)
            }
            Spacer()
            if session.busy { ProgressView().controlSize(.small) }
            Button(L("Отмена")) { dismiss() }
            Button(L("Сохранить и отметить решённым")) {
                finish { await session.save(markResolved: true) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(session.unresolvedCount > 0 || session.busy)
        }
        .font(.system(size: 12))
        .padding(10)
    }

    private func move(_ delta: Int) {
        let conflicts = session.conflictIndices
        guard !conflicts.isEmpty else { return }
        if delta > 0 {
            current = conflicts.first { $0 > current } ?? conflicts[0]
        } else {
            current = conflicts.last { $0 < current } ?? conflicts[conflicts.count - 1]
        }
    }

    private func finish(_ action: @escaping () async -> Bool) {
        Task {
            if await action() {
                workspace.mergeFinished(path: session.path)
                dismiss()
            }
        }
    }
}

/// Общий кусок: длинный свёрнут до пары строк по краям.
private struct StableChunk: View {
    let lines: [String]
    @State private var expanded = false

    var body: some View {
        let collapsed = lines.count > 8 && !expanded
        let shown = collapsed ? Array(lines.prefix(3)) : lines
        VStack(spacing: 0) {
            row(shown)
            if collapsed {
                Button(L("… ещё \(lines.count - 6) общих строк")) { expanded = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
                row(Array(lines.suffix(3)))
            }
        }
    }

    private func row(_ lines: [String]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<3, id: \.self) { column in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                if column < 2 { Rectangle().fill(Color(nsColor: Theme.separator)).frame(width: 1) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
