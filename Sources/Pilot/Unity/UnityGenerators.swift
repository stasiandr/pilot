import Foundation

/// Что написали генераторы исходников Unity.
///
/// Unity запускает генераторы на каждой компиляции, но их вывод никуда не
/// сохраняет. Зато оставляет аргументы компилятора: `Library/Bee/artifacts/
/// <dag>/<Сборка>.rsp` — исходники, ссылки, символы и `-analyzer:` с самими
/// генераторами. Здесь сборка компилируется ещё раз тем же Roslyn из той же
/// Unity — только метаданные и во временную папку, — а вывод генераторов
/// раскладывается по `Temp/GeneratedCode/<Сборка>`: туда, где его ищет
/// Rustlyn. Оттуда он компилируется вместе с проектом и открывается только
/// для чтения.
///
/// Прогон на `Assembly-CSharp` — почти минута, и почти вся она уходит на сами
/// генераторы (они работают в один поток). Поэтому вывод живёт на диске от
/// прогона до прогона: `.pilot-stamp` — с чего он собран, `.pilot-types` —
/// какие файлы о каких типах. Показывается он сразу, даже устаревший, а
/// обновляется следом и заранее (`UnityGeneratorRuns`).
enum UnityGenerators {
    struct Output: Sendable {
        let assembly: String
        let folder: URL
        let files: [URL]
        /// Сколько файлов прогон записал или убрал: 0 — вывод тот же, что был.
        var changed = 0
    }

    struct Failure: Error, Sendable {
        let message: String
    }

    /// Прогон отменили: закрыли проект или место понадобилось прогону по кнопке.
    struct Cancelled: Error {}

    /// Что в папке вывода с чего собрано.
    static let stampName = ".pilot-stamp"
    /// Индекс папки вывода (`GeneratedIndex`).
    static let indexName = ".pilot-types"

    static func assemblyName(of rsp: URL) -> String {
        rsp.deletingPathExtension().lastPathComponent
    }

    static func outputFolder(assembly: String, project: URL) -> URL {
        project.appendingPathComponent("Temp/GeneratedCode/\(assembly)")
    }

    // MARK: - Сборка файла

    /// Response-файл сборки, в которую Unity компилирует `relPath` (путь от
    /// корня Unity-проекта). Сборка одна, но граф у Bee бывает не один:
    /// берём тот, что Unity писала последним.
    static func responseFile(for relPath: String, project: URL) -> URL? {
        responseFiles(for: [relPath], project: project)[relPath]
    }

    /// То же для многих файлов за один проход по rsp: их у большого проекта
    /// сотни на граф, а у `Assembly-CSharp` rsp — два мегабайта. Строки не
    /// режутся, исходник ищется в байтах целиком.
    static func responseFiles(for relPaths: [String], project: URL) -> [String: URL] {
        guard !relPaths.isEmpty else { return [:] }
        let needles = relPaths.map { ($0, Array("\"\($0)\"".utf8)) }
        var best: [String: (url: URL, date: Date)] = [:]
        for rsp in responseFiles(project: project) {
            guard let data = try? Data(contentsOf: rsp.url, options: .mappedIfSafe) else { continue }
            for (path, needle) in needles where lists(data, needle) {
                if let known = best[path], known.date >= rsp.date { continue }
                best[path] = rsp
            }
        }
        return best.mapValues(\.url)
    }

    /// Response-файл сборки по имени — из графа, который Unity писала последним.
    static func responseFile(assembly: String, project: URL) -> URL? {
        responseFiles(project: project)
            .filter { assemblyName(of: $0.url) == assembly }
            .max { $0.date < $1.date }?.url
    }

    /// Все rsp сборок во всех графах Bee, кроме `.mvfrm.rsp` — у тех другой смысл.
    private static func responseFiles(project: URL) -> [(url: URL, date: Date)] {
        let fm = FileManager.default
        let artifacts = project.appendingPathComponent("Library/Bee/artifacts")
        guard let dags = try? fm.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil) else { return [] }
        var found: [(url: URL, date: Date)] = []
        for dag in dags where dag.pathExtension == "dag" {
            guard let files = try? fm.contentsOfDirectory(at: dag, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "rsp" && !file.lastPathComponent.hasSuffix(".mvfrm.rsp") {
                found.append((file, modificationDate(file.path) ?? .distantPast))
            }
        }
        return found
    }

