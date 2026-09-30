import Foundation

/// Слияние сцен, префабов и ассетов Unity по объектам, а не по строкам.
///
/// Файл — список объектов `--- !u!<класс> &<fileID>`, у объекта — свойства
/// верхнего уровня (`  m_Name: …`, `  m_LocalPosition: {…}`, `  speed: 5`).
/// Текстовое слияние спотыкается о соседние строки разных объектов и о
/// списки, куда обе стороны что-то добавили; здесь такое сливается само:
///
/// - свойство правила одна сторона — берётся её значение;
/// - объект добавила или удалила одна сторона — так и будет;
/// - списки ссылок (`m_Component`, `m_Children`) — объединение добавленного
///   и вычитание удалённого с обеих сторон;
/// - переопределения вложенного префаба (`m_Modifications`) — по одному,
///   по паре «объект + путь свойства».
///
/// Спор остаётся, только когда обе стороны изменили одно и то же по-разному,
/// или одна удалила объект, а другая его правила.
enum UnityMerge {

    // MARK: - Разбор

    struct Document: Equatable {
        /// `--- !u!114 &11400000` (и ` stripped`, если есть).
        var header: String
        var fileID: Int64
        var classID: Int
        /// `MonoBehaviour:` — строка с именем типа.
        var typeLine: String
        /// Строки после типа, как есть.
        var body: [String]

        var lines: [String] { [header, typeLine] + body }
    }

    struct Parsed: Equatable {
        /// `%YAML 1.1`, `%TAG …` — до первого объекта.
        var preamble: [String]
        var documents: [Document]
        var trailingNewline: Bool
    }

    /// nil — это не Unity YAML: нет ни одного объекта.
    static func parse(_ text: String) -> Parsed? {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let trailing = text.hasSuffix("\n")
        if trailing, lines.last == "" { lines.removeLast() }
        var preamble: [String] = []
        var documents: [Document] = []
        var i = 0
        while i < lines.count, !lines[i].hasPrefix("--- !u!") {
            preamble.append(lines[i])
            i += 1
        }
        while i < lines.count {
            let header = lines[i]
            guard let (classID, fileID) = headerIDs(header) else { return nil }
            i += 1
            let typeLine = i < lines.count && !lines[i].hasPrefix("--- ") ? lines[i] : ""
            if !typeLine.isEmpty { i += 1 }
            var body: [String] = []
            while i < lines.count, !lines[i].hasPrefix("--- !u!") {
                body.append(lines[i])
                i += 1
            }
            documents.append(Document(header: header, fileID: fileID, classID: classID, typeLine: typeLine, body: body))
        }
        guard !documents.isEmpty else { return nil }
        return Parsed(preamble: preamble, documents: documents, trailingNewline: trailing)
    }

