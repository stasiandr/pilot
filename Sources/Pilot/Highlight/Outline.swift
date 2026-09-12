import Foundation

enum OutlineKind: UInt8 {
    case type, method, property, field, function, variable, namespace, initializer, enumCase
    // Unity: объекты сцен и префабов, методы-сообщения движка, поля инспектора.
    case gameObject, component, prefab, unityMessage, serializedField

    var icon: String {
        switch self {
        case .type:        return "cube"
        case .method:      return "function"
        case .function:    return "function"
        case .property:    return "circle.grid.2x2"
        case .field:       return "tag"
        case .variable:    return "tag"
        case .namespace:   return "shippingbox"
        case .initializer: return "wrench.and.screwdriver"
        case .enumCase:    return "list.number"
        case .gameObject:      return "cube"
        case .component:       return "puzzlepiece.extension"
        case .prefab:          return "cube.transparent"
        case .unityMessage:    return "bolt"
        case .serializedField: return "slider.horizontal.3"
        }
    }

    var label: String {
        switch self {
        case .type:        return "type"
        case .method:      return "method"
        case .function:    return "func"
        case .property:    return "prop"
        case .field:       return "field"
        case .variable:    return "var"
        case .namespace:   return "ns"
        case .initializer: return "init"
        case .enumCase:    return "case"
        case .gameObject:      return "object"
        case .component:       return "comp"
        case .prefab:          return "prefab"
        case .unityMessage:    return "unity"
        case .serializedField: return "inspector"
        }
    }
}

struct OutlineItem: Identifiable {
    var id: Int
    var name: String
    var kind: OutlineKind
    /// Диапазон имени в документе (UTF-16) — туда и прыгаем.
    var range: NSRange
    var line: Int
    var depth: Int
    var container: String?
    /// Ключевое слово, которым введено объявление: `class`, `struct`, `func`.
    /// У методов C-подобных языков его нет.
    var keyword: String? = nil
}

/// Как в этом языке опознаётся объявление.
enum OutlineStyle {
    /// Объявление вводится ключевым словом: `func foo`, `def foo`, `class Bar`.
    /// Надёжно — просто берём следующий идентификатор.
    case keyword
    /// C-подобные: у метода нет вводного слова, есть только форма
    /// `Тип Имя(...) {`. Нужна эвристика.
    case cFamily
    case none
}

/// Структурный разбор файла поверх уже имеющихся токенов.
///
/// Это НЕ семантический анализ: мы не знаем типов и не резолвим имена.
/// Но для навигации по файлу этого достаточно, а главное — работает
/// мгновенно и не ждёт языкового сервера.
enum OutlineBuilder {

    /// Файлы больше этого порога не разбираем: выигрыш от структуры
    /// не окупает секунды ожидания.
    static let maxLines = 120_000

