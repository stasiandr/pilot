import Foundation

/// Вариант автодополнения. Один тип и для ответа языкового сервера,
/// и для запасного дополнения по словам файла.
struct CompletionItem: Equatable {
    var label: String
    /// CompletionItemKind из LSP: 2 — метод, 7 — класс, 14 — ключевое слово…
    var kind: Int = 1
    /// Сигнатура или тип — показывается приглушённо справа.
    var detail: String?
    var filterText: String?
    var sortText: String?
    /// Что вставить, если сервер не прислал точную правку.
    var insertText: String?
    var isSnippet = false
    /// Точная правка от сервера: что и где заменить.
    var edit: TextEdit?
    /// Сопутствующие правки: например, `using` в начале файла.
    var additionalEdits: [TextEdit] = []

    struct TextEdit: Equatable {
        var range: LSPRange
        var newText: String
    }

    /// По чему фильтруем набранное.
    var matchText: String { filterText ?? label }
    /// Текст, который окажется в документе (до раскрытия сниппета).
    var textToInsert: String { edit?.newText ?? insertText ?? label }
}

struct CompletionList {
    var items: [CompletionItem]
    /// Сервер прислал не всё: при следующей букве его надо спросить заново,
    /// а не фильтровать то, что есть.
    var isIncomplete = false
}

// MARK: - Разбор ответа сервера

extension CompletionList {

