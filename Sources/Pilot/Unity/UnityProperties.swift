import Foundation

// MARK: - Дерево сериализованных полей

/// Поле объекта из сериализованного файла Unity — вместе с тем, где именно
/// в тексте лежит его значение. Позиции нужны для правки: инспектор меняет
/// только сами значения, и остальной файл остаётся байт в байт прежним —
/// дифф в git получается ровно на изменённые числа.
struct UnityProperty {
    var key: String
    /// Строка, где начинается поле (от начала документа).
    var line: Int
    var value: UnityValue

    var displayName: String { UnityNames.nicify(key) }

    func child(_ key: String) -> UnityProperty? {
        switch value {
        case .mapping(let children), .sequence(let children):
            return children.first { $0.key == key }
        default:
            return nil
        }
    }
}

indirect enum UnityValue {
    /// Скаляр: число, строка, 0/1 для bool, номер enum.
    case scalar(UnityScalar)
    /// `{x: 0, y: 1, z: 0}`, `{r: …}`, `{fileID: …, guid: …, type: …}`.
    case flow([UnityFlowField])
    case mapping([UnityProperty])
    /// Элементы списка; ключ элемента — его номер.
    case sequence([UnityProperty])

    var scalar: UnityScalar? { if case .scalar(let s) = self { return s }; return nil }
    var flowFields: [UnityFlowField]? { if case .flow(let f) = self { return f }; return nil }

    /// `{fileID: …, guid: …}` — ссылка на объект или ассет.
    var reference: (fileID: Int64, guid: UnityGUID?)? {
        guard let fields = flowFields, let id = fields.first(where: { $0.key == "fileID" }),
              let fileID = Int64(id.raw) else { return nil }
        let guid = fields.first { $0.key == "guid" }.flatMap { UnityGUID($0.raw) }
        return (fileID, guid)
    }
}

struct UnityScalar {
    enum Style { case plain, singleQuoted, doubleQuoted }

    /// Как значение записано в файле, с кавычками.
    var raw: String
    /// Где оно в документе (UTF-16). Для пустого значения — нулевой длины.
    var range: NSRange
    var style: Style
    /// Строка, перенесённая на несколько строк файла. Такие инспектор
    /// показывает, но не правит: переписать перенос точно так же, как Unity,
    /// ненадёжно, а ошибка испортит файл.
    var multiline: Bool
    /// Пустое значение сразу за `ключ:` без пробела: при записи нужен пробел.
    var needsLeadingSpace = false

    /// Значение без кавычек и экранирования.
    var text: String { UnityScalarCodec.decode(raw, style: style) }
    var number: Double? { style == .plain ? Double(raw) : nil }
}

struct UnityFlowField {
    var key: String
    var raw: String
    var range: NSRange
}

/// Одна правка: заменить диапазон документа новым текстом.
struct UnityEdit: Equatable {
    var range: NSRange
    var text: String
    /// Что должно лежать в диапазоне сейчас. Не совпало — файл уже другой,
    /// и правка не применяется: лучше отказать, чем испортить сцену.
    var expected: String? = nil
}

// MARK: - Разбор

extension UnityYAMLFile {

    /// Поля объекта. Разбирается по запросу — только тот объект, что сейчас
    /// в инспекторе, поэтому размер сцены не важен.
    func properties(ofObjectAt index: Int, in model: SyntaxModel) -> [UnityProperty] {
        let object = objects[index]
        let firstLine = object.typeNameLine + 1
        let endLine = index + 1 < objects.count ? objects[index + 1].startLine : model.lineCount
        guard firstLine < endLine else { return [] }
        var parser = UnityPropertyParser(model: model, lines: firstLine..<endLine)
        return parser.parse()
    }
}

struct UnityPropertyParser {
    private struct Line {
        var number: Int
        var start: Int         // начало строки
        var contentStart: Int  // первый непробельный символ
        var end: Int           // конец без \r\n
        var indent: Int { contentStart - start }
        var isBlank: Bool { contentStart >= end }
    }

    private let units: [UInt16]
    private var lines: [Line] = []
    private var i = 0

