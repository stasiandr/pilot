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

        // Сцены и префабы ссылаются GUID и fileID — это не идентификаторы,
        // но ⌘B по ним переходит к ассету.
        if unityReference {
            groups.append(ContextActionGroup(title: nil, actions: [
                ContextAction(title: "Перейти по ссылке", icon: "arrow.forward.circle",
                              shortcut: KeyShortcut("b", .command)) { [weak self] in
                    self?.goToDefinition(at: offset)
                },
            ]))
        } else if let symbol = Occurrences.symbol(in: model, at: offset) {
            groups.append(ContextActionGroup(title: symbol.text, actions: symbolActions(symbol.text, at: offset)))
        }

        if let conflict = MergeConflicts.conflict(atLine: line, in: conflicts) {
            groups.append(ContextActionGroup(title: "Конфликт слияния", actions: conflictActions(conflict)))
        }

        groups.append(ContextActionGroup(title: "Строка \(line + 1)", actions: lineActions(line)))
        groups.append(ContextActionGroup(title: document.url.lastPathComponent, actions: fileActions(document, line: line)))
        return groups.filter { !$0.actions.isEmpty }
    }

    private func symbolActions(_ name: String, at offset: Int) -> [ContextAction] {
        var actions = [
            ContextAction(title: "Перейти к объявлению", icon: "arrow.forward.circle",
                          shortcut: KeyShortcut("b", .command)) { [weak self] in
                self?.goToDefinition(at: offset)
            },
            ContextAction(title: "Найти использования", icon: "arrow.triangle.branch",
                          shortcut: KeyShortcut("r", .command)) { [weak self] in
                self?.findReferences(at: offset)
            },
        ]
        // Пункт появляется, только если реализации действительно есть: меню
        // у курсора показывает доступное, а не весь список команд.
        if let document, symbolIndex != nil,
           !LocalNavigator(index: symbolIndex, document: navDocument(document))
               .implementations(at: offset).declarations.isEmpty {
            actions.append(ContextAction(title: "Перейти к реализациям",
                                         icon: "point.3.connected.trianglepath.dotted",
                                         shortcut: KeyShortcut("b", [.command, .option])) { [weak self] in
                self?.findImplementations(at: offset)
            })
        }
        // Подсветка вхождений приходит с задержкой — считаем сами.
        if let document, Occurrences.find(name, in: document.model).count > 1 {
            actions.append(ContextAction(title: "Следующее вхождение", icon: "chevron.down",
                                         shortcut: KeyShortcut(NSDownArrowFunctionKey, .option)) { [weak self] in
                self?.jumpToOccurrence(1)
            })
            actions.append(ContextAction(title: "Предыдущее вхождение", icon: "chevron.up",
                                         shortcut: KeyShortcut(NSUpArrowFunctionKey, .option)) { [weak self] in
                self?.jumpToOccurrence(-1)
            })
        }
        if canSearchSymbols {
            actions.append(ContextAction(title: "Искать «\(name)» в проекте", icon: "number") { [weak self] in
                self?.openPalette(mode: .symbols)
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
            ContextAction(title: label("Принять текущее", conflict.currentLabel), icon: "arrow.left.square",
                          shortcut: KeyShortcut(NSLeftArrowFunctionKey, [.control, .option, .command])) { [weak self] in
                self?.acceptConflict(.current)
            },
            ContextAction(title: label("Принять входящее", conflict.incomingLabel), icon: "arrow.right.square",
                          shortcut: KeyShortcut(NSRightArrowFunctionKey, [.control, .option, .command])) { [weak self] in
                self?.acceptConflict(.incoming)
            },
            ContextAction(title: "Принять оба", icon: "square.on.square") { [weak self] in
                self?.acceptConflict(.both)
            },
        ]
    }

    /// Строка: ревью, треды и то, что на её месте было до изменений.
    private func lineActions(_ line: Int) -> [ContextAction] {
        var actions: [ContextAction] = []
        if isReviewDocument {
            actions.append(ContextAction(title: "Комментировать строку…", icon: "text.bubble",
                                         shortcut: KeyShortcut("c", [.command, .option])) { [weak self] in
                self?.commentOnLine(line)
            })
        }
        if !threads(atLine: line).isEmpty {
            actions.append(ContextAction(title: "Показать обсуждение", icon: "bubble.left.and.bubble.right") { [weak self] in
                self?.requestLinePopover(line: line, compose: false)
            })
        } else if removedLines(at: line) != nil {
            actions.append(ContextAction(title: "Что было до изменения", icon: "clock.arrow.circlepath") { [weak self] in
                self?.requestLinePopover(line: line, compose: false)
            })
        }
        if !editorLineChanges.isEmpty {
            actions.append(ContextAction(title: "Следующее изменение", icon: "plusminus",
                                         shortcut: KeyShortcut(NSDownArrowFunctionKey, [.control, .option])) { [weak self] in
                self?.jumpToChange(1)
            })
            actions.append(ContextAction(title: "Предыдущее изменение", icon: "plusminus",
                                         shortcut: KeyShortcut(NSUpArrowFunctionKey, [.control, .option])) { [weak self] in
                self?.jumpToChange(-1)
            })
        }
        if !editorCommentMarks.isEmpty {
            actions.append(ContextAction(title: "Следующий тред", icon: "bubble.left",
                                         shortcut: KeyShortcut("]", [.command, .option])) { [weak self] in
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
            actions.append(ContextAction(title: "Показать IL метода", icon: "chevron.left.forwardslash.chevron.right",
                                         ) { [weak self] in
                self?.showMethodBody(of: document.url, line: line)
            })
        }
        if !document.outline.isEmpty {
            actions.append(ContextAction(title: "Структура файла…", icon: "list.bullet.indent",
                                         shortcut: KeyShortcut("o", [.command, .shift])) { [weak self] in
                self?.openPalette(mode: .outline)
            })
            actions.append(ContextAction(title: "Следующее объявление", icon: "arrow.down.to.line",
                                         shortcut: KeyShortcut(NSDownArrowFunctionKey, .control)) { [weak self] in
                self?.jumpToMember(1)
            })
            actions.append(ContextAction(title: "Предыдущее объявление", icon: "arrow.up.to.line",
                                         shortcut: KeyShortcut(NSUpArrowFunctionKey, .control)) { [weak self] in
                self?.jumpToMember(-1)
            })
        }
        // Единственный конфликт, в котором и так стоишь, искать незачем.
        if conflicts.count > 1 || (conflicts.count == 1 && MergeConflicts.conflict(atLine: line, in: conflicts) == nil) {
            actions.append(ContextAction(title: "Следующий конфликт", icon: "exclamationmark.triangle",
                                         shortcut: KeyShortcut(NSDownArrowFunctionKey, [.control, .option, .command])) { [weak self] in
                self?.jumpToConflict(1)
            })
        }
        if unity.isActive {
            actions.append(ContextAction(title: "Где используется ассет", icon: "link",
                                         shortcut: KeyShortcut("r", [.command, .shift])) { [weak self] in
                self?.findAssetUsages()
            })
            actions.append(ContextAction(title: document.url.pathExtension == "meta" ? "Открыть ассет" : "Открыть .meta",
                                         icon: "doc.badge.gearshape",
                                         shortcut: KeyShortcut("m", [.command, .control])) { [weak self] in
                self?.toggleMetaFile()
            })
        }
        return actions
    }
}
