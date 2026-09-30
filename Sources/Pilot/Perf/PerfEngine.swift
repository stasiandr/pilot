import Foundation

/// Замеры без окна — `PILOT_PERF=engine:<группа>`, их запускает `bin/pilot-perf`.
///
/// То же, из чего складывается работа окна, но по отдельности: в окне
/// индексы, компиляция и поиск идут разом, и регрессия одного тонет в
/// сумме. Здесь каждое дело мерится одно, на кэшах проекта из
/// `PILOT_CACHES`:
///
/// * `index` — кэш списка файлов, обход проекта, дерево, объявления, типы;
/// * `search` — индексы ⌘P по префиксам набираемого слова и поиск по тексту;
/// * `rustlyn` — компиляция из кэша, переиндексация и компиляция без
///   изменений, подсветка, структура, диагностика файла, дополнение,
///   переход, ссылки и компиляция после правки (без записи на диск).
///
/// Граф значения мерит сам `--value-graph` (HeadlessGraph), когда задан
/// `PILOT_PERF_OUT`.
@MainActor
enum PerfEngine {
    static var group: String? {
        guard let mode = PerfConfig.mode, mode.hasPrefix("engine:") else { return nil }
        return String(mode.dropFirst("engine:".count))
    }

    static var isRequested: Bool { group != nil }

    static func run() -> Int32 {
        guard let group, let config = PerfConfig.load() else { return 2 }
        let root = config.root
        let unity = UnityProjectInfo.find(inWorkspace: root)
        let exclude: FileIndex.Exclusion? = unity.map { $0.excludedFromIndex }
        guard let files = IndexCache.load(root: root, exclude: exclude) else {
            PerfReport.log("нет кэша списка файлов \(root.path) — откройте проект в Pilot хоть раз")
            return 2
        }
        switch group {
        case "index": return index(config, files: files, exclude: exclude)
        case "search": return search(config, files: files)
        case "rustlyn": return rustlyn(config, files: files, symbols: unity?.preprocessorSymbols ?? [])
        default:
            PerfReport.log("нет такой группы: \(group)")
            return 2
        }
    }

    // MARK: - Замер

    /// `warmup` прогонов не в счёт (диск, кэши процессора), потом
    /// `repeats` в счёт; в отчёт — медиана.
    private static func measure(_ name: String, warmup: Int = 0, repeats: Int = 1,
                                into metrics: inout [String: Double], _ body: () -> Void) {
        for _ in 0..<warmup { body() }
        var results: [PerfSpan.Result] = []
        for _ in 0..<max(1, repeats) {
            let span = PerfSpan()
            body()
            results.append(span.finish())
        }
        metrics["\(name).ms"] = PerfReport.median(results.map(\.wallMs))
        metrics["\(name).minstr"] = PerfReport.median(results.map(\.instructions))
        metrics["\(name).cpu.ms"] = PerfReport.median(results.map(\.cpuMs))
    }

    // MARK: - Индексы

    private static func index(_ config: PerfConfig, files: FileIndex, exclude: FileIndex.Exclusion?) -> Int32 {
        let root = config.root
        var metrics: [String: Double] = [:]
        measure("index.load", warmup: 1, repeats: 3, into: &metrics) {
            _ = IndexCache.load(root: root, exclude: exclude)
        }
        var scanned = 0
        measure("index.scan", warmup: 1, repeats: 2, into: &metrics) {
            scanned = FileIndex.scan(root: root, exclude: exclude, shouldStop: { false }).count
        }
        measure("index.tree", warmup: 1, repeats: 3, into: &metrics) {
            _ = FileTree.build(paths: files.display)
        }
        var symbolCount = 0
        if let cached = IndexCache.loadSymbols(root: root) {
            measure("index.symbols.load", warmup: 1, repeats: 3, into: &metrics) {
                _ = IndexCache.loadSymbols(root: root)
            }
            if let builtAt = cached.builtAt {
                measure("index.symbols.changes", warmup: 1, repeats: 3, into: &metrics) {
                    _ = SymbolIndex.changes(from: cached.index, files: files.display, since: builtAt)
                }
            }
            measure("index.types", warmup: 1, repeats: 3, into: &metrics) {
                _ = TypeIndex.make(root: root, entries: cached.index.typeEntries())
            }
            symbolCount = cached.index.count
        }
        PerfReport.emit("engine.index", metrics, info: [
            "files": "\(files.count)", "scanned": "\(scanned)", "symbols": "\(symbolCount)",
        ])
        return 0
    }

    // MARK: - Поиск

