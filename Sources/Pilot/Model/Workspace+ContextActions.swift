import AppKit

/// ⌘. — меню у курсора: всё, что можно сделать с символом, строкой и
/// файлом там, где стоит курсор. Каждый пункт — уже существующая команда
/// со своим сочетанием: меню подсказывает, что тут вообще доступно.
extension Workspace {

    func contextActions(at offset: Int) -> [ContextActionGroup] {
        guard let document else { return [] }
        caretMoved(to: offset)
        let model = document.model
        let line = model.line(containing: offset)
        let unityReference = unity.isReferenceFile(document)

        var groups: [ContextActionGroup] = []

        // Алиас конфига сервера: ⌘B ведёт в JSON, объявление константы —
        // отдельным пунктом ниже.
        let config = configActions(at: offset, in: document)
        if let config { groups.append(config) }

        // Сцены и префабы ссылаются GUID и fileID — это не идентификаторы,
        // но ⌘B по ним переходит к ассету.
        if unityReference {
            groups.append(ContextActionGroup(title: nil, actions: [
                ContextAction(title: L("Перейти по ссылке"), icon: "arrow.forward.circle",
                              shortcut: KeymapStore.shared.menuShortcut(.goToDefinition)) { [weak self] in
                    self?.goToDefinition(at: offset)
                },
            ]))
        } else if let symbol = Occurrences.symbol(in: model, at: offset) {
            groups.append(ContextActionGroup(title: symbol.text,
                                             actions: symbolActions(symbol.text, at: offset,
                                                                    definitionIsConfig: config != nil)))
        }

        if let conflict = MergeConflicts.conflict(atLine: line, in: conflicts) {
            groups.append(ContextActionGroup(title: L("Конфликт слияния"), actions: conflictActions(conflict)))
        }

        groups.append(ContextActionGroup(title: L("Строка \(line + 1)"), actions: lineActions(line)))
        groups.append(ContextActionGroup(title: document.url.lastPathComponent, actions: fileActions(document, line: line)))
        return groups.filter { !$0.actions.isEmpty }
    }

    private func symbolActions(_ name: String, at offset: Int, definitionIsConfig: Bool = false) -> [ContextAction] {
        var actions = [
            ContextAction(title: L("Перейти к объявлению"), icon: "arrow.forward.circle",
                          shortcut: definitionIsConfig ? nil : KeymapStore.shared.menuShortcut(.goToDefinition)) { [weak self] in
                self?.goToDefinition(at: offset, followConfigs: false)
            },
            ContextAction(title: L("Найти использования"), icon: "arrow.triangle.branch",
                          shortcut: KeymapStore.shared.menuShortcut(.findReferences)) { [weak self] in
                self?.findReferences(at: offset)
            },
        ]
        if let buffer, Rustlyn.understands(buffer.url) {
            actions.append(ContextAction(title: L("Граф значения"), icon: "point.3.connected.trianglepath.dotted",
                                         shortcut: KeymapStore.shared.menuShortcut(.valueGraph)) { [weak self] in
                self?.showValueGraph(at: offset)
            })
        }
        // Пункт появляется, только если реализации действительно есть: меню
        // у курсора показывает доступное, а не весь список команд.
        if let document, symbolIndex != nil,
           !LocalNavigator(index: symbolIndex, document: navDocument(document))
               .implementations(at: offset).declarations.isEmpty {
            actions.append(ContextAction(title: L("Перейти к реализациям"),
                                         icon: "point.3.connected.trianglepath.dotted",
                                         shortcut: KeymapStore.shared.menuShortcut(.implementations)) { [weak self] in
                self?.findImplementations(at: offset)
            })
        }
        // Подсветка вхождений приходит с задержкой — считаем сами.
        if let document, Occurrences.find(name, in: document.model).count > 1 {
            actions.append(ContextAction(title: L("Следующее вхождение"), icon: "chevron.down",
                                         shortcut: KeymapStore.shared.menuShortcut(.nextOccurrence)) { [weak self] in
                self?.jumpToOccurrence(1)
            })
            actions.append(ContextAction(title: L("Предыдущее вхождение"), icon: "chevron.up",
                                         shortcut: KeymapStore.shared.menuShortcut(.previousOccurrence)) { [weak self] in
                self?.jumpToOccurrence(-1)
            })
        }
        if root != nil {
            actions.append(ContextAction(title: L("Искать «\(name)» в проекте"), icon: "magnifyingglass") { [weak self] in
                self?.openSearch(.everything)
                self?.query = name
            })
        }
        return actions
    }

