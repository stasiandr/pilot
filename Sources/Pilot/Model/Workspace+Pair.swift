import SwiftUI
import AppKit

/// Открытый файл из зеркальных папок (правила расширения) и его копия во
/// второй половине пары.
struct MirrorState: Equatable {
    var copy: URL
    var label: String
    /// Копии нет вовсе.
    var missing: Bool
}

// MARK: - Пара проектов
//
// Два проекта, у которых часть кода и договорённостей продублирована и
// меняется вместе. Здесь всё, что ходит между половинами: двойник под
// курсором, поиск и ⌘R по обеим — и, если их описывает расширение проекта,
// сверка сетевых структур, конфиги и зеркала. Сама пара — ProjectPair, куда
// что открыть — ProjectWindows, правила — ProjectRules.

extension Workspace {

    // MARK: Кто в паре

    var partnerLabel: String? { partner.map(ProjectPair.label(of:)) }

    /// Окно второй половины, если оно открыто.
    var partnerWorkspace: Workspace? {
        guard let partner else { return nil }
        return ProjectWindows.shared.workspaces.first { $0.root?.path == partner.path }
    }

    private static var pairLinks: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: ProjectPair.linksKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: ProjectPair.linksKey) }
    }

    /// Пару узнаём при открытии проекта: по связи из меню или по соседней
    /// папке. Вызывается из `refreshExtensions` — с окончаниями из расширения.
    func refreshPartner(extra: [PairRules.Suffixes]) {
        guard let root, !ArchiveLayout.isArchiveFile(root) else {
            partner = nil
            return
        }
        let found = ProjectPair.partner(of: root, links: Self.pairLinks, extra: extra) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        if partner != found { partner = found }
    }

    /// ⌃⌘P — окно второй половины: вперёд, если открыто, иначе новое.
    func openPartner() {
        guard let partner else {
            showNotice("У проекта нет пары — «Пара → Связать с проектом…»")
            return
        }
        ProjectWindows.shared.openAsTab(root: partner, in: self)
    }

    /// Пара, которую не узнать по именам папок, — руками.
    func linkPartner() {
        guard let root else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Связать"
        panel.message = "Второй проект пары для «\(root.lastPathComponent)»: клиент для сервера или сервер для клиента"
        panel.directoryURL = root.deletingLastPathComponent()
        guard panel.runModal() == .OK, let other = panel.url, other.path != root.path else { return }
        Self.pairLinks = ProjectPair.linking(root, other, in: Self.pairLinks)
        ProjectWindows.shared.workspaces.forEach { $0.refreshExtensions() }
        showNotice("Пара: \(root.lastPathComponent) ↔ \(other.lastPathComponent)")
    }

    func unlinkPartner() {
        guard let root else { return }
        Self.pairLinks = ProjectPair.unlinking(root, partner: partner, in: Self.pairLinks)
        ProjectWindows.shared.workspaces.forEach { $0.refreshExtensions() }
        mirror = nil
        showNotice("У «\(root.lastPathComponent)» больше нет пары")
    }

    // MARK: Индексы второй половины

    private static var pairCache: [String: (index: PairIndex, loaded: Date)] = [:]

    /// Живые индексы из окна второй половины или её кэш с диска. nil —
    /// пары нет.
    func partnerIndex() async -> PairIndex? {
        guard let partner else { return nil }
        let label = ProjectPair.label(of: partner)
        if let live = partnerWorkspace, live.symbolIndex != nil || live.fileIndex != nil {
            return PairIndex(root: partner, label: label, symbols: live.symbolIndex, files: live.fileIndex)
        }
        // Кэш с диска читается десятки миллисекунд — не на каждую букву поиска.
        if let cached = Self.pairCache[partner.path], Date().timeIntervalSince(cached.loaded) < 120 {
            return cached.index
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            PairIndex(root: partner, label: label,
                      symbols: IndexCache.loadSymbols(root: partner)?.index,
                      files: IndexCache.load(root: partner))
        }.value
        Self.pairCache[partner.path] = (loaded, Date())
        return loaded
    }

    /// Синхронно — то, что уже есть под рукой: окно второй половины или кэш.
    private var knownPartnerSymbols: SymbolIndex? {
        partnerWorkspace?.symbolIndex ?? partner.flatMap { Self.pairCache[$0.path]?.index.symbols }
    }

    private func noPartnerIndex(_ label: String) {
        showNotice("Индекса \(label) ещё нет — откройте его один раз (⌃⌘P)")
    }

    // MARK: Переход в окно второй половины

    /// Файл второй половины пары открывается в её окне: там её индекс,
    /// компиляция и вкладки. true — переход передан.
    func handOffToPartner(_ target: NavTarget) -> Bool {
        guard let partner, let root else { return false }
        let path = target.url.path
        guard path.hasPrefix(partner.path + "/") else { return false }
        // Вложенные корни (worktree внутри репозитория) — чей ближе.
        if path.hasPrefix(root.path + "/"), root.path.count >= partner.path.count { return false }
        isPaletteOpen = false
        let start = target.range?.start
        let request = OpenRequest(path: target.url, line: start.map { $0.line + 1 },
                                  column: start.map { $0.character + 1 }, project: partner)
        ProjectWindows.shared.open(request, from: nil)
        return true
    }

    // MARK: ⌃⌘T — двойник

    /// То, что во второй половине пары соответствует месту под курсором:
    /// тот же тип или член, модель и код конфига, копия зеркального файла.
    func goToCounterpart() {
        guard let partner, let label = partnerLabel else {
            showNotice("У проекта нет пары — «Пара → Связать с проектом…»")
            return
        }
        guard let document else {
            openPartner()
            return
        }
        let url = document.url
        let relative = relativePath(for: url)
        if rules.pair.isMirrored(relative) {
            openMirrorCopy()
            return
        }
        if url.pathExtension.lowercased() == "json", rules.configs != nil {
            showConfigLinks()
            return
        }
        if !Rustlyn.understands(url) {
            // Не код — тот же путь во второй половине, если он там есть.
            let copy = partner.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: copy.path) {
                navigate(to: NavTarget(url: copy, range: nil))
            } else {
                showNotice("В \(label) нет \(relative)")
            }
            return
        }
        // C#: строка с атрибутом ключа или alias конфига — это про конфиги.
        let line = currentLineText()
        if let configs = rules.configs,
           ConfigLinks.jsonProperty(in: line, attribute: configs.keyAttribute) != nil
            || ConfigLinks.alias(declaredIn: line) != nil {
            showConfigLinks()
            return
        }
        guard let question = twinQuestion(in: document) else {
            showNotice("Под курсором нет имени")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let pair = await self.partnerIndex(), let symbols = pair.symbols else {
                self.noPartnerIndex(label)
                return
            }
            let found = PairQueries.twins(of: question.name, container: question.container, in: symbols)
            if found.count == 1 {
                self.navigate(to: symbols.target(found[0]))
                return
            }
            guard !found.isEmpty else {
                self.showNotice("В \(label) нет «\(question.name)»")
                return
            }
            self.presentList(found.prefix(200).enumerated().map { position, id in
                let symbol = symbols[id]
                return PaletteItem(id: position, icon: Self.icon(for: symbol.kind, keyword: symbol.keyword),
                                   primary: symbol.name,
                                   secondary: [label, symbol.container, symbols.relPath(id)]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   trailing: symbol.keyword ?? symbol.kind.label,
                                   target: symbols.target(id))
            }, mode: .counterparts)
        }
    }

    /// Имя под курсором и тип, которому оно принадлежит. Без курсора на
    /// имени — объявление, в котором он стоит.
    private func twinQuestion(in document: LoadedDocument) -> (name: String, container: String?)? {
        let offset = caretOffset
        let outline = document.outline
        if let word = Occurrences.identifier(in: document.model, at: offset)?.text {
            // Курсор на самом объявлении — его контейнер известен точно.
            if let declared = outline.first(where: { $0.name == word && NSLocationInRange(offset, $0.range) }) {
                return (word, declared.kind == .type ? nil : declared.container)
            }
            if symbolIndex?.typesByName[word] != nil { return (word, nil) }
            // Член: если все одноимённые объявлены в одном типе, он и есть.
            let containers = Set((symbolIndex?.byName[word] ?? []).compactMap { symbolIndex?[$0].container })
            return (word, containers.count == 1 ? containers.first : nil)
        }
        guard let item = caret.outlineItem else { return nil }
        return (item.name, item.kind == .type ? nil : item.container)
    }

    private func currentLineText() -> String {
        guard let document else { return "" }
        let model = document.model
        let line = model.position(at: caretOffset).line
        guard line < model.lineCount else { return "" }
        return String(decoding: model.units[model.lineRange(line)], as: UTF16.self)
    }

    // MARK: Сверка датаграмм

    /// Все датаграммы обеих половин: какие разошлись на проводе, какие есть
    /// только с одной стороны, где разные имена полей.
    func auditDatagrams() {
        guard let label = partnerLabel, let root else {
            showNotice("У проекта нет пары — «Пара → Связать с проектом…»")
            return
        }
        guard let datagramRules = rules.datagrams else {
            showNotice("Сетевые структуры проекта описывает его расширение — здесь его нет")
            return
        }
        guard let own = symbolIndex else {
            showNotice("Собираю объявления проекта — сверка через несколько секунд")
            return
        }
        presentList([], mode: .contract, busy: true)
        let ownLabel = ProjectPair.label(of: root)
        Task { [weak self] in
            guard let self else { return }
            guard let pair = await self.partnerIndex(), let theirs = pair.symbols else {
                self.presentList([], mode: .contract)
                self.noPartnerIndex(label)
                return
            }
            let report = await Task.detached(priority: .userInitiated) {
                PairQueries.contractReport(own: own, theirs: theirs, label: label, ownLabel: ownLabel,
                                           rules: datagramRules)
            }.value
            guard self.paletteMode == .contract else { return }
            self.presentList(report, mode: .contract)
            let broken = report.filter { $0.trailing == "провод" }.count
            self.showNotice(broken == 0 ? "На проводе датаграммы \(ownLabel) и \(label) сходятся"
                                        : "Расходятся на проводе: \(broken)")
        }
    }

    // MARK: Замечания в открытом файле

    /// Датаграмма в открытом файле сверяется с двойником: расхождения — волной
    /// у поля или шага, как ошибки компилятора. Заодно — зеркальный ли файл.
    func schedulePairChecks(delay: Double) {
        let generation = pairCheckGeneration.bump()
        let counter = pairCheckGeneration
        refreshMirror()
        guard let buffer, partner != nil, let label = partnerLabel, Rustlyn.understands(buffer.url),
              buffer.document.decompiled == nil else {
            clearPairDiagnostics()
            return
        }
        let id = ObjectIdentifier(buffer)
        let snapshot = buffer.model.snapshot()
        guard let datagramRules = rules.datagrams, snapshot.text.contains(datagramRules.interface) else {
            clearPairDiagnostics()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.2) * 1_000_000_000))
            guard let self, counter.isCurrent(generation) else { return }
            guard let pair = await self.partnerIndex(), let theirs = pair.symbols else { return }
            let found = await Task.detached(priority: .utility) {
                PairQueries.pairDiagnostics(text: snapshot.text, theirs: theirs, label: label, rules: datagramRules)
            }.value
            guard counter.isCurrent(generation), let current = self.buffer, ObjectIdentifier(current) == id,
                  current.model.version == snapshot.version else { return }
            self.pairDiagnostics = found
            self.pairDiagnosticsBuffer = id
            self.pairDiagnosticsChanged()
        }
    }

    private func clearPairDiagnostics() {
        guard pairDiagnosticsBuffer != nil else { return }
        pairDiagnostics = []
        pairDiagnosticsBuffer = nil
        pairDiagnosticsChanged()
    }

    // MARK: ⌘R через границу

    /// Использования имени во второй половине пары — по тексту, целым
    /// словом, в её C#. Для датаграммы — кто её шлёт и кто ловит.
    func findPartnerReferences(of word: String) {
        let generation = pairReferenceGeneration.bump()
        let counter = pairReferenceGeneration
        // Только имена типов: `Id` или `Write` нашлись бы в тысяче мест.
        guard partner != nil, let label = partnerLabel, let first = word.first, first.isUppercase,
              symbolIndex?.typesByName[word] != nil || knownPartnerSymbols?.typesByName[word] != nil else { return }
        let isDatagram = datagramNames(in: symbolIndex).contains(word)
        let datagramRules = rules.datagrams
        Task { [weak self] in
            guard let self, let pair = await self.partnerIndex(), let files = pair.files,
                  counter.isCurrent(generation) else { return }
            let isPairType = pair.symbols?.typesByName[word] != nil
            guard isPairType || isDatagram else { return }
            let paths = files.display.filter { $0.hasSuffix(".cs") }
            let found = await Task.detached(priority: .userInitiated) { () -> [PaletteItem] in
                var options = ContentSearch.Options()
                options.limit = 500
                let hits = ContentSearch.search(word, root: pair.root, paths: paths, options: options,
                                                shouldStop: { !counter.isCurrent(generation) })
                return hits.filter(\.wholeWord).map { hit in
                    let path = paths[Int(hit.file)]
                    let usage = datagramRules.flatMap { DatagramContract.usage(of: hit.text, type: word, rules: $0) }
                    let start = LSPPosition(line: hit.line, character: hit.column)
                    let end = LSPPosition(line: hit.line, character: hit.column + hit.length)
                    return PaletteItem(id: 0, icon: PairQueries.usageIcon(usage), primary: hit.text,
                                       secondary: "\(label) · \(path)",
                                       trailing: PairQueries.usageTrailing(usage, line: hit.line),
                                       target: NavTarget(url: pair.root.appendingPathComponent(path),
                                                         range: LSPRange(start: start, end: end)))
                }
            }.value
            guard counter.isCurrent(generation), self.paletteMode == .references else { return }
            self.pairReferenceItems = found
            // Свои могли уже прийти — дописываем к ним; иначе их допишет showReferences.
            let own = self.allReferences.filter { !($0.secondary?.hasPrefix(label + " · ") ?? false) }
            self.allReferences = self.renumbered(own + found)
            self.filterReferences()
        }
    }

    /// Свои использования датаграммы показаны — подписываем, какие шлют, а
    /// какие ловят: строки читаются с диска фоном.
    func ownReferencesShown(_ built: [PaletteItem]) {
        guard partner != nil, let document,
              let word = Occurrences.identifier(in: document.model, at: caretOffset)?.text,
              let datagramRules = rules.datagrams,
              datagramNames(in: symbolIndex).contains(word) else { return }
        let generation = pairReferenceGeneration.current
        let counter = pairReferenceGeneration
        Task { [weak self] in
            let roles = await Task.detached(priority: .userInitiated) { () -> [String: DatagramContract.Usage] in
                var lines: [URL: [Substring]] = [:]
                var result: [String: DatagramContract.Usage] = [:]
                for item in built {
                    guard let line = item.target.range?.start.line else { continue }
                    if lines[item.target.url] == nil {
                        let text = SymbolIndex.readSource(item.target.url) ?? ""
                        lines[item.target.url] = text.split(separator: "\n", omittingEmptySubsequences: false)
                    }
                    guard let all = lines[item.target.url], line < all.count,
                          let usage = DatagramContract.usage(of: String(all[line]), type: word,
                                                                      rules: datagramRules) else { continue }
                    result["\(item.target.url.path):\(line)"] = usage
                }
                return result
            }.value
            guard let self, counter.isCurrent(generation), self.paletteMode == .references, !roles.isEmpty else { return }
            self.allReferences = self.allReferences.map { item in
                guard let line = item.target.range?.start.line,
                      let usage = roles["\(item.target.url.path):\(line)"] else { return item }
                var item = item
                item.icon = PairQueries.usageIcon(usage)
                item.trailing = PairQueries.usageTrailing(usage, line: line)
                return item
            }
            self.filterReferences()
        }
    }

    private func datagramNames(in index: SymbolIndex?) -> Set<String> {
        guard let index, let datagramRules = rules.datagrams else { return [] }
        return Set(PairQueries.datagrams(in: index, rules: datagramRules).keys)
    }

    // MARK: ⇧F6 через границу

    struct PartnerRename {
        /// Флажок «и там тоже», если второе переименование возможно сейчас.
        var checkbox: String?
        /// Что сказать в окне переименования.
        var note: String
    }

    /// Имя есть и во второй половине: переименовать и там — или хотя бы
    /// предупредить, что протокол разойдётся.
    func partnerRenameOption(for name: String) -> PartnerRename? {
        guard let label = partnerLabel, let theirs = knownPartnerSymbols else { return nil }
        let twins = theirs.typesByName[name] ?? []
        guard !twins.isEmpty else { return nil }
        let isDatagram = rules.datagrams.map { PairQueries.datagrams(in: theirs, rules: $0)[name] != nil } ?? false
        let why = isDatagram
            ? "«\(name)» — датаграмма: имя — её id на проводе, и без \(label) протокол разойдётся."
            : "В \(label) тоже есть тип «\(name)»."
        if let live = partnerWorkspace, live.compiler.isReady {
            return PartnerRename(checkbox: "И в \(label) — там его переименует компилятор \(label)", note: why)
        }
        return PartnerRename(checkbox: nil,
                             note: why + " Откройте \(label) (⌃⌘P) и дождитесь компиляции, чтобы переименовать и там.")
    }

    /// Второе переименование — компилятором второй половины, по его ссылкам.
    func renameInPartner(old: String, new: String) {
        guard let live = partnerWorkspace, let symbols = live.symbolIndex, let rustlyn = live.rustlyn,
              let id = symbols.typesByName[old]?.first else { return }
        let target = symbols.target(id)
        guard let start = target.range?.start else { return }
        let label = ProjectPair.label(of: live.root ?? target.url)
        live.referenceQueue.async {
            guard let document = try? LoadedDocument.load(url: target.url) else { return }
            let offset = document.model.offset(at: start)
            let result = rustlyn.rename(target.url, offset: offset, to: new, text: nil, options: [.file])
            Task { @MainActor in
                guard let result, result.refused == nil, !result.edits.isEmpty else {
                    live.showNotice("\(label): «\(old)» не переименован — " + (result?.refused ?? "компилятор не нашёл его использований"))
                    return
                }
                live.applyRename(result, old: old, new: new)
            }
        }
    }

    // MARK: Конфиги ↔ код

    /// JSON конфига — его alias, модель и код, который его читает, в обеих
    /// половинах; ключ под курсором — поле модели. Из C# — наоборот: поле с
    /// атрибутом ключа или alias — к JSON. Всё по правилам расширения.
    func showConfigLinks() {
        guard let document, let root, let configRules = rules.configs else { return }
        let url = document.url
        let text = document.model.text
        let offset = caretOffset
        let line = currentLineText()
        presentList([], mode: .counterparts, busy: true)
        Task { [weak self] in
            guard let self else { return }
            let pair = await self.partnerIndex()
            let sides = [PairIndex(root: root, label: ProjectPair.label(of: root), symbols: self.symbolIndex,
                                   files: self.fileIndex)] + (pair.map { [$0] } ?? [])
            let found = await Task.detached(priority: .userInitiated) {
                PairQueries.configLinks(file: url, text: text, offset: offset, line: line, sides: sides,
                                        rules: configRules)
            }.value
            guard self.paletteMode == .counterparts else { return }
            self.presentList(self.renumbered(found), mode: .counterparts)
        }
    }

    // MARK: Зеркала

    /// Открытый файл из зеркальных папок: есть ли его копия во второй
    /// половине и такая ли она. Сравнивается текст вкладки — с правками.
    func refreshMirror() {
        guard let buffer, let partner, let label = partnerLabel, let root,
              buffer.url.path.hasPrefix(root.path + "/") else {
            if mirror != nil { mirror = nil }
            return
        }
        let relative = relativePath(for: buffer.url)
        guard rules.pair.isMirrored(relative) else {
            if mirror != nil { mirror = nil }
            return
        }
        let copy = partner.appendingPathComponent(relative)
        let text = buffer.model.text
        let id = ObjectIdentifier(buffer)
        Task { [weak self] in
            let state = await Task.detached(priority: .utility) { () -> MirrorState? in
                guard let other = try? String(contentsOf: copy, encoding: .utf8) else {
                    return MirrorState(copy: copy, label: label, missing: true)
                }
                return other == text ? nil : MirrorState(copy: copy, label: label, missing: false)
            }.value
            guard let self, let current = self.buffer, ObjectIdentifier(current) == id else { return }
            if self.mirror != state { self.mirror = state }
        }
    }

    func openMirrorCopy() {
        guard let document, let partner else { return }
        let copy = partner.appendingPathComponent(relativePath(for: document.url))
        guard FileManager.default.fileExists(atPath: copy.path) else {
            showNotice("В \(partnerLabel ?? "паре") нет копии этого файла")
            return
        }
        navigate(to: NavTarget(url: copy, range: nil))
    }

    /// Эта версия — во вторую половину: так договорились держать зеркала.
    func copyToMirror() {
        guard let buffer, let mirror else { return }
        let alert = NSAlert()
        alert.messageText = mirror.missing
            ? "Создать \(buffer.url.lastPathComponent) в \(mirror.label)?"
            : "Заменить копию в \(mirror.label) этой версией?"
        alert.informativeText = (mirror.copy.path as NSString).abbreviatingWithTildeInPath
            + (buffer.isDirty ? "\n\nНесохранённые правки попадут в копию как есть." : "")
        alert.addButton(withTitle: mirror.missing ? "Создать" : "Заменить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.createDirectory(at: mirror.copy.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(buffer.model.text.utf8).write(to: mirror.copy, options: .atomic)
            self.mirror = nil
            showNotice("Копия в \(mirror.label) обновлена")
        } catch {
            showNotice("Не удалось записать копию: \(error.localizedDescription)")
        }
    }

    /// Все зеркальные файлы, которые разошлись с копией или есть только с
    /// одной стороны.
    func showMirrorDrift() {
        guard let root, let label = partnerLabel, let partner else {
            showNotice("У проекта нет пары — «Пара → Связать с проектом…»")
            return
        }
        let mirrors = rules.pair
        guard !mirrors.mirrors.isEmpty else {
            showNotice("Зеркальных папок нет — их задаёт расширение проекта")
            return
        }
        let ownFiles = fileIndex?.display.filter(mirrors.isMirrored) ?? []
        let ownLabel = ProjectPair.label(of: root)
        presentList([], mode: .mirrors, busy: true)
        Task { [weak self] in
            guard let self else { return }
            let pair = await self.partnerIndex()
            let theirFiles = pair?.files?.display.filter(mirrors.isMirrored) ?? []
            let found = await Task.detached(priority: .userInitiated) { () -> [PaletteItem] in
                var result: [PaletteItem] = []
                let theirs = Set(theirFiles)
                for path in ownFiles {
                    let here = root.appendingPathComponent(path), there = partner.appendingPathComponent(path)
                    if !theirs.contains(path), !FileManager.default.fileExists(atPath: there.path) {
                        result.append(PaletteItem(id: 0, icon: "doc.badge.plus", primary: path,
                                                  secondary: "Только в \(ownLabel)", trailing: "нет в \(label)",
                                                  target: NavTarget(url: here, range: nil)))
                    } else if (try? Data(contentsOf: here)) != (try? Data(contentsOf: there)) {
                        result.append(PaletteItem(id: 0, icon: "doc.on.doc", primary: path,
                                                  secondary: "Отличается от копии в \(label)", trailing: "разошлись",
                                                  target: NavTarget(url: here, range: nil)))
                    }
                }
                for path in theirFiles.sorted() where !ownFiles.contains(path) {
                    result.append(PaletteItem(id: 0, icon: "doc.badge.ellipsis", primary: path,
                                              secondary: "Только в \(label)", trailing: "нет в \(ownLabel)",
                                              target: NavTarget(url: partner.appendingPathComponent(path), range: nil)))
                }
                return result
            }.value
            guard self.paletteMode == .mirrors else { return }
            self.presentList(self.renumbered(found), mode: .mirrors)
        }
    }
}
