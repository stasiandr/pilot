import Foundation

/// Список файлов проекта от git — вместо обхода диска.
///
/// Отслеживаемые файлы git держит в `.git/index` и отдаёт их, не заглядывая
/// в рабочее дерево: 272 000 путей Unity-проекта — 0.1 с против 10 с обхода
/// с разбором .gitignore. Новые файлы git ищет сам, со своими правилами
/// игнорирования — теми же, что у `git status`, включая глобальный
/// excludesFile и .git/info/exclude, которых наш обход не видит.
enum GitFiles {

    /// Настоящий git, если он есть. `/usr/bin/git` на macOS — заглушка: без
    /// Command Line Tools она показывает системное окно «установите
    /// инструменты», и открытие папки не должно его вызывать. Поэтому
    /// берём сам бинарник из инструментов разработчика или Homebrew.
    static let executable: String? = {
        var candidates: [String] = []
        #if os(macOS)
        // Через этот симлинк xcode-select хранит выбранную папку инструментов.
        if let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(developer + "/usr/bin/git")
        }
        candidates += [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        #else
        candidates += ["/usr/bin/git", "/usr/local/bin/git"]
        #endif
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Отслеживаемые файлы под `root`, пути относительно него. Содержимое
    /// подмодулей раскрывается, как если бы это были обычные папки.
    /// nil — не git-репозиторий, git недоступен или отказался работать.
    static func tracked(root: URL) -> [String]? {
        run(["ls-files", "-z", "--recurse-submodules"], in: root)
    }

    /// Полный список: отслеживаемые файлы плюс новые неигнорируемые. Новые
    /// git ищет обходом дерева — это уже секунда, поэтому отслеживаемые
    /// передаются готовыми, а не запрашиваются заново.
    ///
    /// Удалённые с диска, но ещё не закоммиченные файлы остаются в списке:
    /// `ls-files --deleted` делает lstat каждого файла и на 272 000 путей
    /// идёт пять секунд. Ради редкого случая, когда такой файл просто
    /// не откроется, это слишком дорого.
    static func complete(root: URL, tracked: [String]) -> [String]? {
        guard let untracked = run(["ls-files", "-z", "--others", "--exclude-standard"], in: root)
        else { return nil }
        return tracked + untracked
    }

    private static func run(_ arguments: [String], in root: URL) -> [String]? {
        guard let git = executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        process.currentDirectoryURL = root
        // Только чтение: git не должен ради нас перезаписывать .git/index
        // и мешать блокировкой терминалу пользователя.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Читаем до конца до waitUntilExit: иначе git упрётся в полный пайп.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return split(data)
    }

    /// Разбор вывода `-z`: пути разделены нулевым байтом и не экранируются.
    ///
    /// Заодно отсеивается то, чего нет в обходе диска, — индекс должен быть
    /// одинаковым, откуда бы он ни пришёл: скрытые файлы и папки (любой
    /// компонент пути с точки) и вложенные репозитории, которые git
    /// показывает папкой со слешем на конце. Всё по байтам: на сотнях тысяч
    /// путей строковые проверки заняли бы секунды.
    static func split(_ data: Data) -> [String] {
        var paths: [String] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            var hidden = false
            for i in 0...bytes.count {
                let end = i == bytes.count
                let byte: UInt8 = end ? 0 : bytes[i]
                if byte == 0x2E && (i == start || bytes[i - 1] == 0x2F) { hidden = true }   // «.» в начале компонента
                guard byte == 0 else { continue }
                if i > start && !hidden && bytes[i - 1] != 0x2F {
                    paths.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]),
                                        as: UTF8.self))
                }
                start = i + 1
                hidden = false
            }
        }
        return paths
    }
}