    /// `textDocument/completion` отвечает либо массивом, либо CompletionList;
    /// в LSP 3.17 общие для всех вариантов поля вынесены в `itemDefaults`.
    static func parse(_ value: Any) -> CompletionList {
        var rawItems: [[String: Any]] = []
        var incomplete = false
        var defaults: [String: Any] = [:]

        if let array = value as? [[String: Any]] {
            rawItems = array
        } else if let object = value as? [String: Any] {
            rawItems = object["items"] as? [[String: Any]] ?? []
            incomplete = object["isIncomplete"] as? Bool ?? false
            defaults = object["itemDefaults"] as? [String: Any] ?? [:]
        }

        let defaultRange = defaults["editRange"].flatMap(parseEditRange)
        let defaultFormat = defaults["insertTextFormat"] as? Int

        let items = rawItems.compactMap { raw -> CompletionItem? in
            guard let label = raw["label"] as? String else { return nil }
            var item = CompletionItem(label: label)
            item.kind = raw["kind"] as? Int ?? 1
            item.detail = (raw["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ((raw["labelDetails"] as? [String: Any])?["description"] as? String)
            item.filterText = raw["filterText"] as? String
            item.sortText = raw["sortText"] as? String
            item.insertText = raw["insertText"] as? String
            item.isSnippet = (raw["insertTextFormat"] as? Int ?? defaultFormat) == 2

            if let textEdit = raw["textEdit"] as? [String: Any],
               let newText = textEdit["newText"] as? String,
               let range = parseEditRange(textEdit) {
                item.edit = CompletionItem.TextEdit(range: range, newText: newText)
            } else if let range = defaultRange {
                let newText = raw["textEditText"] as? String ?? item.insertText ?? label
                item.edit = CompletionItem.TextEdit(range: range, newText: newText)
            }
            item.additionalEdits = (raw["additionalTextEdits"] as? [[String: Any]] ?? []).compactMap { edit in
                guard let newText = edit["newText"] as? String,
                      let range = (edit["range"] as? [String: Any]).flatMap(LSPRange.parse) else { return nil }
                return CompletionItem.TextEdit(range: range, newText: newText)
            }
            return item
        }
        return CompletionList(items: items, isIncomplete: incomplete)
    }

    /// Обычная правка — `range`; InsertReplaceEdit — `insert`/`replace`.
    /// Берём `insert`: он не съедает хвост слова справа от курсора.
    private static func parseEditRange(_ value: Any) -> LSPRange? {
        guard let object = value as? [String: Any] else { return nil }
        if let range = (object["range"] as? [String: Any]).flatMap(LSPRange.parse) { return range }
        if let insert = (object["insert"] as? [String: Any]).flatMap(LSPRange.parse) { return insert }
        return LSPRange.parse(object)   // itemDefaults.editRange бывает голым Range
    }
}

extension LSPRange {
    static func parse(_ object: [String: Any]) -> LSPRange? {
        guard let start = object["start"] as? [String: Any],
              let end = object["end"] as? [String: Any],
              let sl = start["line"] as? Int, let sc = start["character"] as? Int,
              let el = end["line"] as? Int, let ec = end["character"] as? Int else { return nil }
        return LSPRange(start: LSPPosition(line: sl, character: sc),
                        end: LSPPosition(line: el, character: ec))
    }
}

// MARK: - Сниппеты

/// Сниппеты LSP (`foo(${1:bar}, $0)`) превращаются в обычный текст.
/// Первое поле ввода запоминается, чтобы после вставки его выделить:
/// начал печатать — и заглушка заменилась, как в Xcode.
enum Snippet {
    struct Expansion: Equatable {
        var text: String
        /// Что выделить после вставки — в UTF-16 внутри `text`.
        var selection: NSRange?
    }

    static func expand(_ snippet: String) -> Expansion {
        let units = Array(snippet.utf16)
        var out: [UInt16] = []
        // Поля: номер → диапазон в `out`. $0 — финальная позиция курсора.
        var fields: [Int: NSRange] = [:]
        var stack: [(number: Int, start: Int)] = []
        var i = 0

        func readNumber() -> Int? {
            var value = 0, digits = 0
            while i < units.count, units[i] >= 0x30, units[i] <= 0x39 {
                value = value * 10 + Int(units[i] - 0x30); i += 1; digits += 1
            }
            return digits > 0 ? value : nil
        }
        func record(_ number: Int, _ range: NSRange) {
            if fields[number] == nil { fields[number] = range }
        }

        while i < units.count {
            let c = units[i]
            if c == 0x5C, i + 1 < units.count {                        // \$ \} \\
                out.append(units[i + 1]); i += 2; continue
            }
            if c == 0x24, i + 1 < units.count {                        // $
                let next = units[i + 1]
                if next >= 0x30 && next <= 0x39 {                      // $1
                    i += 1
                    if let n = readNumber() { record(n, NSRange(location: out.count, length: 0)) }
                    continue
                }
                if next == 0x7B {                                      // ${
                    let save = i
                    i += 2
                    if let n = readNumber() {
                        if i < units.count, units[i] == 0x3A {         // ${1:заглушка
                            i += 1
                            stack.append((n, out.count))
                            continue
                        }
                        if i < units.count, units[i] == 0x7C {         // ${1|a,b|} — берём первый
                            i += 1
                            let start = out.count
                            while i < units.count, units[i] != 0x2C, units[i] != 0x7C { out.append(units[i]); i += 1 }
                            while i < units.count, units[i] != 0x7D { i += 1 }
                            i += 1
                            record(n, NSRange(location: start, length: out.count - start))
                            continue
                        }
                        if i < units.count, units[i] == 0x7D {         // ${1}
                            i += 1
                            record(n, NSRange(location: out.count, length: 0))
                            continue
                        }
                    }
                    // Переменная (${TM_FILENAME}) или мусор: выбрасываем до «}».
                    i = save + 2
                    var depth = 1
                    while i < units.count, depth > 0 {
                        if units[i] == 0x7B { depth += 1 } else if units[i] == 0x7D { depth -= 1 }
                        i += 1
                    }
                    continue
                }
            }
            if c == 0x7D, let open = stack.popLast() {                 // конец ${1:…}
                record(open.number, NSRange(location: open.start, length: out.count - open.start))
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }

        let firstField = fields.keys.filter { $0 > 0 }.min()
        let selection = firstField.flatMap { fields[$0] } ?? fields[0]
        return Expansion(text: String(decoding: out, as: UTF16.self), selection: selection)
    }
}

// MARK: - Ранжирование

/// Фильтр набранного префикса по вариантам. Сервер уже отсортировал их по
/// смыслу (sortText), мы лишь отсекаем неподходящее и поднимаем точные
/// попадания: префикс с учётом регистра, без него, затем «горбы» и
/// подпоследовательность — `gTD` находит `getTextDocument`.
enum CompletionRanking {

    static func rank(_ items: [CompletionItem], prefix: String) -> [Int] {
        let query = Array(prefix.utf16)
        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard let score = score(Array(item.matchText.utf16), query) else { continue }
            scored.append((index, score))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let sa = items[a.index].sortText ?? items[a.index].label
            let sb = items[b.index].sortText ?? items[b.index].label
            if sa != sb { return sa < sb }
            return items[a.index].label.utf16.count < items[b.index].label.utf16.count
        }
        return scored.map(\.index)
    }

    /// nil — не подходит. Чем больше, тем выше в списке.
    static func score(_ text: [UInt16], _ query: [UInt16]) -> Int? {
        if query.isEmpty { return 0 }
        if text.count >= query.count && Array(text.prefix(query.count)) == query {
            return 1000 - (text.count - query.count)
        }
        let lowerText = text.map(lower), lowerQuery = query.map(lower)
        if lowerText.count >= lowerQuery.count && Array(lowerText.prefix(lowerQuery.count)) == lowerQuery {
            return 800 - (text.count - query.count)
        }
        // Подпоследовательность; начало слова и заглавные буквы — в плюс.
        var ti = 0, bonus = 0
        for (qi, q) in lowerQuery.enumerated() {
            var found = false
            while ti < lowerText.count {
                defer { ti += 1 }
                guard lowerText[ti] == q else { continue }
                let boundary = ti == 0 || isUpper(text[ti]) || text[ti - 1] == 0x5F
                if qi == 0 && ti != 0 && !boundary { continue }   // первая буква — только с начала слова
                if boundary { bonus += 10 }
                found = true
                break
            }
            if !found { return nil }
        }
        return 100 + bonus - text.count
    }

    @inline(__always) private static func lower(_ c: UInt16) -> UInt16 { (c >= 0x41 && c <= 0x5A) ? c + 32 : c }
    @inline(__always) private static func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
}

// MARK: - Запасное дополнение по словам

/// Без языкового сервера — слова этого же файла и ключевые слова языка,
/// как в VS Code. Грубо, но набрать длинное имя второй раз не приходится.
enum WordCompletion {

    static func items(in model: SyntaxModel, excluding caret: Int, limit: Int = 5000) -> [CompletionItem] {
        var seen = Set<String>()
        var result: [CompletionItem] = []
        let units = model.units
        var i = 0
        let n = units.count
        while i < n, result.count < limit {
            guard isIdentStart(units[i]) else { i += 1; continue }
            let start = i
            while i < n, isIdentPart(units[i]) { i += 1 }
            // Само набираемое слово в варианты не кладём.
            if caret >= start && caret <= i { continue }
            guard i - start >= 3 else { continue }
            let word = String(decoding: units[start..<i], as: UTF16.self)
            if seen.insert(word).inserted { result.append(CompletionItem(label: word, kind: 1)) }
        }
        for keyword in model.spec?.keywords ?? [] where seen.insert(keyword).inserted {
            result.append(CompletionItem(label: keyword, kind: 14))
        }
        return result
    }

    @inline(__always) static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
    }
    @inline(__always) static func isIdentPart(_ c: UInt16) -> Bool {
        isIdentStart(c) || (c >= 0x30 && c <= 0x39)
    }
}