    init(model: SyntaxModel, lines range: Range<Int>) {
        units = model.units
        lines.reserveCapacity(range.count)
        for number in range {
            let span = model.lineRange(number)
            var end = span.upperBound
            while end > span.lowerBound, units[end - 1] == 0x0A || units[end - 1] == 0x0D { end -= 1 }
            var content = span.lowerBound
            while content < end, units[content] == 0x20 { content += 1 }
            lines.append(Line(number: number, start: span.lowerBound, contentStart: content, end: end))
        }
    }

    mutating func parse() -> [UnityProperty] {
        i = 0
        skipBlank()
        guard i < lines.count else { return [] }
        return parseMapping(indent: lines[i].indent)
    }

    private mutating func skipBlank() {
        while i < lines.count, lines[i].isBlank { i += 1 }
    }

    private func isDash(_ line: Line) -> Bool {
        line.contentStart < line.end && units[line.contentStart] == 0x2D
            && (line.contentStart + 1 == line.end || units[line.contentStart + 1] == 0x20)
    }

    /// Поля одного уровня: `ключ: значение` на отступе `indent`.
    private mutating func parseMapping(indent: Int) -> [UnityProperty] {
        var result: [UnityProperty] = []
        while true {
            skipBlank()
            guard i < lines.count else { break }
            let line = lines[i]
            if line.indent < indent { break }
            if line.indent > indent || isDash(line) {
                // Сюда попадают только строки битого или непривычного файла:
                // пропускаем их, чтобы не зациклиться.
                if line.indent == indent { break }
                i += 1
                continue
            }
            guard let colon = keyColon(line) else { i += 1; continue }
            let key = unquotedKey(line.contentStart, colon)
            let valueStart = min(colon + 2, line.end)
            i += 1

            if valueStart >= line.end {
                // `ключ:` без значения — дальше вложенный блок, список или ничего.
                skipBlank()
                if i < lines.count, lines[i].indent == indent, isDash(lines[i]) {
                    result.append(UnityProperty(key: key, line: line.number,
                                                value: .sequence(parseSequence(indent: indent))))
                } else if i < lines.count, lines[i].indent > indent {
                    let childIndent = lines[i].indent
                    let value: UnityValue = isDash(lines[i])
                        ? .sequence(parseSequence(indent: childIndent))
                        : .mapping(parseMapping(indent: childIndent))
                    result.append(UnityProperty(key: key, line: line.number, value: value))
                } else {
                    let empty = UnityScalar(raw: "", range: NSRange(location: line.end, length: 0),
                                            style: .plain, multiline: false,
                                            needsLeadingSpace: line.end == colon + 1)
                    result.append(UnityProperty(key: key, line: line.number, value: .scalar(empty)))
                }
                continue
            }
            let value = parseInlineValue(line, from: valueStart, parentIndent: indent)
            result.append(UnityProperty(key: key, line: line.number, value: value))
        }
        return result
    }

    /// Элементы списка `- …` на отступе `indent`. Unity пишет списки без
    /// дополнительного отступа: `-` стоит вровень с ключом родителя.
    private mutating func parseSequence(indent: Int) -> [UnityProperty] {
        var items: [UnityProperty] = []
        while true {
            skipBlank()
            guard i < lines.count, lines[i].indent == indent, isDash(lines[i]) else { break }
            let line = lines[i]
            let itemStart = min(line.contentStart + 2, line.end)
            let key = String(items.count)

            if itemStart < line.end, keyColon(line, from: itemStart) != nil {
                // `- ключ: значение` — элемент-структура. Первое поле стоит на
                // строке с дефисом, остальные — на отступе indent + 2.
                lines[i].contentStart = itemStart
                let fields = parseMapping(indent: indent + 2)
                items.append(UnityProperty(key: key, line: line.number, value: .mapping(fields)))
            } else {
                i += 1
                let value = itemStart < line.end
                    ? parseInlineValue(line, from: itemStart, parentIndent: indent)
                    : .scalar(UnityScalar(raw: "", range: NSRange(location: line.end, length: 0),
                                          style: .plain, multiline: false))
                items.append(UnityProperty(key: key, line: line.number, value: value))
            }
        }
        return items
    }

