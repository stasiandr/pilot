import AppKit

/// Конфиги по правилам расширения (см. `ConfigCatalog`): из кода — в JSON
/// конфига, из конфига — к алиасу в коде и к тем, кто его берёт.
extension Workspace {

    /// Куда ведёт то, что под курсором.
    enum ConfigLink: Equatable {
        /// Файлы конфига: ⌘B по алиасу в коде или по пути в реестре. У
        /// дерева и у префикса их несколько.
        case files([URL], alias: String)
        /// Алиас в реестре — к его объявлению в коде.
        case declaration(alias: String)
    }

    var configCatalog: ConfigCatalog? {
        guard let root else { return nil }
        return configCatalogs.catalog(root: root, rules: rules.configs)
    }

    /// ⌘B: `true` — под курсором алиас конфига, и переход сделан.
    func goToConfig(at offset: Int, in document: LoadedDocument) -> Bool {
        guard let catalog = configCatalog, document.revision == nil, document.decompiled == nil,
              let link = configLink(at: offset, in: document, catalog: catalog) else { return false }
        switch link {
        case .files(let urls, let alias):
            NSLog("[configs] ⌘B %@ → %@", alias,
                  urls.count == 1 ? (catalog.path(of: urls[0]) ?? urls[0].path) : "\(urls.count) файлов")
            openConfigFiles(urls, alias: alias, catalog: catalog)
        case .declaration(let alias):
            goToAliasDeclaration(alias)
        }
        return true
    }

    func configLink(at offset: Int, in document: LoadedDocument, catalog: ConfigCatalog) -> ConfigLink? {
        let model = document.model
        guard model.lineCount > 0 else { return nil }
        let line = model.lineRange(model.line(containing: offset))

        // Строка: сам алиас (`"Jobs"` в классе алиасов) или, в реестре,
        // путь либо алиас записи.
        if let literal = ConfigCatalog.stringLiteral(in: model.units, line: line, at: offset) {
            if catalog.isMeta(document.url) {
                if let alias = catalog.aliasByPath[literal.text] {
                    return .files([catalog.directory.appendingPathComponent(literal.text)], alias: alias)
                }
                return catalog.knows(literal.text) ? .declaration(alias: literal.text) : nil
            }
            let urls = catalog.files(forAlias: literal.text)
            return urls.isEmpty ? nil : .files(urls, alias: literal.text)
        }

        guard document.url.pathExtension == "cs",
              let symbol = Occurrences.symbol(in: model, at: offset) else { return nil }
        let text = String(decoding: model.units[line], as: UTF16.self)
        guard let alias = aliasConstant(symbol.text, at: offset, currentLine: text, in: document, catalog: catalog)
        else { return nil }
        return .files(catalog.files(forAlias: alias), alias: alias)
    }

    /// Один файл — открываем, несколько (дерево, префикс) — списком.
    func openConfigFiles(_ urls: [URL], alias: String, catalog: ConfigCatalog) {
        guard let first = urls.first else { return }
        if urls.count == 1 {
            navigate(to: NavTarget(url: first, range: nil))
            return
        }
        showDeclarations(urls.map { url in
            FoundDeclaration(target: NavTarget(url: url, range: nil), name: url.lastPathComponent, kind: .field,
                             container: alias,
                             path: catalog.path(of: url).map { "\(catalog.rules.folder)/\($0)" } ?? url.path)
        })
    }

    /// Значение константы-алиаса с этим именем, если оно — алиас конфига.
    ///
    /// Объявление ищется по индексу имён, а не компилятором: константа с
    /// таким именем обычно одна, её строка читается с диска, и ⌘B по
    /// обычному имени в проекте с конфигами почти ничего не стоит. Несколько
    /// одноимённых констант с разными алиасами — решает навигатор.
    private func aliasConstant(_ name: String, at offset: Int, currentLine: String,
                               in document: LoadedDocument, catalog: ConfigCatalog) -> String? {
        // Курсор на самом объявлении.
        if let found = ConfigCatalog.constant(in: currentLine, named: name),
           catalog.knows(found.value) {
            return found.value
        }
        guard let symbols = symbolIndex, let ids = symbols.byName[name] else { return nil }
        var values: [(target: NavTarget, alias: String)] = []
        for id in ids.prefix(32) where symbols[id].kind == .field || symbols[id].kind == .property {
            let target = symbols.target(id)
            guard let line = target.range?.start.line,
                  let found = ConfigCatalog.constant(in: lineText(line, of: target.url), named: name),
                  catalog.knows(found.value) else { continue }
            values.append((target, found.value))
        }
        let distinct = Set(values.map(\.alias))
        if distinct.count <= 1 { return distinct.first }

        let answer = LocalNavigator(index: symbolIndex, document: navDocument(document)).definition(at: offset)
        guard answer.isExact, let first = answer.declarations.first else { return nil }
        return values.first {
            $0.target.url == first.target.url && $0.target.range?.start.line == first.target.range?.start.line
        }?.alias
    }

