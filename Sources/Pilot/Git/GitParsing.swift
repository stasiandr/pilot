import Foundation

// Разбор машинного вывода git. Здесь нет ни процессов, ни AppKit — только
// байты на входе, поэтому всё это проверяется тестами ядра.

/// Что случилось с файлом относительно HEAD — одной буквой в палитре и цветом в дереве.
enum GitFileState: Equatable {
    case modified, added, deleted, renamed, untracked, conflicted

    /// Буквы — как у самого git: `?` неотслеживаемый, `U` — конфликт слияния.
    var letter: String {
        switch self {
        case .modified:   return "M"
        case .added:      return "A"
        case .deleted:    return "D"
        case .renamed:    return "R"
        case .untracked:  return "?"
        case .conflicted: return "U"
        }
    }

    var label: String {
        switch self {
        case .modified:   return L("изменён")
        case .added:      return L("добавлен")
        case .deleted:    return L("удалён")
        case .renamed:    return L("переименован")
        case .untracked:  return L("не отслеживается")
        case .conflicted: return L("конфликт")
        }
    }
}

// MARK: - git status --porcelain=v2

/// Состояние репозитория: ветка и изменённые файлы.
///
/// Формат v2, а не v1: в нём есть хэш HEAD (по нему видно, что сделали
/// коммит и полоски пора пересчитать) и явная пометка отсоединённого HEAD.
struct GitStatus: Equatable {
    /// Хэш HEAD; nil — в репозитории ещё нет коммитов.
    var head: String?
    /// Имя ветки; nil — HEAD отсоединён.
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// Пути от корня репозитория.
    var files: [String: GitFileState] = [:]

    /// Что показать в статус-строке: ветку или короткий хэш.
    var headLabel: String {
        if let branch { return branch }
        if let head { return String(head.prefix(7)) }
        return L("без коммитов")
    }

    /// Вывод `git status --porcelain=v2 -z --branch`.
    static func parse(_ data: Data) -> GitStatus {
        var status = GitStatus()
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }

        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            guard let type = record.first else { continue }
            switch type {
            case "#":
                status.parseHeader(record)
            case "1":
                // 1 XY sub mH mI mW hH hI path — путь может содержать пробелы.
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                status.files[String(fields[8])] = state(xy: fields[1])
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path, следующей записью — старый путь.
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                i += 1
                guard fields.count == 10 else { continue }
                status.files[String(fields[9])] = .renamed
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                status.files[String(fields[10])] = .conflicted
            case "?":
                status.files[String(record.dropFirst(2))] = .untracked
            default:
                continue   // "!" — игнорируемые, их мы не запрашиваем
            }
        }
        return status
    }

    private mutating func parseHeader(_ record: String) {
        let parts = record.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid":      head = value == "(initial)" ? nil : value
        case "branch.head":     branch = value == "(detached)" ? nil : value
        case "branch.upstream": upstream = value
        case "branch.ab":
            // "+1 -2"
            for number in value.split(separator: " ") {
                if number.hasPrefix("+") { ahead = Int(number.dropFirst()) ?? 0 }
                if number.hasPrefix("-") { behind = Int(number.dropFirst()) ?? 0 }
            }
        default: break
        }
    }

    /// XY: X — индекс против HEAD, Y — рабочая копия против индекса.
    /// Нам важно итоговое отличие от HEAD, поэтому индекс и рабочую копию
    /// не различаем: и застейдженное, и нет — просто «изменён».
    private static func state(xy: Substring) -> GitFileState {
        let x = xy.first ?? ".", y = xy.dropFirst().first ?? "."
        if x == "A" { return .added }
        if x == "D" || y == "D" { return .deleted }
        return .modified
    }
}

// MARK: - git blame --porcelain

/// Кто и когда последним трогал каждую строку.
struct GitBlame {
    struct Commit: Equatable {
        var sha: String
        var author = ""
        var time: Date?
        var summary = ""

        /// С `--contents` строки, которых нет в HEAD, приходят с нулевым хэшем.
        var isUncommitted: Bool { sha.allSatisfy { $0 == "0" } }
        var shortSHA: String { String(sha.prefix(7)) }
    }

    var commits: [Commit] = []
    /// Для каждой строки файла — индекс в `commits`, -1 — git о ней не сказал.
    var lineCommits: [Int32] = []

    func commit(atLine line: Int) -> Commit? {
        guard line >= 0, line < lineCommits.count else { return nil }
        let index = Int(lineCommits[line])
        return index >= 0 ? commits[index] : nil
    }

    /// Вывод `git blame --porcelain`. На каждую строку файла — заголовок
    /// «хэш исходная итоговая [сколько]», затем сведения о коммите (только
    /// при первом его появлении) и сама строка после табуляции.
    static func parse(_ data: Data, lineCount: Int) -> GitBlame {
        var blame = GitBlame()
        blame.lineCommits = [Int32](repeating: -1, count: lineCount)
        var indexBySHA: [String: Int] = [:]
        var current = -1
        var expectHeader = true

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            guard let first = line.first else { continue }
            if first == 0x09 {           // \t — содержимое строки, дальше новый заголовок
                expectHeader = true
                continue
            }
            if expectHeader {
                expectHeader = false
                let fields = line.split(separator: 0x20)
                guard fields.count >= 3, fields[0].count == 40 else { current = -1; continue }
                let sha = String(decoding: fields[0], as: UTF8.self)
                if let known = indexBySHA[sha] {
                    current = known
                } else {
                    current = blame.commits.count
                    indexBySHA[sha] = current
                    blame.commits.append(Commit(sha: sha))
                }
                if let final = Int(String(decoding: fields[2], as: UTF8.self)),
                   final >= 1, final <= lineCount {
                    blame.lineCommits[final - 1] = Int32(current)
                }
                continue
            }
            guard current >= 0 else { continue }
            let text = String(decoding: line, as: UTF8.self)
            if let value = text.value(after: "author ") {
                blame.commits[current].author = value
            } else if let value = text.value(after: "author-time "), let seconds = TimeInterval(value) {
                blame.commits[current].time = Date(timeIntervalSince1970: seconds)
            } else if let value = text.value(after: "summary ") {
                blame.commits[current].summary = value
            }
        }
        return blame
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
