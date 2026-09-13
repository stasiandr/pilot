import Foundation

/// Git как отдельный процесс. Без libgit2: git и так стоит у всех, кто читает
/// код, а его porcelain-вывод — стабильный контракт.
///
/// Всё здесь синхронно и вызывается только из фоновых очередей.
enum Git {

    static let executable: String? = locate()

    private static func locate() -> String? {
        let fm = FileManager.default
        // Homebrew — первым: так git тот же, что в терминале.
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
            return path
        }
        #if os(macOS)
        // /usr/bin/git — заглушка: без Command Line Tools она не запускает git,
        // а показывает диалог установки. Берём её, только если инструменты есть.
        var developerDirs = ["/Library/Developer/CommandLineTools",
                             "/Applications/Xcode.app/Contents/Developer"]
        if let selected = try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            developerDirs.insert(selected, at: 0)
        }
        let hasTools = developerDirs.contains { fm.isExecutableFile(atPath: $0 + "/usr/bin/git") }
        return hasTools ? "/usr/bin/git" : nil
        #else
        return fm.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : nil
        #endif
    }

    /// Ближайшая папка с `.git` (каталогом или файлом — у worktree и
    /// подмодулей это файл). Процесс ради этого не нужен: пара вызовов stat.
    static func repositoryRoot(for directory: URL) -> URL? {
        let fm = FileManager.default
        var dir = directory.standardizedFileURL
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    // MARK: - Запуск

    struct Output {
        var status: Int32
        var stdout: Data
    }

    /// nil — git не установлен, не запустился или запуск отменили.
    static func run(_ arguments: [String], in directory: URL,
                    cancellation: Cancellation? = nil) -> Output? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Без необязательных блокировок status не трогает index.lock и не
        // мешает git, запущенному пользователем в терминале в ту же секунду.
        process.arguments = ["--no-optional-locks"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        cancellation?.attach(process)
        // Читаем до конца раньше, чем ждём выхода: иначе git упрётся
        // в заполненный pipe, а мы — в его завершение.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if cancellation?.isCancelled == true { return nil }
        return Output(status: process.terminationStatus, stdout: data)
    }

    /// Отмена долгого запуска: blame на файле с богатой историей идёт секунды,
    /// а читатель за это время успевает открыть три других файла.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }

        fileprivate func attach(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            self.process = process
            if cancelled { process.terminate() }
        }
    }

    // MARK: - Операции

    /// Ветка и изменённые файлы под `directory` (пути — от корня репозитория).
    static func status(in directory: URL) -> GitStatus? {
        guard let output = run(["status", "--porcelain=v2", "-z", "--branch",
                                "--untracked-files=all", "--", "."], in: directory),
              output.status == 0 else { return nil }
        return GitStatus.parse(output.stdout)
    }

    /// Изменённые строки текста относительно HEAD. `path` — от корня репозитория.
    /// `tracked == false` — файла в HEAD нет, и blame по нему бессмыслен.
    static func lineChanges(text: String, path: String, repository: URL)
        -> (changes: [LineDiff.Change], tracked: Bool)? {
        if let head = run(["cat-file", "blob", "HEAD:\(path)"], in: repository), head.status == 0 {
            // Декодируем так же, как документ при открытии, — иначе файл
            // не в UTF-8 целиком загорелся бы изменённым.
            let old = String(data: head.stdout, encoding: .utf8)
                ?? String(data: head.stdout, encoding: .isoLatin1) ?? ""
            return (LineDiff.changes(old: old, new: text), true)
        }
        // В HEAD файла нет: он либо новый, либо игнорируемый. Код 0 —
        // игнорируется, 1 — нет; всё прочее — git сломан, молчим.
        guard let ignored = run(["check-ignore", "-q", "--", path], in: repository) else { return nil }
        switch ignored.status {
        case 0:  return ([], false)
        case 1:  return (LineDiff.changes(old: "", new: text), false)
        default: return nil
        }
    }

    /// Авторство строк именно того текста, что на экране (`--contents`),
    /// а не файла на диске — по той же причине, что и в LineDiff.
    static func blame(text: String, path: String, repository: URL, lineCount: Int,
                      cancellation: Cancellation? = nil) -> GitBlame? {
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilot-blame-\(UUID().uuidString)")
        guard (try? text.data(using: .utf8)?.write(to: snapshot)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: snapshot) }

        guard let output = run(["blame", "--porcelain", "--contents", snapshot.path, "--", path],
                               in: repository, cancellation: cancellation),
              output.status == 0 else { return nil }
        return GitBlame.parse(output.stdout, lineCount: lineCount)
    }
}
