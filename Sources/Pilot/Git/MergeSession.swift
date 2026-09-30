import SwiftUI

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
    /// Решения спорных кусков: индекс куска → строки результата.
    @Published var resolutions: [Int: [String]] = [:]
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

    var conflictIndices: [Int] { chunks.indices.filter { chunks[$0].isConflict } }
    var unresolvedCount: Int { conflictIndices.filter { resolutions[$0] == nil }.count }

    func load() {
        let repository = repository, path = path
        Task {
            let versions = await Task.detached(priority: .userInitiated) { () -> [String?] in
                (1...3).map { stage in
                    guard let output = Git.run(["show", ":\(stage):\(path)"], in: repository), output.status == 0 else { return nil }
                    return String(data: output.stdout, encoding: .utf8) ?? String(decoding: output.stdout, as: UTF8.self)
                }
            }.value
            let base = versions[0] ?? "", ours = versions[1], theirs = versions[2]
            missing = (ours == nil, theirs == nil)
            trailingNewline = (ours ?? theirs ?? base).hasSuffix("\n")
            chunks = Merge3.merge(base: base, ours: ours ?? "", theirs: theirs ?? "")
            resolutions = [:]
            isLoaded = true
            if versions.allSatisfy({ $0 == nil }) {
                error = L("В индексе нет версий этого файла — конфликт уже решён или файл не в слиянии")
            }
        }
    }

    // MARK: - Решения

    enum Choice { case ours, theirs, oursThenTheirs, theirsThenOurs, base }

    func resolve(_ index: Int, _ choice: Choice) {
        guard chunks.indices.contains(index) else { return }
        let chunk = chunks[index]
        switch choice {
        case .ours: resolutions[index] = chunk.ours
        case .theirs: resolutions[index] = chunk.theirs
        case .oursThenTheirs: resolutions[index] = chunk.ours + chunk.theirs
        case .theirsThenOurs: resolutions[index] = chunk.theirs + chunk.ours
        case .base: resolutions[index] = chunk.base
        }
    }

    func setText(_ index: Int, _ text: String) {
        resolutions[index] = Merge3.split(text.hasSuffix("\n") ? text : text + "\n")
    }

    func unresolve(_ index: Int) { resolutions[index] = nil }

    /// Палочка: всё, что решается без человека. Сколько решено.
    @discardableResult
    func autoResolve() -> Int {
        var count = 0
        for index in conflictIndices where resolutions[index] == nil {
            if let lines = Merge3.autoResolve(chunks[index]) {
                resolutions[index] = lines
                count += 1
            }
        }
        return count
    }

    /// Всё спорное — одной стороной.
    func resolveAll(_ choice: Choice) {
        for index in conflictIndices where resolutions[index] == nil { resolve(index, choice) }
    }

    func lines(of index: Int) -> [String] {
        resolutions[index] ?? chunks[index].automatic
    }

    var resultText: String {
        Merge3.text(chunks.indices.map(lines(of:)), trailingNewline: trailingNewline)
    }

    // MARK: - Запись

    /// Записать результат и отметить файл решённым. true — получилось.
    func save(markResolved: Bool) async -> Bool {
        let url = repository.appendingPathComponent(path)
        do {
            try resultText.write(to: url, atomically: true, encoding: .utf8)
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
