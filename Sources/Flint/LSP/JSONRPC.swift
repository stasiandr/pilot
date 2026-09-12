import Foundation

enum RPCError: Error, LocalizedError {
    case serverError(code: Int, message: String)
    case malformed(String)
    case timeout(method: String)
    case notRunning
    case cancelled

    var errorDescription: String? {
        switch self {
        case .serverError(let code, let message): return "LSP \(code): \(message)"
        case .malformed(let what):                return "Некорректный ответ LSP: \(what)"
        case .timeout(let method):                return "Таймаут запроса \(method)"
        case .notRunning:                         return "Языковой сервер не запущен"
        case .cancelled:                          return "Запрос отменён"
        }
    }
}

/// Разбор потока base-протокола LSP: заголовки, `Content-Length`, тело.
///
/// Кадрирование обязано быть байтовым. `Content-Length` считает БАЙТЫ, а чтение
/// из пайпа рвётся в произвольном месте — в том числе посередине многобайтового
/// UTF-8. Поэтому здесь нет ни одной операции над String до тех пор, пока
/// не собрано целое тело сообщения.
struct MessageFramer {
    private var buffer = Data()

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let contentLength = "content-length:"

    /// Скармливает очередную порцию байт, возвращает все полные тела сообщений.
    mutating func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var messages: [Data] = []

        while true {
            guard let headerRange = buffer.range(of: Self.headerEnd) else { break }

            let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
            guard let length = Self.parseContentLength(headerData) else {
                // Заголовок без Content-Length — выбрасываем его и идём дальше,
                // иначе застрянем на нём навсегда.
                buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                continue
            }

            let bodyStart = headerRange.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else {
                break   // тело ещё не дочитано
            }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            messages.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        return messages
    }

    private static func parseContentLength(_ header: Data) -> Int? {
        // Заголовки по спецификации ASCII, так что здесь String уже безопасен.
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
            let lower = line.lowercased()
            guard lower.hasPrefix(contentLength) else { continue }
            let value = line.dropFirst(contentLength.count).trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
        return nil
    }

    /// Оборачивает тело в кадр base-протокола.
    static func frame(_ body: Data) -> Data {
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}

/// Минимальный доступ к JSON без моделирования всего протокола:
/// у LSP слишком много форм ответов, чтобы описывать каждую типом.
enum JSON {
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
            as? [String: Any]
    }

    /// Перекодирует произвольный кусок JSON в Codable-тип.
    static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        if value is NSNull { throw RPCError.malformed("получен null вместо \(T.self)") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }
}
