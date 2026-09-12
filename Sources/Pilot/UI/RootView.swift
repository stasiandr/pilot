import SwiftUI
import AppKit

/// Окно в духе Xcode 26: плавающий стеклянный навигатор слева, над
/// редактором — jump bar, в тулбаре — заголовок с веткой и капсула
/// активности посередине.
struct RootView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        NavigationSplitView {
            NavigatorView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 440)
        } detail: {
            detail
                .toolbar { toolbar }
                .pilotTransparentToolbar()
        }
        .navigationTitle(workspace.root?.lastPathComponent ?? "Pilot")
        .overlay {
            if workspace.isPaletteOpen { paletteOverlay }
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    // MARK: - Редактор

    private var detail: some View {
        VStack(spacing: 0) {
            if workspace.root != nil {
                JumpBar(workspace: workspace)
            }
            content
            if workspace.root != nil {
                statusBar
            }
        }
        .background(Color(nsColor: Theme.editorBackground).ignoresSafeArea())
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
            noEditor
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

    /// Пустой редактор, как «No Editor» в Xcode: крупная приглушённая
    /// надпись и подсказки по клавишам.
    private var noEditor: some View {
        VStack(spacing: 18) {
            Text("Нет открытого файла")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 8) {
                shortcutHint(["⌘", "P"], "Перейти к файлу")
                shortcutHint(["⌘", "⇧", "O"], "Структура файла")
                shortcutHint(["⌘", "O"], "Открыть папку")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcutHint(_ keys: [String], _ title: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .frame(minWidth: 20, minHeight: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.08)))
                }
            }
            .frame(width: 76, alignment: .trailing)
            Text(title).font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Стартовый экран

    /// По мотивам окна «Welcome to Xcode»: слева иконка и главное действие,
    /// справа недавние проекты — всё на одной стеклянной панели.
    private var welcome: some View {
        HStack(spacing: 0) {
            VStack(spacing: 20) {
                appIcon
                VStack(spacing: 5) {
                    Text("Pilot").font(.system(size: 30, weight: .bold))
                    Text("Мгновенный просмотрщик кода")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Button {
                    workspace.promptForFolder()
                } label: {
                    Label("Открыть папку…", systemImage: "folder")
                        .frame(minWidth: 180)
                }
                .pilotGlassButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
            }
            .frame(maxWidth: .infinity)

            if !workspace.recentRoots.isEmpty {
                recentProjects
            }
        }
        .padding(24)
        .frame(width: workspace.recentRoots.isEmpty ? 380 : 700, height: 380)
        .pilotGlass(cornerRadius: 30)
        .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appIcon: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.54, green: 0.68, blue: 0.96),
                                          Color(red: 0.78, green: 0.63, blue: 0.96)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 96, height: 96)
            .overlay {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Недавние")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(workspace.recentRoots.prefix(6), id: \.path) { url in
                RecentProjectRow(url: url) { workspace.open(root: url) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.18)))
    }

    // MARK: - Тулбар

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            titleView
        }
        .pilotWithoutGlassBackground()

        ToolbarItem(placement: .principal) {
            ActivityView(workspace: workspace)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { workspace.openPalette(mode: .outline) } label: {
                Label("Структура файла", systemImage: "list.bullet.indent")
            }
            .help("Структура файла (⌘⇧O)")
            .disabled(workspace.document == nil)

            Button { workspace.openPalette(mode: .symbols) } label: {
                Label("Символ в проекте", systemImage: "number")
            }
            .help("Символ в проекте (⌘T)")
            .disabled(!workspace.lsp.isReady)
        }
    }

    /// Как в Xcode: иконка ветки, под именем проекта — текущая ветка.
    private var titleView: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(workspace.root?.lastPathComponent ?? "Pilot")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let branch = workspace.branch {
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 170, alignment: .leading)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Статусная строка

    /// Как нижняя полоса редактора Xcode: язык слева, позиция курсора справа.
    private var statusBar: some View {
        HStack(spacing: 10) {
            if let doc = workspace.document {
                let icon = Theme.fileIcon(forName: doc.url.lastPathComponent)
                Image(systemName: icon.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: icon.color))
                Text(doc.languageName)
                Text(Theme.count(doc.model.lineCount, "строка", "строки", "строк"))
                    .foregroundStyle(.tertiary)

                Spacer()

                let position = doc.model.position(at: workspace.caretOffset)
                Text("Строка: \(position.line + 1)   Столбец: \(position.character + 1)")
                    .monospacedDigit()
            } else {
                Spacer()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: Theme.editorBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
        }
    }

    // MARK: - Оверлей палитры

    private var paletteOverlay: some View {
        ZStack(alignment: .top) {
            // Клик мимо палитры закрывает её.
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { workspace.isPaletteOpen = false }

            PaletteView(workspace: workspace)
                .padding(.top, 60)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Капсула активности

/// Центральная капсула тулбара — как activity view в Xcode: слева «что
/// открыто», справа «что происходит». Клик — переход к файлу, как ⌘P.
struct ActivityView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Button {
            if workspace.root != nil { workspace.openPalette(mode: .files) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(workspace.root?.lastPathComponent ?? "Pilot")
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let doc = workspace.document {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    let icon = Theme.fileIcon(forName: doc.url.lastPathComponent)
                    Image(systemName: icon.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: icon.color))
                    Text(doc.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }

                // Не Spacer: Spacer внутри элемента тулбара SwiftUI принимает
                // за гибкий пробел и молча выбрасывает весь элемент.
                Color.clear.frame(minWidth: 24, maxWidth: .infinity, maxHeight: 1)
                // Статус не сжимается: ужимается имя проекта, как в Xcode.
                status.fixedSize()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(minWidth: 280, idealWidth: 440, maxWidth: 520, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Перейти к файлу (⌘P)")
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if workspace.root == nil {
                Text("Нет открытого проекта").foregroundStyle(.secondary)
            } else if workspace.isIndexing {
                ProgressView().controlSize(.mini)
                Text("Индексация…").foregroundStyle(.secondary)
            } else {
                Text("Готово").foregroundStyle(.secondary)
                Text("|").foregroundStyle(.quaternary)
                Text(Theme.count(workspace.fileCount, "файл", "файла", "файлов"))
                    .foregroundStyle(.tertiary)
            }
            languageServer
        }
        .lineLimit(1)
    }

    /// Состояние языкового сервера — единственное место, где он виден,
    /// пока не готов. Всё остальное приложение о нём не знает.
    @ViewBuilder
    private var languageServer: some View {
        let name = workspace.lsp.serverName ?? "LSP"
        switch workspace.lsp.state {
        case .stopped:
            EmptyView()
        case .starting(let detail):
            divider
            ProgressView().controlSize(.mini)
            Text(name).foregroundStyle(.secondary)
                .help("\(name): \(detail). Просмотр и поиск работают уже сейчас.")
        case .ready:
            divider
            Circle().fill(.green).frame(width: 6, height: 6)
            Text(name).foregroundStyle(.secondary)
                .help("Переход к определению: ⌘B или ⌘+клик. Символы: ⌘T. Использования: ⌘R.")
        case .failed(let why):
            divider
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(name).foregroundStyle(.secondary)
                .help("Языковой сервер не поднялся:\n\(why)")
        }
    }

    private var divider: some View {
        Text("|").foregroundStyle(.quaternary)
    }
}

// MARK: - Недавний проект на стартовом экране

struct RecentProjectRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(nsColor: Theme.folderIcon.color))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().path
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