    private func conflictActions(_ conflict: MergeConflict) -> [ContextAction] {
        func label(_ title: String, _ side: String) -> String {
            side.isEmpty ? title : "\(title) — \(side)"
        }
        return [
            ContextAction(title: label(L("Принять текущее"), conflict.currentLabel), icon: "arrow.left.square",
                          shortcut: KeymapStore.shared.menuShortcut(.acceptCurrent)) { [weak self] in
                self?.acceptConflict(.current)
            },
            ContextAction(title: label(L("Принять входящее"), conflict.incomingLabel), icon: "arrow.right.square",
                          shortcut: KeymapStore.shared.menuShortcut(.acceptIncoming)) { [weak self] in
                self?.acceptConflict(.incoming)
            },
            ContextAction(title: L("Принять оба"), icon: "square.on.square") { [weak self] in
                self?.acceptConflict(.both)
            },
        ]
    }

    /// Строка: ревью, треды и то, что на её месте было до изменений.
    private func lineActions(_ line: Int) -> [ContextAction] {
        var actions: [ContextAction] = []
        if isReviewDocument {
            actions.append(ContextAction(title: L("Комментировать строку…"), icon: "text.bubble",
                                         shortcut: KeymapStore.shared.menuShortcut(.commentLine)) { [weak self] in
                self?.commentOnLine(line)
            })
        }
        if !threads(atLine: line).isEmpty {
            actions.append(ContextAction(title: L("Показать обсуждение"), icon: "bubble.left.and.bubble.right") { [weak self] in
                self?.requestLinePopover(line: line, compose: false)
            })
        } else if removedLines(at: line) != nil {
            actions.append(ContextAction(title: L("Что было до изменения"), icon: "clock.arrow.circlepath") { [weak self] in
                self?.requestLinePopover(line: line, compose: false)
            })
        }
        if !editorLineChanges.isEmpty {
            actions.append(ContextAction(title: L("Следующее изменение"), icon: "plusminus",
                                         shortcut: KeymapStore.shared.menuShortcut(.nextChange)) { [weak self] in
                self?.jumpToChange(1)
            })
            actions.append(ContextAction(title: L("Предыдущее изменение"), icon: "plusminus",
                                         shortcut: KeymapStore.shared.menuShortcut(.previousChange)) { [weak self] in
                self?.jumpToChange(-1)
            })
        }
        if !editorCommentMarks.isEmpty {
            actions.append(ContextAction(title: L("Следующий тред"), icon: "bubble.left",
                                         shortcut: KeymapStore.shared.menuShortcut(.nextThread)) { [weak self] in
                self?.jumpToThread(1)
            })
        }
        return actions
    }

    private func fileActions(_ document: LoadedDocument, line: Int) -> [ContextAction] {
        var actions: [ContextAction] = []
        // Сборка без исходников: у метода под курсором можно посмотреть IL.
        // Пункт появляется, только если в этой строке действительно объявлен
        // метод, — меню показывает доступное, а не весь список команд.
        //
        // Спрашивается по одному методу и только когда спросили: поверхность
        // сборки — это проход по таблицам и ни одной инструкции, а тело
        // читается у того метода, который открыли.
        if document.decompiled == .assembly,
           AssemblySource.methodBody(of: document.url, line: line) != nil {
            actions.append(ContextAction(title: L("Показать IL метода"), icon: "chevron.left.forwardslash.chevron.right",
                                         ) { [weak self] in
                self?.showMethodBody(of: document.url, line: line)
            })
        }
        if !document.outline.isEmpty {
            actions.append(ContextAction(title: L("Структура файла…"), icon: "list.bullet.indent",
                                         shortcut: KeymapStore.shared.menuShortcut(.fileStructure)) { [weak self] in
                self?.openPalette(mode: .outline)
            })
            actions.append(ContextAction(title: L("Следующее объявление"), icon: "arrow.down.to.line",
                                         shortcut: KeymapStore.shared.menuShortcut(.nextMember)) { [weak self] in
                self?.jumpToMember(1)
            })
            actions.append(ContextAction(title: L("Предыдущее объявление"), icon: "arrow.up.to.line",
                                         shortcut: KeymapStore.shared.menuShortcut(.previousMember)) { [weak self] in
                self?.jumpToMember(-1)
            })
        }
        // Единственный конфликт, в котором и так стоишь, искать незачем.
        if conflicts.count > 1 || (conflicts.count == 1 && MergeConflicts.conflict(atLine: line, in: conflicts) == nil) {
            actions.append(ContextAction(title: L("Следующий конфликт"), icon: "exclamationmark.triangle",
                                         shortcut: KeymapStore.shared.menuShortcut(.nextConflict)) { [weak self] in
                self?.jumpToConflict(1)
            })
        }
        if unity.isActive {
            actions.append(ContextAction(title: L("Где используется ассет"), icon: "link",
                                         shortcut: KeymapStore.shared.menuShortcut(.assetUsages)) { [weak self] in
                self?.findAssetUsages()
            })
            actions.append(ContextAction(title: document.url.pathExtension == "meta" ? L("Открыть ассет") : L("Открыть .meta"),
                                         icon: "doc.badge.gearshape",
                                         shortcut: KeymapStore.shared.menuShortcut(.toggleMeta)) { [weak self] in
                self?.toggleMetaFile()
            })
        }
        return actions
    }
}