    static func build(model: SyntaxModel) -> [OutlineItem] {
        guard let spec = model.spec, spec.outline != .none else { return [] }
        guard model.lineCount <= maxLines else { return [] }

        let tokens = model.tokens(fromLine: 0, toLine: model.lineCount - 1)
        guard !tokens.isEmpty else { return [] }

        var items: [OutlineItem] = []
        var scopes: [(name: String, depth: Int)] = []
        var braceDepth = 0
        var parenDepth = 0
        /// Глубина, на которой открылось тело метода. Пока мы внутри него,
        /// объявлений не ищем — иначе каждый вызов функции станет «методом».
        var bodyDepth: Int? = nil
        /// Объявление найдено, тело ещё не началось. Нельзя входить в режим
        /// «внутри тела» сразу: у `=> выражения` и у методов интерфейса
        /// фигурных скобок нет вовсе, и флаг тогда не сбросится никогда.
        var pendingBody = false

        let units = model.units

        func text(_ token: Token) -> String {
            String(decoding: units[Int(token.start)..<Int(token.start + token.length)], as: UTF16.self)
        }

        /// Индекс следующего значимого токена (комментарии и атрибуты пропускаем).
        func nextMeaningful(after index: Int) -> Int? {
            var j = index + 1
            while j < tokens.count {
                switch tokens[j].kind {
                case .comment, .docComment, .attribute, .preprocessor: j += 1
                default: return j
                }
            }
            return nil
        }

        func isIdentifierLike(_ token: Token) -> Bool {
            switch token.kind {
            case .plain, .type, .function, .constant: return true
            default: return false
            }
        }

        func record(_ nameToken: Token, kind: OutlineKind, opensScope: Bool, keyword: String? = nil) {
            let name = text(nameToken)
            guard !name.isEmpty else { return }
            let line = model.line(containing: Int(nameToken.start))
            let depth = spec.indentBased ? indentDepth(model, line) : scopes.count

            items.append(OutlineItem(
                id: items.count,
                name: name,
                kind: kind,
                range: NSRange(location: Int(nameToken.start), length: Int(nameToken.length)),
                line: line,
                depth: depth,
                container: scopes.last?.name,
                keyword: keyword))

            if opensScope { scopes.append((name, braceDepth)) }
        }

        var i = 0
        while i < tokens.count {
            let token = tokens[i]

            // --- отслеживаем вложенность по скобкам ---
            if token.length == 1 {
                let ch = units[Int(token.start)]
                if ch == 0x7B {              // {
                    if pendingBody, bodyDepth == nil { bodyDepth = braceDepth }
                    pendingBody = false
                    braceDepth += 1
                    i += 1
                    continue
                }
                if ch == 0x7D {              // }
                    pendingBody = false
                    braceDepth -= 1
                    if let body = bodyDepth, braceDepth <= body { bodyDepth = nil }
                    while let last = scopes.last, last.depth >= braceDepth { scopes.removeLast() }
                    i += 1
                    continue
                }
                if ch == 0x3B { pendingBody = false; i += 1; continue }   // ;
                if ch == 0x28 { parenDepth += 1; i += 1; continue }       // (
                if ch == 0x29 { parenDepth = max(0, parenDepth - 1); i += 1; continue }
            }

            // Внутри тела метода объявлений не ищем. Для языков с блоками
            // по отступам скобок нет, и такой защиты не требуется:
            // там объявление всегда вводится ключевым словом.
            if !spec.indentBased, bodyDepth != nil { i += 1; continue }

            switch token.kind {
            case .comment, .docComment, .preprocessor, .attribute, .string, .number:
                i += 1
                continue
            default:
                break
            }

            let word = text(token)

            // --- объявления, вводимые ключевым словом ---
            if var kind = spec.declarationKeywords[word] {
                guard let nameIndex = nextMeaningful(after: i) else { i += 1; continue }
                var nameToken = tokens[nameIndex]
                var keyword = word

                // Swift: `init` — само по себе имя; C#: `record class Foo`.
                if kind == .initializer {
                    record(token, kind: .initializer, opensScope: false, keyword: word)
                    pendingBody = true
                    i += 1
                    continue
                }
                // Пропускаем вторичное ключевое слово: `record class Foo`, `enum class Bar`.
                // Что объявлено, решает второе слово: Swift-овый `class func foo` —
                // метод, а не класс `foo`, а `const enum Foo` в TS — тип.
                // Если оба слова типовые, оставляем первое: оно точнее.
                var nameAt = nameIndex
                if nameToken.kind == .keyword, let secondary = spec.declarationKeywords[text(nameToken)],
                   let after = nextMeaningful(after: nameIndex) {
                    if !(kind == .type && secondary == .type) {
                        kind = secondary
                        keyword = text(nameToken)
                    }
                    nameToken = tokens[after]
                    nameAt = after
                }
                guard isIdentifierLike(nameToken) else { i += 1; continue }

                // `namespace Acme.Billing`, `package com.acme.billing` — имя целиком,
                // а не только первый сегмент: лексер режет его по точкам.
                if kind == .namespace {
                    var j = nameAt
                    while j + 2 < tokens.count {
                        let dot = tokens[j + 1], part = tokens[j + 2]
                        guard dot.length == 1, units[Int(dot.start)] == 0x2E,
                              dot.start == tokens[j].start + tokens[j].length,
                              part.start == dot.start + 1, isIdentifierLike(part) else { break }
                        j += 2
                    }
                    let last = tokens[j]
                    nameToken.length = last.start + last.length - nameToken.start
                }

                let opensScope = (kind == .type || kind == .namespace)
                record(nameToken, kind: kind, opensScope: opensScope, keyword: keyword)
                pendingBody = (kind == .method || kind == .function || kind == .property)
                i += 1
                continue
            }

            // --- C-подобные: метод без вводного слова ---
            if spec.outline == .cFamily, parenDepth == 0, token.kind == .function {
                let isDeclaration = looksLikeDeclaration(tokens: tokens, at: i,
                                                         units: units, spec: spec)
                if isDeclaration {
                    record(token, kind: .method, opensScope: false)
                }
                pendingBody = isDeclaration
                i += 1
                continue
            }

            // --- C-подобные: свойство или поле ---
            // Что именно — определяет символ сразу после имени:
            //   `Имя {`  свойство,  `Имя =>` свойство-выражение,
            //   `Имя ;`  поле,      `Имя =`  поле с инициализатором.
            if spec.outline == .cFamily, parenDepth == 0, isIdentifierLike(token),
               let next = nextMeaningful(after: i),
               precededByTypeLike(tokens: tokens, at: i, units: units, spec: spec) {

                let follower = tokens[next]
                let followerChar = follower.length == 1 ? units[Int(follower.start)] : 0

                if followerChar == 0x7B {                       // {
                    record(token, kind: .property, opensScope: false)
                    pendingBody = true
                    i += 1
                    continue
                }
                if isArrow(tokens: tokens, at: next, units: units) {
                    record(token, kind: .property, opensScope: false)
                    pendingBody = false        // тело-выражение, скобок не будет
                    i += 1
                    continue
                }
                if followerChar == 0x3B {                       // ;
                    record(token, kind: .field, opensScope: false)
                    pendingBody = false
                    i += 1
                    continue
                }
                // `=`, но не `==` и не `=>`
                if followerChar == 0x3D, next + 1 < tokens.count {
                    let after = tokens[next + 1]
                    let afterChar = after.length == 1 ? units[Int(after.start)] : 0
                    if afterChar != 0x3D && afterChar != 0x3E {
                        record(token, kind: .field, opensScope: false)
                        pendingBody = false
                        i += 1
                        continue
                    }
                }
            }

            i += 1
        }

        return items
    }

