import Foundation

// MARK: - Где искать

/// Одна палитра поиска на всё: файлы, типы, символы и текст в файлах.
/// Область — фильтр поверх неё, а не отдельный поиск: сочетание клавиш
/// открывает ту же палитру, только сразу с нужным фильтром.
enum SearchScope: Int, CaseIterable, Equatable {
    case everything, files, types, symbols, text

    var title: String {
        switch self {
        case .everything: return L("Всё")
        case .files:      return L("Файлы")
        case .types:      return L("Типы")
        case .symbols:    return L("Символы")
        case .text:       return L("Текст")
        }
    }

    var placeholder: String {
        switch self {
        case .everything: return L("Файл, класс, символ или текст…")
        case .files:      return L("Перейти к файлу…")
        case .types:      return L("Класс, интерфейс, структура…")
        case .symbols:    return L("Символ в проекте…")
        case .text:       return L("Текст в файлах проекта…")
        }
    }

    var icon: String {
        switch self {
        case .everything: return "magnifyingglass"
        case .files:      return "doc"
        case .types:      return "cube"
        case .symbols:    return "number"
        case .text:       return "text.magnifyingglass"
        }
    }

    /// Какие источники спрашивать.
    func includes(_ source: SearchSource) -> Bool {
        switch self {
        case .everything: return true
        case .files:      return source == .file
        case .types:      return source == .type || source == .assembly
        case .symbols:    return source == .type || source == .member || source == .assembly
        case .text:       return source == .text
        }
    }
}

/// Откуда строка выдачи.
enum SearchSource: Int, Equatable {
    case file, type, member, assembly, text
}

// MARK: - Что имеется в виду

/// Что, судя по запросу, ищут. Не жёсткое решение, а веса: найдётся всё,
/// что совпало, но выше встанет то, что похоже на задуманное.
///
/// - `/` или расширение файла (`Player.cs`, `ui/menu`) — файл;
/// - точка между именами (`Game.Pawn`) — имя с контейнером;
/// - PascalCase и сокращения (`PlPawn`, `USvc`) — тип или член;
/// - пробел, кавычки, скобки, `=`, кириллица — то, чего в именах не бывает,
///   значит, это текст в файлах.
struct SearchIntent: Equatable {
    var path = false
    var qualified = false
    var pascal = false
    var text = false
    /// Запрос, по которому судят о совпадении имени: для `Game.Pawn` — `Pawn`.
    var name = ""

    static func classify(_ raw: String) -> SearchIntent {
        let query = raw.trimmingCharacters(in: .whitespaces)
        var intent = SearchIntent()
        guard !query.isEmpty else { return intent }

        var identifierOnly = true
        var dots = 0
        var slash = false
        for scalar in query.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_":
                continue
            case ".":
                dots += 1
            case "/", "\\":
                slash = true
            case "-", "@", "*":
                // Дефис и звёздочка бывают в именах файлов и в масках, но не
                // в именах C#.
                identifierOnly = false
            default:
                identifierOnly = false
                intent.text = true
            }
        }
        if intent.text {
            intent.name = query
            return intent
        }

        // Расширение пишут строчными (`Player.cs`), а член типа — с заглавной
        // (`Game.Pawn`): `Game.Asset` — это член, `Game.asset` — файл.
        let lastDot = query.lastIndex(of: ".")
        let suffix = lastDot.map { String(query[query.index(after: $0)...]) } ?? ""
        let looksLikeFile = suffix.first?.isLowercase == true
            && Self.fileExtensions.contains(suffix.lowercased())
        intent.path = slash || looksLikeFile
        intent.qualified = !intent.path && dots > 0 && identifierOnly

        let last = intent.qualified
            ? String(query.split(separator: ".", omittingEmptySubsequences: true).last ?? "")
            : intent.path ? Self.stem(of: Self.lastComponent(query)) : query
        intent.name = last
        let uppercase = last.unicodeScalars.filter { ("A"..."Z").contains($0) }.count
        intent.pascal = !intent.path && (uppercase >= 2 || last.first?.isUppercase == true)
        return intent
    }

    /// Насколько источник подходит под намерение: прибавка к ступени.
    func weight(_ source: SearchSource) -> Int {
        if text { return source == .text ? 5 : 0 }
        if path { return source == .file ? 3 : 0 }
        switch source {
        case .file:     return qualified ? 0 : 1
        case .type:     return qualified || pascal ? 2 : 1
        case .member:   return qualified ? 2 : 1
        case .assembly: return qualified || pascal ? 1 : 0
        // Текст ниже любого совпадения имени: `Player` — скорее класс, чем
        // строчка, где это слово написано.
        case .text:     return -10
        }
    }

    static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func stem(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// Расширения, по которым `что-то.ext` — это файл, а не `Тип.Член`.
    static let fileExtensions: Set<String> = [
        "cs", "csproj", "sln", "slnx", "props", "targets", "asmdef", "asmref", "rsp",
        "json", "jsonc", "yaml", "yml", "xml", "toml", "ini", "cfg", "config", "plist",
        "md", "txt", "rst", "log", "csv",
        "swift", "rs", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "java", "kt", "kts",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "lua", "rb", "php", "sh", "zsh", "ps1",
        "html", "htm", "css", "scss", "less", "uss", "uxml", "svg",
        "shader", "hlsl", "cginc", "compute", "glsl", "shadergraph", "shadersubgraph",
        "unity", "prefab", "asset", "mat", "anim", "controller", "overrideController",
        "physicMaterial", "mixer", "playable", "signal", "spriteatlas", "meta",
        "png", "jpg", "jpeg", "tga", "psd", "exr", "hdr", "gif", "tif", "tiff",
        "fbx", "obj", "blend", "wav", "mp3", "ogg", "ttf", "otf", "dll", "so", "dylib",
        "lock", "gitignore", "editorconfig",
    ].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }
}

