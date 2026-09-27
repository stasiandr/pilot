import SwiftUI
import AppKit

/// Настройки → Кэши: сколько места занимает Pilot, по проектам, и чем его
/// освободить. Всё, кроме истории правок, пересобирается само при следующем
/// открытии проекта — поэтому удаляется без вопросов.
struct CacheSettingsView: View {
    @State private var entries: [CacheStore.Entry] = []
    @State private var scanning = false
    @State private var confirmsHistory: CacheStore.Entry?
    @State private var confirmsAll = false
    @AppStorage(CacheStore.autoCleanKey) private var autoCleanDays = 0

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scanning && entries.isEmpty ? L("Считаю…") : L("Кэши Pilot: \(Self.size(cacheTotal))"))
                            .font(.headline)
                        if historyTotal > 0 {
                            Text(L("Ещё \(Self.size(historyTotal)) — история правок"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if scanning { ProgressView().controlSize(.small) }
                    Button(L("Показать в Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([CacheStore.Locations.standard.caches])
                    }
                }
                Picker(L("Удалять кэши проектов, которые не открывали"), selection: $autoCleanDays) {
                    Text(L("Никогда")).tag(0)
                    Text(L("30 дней")).tag(30)
                    Text(L("90 дней")).tag(90)
                    Text(L("180 дней")).tag(180)
                }
                HStack {
                    Button(L("Удалить устаревшие (\(Self.size(staleTotal)))")) { removeAll(stale) }
                        .disabled(stale.isEmpty)
                        .help(L("Проекты, которых нет на диске или которые не открывали \(String(staleDays)) дней"))
                    Button(L("Очистить все кэши…")) { confirmsAll = true }
                        .disabled(!caches.contains(where: CacheStore.canRemove))
                }
            } footer: {
                Text(L("Кэш ускоряет открытие проекта, поиск и навигацию. Удалённый кэш проект соберёт заново, когда его откроют. Кэши открытых проектов не удаляются."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(L("Проекты")) {
                if projects.isEmpty {
                    Text(scanning ? L("Считаю…") : L("Кэшей проектов нет")).foregroundStyle(.secondary)
                }
                ForEach(projects) { row($0) }
            }

            if !shared.isEmpty {
                Section(L("Общие")) {
                    ForEach(shared) { row($0) }
                }
            }

            if !history.isEmpty {
                Section {
                    ForEach(history) { row($0) }
                } header: {
                    Text(L("История правок"))
                } footer: {
                    Text(L("Не кэш: прежние версии файлов, которые Pilot сохранял при правке. Удалённую историю не вернуть."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 520)
        .onAppear(perform: rescan)
        .toolbar {
            Button(L("Пересчитать"), action: rescan).disabled(scanning)
        }
        .confirmationDialog(L("Удалить историю правок «\(confirmsHistory?.name ?? "")»?"),
                            isPresented: Binding(get: { confirmsHistory != nil }, set: { if !$0 { confirmsHistory = nil } })) {
            Button(L("Удалить"), role: .destructive) {
                if let entry = confirmsHistory { removeAll([entry]) }
            }
        } message: {
            Text(L("Прежние версии файлов этого проекта пропадут насовсем."))
        }
        .confirmationDialog(L("Очистить все кэши (\(Self.size(removableTotal)))?"), isPresented: $confirmsAll) {
            Button(L("Очистить"), role: .destructive) { removeAll(caches.filter(CacheStore.canRemove)) }
        } message: {
            Text(L("Проекты соберут кэши заново при следующем открытии — первый раз это дольше обычного. История правок останется."))
        }
    }

    // MARK: Строка

    private func row(_ entry: CacheStore.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(entry))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                    if entry.isOpen { tag(L("открыт"), .blue) }
                    if entry.isOrphan { tag(L("нет на диске"), .orange) }
                }
                Text(subtitle(entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(Self.size(entry.size))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                if entry.kind == .history { confirmsHistory = entry } else { removeAll([entry]) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!CacheStore.canRemove(entry))
            .help(entry.isOpen ? L("Проект открыт — закройте его, чтобы удалить") : L("Удалить"))
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func icon(_ entry: CacheStore.Entry) -> String {
        switch entry.kind {
        case .project: return "folder"
        case .assemblies: return "shippingbox"
        case .jadx: return "cup.and.saucer"
        case .oldCopilot: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        }
    }

    private func subtitle(_ entry: CacheStore.Entry) -> String {
        var parts: [String] = []
        switch entry.kind {
        case .project, .history:
            parts.append(entry.projectPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("путь неизвестен"))
        case .assemblies: parts.append(L("общие для всех проектов"))
        case .jadx: parts.append(L("ускоряет запуск декомпилятора"))
        case .oldCopilot: parts.append(entry.urls.map(\.lastPathComponent).joined(separator: ", "))
        }
        if let date = entry.lastUsed {
            parts.append(L("изменён \(date.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Данные

    private var projects: [CacheStore.Entry] { entries.filter { $0.kind == .project } }
    private var shared: [CacheStore.Entry] { entries.filter { $0.kind != .project && $0.kind != .history } }
    private var history: [CacheStore.Entry] { entries.filter { $0.kind == .history } }
    private var caches: [CacheStore.Entry] { entries.filter { $0.kind != .history } }
    /// Срок из автоочистки, а без неё — месяц.
    private var staleDays: Int { autoCleanDays > 0 ? autoCleanDays : 30 }
    private var stale: [CacheStore.Entry] { CacheStore.stale(entries, olderThan: staleDays) }

    private var cacheTotal: Int64 { caches.reduce(0) { $0 + $1.size } }
    private var historyTotal: Int64 { history.reduce(0) { $0 + $1.size } }
    private var staleTotal: Int64 { stale.reduce(0) { $0 + $1.size } }
    private var removableTotal: Int64 { caches.filter(CacheStore.canRemove).reduce(0) { $0 + $1.size } }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Недавние — прямо из настроек, без отсева: путь проекта, которого
    /// больше нет, как раз и нужен, чтобы сказать «нет на диске».
    static var knownRoots: [URL] {
        (UserDefaults.standard.array(forKey: "pilot.recentRoots") as? [String] ?? []).map(URL.init(fileURLWithPath:))
    }

    static var openRoots: [URL] {
        ProjectWindows.shared.workspaces.compactMap(\.root)
    }

    private func rescan() {
        guard !scanning else { return }
        scanning = true
        let known = Self.knownRoots, open = Self.openRoots, copilot = CopilotInstaller.version
        Task.detached(priority: .userInitiated) {
            let found = CacheStore.scan(known: known, open: open, copilotVersion: copilot)
            await MainActor.run {
                entries = found
                scanning = false
            }
        }
    }

    private func removeAll(_ doomed: [CacheStore.Entry]) {
        scanning = true
        Task.detached(priority: .userInitiated) {
            for entry in doomed { CacheStore.remove(entry) }
            await MainActor.run {
                scanning = false
                rescan()
            }
        }
    }
}