    /// Значение на той же строке, что и ключ.
    private mutating func parseInlineValue(_ line: Line, from start: Int, parentIndent: Int) -> UnityValue {
        let end = line.end
        let first = units[start]
        if first == 0x7B, let fields = parseFlow(start, end) {     // {
            return .flow(fields)
        }
        if end - start == 2, first == 0x5B, units[start + 1] == 0x5D {   // []
            return .sequence([])
        }

        var style = UnityScalar.Style.plain
        if first == 0x27 { style = .singleQuoted }
        if first == 0x22 { style = .doubleQuoted }
        // Значение может продолжаться на следующих строках: у строки в
        // кавычках — пока кавычка не закроется, у простой — пока отступ
        // глубже ключа (детей у `ключ: значение` быть не может).
        var rangeEnd = end
        var multiline = false
        if style == .plain {
            var j = i
            while j < lines.count {
                if lines[j].isBlank { j += 1; continue }
                guard lines[j].indent > parentIndent else { break }
                rangeEnd = lines[j].end
                multiline = true
                j += 1
                i = j
            }
        } else if !quoteClosed(start, end, style: style) {
            while i < lines.count {
                rangeEnd = lines[i].end
                multiline = true
                i += 1
                if quoteClosed(start, rangeEnd, style: style) { break }
            }
        }
        let range = NSRange(location: start, length: rangeEnd - start)
        return .scalar(UnityScalar(raw: string(start, rangeEnd), range: range, style: style,
                                   multiline: multiline))
    }

    private func startsFlowOrQuote(_ at: Int) -> Bool {
        let c = units[at]
        return c == 0x7B || c == 0x5B || c == 0x27 || c == 0x22
    }

    /// Закрыта ли кавычка, открытая в `start`, к позиции `end`.
    private func quoteClosed(_ start: Int, _ end: Int, style: UnityScalar.Style) -> Bool {
        guard style != .plain else { return true }
        let quote: UInt16 = style == .singleQuoted ? 0x27 : 0x22
        var j = start + 1
        while j < end {
            let c = units[j]
            if style == .doubleQuoted, c == 0x5C { j += 2; continue }   // \x
            if c == quote {
                if style == .singleQuoted, j + 1 < end, units[j + 1] == 0x27 { j += 2; continue }   // ''
                return true
            }
            j += 1
        }
        return false
    }

    /// Двоеточие после ключа: `ключ: значение` или `ключ:` в конце строки.
    /// Ключ в кавычках (`'m_MeshMetrics[0]': 1`) — только если за
    /// закрывающей кавычкой сразу двоеточие; иначе это строка-значение.
    private func keyColon(_ line: Line, from: Int? = nil) -> Int? {
        let start = from ?? line.contentStart
        guard start < line.end else { return nil }
        let first = units[start]
        if first == 0x27 || first == 0x22 {
            var j = start + 1
            while j < line.end {
                if units[j] == first {
                    if first == 0x27, j + 1 < line.end, units[j + 1] == 0x27 { j += 2; continue }
                    break
                }
                if first == 0x22, units[j] == 0x5C { j += 1 }
                j += 1
            }
            let colon = j + 1
            guard j < line.end, colon < line.end, units[colon] == 0x3A,
                  colon + 1 == line.end || units[colon + 1] == 0x20 else { return nil }
            return colon
        }
        guard !startsFlowOrQuote(start) else { return nil }
        var j = start
        while j < line.end {
            if units[j] == 0x3A, j + 1 == line.end || units[j + 1] == 0x20 { return j > start ? j : nil }
            j += 1
        }
        return nil
    }

    /// `{a: 1, b: {c: 2}}` — только плоские поля; вложенные фигурные
    /// скобки Unity в таких значениях не пишет.
    private func parseFlow(_ start: Int, _ end: Int) -> [UnityFlowField]? {
        guard units[end - 1] == 0x7D else { return nil }
        var fields: [UnityFlowField] = []
        var j = start + 1
        let close = end - 1
        while j < close {
            while j < close, units[j] == 0x20 || units[j] == 0x2C { j += 1 }
            guard j < close else { break }
            let keyStart = j
            while j < close, units[j] != 0x3A { j += 1 }
            guard j < close else { return nil }
            let key = string(keyStart, j)
            j += 1
            while j < close, units[j] == 0x20 { j += 1 }
            let valueStart = j
            while j < close, units[j] != 0x2C { j += 1 }
            var valueEnd = j
            while valueEnd > valueStart, units[valueEnd - 1] == 0x20 { valueEnd -= 1 }
            fields.append(UnityFlowField(key: key, raw: string(valueStart, valueEnd),
                                         range: NSRange(location: valueStart, length: valueEnd - valueStart)))
        }
        return fields
    }

