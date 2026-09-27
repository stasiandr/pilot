import Foundation

/// Что написали генераторы исходников Unity — по требованию.
///
/// Unity запускает генераторы на каждой компиляции, но их вывод никуда не
/// сохраняет. Зато оставляет аргументы компилятора: `Library/Bee/artifacts/
/// <dag>/<Сборка>.rsp` — исходники, ссылки, символы и `-analyzer:` с самими
/// генераторами. Здесь сборка компилируется ещё раз тем же Roslyn из той же
/// Unity, только сборка уходит во временную папку, а генераторы пишут файлы в
/// `Temp/GeneratedCode/<Сборка>` — туда, где их ищет Rustlyn: оттуда они
/// компилируются вместе с проектом и открываются только для чтения.
enum UnityGenerators {
    struct Output: Sendable {
        let assembly: String
        let folder: URL
        let files: [URL]
    }

    struct Failure: Error {
        let message: String
    }

    // MARK: - Сборка файла

    /// Response-файл сборки, в которую Unity компилирует `relPath` (путь от
    /// корня Unity-проекта). Сборка одна, но граф у Bee бывает не один:
    /// берём тот, что Unity писала последним.
    static func responseFile(for relPath: String, project: URL) -> URL? {
        let needle = "\"\(relPath)\""
        let fm = FileManager.default
        let artifacts = project.appendingPathComponent("Library/Bee/artifacts")
        guard let dags = try? fm.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil) else { return nil }
        var best: (url: URL, date: Date)?
        for dag in dags where dag.pathExtension == "dag" {
            guard let files = try? fm.contentsOfDirectory(at: dag, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == "rsp" && !file.lastPathComponent.hasSuffix(".mvfrm.rsp") {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      text.split(whereSeparator: \.isNewline).contains(where: { $0 == needle }) else { continue }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || date > best!.date { best = (file, date) }
            }
        }
        return best?.url
    }

    // MARK: - Запуск

