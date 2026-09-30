import Foundation

// Разбор для окна истории: коммиты с графом веток, ветки, stash, файлы
// коммита, дифф в две колонки, незаконченные операции. Только строки и
// байты — проверяется тестами ядра.

// MARK: - Коммиты

struct GitCommitInfo: Identifiable, Hashable, Sendable {
    var hash: String
    var parents: [String]
    var author: String
    var email: String
    var date: Date
    /// `HEAD -> main`, `origin/main`, `tag: v1.2`.
    var refs: [String]
    var subject: String

    var id: String { hash }
    var shortHash: String { String(hash.prefix(8)) }
    var isMerge: Bool { parents.count > 1 }

    /// Разделители полей и записей — управляющие символы: в теме коммита
    /// их не бывает, а табуляция и `|` бывают.
    static let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e"

    static func parse(_ data: Data) -> [GitCommitInfo] {
        data.split(separator: 0x1E).compactMap { record in
            var bytes = record[...]
            while bytes.first == 0x0A { bytes = bytes.dropFirst() }
            let fields = bytes.split(separator: 0x1F, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 7, fields[0].count >= 40 else { return nil }
            return GitCommitInfo(
                hash: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                author: fields[2],
                email: fields[3],
                date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                refs: fields[5].isEmpty ? [] : fields[5].components(separatedBy: ", "),
                subject: fields[6])
        }
    }
}

// MARK: - Граф

/// Строка графа: где точка коммита и какие линии идут через строку.
/// Колонки не сдвигаются, когда линия кончается, — вместо этого место
/// освобождается и достаётся следующей новой ветке. Так нет диагоналей
/// через полграфа, как у `git log --graph` на слиянии.
struct GitGraphRow: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var from: Int
        var to: Int
        var color: Int
    }

    var column: Int
    var color: Int
    /// Верхняя половина: от верха строки (колонка `from`) к середине (`to`).
    var top: [Line] = []
    /// Нижняя половина: от середины (`from`) к низу строки (`to`).
    var bottom: [Line] = []

    var width: Int {
        ([column] + top.flatMap { [$0.from, $0.to] } + bottom.flatMap { [$0.from, $0.to] }).max()! + 1
    }
}

/// Раскладка графа по мере подгрузки страниц лога: состояние колонок
/// переносится со страницы на страницу.
struct GitGraphLayout: Sendable {
    /// Какой коммит ждёт каждая колонка; nil — свободна.
    private var lanes: [String?] = []
    private var colors: [Int] = []
    private var nextColor = 0

    mutating func add(_ commit: GitCommitInfo) -> GitGraphRow {
        let before = lanes
        let beforeColors = colors

        var column = lanes.firstIndex(of: commit.hash)
        if column == nil {
            column = freeLane()
            colors[column!] = takeColor()
        }
        let col = column!
        let color = colors[col]
        var row = GitGraphRow(column: col, color: color)

        // Сверху: все линии, что шли в строку. Ждавшие этот коммит сходятся
        // в точку, остальные идут прямо.
        for (i, hash) in before.enumerated() where hash != nil {
            row.top.append(.init(from: i, to: hash == commit.hash ? col : i, color: beforeColors[i]))
        }
        // Другие колонки, ждавшие этот же коммит, на нём кончаются.
        for i in lanes.indices where i != col && lanes[i] == commit.hash { lanes[i] = nil }

        // Первый родитель продолжает колонку, остальные — в колонку, что уже
        // ждёт этого родителя, или в новую.
        lanes[col] = commit.parents.first
        var targets: [(lane: Int, color: Int)] = []
        if !commit.parents.isEmpty { targets.append((col, color)) }
        for parent in commit.parents.dropFirst() {
            if let existing = lanes.firstIndex(where: { $0 == parent }) {
                targets.append((existing, colors[existing]))
            } else {
                let lane = freeLane()
                lanes[lane] = parent
                colors[lane] = takeColor()
                targets.append((lane, colors[lane]))
            }
        }

        // Снизу: из точки — к родителям, остальные занятые колонки — прямо.
        for target in targets {
            row.bottom.append(.init(from: col, to: target.lane, color: target.color))
        }
        for (i, hash) in lanes.enumerated() where hash != nil && !targets.contains(where: { $0.lane == i }) {
            // Прямо идут только те, что были и сверху; новых не бывает.
            if i < before.count, before[i] != nil {
                row.bottom.append(.init(from: i, to: i, color: colors[i]))
            }
        }
        while lanes.last == .some(nil) {
            lanes.removeLast()
            colors.removeLast()
        }
        return row
    }