    private func unquotedKey(_ start: Int, _ end: Int) -> String {
        let key = string(start, end)
        guard key.count >= 2, let q = key.first, q == "'" || q == "\"", key.last == q else { return key }
        return UnityScalarCodec.decode(key, style: q == "'" ? .singleQuoted : .doubleQuoted)
    }

    private func string(_ start: Int, _ end: Int) -> String {
        String(decoding: units[start..<max(start, end)], as: UTF16.self)
    }
}

// MARK: - Кодирование скаляров

enum UnityScalarCodec {

    static func decode(_ raw: String, style: UnityScalar.Style) -> String {
        switch style {
        case .plain:
            return fold(raw)
        case .singleQuoted:
            guard raw.count >= 2 else { return raw }
            let inner = String(raw.dropFirst().dropLast())
            return fold(inner).replacingOccurrences(of: "''", with: "'")
        case .doubleQuoted:
            guard raw.count >= 2 else { return raw }
            return unescape(fold(String(raw.dropFirst().dropLast())))
        }
    }

    /// Перенос строк YAML: одиночный перевод строки — пробел, пустая
    /// строка — перевод строки, отступ продолжения не считается.
    private static func fold(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        let rows = text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \r"))
        }
        var result = ""
        var pendingBreaks = 0
        for (k, row) in rows.enumerated() {
            if row.isEmpty && k > 0 { pendingBreaks += 1; continue }
            if k > 0 { result += pendingBreaks > 0 ? String(repeating: "\n", count: pendingBreaks) : " " }
            pendingBreaks = 0
            result += row
        }
        return result
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var it = Array(text.unicodeScalars)[...]
        while let c = it.popFirst() {
            guard c == "\\", let e = it.popFirst() else { out.unicodeScalars.append(c); continue }
            switch e {
            case "n": out += "\n"
            case "t": out += "\t"
            case "r": out += "\r"
            case "0": out += "\0"
            case "\"": out += "\""
            case "\\": out += "\\"
            case "/": out += "/"
            case " ": out += " "
            case "x", "u", "U":
                let count = e == "x" ? 2 : (e == "u" ? 4 : 8)
                let hex = String(String.UnicodeScalarView(it.prefix(count)))
                if hex.count == count, let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                    out.unicodeScalars.append(scalar)
                    it = it.dropFirst(count)
                } else {
                    out += "\\" + String(e)
                }
            default:
                out += "\\" + String(e)
            }
        }
        return out
    }

    /// Новое значение в той же манере, в какой было записано старое.
    /// Кавычки добавляются, только если без них YAML прочитает не то.
    static func encode(_ text: String, like original: UnityScalar.Style) -> String {
        if original == .doubleQuoted || text.contains(where: { $0.isNewline || $0 == "\t" }) {
            var out = "\""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                case "\r": out += "\\r"
                default:
                    if scalar.value < 0x20 { out += String(format: "\\x%02X", scalar.value) }
                    else { out.unicodeScalars.append(scalar) }
                }
            }
            return out + "\""
        }
        if original == .singleQuoted || needsQuotes(text) {
            return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        }
        return text
    }

    static func needsQuotes(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) || first == " " || last == " " { return true }
        return text.contains(": ") || text.contains(" #") || text.hasSuffix(":")
    }
}

// MARK: - Числа

enum UnityNumber {
    /// Как Unity пишет float: кратчайшее представление без экспоненты,
    /// целые — без `.0`.
    static func format(_ value: Double) -> String {
        let float = Float(value)
        if float == float.rounded(), abs(float) < 1e7 {
            let int = Int(float)
            return int == 0 && float.sign == .minus ? "-0" : String(int)
        }
        let text = "\(float)"
        guard text.contains("e") else { return text }
        // 1e-05 → 0.00001: экспоненту Unity не пишет.
        var fixed = String(format: "%.12f", Double(float))
        while fixed.hasSuffix("0") { fixed.removeLast() }
        if fixed.hasSuffix(".") { fixed.removeLast() }
        return fixed
    }