    /// Прогнать генераторы сборки из `rsp`. Если ни исходники, ни аргументы
    /// с прошлого раза не менялись — вернуть то, что уже лежит на диске.
    static func run(rsp: URL, project: URL, editor: URL) throws -> Output {
        let fm = FileManager.default
        let assembly = rsp.deletingPathExtension().lastPathComponent
        let folder = project.appendingPathComponent("Temp/GeneratedCode/\(assembly)")
        let stampFile = folder.appendingPathComponent(".pilot-stamp")

        // Список исходников — с того раза, когда Unity компилировала сама.
        // Удалённые с тех пор выбрасываем, иначе csc не начнёт; новые сюда
        // не попадут, пока Unity их не скомпилирует.
        let text = try String(contentsOf: rsp, encoding: .utf8)
        var arguments: [String] = []
        var newest = Date.distantPast
        var sources = 0
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("\""), line.hasSuffix(".cs\"") {
                let path = project.appendingPathComponent(String(line.dropFirst().dropLast())).path
                guard let attributes = try? fm.attributesOfItem(atPath: path) else { continue }
                if let date = attributes[.modificationDate] as? Date, date > newest { newest = date }
                sources += 1
            }
            arguments.append(String(line))
        }
        let rspDate = (try? rsp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let stamp = "\(rspDate.timeIntervalSince1970) \(newest.timeIntervalSince1970) \(sources)"
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp {
            return Output(assembly: assembly, folder: folder, files: generatedFiles(in: folder))
        }

        let dotnet = editor.appendingPathComponent("NetCoreRuntime/dotnet")
        let csc = editor.appendingPathComponent("DotNetSdkRoslyn/csc.dll")
        guard fm.isExecutableFile(atPath: dotnet.path), fm.fileExists(atPath: csc.path) else {
            throw Failure(message: L("Не найден компилятор Unity в \(editor.path)"))
        }

        // Прежний вывод — долой: файл удалённого типа иначе остался бы
        // лишним объявлением в проекте.
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let scratch = fm.temporaryDirectory.appendingPathComponent("pilot-generators-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // Последний -out побеждает: сборка Unity на месте, наша — в scratch.
        arguments += [
            "-out:\"\(scratch.appendingPathComponent("out.dll").path)\"",
            "-refout:\"\(scratch.appendingPathComponent("out.ref.dll").path)\"",
            "-generatedfilesout:\"\(folder.path)\"",
        ]
        let response = scratch.appendingPathComponent("args.rsp")
        try arguments.joined(separator: "\n").write(to: response, atomically: true, encoding: .utf8)

        // csc из Unity 2022 не создаёт папки под вывод генератора, а только
        // жалуется на каждый файл. Папки берём из жалоб и компилируем ещё раз.
        var log = ""
        for _ in 0..<3 {
            log = try compile(dotnet: dotnet, csc: csc, response: response, in: project)
            let missing = unwritable(in: log)
            if missing.isEmpty { break }
            for path in missing {
                try? fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            }
        }
        let files = generatedFiles(in: folder)
        // Ошибки компиляции генераторам не мешают — они работают до неё.
        // Пусто и с ошибками — значит, не дошло и до генераторов.
        if files.isEmpty, log.contains(" error ") {
            let first = log.split(whereSeparator: \.isNewline).first { $0.contains(" error ") } ?? ""
            throw Failure(message: String(first))
        }
        try? stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        return Output(assembly: assembly, folder: folder, files: files)
    }

    private static func compile(dotnet: URL, csc: URL, response: URL, in project: URL) throws -> String {
        let process = Process()
        process.executableURL = dotnet
        process.arguments = ["exec", csc.path, "-nologo", "@" + response.path]
        process.currentDirectoryURL = project
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `error CS0016: Could not write to output file '<путь>' -- …`
    static func unwritable(in log: String) -> [String] {
        var paths: [String] = []
        for line in log.split(whereSeparator: \.isNewline) where line.contains("CS0016") {
            guard let open = line.range(of: "output file '"),
                  let close = line[open.upperBound...].range(of: "'") else { continue }
            paths.append(String(line[open.upperBound..<close.lowerBound]))
        }
        return paths
    }

    static func generatedFiles(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "cs" { files.append(url) }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Что относится к файлу

    /// Типы, объявленные в тексте: к ним генераторы и пишут partial-части.
    static func declaredTypes(in text: String) -> Set<String> {
        let pattern = #"\b(?:class|struct|record|interface|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var names = Set<String>()
        for match in regex.matches(in: text, range: range) {
            if let name = Range(match.range(at: 1), in: text) { names.insert(String(text[name])) }
        }
        return names
    }

    /// Сгенерированные файлы, которые относятся к `types`: имя файла
    /// называет тип (`UpdateClanGiftsViewSystem.system_<guid>.g.cs`,
    /// `ns.LootCaseType_to_default_string.g.cs`) или файл дописывает его
    /// `partial`-частью.
    static func files(_ files: [URL], about types: Set<String>) -> [URL] {
        guard !types.isEmpty else { return [] }
        let partial = types.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let regex = try? NSRegularExpression(pattern: #"\bpartial\s+(?:class|struct|record|interface)\s+(?:"# + partial + #")\b"#)
        return files.filter { url in
            let tokens = url.lastPathComponent.split { $0 == "." || $0 == "_" }
            if tokens.contains(where: { types.contains(String($0)) }) { return true }
            guard let regex, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// `SystemCallGenerator/SourceGenerators.Generators.Pipelines.SystemsPipeline/…`
    /// → `SystemsPipeline`: подпись строки в списке.
    static func generatorName(of file: URL, in folder: URL) -> String {
        let rel = file.path.dropFirst(folder.path.count + 1).split(separator: "/")
        guard rel.count >= 2 else { return "" }
        return String(rel[1].split(separator: ".").last ?? rel[1])
    }
}
