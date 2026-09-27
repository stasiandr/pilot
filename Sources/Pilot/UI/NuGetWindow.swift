import SwiftUI
import AppKit

/// Окно NuGet проекта — как одноимённое окно Rider: слева пакеты
/// (установленные, с обновлениями или найденные в лентах), справа
/// выбранный пакет: версия и в какие проекты он поставлен. Вкладка
/// «Источники» — ленты из NuGet.Config с логином и токеном.
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

// MARK: - Кнопка в тулбаре

/// NuGet в тулбаре окна проекта — у проектов .NET. Точка на значке, как у
/// кнопки базы: пакеты не восстановлены, и компиляция их не видит.
///
/// Отчёт приходит значением, а не подпиской на NuGetService: иначе каждая
/// буква в поиске окна NuGet перестраивала бы тулбар окна проекта.
struct NuGetToolbarButton: View {
    let report: NuGetRestoreReport
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label {
                Text(L("Пакеты NuGet"))
            } icon: {
                Image(systemName: "shippingbox")
                    .overlay(alignment: .bottomTrailing) {
                        if report.needsAttention {
                            Circle()
                                .fill(Color(nsColor: Theme.diagnosticWarning))
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: 2)
                        }
                    }
            }
        }
        .help(help)
    }

    private var help: String {
        let title = KeymapStore.shared.help(L("Пакеты NuGet"), .nuget)
        return report.needsAttention ? title + "\n" + report.headline : title
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
            restoreBanner
            if nuget.tab != .sources { sourcesBanner }
            HSplitView {
                Group {
                    if nuget.tab == .sources { sourceList } else { packageList }
                }
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
                Group {
                    if nuget.tab == .sources { sourceDetail } else { detail }
                }
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
        .background(Color(nsColor: Theme.swiftUIEditorBackground))
        .onAppear {
            nuget.activate()
            filterFocused = true
        }
        .onDisappear { nuget.deactivate() }
        .onChange(of: nuget.tab) { _, tab in
            nuget.selectedID = nil
            switch tab {
            case .browse: nuget.search()
            case .sources:
                nuget.checkAllSources()
                if nuget.selectedSource == nil {
                    nuget.selectedSource = nuget.missingSources.first.map { "suggested:" + $0.url } ?? nuget.sources.first?.id
                }
            default: nuget.selectedID = nuget.list(for: tab).first?.id
            }
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

            if nuget.tab == .sources {
                Spacer()
                Button {
                    nuget.reloadSources()
                    nuget.checkAllSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L("Перечитать NuGet.Config и проверить ленты"))
            } else {
                filterControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var filterControls: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(nuget.tab == .browse ? searchPrompt : L("Фильтр по имени"), text: $nuget.filter)
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

    private var searchPrompt: String {
        let names = nuget.sources.filter { $0.isEnabled && $0.isRemote }.map(\.name)
        if names.count > 1 {
            let list = names.joined(separator: ", ")
            return L("Искать в лентах: \(list)")
        }
        let name = names.first ?? "nuget.org"
        return L("Искать на \(name)")
    }

    private func tabTitle(_ tab: NuGetService.Tab) -> String {
        switch tab {
        case .installed: return "\(tab.title) \(nuget.installed.count)"
        case .updates:
            let count = nuget.updates.count
            return count > 0 ? "\(tab.title) \(count)" : tab.title
        case .browse: return tab.title
        case .sources:
            let attention = nuget.missingSources.count + nuget.sourcesNeedingLogin.count
            return attention > 0 ? "\(tab.title) \(attention)" : tab.title
        }
    }

    // MARK: - restore

    /// Пакеты, которых компиляция не видит, — над всеми вкладками: на
    /// «Источниках» чинят ленту, и restore после этого — тут же.
    @ViewBuilder
    private var restoreBanner: some View {
        let report = nuget.restore
        if !report.problems.isEmpty {
            // Тесты и утилиты рядом с собранным проектом — спокойнее.
            let tint = report.needsAttention ? Color(nsColor: Theme.diagnosticWarning) : Color.secondary
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: report.needsAttention ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.headline)
                        .lineLimit(2)
                    ForEach(report.reasons + report.messages, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .help(report.details)
                Spacer(minLength: 8)
                Button(L("Восстановить")) { nuget.restorePackages() }
                    .disabled(nuget.isBusy)
                    .help(L("dotnet restore этих проектов"))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(report.needsAttention ? tint.opacity(0.12) : Color.clear)
            Divider()
        }
    }

    // MARK: - Ленты

    /// Проекту нужна лента, которой нет, или лента не пускает без логина:
    /// без неё restore упадёт, а пакетов из неё не найти.
    @ViewBuilder
    private var sourcesBanner: some View {
        let missing = nuget.missingSources
        let locked = nuget.sourcesNeedingLogin
        if !missing.isEmpty || !locked.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
                if let first = missing.first {
                    Text(L("Проекту нужна лента «\(first.name)» — её нет в NuGet.Config"))
                } else if let first = locked.first {
                    Text(L("Лента «\(first.name)» не пускает без логина и токена"))
                }
                Spacer()
                Button(missing.isEmpty ? L("Ввести токен…") : L("Подключить…")) {
                    nuget.selectedSource = missing.first.map { "suggested:" + $0.url } ?? locked.first?.id
                    nuget.tab = .sources
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: Theme.diagnosticWarning).opacity(0.12))
            Divider()
        }
    }

    private var sourceList: some View {
        VStack(spacing: 0) {
            List(selection: $nuget.selectedSource) {
                if !nuget.missingSources.isEmpty {
                    Section(L("Нужны проекту")) {
                        ForEach(nuget.missingSources, id: \.url) { suggested in
                            SuggestedSourceRow(source: suggested)
                                .tag("suggested:" + suggested.url)
                        }
                    }
                }
                Section(L("NuGet.Config")) {
                    ForEach(nuget.sources) { source in
                        SourceRow(source: source, status: nuget.sourceStatus[source.id])
                            .tag(source.id)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button {
                    nuget.selectedSource = "new"
                } label: {
                    Label(L("Новая лента"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var sourceDetail: some View {
        let selection = nuget.selectedSource
        if selection == "new" {
            SourceDetail(nuget: nuget, source: nil, suggested: nil).id("new")
        } else if let selection, selection.hasPrefix("suggested:"),
                  let suggested = nuget.suggestedSources.first(where: { "suggested:" + $0.url == selection }) {
            SourceDetail(nuget: nuget, source: nil, suggested: suggested).id(selection)
        } else if let source = nuget.sources.first(where: { $0.id == selection }) {
            SourceDetail(nuget: nuget, source: source, suggested: nil).id(source)
        } else {
            placeholder(icon: "tray.2", L("Выберите ленту"), nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Список

    @ViewBuilder
    private var packageList: some View {
        VStack(spacing: 0) {
            if nuget.tab == .browse, !nuget.searchFailures.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
                    Text(nuget.searchFailures.joined(separator: "; "))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
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
                placeholder(icon: "wifi.exclamationmark", L("Ленты не ответили"), error)
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
                    if !package.isFromNuGetOrg {
                        Text(package.source)
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color(nsColor: Theme.separator)))
                            .foregroundStyle(.secondary)
                    }
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

    /// Версии для выбора: из лент, без предварительных, если их не просили.
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
                    if info?.isFromNuGetOrg ?? true, let url = URL(string: "https://www.nuget.org/packages/\(id)") {
                        Link("nuget.org", destination: url)
                    } else if let info {
                        Label(info.source, systemImage: "tray.2")
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

// MARK: - Источники

private struct SourceRow: View {
    let source: NuGetSource
    let status: NuGetService.SourceStatus?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: source.isRemote ? "globe" : "folder")
                .foregroundStyle(source.isEnabled ? Color(nsColor: Theme.assetLink) : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(source.isEnabled ? .primary : .secondary)
                Text(source.url)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !source.isEnabled {
                Text(L("выключена")).font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                SourceStatusIcon(status: status)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SuggestedSourceRow: View {
    let source: SuggestedNuGetSource

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).fontWeight(.medium).lineLimit(1)
                Text(source.url)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SourceStatusIcon: View {
    let status: NuGetService.SourceStatus?

    var body: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.mini)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: Theme.gitAdded))
                .help(L("Лента отвечает"))
        case .unauthorized:
            Image(systemName: "key.fill")
                .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
                .help(L("Нужен логин и токен"))
        case .failed(let message):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color(nsColor: Theme.diagnosticError))
                .help(message)
        case nil:
            EmptyView()
        }
    }
}

/// Лента: подключённая (правка логина и токена), предложенная расширением
/// проекта или новая.
private struct SourceDetail: View {
    @ObservedObject var nuget: NuGetService
    let source: NuGetSource?
    let suggested: SuggestedNuGetSource?

    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var note: String?
    @State private var isFilling = false
    @State private var loaded = false

    /// Имя и адрес объявлены в репозитории — здесь только логин и токен.
    private var isLocked: Bool { source.map { !nuget.isUserSource($0) } ?? false }
    private var gitLabHost: String? {
        guard url.contains("/api/v4/") else { return nil }
        return URL(string: url)?.host
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                title
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text(L("Имя")).foregroundStyle(.secondary)
                        TextField("", text: $name).disabled(isLocked)
                    }
                    GridRow {
                        Text(L("Адрес")).foregroundStyle(.secondary)
                        TextField("https://…/index.json", text: $url).disabled(isLocked)
                    }
                    GridRow {
                        Text(L("Логин")).foregroundStyle(.secondary)
                        TextField(gitLabHost != nil ? L("имя пользователя в GitLab") : "", text: $username)
                    }
                    GridRow {
                        Text(L("Токен")).foregroundStyle(.secondary)
                        SecureField(L("или пароль"), text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 560)

                if let host = gitLabHost {
                    gitLabHelp(host)
                }

                HStack(spacing: 10) {
                    Button(source == nil ? L("Подключить") : L("Сохранить")) { save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    if let source {
                        Button(L("Проверить")) { nuget.check(source) }
                        SourceStatusIcon(status: nuget.sourceStatus[source.id])
                        Spacer()
                        Toggle(L("Включена"), isOn: Binding(
                            get: { source.isEnabled },
                            set: { enabled in perform { try nuget.setEnabled(enabled, source: source) } }))
                            .toggleStyle(.checkbox)
                        if nuget.isUserSource(source) {
                            Button(role: .destructive) {
                                perform { try nuget.removeSource(source) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(L("Убрать ленту из NuGet.Config"))
                        }
                    }
                }
                if case .failed(let message)? = source.flatMap({ nuget.sourceStatus[$0.id] }) {
                    Text(message).foregroundStyle(Color(nsColor: Theme.diagnosticError)).font(.system(size: 11))
                }
                if case .unauthorized? = source.flatMap({ nuget.sourceStatus[$0.id] }) {
                    Text(L("Лента не приняла логин и токен"))
                        .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
                        .font(.system(size: 11))
                }
                if let error {
                    Text(error).foregroundStyle(Color(nsColor: Theme.diagnosticError)).font(.system(size: 11))
                }
                if let note {
                    Text(note).foregroundStyle(.secondary).font(.system(size: 11))
                }

                Divider()
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = source?.name ?? suggested?.name ?? ""
            url = source?.url ?? suggested?.url ?? ""
            username = source?.username ?? ""
            password = source?.password ?? ""
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(source?.name ?? suggested?.name ?? L("Новая лента"))
                .font(.system(size: 17, weight: .semibold))
            if let file = source?.configFile {
                Text(file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if suggested != nil {
                Text(L("Нужна проекту по его расширению"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func gitLabHelp(_ host: String) -> some View {
        HStack(spacing: 10) {
            Button {
                fillFromPilot()
            } label: {
                if isFilling { ProgressView().controlSize(.mini) } else { Text(L("Взять токен Pilot для \(host)")) }
            }
            .disabled(isFilling)
            .help(L("Токен, который Pilot хранит для ревью мерж-реквестов, и ваш логин в GitLab"))
            if let link = URL(string: "https://\(host)/-/user_settings/personal_access_tokens") {
                Link(L("Создать токен в GitLab"), destination: link)
                    .help(L("Права: read_api и read_registry, срок можно не ограничивать"))
            }
        }
        .font(.system(size: 12))
    }

    private var footnote: String {
        var lines: [String] = []
        if isLocked {
            lines.append(L("Лента объявлена в репозитории: логин и токен Pilot запишет не туда, а в ~/.nuget/NuGet/NuGet.Config."))
        }
        lines.append(L("Логин и токен хранятся в ~/.nuget/NuGet/NuGet.Config открытым текстом — только так их читает dotnet на macOS. Оттуда же их берут restore, Rider и сборка."))
        return lines.joined(separator: "\n")
    }

    private func fillFromPilot() {
        isFilling = true
        error = nil
        note = nil
        Task {
            if let found = await nuget.gitLabCredentials(for: url) {
                username = found.username
                password = found.token
                let action = source == nil ? L("Подключить") : L("Сохранить")
                note = L("Логин и токен взяты из Pilot — нажмите «\(action)»")
            } else {
                error = L("У Pilot нет рабочего токена для этого GitLab — создайте токен и вставьте его сюда")
            }
            isFilling = false
        }
    }

    private func save() {
        perform {
            try nuget.saveSource(original: source, name: name, url: url, username: username, password: password)
            note = nil
        }
    }

    private func perform(_ action: () throws -> Void) {
        error = nil
        do { try action() } catch { self.error = error.localizedDescription }
    }
}
