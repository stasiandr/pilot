import Foundation

struct JadxError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Процесс jadx (Jadx/src/pilot/JadxEngine.java): запросы и ответы — JSON,
/// по строке на сообщение, через stdin/stdout. Всё, что пишет сам jadx, уходит в stderr.
///
/// JVM поднимается при открытии архива и живёт, пока открыт проект:
/// декомпиляция первого класса после старта в разы медленнее следующих.
final class JadxClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var buffer = Data()
    private var stderrTail = ""
    private var failure: String?

    init() throws {
        let runtime = try Self.runtime()
        process.executableURL = runtime.java
        process.arguments = runtime.arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { self?.consume(chunk) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: chunk, as: UTF8.self)
            self.lock.withLock { self.stderrTail = String((self.stderrTail + text).suffix(4000)) }
        }
        process.terminationHandler = { [weak self] proc in
            self?.failAll(L("jadx завершился (код \(proc.terminationStatus))"))
        }
        try process.run()
    }

    deinit { stop() }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            send(method, params) { continuation.resume(with: $0) }
        }
    }

    func object(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let result = try await call(method, params) as? [String: Any] else {
            throw JadxError(message: L("jadx: неожиданный ответ на \(method)"))
        }
        return result
    }

    /// Для фоновых очередей, которые не умеют ждать асинхронно (предпросмотр палитры).
    /// С главного потока не звать.
    func objectSync(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<Any, Error> = .failure(JadxError(message: L("jadx не ответил")))
        send(method, params) { result in
            outcome = result
            done.signal()
        }
        done.wait()
        guard let result = try outcome.get() as? [String: Any] else {
            throw JadxError(message: L("jadx: неожиданный ответ на \(method)"))
        }
        return result
    }

    private func send(_ method: String, _ params: [String: Any], _ completion: @escaping (Result<Any, Error>) -> Void) {
        let (id, dead): (Int, String?) = lock.withLock {
            nextID += 1
            if failure == nil { pending[nextID] = completion }
            return (nextID, failure)
        }
        if let dead {
            completion(.failure(JadxError(message: dead)))
            return
        }
        do {
            let line = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            try input.fileHandleForWriting.write(contentsOf: line + Data([0x0A]))
        } catch {
            let callback = lock.withLock { pending.removeValue(forKey: id) }
            callback?(.failure(error))
        }
    }

    private func consume(_ chunk: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        for line in lines {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = message["id"] as? Int else { continue }
            let callback = lock.withLock { pending.removeValue(forKey: id) }
            if let error = message["error"] as? String {
                callback?(.failure(JadxError(message: error)))
            } else {
                callback?(.success(message["result"] ?? NSNull()))
            }
        }
    }

    private func failAll(_ reason: String) {
        let (callbacks, message) = lock.withLock { () -> ([(Result<Any, Error>) -> Void], String) in
            let tail = stderrTail.split(separator: "\n").suffix(6).joined(separator: "\n")
            let message = tail.isEmpty ? reason : "\(reason)\n\(tail)"
            failure = message
            let callbacks = Array(pending.values)
            pending.removeAll()
            return (callbacks, message)
        }
        for callback in callbacks { callback(.failure(JadxError(message: message))) }
    }

    // MARK: - Где JVM и jar'ы

    private static func runtime() throws -> (java: URL, arguments: [String]) {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources.appendingPathComponent("Jadx")) }
        // Запуск не из бандла: .build/<config>/Pilot → .build/jadx.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<4 {
            dirs.append(dir.appendingPathComponent("jadx"))
            dir = dir.deletingLastPathComponent()
        }
        guard let jars = dirs.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("engine.jar").path) }) else {
            throw JadxError(message: L("Pilot собран без jadx: нужен JDK (brew install openjdk) и пересборка"))
        }

        var candidates: [URL] = []
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"] {
            candidates.append(URL(fileURLWithPath: home).appendingPathComponent("bin/java"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/opt/openjdk/bin/java"))
        candidates.append(URL(fileURLWithPath: "/usr/local/opt/openjdk/bin/java"))
        guard let java = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw JadxError(message: L("Не найдена Java для jadx: brew install openjdk"))
        }

        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pilot")
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let classpath = ["engine.jar", "jadx.jar"].map { jars.appendingPathComponent($0).path }.joined(separator: ":")
        return (java, [
            "-XX:+UseG1GC", "-XX:MaxRAMPercentage=60", "-Xss8m",
            "-Djava.awt.headless=true", "-Dfile.encoding=UTF-8",
            // Архив общих классов: второй и следующие запуски JVM заметно быстрее.
            "-XX:SharedArchiveFile=\(cache.appendingPathComponent("jadx.jsa").path)",
            "-XX:+AutoCreateSharedArchive", "-Xshare:auto",
            "-cp", classpath, "pilot.JadxEngine",
        ])
    }
}
