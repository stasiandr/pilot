import Foundation

/// Позиция в документе по правилам LSP: номер строки и смещение внутри строки
/// в UTF-16 code units (`PositionEncodingKind.utf16` — значение по умолчанию).
///
/// Это ровно та система координат, в которой уже работает SyntaxModel,
/// поэтому преобразование получается без единого перекодирования.
struct LSPPosition: Codable, Equatable {
    var line: Int
    var character: Int
}

struct LSPRange: Codable, Equatable {
    var start: LSPPosition
    var end: LSPPosition
}

struct LSPLocation: Equatable {
    var uri: String
    var range: LSPRange

    var fileURL: URL? { URL(string: uri) }

    /// `textDocument/definition` возвращает три разные формы:
    /// Location, Location[] или LocationLink[]. Нормализуем все.
    static func parse(_ value: Any) -> [LSPLocation] {
        if let array = value as? [Any] { return array.flatMap { parseOne($0) } }
        return parseOne(value)
    }

    private static func parseOne(_ value: Any) -> [LSPLocation] {
        guard let dict = value as? [String: Any] else { return [] }

        // Обычный Location
        if let uri = dict["uri"] as? String,
           let rangeValue = dict["range"],
           let range = try? JSON.decode(LSPRange.self, from: rangeValue) {
            return [LSPLocation(uri: uri, range: range)]
        }
        // LocationLink: цель лежит в targetUri/targetSelectionRange
        if let uri = dict["targetUri"] as? String {
            let rangeValue = dict["targetSelectionRange"] ?? dict["targetRange"]
            if let rangeValue, let range = try? JSON.decode(LSPRange.self, from: rangeValue) {
                return [LSPLocation(uri: uri, range: range)]
            }
        }
        return []
    }
}

/// Содержимое всплывающей подсказки. В протоколе оно полиморфно
/// (MarkupContent | MarkedString | MarkedString[]), поэтому разбираем вручную.
enum HoverContent {
    /// Возвращает готовый к показу текст, очищенный от markdown-обвязки.
    static func parse(_ value: Any) -> String? {
        guard let dict = value as? [String: Any], let contents = dict["contents"] else { return nil }
        let raw = flatten(contents)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func flatten(_ value: Any) -> String {
        if let s = value as? String { return stripFences(s) }
        if let array = value as? [Any] {
            return array.map { flatten($0) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
        }
        if let dict = value as? [String: Any] {
            // и MarkupContent, и MarkedString держат текст в "value"
            if let v = dict["value"] as? String { return stripFences(v) }
        }
        return ""
    }

    /// Roslyn заворачивает сигнатуру в ```csharp … ```. В подсказке
    /// ограждения только мешают — показываем сам код.
    private static func stripFences(_ s: String) -> String {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Символ из `workspace/symbol`. Сервер может вернуть старый SymbolInformation
/// (с location) или новый WorkspaceSymbol (где location может быть «ленивым»,
/// только с uri). Поддерживаем обе формы.
struct LSPSymbol: Equatable {
    var name: String
    var kind: Int
    var containerName: String?
    var uri: String
    var range: LSPRange?

    var fileURL: URL? { URL(string: uri) }

    static func parse(_ value: Any) -> [LSPSymbol] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { item in
            guard let dict = item as? [String: Any],
                  let name = dict["name"] as? String else { return nil }
            let kind = dict["kind"] as? Int ?? 0
            let container = dict["containerName"] as? String

            guard let location = dict["location"] as? [String: Any],
                  let uri = location["uri"] as? String else { return nil }
            let range = location["range"].flatMap { try? JSON.decode(LSPRange.self, from: $0) }

            return LSPSymbol(name: name, kind: kind, containerName: container,
                             uri: uri, range: range)
        }
    }

    /// SF Symbol под вид символа (нумерация SymbolKind из спецификации LSP).
    var iconName: String {
        switch kind {
        case 5:      return "cube"                  // Class
        case 6, 12:  return "function"              // Method / Function
        case 7, 8:   return "circle.grid.2x2"       // Property / Field
        case 9:      return "wrench.and.screwdriver" // Constructor
        case 10:     return "list.number"           // Enum
        case 11:     return "point.3.connected.trianglepath.dotted" // Interface
        case 13, 14: return "tag"                   // Variable / Constant
        case 2, 3:   return "shippingbox"           // Module / Namespace
        case 23:     return "square.on.square"      // Struct
        default:     return "number"
        }
    }

    var kindLabel: String {
        switch kind {
        case 2, 3:  return "namespace"
        case 5:     return "class"
        case 6:     return "method"
        case 7:     return "property"
        case 8:     return "field"
        case 9:     return "ctor"
        case 10:    return "enum"
        case 11:    return "interface"
        case 12:    return "func"
        case 23:    return "struct"
        default:    return ""
        }
    }
}

/// Возможности сервера — нужны, чтобы не слать запросы, которые он не умеет.
struct ServerCapabilities {
    var definition = false
    var hover = false
    var references = false
    var workspaceSymbol = false
    var documentSymbol = false
    /// Нужен ли серверу полный текст документа при открытии (TextDocumentSyncKind).
    var syncKind = 1

    static func parse(_ value: Any) -> ServerCapabilities {
        var caps = ServerCapabilities()
        guard let root = value as? [String: Any],
              let c = root["capabilities"] as? [String: Any] else { return caps }

        func flag(_ key: String) -> Bool {
            if let b = c[key] as? Bool { return b }
            return c[key] is [String: Any]   // провайдер с опциями = включён
        }
        caps.definition = flag("definitionProvider")
        caps.hover = flag("hoverProvider")
        caps.references = flag("referencesProvider")
        caps.workspaceSymbol = flag("workspaceSymbolProvider")
        caps.documentSymbol = flag("documentSymbolProvider")

        if let sync = c["textDocumentSync"] as? Int { caps.syncKind = sync }
        else if let sync = c["textDocumentSync"] as? [String: Any],
                let change = sync["change"] as? Int { caps.syncKind = change }
        return caps
    }
}
