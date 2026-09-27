import Foundation

/// Сгенерированный код Unity: что генераторы исходников написали для типов
/// открытого файла (`UnityGenerators`, `UnityGeneratorRuns`).
extension Workspace {
    /// Показать в палитре, что генераторы написали для типов открытого файла.
    ///
    /// Показывается сразу то, что уже лежит на диске, — даже если с тех пор
    /// менялись исходники: тогда статус палитры говорит, от какого времени
    /// этот код, а обновление идёт следом и подменяет список на месте. Ждать
    /// приходится только первого прогона для сборки — у `Assembly-CSharp`
    /// это почти минута, и палитра всё это время говорит, над чем работает.
    func showGeneratedCode() {
        guard let project = unity.project else {
            showNotice(L("Сгенерированный код есть только у Unity-проекта"))
            return
        }
        guard let url = document?.url ?? requestedFile, url.pathExtension == "cs" else {
            showNotice(L("Сначала откройте файл C#"))
            return
        }
        let root = project.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            showNotice(L("Файл не из Unity-проекта"))
            return
        }
        let relPath = String(path.dropFirst(root.count + 1))
        let types = UnityGenerators.declaredTypes(in: buffer?.model.text ?? "")
        let fileName = url.lastPathComponent
        let id = generatorRuns.beginShowing(types: types)

        generatedStatus = L("Ищу сборку \(fileName)…")
        presentList([], mode: .generated, busy: true)

        let projectRoot = project.root
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let rsp = UnityGenerators.responseFile(for: relPath, project: projectRoot) else {
                let message = L("Unity ещё не компилировала \(fileName) — откройте проект в Unity")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.generatedFailed(id, message) }
                }
                return
            }
            let snapshot = UnityGenerators.snapshot(rsp: rsp, project: projectRoot)
            let files = snapshot.index.files(about: types)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.showGenerated(id, rsp: rsp, snapshot: snapshot, files: files) }
            }
        }
    }

    /// Проект сменился: прогоны прежнего — долой. Фон новому проекту не
    /// мешает индексу и Rustlyn: пока они работают, он ждёт.
    func generatedCodeProjectChanged() {
        generatorRuns.isBusy = { [weak self] in
            guard let self else { return true }
            if case .compiling = self.compiler { return true }
            return self.isIndexing || self.isTypeIndexing
        }
        generatorRuns.workedIn = { [weak self] in
            guard let self else { return [] }
            let open = [self.document?.url].compactMap { $0 } + self.tabs.map(\.url)
            return open.filter { $0.pathExtension == "cs" }
        }
        generatorRuns.workspaceChanged(to: unity.project)
    }

    // MARK: - Палитра

    private var paletteShowsGenerated: Bool { isPaletteOpen && paletteMode == .generated }

    private func showGenerated(_ id: Int, rsp: URL, snapshot: UnityGenerators.Snapshot, files: [String]) {
        guard var shown = generatorRuns.shown, shown.id == id, paletteShowsGenerated else { return }
        shown.rsp = rsp
        if snapshot.freshness != .missing {
            shown.snapshot = snapshot
            shown.files = files
        }
        generatorRuns.shown = shown
        let generated = Self.generatedTime(snapshot.generated)
        switch snapshot.freshness {
        case .fresh:
            presentGenerated(files, snapshot: snapshot,
                             status: L("Собрано в \(generated) — исходники с тех пор не менялись"), busy: false)
        case .stale:
            presentGenerated(files, snapshot: snapshot,
                             status: L("Собрано в \(generated), исходники с тех пор менялись — обновляю…"), busy: true)
            generatorRuns.request(rsp, priority: .refresh) { [weak self] outcome in self?.generatedRefreshed(id, outcome) }
        case .missing:
            generatedStatus = L("Генераторы работают над \(snapshot.assembly)…")
            presentList([], mode: .generated, busy: true)
            generatorRuns.request(rsp, priority: .waiting) { [weak self] outcome in self?.generatedRefreshed(id, outcome) }
        }
    }

    /// Прогон закончился: список — заново, из обновлённого вывода, выделение
    /// остаётся на том же файле. Не вышло — прежний список остаётся, а
    /// статус говорит, что он может быть устаревшим.
    private func generatedRefreshed(_ id: Int, _ outcome: UnityGeneratorRuns.Outcome) {
        guard let shown = generatorRuns.shown, shown.id == id, let rsp = shown.rsp,
              let root = unity.project?.root, paletteShowsGenerated else { return }
        switch outcome {
        case .failure(let failure):
            guard let shownSnapshot = shown.snapshot else {
                generatedFailed(id, failure.message)
                return
            }
            let generated = Self.generatedTime(shownSnapshot.generated)
            presentGenerated(shown.files, snapshot: shownSnapshot,
                             status: L("Собрано в \(generated) и может быть устаревшим: \(failure.message)"), busy: false)
        case .success:
            let types = shown.types
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let snapshot = UnityGenerators.snapshot(rsp: rsp, project: root)
                let files = snapshot.index.files(about: types)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, var current = self.generatorRuns.shown, current.id == id,
                              self.paletteShowsGenerated else { return }
                        current.snapshot = snapshot
                        current.files = files
                        self.generatorRuns.shown = current
                        // Исходники могли поменяться, пока шёл прогон: тогда и
                        // новый вывод уже не свежий — так и сказать, а обновить
                        // снова — следующим нажатием.
                        let generated = Self.generatedTime(snapshot.generated)
                        let status = snapshot.freshness == .fresh
                            ? L("Обновлено в \(generated)")
                            : L("Собрано в \(generated), исходники с тех пор менялись")
                        self.presentGenerated(files, snapshot: snapshot, status: status, busy: false)
                    }
                }
            }
        }
    }

    private func generatedFailed(_ id: Int, _ message: String) {
        guard generatorRuns.shown?.id == id, paletteShowsGenerated else { return }
        generatedStatus = ""
        isPaletteOpen = false
        showNotice(message)
    }

    /// Список файлов в палитру. Открыта она уже в этом режиме — выделение
    /// остаётся на том же файле, даже если строки над ним добавились или ушли.
    private func presentGenerated(_ files: [String], snapshot: UnityGenerators.Snapshot, status: String, busy: Bool) {
        let selected = paletteShowsGenerated && items.indices.contains(selection) ? items[selection].target.url : nil
        let folder = snapshot.folder
        let built = files.enumerated().map { position, path in
            let file = folder.appendingPathComponent(path)
            return PaletteItem(
                id: position,
                icon: "gearshape.2",
                primary: file.lastPathComponent,
                secondary: UnityGenerators.generatorName(of: file, in: folder),
                trailing: snapshot.assembly,
                target: NavTarget(url: file, range: nil))
        }
        let total = snapshot.index.entries.count
        if built.isEmpty {
            let nothing = total > 0
                ? L("Для типов этого файла генераторы ничего не написали (всего в \(snapshot.assembly): \(String(total)))")
                : L("Для типов этого файла генераторы ничего не написали")
            generatedStatus = nothing + "\n" + status
        } else {
            generatedStatus = status
        }
        presentList(built, mode: .generated, busy: busy)
        if let selected, let index = items.firstIndex(where: { $0.target.url == selected }) { selection = index }
    }

    /// Когда собран вывод: сегодня — только время, иначе и дата.
    private static func generatedTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Localization.current == .ru ? "ru_RU" : "en_US")
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
