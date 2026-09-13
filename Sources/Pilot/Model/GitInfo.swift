import Foundation

/// Текущая ветка git — для подзаголовка окна, как в Xcode.
///
/// HEAD читается напрямую: запускать git ради одной строки — лишние
/// десятки миллисекунд на старте. Папка проекта может лежать внутри
/// репозитория, поэтому .git ищется вверх по дереву.
enum GitInfo {

    static func branch(at root: URL) -> String? {
        var path = root.standardizedFileURL.path
        while true {
            if let head = readHead(in: path) { return parse(head: head) }
            if path == "/" || path.isEmpty { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    private static func readHead(in directory: String) -> String? {
        let dotGit = (directory as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }

        var gitDir = dotGit
        if !isDirectory.boolValue {
            // Worktree или сабмодуль: в файле .git лежит «gitdir: <путь>».
            guard let link = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  link.hasPrefix("gitdir:") else { return nil }
            let target = link.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/") ? target : (directory as NSString).appendingPathComponent(target)
        }
        return try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"),
                           encoding: .utf8)
    }

    /// «ref: refs/heads/main» → «main»; отсоединённый HEAD — короткий хэш.
    static func parse(head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: ") {
            let ref = line.dropFirst("ref: ".count)
            let prefix = "refs/heads/"
            return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : String(ref)
        }
        return line.isEmpty ? nil : String(line.prefix(7))
    }
}
