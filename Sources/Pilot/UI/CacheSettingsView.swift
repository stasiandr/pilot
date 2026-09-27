import SwiftUI
import AppKit

/// Настройки → Кэши: сколько места занимает Pilot — по видам и по проектам,
/// схемой и цифрами, — что из этого хранить и чем место освободить. Всё,
/// кроме истории правок, пересобирается само при следующем открытии
/// проекта — поэтому удаляется без вопросов.
struct CacheSettingsView: View {
    @State private var entries: [CacheStore.Entry]
    @State private var policy: CachePolicy
    @State private var scanning = false
    /// Проекты, раскрытые по видам.
    @State private var expanded: Set<String>
    /// Вид под мышью: на схемах и в строках он ярче, остальные бледнее.
    @State private var highlighted: CacheKind?
    @State private var confirmsHistory: CacheStore.Entry?
    @State private var confirmsAll = false
    /// Вид только что выключили — предложить удалить то, что он уже занимает.
    @State private var offer: Offer?
    @AppStorage(CacheStore.autoCleanKey) private var autoCleanDays = 0

    /// Строки даны готовыми, а не найдены на диске: снимок вида.
    private let isSample: Bool

    init() {
        _entries = State(initialValue: [])
        _policy = State(initialValue: .current)
        _expanded = State(initialValue: [])
        isSample = false
    }

    /// С готовыми строками и настройкой — чтобы посмотреть на вид без диска.
    init(sample: [CacheStore.Entry], policy: CachePolicy = CachePolicy(), expanded: Set<String> = []) {
        _entries = State(initialValue: sample)
        _policy = State(initialValue: policy)
        _expanded = State(initialValue: expanded)
        isSample = true
    }

    struct Offer: Identifiable {
        let kind: CacheKind
        /// Всё, что перестало храниться: с разбором файлов — и компиляция.
        let kinds: Set<CacheKind>
        var id: CacheKind { kind }
    }

