import Foundation
import CryptoKit

/// Версия файла из git — файлом на диске, чтобы её показал тот же
/// просмотрщик, что и рабочую копию: картинку, модель, шрифт, PDF.
///
/// Файл лежит во временной папке под своим именем — просмотрщик узнаёт
/// формат по расширению. Файл в Git LFS в git хранится указателем;
/// его содержимое достаёт `git lfs smudge` (из локального кэша LFS, а
/// если там нет — с сервера).
enum GitBlobs {
    /// Где версия: в коммите, в индексе, в стадии слияния или на диске.
    enum Revision: Hashable, Sendable {
        case commit(String)
        /// `:путь` — подготовленное.
        case index
        /// `:1:путь` — предок, `:2:` — наша, `:3:` — их (при конфликте).
        case stage(Int)
        case workingTree
        /// Версии нет: файл добавлен (до) или удалён (после).
        case none

        var spec: String? {
            switch self {
            case .none: return nil
            case .commit(let hash): return hash + ":"
            case .index: return ":"
            case .stage(let n): return ":\(n):"
            case .workingTree: return nil
            }
        }
    }

    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-blobs", isDirectory: true)

    /// Файл с версией. nil — такой версии нет (файл добавлен или удалён).
    /// Синхронно — только из фона: git, а для LFS и сеть.
    static func file(_ path: String, at revision: Revision, in repository: URL) -> URL? {
        if revision == .none { return nil }
        guard let spec = revision.spec else {
            let url = repository.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard let output = Git.run(["cat-file", "blob", spec + path], in: repository), output.status == 0 else { return nil }
        var data = output.stdout
        if isLFSPointer(data), let real = smudge(data: data, path: path, repository: repository) { data = real }
        let key = SHA256.hash(data: Data((repository.path + "\n" + spec + path).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        let url = folder.appendingPathComponent((path as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    /// Указатель LFS: несколько строк текста, начиная с `version https://git-lfs`.
    static func isLFSPointer(_ data: Data) -> Bool {
        data.count < 1024 && data.starts(with: Data("version https://git-lfs".utf8))
    }

    /// `git lfs smudge`: указатель на входе, файл на выходе — байтами
    /// (Git.execute отдаёт текст, двоичное он бы испортил).
    private static func smudge(data: Data, path: String, repository: URL) -> Data? {
        guard let executable = Git.executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["lfs", "smudge", "--", path]
        process.currentDirectoryURL = repository
        process.environment = Git.environment()
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().async {
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? result : nil
    }
}
