import Foundation

// Разбор для окна коммита: что подготовлено, что нет, и дифф по кускам,
// из которых собирается патч для `git apply --cached`. Только байты и
// строки — проверяется тестами ядра.

/// Файл, который попадёт или может попасть в коммит.
struct GitChange: Identifiable, Hashable {
    enum Kind: Hashable {
        case modified, added, deleted, renamed, typeChanged

        var letter: String {
            switch self {
            case .modified: return "M"
            case .added: return "A"
            case .deleted: return "D"
            case .renamed: return "R"
            case .typeChanged: return "T"
            }
        }
    }

    /// От корня репозитория.
    var path: String
    /// Откуда переименован.
    var originalPath: String?
    /// Что подготовлено к коммиту (индекс против HEAD); nil — ничего.
    var staged: Kind?
    /// Что в рабочей копии сверх индекса; nil — ничего.
    var unstaged: Kind?
    var isUntracked = false
    var isConflicted = false

    var id: String { path }
    var hasStaged: Bool { staged != nil }
    var hasUnstaged: Bool { unstaged != nil || isUntracked || isConflicted }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Рабочая копия для окна коммита: ветка и файлы с разделением на
/// подготовленное и нет — то, что `GitStatus` для полосок сливает в одно.
struct GitWorkingTree: Equatable {
    var branch: String?
    var head: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [GitChange] = []

    var staged: [GitChange] { changes.filter(\.hasStaged) }
    var unstaged: [GitChange] { changes.filter(\.hasUnstaged) }

    /// Вывод `git status --porcelain=v2 -z --branch --untracked-files=all`.
    static func parse(_ data: Data) -> GitWorkingTree {
        let status = GitStatus.parse(data)
        var tree = GitWorkingTree(branch: status.branch, head: status.head, upstream: status.upstream,
                                  ahead: status.ahead, behind: status.behind)
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            guard let type = record.first else { continue }
            switch type {
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                let (x, y) = kinds(fields[1])
                tree.changes.append(GitChange(path: String(fields[8]), staged: x, unstaged: y))
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = i < records.count ? records[i] : nil
                i += 1
                guard fields.count == 10 else { continue }
                let (x, y) = kinds(fields[1])
                tree.changes.append(GitChange(path: String(fields[9]), originalPath: original, staged: x, unstaged: y))
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                tree.changes.append(GitChange(path: String(fields[10]), isConflicted: true))
            case "?":
                tree.changes.append(GitChange(path: String(record.dropFirst(2)), isUntracked: true))
            default:
                continue
            }
        }
        tree.changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return tree
    }

    private static func kinds(_ xy: Substring) -> (GitChange.Kind?, GitChange.Kind?) {
        func kind(_ c: Character?) -> GitChange.Kind? {
            switch c {
            case "M": return .modified
            case "A": return .added
            case "D": return .deleted
            case "R", "C": return .renamed
            case "T": return .typeChanged
            default: return nil
            }
        }
        return (kind(xy.first), kind(xy.dropFirst().first))
    }
}

// MARK: - Дифф по кускам

/// `git diff` одного файла: шапка и куски. Из куска собирается патч,
/// который `git apply --cached` применяет к индексу, — так кусок
/// подготавливается к коммиту отдельно от остальных.
struct GitFilePatch: Equatable {
    struct Hunk: Equatable, Identifiable {
        /// `@@ -12,5 +12,6 @@ func foo()`.
        var header: String
        /// Строки с маркерами ` `, `-`, `+` и `\ No newline at end of file`.
        var lines: [String]
        var oldStart: Int
        var newStart: Int

        var id: String { header + "#\(oldStart)" }
        var additions: Int { lines.filter { $0.hasPrefix("+") }.count }
        var deletions: Int { lines.filter { $0.hasPrefix("-") }.count }
    }

    /// `diff --git …`, `index …`, `--- a/…`, `+++ b/…` и прочее до первого куска.
    var header: [String] = []
    var hunks: [Hunk] = []
    /// Двоичный файл: куски не показать и не применить по одному.
    var isBinary = false

    /// Вывод `git diff` для одного файла; для нескольких — первый.
    static func parse(_ text: String) -> GitFilePatch {
        var patch = GitFilePatch()
        var current: Hunk?
        var seenFile = false
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                if seenFile { break }
                seenFile = true
            }
            if raw.hasPrefix("@@") {
                if let current { patch.hunks.append(current) }
                let (old, new) = hunkStarts(raw)
                current = Hunk(header: raw, lines: [], oldStart: old, newStart: new)
            } else if current != nil {
                if raw.hasPrefix(" ") || raw.hasPrefix("+") || raw.hasPrefix("-") || raw.hasPrefix("\\") {
                    current!.lines.append(raw)
                }
            } else if !raw.isEmpty {
                if raw.hasPrefix("Binary files ") || raw == "GIT binary patch" { patch.isBinary = true }
                patch.header.append(raw)
            }
        }
        if let current { patch.hunks.append(current) }
        return patch
    }

    /// Патч из одного куска — для `git apply --cached` (или `-R`).
    func patch(for hunk: Hunk) -> String {
        (header + [hunk.header] + hunk.lines).joined(separator: "\n") + "\n"
    }

    /// `@@ -12,5 +12,6 @@` → (12, 12).
    static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start("-"), start("+"))
    }
}

/// Сообщение коммита: git сам выбросит строки-комментарии и хвостовые
/// пробелы, но пустое сообщение — отказ, а первая строка длиннее ~72
/// символов плохо читается в `git log --oneline` и в GitLab.
enum CommitMessage {
    static let summaryLimit = 72

    static func summary(_ message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    static func isEmpty(_ message: String) -> Bool {
        message.split(separator: "\n").allSatisfy { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.hasPrefix("#")
        }
    }
}
