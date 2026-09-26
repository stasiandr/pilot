import SwiftUI

/// Плашка над редактором: в проекте нашлось расширение, которое ещё не
/// включали. Включить — правила начинают действовать сразу.
struct ExtensionBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let item = workspace.pendingExtensions.first {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("В проекте есть расширение «\(item.manifest.name)» — включить?"))
                        .font(.system(size: 12))
                    Text(ExtensionSummary.text(item.manifest))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 8)
                Button(L("Не включать")) { workspace.setExtension(item, enabled: false) }
                    .controlSize(.small)
                Button(L("Включить")) { workspace.setExtension(item, enabled: true) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: Theme.chromeBackground))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
            }
            .help(item.manifest.description ?? item.directory.path)
        }
    }
}

/// Что расширение меняет — одной строкой, из его разделов.
enum ExtensionSummary {
    static func text(_ manifest: ProjectRules.Manifest) -> String {
        let rules = manifest.rules
        var parts: [String] = []
        if !rules.pair.suffixes.isEmpty { parts.append(L("имена пары")) }
        if !rules.pair.mirrors.isEmpty { parts.append(L("зеркальные папки")) }
        if rules.datagrams != nil { parts.append(L("сетевые структуры")) }
        if rules.configs != nil { parts.append(L("конфиги")) }
        let what = parts.isEmpty ? L("ничего не описывает") : parts.joined(separator: ", ")
        return manifest.description.map { "\($0) — \(what)" } ?? what
    }
}

/// Настройки → Расширения: расширения открытых проектов, включить и выключить.
struct ExtensionSettingsView: View {
    /// Окна открываются и закрываются не отсюда: список берётся при показе
    /// вкладки и по кнопке.
    @State private var projects: [Workspace] = []

    var body: some View {
        Form {
            if projects.isEmpty {
                Text(L("Откройте проект — здесь появятся его расширения."))
                    .foregroundStyle(.secondary)
            }
            ForEach(projects, id: \.root) { workspace in
                ProjectExtensionsSection(workspace: workspace)
            }
            Section {
                Text(L("Расширение — папка .pilot/extensions/<имя>/ с extension.json в репозитории проекта. Оно описывает соглашения проекта: как узнать вторую половину пары, какие папки у половин одинаковые, как устроены сетевые структуры и конфиги. Код расширения не исполняют."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 420)
        .onAppear(perform: reload)
        .toolbar {
            Button(L("Перечитать")) {
                ProjectWindows.shared.workspaces.forEach { $0.refreshExtensions() }
                reload()
            }
        }
    }

    private func reload() {
        projects = ProjectWindows.shared.workspaces.filter { $0.root != nil }
    }
}

private struct ProjectExtensionsSection: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Section(workspace.root?.lastPathComponent ?? "") {
            if workspace.projectExtensions.isEmpty {
                Text(L("Расширений нет")).foregroundStyle(.secondary)
            }
            ForEach(workspace.projectExtensions, id: \.directory) { item in
                Toggle(isOn: Binding(get: { workspace.state(of: item) == .enabled },
                                     set: { workspace.setExtension(item, enabled: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.manifest.name)
                        Text(ExtensionSummary.text(item.manifest))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text((item.directory.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            ForEach(workspace.extensionProblems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
            }
        }
    }
}
