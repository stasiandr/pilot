import Foundation

/// Два проекта, которые живут парой: например, клиент и сервер одного
/// продукта в разных репозиториях, у которых часть типов и договорённостей
/// продублирована и меняется вместе. Pilot знает пару и ходит между её
/// половинами: к двойнику типа, поиском и ⌘R по обеим. Что ещё у пары общего
/// (сетевые структуры, конфиги, зеркальные папки), говорят правила
/// расширения проекта — `ProjectRules`.
///
/// Пара узнаётся сама — по соседним папкам `имя-client` и `имя-server`
/// (и окончаниям из расширения), — или связывается руками (меню «Пара»). Связь хранится в настройках по
/// путям обоих корней; пустая строка — «пары нет», даже если соседи по имени
/// подходят.
///
/// Без AppKit: тип проверяется тестами ядра.
enum ProjectPair {
    static let linksKey = "pilot.pairs"

    /// Окончания имён, по которым половины пары узнают друг друга.
    static let suffixes: [(String, String)] = [
        ("-client", "-server"), ("_client", "_server"), (".client", ".server"),
        ("-Client", "-Server"), ("_Client", "_Server"), (".Client", ".Server"),
        ("Client", "Server"),
    ]

    /// Второй проект пары или nil. `extra` — окончания из расширения,
    /// `isDirectory` — есть ли такая папка.
    static func partner(of root: URL, links: [String: String], extra: [PairRules.Suffixes] = [],
                        isDirectory: (String) -> Bool) -> URL? {
        if let linked = links[root.path] {
            guard !linked.isEmpty, isDirectory(linked) else { return nil }
            return URL(fileURLWithPath: linked)
        }
        let name = root.lastPathComponent
        let parent = root.deletingLastPathComponent()
        for (first, second) in suffixes + extra.map({ ($0.first, $0.second) }) {
            for (from, to) in [(first, second), (second, first)]
            where name.hasSuffix(from) && name.count > from.count {
                let other = parent.appendingPathComponent(String(name.dropLast(from.count)) + to)
                if isDirectory(other.path) { return other }
            }
        }
        return nil
    }

    /// Короткая подпись половины: `client`, `server`; без узнаваемого
    /// окончания — имя папки.
    static func label(of root: URL) -> String {
        let name = root.lastPathComponent
        for (first, second) in suffixes {
            for suffix in [first, second] where name.hasSuffix(suffix) && name.count > suffix.count {
                return suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-_.")).lowercased()
            }
        }
        return name
    }

    /// Связать два корня. Прежние пары обоих разрываются: у проекта одна пара.
    static func linking(_ a: URL, _ b: URL, in links: [String: String]) -> [String: String] {
        var result = links
        for root in [a.path, b.path] {
            if let old = result[root], !old.isEmpty, old != a.path, old != b.path {
                result[old] = nil
            }
        }
        result[a.path] = b.path
        result[b.path] = a.path
        return result
    }

    /// Разорвать пару: обе половины запоминают «пары нет», иначе соседи по
    /// имени тут же сложились бы в неё снова.
    static func unlinking(_ root: URL, partner: URL?, in links: [String: String]) -> [String: String] {
        var result = links
        result[root.path] = ""
        if let partner { result[partner.path] = "" }
        return result
    }
}
