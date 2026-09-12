import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        ZStack {
            Color(nsColor: Theme.editorBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                content
                statusBar
            }

            if workspace.isPaletteOpen {
                paletteOverlay
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder
    private var content: some View {
        if let error = workspace.loadError {
            notice(icon: "exclamationmark.triangle", title: error)
        } else if workspace.document != nil {
            CodeView(document: workspace.document,
                     fontSize: workspace.fontSize,
                     reveal: workspace.reveal,
                     occurrences: workspace.occurrences,
                     onCaretChange: { workspace.caretMoved(to: $0) },
                     onGoToDefinition: { workspace.goToDefinition(at: $0) })
        } else if workspace.root == nil {
            welcome
        } else {
            notice(icon: "magnifyingglass",
                   title: "Нажмите ⌘P, чтобы найти файл")
        }
    }

    private func notice(icon: String, title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Стартовый экран

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text("Pilot").font(.system(size: 26, weight: .semibold))
                Text("Мгновенный просмотрщик кода")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Button("Открыть папку…") { workspace.promptForFolder() }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)

            if !workspace.recentRoots.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Недавние")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 2)
                    ForEach(workspace.recentRoots.prefix(5), id: \.path) { url in
                        Button {
                            workspace.open(root: url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder").font(.system(size: 11))
                                Text(url.lastPathComponent).font(.system(size: 12))
                                Text(url.deletingLastPathComponent().path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Статусная строка

    private var statusBar: some View {
        HStack(spacing: 12) {
            historyControls

            if let doc = workspace.document {
                Text(doc.url.lastPathComponent).font(.system(size: 11, weight: .medium))
                Text(doc.languageName).font(.system(size: 11)).foregroundStyle(.secondary)
                if !workspace.breadcrumb.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.quaternary)
                    Text(workspace.breadcrumb)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Где сейчас курсор. ⌃↑ и ⌃↓ — по объявлениям.")
                } else {
                    Text("\(doc.model.lineCount) строк")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            } else if let root = workspace.root {
                Image(systemName: "folder").font(.system(size: 10))
                Text(root.lastPathComponent).font(.system(size: 11, weight: .medium))
            }

            Spacer()

            languageServerChip

            if workspace.isIndexing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Индексация…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if workspace.fileCount > 0 {
                Text("\(workspace.fileCount) файлов")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    // MARK: - Состояние языкового сервера

    /// Фишка в статус-строке — единственное место, где LSP вообще виден,
    /// пока он не готов. Всё остальное приложение о нём не знает.
    @ViewBuilder
    private var languageServerChip: some View {
        switch workspace.lsp.state {
        case .stopped:
            EmptyView()

        case .starting(let detail):
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.55)
                Text("\(workspace.lsp.serverName ?? "LSP") · \(detail)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("Языковой сервер готовится. Просмотр и поиск работают уже сейчас.")

        case .ready:
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(workspace.lsp.serverName ?? "LSP")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .help("Переход к определению: ⌘B или ⌘+клик. Символы: ⌘T. Использования: ⌘R.")

        case .failed(let why):
            HStack(spacing: 5) {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text(workspace.lsp.serverName ?? "LSP")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .help("Языковой сервер не поднялся:\n\(why)")
        }
    }

    /// Кнопки назад/вперёд появляются только когда есть куда идти.
    @ViewBuilder
    private var historyControls: some View {
        if workspace.canGoBack || workspace.canGoForward {
            HStack(spacing: 2) {
                Button { workspace.goBack() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                }
                .disabled(!workspace.canGoBack)
                Button { workspace.goForward() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .disabled(!workspace.canGoForward)
            }
            .buttonStyle(.borderless)
            .help("Назад / вперёд по переходам (⌘[ и ⌘])")
        }
    }

    // MARK: - Оверлей палитры

    private var paletteOverlay: some View {
        ZStack(alignment: .top) {
            // Клик мимо палитры закрывает её.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { workspace.isPaletteOpen = false }

            PaletteView(workspace: workspace)
                .padding(.top, 90)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
