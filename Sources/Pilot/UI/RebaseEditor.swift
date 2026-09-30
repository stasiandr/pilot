import SwiftUI
import AppKit

/// Интерактивный rebase списком, как в lazygit и Fork: действие каждого
/// коммита — клавишей (p, r, s, f, d), порядок — ⌥↑/⌥↓ или
/// перетаскиванием. Только неотправленные коммиты без слияний:
/// опубликованную историю Pilot не переписывает.
struct RebaseEditor: View {
    @ObservedObject var client: GitClient
    let base: GitCommitInfo
    @Environment(\.dismiss) private var dismiss
    @State private var steps: [RebaseStep] = []
    @State private var refusal: String?
    @State private var selection: String?
    @State private var loading = true
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Интерактивный rebase")).font(.headline)
                Text(L("Коммиты после \(base.shortHash) «\(base.subject)», старые сверху"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(16)
            Divider()
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
            } else if let refusal {
                VStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                    Text(refusal).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                list
                Divider()
                if let selected = steps.firstIndex(where: { $0.id == selection }), steps[selected].action == .reword {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Новое сообщение")).font(.system(size: 11)).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { steps[selected].message ?? steps[selected].commit.subject },
                                                 set: { steps[selected].message = $0 }))
                            .font(.system(size: 12))
                            .frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: Theme.separator)))
                    }
                    .padding(12)
                    Divider()
                }
                Text(L("p pick · r reword · s squash · f fixup · d drop · ⌥↑↓ — переставить"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            HStack {
                if let problem = RebaseStep.problem(steps), !steps.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
                }
                Spacer()
                Button(L("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Переписать")) {
                    client.runRebase(base: base, steps: steps)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(steps.isEmpty || RebaseStep.problem(steps) != nil || !changed)
            }
            .padding(16)
        }
        .frame(width: 640)
        .task {
            switch await client.rebaseSteps(from: base) {
            case .success(let loaded):
                steps = loaded
                original = loaded.map(\.id)
                selection = loaded.last?.id
                listFocused = true
            case .failure(.message(let text)):
                refusal = text
            }
            loading = false
        }
    }

    /// Порядок до правок: ничего не поменяли — переписывать нечего.
    @State private var original: [String] = []

    private var changed: Bool {
        steps.contains { $0.action != .pick } || steps.map(\.id) != original
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach($steps) { $step in
                HStack(spacing: 8) {
                    Picker("", selection: $step.action) {
                        ForEach(RebaseStep.Action.allCases, id: \.self) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 92)
                    Text(step.commit.shortHash)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(step.action == .reword ? (step.message ?? step.commit.subject) : step.commit.subject)
                        .lineLimit(1)
                        .strikethrough(step.action == .drop)
                        .foregroundStyle(step.action == .drop ? .tertiary : .primary)
                    Spacer()
                    Text(step.commit.author).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
                .tag(step.id)
            }
            .onMove { from, to in steps.move(fromOffsets: from, toOffset: to) }
        }
        .listStyle(.plain)
        .frame(minHeight: 220, maxHeight: 420)
        .focused($listFocused)
        .onKeyPress(characters: .init(charactersIn: "prsfd")) { press in
            guard let index = steps.firstIndex(where: { $0.id == selection }),
                  let action = RebaseStep.Action.allCases.first(where: { String($0.key) == press.characters }) else {
                return .ignored
            }
            steps[index].action = action
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            move(-1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            move(1)
            return .handled
        }
    }

    private func move(_ delta: Int) {
        guard let index = steps.firstIndex(where: { $0.id == selection }) else { return }
        let target = index + delta
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }
}
