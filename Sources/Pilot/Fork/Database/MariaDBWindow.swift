import SwiftUI
import AppKit

/// Окна базы данных: контейнер MariaDB и обозреватель. Оба — по одному на
/// приложение, а не на проект: база одна на машину.
struct DatabaseScenes: Scene {
    var body: some Scene {
        Window(L("MariaDB в Docker"), id: MariaDBWindow.sceneID) {
            MariaDBWindow()
        }
        .defaultSize(width: 760, height: 560)
        Window(L("База данных"), id: DatabaseWindow.sceneID) {
            DatabaseWindow()
        }
        .defaultSize(width: 1200, height: 760)
    }
}

/// Меню «База данных».
struct DatabaseCommands: Commands {
    var body: some Commands {
        CommandMenu(L("База данных")) {
            OpenWindowButton(title: L("MariaDB в Docker…"), id: MariaDBWindow.sceneID)
            OpenWindowButton(title: L("Обозреватель базы…"), id: DatabaseWindow.sceneID)
        }
    }
}

private struct OpenWindowButton: View {
    let title: String
    let id: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: id) }
    }
}

// MARK: - Контейнер

struct MariaDBWindow: View {
    static let sceneID = "mariadb"

    @ObservedObject private var container = MariaDBContainer.shared
    @ObservedObject private var language = LanguageStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsWipe = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                settingsForm
                    .frame(width: 300)
                Divider()
                environment
            }
            .frame(height: 220)
            Divider()
            ConsoleTextView(log: container.log)
                .background(Color(nsColor: Theme.chromeBackground))
        }
        .background(Color(nsColor: Theme.editorBackground))
        .navigationTitle(L("MariaDB в Docker"))
        .frame(minWidth: 640, minHeight: 420)
        .id(language.current)
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
        .onAppear { container.appear() }
        .onDisappear { container.disappear() }
        .confirmationDialog(L("Удалить контейнер и все данные базы?"), isPresented: $confirmsWipe) {
            Button(L("Удалить вместе с данными"), role: .destructive) { container.remove(data: true) }
        } message: {
            Text(L("Том \(container.settings.volume) будет удалён — вернуть базу будет нельзя."))
        }
        .background {
            Button("") { dismiss() }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
        }
    }

    // MARK: Шапка: состояние и кнопки

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                if let subtitle = statusSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let busy = container.busy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            }
            actions
                .disabled(container.busy != nil)
        }
        .padding(12)
    }

    @ViewBuilder
    private var actions: some View {
        switch container.state {
        case .unknown, .noDocker:
            EmptyView()
        case .daemonDown:
            if container.canStartColima {
                Button(L("Запустить Colima")) { container.startColima() }
            }
        case .absent:
            Button(L("Создать и запустить")) { container.create() }
                .buttonStyle(.borderedProminent)
            Button(L("Удалить данные…")) { confirmsWipe = true }
        case .stopped:
            Button(L("Запустить")) { container.start() }
                .buttonStyle(.borderedProminent)
            moreMenu
        case .running:
            Button(L("Открыть в обозревателе")) {
                DatabaseBrowser.shared.connect(to: container.connectionOptions)
                openWindow(id: DatabaseWindow.sceneID)
            }
            .buttonStyle(.borderedProminent)
            Button(L("Остановить")) { container.stop() }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if case .running = container.state {
                Button(L("Перезапустить")) { container.restart() }
                Button(L("Загрузить дамп…")) { container.chooseDump() }
                Divider()
            }
            Button(container.followsLogs ? L("Не следить за логами") : L("Следить за логами")) { container.toggleLogs() }
            Button(L("Очистить вывод")) { container.log.clear() }
            Divider()
            Button(L("Удалить контейнер (данные останутся)")) { container.remove(data: false) }
            Button(L("Удалить контейнер и данные…"), role: .destructive) { confirmsWipe = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var statusColor: Color {
        switch container.state {
        case .running(let health):
            return health == "starting" ? .yellow : health == "unhealthy" ? .orange : .green
        case .stopped: return .gray
        case .absent: return .secondary.opacity(0.4)
        case .daemonDown, .noDocker: return .red
        case .unknown: return .clear
        }
    }

    private var statusTitle: String {
        switch container.state {
        case .unknown: return L("Проверка…")
        case .noDocker: return L("Docker не найден")
        case .daemonDown: return L("Docker не отвечает")
        case .absent: return L("Контейнера \(container.settings.name) нет")
        case .stopped(let status): return L("Остановлен (\(status))")
        case .running(let health):
            switch health {
            case "starting": return L("Запущен, база готовится…")
            case "unhealthy": return L("Запущен, но база не отвечает")
            default: return L("Работает")
            }
        }
    }

    private var statusSubtitle: String? {
        switch container.state {
        case .noDocker: return L("Поставьте Docker Desktop, OrbStack или Colima (brew install colima docker)")
        case .daemonDown(let message): return message.isEmpty ? nil : message
        case .running, .stopped:
            let d = container.details
            return [d.image, d.ports, d.id].filter { !$0.isEmpty }.joined(separator: " · ")
        default: return nil
        }
    }

    // MARK: Настройки контейнера

    /// Меняются, пока контейнера нет: у созданного они уже зашиты в него.
    private var settingsForm: some View {
        let locked: Bool = {
            if case .absent = container.state { return false }
            if case .daemonDown = container.state { return false }
            return true
        }()
        return Form {
            TextField(L("Контейнер"), text: $container.settings.name)
            TextField(L("Образ"), text: $container.settings.image)
            TextField(L("Порт"), value: $container.settings.port, format: .number.grouping(.never))
            TextField(L("Пароль root"), text: $container.settings.password)
            TextField(L("Имя базы"), text: $container.settings.database)
            if locked {
                Text(L("Чтобы поменять, удалите контейнер — данные в томе останутся."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(locked)
        .padding(12)
    }

    private var environment: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Окружение clm-server")).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(container.serverEnvironment, forType: .string)
                } label: {
                    Label(L("Скопировать"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            Text(container.serverEnvironment)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(12)
    }
}
