import Foundation

// MARK: - Язык

/// Язык интерфейса Pilot.
///
/// Исходный язык — русский: строки в коде пишутся по-русски и сами служат
/// ключами. Переводы на остальные языки — таблицы «русская строка → перевод»
/// (`English.swift`); новый язык — это новый `case` и новая таблица.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case ru
    case en

    var id: String { rawValue }

    /// Название на самом языке — как в списке языков macOS: его должен
    /// узнать тот, кто на нём читает.
    var nativeName: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    /// Переводы с русского; у самого русского таблицы нет.
    var table: [String: String]? {
        switch self {
        case .ru: return nil
        case .en: return English.table
        }
    }

    /// Первый из предпочитаемых языков системы, который Pilot знает;
    /// не знает ни одного — английский.
    static func preferred(from languages: [String]) -> AppLanguage {
        for code in languages {
            let base = code.split(separator: "-").first.map(String.init)?.lowercased() ?? code
            if let language = AppLanguage(rawValue: base) { return language }
        }
        return .en
    }
}

// MARK: - Перевод

enum Localization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var language: AppLanguage = .ru

    /// Текущий язык. По умолчанию русский — язык исходников, так что тесты
    /// ядра видят те же строки, что написаны в коде. Приложение ставит
    /// выбранный в настройках при запуске и при смене.
    static var current: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return language }
        set { lock.lock(); language = newValue; lock.unlock() }
    }

    /// Перевод ключа на текущий язык. Перевода нет — остаётся русский:
    /// лучше строка не на том языке, чем пустое место.
    static func string(_ key: LocalizedKey) -> String {
        let format = current.table?[key.key] ?? key.key
        return substitute(format, key.arguments)
    }

    /// Подставляет аргументы в формат: `%@` — следующий по порядку,
    /// `%2$@` — второй (перевод может переставить их), `%%` — сам знак.
    static func substitute(_ format: String, _ arguments: [String]) -> String {
        guard format.contains("%") else { return format }
        var out = ""
        var next = 0
        var i = format.startIndex
        while i < format.endIndex {
            let c = format[i]
            guard c == "%" else { out.append(c); i = format.index(after: i); continue }
            let rest = format[format.index(after: i)...]
            if rest.hasPrefix("%") {
                out.append("%")
                i = format.index(i, offsetBy: 2)
            } else if rest.hasPrefix("@") {
                if next < arguments.count { out += arguments[next] }
                next += 1
                i = format.index(i, offsetBy: 2)
            } else if let dollar = rest.firstIndex(of: "$"),
                      let n = Int(rest[rest.startIndex..<dollar]),
                      format[format.index(after: dollar)...].hasPrefix("@") {
                if n >= 1, n <= arguments.count { out += arguments[n - 1] }
                i = format.index(dollar, offsetBy: 2)
            } else {
                out.append(c)
                i = format.index(after: i)
            }
        }
        return out
    }

    /// Число со словом в нужной форме: «1 файл», «3 файла», «7 055 файлов».
    /// Ключ перевода — три русские формы через `|`: `"файл|файла|файлов"`,
    /// перевод — формы своего языка: `"file|files"`.
    static func count(_ n: Int, _ one: String, _ few: String, _ many: String, grouped: Bool = true) -> String {
        let number = grouped ? n.formatted() : String(n)
        return number + " " + word(for: n, one, few, many)
    }

    /// Только слово — для фраз, где число стоит не прямо перед ним.
    static func word(for n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let language = current
        guard let table = language.table else { return russianForm(n, one, few, many) }
        let key = one + "|" + few + "|" + many
        guard let forms = table[key]?.split(separator: "|").map(String.init), !forms.isEmpty else {
            return russianForm(n, one, few, many)
        }
        // Английский: одна форма для единицы, другая для всего остального.
        return n == 1 || forms.count == 1 ? forms[0] : forms[1]
    }

    private static func russianForm(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod100 = abs(n) % 100, mod10 = abs(n) % 10
        if (11...14).contains(mod100) { return many }
        if mod10 == 1 { return one }
        if (2...4).contains(mod10) { return few }
        return many
    }
}

/// Строка интерфейса: `L("Открыть папку…")`, `L("Файлов: \(n)")`.
func L(_ key: LocalizedKey) -> String {
    Localization.string(key)
}

// MARK: - Ключ

/// Ключ перевода из строкового литерала. Интерполяции становятся `%@`
/// в ключе и аргументами подстановки: `L("Ассет \(guid) не найден")` ищет
/// в таблице `"Ассет %@ не найден"`, а перевод ставит `guid` на своё место.
struct LocalizedKey: ExpressibleByStringInterpolation {
    private(set) var key = ""
    private(set) var arguments: [String] = []

    init(stringLiteral value: String) {
        key = value.replacingOccurrences(of: "%", with: "%%")
    }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity + 2 * interpolationCount)
        }

        mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(String(describing: value))
        }
    }
}
