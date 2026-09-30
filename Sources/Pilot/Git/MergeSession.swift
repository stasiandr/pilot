import SwiftUI
import Combine

/// Слияние одного файла в конфликте: три версии из индекса (предок —
/// `:1:`, наша — `:2:`, их — `:3:`), куски diff3 и решение по каждому
/// спорному. Результат пишется в файл и отмечается решённым (`git add`).
@MainActor
final class MergeSession: ObservableObject {
    let repository: URL
    let path: String
    /// UnityYAMLMerge — для сцен и префабов: он сливает по объектам, а не по строкам.
    let yamlMerge: URL?

    @Published private(set) var chunks: [Merge3.Chunk] = []
    /// Три редактора окна слияния — создаются, когда версии прочитаны.
    @Published private(set) var editor: MergeEditorModel?
    private var editorChanges: AnyCancellable?
    /// Unity YAML: слияние по объектам; nil — файл не Unity или не разобрался.
    @Published private(set) var objects: UnityMerge.Result?
    /// JSON: слияние по ключам; nil — не JSON или не разобрался.
    @Published private(set) var keys: JSONMerge.Result?
    /// Выбор в спорах по объектам и по ключам — в сессии, а не в виде:
    /// ушёл к другому файлу и вернулся — выбранное на месте.
    @Published var picks: [String: UnityMerge.Pick] = [:]
    @Published var keyPicks: [String: JSONMerge.Pick] = [:]
    /// Чьи версии: наша ветка и та, что вливается.
    @Published private(set) var oursName = ""
    /// Двоичный файл: сливать нечего, только взять одну сторону целиком.
    @Published private(set) var isBinary = false
    @Published private(set) var theirsName = ""
    @Published private(set) var isLoaded = false
    @Published var error: String?
    @Published private(set) var busy = false
    private var trailingNewline = true
    /// Версия отсутствует: удалили с одной стороны.
    @Published private(set) var missing: (ours: Bool, theirs: Bool) = (false, false)

    init(repository: URL, path: String, yamlMerge: URL?) {
        self.repository = repository
        self.path = path
        self.yamlMerge = Self.isUnityYAML(path) ? yamlMerge : nil
    }

    static let unityExtensions: Set<String> = ["unity", "prefab", "asset", "mat", "anim", "controller",
                                                "overrideController", "physicMaterial", "mask", "playable"]

    static func isUnityYAML(_ path: String) -> Bool {
        unityExtensions.contains((path as NSString).pathExtension)
    }

    func load() {
        let repository = repository, path = path
        Task {
            let raw = await Task.detached(priority: .userInitiated) { () -> [Data?] in
                (1...3).map { stage in
                    guard let output = Git.run(["show", ":\(stage):\(path)"], in: repository), output.status == 0 else { return nil }
                    return output.stdout
                }
            }.value
            // Картинка, модель, шрифт, PDF — показываем как их, даже если
            // формат текстовый (OBJ, SVG): вершины текстом не сравнить.
            if raw.contains(where: { $0?.prefix(8192).contains(0) == true }) || MediaKind(filename: path) != nil {
                isBinary = true
                let names = await Task.detached { Self.branchNames(repository) }.value
                oursName = names.ours
                theirsName = names.theirs
                isLoaded = true
                return
            }
            let versions = raw.map { data in data.map { String(data: $0, encoding: .utf8) ?? String(decoding: $0, as: UTF8.self) } }
            let base = versions[0] ?? "", ours = versions[1], theirs = versions[2]
            missing = (ours == nil, theirs == nil)
            trailingNewline = (ours ?? theirs ?? base).hasSuffix("\n")
            chunks = Merge3.merge(base: base, ours: ours ?? "", theirs: theirs ?? "")
            let editor = MergeEditorModel(chunks: chunks, trailingNewline: trailingNewline,
                                          fileName: (path as NSString).lastPathComponent)
            // Решения в редакторе — это и счётчики окна: пусть оно их видит.
            editorChanges = editor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            self.editor = editor
            if Self.isUnityYAML(path) || (ours ?? "").hasPrefix("%YAML") {
                objects = UnityMerge.merge(base: base, ours: ours ?? "", theirs: theirs ?? "")
            } else if (path as NSString).pathExtension.lowercased() == "json", let ours, let theirs {
                keys = JSONMerge.merge(base: base, ours: ours, theirs: theirs)
            }
            let names = await Task.detached { Self.branchNames(repository) }.value
            oursName = names.ours
            theirsName = names.theirs
            isLoaded = true
            if versions.allSatisfy({ $0 == nil }) {
                error = L("В индексе нет версий этого файла — конфликт уже решён или файл не в слиянии")
            }
        }
    }