    private static func search(_ config: PerfConfig, files: FileIndex) -> Int32 {
        let root = config.root
        // Как набирают в палитре: каждый префикс — свой запрос.
        let word = config.palette?.text ?? "Parking"
        let queries = config.queries ?? word.indices.map { String(word[...$0]) }
        var metrics: [String: Double] = [:]
        var found = 0
        measure("search.files", warmup: 1, repeats: 5, into: &metrics) {
            found = queries.reduce(0) { $0 + files.search($1, limit: 200, shouldStop: { false }).count }
        }
        var info = ["queries": "\(queries.count)", "files.found": "\(found)"]
        if let symbols = IndexCache.loadSymbols(root: root)?.index {
            measure("search.symbols", warmup: 1, repeats: 5, into: &metrics) {
                found = queries.reduce(0) { $0 + symbols.search($1, limit: 300, shouldStop: { false }).count }
            }
            info["symbols.found"] = "\(found)"
        }
        if let types = IndexCache.loadTypes(root: root) {
            measure("search.types", warmup: 1, repeats: 5, into: &metrics) {
                found = queries.reduce(0) { $0 + types.search($1, limit: 200, shouldStop: { false }).count }
            }
            info["types.found"] = "\(found)"
        }
        if let text = config.textQuery {
            // Тот же порядок и те же исключения, что у палитры.
            let paths = Workspace.TextSearchOrder(open: [], folder: nil, data: false).apply(to: files.display)
            measure("search.text", warmup: 1, repeats: 3, into: &metrics) {
                found = ContentSearch.search(text, root: root, paths: paths, shouldStop: { false }).count
            }
            info["text.found"] = "\(found)"
        }
        PerfReport.emit("engine.search", metrics, info: info)
        return 0
    }

    // MARK: - Компилятор

    private static func rustlyn(_ config: PerfConfig, files: FileIndex, symbols: [String]) -> Int32 {
        let root = config.root
        var metrics: [String: Double] = [:]
        var info: [String: String] = [:]
        var session: Rustlyn?
        measure("rustlyn.load", into: &metrics) {
            session = Rustlyn.start(root: root, symbols: symbols)
            if let loaded = session?.loadCompilation() { info["cached"] = "\(loaded.files) files" }
        }
        guard let rustlyn = session else {
            PerfReport.log("Rustlyn не поднялся для \(root.path)")
            return 2
        }
        let sources = Rustlyn.sources(among: files.display, root: root)
        measure("rustlyn.reindex", into: &metrics) {
            let report = rustlyn.reindex(paths: sources)
            info["reindex"] = "\(report.files) files, \(report.parsed) parsed"
        }
        measure("rustlyn.compile", into: &metrics) {
            let compiled = rustlyn.compile()
            info["compile"] = compiled.map { "\($0.files) files\($0.unchanged ? ", unchanged" : "")" } ?? "failed"
        }

        func place(_ place: PerfConfig.Place) -> (url: URL, text: String, offset: Int)? {
            let url = config.url(place.file)
            guard let text = SymbolIndex.readSource(url) else {
                PerfReport.log("не прочитать \(place.file)")
                return nil
            }
            let model = SyntaxModel(text: text, spec: nil)
            return (url, text, model.offset(at: LSPPosition(line: place.line - 1, character: place.column - 1)))
        }

        if let file = config.editor?.file, let text = SymbolIndex.readSource(config.url(file)) {
            let url = config.url(file)
            let lines = max(0, text.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 })
            measure("rustlyn.open", into: &metrics) { rustlyn.open(url) }
            measure("rustlyn.tokens", warmup: 1, repeats: 3, into: &metrics) {
                _ = rustlyn.tokens(url, lines: 0...lines)
            }
            measure("rustlyn.outline", warmup: 1, repeats: 3, into: &metrics) { _ = rustlyn.outline(url) }
            // Первая диагностика файла — с проверками по всему проекту, дальше — из памяти.
            measure("rustlyn.diagnostics", into: &metrics) {
                info["diagnostics"] = "\(rustlyn.diagnostics(url, text: nil)?.items.count ?? -1)"
            }
            measure("rustlyn.diagnostics.again", repeats: 3, into: &metrics) {
                _ = rustlyn.diagnostics(url, text: nil)
            }
        }
        if let completion = config.completion, let at = place(completion) {
            measure("rustlyn.completion", warmup: 1, repeats: 3, into: &metrics) {
                info["completion"] = "\(rustlyn.completions(at.url, offset: at.offset, text: nil)?.items.count ?? -1)"
            }
        }
        if let definition = config.definition, let at = place(definition) {
            measure("rustlyn.definition", warmup: 1, repeats: 3, into: &metrics) {
                info["definition"] = rustlyn.definition(at.url, offset: at.offset).targets.first?.name ?? "-"
            }
        }
        if let references = config.references, let at = place(references) {
            measure("rustlyn.references", warmup: 1, repeats: 3, into: &metrics) {
                info["references"] = "\(rustlyn.references(at.url, offset: at.offset).targets.count)"
            }
        }
        if let edit = config.edit, let at = place(edit) {
            // Правка — как сохранение, но без записи: Rustlyn получает текст
            // в руки и компилирует проект с ним.
            let inserted = config.editText ?? "int perfProbe = 1;\n"
            let edited = (at.text as NSString).replacingCharacters(in: NSRange(location: at.offset, length: 0),
                                                                   with: inserted)
            // Последний замер: обратно текст не возвращается — процесс сейчас
            // выйдет, а компиляция на диск не пишется.
            measure("rustlyn.edit", into: &metrics) {
                rustlyn.open(at.url, text: edited)
                let compiled = rustlyn.compile()
                info["edit"] = compiled.map { $0.unchanged ? "unchanged" : "\($0.milliseconds) ms" } ?? "failed"
            }
        }
        PerfReport.emit("engine.rustlyn", metrics, info: info)
        return 0
    }
}