    private mutating func freeLane() -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
        lanes.append(nil)
        colors.append(0)
        return lanes.count - 1
    }

    private mutating func takeColor() -> Int {
        defer { nextColor += 1 }
        return nextColor
    }
}

// MARK: - Ветки

struct GitBranch: Identifiable, Hashable, Sendable {
    /// `main` или `origin/main`.
    var name: String
    var isRemote: Bool
    var isCurrent: Bool
    var hash: String
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// Upstream был, а на сервере ветку удалили.
    var upstreamGone = false
    var date: Date
    var subject: String

    var id: String { (isRemote ? "remote/" : "local/") + name }
    /// Для `origin/feature/x` — `feature/x`: имя, под которым её берут локально.
    var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    static let format = "--format=%(refname)%1f%(objectname)%1f%(upstream:short)%1f%(upstream:track)%1f%(committerdate:unix)%1f%(HEAD)%1f%(subject)%1e"

    /// Вывод `git for-each-ref <format> refs/heads refs/remotes`.
    static func parse(_ data: Data) -> [GitBranch] {
        data.split(separator: 0x1E).compactMap { record in
            var bytes = record[...]
            while bytes.first == 0x0A { bytes = bytes.dropFirst() }
            let f = bytes.split(separator: 0x1F, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard f.count >= 7 else { return nil }
            let ref = f[0]
            let isRemote = ref.hasPrefix("refs/remotes/")
            let name = String(ref.dropFirst(isRemote ? "refs/remotes/".count : "refs/heads/".count))
            // `origin/HEAD` — указатель, а не ветка.
            if isRemote && name.hasSuffix("/HEAD") { return nil }
            var branch = GitBranch(name: name, isRemote: isRemote, isCurrent: f[5] == "*", hash: f[1],
                                   upstream: f[2].isEmpty ? nil : f[2],
                                   date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0), subject: f[6])
            // `[ahead 2, behind 1]`, `[gone]`.
            let track = f[3].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            for part in track.components(separatedBy: ", ") {
                let words = part.split(separator: " ")
                if words.first == "ahead", words.count == 2 { branch.ahead = Int(words[1]) ?? 0 }
                if words.first == "behind", words.count == 2 { branch.behind = Int(words[1]) ?? 0 }
                if part == "gone" { branch.upstreamGone = true }
            }
            return branch
        }
    }

    /// Можно ли так назвать ветку — то же, что проверяет `git check-ref-format --branch`,
    /// без процесса: имя набирают в палитре, и ответ нужен на каждую букву.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("//"),
              !name.contains("@{") else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
        if name.unicodeScalars.contains(where: { forbidden.contains($0) }) { return false }
        return !name.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

// MARK: - Stash

struct GitStash: Identifiable, Hashable, Sendable {
    /// `stash@{0}`.
    var ref: String
    var hash: String
    var date: Date
    /// `On main: сообщение` или `WIP on main: abc123 тема`.
    var message: String

    var id: String { hash }

    static let format = "--format=%gd%x1f%H%x1f%ct%x1f%gs%x1e"

    static func parse(_ data: Data) -> [GitStash] {
        data.split(separator: 0x1E).compactMap { record in
            var bytes = record[...]
            while bytes.first == 0x0A { bytes = bytes.dropFirst() }
            let f = bytes.split(separator: 0x1F, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard f.count >= 4 else { return nil }
            return GitStash(ref: f[0], hash: f[1], date: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0),
                            message: f[3])
        }
    }
}

// MARK: - Файлы коммита

/// Файл в сравнении двух версий: `git diff --name-status -z -M`.
struct GitChangedFile: Identifiable, Hashable, Sendable {
    var path: String
    var originalPath: String?
    var kind: GitChange.Kind

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    static func parse(_ data: Data) -> [GitChangedFile] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var result: [GitChangedFile] = []
        var i = 0
        while i < fields.count {
            let status = fields[i]
            i += 1
            guard let letter = status.first else { continue }
            let kind: GitChange.Kind
            switch letter {
            case "A": kind = .added
            case "D": kind = .deleted
            case "R", "C": kind = .renamed
            case "T": kind = .typeChanged
            default: kind = .modified
            }
            if letter == "R" || letter == "C" {
                guard i + 1 < fields.count else { break }
                result.append(GitChangedFile(path: fields[i + 1], originalPath: fields[i], kind: kind))
                i += 2
            } else {
                guard i < fields.count else { break }
                result.append(GitChangedFile(path: fields[i], kind: kind))
                i += 1
            }
        }
        return result
    }
}

