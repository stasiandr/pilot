import Foundation

/// Запрос к списку мерж-реквестов.
///
/// По загруженному списку открытых MR ищет мгновенно: каждое слово запроса
/// должно найтись в заголовке, номере, людях, ветке или метках. То, чего в
/// списке нет, — слитые, закрытые, найденные по описанию — ищет GitLab
/// (`apiSearch`, `apiAuthor`, `iid`).
///
/// * `!123`, `#123`, `123` — номер MR;
/// * `@ada` — автор, ревьюер или ответственный с таким логином.
struct MergeRequestSearch: Equatable, Sendable {
    private struct Word: Equatable, Sendable {
        var text: String
        var isUser: Bool
        /// `!123` — только номер, а не «123» где-то в заголовке.
        var isReference: Bool
    }

    private let words: [Word]
    /// Номер MR, если запрос — одно число.
    let iid: Int?
    /// Текст для `search=` в API: без `@логинов` и `!номеров`, регистр как ввели.
    let apiSearch: String
    /// Первый `@логин` — для `author_username=`.
    let apiAuthor: String?

    init(_ query: String) {
        let raw = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var words: [Word] = []
        var plain: [String] = []
        var author: String?
        for token in raw {
            if token.hasPrefix("@"), token.count > 1 {
                let login = String(token.dropFirst())
                words.append(Word(text: Self.fold(login), isUser: true, isReference: false))
                if author == nil { author = login }
            } else if let first = token.first, first == "!" || first == "#", Int(token.dropFirst()) != nil {
                words.append(Word(text: String(token.dropFirst()), isUser: false, isReference: true))
            } else {
                words.append(Word(text: Self.fold(token), isUser: false, isReference: false))
                plain.append(token)
            }
        }
        self.words = words
        apiSearch = plain.joined(separator: " ")
        apiAuthor = author
        if words.count == 1, let only = words.first, !only.isUser { iid = Int(only.text) } else { iid = nil }
    }

    var isEmpty: Bool { words.isEmpty }

    /// Стоит ли спрашивать GitLab: одна-две буквы находят всё подряд.
    var wantsServer: Bool { iid != nil || apiAuthor != nil || apiSearch.count >= 2 }

    /// Регистр, ударения и «ё» не важны.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Насколько MR подходит: 3 — это он по номеру, 2 — все слова в заголовке,
    /// 1 — слова нашлись где-то ещё; `nil` — не подходит.
    func score(_ mr: GLMergeRequest) -> Int? {
        guard !words.isEmpty else { return 0 }
        if let iid, mr.iid == iid { return 3 }
        let title = Self.fold(mr.title)
        let people = [mr.author] + (mr.reviewers ?? []) + (mr.assignees ?? [])
        let logins = people.map { Self.fold($0.username) }
        // Целевую ветку не смотрим: «dev» иначе нашёл бы всё, что вливается в develop.
        let other = (people.map { Self.fold($0.name) } + logins
                     + [Self.fold(mr.sourceBranch)] + (mr.labels ?? []).map(Self.fold))
        var allInTitle = true
        for word in words {
            if word.isReference {
                guard String(mr.iid) == word.text else { return nil }
                continue
            }
            if word.isUser {
                guard logins.contains(where: { $0.hasPrefix(word.text) }) else { return nil }
                continue
            }
            if title.contains(word.text) { continue }
            allInTitle = false
            guard String(mr.iid) == word.text || other.contains(where: { $0.contains(word.text) }) else { return nil }
        }
        return allInTitle ? 2 : 1
    }

    /// Подходящие MR: сначала лучшие, при равенстве — в исходном порядке
    /// (список приходит свежими сверху).
    func filter(_ list: [GLMergeRequest]) -> [GLMergeRequest] {
        guard !words.isEmpty else { return list }
        return list.enumerated()
            .compactMap { index, mr in score(mr).map { (index, $0, mr) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
    }
}