    /// Ввод пользователя → запись в файл. Запятая как разделитель тоже годится.
    static func parse(_ input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}

// MARK: - Поворот

/// Unity хранит поворот кватернионом, а в инспекторе показывает углы Эйлера.
/// Порядок — как у `Quaternion.Euler`: Z, затем X, затем Y (q = qy · qx · qz).
enum UnityRotation {

    static func euler(x: Double, y: Double, z: Double, w: Double) -> (x: Double, y: Double, z: Double) {
        let r12 = 2 * (y * z - w * x)
        let sinX = max(-1, min(1, -r12))
        let ex = asin(sinX)
        var ey: Double, ez: Double
        if abs(sinX) < 0.9999999 {
            ey = atan2(2 * (x * z + w * y), 1 - 2 * (x * x + y * y))
            ez = atan2(2 * (x * y + w * z), 1 - 2 * (x * x + z * z))
        } else {
            // Карданов замок: Z и Y неразличимы, всё относим к Y.
            ey = atan2(-2 * (x * z - w * y), 1 - 2 * (y * y + z * z))
            ez = 0
        }
        return (normalize(degrees(ex)), normalize(degrees(ey)), normalize(degrees(ez)))
    }

    static func quaternion(x: Double, y: Double, z: Double) -> (x: Double, y: Double, z: Double, w: Double) {
        let (hx, hy, hz) = (radians(x) / 2, radians(y) / 2, radians(z) / 2)
        let qx = (x: sin(hx), y: 0.0, z: 0.0, w: cos(hx))
        let qy = (x: 0.0, y: sin(hy), z: 0.0, w: cos(hy))
        let qz = (x: 0.0, y: 0.0, z: sin(hz), w: cos(hz))
        return multiply(multiply(qy, qx), qz)
    }

    private typealias Q = (x: Double, y: Double, z: Double, w: Double)

    private static func multiply(_ a: Q, _ b: Q) -> Q {
        (x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
         y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
         z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
         w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
    }

    private static func degrees(_ r: Double) -> Double { r * 180 / .pi }
    private static func radians(_ d: Double) -> Double { d * .pi / 180 }

    /// Как в инспекторе Unity: [0, 360), без `-0` и без 359.99999.
    private static func normalize(_ d: Double) -> Double {
        var v = d.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        if abs(v - 360) < 1e-4 || abs(v) < 1e-4 { v = 0 }
        return (v * 1e4).rounded() / 1e4
    }
}

// MARK: - Имена полей

enum UnityNames {
    /// `m_LocalPosition` → `Local Position`, `<Health>k__BackingField` → `Health`,
    /// `_moveSpeed` → `Move Speed` — как `ObjectNames.NicifyVariableName`.
    static func nicify(_ key: String) -> String {
        var name = Substring(key)
        if name.hasPrefix("<"), let close = name.firstIndex(of: ">") {
            name = name[name.index(after: name.startIndex)..<close]
        }
        if name.hasPrefix("m_") { name = name.dropFirst(2) }
        while name.hasPrefix("_") { name = name.dropFirst() }
        if name.count > 1, name.first == "k", name.dropFirst().first?.isUppercase == true { name = name.dropFirst() }
        guard !name.isEmpty else { return key }

        var result = ""
        let chars = Array(name)
        for (k, c) in chars.enumerated() {
            if c == "_" { result += " "; continue }
            if k > 0, c.isUppercase {
                let prev = chars[k - 1]
                let nextIsLower = k + 1 < chars.count && chars[k + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) { result += " " }
            } else if k > 0, c.isNumber, chars[k - 1].isLetter {
                result += " "
            }
            result.append(k == 0 ? Character(c.uppercased()) : c)
        }
        return result.replacingOccurrences(of: "  ", with: " ")
    }
}

// MARK: - Правки

enum UnityEdits {