    /// Строка файла: из открытой вкладки, если он открыт, иначе с диска.
    func lineText(_ line: Int, of url: URL) -> String {
        if let tab = tab(for: url, revision: nil) {
            let model = tab.document.model
            guard line < model.lineCount else { return "" }
            return String(decoding: model.units[model.lineRange(line)], as: UTF16.self)
        }
        guard let text = SymbolIndex.readSource(url) else { return "" }
        var number = 0
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if number == line { return String(piece) }
            number += 1
        }
        return ""
    }

    // MARK: - Из конфига в код

    /// Объявление алиаса в коде: `const string Jobs = "Jobs"`. Ищется по
    /// тексту `"Jobs` в .cs-файлах — значение константы в индексе имён не
    /// хранится. Нет константы на весь алиас — годится префикс, к которому
    /// код дописывает остальное: `Quests.easy` берут как
    /// `QUESTS_DIRECTORY + "easy"`.
    func aliasDeclarations(_ alias: String, completion: @escaping ([FoundDeclaration]) -> Void) {
        guard let root, let files = projectFiles, let configRules = rules.configs else { completion([]); return }
        let paths = files.display.filter { $0.hasSuffix(".cs") }
        let head = alias.split(separator: ".", maxSplits: 1).first.map(String.init) ?? alias
        DispatchQueue.global(qos: .userInitiated).async {
            var options = ContentSearch.Options()
            options.limit = 400
            let hits = ContentSearch.search("\"\(head)", root: root, paths: paths, options: options,
                                            shouldStop: { false })
            var found: [FoundDeclaration] = []
            var values: [String] = []
            var lines: [Int32: [Substring]] = [:]
            for hit in hits {
                let path = paths[Int(hit.file)]
                let url = root.appendingPathComponent(path)
                if lines[hit.file] == nil {
                    lines[hit.file] = (SymbolIndex.readSource(url) ?? "")
                        .split(separator: "\n", omittingEmptySubsequences: false)
                }
                guard let all = lines[hit.file], hit.line < all.count else { continue }
                let text = String(all[hit.line])
                guard let constant = ConfigCatalog.constant(in: text),
                      constant.value == alias || (constant.value.hasSuffix(".") && alias.hasPrefix(constant.value))
                else { continue }
                let column = constant.column
                let target = NavTarget(url: url, range: LSPRange(
                    start: LSPPosition(line: hit.line, character: column),
                    end: LSPPosition(line: hit.line, character: column + constant.name.utf16.count)))
                found.append(FoundDeclaration(target: target, name: constant.name, kind: .field,
                                              container: ConfigCatalog.modelType(in: text, attribute: configRules.modelAttribute),
                                              path: path))
                values.append(constant.value)
            }
            // Точное совпадение важнее префикса; из префиксов — самый длинный.
            let best = values.max { $0.count < $1.count }
            let chosen = zip(found, values).filter { $0.1 == best }.map(\.0)
            DispatchQueue.main.async { completion(chosen) }
        }
    }

    func goToAliasDeclaration(_ alias: String, thenFindUsages: Bool = false) {
        aliasDeclarations(alias) { [weak self] found in
            guard let self else { return }
            guard let first = found.first else {
                self.showNotice("Алиас «\(alias)» в коде не объявлен")
                return
            }
            guard found.count == 1 else {
                self.showDeclarations(found)
                return
            }
            self.navigate(to: first.target) { [weak self] in
                guard thenFindUsages, let self, let document = self.document,
                      document.url.standardizedFileURL == first.target.url.standardizedFileURL,
                      let range = first.target.range else { return }
                self.findReferences(at: document.model.offset(at: range.start))
            }
        }
    }

    /// Модель конфига — класс из атрибута модели (`[Attr(typeof(…))]`) у алиаса.
    func goToConfigModel(_ alias: String) {
        aliasDeclarations(alias) { [weak self] found in
            guard let self else { return }
            let names = found.compactMap(\.container).flatMap(ConfigCatalog.typeNames(in:))
            let types = names.lazy.compactMap { name -> [FoundDeclaration]? in
                guard let symbols = self.symbolIndex, let ids = symbols.typesByName[name], !ids.isEmpty else { return nil }
                return ids.map { id in
                    let symbol = symbols[id]
                    return FoundDeclaration(target: symbols.target(id), name: symbol.name, kind: symbol.kind,
                                            container: symbol.container, path: symbols.relPath(id))
                }
            }.first
            guard let types, let first = types.first else {
                self.showNotice("Модель конфига «\(alias)» не найдена")
                return
            }
            if types.count == 1 { self.navigate(to: first.target) } else { self.showDeclarations(types) }
        }
    }

    // MARK: - ⌘.

    /// Раздел меню у курсора: алиас под курсором или конфиг, открытый в редакторе.
    func configActions(at offset: Int, in document: LoadedDocument) -> ContextActionGroup? {
        guard let catalog = configCatalog else { return nil }
        if let link = configLink(at: offset, in: document, catalog: catalog) {
            switch link {
            case .files(let urls, let alias):
                let title = urls.count == 1
                    ? "Открыть конфиг \(catalog.path(of: urls[0]) ?? urls[0].lastPathComponent)"
                    : "Файлы конфига (\(urls.count))…"
                var actions = [
                    ContextAction(title: title, icon: "doc.text",
                                  shortcut: KeymapStore.shared.menuShortcut(.goToDefinition)) { [weak self] in
                        self?.openConfigFiles(urls, alias: alias, catalog: catalog)
                    },
                ]
                if !catalog.isMeta(document.url) {
                    actions.append(ContextAction(title: "Модель конфига", icon: "cube") { [weak self] in
                        self?.goToConfigModel(alias)
                    })
                }
                return ContextActionGroup(title: "Конфиг \(alias)", actions: actions)
            case .declaration(let alias):
                return ContextActionGroup(title: "Конфиг \(alias)", actions: aliasActions(alias, catalog: catalog))
            }
        }
        guard let alias = catalog.alias(of: document.url) else { return nil }
        return ContextActionGroup(title: "Конфиг \(alias)", actions: aliasActions(alias, catalog: catalog, inConfig: true))
    }

    private func aliasActions(_ alias: String, catalog: ConfigCatalog, inConfig: Bool = false) -> [ContextAction] {
        var actions = [
            ContextAction(title: "Где используется конфиг", icon: "arrow.triangle.branch") { [weak self] in
                self?.goToAliasDeclaration(alias, thenFindUsages: true)
            },
            ContextAction(title: "Алиас в коде", icon: "arrow.forward.circle") { [weak self] in
                self?.goToAliasDeclaration(alias)
            },
            ContextAction(title: "Модель конфига", icon: "cube") { [weak self] in
                self?.goToConfigModel(alias)
            },
        ]
        if inConfig, let document {
            if let folder = Self.folderConfig(of: document.url, catalog: catalog) {
                actions.append(ContextAction(title: "Сборка папки: \(catalog.rules.folderConfig)",
                                             icon: "list.bullet.rectangle") { [weak self] in
                    self?.navigate(to: NavTarget(url: folder, range: nil))
                })
            } else {
                actions.append(ContextAction(title: "Запись в \(catalog.rules.registry)", icon: "list.bullet.rectangle") { [weak self] in
                    self?.goToMetaEntry(alias, catalog: catalog)
                })
            }
        }
        return actions
    }

    /// `folder.json` дерева, в которое входит файл: рядом (`by_files`) или
    /// папкой выше (`by_folders`). Файл из реестра — не из дерева.
    private static func folderConfig(of url: URL, catalog: ConfigCatalog) -> URL? {
        guard let path = catalog.path(of: url), catalog.sources.values.contains(where: { $0.contains(path) }),
              !(SymbolIndex.readSource(catalog.metaURL) ?? "").contains("\"\(path)\"") else { return nil }
        let folder = url.deletingLastPathComponent()
        for candidate in [folder, folder.deletingLastPathComponent()] {
            let config = candidate.appendingPathComponent(catalog.rules.folderConfig)
            if FileManager.default.fileExists(atPath: config.path) { return config }
        }
        return nil
    }

    private func goToMetaEntry(_ alias: String, catalog: ConfigCatalog) {
        let needle = "\"\(alias)\""
        var number = 0
        var found: Int?
        for line in (SymbolIndex.readSource(catalog.metaURL) ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains(needle) { found = number; break }
            number += 1
        }
        let range = found.map { LSPRange(start: LSPPosition(line: $0, character: 0), end: LSPPosition(line: $0, character: 0)) }
        navigate(to: NavTarget(url: catalog.metaURL, range: range))
    }
}
