import SwiftUI
import AppKit

/// Окно NuGet проекта — как одноимённое окно Rider: слева пакеты
/// (установленные, с обновлениями или найденные на nuget.org), справа
/// выбранный пакет: версия и в какие проекты он поставлен.
///
/// Своё окно у каждого проекта: открывается по пути корня, а сервис
/// берёт у воркспейса окна этого проекта.
struct NuGetWindow: View {
    static let sceneID = "nuget"

    let rootPath: String?
    @ObservedObject private var language = LanguageStore.shared

    var body: some View {
        Group {
            if let workspace = ProjectWindows.shared.workspaces.first(where: { $0.root?.path == rootPath }) {
                NuGetView(nuget: workspace.nuget)
                    .navigationTitle(L("NuGet — \(workspace.root?.lastPathComponent ?? "")"))
            } else {
                Text(L("Проект этого окна закрыт"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("NuGet")
            }
        }
        .id(language.current)
        .frame(minWidth: 820, minHeight: 480)
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
    }
}

struct NuGetView: View {
    @ObservedObject var nuget: NuGetService
    @Environment(\.dismiss) private var dismiss
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                packageList
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
                detail
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
            if nuget.showsLog {
                Divider()
                ConsoleTextView(log: nuget.log)
                    .frame(height: 170)
                    .background(Color(nsColor: Theme.chromeBackground))
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: Theme.editorBackground))
        .onAppear {
            nuget.activate()
            filterFocused = true
        }
        .onChange(of: nuget.tab) { _, tab in
            nuget.selectedID = nil
            if tab == .browse { nuget.search() } else { nuget.selectedID = nuget.list(for: tab).first?.id }
        }
        .onChange(of: nuget.filter) { _, _ in
            if nuget.tab == .browse { nuget.search(debounced: true) }
        }
        .onChange(of: nuget.selectedID) { _, id in
            if let id { nuget.loadDetails(id) }
        }
        // ⌘W закрывает окно: пункт меню «Закрыть вкладку» без проекта впереди выключен.
        .background {
            Button("") { dismiss() }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $nuget.tab) {
                ForEach(NuGetService.Tab.allCases) { tab in
                    Text(tabTitle(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(nuget.tab == .browse ? L("Искать на nuget.org") : L("Фильтр по имени"), text: $nuget.filter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onSubmit { if nuget.tab == .browse { nuget.search() } }
                if !nuget.filter.isEmpty {
                    Button { nuget.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.separator).opacity(0.6)))

            Toggle(L("Предварительные"), isOn: $nuget.includePrerelease)
                .toggleStyle(.checkbox)
                .help(L("Показывать и предлагать версии с меткой: -beta, -rc, -preview"))

            Button {
                nuget.refresh()
                if nuget.tab == .browse { nuget.search() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L("Перечитать проекты"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tabTitle(_ tab: NuGetService.Tab) -> String {
        switch tab {
        case .installed: return "\(tab.title) \(nuget.installed.count)"
        case .updates:
            let count = nuget.updates.count
            return count > 0 ? "\(tab.title) \(count)" : tab.title
        case .browse: return tab.title
        }
    }

    // MARK: - Список

    @ViewBuilder
    private var packageList: some View {
        VStack(spacing: 0) {
            if nuget.tab == .updates, !nuget.updates.isEmpty {
                HStack {
                    Text(Localization.count(nuget.updates.count, "обновление", "обновления", "обновлений"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Обновить все")) { nuget.updateAll() }
                        .disabled(nuget.isBusy)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
            List(selection: $nuget.selectedID) {
                if nuget.tab == .browse {
                    ForEach(nuget.results) { package in
                        SearchRow(package: package, installed: nuget.installed(package.id))
                            .tag(package.id)
                    }
                } else {
                    ForEach(nuget.list(for: nuget.tab)) { package in
                        InstalledRow(package: package, update: nuget.update(for: package))
                            .tag(package.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay { listPlaceholder }
        }
    }

    @ViewBuilder
    private var listPlaceholder: some View {
        if nuget.tab == .browse {
            if nuget.isSearching && nuget.results.isEmpty {
                ProgressView().controlSize(.small)
            } else if let error = nuget.searchError {
                placeholder(icon: "wifi.exclamationmark", L("Не удалось спросить nuget.org"), error)
            } else if nuget.results.isEmpty {
                placeholder(icon: "shippingbox", L("Ничего не нашлось"), nil)
            }
        } else if nuget.isScanning && nuget.projects.isEmpty {
            ProgressView().controlSize(.small)
        } else if nuget.projects.isEmpty {
            placeholder(icon: "shippingbox",
                        L("Нет проектов .NET в SDK-стиле"),
                        L("Проекты Unity генерирует редактор — пакеты NuGet в них не ставят"))
        } else if nuget.list(for: nuget.tab).isEmpty {
            if nuget.tab == .updates {
                placeholder(icon: "checkmark.circle",
                            nuget.isCheckingUpdates ? L("Проверяю обновления…") : L("Всё свежее"), nil)
            } else if nuget.filter.isEmpty {
                placeholder(icon: "shippingbox", L("Пакетов пока нет"), L("Найдите их на вкладке «Поиск»"))
            } else {
                placeholder(icon: "shippingbox", L("Ничего не нашлось"), nil)
            }
        }
    }

    private func placeholder(icon: String, _ title: String, _ hint: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
    }

    // MARK: - Пакет

    @ViewBuilder
    private var detail: some View {
        if let id = nuget.selectedID {
            PackageDetail(nuget: nuget, id: id)
                .id(id)
        } else {
            placeholder(icon: "shippingbox", L("Выберите пакет"), nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Строка состояния

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch nuget.operation {
            case .idle:
                Text(Localization.count(nuget.projects.count, "проект", "проекта", "проектов"))
                    .foregroundStyle(.secondary)
            case .running(let title):
                ProgressView().controlSize(.mini)
                Text(title).lineLimit(1)
                Button(L("Отменить")) { nuget.cancel() }
                    .buttonStyle(.borderless)
            case .finished(let succeeded, let message):
                Image(systemName: succeeded ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(Color(nsColor: succeeded ? Theme.gitAdded : Theme.diagnosticError))
                Text(message).lineLimit(1)
            }
            Spacer()
            if nuget.isCheckingUpdates {
                ProgressView().controlSize(.mini)
                Text(L("Проверяю обновления…")).foregroundStyle(.secondary)
            }
            Button { nuget.showsLog.toggle() } label: {
                Label(L("Вывод dotnet"), systemImage: nuget.showsLog ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(nsColor: Theme.chromeBackground))
    }
}

// MARK: - Строки списка

private struct InstalledRow: View {
    let package: InstalledPackage
    let update: NuGetVersion?

    var body: some View {
        HStack(spacing: 8) {
            PackageIcon(url: nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.id).fontWeight(.medium).lineLimit(1)
                Text(Localization.count(package.versions.count, "проект", "проекта", "проектов"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(versionText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(package.isInconsistent ? Color(nsColor: Theme.diagnosticWarning) : .secondary)
                    .help(package.isInconsistent ? L("В проектах разные версии") : "")
                if let update {
                    Text("→ \(update.text)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: Theme.gitAdded))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var versionText: String {
        let distinct = Set(package.versions.values.map { $0 ?? "?" })
        if distinct.count == 1 { return distinct.first! }
        return package.newestInstalled.map { "\($0.text)…" } ?? "?"
    }
}

private struct SearchRow: View {
    let package: NuGetPackage
    let installed: InstalledPackage?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PackageIcon(url: package.iconURL)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(package.id).fontWeight(.medium).lineLimit(1)
                    if package.verified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(nsColor: Theme.assetLink))
                            .help(L("Префикс имени подтверждён владельцем"))
                    }
                }
                Text(package.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(package.version)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if installed != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.gitAdded))
                        .help(L("Уже установлен"))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PackageIcon: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 22, height: 22)
    }

    private var fallback: some View {
        Image(systemName: "shippingbox.fill")
            .font(.system(size: 16))
            .foregroundStyle(Color(nsColor: Theme.assetLink).opacity(0.8))
    }
}

// MARK: - Карточка пакета

private struct PackageDetail: View {
    @ObservedObject var nuget: NuGetService
    let id: String
    /// Какую версию ставить; nil — предложенную (последнюю).
    @State private var chosen: NuGetVersion?

    private var key: String { id.lowercased() }
    private var info: NuGetPackage? { nuget.details[key] ?? nuget.results.first { $0.id == id } }
    private var installed: InstalledPackage? { nuget.installed(id) }

    /// Версии для выбора: с nuget.org, без предварительных, если их не просили.
    private var available: [NuGetVersion] {
        let all = nuget.versions[key] ?? info?.versions ?? []
        let current = installed?.newestInstalled
        return all.filter { nuget.includePrerelease || !$0.isPrerelease || $0 == current }
    }

    private var target: NuGetVersion? {
        chosen ?? available.first { !$0.isPrerelease || nuget.includePrerelease } ?? info?.latest
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                title
                if let info, !info.description.isEmpty {
                    Text(info.description)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if info == nil {
                    ProgressView().controlSize(.small)
                }
                versionRow
                Divider()
                projectsTable
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: some View {
        HStack(alignment: .top, spacing: 10) {
            PackageIcon(url: info?.iconURL)
                .scaleEffect(1.5)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(id)
                    .font(.system(size: 17, weight: .semibold))
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    if let info, !info.authors.isEmpty {
                        Text(info.authors).lineLimit(1)
                    }
                    if let info, info.totalDownloads > 0 {
                        Label(Self.downloads(info.totalDownloads), systemImage: "arrow.down.circle")
                    }
                    if let url = info?.projectURL {
                        Link(L("Сайт"), destination: url)
                    }
                    if let url = URL(string: "https://www.nuget.org/packages/\(id)") {
                        Link("nuget.org", destination: url)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var versionRow: some View {
        HStack(spacing: 10) {
            Text(L("Версия"))
            Picker("", selection: Binding(get: { target }, set: { chosen = $0 })) {
                ForEach(available, id: \.self) { version in
                    Text(version.text).tag(Optional(version))
                }
                if available.isEmpty, let target {
                    Text(target.text).tag(Optional(target))
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .disabled(available.isEmpty)
            Spacer()
            let missing = nuget.projects.filter { $0.reference(id) == nil }.map(\.path)
            let differ = nuget.projects.filter { project in
                guard let reference = project.reference(id) else { return false }
                return reference.resolved != target
            }.map(\.path)
            if !differ.isEmpty, let target {
                Button(L("Всем — \(target.text)")) { nuget.install(id, version: target.text, projects: differ) }
                    .help(L("Поставить эту версию во все проекты, где пакет уже есть"))
                    .disabled(nuget.isBusy)
            }
            if !missing.isEmpty {
                Button(L("Установить во все")) { nuget.install(id, version: target?.text, projects: missing) }
                    .buttonStyle(.borderedProminent)
                    .disabled(nuget.isBusy)
            }
        }
    }

    private var projectsTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Проекты"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            if nuget.projects.isEmpty {
                Text(L("Нет проектов .NET в SDK-стиле")).foregroundStyle(.secondary)
            }
            ForEach(nuget.projects) { project in
                ProjectRow(nuget: nuget, project: project, id: id, target: target)
                Divider().opacity(0.5)
            }
        }
    }

    static func downloads(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1e3)
        default: return String(n)
        }
    }
}

private struct ProjectRow: View {
    @ObservedObject var nuget: NuGetService
    let project: NuGetProject
    let id: String
    let target: NuGetVersion?

    var body: some View {
        let reference = project.reference(id)
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).lineLimit(1)
                Text([project.path, project.frameworks].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let reference {
                Text(reference.version ?? "—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(reference.isCentral ? L("Версия из Directory.Packages.props") : "")
                if reference.isCentral {
                    Image(systemName: "building.columns")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help(L("Версия из Directory.Packages.props"))
                }
                if let target, reference.resolved != target {
                    let newer = reference.resolved.map { target > $0 } ?? true
                    Button(newer ? L("Обновить до \(target.text)") : L("Сменить на \(target.text)")) {
                        nuget.install(id, version: target.text, projects: [project.path])
                    }
                    .disabled(nuget.isBusy)
                }
                Button(role: .destructive) {
                    nuget.remove(id, projects: [project.path])
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L("Удалить из \(project.name)"))
                .disabled(nuget.isBusy)
            } else {
                Button(L("Установить")) {
                    nuget.install(id, version: target?.text, projects: [project.path])
                }
                .disabled(nuget.isBusy)
            }
        }
        .padding(.vertical, 6)
    }
}