    var body: some View {
        Form {
            overview
            kindSection
            projectSection
            if !history.isEmpty { historySection }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 620)
        .onAppear {
            guard !isSample else { return }
            policy = .current
            rescan()
        }
        .confirmationDialog(L("Удалить историю правок «\(confirmsHistory?.name ?? "")»?"),
                            isPresented: Binding(get: { confirmsHistory != nil }, set: { if !$0 { confirmsHistory = nil } })) {
            Button(L("Удалить"), role: .destructive) {
                if let entry = confirmsHistory { remove([(entry, nil)]) }
            }
        } message: {
            Text(L("Прежние версии файлов этого проекта пропадут насовсем."))
        }
        .confirmationDialog(L("Очистить все кэши (\(Self.size(removableTotal)))?"), isPresented: $confirmsAll) {
            Button(L("Очистить"), role: .destructive) { remove(caches.map { ($0, nil) }) }
        } message: {
            Text(L("Проекты соберут кэши заново при следующем открытии — первый раз это дольше обычного. История правок останется."))
        }
        .confirmationDialog(offer.map { L("Удалить «\($0.kind.title)» с диска (\(Self.size(removableSize(of: $0.kinds))))?") } ?? "",
                            isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }),
                            presenting: offer) { offer in
            Button(L("Удалить"), role: .destructive) { removeKinds(offer.kinds) }
            Button(L("Оставить"), role: .cancel) {}
        } message: { offer in
            Text(offerMessage(offer))
        }
    }

    // MARK: Обзор: схема и очистка

    private var overview: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                Button(action: rescan) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(L("Пересчитать"))
                    .disabled(scanning)
                Button(L("Показать в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([CacheStore.Locations.standard.caches])
                }
            }
            // Схема и ключ к ней — одной строкой, без разделителя между ними.
            VStack(alignment: .leading, spacing: 10) {
                CacheBar(parts: CacheKind.caches.map { ($0, totals[$0] ?? 0) }, scale: cacheTotal,
                         height: 14, highlighted: $highlighted, track: true)
                legend
            }
            .padding(.vertical, 4)
            Picker(L("Удалять кэши проектов, которые не открывали"), selection: $autoCleanDays) {
                Text(L("Никогда")).tag(0)
                Text(L("30 дней")).tag(30)
                Text(L("90 дней")).tag(90)
                Text(L("180 дней")).tag(180)
            }
            HStack {
                Button(L("Удалить устаревшие (\(Self.size(staleTotal)))")) { remove(stale.map { ($0, nil) }) }
                    .disabled(stale.isEmpty)
                    .help(L("Проекты, которых нет на диске или которые не открывали \(String(staleDays)) дней, и остатки прежних версий"))
                Button(L("Очистить все кэши…")) { confirmsAll = true }
                    .disabled(removableTotal == 0)
            }
        }
    }

    /// Ключ к схеме: цвет, вид и сколько он занимает — в порядке схемы.
    private var legend: some View {
        Flow(spacing: 16, lineSpacing: 6) {
            ForEach(CacheKind.caches.filter { (totals[$0] ?? 0) > 0 }) { kind in
                HStack(spacing: 6) {
                    Swatch(kind: kind, highlighted: highlighted)
                    Text(kind.title)
                        .lineLimit(1)
                    Text(Self.size(totals[kind] ?? 0))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .font(.system(size: 11))
                .contentShape(Rectangle())
                .onHover { inside in hover(kind, inside) }
                .help(kind.detail)
            }
        }
    }

    // MARK: Виды: что хранить

    private var kindSection: some View {
        Section {
            ForEach(kinds) { kindRow($0) }
        } header: {
            Text(L("Виды кэша"))
        } footer: {
            Text(L("Выключенный кэш Pilot не пишет и не читает: то же строится заново при каждом открытии проекта — дольше, но так же верно. Разбор файлов, сборки и архив jadx открытые проекты перестанут писать, когда их откроют заново."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Всё, что можно выключить, — даже пустое; остальное — если есть.
    private var kinds: [CacheKind] {
        CacheKind.caches.filter { $0.isSwitchable || (totals[$0] ?? 0) > 0 }
    }

    private func kindRow(_ kind: CacheKind) -> some View {
        let total = totals[kind] ?? 0
        let removable = removableSize(of: [kind])
        let stored = policy.stores(kind)
        let waitsFor = kind.storedWith.flatMap { policy.stores($0) ? nil : $0 }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Swatch(kind: kind, highlighted: highlighted)
                    Text(kind.title)
                        .foregroundStyle(stored ? .primary : .secondary)
                }
                Text(detail(kind))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
            Spacer(minLength: 12)
            Text(total > 0 ? Self.size(total) : "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            Button { removeKinds([kind]) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(removable == 0)
                .help(removable > 0 ? L("Удалить с диска: \(Self.size(removable))")
                      : total > 0 ? L("Проект открыт — закройте его, чтобы удалить") : L("Удалять нечего"))
            // Столбец переключателей держит место и там, где выключать нечего:
            // размеры и корзины стоят одна под другой.
            if kind.isSwitchable {
                Toggle(L("Хранить на диске"), isOn: Binding(get: { stored }, set: { setStores(kind, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(waitsFor != nil)
                    .help(waitsFor.map { L("Хранится вместе с видом «\($0.title)» — сначала включите его") }
                          ?? L("Хранить на диске"))
                    .frame(width: 40, alignment: .trailing)
            } else {
                Color.clear.frame(width: 40, height: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in hover(kind, inside) }
    }

    /// Старые версии Copilot — поимённо: какие именно лежат.
    private func detail(_ kind: CacheKind) -> String {
        let versions = caches.flatMap(\.parts).filter { $0.kind == .oldCopilot }.flatMap(\.urls)
            .map(\.lastPathComponent).sorted()
        guard kind == .oldCopilot, !versions.isEmpty else { return kind.detail }
        return L("Скачанные раньше: \(versions.joined(separator: ", ")); нужна только текущая.")
    }

    // MARK: Проекты

    private var projectSection: some View {
        Section {
            if projects.isEmpty {
                Text(scanning ? L("Считаю…") : L("Кэшей проектов нет")).foregroundStyle(.secondary)
            }
            ForEach(projects) { projectRow($0) }
        } header: {
            Text(L("Проекты"))
        } footer: {
            Text(L("Кэш ускоряет открытие проекта, поиск и навигацию. Удалённый кэш проект соберёт заново, когда его откроют. То, что открытый проект держит в работе, удаляется после его закрытия."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func projectRow(_ entry: CacheStore.Entry) -> some View {
        DisclosureGroup(isExpanded: expansion(entry.id)) {
            ForEach(entry.parts) { partRow($0, of: entry) }
        } label: {
            HStack(spacing: 10) {
                DisclosureLabel(isExpanded: expansion(entry.id)) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        title(entry)
                        Spacer(minLength: 8)
                        // Столбец полос: доля от самого большого проекта, так
                        // что проекты сравниваются между собой и по видам сразу.
                        CacheBar(parts: entry.parts.map { ($0.kind, $0.size) }, scale: largestProject,
                                 height: 6, highlighted: $highlighted, anchored: true)
                            .frame(width: 150)
                        Text(Self.size(entry.size))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .trailing)
                    }
                }
                Button { remove([(entry, nil)]) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(!CacheStore.canRemove(entry, policy: policy))
                    .help(removeHelp(entry))
            }
        }
    }

    private func partRow(_ part: CacheStore.Part, of entry: CacheStore.Entry) -> some View {
        let busy = CacheStore.isBusy(part, in: entry, policy: policy)
        return HStack(spacing: 10) {
            Swatch(kind: part.kind, highlighted: highlighted)
            Text(part.kind.title)
                .font(.system(size: 12))
            if part.kind.isSwitchable, !policy.stores(part.kind) {
                tag(L("не хранится"), .gray)
            }
            Spacer()
            Text(Self.size(part.size))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            Button { remove([(entry, Set([part.kind]))]) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(busy || part.size == 0)
                .help(busy ? L("Проект открыт — закройте его, чтобы удалить") : L("Удалить"))
        }
        // Размеры и корзины — под теми же у строки проекта.
        .padding(.leading, 28)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .onHover { inside in hover(part.kind, inside) }
    }

    private func removeHelp(_ entry: CacheStore.Entry) -> String {
        let free = CacheStore.removableSize(entry, policy: policy)
        if entry.isOpen, free > 0, free < entry.size {
            return L("Удалить то, что проект не держит в работе: \(Self.size(free))")
        }
        return entry.isOpen && free == 0 ? L("Проект открыт — закройте его, чтобы удалить") : L("Удалить")
    }

    // MARK: История правок

    private var historySection: some View {
        Section {
            ForEach(history) { entry in
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    title(entry)
                    Spacer(minLength: 8)
                    Text(Self.size(entry.size))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { confirmsHistory = entry } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(!CacheStore.canRemove(entry, policy: policy))
                        .help(entry.isOpen ? L("Проект открыт — закройте его, чтобы удалить") : L("Удалить"))
                }
            }
        } header: {
            Text(CacheKind.history.title)
        } footer: {
            Text(CacheKind.history.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Мелочи строк

    private func title(_ entry: CacheStore.Entry) -> some View {
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
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func subtitle(_ entry: CacheStore.Entry) -> String {
        var parts = [entry.projectPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("путь неизвестен")]
        if let date = entry.lastUsed {
            parts.append(L("изменён \(date.formatted(.relative(presentation: .named).locale(Self.locale)))"))
        }
        return parts.joined(separator: " · ")
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func hover(_ kind: CacheKind, _ inside: Bool) {
        if inside { highlighted = kind } else if highlighted == kind { highlighted = nil }
    }

    // MARK: Данные

    private var projects: [CacheStore.Entry] { entries.filter { $0.scope == .project } }
    private var history: [CacheStore.Entry] { entries.filter { $0.scope == .history } }
    private var caches: [CacheStore.Entry] { entries.filter { $0.scope != .history } }
    private var totals: [CacheKind: Int64] { CacheStore.totals(caches) }
    private var largestProject: Int64 { projects.map(\.size).max() ?? 0 }
    /// Срок из автоочистки, а без неё — месяц.
    private var staleDays: Int { autoCleanDays > 0 ? autoCleanDays : 30 }
    private var stale: [CacheStore.Entry] { CacheStore.stale(entries, olderThan: staleDays, policy: policy) }

    private var cacheTotal: Int64 { caches.reduce(0) { $0 + $1.size } }
    private var historyTotal: Int64 { history.reduce(0) { $0 + $1.size } }
    private var staleTotal: Int64 { stale.reduce(0) { $0 + CacheStore.removableSize($1, policy: policy) } }
    private var removableTotal: Int64 { caches.reduce(0) { $0 + CacheStore.removableSize($1, policy: policy) } }

    private func removableSize(of kinds: Set<CacheKind>, policy: CachePolicy? = nil) -> Int64 {
        caches.reduce(0) { $0 + CacheStore.removableSize($1, kinds: kinds, policy: policy ?? self.policy) }
    }

    /// Что из `kinds` держат открытые проекты.
    private func busySize(of kinds: Set<CacheKind>) -> Int64 {
        caches.reduce(0) { sum, entry in
            sum + entry.parts.filter { kinds.contains($0.kind) && CacheStore.isBusy($0, in: entry, policy: policy) }
                .reduce(0) { $0 + $1.size }
        }
    }

    /// Числа и даты — на языке интерфейса, а не системы: «3 дня назад»
    /// рядом с «изменён», а не «3 days ago».
    private static var locale: Locale {
        Locale(identifier: Localization.current == .ru ? "ru_RU" : "en_US")
    }

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    // MARK: Настройка

    private func setStores(_ kind: CacheKind, _ on: Bool) {
        var next = policy
        if on { next.switchedOff.remove(kind) } else { next.switchedOff.insert(kind) }
        // Выключили разбор — перестала храниться и компиляция.
        let stopped = Set(CacheKind.allCases.filter { policy.stores($0) && !next.stores($0) })
        if !isSample { CachePolicy.current = next }
        policy = next
        if !stopped.isEmpty, removableSize(of: stopped, policy: next) > 0 {
            offer = Offer(kind: kind, kinds: stopped)
        }
    }

    private func offerMessage(_ offer: Offer) -> String {
        var lines = [L("Pilot больше его не пишет. Оставленное пригодится, если кэш снова включить.")]
        if offer.kinds.count > 1 {
            let others = offer.kinds.subtracting([offer.kind]).map(\.title).sorted().joined(separator: ", ")
            lines.append(L("Вместе с ним перестаёт храниться «\(others)»."))
        }
        let busy = busySize(of: offer.kinds)
        if busy > 0 {
            lines.append(L("Ещё \(Self.size(busy)) держат открытые проекты — это можно будет удалить после их закрытия."))
        }
        if !offer.kind.appliesToOpenProjects, entries.contains(where: \.isOpen) {
            lines.append(L("Открытые проекты перестанут его писать, когда их откроют заново."))
        }
        return lines.joined(separator: " ")
    }

    // MARK: Скан и удаление

    /// Недавние — прямо из настроек, без отсева: путь проекта, которого
    /// больше нет, как раз и нужен, чтобы сказать «нет на диске».
    static var knownRoots: [URL] {
        (UserDefaults.standard.array(forKey: "pilot.recentRoots") as? [String] ?? []).map(URL.init(fileURLWithPath:))
    }

    static var openRoots: [URL] {
        ProjectWindows.shared.workspaces.compactMap(\.root)
    }

    private func rescan() {
        guard !scanning, !isSample else { return }
        scanning = true
        let known = Self.knownRoots, open = Self.openRoots, held = Rustlyn.foldersInUse()
        let copilot = CopilotInstaller.version
        Task.detached(priority: .userInitiated) {
            let found = CacheStore.scan(known: known, open: open, held: held, copilotVersion: copilot)
            await MainActor.run {
                entries = found
                scanning = false
            }
        }
    }

    /// Всё, что хранят `kinds`, — по всем строкам.
    private func removeKinds(_ kinds: Set<CacheKind>) {
        remove(caches.filter { $0.parts.contains { kinds.contains($0.kind) } }.map { ($0, kinds) })
    }

    /// Строки целиком (`nil`) или только части нужных видов. Занятое
    /// открытыми проектами остаётся — это решает `CacheStore.remove`.
    private func remove(_ targets: [(CacheStore.Entry, Set<CacheKind>?)]) {
        guard !isSample, !targets.isEmpty else { return }
        scanning = true
        let policy = self.policy
        Task.detached(priority: .userInitiated) {
            for (entry, kinds) in targets { CacheStore.remove(entry, kinds: kinds, policy: policy) }
            await MainActor.run {
                scanning = false
                rescan()
            }
        }
    }
}

// MARK: - Схема

/// Цвета видов на схеме. Порядок и сами цвета — из проверенной палитры:
/// соседние различимы и при протанопии и дейтеранопии, а у тёмной темы —
/// свои ступени, подобранные под тёмный фон, а не те же. Чего не выключить
/// (остатки, старые версии Copilot), — серое «прочее».
enum CacheColors {
    static func color(_ kind: CacheKind, _ scheme: ColorScheme) -> Color {
        let (light, dark): (UInt32, UInt32)
        switch kind {
        case .compilation: (light, dark) = (0x2A78D6, 0x3987E5)
        case .parsedFiles: (light, dark) = (0xEB6834, 0xD95926)
        case .declarations: (light, dark) = (0x1BAF7A, 0x199E70)
        case .fileList: (light, dark) = (0xEDA100, 0xC98500)
        case .unityAssets: (light, dark) = (0xE87BA4, 0xD55181)
        case .assemblyTypes: (light, dark) = (0x008300, 0x008300)
        case .decompiled: (light, dark) = (0x4A3AA7, 0x9085E9)
        case .jadx: (light, dark) = (0xE34948, 0xE66767)
        case .leftovers, .oldCopilot, .history: (light, dark) = (0x898781, 0x898781)
        }
        let hex = scheme == .dark ? dark : light
        return Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}

/// Подписи слева направо с переносом: ключ к схеме занимает столько строк,
/// сколько нужно подписям целиком, а не делит ширину на равные столбцы и
/// не обрезает длинные названия.
private struct Flow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// Цветной квадратик вида — ключ к схеме рядом с его названием.
private struct Swatch: View {
    let kind: CacheKind
    var highlighted: CacheKind?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(CacheColors.color(kind, scheme))
            .frame(width: 10, height: 10)
            .opacity(highlighted == nil || highlighted == kind ? 1 : 0.35)
    }
}

/// Полоса по видам: у каждого — отрезок своего цвета, длиной в его долю от
/// `scale`. Общая полоса — во всю ширину; полоса проекта — в долю от самого
/// большого проекта, так что и проекты видно рядом друг с другом. Между
/// отрезками — просвет цвета фона, а не обводка.
private struct CacheBar: View {
    let parts: [(kind: CacheKind, size: Int64)]
    let scale: Int64
    let height: CGFloat
    @Binding var highlighted: CacheKind?
    /// Подложка во всю ширину, пока кэшей нет, — чтобы полоса не пропадала.
    /// У полос проектов её нет: там ширина — сравнение, а не «сколько из скольких».
    var track = false
    /// Полоса растёт от общей левой кромки (столбец проектов): у начала углы
    /// прямые, скруглён только конец — длины сравниваются от одной черты.
    var anchored = false
    @Environment(\.colorScheme) private var scheme

    private let gap: CGFloat = 2

    private var shape: AnyShape {
        let radius = min(4, height / 2)
        return anchored
            ? AnyShape(UnevenRoundedRectangle(bottomTrailingRadius: radius, topTrailingRadius: radius))
            : AnyShape(RoundedRectangle(cornerRadius: radius))
    }

    private struct Piece: Identifiable {
        let kind: CacheKind
        let size: Int64
        let width: CGFloat
        var id: CacheKind { kind }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: gap) {
                ForEach(pieces(width: geometry.size.width)) { piece in
                    Rectangle()
                        .fill(CacheColors.color(piece.kind, scheme))
                        .opacity(highlighted == nil || highlighted == piece.kind ? 1 : 0.3)
                        .frame(width: piece.width)
                        .help(piece.kind.title + " — " + CacheSettingsView.size(piece.size))
                        .onHover { inside in
                            if inside { highlighted = piece.kind } else if highlighted == piece.kind { highlighted = nil }
                        }
                }
            }
            .clipShape(shape)
        }
        .frame(height: height)
        .background {
            // Только у пустой: у полной просветы между отрезками — цвета фона.
            if track, parts.allSatisfy({ $0.size == 0 }) {
                shape.fill(Color.secondary.opacity(0.12))
            }
        }
    }

    private func pieces(width: CGFloat) -> [Piece] {
        let shown = parts.filter { $0.size > 0 }
        let widths = Self.widths(shown.map(\.size), scale: scale, width: width, gap: gap)
        return zip(shown, widths).compactMap { part, width in
            width > 0 ? Piece(kind: part.kind, size: part.size, width: width) : nil
        }
    }

    /// Ширины отрезков: доля от `scale` на всю ширину, за вычетом просветов.
    /// Отрезок уже точки не рисуется — просветы вокруг него заметнее его
    /// самого; короткая полоса (маленький проект) — одним отрезком самого
    /// большого вида, но хотя бы штрихом.
    static func widths(_ sizes: [Int64], scale: Int64, width: CGFloat, gap: CGFloat) -> [CGFloat] {
        let total = sizes.reduce(0, +)
        guard total > 0, scale > 0, width > 0 else { return sizes.map { _ in 0 } }
        let span = max(3, width * CGFloat(Double(min(total, scale)) / Double(scale)))
        if span < 12, let largest = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) {
            return sizes.indices.map { $0 == largest ? span : 0 }
        }
        let kept = sizes.map { CGFloat($0) / CGFloat(total) * span >= 1 }
        let keptTotal = zip(sizes, kept).reduce(Int64(0)) { $0 + ($1.1 ? $1.0 : 0) }
        let room = span - gap * CGFloat(max(kept.filter { $0 }.count - 1, 0))
        return zip(sizes, kept).map { size, keep in
            keep ? max(1, room * CGFloat(size) / CGFloat(keptTotal)) : 0
        }
    }
}