    /// Есть ли в rsp строка ровно из `needle` (исходник в кавычках): каждая
    /// такая строка начинается с кавычки после перевода строки.
    private static func lists(_ data: Data, _ needle: [UInt8]) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress, !needle.isEmpty else { return false }
            var offset = 0
            while offset + needle.count <= raw.count {
                guard let hit = memchr(base + offset, Int32(needle[0]), raw.count - offset) else { return false }
                let at = base.distance(to: UnsafeRawPointer(hit))
                let end = at + needle.count
                if end <= raw.count, memcmp(base + at, needle, needle.count) == 0 {
                    let before = at == 0 ? UInt8(ascii: "\n") : raw[at - 1]
                    let after = end == raw.count ? UInt8(ascii: "\n") : raw[end]
                    if (before == 0x0A || before == 0x0D) && (after == 0x0A || after == 0x0D) { return true }
                }
                offset = at + 1
            }
            return false
        }
    }

    // MARK: - Компилятор

    /// Roslyn, которым компилирует сама Unity.
    struct Compiler: Sendable, Equatable {
        let dotnet: URL
        let csc: URL
    }

    /// Unity 2022 держит `dotnet` и `csc.dll` прямо в `Contents`, Unity 6 —
    /// в `Contents/Resources/Scripting`.
    static func compiler(in editor: URL) -> Compiler? {
        let fm = FileManager.default
        for base in [editor, editor.appendingPathComponent("Resources/Scripting")] {
            let dotnet = base.appendingPathComponent("NetCoreRuntime/dotnet")
            let csc = base.appendingPathComponent("DotNetSdkRoslyn/csc.dll")
            if fm.isExecutableFile(atPath: dotnet.path), fm.fileExists(atPath: csc.path) {
                return Compiler(dotnet: dotnet, csc: csc)
            }
        }
        return nil
    }

    // MARK: - Аргументы

    /// Имя ключа в строке rsp: `-out:"…"`, `/debug:portable`, `-refonly`,
    /// `-skipanalyzers+` → `out`, `debug`, `refonly`, `skipanalyzers`. Регистр
    /// csc не важен. Исходник в кавычках и путь `/Users/…` ключом не считаются:
    /// за именем ключа идёт `:`, `+`, `-` или конец строки.
    static func optionName<S: StringProtocol>(_ line: S) -> String? {
        guard let first = line.first, first == "-" || first == "/" else { return nil }
        let body = line.dropFirst()
        let name = body.prefix { $0.isASCII && $0.isLetter }
        guard !name.isEmpty else { return nil }
        let rest = body.dropFirst(name.count)
        guard rest.isEmpty || rest.first == ":" || rest.first == "+" || rest.first == "-" else { return nil }
        return name.lowercased()
    }

    /// Значение ключа без кавычек: `-r:"/a b/c.dll"` → `/a b/c.dll`.
    static func optionValue<S: StringProtocol>(_ line: S) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Ключи rsp Unity, которых в нашем прогоне нет: они пишут файлы Unity
    /// (`-out`, `-refout`, `-pdb`, `-doc`, `-errorlog`), спорят с `-refonly` и
    /// нашими же ключами или превращают предупреждения в ошибки
    /// (`-warnaserror`) — а ошибка разбора обрывает прогон раньше генераторов.
    static let replacedOptions: Set<String> = [
        "out", "refout", "refonly", "pdb", "doc", "errorlog", "generatedfilesout",
        "skipanalyzers", "reportanalyzer", "warnaserror",
    ]

    /// Аргументы нашего прогона: rsp Unity в том же порядке — от него зависит
    /// порядок деревьев, а значит, и то, что генераторы увидят первым, — без
    /// `replacedOptions` и без исходников, которых больше нет (иначе csc не
    /// начнёт; новые сюда не попадут, пока их не скомпилирует Unity).
    ///
    /// Сверху — наши: `-refonly` (только метаданные: тела методов не
    /// компилируются вовсе, а генераторы работают раньше), `-skipanalyzers+`
    /// (диагностические анализаторы не нужны, генераторы идут и с ним) и
    /// папка для вывода генераторов. `-doc` не выбрасывается, а переводится во
    /// временную папку: с ним разбираются XML-комментарии, и генератор,
    /// который их переносит, без него написал бы другое.
    static func arguments(rspText: String, output: URL, generated: URL, skipAnalyzers: Bool,
                          sourceExists: (String) -> Bool) -> [String] {
        var arguments: [String] = []
        var documented = false
        for line in rspText.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("\""), line.hasSuffix(".cs\"") {
                guard sourceExists(String(line.dropFirst().dropLast())) else { continue }
            } else if let name = optionName(line), replacedOptions.contains(name) {
                if name == "doc" { documented = true }
                continue
            }
            arguments.append(String(line))
        }
        arguments.append("-out:\"\(output.path)\"")
        arguments.append("-refonly")
        if skipAnalyzers { arguments.append("-skipanalyzers+") }
        if documented { arguments.append("-doc:\"\(output.deletingPathExtension().path).xml\"") }
        arguments.append("-generatedfilesout:\"\(generated.path)\"")
        return arguments
    }

    /// csc не знает ключа (`error CS2007: Unrecognized option: '-skipanalyzers+'`).
    static func rejected(_ option: String, in log: String) -> Bool {
        log.split(whereSeparator: \.isNewline).contains { $0.contains("CS2007") && $0.contains(option) }
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

    // MARK: - С чего собран вывод

    /// Что из rsp читает компилятор, кроме самих аргументов.
    struct Inputs: Equatable, Sendable {
        /// Исходники — как записаны в rsp, от корня проекта.
        var sources: [String] = []
        /// Сборки генераторов, ссылки, дополнительные файлы и настройки анализаторов.
        var files: [String] = []
    }

    static let inputOptions: Set<String> = ["analyzer", "a", "r", "reference", "additionalfile", "analyzerconfig"]

    static func inputs(rspText: String) -> Inputs {
        var inputs = Inputs()
        for line in rspText.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("\""), line.hasSuffix(".cs\"") {
                inputs.sources.append(String(line.dropFirst().dropLast()))
            } else if let name = optionName(line), inputOptions.contains(name),
                      let value = optionValue(line), !value.isEmpty {
                inputs.files.append(value)
            }
        }
        return inputs
    }

    /// Отметка «с чего собран вывод»: время rsp, самое позднее время изменения
    /// среди исходников, генераторов, ссылок и дополнительных файлов и число
    /// исходников. Устаревает от любой правки в сборке: генератор видит её
    /// всю, и какая правка его не касается, снаружи не узнать.
    static func stamp(rspDate: Date, inputs: Inputs, modified: [String: Date]) -> String {
        var newest = Date.distantPast
        var sources = 0
        for path in inputs.sources {
            guard let date = modified[path] else { continue }
            sources += 1
            if date > newest { newest = date }
        }
        for path in inputs.files {
            if let date = modified[path], date > newest { newest = date }
        }
        return "\(rspDate.timeIntervalSince1970) \(newest.timeIntervalSince1970) \(sources)"
    }

    /// Отметка для rsp как он есть сейчас, его текст и что из него есть на диске.
    static func currentStamp(rsp: URL, project: URL) -> (stamp: String, text: String, modified: [String: Date])? {
        guard let text = try? String(contentsOf: rsp, encoding: .utf8) else { return nil }
        let inputs = inputs(rspText: text)
        let modified = modificationDates(inputs.sources + inputs.files, project: project)
        let stamp = stamp(rspDate: modificationDate(rsp.path) ?? .distantPast, inputs: inputs, modified: modified)
        return (stamp, text, modified)
    }

    /// Время изменения путей из rsp (от корня проекта или абсолютных);
    /// которых нет на диске — нет и в ответе. `stat`, а не `FileManager`:
    /// у `Assembly-CSharp` двадцать тысяч исходников.
    static func modificationDates(_ paths: [String], project: URL) -> [String: Date] {
        var dates: [String: Date] = [:]
        dates.reserveCapacity(paths.count)
        let root = project.path
        for path in paths {
            let full = path.hasPrefix("/") ? path : root + "/" + path
            if let date = modificationDate(full) { dates[path] = date }
        }
        return dates
    }

    static func modificationDate(_ path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim
        #endif
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    private static func fileSize(_ path: String) -> Int64? {
        var info = stat()
        return stat(path, &info) == 0 ? Int64(info.st_size) : nil
    }

    enum Freshness: Equatable, Sendable {
        /// Вывод собран из того, что сейчас на диске.
        case fresh
        /// Вывод есть, но с тех пор менялись исходники или аргументы.
        case stale
        /// Вывода нет: для этой сборки генераторы ещё не запускались.
        case missing
    }

    /// Свежесть вывода по отметке прошлого прогона и нынешней. Пустой вывод
    /// с той же отметкой — тоже свежий: генераторы ничего не написали.
    static func freshness(stored: String?, current: String?, hasOutput: Bool) -> Freshness {
        if let stored, let current, stored == current { return .fresh }
        return hasOutput || stored != nil ? .stale : .missing
    }

    /// Что лежит на диске для сборки — без компиляции: для кнопки, которая
    /// показывает вывод сразу, и для решения, обновлять ли его заранее.
    struct Snapshot: Sendable {
        let assembly: String
        let folder: URL
        let freshness: Freshness
        /// Когда вывод собран: время отметки, без неё — время папки.
        let generated: Date?
        let index: GeneratedIndex
    }

    static func snapshot(rsp: URL, project: URL, folder: URL? = nil) -> Snapshot {
        let assembly = assemblyName(of: rsp)
        let folder = folder ?? outputFolder(assembly: assembly, project: project)
        let stampFile = folder.appendingPathComponent(stampName)
        let stored = try? String(contentsOf: stampFile, encoding: .utf8)
        let index = GeneratedIndex.load(folder: folder, stamp: stored)
        let current = currentStamp(rsp: rsp, project: project)?.stamp
        return Snapshot(assembly: assembly, folder: folder,
                        freshness: freshness(stored: stored, current: current, hasOutput: !index.entries.isEmpty),
                        generated: modificationDate(stampFile.path)
                            ?? (index.entries.isEmpty ? nil : modificationDate(folder.path)),
                        index: index)
    }

    // MARK: - Прогон

    /// Отмена прогона и приоритет его компилятора. Прогон ждёт csc на своей
    /// очереди, а отменяют и торопят его с главного потока.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var background: Bool

        /// `background` — прогон заранее: компилятор идёт с `PRIO_DARWIN_BG`,
        /// после всех (процессор — на экономных ядрах, диск — последним), и
        /// этот приоритет снимается на ходу, если прогон понадобился человеку.
        init(background: Bool) {
            self.background = background
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }

        /// Прогон ждёт человек: компилятор — из фона на обычный приоритет.
        func hurry() {
            lock.lock()
            defer { lock.unlock() }
            guard background else { return }
            background = false
            if let process, process.isRunning { Self.setBackground(process, false) }
        }

        /// Компилятор запущен; false — прогон уже отменён, и его остановили.
        fileprivate func started(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            self.process = process
            if background { Self.setBackground(process, true) }
            if cancelled { process.terminate() }
            return !cancelled
        }

        fileprivate func finished() {
            lock.lock()
            process = nil
            lock.unlock()
        }

        private static func setBackground(_ process: Process, _ on: Bool) {
            #if canImport(Darwin)
            _ = setpriority(PRIO_DARWIN_PROCESS, id_t(process.processIdentifier), on ? PRIO_DARWIN_BG : 0)
            #endif
        }
    }

    /// Прогнать генераторы сборки из `rsp` и разложить их вывод по `folder`
    /// (по умолчанию `Temp/GeneratedCode/<Сборка>`).
    ///
    /// Компилятор пишет во временную папку, а в `folder` меняется только то,
    /// что поменялось (`sync`): пока идёт прогон, там лежит прежний вывод
    /// целиком, а после Rustlyn и открытые вкладки узнают о правках по
    /// событиям ФС — как и после компиляции Unity. Ничего не поменялось —
    /// событий нет, и Rustlyn ничего не перекомпилирует.
    static func refresh(rsp: URL, project: URL, editor: URL, folder: URL? = nil, run: Run? = nil) throws -> Output {
        let fm = FileManager.default
        let assembly = assemblyName(of: rsp)
        let folder = folder ?? outputFolder(assembly: assembly, project: project)
        guard let compiler = compiler(in: editor) else {
            throw Failure(message: L("Не найден компилятор Unity в \(editor.path)"))
        }
        // Отметка — до компиляции: правка, сделанная во время прогона,
        // оставит вывод устаревшим, а не свежим.
        guard let current = currentStamp(rsp: rsp, project: project) else {
            throw Failure(message: L("Не удалось прочитать \(rsp.lastPathComponent)"))
        }
        let (stamp, text, modified) = current

        let scratch = fm.temporaryDirectory.appendingPathComponent("pilot-generators-\(UUID().uuidString)")
        let staging = scratch.appendingPathComponent("generated")
        // Корень вывода должен быть: тогда csc сам создаёт в нём папки генераторов.
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        var skipAnalyzers = true
        var log = ""
        for _ in 0..<4 {
            let arguments = arguments(rspText: text, output: scratch.appendingPathComponent("out.dll"),
                                      generated: staging, skipAnalyzers: skipAnalyzers,
                                      sourceExists: { modified[$0] != nil })
            let response = scratch.appendingPathComponent("args.rsp")
            try arguments.joined(separator: "\n").write(to: response, atomically: true, encoding: .utf8)
            log = try compile(compiler, response: response, in: project, run: run)
            // Старый Roslyn не знает -skipanalyzers: без него — то же, только дольше.
            if skipAnalyzers, rejected("skipanalyzers", in: log) {
                skipAnalyzers = false
                continue
            }
            // Папку, которой не оказалось, csc не создаёт, а жалуется на каждый
            // файл в ней. Папки берём из жалоб и компилируем ещё раз.
            let missing = unwritable(in: log)
            if missing.isEmpty { break }
            for path in missing {
                try? fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            }
        }

        let produced = relativeFiles(in: staging)
        // Ошибки компиляции генераторам не мешают — они работают до неё.
        // Пусто и с ошибками — значит, не дошло и до генераторов; прежний
        // вывод тогда остаётся как был.
        if produced.isEmpty, log.contains(" error ") {
            let first = log.split(whereSeparator: \.isNewline).first { $0.contains(" error ") } ?? ""
            throw Failure(message: String(first))
        }
        let previous = GeneratedIndex.load(folder: folder,
                                           stamp: try? String(contentsOf: folder.appendingPathComponent(stampName),
                                                              encoding: .utf8))
        let changes = try sync(from: staging, files: produced, to: folder)
        // Индекс и отметка — последними: отметка говорит, что вывод полон.
        let index = GeneratedIndex.build(folder: folder, reusing: previous, rewritten: Set(changes.written))
        try? index.serialized(stamp: stamp).write(to: folder.appendingPathComponent(indexName),
                                                  atomically: true, encoding: .utf8)
        try? stamp.write(to: folder.appendingPathComponent(stampName), atomically: true, encoding: .utf8)
        return Output(assembly: assembly, folder: folder,
                      files: index.entries.map { folder.appendingPathComponent($0.path) },
                      changed: changes.written.count + changes.removed.count)
    }

    private static func compile(_ compiler: Compiler, response: URL, in project: URL, run: Run?) throws -> String {
        let process = Process()
        process.executableURL = compiler.dotnet
        process.arguments = ["exec", compiler.csc.path, "-nologo", "@" + response.path]
        process.currentDirectoryURL = project
        #if os(macOS)
        // Приоритет компилятора — свой, а не очереди, с которой его запустили:
        // фоновый прогон его понижает, и то так, чтобы можно было вернуть.
        process.qualityOfService = .userInitiated
        #endif
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let live = run?.started(process) ?? true
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        run?.finished()
        if !live || run?.isCancelled == true { throw Cancelled() }
        return String(decoding: data, as: UTF8.self)
    }

    /// `.cs` под папкой — пути от неё, по порядку.
    static func relativeFiles(in folder: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        var files: [String] = []
        for case let path as String in walker where path.hasSuffix(".cs") { files.append(path) }
        return files.sorted()
    }

    static func generatedFiles(in folder: URL) -> [URL] {
        relativeFiles(in: folder).map { folder.appendingPathComponent($0) }
    }

    // MARK: - Раскладка по папке вывода

    /// Имя файла без случайной части. SystemCallGenerator кладёт в имя новый
    /// GUID на каждой компиляции (`Row.component_<32 знака>.g.cs`): без этого
    /// каждый прогон менял бы имена шестнадцати тысяч файлов, открытые вкладки
    /// теряли бы свой, а Rustlyn перечитывал бы всё.
    static func stableName(_ path: String) -> String {
        let bytes = Array(path.utf8)
        func isHex(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
        }
        /// Длина GUID с этого места: 32 знака подряд или 8-4-4-4-12.
        func guid(at start: Int) -> Int? {
            var run = start
            while run < bytes.count, isHex(bytes[run]) { run += 1 }
            if run - start == 32 { return 32 }
            var at = start
            for (index, length) in [8, 4, 4, 4, 12].enumerated() {
                if index > 0 {
                    guard at < bytes.count, bytes[at] == UInt8(ascii: "-") else { return nil }
                    at += 1
                }
                for _ in 0..<length {
                    guard at < bytes.count, isHex(bytes[at]) else { return nil }
                    at += 1
                }
            }
            return at < bytes.count && isHex(bytes[at]) ? nil : at - start
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if isHex(bytes[i]), i == 0 || !isHex(bytes[i - 1]), let length = guid(at: i) {
                out.append(UInt8(ascii: "*"))
                i += length
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    struct Move: Hashable, Sendable {
        /// Путь в новом выводе.
        var from: String
        /// Куда он ляжет в папке вывода.
        var to: String
    }

    /// Что сделать с папкой вывода, чтобы в ней оказался новый вывод.
    struct SyncPlan: Equatable, Sendable {
        var write: [Move] = []
        var remove: [String] = []
        /// Сколько файлов совпало с новыми и осталось как было.
        var kept = 0
    }

    /// План раскладки: файлы сопоставляются по `stableName`. Сначала — те же
    /// имена, потом тот же текст под другим GUID (такой файл остаётся под
    /// старым именем), остальные новые тексты ложатся под оставшиеся старые
    /// имена: открытая вкладка покажет новый текст, а не пропавший файл.
    /// `same(старый, новый)` — одинаков ли текст.
    static func syncPlan(old: [String], new: [String], same: (String, String) -> Bool) -> SyncPlan {
        var plan = SyncPlan()
        let oldGroups = Dictionary(grouping: old, by: stableName)
        let newGroups = Dictionary(grouping: new, by: stableName)
        for key in Set(oldGroups.keys).union(newGroups.keys).sorted() {
            var olds = (oldGroups[key] ?? []).sorted()
            var news = (newGroups[key] ?? []).sorted()
            for name in news where olds.contains(name) {
                olds.removeAll { $0 == name }
                news.removeAll { $0 == name }
                if same(name, name) { plan.kept += 1 } else { plan.write.append(Move(from: name, to: name)) }
            }
            for name in news {
                guard let match = olds.first(where: { same($0, name) }) else { continue }
                olds.removeAll { $0 == match }
                news.removeAll { $0 == name }
                plan.kept += 1
            }
            while !news.isEmpty, !olds.isEmpty {
                plan.write.append(Move(from: news.removeFirst(), to: olds.removeFirst()))
            }
            plan.write += news.map { Move(from: $0, to: $0) }
            plan.remove += olds
        }
        return plan
    }

    /// Разложить новый вывод из `staging` по `folder` по `syncPlan`. Файл
    /// заменяется переименованием — читатель видит старый текст или новый,
    /// но не пустоту.
    static func sync(from staging: URL, files produced: [String], to folder: URL) throws
        -> (written: [String], removed: [String]) {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = relativeFiles(in: folder)
        var incoming = produced
        if existing.isEmpty {
            // Первый прогон: папки генераторов переезжают целиком — одно
            // переименование на папку, а не на каждый из тысяч файлов.
            for item in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? []
            where !fm.fileExists(atPath: folder.appendingPathComponent(item).path) {
                _ = rename(staging.appendingPathComponent(item).path, folder.appendingPathComponent(item).path)
            }
            incoming = relativeFiles(in: staging)
        }
        let plan = syncPlan(old: existing, new: incoming) { old, new in
            sameContents(folder.appendingPathComponent(old).path, staging.appendingPathComponent(new).path)
        }
        var made = Set<String>()
        for move in plan.write {
            let source = staging.appendingPathComponent(move.from)
            let target = folder.appendingPathComponent(move.to)
            let parent = target.deletingLastPathComponent()
            if made.insert(parent.path).inserted {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            if rename(source.path, target.path) != 0 {
                // Другой том: переименованием не перенести.
                try Data(contentsOf: source).write(to: target, options: .atomic)
            }
        }
        for path in plan.remove { try? fm.removeItem(at: folder.appendingPathComponent(path)) }
        if !plan.remove.isEmpty { removeEmptyFolders(in: folder) }
        return (existing.isEmpty ? produced : plan.write.map(\.to), plan.remove)
    }

    private static func sameContents(_ a: String, _ b: String) -> Bool {
        guard let sizeA = fileSize(a), sizeA == fileSize(b) else { return false }
        guard let dataA = FileManager.default.contents(atPath: a),
              let dataB = FileManager.default.contents(atPath: b) else { return false }
        return dataA == dataB
    }

    private static func removeEmptyFolders(in folder: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: folder.path) else { return }
        var folders: [String] = []
        for case let path as String in walker {
            var isFolder: ObjCBool = false
            if fm.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isFolder), isFolder.boolValue {
                folders.append(path)
            }
        }
        // Глубокие — первыми: опустевшая папка опустошает родителя.
        for path in folders.sorted(by: { $0.count > $1.count }) {
            let url = folder.appendingPathComponent(path)
            if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Индекс папки вывода

    /// Какие файлы лежат в папке вывода и какие типы каждый дописывает
    /// `partial`-частью. Без него «что относится к открытому файлу» читало бы
    /// все шестнадцать тысяч файлов `Assembly-CSharp` на каждое нажатие.
    struct GeneratedIndex: Sendable, Equatable {
        struct Entry: Sendable, Equatable {
            /// Путь от папки вывода.
            var path: String
            var partials: [String]
        }
        var entries: [Entry] = []

        static let header = "pilot generated index 1"

        /// Первая строка — заголовок, вторая — отметка, при которой записан
        /// индекс, дальше `путь<TAB>Тип Тип`.
        func serialized(stamp: String) -> String {
            var out = Self.header + "\n" + stamp.replacingOccurrences(of: "\n", with: " ") + "\n"
            for entry in entries { out += entry.path + "\t" + entry.partials.joined(separator: " ") + "\n" }
            return out
        }

        static func parse(_ text: String) -> (stamp: String, index: GeneratedIndex)? {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 2, lines[0] == header else { return nil }
            var entries: [Entry] = []
            for line in lines.dropFirst(2) where !line.isEmpty {
                guard let tab = line.firstIndex(of: "\t") else { return nil }
                entries.append(Entry(path: String(line[..<tab]),
                                     partials: line[line.index(after: tab)...].split(separator: " ").map(String.init)))
            }
            return (String(lines[1]), GeneratedIndex(entries: entries))
        }

        /// Собрать по папке. Файлы, которых нет в `rewritten`, берутся из
        /// `reusing`, если они там есть, — читаются только новые.
        static func build(folder: URL, reusing old: GeneratedIndex? = nil, rewritten: Set<String> = []) -> GeneratedIndex {
            let known = Dictionary((old?.entries ?? []).map { ($0.path, $0.partials) }, uniquingKeysWith: { a, _ in a })
            let paths = UnityGenerators.relativeFiles(in: folder)
            var entries = paths.map { Entry(path: $0, partials: rewritten.contains($0) ? [] : known[$0] ?? []) }
            let unread = paths.indices.filter { rewritten.contains(paths[$0]) || known[paths[$0]] == nil }
            // Файлов десятки тысяч, и каждый надо открыть: читаем на всех ядрах.
            let base = folder.path + "/"
            let found = UnsafeMutableBufferPointer<[String]>.allocate(capacity: unread.count)
            _ = found.initialize(from: repeatElement([], count: unread.count))
            let chunk = 256
            DispatchQueue.concurrentPerform(iterations: (unread.count + chunk - 1) / chunk) { part in
                for slot in part * chunk..<min(unread.count, (part + 1) * chunk) {
                    let data = FileManager.default.contents(atPath: base + paths[unread[slot]]) ?? Data()
                    found[slot] = UnityGenerators.partialTypes(in: data)
                }
            }
            for (slot, index) in unread.enumerated() { entries[index].partials = found[slot] }
            found.deinitialize()
            found.deallocate()
            return GeneratedIndex(entries: entries)
        }

        /// Индекс папки: записанный при той же отметке, что лежит рядом, —
        /// иначе папку писал кто-то ещё, и индекс собирается заново (и
        /// записывается, чтобы в следующий раз не собирать).
        static func load(folder: URL, stamp: String?) -> GeneratedIndex {
            let file = folder.appendingPathComponent(UnityGenerators.indexName)
            if let text = try? String(contentsOf: file, encoding: .utf8), let saved = parse(text),
               saved.stamp == (stamp ?? "").replacingOccurrences(of: "\n", with: " ") {
                return saved.index
            }
            guard FileManager.default.fileExists(atPath: folder.path) else { return GeneratedIndex() }
            let index = build(folder: folder)
            try? index.serialized(stamp: stamp ?? "").write(to: file, atomically: true, encoding: .utf8)
            return index
        }

        /// Файлы про эти типы: имя файла называет тип
        /// (`UpdateClanGiftsViewSystem.system_<guid>.g.cs`,
        /// `ns.LootCaseType_to_default_string.g.cs`) или файл дописывает его
        /// `partial`-частью.
        func files(about types: Set<String>) -> [String] {
            guard !types.isEmpty else { return [] }
            return entries.filter { entry in
                UnityGenerators.namesType(fileName(entry.path), types) || entry.partials.contains(where: types.contains)
            }.map(\.path)
        }

        private func fileName(_ path: String) -> Substring {
            path.split(separator: "/").last ?? Substring(path)
        }
    }

    /// Имя файла называет один из типов: `A.B_C.g.cs` → A, B, C, g, cs.
    static func namesType<S: StringProtocol>(_ fileName: S, _ types: Set<String>) -> Bool {
        fileName.split { $0 == "." || $0 == "_" }.contains { types.contains(String($0)) }
    }

    /// Типы, которые текст дописывает `partial`-частью: `partial class X`,
    /// `partial struct X`, `partial record struct X`. Проход по байтам, без
    /// регулярных выражений: текстов — десятки мегабайт.
    static func partialTypes(in data: Data) -> [String] {
        data.withUnsafeBytes { raw -> [String] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            func isIdentifier(_ c: UInt8) -> Bool {
                (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80
            }
            func skipSpace(_ j: inout Int) {
                while j < count, bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D { j += 1 }
            }
            func word(_ j: inout Int) -> String {
                let start = j
                while j < count, isIdentifier(bytes[j]) { j += 1 }
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<j]), as: UTF8.self)
            }
            let keyword = Array("partial".utf8)
            var names: [String] = []
            var i = 0
            while i + keyword.count <= count {
                guard bytes[i] == keyword[0], i == 0 || !isIdentifier(bytes[i - 1]),
                      (1..<keyword.count).allSatisfy({ bytes[i + $0] == keyword[$0] }),
                      i + keyword.count == count || !isIdentifier(bytes[i + keyword.count]) else {
                    i += 1
                    continue
                }
                var j = i + keyword.count
                skipSpace(&j)
                var kind = word(&j)
                if kind == "record" {
                    var k = j
                    skipSpace(&k)
                    var l = k
                    let next = word(&l)
                    if next == "class" || next == "struct" {
                        j = l
                        kind = next
                    }
                }
                if ["class", "struct", "interface", "record"].contains(kind) {
                    skipSpace(&j)
                    let name = word(&j)
                    if !name.isEmpty { names.append(name) }
                }
                i = max(j, i + 1)
            }
            return names
        }
    }

    // MARK: - Что относится к файлу

    /// Типы, объявленные в тексте: к ним генераторы и пишут partial-части.
    static func declaredTypes(in text: String) -> Set<String> {
        let pattern = #"\b(?:record\s+(?:class|struct)|class|struct|record|interface|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var names = Set<String>()
        for match in regex.matches(in: text, range: range) {
            if let name = Range(match.range(at: 1), in: text) { names.insert(String(text[name])) }
        }
        return names
    }

    /// Сгенерированные файлы, которые относятся к `types` — то же, что
    /// `GeneratedIndex.files(about:)`, но без индекса: читая файлы.
    static func files(_ files: [URL], about types: Set<String>) -> [URL] {
        guard !types.isEmpty else { return [] }
        return files.filter { url in
            if namesType(url.lastPathComponent, types) { return true }
            guard let data = FileManager.default.contents(atPath: url.path) else { return false }
            return partialTypes(in: data).contains(where: types.contains)
        }
    }

    /// `SystemCallGenerator/SourceGenerators.Generators.Pipelines.SystemsPipeline/…`
    /// → `SystemsPipeline`: подпись строки в списке.
    static func generatorName(of file: URL, in folder: URL) -> String {
        let rel = file.path.dropFirst(folder.path.count + 1).split(separator: "/")
        guard rel.count >= 2 else { return "" }
        return String(rel[1].split(separator: ".").last ?? rel[1])
    }

    // MARK: - Заранее: когда и что

    /// Сборка, которую Unity только что компилировала: в граф Bee легли её
    /// `<Сборка>.dll` или `<Сборка>.rsp` (`Library/Bee/artifacts/<граф>.dag/`).
    static func recompiledAssembly(_ path: String) -> String? {
        guard let marker = path.range(of: "/Library/Bee/artifacts/") else { return nil }
        let parts = path[marker.upperBound...].split(separator: "/")
        guard parts.count == 2, parts[0].hasSuffix(".dag") else { return nil }
        let name = parts[1]
        if name.hasSuffix(".rsp"), !name.hasSuffix(".mvfrm.rsp") { return String(name.dropLast(4)) }
        if name.hasSuffix(".dll"), !name.hasSuffix(".ref.dll") { return String(name.dropLast(4)) }
        return nil
    }

    /// Сборка, чей вывод лежит по этому пути: `…/Temp/GeneratedCode/<Сборка>/…`.
    static func outputAssembly(_ path: String) -> String? {
        guard let marker = path.range(of: "/Temp/GeneratedCode/") else { return nil }
        return path[marker.upperBound...].split(separator: "/").first.map(String.init)
    }

    /// Какие сборки обновлять заранее: `Assembly-CSharp` первой — в ней почти
    /// весь код проекта, — дальше в том порядке, в каком их назвали; каждую
    /// один раз и не больше `limit`: прогон большой сборки — минута процессора.
    static func precomputeOrder(_ rsps: [URL], limit: Int) -> [URL] {
        var seen = Set<String>()
        let unique = rsps.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let main = unique.filter { assemblyName(of: $0) == "Assembly-CSharp" }
        let rest = unique.filter { assemblyName(of: $0) != "Assembly-CSharp" }
        return Array((main + rest).prefix(limit))
    }

    /// Через сколько секунд можно начинать фоновый прогон; nil — сейчас.
    /// Пока Pilot или Unity компилируют для человека, фон ждёт: Unity — до
    /// `quiet` секунд тишины в `Library/Bee`, свою компиляцию — повторной
    /// проверкой через `retry`.
    static func backgroundDelay(now: Date, lastBee: Date?, busy: Bool,
                                quiet: TimeInterval, retry: TimeInterval) -> TimeInterval? {
        if let lastBee {
            let silence = now.timeIntervalSince(lastBee)
            if silence < quiet { return quiet - silence }
        }
        return busy ? retry : nil
    }
}
