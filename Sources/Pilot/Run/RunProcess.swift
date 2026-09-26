import Foundation

/// Запущенная цель. Своя группа процессов: `dotnet run` запускает сервер
/// дочерним процессом, скрипт — ещё какие-то, и «Стоп» должен остановить
/// их все, а не оставить сервер держать порт.
///
/// Запуск — через login-shell пользователя: у приложения из Finder урезанный
/// PATH, и ни `dotnet` из Homebrew, ни переменные из профиля без него не
/// видны. Вывод и ошибки идут в одну трубу — в консоли они по порядку.
final class RunProcess: @unchecked Sendable {
    let pid: pid_t

    private let lock = NSLock()
    private var exited = false

    /// Все живые группы — чтобы при выходе Pilot их не бросить.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var live: [pid_t: RunProcess] = [:]

    private init(pid: pid_t) { self.pid = pid }

    enum Failure: LocalizedError {
        case pipe(Int32)
        case spawn(Int32)

        var errorDescription: String? {
            switch self {
            case .pipe(let code): return "не создать трубу: \(String(cString: strerror(code)))"
            case .spawn(let code): return "не запустить shell: \(String(cString: strerror(code)))"
            }
        }
    }

    /// `onOutput` и `onExit` зовутся с фоновых потоков. `onExit` получает
    /// код выхода, а для убитого сигналом — 128 + номер сигнала, как shell.
    static func start(command: String, directory: URL, environment: [String: String],
                      onOutput: @escaping @Sendable (Data) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws -> RunProcess {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw Failure.pipe(errno) }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Своя группа; остальные дескрипторы Pilot не наследуются; сигналы —
        // по умолчанию: Pilot сам игнорирует SIGTERM (см. AppDelegate),
        // и без сброса сервер унаследовал бы глухоту к нему.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let shell = loginShell()
        let argv = [shell, "-l", "-c", command]
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        let envp = env.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let status = withCStrings(argv) { argvp in
            withCStrings(envp) { envpp in
                posix_spawn(&pid, shell, &actions, &attributes, argvp, envpp)
            }
        }
        close(writeEnd)
        guard status == 0 else {
            close(readEnd)
            throw Failure.spawn(status)
        }

        let process = RunProcess(pid: pid)
        registryLock.lock()
        live[pid] = process
        registryLock.unlock()

        // Читаем до EOF: труба закрывается, когда её отпустят все в группе.
        let drained = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { drained.signal() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(readEnd, &buffer, buffer.count)
                if n > 0 { onOutput(Data(buffer[0..<n])); continue }
                if n < 0, errno == EINTR { continue }
                break
            }
            close(readEnd)
        }
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            let signal = status & 0x7F
            let code = signal == 0 ? (status >> 8) & 0xFF : 128 + signal
            process.lock.lock()
            process.exited = true
            process.lock.unlock()
            // Главный процесс завершился — то, что он оставил в группе,
            // тоже пора: иначе осиротевший сервер держит порт до перезагрузки.
            kill(-pid, SIGTERM)
            registryLock.lock()
            live[pid] = nil
            registryLock.unlock()
            // Последние строки — до сообщения о выходе. Кто-то в группе
            // может держать трубу и дальше; долго его не ждём.
            _ = drained.wait(timeout: .now() + 1)
            onExit(code)
        }
        return process
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !exited
    }

    /// Как ⌃C в терминале: .NET и большинство серверов на это закрываются
    /// сами. Не закрылись за `grace` — SIGTERM, потом SIGKILL.
    func stop(grace: TimeInterval = 3) {
        signalGroup(SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            guard isRunning else { return }
            signalGroup(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if isRunning { signalGroup(SIGKILL) }
            }
        }
    }

    private func signalGroup(_ signal: Int32) {
        kill(-pid, signal)
    }

    /// Pilot закрывается: ждать некогда, SIGTERM всем группам сразу.
    static func terminateAll() {
        registryLock.lock()
        let processes = Array(live.values)
        registryLock.unlock()
        for process in processes { process.signalGroup(SIGTERM) }
    }

    private static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }

    private static func withCStrings<R>(_ strings: [String],
                                        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