    /// Стоит ли на этой позиции `=>`. Лексер выдаёт стрелку двумя токенами.
    private static func isArrow(tokens: [Token], at index: Int, units: [UInt16]) -> Bool {
        guard index + 1 < tokens.count else { return false }
        let a = tokens[index], b = tokens[index + 1]
        guard a.length == 1, b.length == 1, b.start == a.start + 1 else { return false }
        return units[Int(a.start)] == 0x3D && units[Int(b.start)] == 0x3E
    }

    // MARK: - Эвристики для C-подобных языков

    /// Объявление ли это метода, а не вызов.
    ///
    /// Два независимых признака, оба должны сойтись:
    ///   * слева стоит тип или модификатор (а не `.`, `=`, `new`, `return`);
    ///   * справа за закрывающей скобкой идёт `{`, `=>`, `;` или `where`.
    private static func looksLikeDeclaration(tokens: [Token], at index: Int,
                                             units: [UInt16], spec: LanguageSpec) -> Bool {
        guard precededByTypeLike(tokens: tokens, at: index, units: units, spec: spec) else { return false }

        // Ищем закрывающую скобку списка параметров.
        var depth = 0
        var j = index + 1
        while j < tokens.count {
            let t = tokens[j]
            if t.length == 1 {
                let ch = units[Int(t.start)]
                if ch == 0x28 { depth += 1 }                    // (
                else if ch == 0x29 {                            // )
                    depth -= 1
                    if depth == 0 { break }
                }
                // Скобка тела встретилась раньше конца параметров — это не объявление.
                if ch == 0x7B && depth == 0 { return false }
            }
            j += 1
        }
        guard j < tokens.count else { return false }

        // Что идёт после ')'
        var k = j + 1
        while k < tokens.count, tokens[k].kind == .comment || tokens[k].kind == .docComment { k += 1 }
        guard k < tokens.count else { return false }

        let after = tokens[k]
        let afterText = String(decoding: units[Int(after.start)..<Int(after.start + after.length)],
                               as: UTF16.self)
        if after.length == 1 {
            let ch = units[Int(after.start)]
            if ch == 0x7B { return true }                        // {  — тело
            if ch == 0x3B { return true }                        // ;  — абстрактный / интерфейс
            if ch == 0x3A { return true }                        // :  — : base(...)
        }
        if afterText == "=>" || afterText == "where" { return true }
        // `=` начинает `=> …` в две лексемы
        if afterText == "=", k + 1 < tokens.count {
            let n = tokens[k + 1]
            if n.length == 1 && units[Int(n.start)] == 0x3E { return true }
        }
        return false
    }

    /// Слева от имени стоит что-то, похожее на тип или модификатор.
    private static func precededByTypeLike(tokens: [Token], at index: Int,
                                           units: [UInt16], spec: LanguageSpec) -> Bool {
        var j = index - 1
        while j >= 0, tokens[j].kind == .comment || tokens[j].kind == .docComment
                    || tokens[j].kind == .attribute || tokens[j].kind == .preprocessor { j -= 1 }
        guard j >= 0 else { return false }

        let prev = tokens[j]
        let prevText = String(decoding: units[Int(prev.start)..<Int(prev.start + prev.length)],
                              as: UTF16.self)

        // Явные признаки вызова, а не объявления.
        if prev.length == 1 {
            let ch = units[Int(prev.start)]
            // . = ( , + - * / < > ! & | ? :
            if ch == 0x2E || ch == 0x3D || ch == 0x28 || ch == 0x2C || ch == 0x2B
                || ch == 0x2D || ch == 0x2A || ch == 0x2F || ch == 0x21 || ch == 0x26
                || ch == 0x7C || ch == 0x3F { return false }
            // `>` и `]` закрывают дженерик или массив — это как раз тип
            if ch == 0x3E || ch == 0x5D { return true }
        }
        if ["new", "return", "await", "throw", "yield", "case", "in", "is", "as"].contains(prevText) {
            return false
        }
        if spec.modifierKeywords.contains(prevText) { return true }
        switch prev.kind {
        case .type, .plain: return true      // `void Foo(`, `MyType Foo(`
        case .keyword:      return spec.typeKeywords.contains(prevText)
        default:            return false
        }
    }

    /// Для языков с блоками по отступам глубина берётся из самого отступа.
    private static func indentDepth(_ model: SyntaxModel, _ line: Int) -> Int {
        let range = model.lineRange(line)
        var spaces = 0
        var i = range.lowerBound
        while i < range.upperBound {
            let c = model.units[i]
            if c == 0x20 { spaces += 1 }
            else if c == 0x09 { spaces += 4 }
            else { break }
            i += 1
        }
        return spaces / 4
    }
}
