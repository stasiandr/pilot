import SwiftUI
import AppKit

/// Палитра. Один компонент на все режимы: файлы (⌘P), классы (⇧⇧),
/// структура файла (⌘⇧O), символы (⌘T), использования (⌘R) — отличаются
/// только источником строк.
struct PaletteView: View {
    @ObservedObject var workspace: Workspace
    @FocusState private var focused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        PilotGlassGroup(spacing: 14) {
            VStack(spacing: 0) {
                queryField
                if !workspace.items.isEmpty {
                    Divider().opacity(0.35)
                    resultList
                } else if shouldShowEmptyState {
                    emptyState
                }
            }
            .frame(width: 660)
            .pilotGlass(cornerRadius: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.30), radius: 40, y: 18)
        }
        .onAppear { focused = true; installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private var shouldShowEmptyState: Bool {
        if workspace.paletteBusy { return true }
        return !workspace.query.isEmpty || workspace.paletteMode != .files
    }

    // MARK: - Поле ввода

    private var queryField: some View {
        HStack(spacing: 10) {
            Image(systemName: workspace.paletteMode.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(workspace.paletteMode.placeholder, text: $workspace.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .focused($focused)
                .onSubmit { workspace.activateSelection() }

            if workspace.paletteBusy || isIndexingForMode {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            counter
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var isIndexingForMode: Bool {
        switch workspace.paletteMode {
        case .files:   return workspace.isIndexing
        case .classes: return workspace.isIndexing || workspace.isTypeIndexing
        case .outline, .symbols, .references, .changes: return false
        }
    }

    @ViewBuilder
    private var counter: some View {
        switch workspace.paletteMode {
        case .files:
            Text("\(workspace.fileCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help("Файлов в индексе")
        case .classes:
            Text("\(workspace.typeCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help("Типов в индексе")
        case .symbols, .references, .outline, .changes:
            if !workspace.items.isEmpty {
                Text("\(workspace.items.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Text(emptyMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private var emptyMessage: String {
        if workspace.paletteBusy { return "Ищу…" }
        switch workspace.paletteMode {
        case .files:
            return "Ничего не найдено"
        case .classes:
            if !workspace.query.isEmpty { return "Ничего не найдено" }
            if workspace.isTypeIndexing && workspace.typeCount == 0 {
                return "Собираю классы проекта… Файлы ищутся уже сейчас"
            }
            return "Начните вводить имя класса — можно заглавными: USvc → UserService"
        case .symbols:
            if !workspace.lsp.isReady { return lspNotReadyMessage }
            return workspace.query.isEmpty ? "Начните вводить имя символа" : "Ничего не найдено"
        case .references:
            if !workspace.lsp.isReady { return lspNotReadyMessage }
            return "Использований не найдено"
        case .outline:
            return workspace.document == nil
                ? "Сначала откройте файл"
                : "В этом файле объявлений не найдено"
        case .changes:
            if workspace.git.repository == nil { return "Проект не под git" }
            return workspace.query.isEmpty ? "Изменений нет — всё закоммичено" : "Ничего не найдено"
        }
    }

    private var lspNotReadyMessage: String {
        switch workspace.lsp.state {
        case .stopped:            return "Языковой сервер не запущен — откройте файл .cs"
        case .starting(let what): return "Языковой сервер ещё греется: \(what)"
        case .failed(let why):    return "Языковой сервер не поднялся: \(why)"
        case .ready:              return "Ничего не найдено"
        }
    }

    // MARK: - Результаты

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(workspace.items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isSelected: index == workspace.selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                workspace.selection = index
                                workspace.activateSelection()
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 420)
            .onChange(of: workspace.selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    // MARK: - Клавиатура
    //
    // Локальный монитор надёжнее, чем .onKeyPress: поле ввода держит фокус
    // и само съедает стрелки.

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: workspace.moveSelection(-1); return nil     // ↑
            case 125: workspace.moveSelection(1);  return nil     // ↓
            case 36, 76: workspace.activateSelection(); return nil // Return
            case 53: workspace.isPaletteOpen = false; return nil   // Esc
            case 48:                                               // Tab — как в fzf
                workspace.moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            default:
                // ^N / ^P — привычная навигация для тех, кто из терминала
                if event.modifierFlags.contains(.control),
                   let ch = event.charactersIgnoringModifiers?.lowercased() {
                    if ch == "n" { workspace.moveSelection(1); return nil }
                    if ch == "p" { workspace.moveSelection(-1); return nil }
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Строка результата

struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 1) {
                styledPrimary
                    .lineLimit(1)
                    .truncationMode(.head)
                if let secondary = item.secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75))
                                                    : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 6)

            if let trailing = item.trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75))
                                                : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    /// Собираем строку отрезками: совпавшие символы выделены,
    /// путь к файлу приглушён относительно имени.
    private var styledPrimary: Text {
        guard !item.positions.isEmpty else { return Text(item.primary) }

        let matched = Set(item.positions.map { Int($0) })
        var result = Text("")
        var utf8Index = 0
        var runText = ""
        var runMatched = false
        var runInName = false
        var started = false

        func flush() {
            guard !runText.isEmpty else { return }
            var t = Text(runText)
            if runMatched {
                t = t.bold()
                if !isSelected { t = t.foregroundColor(.accentColor) }
            } else if !runInName && !isSelected {
                t = t.foregroundColor(.secondary)
            }
            result = result + t
            runText = ""
        }

        for ch in item.primary {
            let width = String(ch).utf8.count
            let isMatched = matched.contains(utf8Index)
            let inName = utf8Index >= item.nameOffset
            if !started || isMatched != runMatched || inName != runInName {
                flush()
                runMatched = isMatched
                runInName = inName
                started = true
            }
            runText.append(ch)
            utf8Index += width
        }
        flush()
        return result
    }
}
