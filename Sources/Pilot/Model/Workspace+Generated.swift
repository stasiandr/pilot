import Foundation

/// Сгенерированный код Unity: что генераторы исходников написали для типов
/// открытого файла (`UnityGenerators`).
extension Workspace {
    /// Показать в палитре, что генераторы написали для типов открытого файла.
    /// В первый раз для сборки — прогнав её компилятор: у `Assembly-CSharp`
    /// это полминуты, и всё это время палитра говорит, над чем работает.
    func showGeneratedCode() {
        guard let project = unity.project else {
            showNotice(L("Сгенерированный код есть только у Unity-проекта"))
            return
        }
        guard let url = document?.url ?? requestedFile, url.pathExtension == "cs" else {
            showNotice(L("Сначала откройте файл C#"))
            return
        }
        guard let editor = project.editorContents else {
            showNotice(L("Не найден редактор Unity \(project.editorVersion ?? "")"))
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

        generatedStatus = L("Ищу сборку \(fileName)…")
        presentList([], mode: .generated, busy: true)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<(UnityGenerators.Output, [URL]), UnityGenerators.Failure>
            if let rsp = UnityGenerators.responseFile(for: relPath, project: project.root) {
                let assembly = rsp.deletingPathExtension().lastPathComponent
                await MainActor.run { self?.generatedStatus = L("Генераторы работают над \(assembly)…") }
                do {
                    let output = try UnityGenerators.run(rsp: rsp, project: project.root, editor: editor)
                    result = .success((output, UnityGenerators.files(output.files, about: types)))
                } catch let failure as UnityGenerators.Failure {
                    result = .failure(failure)
                } catch {
                    result = .failure(.init(message: error.localizedDescription))
                }
            } else {
                result = .failure(.init(message: L("Unity ещё не компилировала \(fileName) — откройте проект в Unity")))
            }
            await MainActor.run { self?.presentGenerated(result) }
        }
    }

    private func presentGenerated(_ result: Result<(UnityGenerators.Output, [URL]), UnityGenerators.Failure>) {
        guard paletteMode == .generated else { return }
        switch result {
        case .failure(let failure):
            generatedStatus = ""
            isPaletteOpen = false
            showNotice(failure.message)
        case .success(let (output, files)):
            generatedStatus = files.isEmpty && !output.files.isEmpty
                ? L("Для типов этого файла генераторы ничего не написали (всего в \(output.assembly): \(String(output.files.count)))")
                : ""
            let items = files.enumerated().map { position, file in
                PaletteItem(
                    id: position,
                    icon: "gearshape.2",
                    primary: file.lastPathComponent,
                    secondary: UnityGenerators.generatorName(of: file, in: output.folder),
                    trailing: output.assembly,
                    target: NavTarget(url: file, range: nil))
            }
            presentList(items, mode: .generated)
        }
    }
}