    /// Новое значение скаляра. `nil` — править нельзя или нечего.
    /// `numeric` — поле числовое (из типа в скрипте); `nil` — судим по
    /// текущему значению.
    static func scalar(_ scalar: UnityScalar, text: String, numeric: Bool? = nil) -> UnityEdit? {
        guard !scalar.multiline else { return nil }
        var encoded: String
        if numeric ?? (scalar.number != nil) {
            guard let value = UnityNumber.parse(text) else { return nil }
            encoded = numberText(value, typed: text)
        } else {
            encoded = UnityScalarCodec.encode(text, like: scalar.style)
        }
        if encoded == scalar.raw { return nil }
        if scalar.needsLeadingSpace, !encoded.isEmpty { encoded = " " + encoded }
        return UnityEdit(range: scalar.range, text: encoded, expected: scalar.raw)
    }

    static func number(_ field: UnityFlowField, text: String) -> UnityEdit? {
        guard let value = UnityNumber.parse(text) else { return nil }
        let encoded = numberText(value, typed: text)
        return encoded == field.raw ? nil : UnityEdit(range: field.range, text: encoded, expected: field.raw)
    }

    static func number(_ field: UnityFlowField, value: Double) -> UnityEdit? {
        let encoded = UnityNumber.format(value)
        return encoded == field.raw ? nil : UnityEdit(range: field.range, text: encoded, expected: field.raw)
    }

    /// Что ввёл пользователь, то и пишем, если это число: `1.50` так и
    /// останется `1.50`. Иначе — в формате Unity.
    private static func numberText(_ value: Double, typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let plain = trimmed.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
        return plain && !trimmed.hasPrefix(".") && !trimmed.hasSuffix(".") ? trimmed : UnityNumber.format(value)
    }

    /// Поворот Transform: пишем кватернион и, если есть, подсказку углов,
    /// которую Unity показывает в инспекторе.
    static func rotation(of transform: [UnityProperty], euler: (x: Double, y: Double, z: Double)) -> [UnityEdit] {
        var edits: [UnityEdit] = []
        let q = UnityRotation.quaternion(x: euler.x, y: euler.y, z: euler.z)
        if let fields = transform.first(where: { $0.key == "m_LocalRotation" })?.value.flowFields {
            for field in fields {
                let value: Double?
                switch field.key {
                case "x": value = q.x
                case "y": value = q.y
                case "z": value = q.z
                case "w": value = q.w
                default: value = nil
                }
                if let value, let edit = number(field, value: value) { edits.append(edit) }
            }
        }
        if let fields = transform.first(where: { $0.key == "m_LocalEulerAnglesHint" })?.value.flowFields {
            for field in fields {
                let value: Double?
                switch field.key {
                case "x": value = euler.x
                case "y": value = euler.y
                case "z": value = euler.z
                default: value = nil
                }
                if let value, let edit = number(field, value: value) { edits.append(edit) }
            }
        }
        return edits
    }

    /// Правки ложатся в текст: не пересекаются, не выходят за край, и на
    /// месте каждой лежит то, что она ожидает.
    static func validate(_ edits: [UnityEdit], in text: NSString) -> Bool {
        var previousEnd = 0
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            guard edit.range.location >= previousEnd, NSMaxRange(edit.range) <= text.length else { return false }
            if let expected = edit.expected, text.substring(with: edit.range) != expected { return false }
            previousEnd = NSMaxRange(edit.range)
        }
        return true
    }

    /// Применяет правки к тексту. Возвращает новый текст и обратные правки —
    /// для отмены.
    static func apply(_ edits: [UnityEdit], to text: String) -> (text: String, inverse: [UnityEdit])? {
        let source = text as NSString
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        // Правки не должны пересекаться и выходить за текст.
        var previousEnd = 0
        for edit in sorted {
            guard edit.range.location >= previousEnd, NSMaxRange(edit.range) <= source.length else { return nil }
            if let expected = edit.expected, source.substring(with: edit.range) != expected { return nil }
            previousEnd = NSMaxRange(edit.range)
        }
        let result = NSMutableString(string: text)
        var inverse: [UnityEdit] = []
        var delta = 0
        for edit in sorted {
            let old = source.substring(with: edit.range)
            let newLength = (edit.text as NSString).length
            inverse.append(UnityEdit(range: NSRange(location: edit.range.location + delta, length: newLength),
                                     text: old, expected: edit.text))
            delta += newLength - edit.range.length
        }
        for edit in sorted.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.text)
        }
        return (result as String, inverse)
    }
}