// MARK: - Дифф в две колонки

/// Строка сравнения в две колонки: слева старая версия, справа новая.
/// Удалённые и добавленные подряд строки встают напротив друг друга —
/// так изменённая строка видна одной парой, а не двумя блоками.
struct SideBySideRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, changed, removed, added, separator }

    var kind: Kind
    var oldNumber: Int?
    var old: String?
    var newNumber: Int?
    var new: String?

    static func rows(_ patch: GitFilePatch) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        for (index, hunk) in patch.hunks.enumerated() {
            if index > 0 { rows.append(SideBySideRow(kind: .separator)) }
            var oldLine = hunk.oldStart, newLine = hunk.newStart
            var removed: [(Int, String)] = [], added: [(Int, String)] = []
            func flush() {
                for k in 0..<max(removed.count, added.count) {
                    let r = k < removed.count ? removed[k] : nil
                    let a = k < added.count ? added[k] : nil
                    let kind: Kind = r != nil && a != nil ? .changed : (r != nil ? .removed : .added)
                    rows.append(SideBySideRow(kind: kind, oldNumber: r?.0, old: r?.1, newNumber: a?.0, new: a?.1))
                }
                removed = []
                added = []
            }
            for line in hunk.lines {
                switch line.first {
                case "-":
                    removed.append((oldLine, String(line.dropFirst()))); oldLine += 1
                case "+":
                    added.append((newLine, String(line.dropFirst()))); newLine += 1
                case "\\":
                    continue
                default:
                    flush()
                    let text = String(line.dropFirst())
                    rows.append(SideBySideRow(kind: .context, oldNumber: oldLine, old: text, newNumber: newLine, new: text))
                    oldLine += 1; newLine += 1
                }
            }
            flush()
        }
        return rows
    }
}

// MARK: - Незаконченная операция

/// Что git делает и ждёт от человека: слияние с конфликтами, rebase,
/// cherry-pick, revert. Видно по файлам в каталоге `.git`.
enum GitOperation: Equatable, Sendable {
    case merge, rebase, cherryPick, revert

    var title: String {
        switch self {
        case .merge: return L("Идёт слияние")
        case .rebase: return L("Идёт rebase")
        case .cherryPick: return L("Идёт cherry-pick")
        case .revert: return L("Идёт revert")
        }
    }

    /// Команда для «Продолжить»/«Прервать».
    var command: String {
        switch self {
        case .merge: return "merge"
        case .rebase: return "rebase"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        }
    }

    static func current(gitDirectory: URL) -> GitOperation? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDirectory.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }
}

// MARK: - Интерактивный rebase

struct RebaseStep: Identifiable, Hashable, Sendable {
    enum Action: String, CaseIterable, Sendable {
        case pick, reword, squash, fixup, drop

        var key: Character {
            switch self {
            case .pick: return "p"
            case .reword: return "r"
            case .squash: return "s"
            case .fixup: return "f"
            case .drop: return "d"
            }
        }
    }

    var commit: GitCommitInfo
    var action: Action = .pick
    /// Новое сообщение для reword.
    var message: String?

    var id: String { commit.hash }

    /// Список для `GIT_SEQUENCE_EDITOR`. Новое сообщение reword — не через
    /// редактор (его нет), а `exec git commit --amend -F файл` сразу после
    /// pick. Файлы сообщений пишет вызывающий: `messageFile(i)` — путь для
    /// шага `i`.
    static func todo(_ steps: [RebaseStep], messageFile: (Int) -> String) -> String {
        var lines: [String] = []
        for (i, step) in steps.enumerated() {
            switch step.action {
            case .drop:
                lines.append("drop \(step.commit.hash)")
            case .reword:
                lines.append("pick \(step.commit.hash)")
                lines.append("exec git commit --amend --allow-empty --no-verify -q -F \(shellQuote(messageFile(i)))")
            default:
                lines.append("\(step.action.rawValue) \(step.commit.hash)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Первый шаг не может быть squash или fixup — не с чем сливать.
    static func problem(_ steps: [RebaseStep]) -> String? {
        guard let first = steps.first(where: { $0.action != .drop }) else {
            return L("Все коммиты выброшены — ветка станет пустой")
        }
        if first.action == .squash || first.action == .fixup {
            return L("Первый оставшийся коммит нельзя слить с предыдущим")
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