// MARK: - Строка-кандидат

/// Совпадение из любого источника. Что показывать, решает тот, кто
/// собирал: здесь только то, по чему ранжируют.
struct SearchCandidate: Equatable {
    var source: SearchSource
    /// Имя, по которому судят о точности: имя типа, члена, файла без пути.
    /// У строки текста — сама строка.
    var name: String
    /// Путь относительно корня: для близости к открытому файлу и повторов.
    var path: String
    /// Очки нечёткого совпадения своего индекса (или поиска по тексту).
    var score: Int
    /// Номер в источнике — по нему строка и собирается.
    var id: Int32
    /// Совпало целым словом — только для текста.
    var wholeWord = false
    /// Что подсветить в показанной строке.
    var positions: [Int32] = []
    /// Из второй половины пары: номер — в её индексах, а не в своих.
    var pair = false
}

// MARK: - Ранжирование

enum UnifiedSearch {

    /// Точность совпадения имени: 4 — совпало как есть, 3 — без учёта
    /// регистра, 2 — с начала, 1 — подстрокой, 0 — только нечётко.
    static func quality(of name: String, for intent: SearchIntent, source: SearchSource) -> Int {
        let query = intent.name
        guard !query.isEmpty else { return 0 }
        var subject = name
        if source == .file {
            // `Player.cs` по запросу `Player` — точное совпадение, по
            // `Player.cs` — тоже.
            let full = SearchIntent.lastComponent(name)
            subject = query.contains(".") ? full : SearchIntent.stem(of: full)
        }
        if subject == query { return 4 }
        let lowerSubject = subject.lowercased(), lowerQuery = query.lowercased()
        if lowerSubject == lowerQuery { return 3 }
        if lowerSubject.hasPrefix(lowerQuery) { return 2 }
        if lowerSubject.contains(lowerQuery) { return 1 }
        return 0
    }

    /// Ступень строки: точность плюс то, насколько источник подходит
    /// под намерение. Внутри ступени решают очки.
    static func tier(_ candidate: SearchCandidate, intent: SearchIntent) -> Int {
        if candidate.source == .text {
            return intent.weight(.text) + (candidate.wholeWord ? 1 : 0)
        }
        return quality(of: candidate.name, for: intent, source: candidate.source) * 2
            + intent.weight(candidate.source)
    }

    /// Прибавка за близость к открытому файлу: та же папка, тот же
    /// верхний каталог. Искомое обычно рядом с тем, что правят.
    static func proximity(_ path: String, near: String?) -> Int {
        guard let near, !near.isEmpty, !path.isEmpty else { return 0 }
        let a = path.split(separator: "/").dropLast()
        let b = near.split(separator: "/").dropLast()
        var shared = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            shared += 1
        }
        if shared == a.count && shared == b.count { return 12 }   // одна папка
        return min(shared, 4) * 2
    }

    /// Порядок при равных ступени и очках: тип, член, файл, сборка, текст.
    private static func order(_ source: SearchSource) -> Int {
        switch source {
        case .type: return 0
        case .member: return 1
        case .file: return 2
        case .assembly: return 3
        case .text: return 4
        }
    }

    /// Все кандидаты одним списком, лучшие сверху.
    ///
    /// `near` — путь открытого файла, `recent` — файлы открытых вкладок:
    /// они получают прибавку. Файл, в котором объявлен найденный тип с тем
    /// же именем (`Player.cs` рядом с `class Player`), — повтор той же
    /// строки и выбрасывается, если только не искали именно файл.
    static func rank(_ candidates: [SearchCandidate], intent: SearchIntent,
                     near: String? = nil, recent: Set<String> = [], limit: Int = 300) -> [SearchCandidate] {
        var declared = Set<String>()
        if !intent.path {
            for c in candidates where c.source == .type {
                declared.insert(c.path + "\u{0}" + c.name)
            }
        }
        var keyed: [(tier: Int, score: Int, candidate: SearchCandidate)] = []
        keyed.reserveCapacity(candidates.count)
        for c in candidates {
            if c.source == .file, !declared.isEmpty,
               declared.contains(c.path + "\u{0}" + SearchIntent.stem(of: SearchIntent.lastComponent(c.path))) {
                continue
            }
            var score = c.score + proximity(c.path, near: near)
            if recent.contains(c.path) { score += 10 }
            keyed.append((tier(c, intent: intent), score, c))
        }
        keyed.sort { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.score != b.score { return a.score > b.score }
            let oa = order(a.candidate.source), ob = order(b.candidate.source)
            if oa != ob { return oa < ob }
            if a.candidate.name.count != b.candidate.name.count {
                return a.candidate.name.count < b.candidate.name.count
            }
            return a.candidate.path < b.candidate.path
        }
        return keyed.prefix(limit).map(\.candidate)
    }

    /// Нечёткое совпадение произвольного имени — для того, что пришло не из
    /// своих индексов (символы языкового сервера). Очки те же, что у индексов.
    static func fuzzy(_ query: String, _ name: String) -> (score: Int, positions: [Int32])? {
        let q = FuzzyMatch.Query(query)
        guard !q.isEmpty else { return nil }
        let bytes = Array(name.utf8)
        var positions: [Int32]? = []
        let score = bytes.withUnsafeBufferPointer { buf -> Int? in
            guard let base = buf.baseAddress else { return nil }
            return FuzzyMatch.score(q, text: base, len: buf.count, nameStart: 0, positions: &positions)
        }
        return score.map { ($0, positions ?? []) }
    }
}