    /// Наша ветка — текущая; их — из `MERGE_HEAD` (или rebase, cherry-pick),
    /// именем из сообщения слияния, иначе коротким хэшем.
    nonisolated static func branchNames(_ repository: URL) -> (ours: String, theirs: String) {
        func text(_ arguments: [String]) -> String {
            guard let output = Git.run(arguments, in: repository), output.status == 0 else { return "" }
            return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ours = text(["symbolic-ref", "--quiet", "--short", "HEAD"])
        var theirs = ""
        if let directory = Git.gitDirectory(for: repository),
           let message = try? String(contentsOf: directory.appendingPathComponent("MERGE_MSG"), encoding: .utf8),
           let first = message.split(separator: "\n").first, let branch = GitCommitInfo.mergedBranch(String(first)) {
            theirs = branch
        }
        if theirs.isEmpty {
            for head in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REBASE_HEAD", "REVERT_HEAD"] {
                let hash = text(["rev-parse", "--short", "--verify", "--quiet", head])
                if !hash.isEmpty { theirs = hash; break }
            }
        }
        return (ours.isEmpty ? "HEAD" : ours, theirs)
    }

    /// Записать результат и отметить файл решённым. true — получилось.
    /// `text` — готовый текст (из редактора или слияния по объектам).
    func save(text: String? = nil, markResolved: Bool) async -> Bool {
        let url = repository.appendingPathComponent(path)
        do {
            guard let text = text ?? editor?.resultText else { return false }
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        guard markResolved else { return true }
        return await add()
    }

    private func add() async -> Bool {
        let repository = repository, path = path
        let result = await Task.detached { Git.execute(["add", "--", path], in: repository) }.value
        if result?.succeeded != true {
            error = result?.message ?? L("Не удалось запустить git")
            return false
        }
        return true
    }

    /// Взять версию одной стороны целиком (`checkout --ours/--theirs`) —
    /// для двоичных и тех, где сливать по строкам бессмысленно.
    func takeWhole(_ ours: Bool) async -> Bool {
        busy = true
        defer { busy = false }
        let repository = repository, path = path
        let result = await Task.detached {
            Git.execute(["checkout", ours ? "--ours" : "--theirs", "--", path], in: repository)
        }.value
        guard result?.succeeded == true else {
            error = result?.message ?? L("Не удалось запустить git")
            return false
        }
        return await add()
    }

    /// UnityYAMLMerge: сливает сцену по объектам. Код 0 — слил сам, файл
    /// записан; иначе — остались конфликты, и файл не трогаем.
    func runYAMLMerge() async -> Bool {
        guard let tool = yamlMerge else { return false }
        busy = true
        defer { busy = false }
        let repository = repository, path = path
        let outcome = await Task.detached { () -> (Int32, String)? in
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-yamlmerge-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let ext = (path as NSString).pathExtension
            var files: [URL] = []
            for (stage, name) in [(1, "BASE"), (2, "LOCAL"), (3, "REMOTE")] {
                let file = temp.appendingPathComponent("\(name).\(ext)")
                let data = Git.run(["show", ":\(stage):\(path)"], in: repository)?.stdout ?? Data()
                try? data.write(to: file)
                files.append(file)
            }
            let output = temp.appendingPathComponent("MERGED.\(ext)")
            let process = Process()
            process.executableURL = tool
            // Порядок, как в документации Unity для git: база, их, наша, результат.
            process.arguments = ["merge", "-p", files[0].path, files[2].path, files[1].path, output.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return nil }
            let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            if process.terminationStatus == 0, let merged = try? Data(contentsOf: output) {
                try? merged.write(to: repository.appendingPathComponent(path))
            }
            return (process.terminationStatus, log)
        }.value
        guard let outcome else {
            error = L("Не удалось запустить UnityYAMLMerge")
            return false
        }
        guard outcome.0 == 0 else {
            error = L("UnityYAMLMerge не смог слить сам:\n\(outcome.1.suffix(2000))")
            return false
        }
        return await add()
    }

    // MARK: - Где UnityYAMLMerge

    /// Сначала — в редакторе этого проекта, потом — в любом из Hub.
    /// В разных версиях Unity он лежит в разных папках `Contents`.
    nonisolated static func locateYAMLMerge(editorContents: URL?) -> URL? {
        let fm = FileManager.default
        func inside(_ contents: URL) -> URL? {
            for folder in ["Tools", "Helpers", "Resources"] {
                let url = contents.appendingPathComponent(folder).appendingPathComponent("UnityYAMLMerge")
                if fm.isExecutableFile(atPath: url.path) { return url }
            }
            return nil
        }
        if let editorContents, let found = inside(editorContents) { return found }
        for hub in ["/Applications/Unity/Hub/Editor", NSHomeDirectory() + "/Applications/Unity/Hub/Editor"] {
            let versions = (try? fm.contentsOfDirectory(atPath: hub))?.sorted(by: >) ?? []
            for version in versions {
                if let found = inside(URL(fileURLWithPath: hub).appendingPathComponent(version)
                    .appendingPathComponent("Unity.app/Contents")) { return found }
            }
        }
        return nil
    }
}