    /// `--- !u!1 &1001 stripped` → (1, 1001).
    static func headerIDs(_ header: String) -> (Int, Int64)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("!u!"), parts[2].hasPrefix("&"),
              let classID = Int(parts[1].dropFirst(3)), let fileID = Int64(parts[2].dropFirst()) else { return nil }
        return (classID, fileID)
    }

    /// Свойства верхнего уровня: строка `  ключ: …` и всё, что под ней, до
    /// следующего такого ключа. Элементы списка (`  - …`) на том же отступе
    /// принадлежат ключу над ними — так Unity пишет списки.
    static func properties(_ body: [String], indent: Int = 2) -> [(key: String, lines: [String])] {
        let prefix = String(repeating: " ", count: indent)
        var result: [(key: String, lines: [String])] = []
        for line in body {
            if line.hasPrefix(prefix), line.count > indent {
                let rest = line.dropFirst(indent)
                if let first = rest.first, first != " ", first != "-", let colon = rest.firstIndex(of: ":") {
                    result.append((String(rest[..<colon]), [line]))
                    continue
                }
            }
            if result.isEmpty { result.append(("", [line])) } else { result[result.count - 1].lines.append(line) }
        }
        return result
    }

    // MARK: - Результат

    struct Conflict: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Обе стороны по-разному изменили свойство.
            case property
            /// Одна удалила объект, другая его правила.
            case deletedByOurs, deletedByTheirs
        }

        var id: String
        var kind: Kind
        var fileID: Int64
        var classID: Int
        /// Имя свойства: `speed`, `m_LocalPosition`, `m_Modifications › m_Name (&400)`.
        var property: String
        /// Строки с каждой стороны; nil — свойства (объекта) там нет.
        var base: [String]?
        var ours: [String]?
        var theirs: [String]?
    }

    enum Pick: Equatable { case ours, theirs }

    /// Кусок итогового текста: готовые строки или спор, который решит человек.
    enum Segment: Equatable {
        case lines([String])
        case conflict(String)
    }

    struct Result: Equatable {
        var segments: [Segment]
        var conflicts: [Conflict]
        var trailingNewline: Bool
        /// Сколько правок взято само — для строки «слито само: …».
        var fromOurs = 0
        var fromTheirs = 0

        /// Текст с решениями. Нерешённый спор — наша сторона: так файл хотя
        /// бы открывается в Unity.
        func text(_ picks: [String: Pick]) -> String {
            let byID = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, $0) })
            var lines: [String] = []
            for segment in segments {
                switch segment {
                case .lines(let chunk): lines += chunk
                case .conflict(let id):
                    guard let conflict = byID[id] else { continue }
                    lines += (picks[id] == .theirs ? conflict.theirs : conflict.ours) ?? []
                }
            }
            return lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        }
    }

    // MARK: - Слияние

    static func merge(base: String, ours: String, theirs: String) -> Result? {
        guard let o = parse(ours), let t = parse(theirs) else { return nil }
        let b = parse(base) ?? Parsed(preamble: o.preamble, documents: [], trailingNewline: o.trailingNewline)
        var result = Result(segments: [.lines(o.preamble)], conflicts: [], trailingNewline: o.trailingNewline)

        let baseDocs = Dictionary(b.documents.map { ($0.fileID, $0) }, uniquingKeysWith: { a, _ in a })
        let theirDocs = Dictionary(t.documents.map { ($0.fileID, $0) }, uniquingKeysWith: { a, _ in a })
        let ourIDs = Set(o.documents.map(\.fileID))

        // Порядок — наш; их новые объекты — в конце: Unity порядок не важен.
        for doc in o.documents {
            let bd = baseDocs[doc.fileID], td = theirDocs[doc.fileID]
            if td == nil {
                if bd == nil {
                    result.segments.append(.lines(doc.lines))   // добавили мы
                } else if bd == doc {
                    result.fromTheirs += 1                        // удалили они
                } else {
                    let id = "\(doc.fileID)#object"
                    result.conflicts.append(Conflict(id: id, kind: .deletedByTheirs, fileID: doc.fileID, classID: doc.classID,
                                                     property: "", base: bd?.lines, ours: doc.lines, theirs: nil))
                    result.segments.append(.conflict(id))
                }
                continue
            }
            mergeDocument(base: bd, ours: doc, theirs: td!, into: &result)
        }
        for doc in t.documents where !ourIDs.contains(doc.fileID) {
            let bd = baseDocs[doc.fileID]
            if bd == nil {
                result.segments.append(.lines(doc.lines))       // добавили они
                result.fromTheirs += 1
            } else if bd == doc {
                result.fromOurs += 1                              // удалили мы
            } else {
                let id = "\(doc.fileID)#object"
                result.conflicts.append(Conflict(id: id, kind: .deletedByOurs, fileID: doc.fileID, classID: doc.classID,
                                                 property: "", base: bd?.lines, ours: nil, theirs: doc.lines))
                result.segments.append(.conflict(id))
            }
        }
        return result
    }

    private static func mergeDocument(base: Document?, ours: Document, theirs: Document, into result: inout Result) {
        if ours == theirs { result.segments.append(.lines(ours.lines)); return }
        if let base, ours == base { result.segments.append(.lines(theirs.lines)); result.fromTheirs += 1; return }
        if let base, theirs == base { result.segments.append(.lines(ours.lines)); result.fromOurs += 1; return }
        result.segments.append(.lines([ours.header, ours.typeLine]))
        mergeKeyed(base: base.map { properties($0.body) } ?? [],
                   ours: properties(ours.body), theirs: properties(theirs.body),
                   document: ours, label: { $0 }, into: &result) { key, b, o, t, result in
            // Список ссылок — объединение правок обеих сторон.
            if let merged = mergeReferenceList(base: b, ours: o, theirs: t) {
                result.segments.append(.lines(merged))
                return true
            }
            // Переопределения вложенного префаба — каждое отдельно.
            if key == "m_Modification", let b {
                mergeModification(base: b, ours: o, theirs: t, document: ours, into: &result)
                return true
            }
            return false
        }
    }

    /// Слияние списков «ключ → строки»: одинаковое и правленное одной
    /// стороной — само, остальное — `special` или спор.
    private static func mergeKeyed(base: [(key: String, lines: [String])], ours: [(key: String, lines: [String])],
                                   theirs: [(key: String, lines: [String])], document: Document,
                                   label: (String) -> String, into result: inout Result,
                                   special: (String, [String]?, [String], [String], inout Result) -> Bool) {
        let b = Dictionary(base.map { ($0.key, $0.lines) }, uniquingKeysWith: { a, _ in a })
        let t = Dictionary(theirs.map { ($0.key, $0.lines) }, uniquingKeysWith: { a, _ in a })
        let ourKeys = Set(ours.map(\.key))
        func resolve(_ key: String, _ bl: [String]?, _ ol: [String]?, _ tl: [String]?) {
            if ol == tl { if let ol { result.segments.append(.lines(ol)) }; return }
            if ol == bl { if let tl { result.segments.append(.lines(tl)) }; result.fromTheirs += 1; return }
            if tl == bl { if let ol { result.segments.append(.lines(ol)) }; result.fromOurs += 1; return }
            if let ol, let tl, special(key, bl, ol, tl, &result) { return }
            let id = "\(document.fileID)#\(label(key))"
            result.conflicts.append(Conflict(id: id, kind: .property, fileID: document.fileID, classID: document.classID,
                                             property: label(key), base: bl, ours: ol, theirs: tl))
            result.segments.append(.conflict(id))
        }
        for (key, lines) in ours { resolve(key, b[key], lines, t[key]) }
        for (key, lines) in theirs where !ourKeys.contains(key) { resolve(key, b[key], nil, lines) }
    }

    /// `  m_Component:` + `  - component: {fileID: 4}`… — если все элементы
    /// однострочные, список сливается как множество: наш порядок, минус
    /// удалённое ими, плюс добавленное ими. Иначе nil.
    static func mergeReferenceList(base: [String]?, ours: [String], theirs: [String]) -> [String]? {
        func items(_ lines: [String]?) -> [String]? {
            guard let lines, lines.count >= 1 else { return nil }
            let rest = Array(lines.dropFirst())
            guard lines[0].hasSuffix(":"), rest.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }) else {
                return nil
            }
            return rest
        }
        // Пустой список Unity пишет `  m_Children: []` — он тоже годится.
        func itemsOrEmpty(_ lines: [String]?) -> [String]? {
            if let lines, lines.count == 1, lines[0].hasSuffix(": []") { return [] }
            return items(lines)
        }
        guard let o = itemsOrEmpty(ours), let t = itemsOrEmpty(theirs) else { return nil }
        let b = itemsOrEmpty(base) ?? []
        guard !(o.isEmpty && t.isEmpty) else { return nil }
        let removedByTheirs = Set(b).subtracting(t)
        var merged = o.filter { !removedByTheirs.contains($0) }
        for item in t where !b.contains(item) && !merged.contains(item) { merged.append(item) }
        let key = (ours.first ?? theirs.first ?? "").replacingOccurrences(of: " []", with: "")
        let header = key.hasSuffix(":") ? key : key + ":"
        return merged.isEmpty ? [header + " []"] : [header] + merged
    }

    /// `m_Modification` вложенного префаба: его подключи (`m_TransformParent`,
    /// `m_RemovedComponents`…) — как свойства, а список `m_Modifications` —
    /// по элементам с ключом «target + propertyPath».
    private static func mergeModification(base: [String], ours: [String], theirs: [String],
                                          document: Document, into result: inout Result) {
        result.segments.append(.lines([ours[0]]))
        func sub(_ lines: [String]) -> [(key: String, lines: [String])] { properties(Array(lines.dropFirst()), indent: 4) }
        mergeKeyed(base: sub(base), ours: sub(ours), theirs: sub(theirs), document: document,
                   label: { "m_Modification › \($0)" }, into: &result) { key, b, o, t, result in
            guard key == "m_Modifications" else { return false }
            result.segments.append(.lines([o[0]]))
            mergeKeyed(base: modificationItems(b), ours: modificationItems(o), theirs: modificationItems(t),
                       document: document, label: { "m_Modifications › \($0)" }, into: &result) { _, _, _, _, _ in false }
            return true
        }
    }

    /// Элементы `m_Modifications`: `    - target: {fileID: 1, guid: …}` и строки
    /// под ним. Ключ — `propertyPath (fileID)`: одно свойство одного объекта.
    static func modificationItems(_ lines: [String]?) -> [(key: String, lines: [String])] {
        guard let lines, lines.count > 1 else { return [] }
        var items: [(key: String, lines: [String])] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                items.append(("", [line]))
            } else if !items.isEmpty {
                items[items.count - 1].lines.append(line)
            }
        }
        return items.map { item in
            let target = item.lines.first.flatMap { line in
                line.range(of: "fileID: ").map { r in String(line[r.upperBound...].prefix { $0.isNumber || $0 == "-" }) }
            } ?? "?"
            let path = item.lines.first { $0.contains("propertyPath: ") }
                .map { String($0[$0.range(of: "propertyPath: ")!.upperBound...]) } ?? "?"
            return ("\(path) (&\(target))", item.lines)
        }
    }

    /// Значение для показа: `  speed: 5` → `5`, многострочное — без отступа.
    static func display(_ lines: [String]?) -> String {
        guard let lines, !lines.isEmpty else { return "—" }
        if lines.count == 1, let colon = lines[0].firstIndex(of: ":") {
            let value = lines[0][lines[0].index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? "—" : value
        }
        let indent = lines.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(indent)) }.joined(separator: "\n")
    }
}
