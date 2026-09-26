import Foundation
import CryptoKit

/// Языковой сервер Copilot — нативный бинарник GitHub из npm
/// (`@github/copilot-language-server-darwin-*`, MIT). В бандл его не кладём:
/// он весит 120 МБ, а нужен не всем. Скачивается, когда Copilot включают в
/// настройках, — закреплённая версия, со сверкой SHA-512 из реестра npm.
enum CopilotInstaller {
    static let version = "1.551.0"

    private struct Package {
        let arch: String
        let integrity: String
    }

    private static var package: Package {
        #if arch(arm64)
        Package(arch: "arm64",
                integrity: "c+RzG7KDdlJdeNYGRtByQJUPh/Rkg8Uun/ftgjCPy2qfQ9TereOsvemTGxaPptgdjf0EtkhM6/Em+LiMZ0maiQ==")
        #else
        Package(arch: "x64",
                integrity: "MloGSJH524TvChZqP1veQmxmOsaMgRGEEepKxdifMganDwC+6SHDHxLVy62yBXyFRicUNzjlXWNswTY6EAjgfg==")
        #endif
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pilot/Copilot/\(version)", isDirectory: true)
    }

    static var executable: URL { directory.appendingPathComponent("copilot-language-server") }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    enum Failure: LocalizedError {
        case download(String)
        case checksum
        case unpack

        var errorDescription: String? {
            switch self {
            case .download(let why): return L("Не удалось скачать сервер Copilot: \(why)")
            case .checksum: return L("Сервер Copilot скачался с другой контрольной суммой — не запускаю")
            case .unpack: return L("Не удалось распаковать сервер Copilot")
            }
        }
    }

    /// Скачать и распаковать. `progress` — доля от 0 до 1, с главного потока.
    static func install(progress: @escaping @MainActor (Double) -> Void) async throws {
        let name = "copilot-language-server-darwin-\(package.arch)"
        let url = URL(string: "https://registry.npmjs.org/@github/\(name)/-/\(name)-\(version).tgz")!

        let (archive, response) = try await download(url, progress: progress)
        defer { try? FileManager.default.removeItem(at: archive) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.download("HTTP \(http.statusCode)")
        }

        // Сверка — до распаковки: чужой архив не должен даже раскрыться.
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard Data(SHA512.hash(data: data)).base64EncodedString() == package.integrity else {
            throw Failure.checksum
        }

        let fm = FileManager.default
        let unpacked = fm.temporaryDirectory.appendingPathComponent("pilot-copilot-\(UUID().uuidString)")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: unpacked) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", unpacked.path]
        try tar.run()
        tar.waitUntilExit()
        let binary = unpacked.appendingPathComponent("package/copilot-language-server")
        guard tar.terminationStatus == 0, fm.fileExists(atPath: binary.path) else { throw Failure.unpack }

        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.moveItem(at: binary, to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private static func download(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> (URL, URLResponse) {
        let delegate = ProgressDelegate(progress: progress)
        do {
            return try await URLSession.shared.download(from: url, delegate: delegate)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @MainActor (Double) -> Void
        init(progress: @escaping @MainActor (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let report = progress
            Task { @MainActor in report(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }
}
