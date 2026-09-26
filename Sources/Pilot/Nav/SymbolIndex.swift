import Foundation

/// autoreleasepool есть только там, где есть Objective-C; тесты ядра гоняются и без него.
@inline(__always) func drainingAutoreleased<T>(_ body: () -> T) -> T {
    #if canImport(ObjectiveC)
    return autoreleasepool(invoking: body)
    #else
    return body()
    #endif
}

/// Объявление где-то в проекте: тип, метод, свойство, поле, значение enum.
struct Symbol: Equatable {
    var name: String
    var kind: OutlineKind
    var keyword: String?
    /// Объемлющий тип (у членов) или пространство имён (у типов верхнего уровня).
    var container: String?
    /// Тип поля и свойства, возвращаемый тип метода — как написан в коде.
    var typeText: String?
    var bases: [String] = []
    var genericParams: [String] = []
    /// У методов C-подобных языков: типы параметров, как записаны.
    /// Даёт число параметров для выбора перегрузки и `this`-получателя
    /// у методов-расширений.
    var parameters: [String] = []
    var file: Int32
    var line: Int32
    var column: Int32      // UTF-16, как у LSP
    var length: Int32
}

/// Что известно о файле целиком: нужно, чтобы понять, какой из одноимённых
/// типов имеется в виду — ближе тот, чей namespace подключён через `using`.
struct SourceFileInfo: Equatable {
    var path: String
    var namespaces: [String] = []
    var usings: [String] = []
    /// `using Vec = UnityEngine.Vector3;`
    var aliases: [String: String] = [:]
}

/// Индекс объявлений всего проекта — основа быстрого навигатора.
///
/// Строится тем же лексером и структурным разбором, что и ⌘⇧O, на всех ядрах.
/// На проекте в 26 000 файлов C# — около секунды и десятков мегабайт.
/// Семантики здесь нет: имена не резолвятся компилятором, поэтому ответы
/// приблизительные. Зато они есть с первой секунды, на любом языке, и на C#
/// — пока Rustlyn компилирует проект.
final class SymbolIndex: @unchecked Sendable {   // неизменяем после построения

    let root: URL
    private(set) var files: [SourceFileInfo] = []
    private(set) var symbols: [Symbol] = []

    /// Имя → объявления с таким именем (все виды).
    private(set) var byName: [String: [Int32]] = [:]
    /// Имя типа → его объявления (partial-классы дают несколько).
    private(set) var typesByName: [String: [Int32]] = [:]
    /// Имя типа → члены, объявленные внутри него.
    private(set) var membersByOwner: [String: [Int32]] = [:]
    /// Короткое имя базового типа → типы, назвавшие его в `: Base, IFoo`.
    /// Обратная сторона `bases`: по ней навигатор идёт вниз по иерархии.
    /// Ключ без namespace и дженериков, поэтому одноимённые базовые из разных
    /// namespace попадают вместе — разбирается это уже резолвом типов.
    private(set) var derivedByBase: [String: [Int32]] = [:]
    /// Короткое имя расширяемого типа → методы-расширения для него.
    /// `static void Say(this Player p)` зовётся как член Player, но лежит
    /// в постороннем static-классе, и через `membersByOwner` его не найти.
    private(set) var extensionsByReceiver: [String: [Int32]] = [:]

    /// «контейнер.имя» в нижнем регистре подряд — для fuzzy-поиска без аллокаций.
    private var bytes: [UInt8] = []
    private var spans: [(start: Int32, length: Int32, nameStart: Int32)] = []

    init(root: URL) { self.root = root }

    var count: Int { symbols.count }

    subscript(id: Int32) -> Symbol { symbols[Int(id)] }

    func relPath(_ id: Int32) -> String { files[Int(symbols[Int(id)].file)].path }

    func fileInfo(_ id: Int32) -> SourceFileInfo { files[Int(symbols[Int(id)].file)] }

    func target(_ id: Int32) -> NavTarget {
        let s = symbols[Int(id)]
        let start = LSPPosition(line: Int(s.line), character: Int(s.column))
        let end = LSPPosition(line: Int(s.line), character: Int(s.column + s.length))
        return NavTarget(url: root.appendingPathComponent(files[Int(s.file)].path),
                         range: LSPRange(start: start, end: end))
    }

    static func isType(_ kind: OutlineKind) -> Bool { kind == .type }

    static func isMember(_ kind: OutlineKind) -> Bool {
        switch kind {
        case .method, .property, .field, .enumCase, .initializer, .function, .variable,
             .unityMessage, .serializedField: return true
        case .type, .namespace, .gameObject, .component, .prefab, .heading: return false
        }
    }

    // MARK: - Наполнение

    fileprivate func append(file: SourceFileInfo, _ found: some Sequence<Symbol>) {
        let fileID = Int32(files.count)
        files.append(file)
        for var s in found {
            s.file = fileID
            symbols.append(s)
        }
    }

    /// Таблицы поиска — после того как все файлы добавлены.
    fileprivate func finish() {
        byName.reserveCapacity(symbols.count)
        spans.reserveCapacity(symbols.count)
        for (i, s) in symbols.enumerated() {
            let id = Int32(i)
            byName[s.name, default: []].append(id)
            if Self.isType(s.kind) {
                typesByName[s.name, default: []].append(id)
                for base in s.bases { derivedByBase[Self.baseKey(base), default: []].append(id) }
            }
            if Self.isMember(s.kind), let owner = s.container { membersByOwner[owner, default: []].append(id) }
            if let receiver = Self.extensionReceiver(s) { extensionsByReceiver[receiver, default: []].append(id) }

            let start = bytes.count
            var nameStart = 0
            if let container = s.container {
                for b in container.utf8 { bytes.append(Self.lower(b)) }
                bytes.append(0x2E)
                nameStart = bytes.count - start
            }
            for b in s.name.utf8 { bytes.append(Self.lower(b)) }
            spans.append((Int32(start), Int32(bytes.count - start), Int32(nameStart)))
        }
    }

    /// Тип, который расширяет метод: `static void Say(this Player p)` → `Player`.
    /// nil — обычный метод. Ключ такой же короткий, как у наследников:
    /// одноимённые типы разбирает уже навигатор.
    static func extensionReceiver(_ s: Symbol) -> String? {
        guard s.kind == .method, let first = s.parameters.first,
              first.hasPrefix(extensionMarker) else { return nil }
        return baseKey(String(first.dropFirst(extensionMarker.count)))
    }

    /// Как записан получатель метода-расширения в C#.
    static let extensionMarker = "this "

    /// Ключ `derivedByBase`: имя базового типа без namespace и дженериков.
    /// `Game.Ecs.Base<T>` → `Base`.
    static func baseKey(_ text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespaces)
        if let lt = name.firstIndex(of: "<") { name = String(name[..<lt]) }
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        return name
    }

    @inline(__always) private static func lower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 32 : b
    }

    // MARK: - Разбор одного файла

    /// Разбирать ли файл вообще: только языки, у которых есть структурный разбор.
    static func spec(forPath path: String) -> LanguageSpec? {
        guard let spec = Languages.detect(filename: (path as NSString).lastPathComponent),
              spec.outline != .none else { return nil }
        return spec
    }

    static func extract(text: String, spec: LanguageSpec, path: String) -> (SourceFileInfo, [Symbol]) {
        let model = SyntaxModel(text: text, spec: spec)
        var info = SourceFileInfo(path: path)
        var found: [Symbol] = []
        for item in OutlineBuilder.build(model: model) {
            if item.kind == .namespace {
                info.namespaces.append(item.name)
                continue
            }
            let position = model.position(at: item.range.location)
            found.append(Symbol(name: item.name, kind: item.kind, keyword: item.keyword,
                                container: item.container, typeText: item.typeText,
                                bases: item.bases, genericParams: item.genericParams,
                                parameters: item.parameters,
                                file: 0, line: Int32(position.line),
                                column: Int32(position.character), length: Int32(item.range.length)))
        }
        if spec.outline == .cFamily {
            readUsings(model, into: &info)
            found += includedStashes(model, outline: found)
        }
        return (info, found)
    }

    /// Поля, которые допишет кодогенератор Morpeh: `[IncludeStash(typeof(Health))]`
    /// над системой превращается в `private readonly Stash<Health> _health;`.
    /// В исходниках этого поля нет, а обращений к нему — десятки тысяч, поэтому
    /// повторяем правило генератора: `_` + имя компонента со строчной буквы или
    /// имя из второго аргумента. «Объявлением» считаем сам атрибут.
    static func includedStashes(_ model: SyntaxModel, outline: [Symbol]) -> [Symbol] {
        let units = model.units
        let marker = Array("IncludeStash(typeof(".utf16)
        guard units.count > marker.count else { return [] }
        var result: [Symbol] = []
        var i = 0
        let last = units.count - marker.count
        while i <= last {
            guard units[i] == marker[0] else { i += 1; continue }
            var k = 1
            while k < marker.count, units[i + k] == marker[k] { k += 1 }
            guard k == marker.count else { i += 1; continue }

            // Имя компонента: `typeof(Foo)` или `typeof(Ns.Foo)`; дженерики пропускаем.
            var j = i + marker.count
            let start = j
            while j < units.count, isNameUnit(units[j]) || units[j] == 0x2E { j += 1 }
            guard j < units.count, j > start, units[j] == 0x29 else { i = j; continue }   // )
            var nameStart = start
            for p in start..<j where units[p] == 0x2E { nameStart = p + 1 }
            let component = String(decoding: units[nameStart..<j], as: UTF16.self)

            // Необязательное явное имя поля: `, "customName")`.
            var fieldName = "_" + component.prefix(1).lowercased() + component.dropFirst()
            var p = j + 1
            while p < units.count, units[p] == 0x20 { p += 1 }
            if p < units.count, units[p] == 0x2C {
                p += 1
                while p < units.count, units[p] == 0x20 { p += 1 }
                if p < units.count, units[p] == 0x22 {
                    let q = p + 1
                    var e = q
                    while e < units.count, units[e] != 0x22, units[e] != 0x0A { e += 1 }
                    if e < units.count, units[e] == 0x22, e > q {
                        fieldName = String(decoding: units[q..<e], as: UTF16.self)
                    }
                }
            }

            // Атрибут относится к ближайшему типу, объявленному ниже.
            let position = model.position(at: nameStart)
            if let owner = outline.first(where: { $0.kind == .type
                                                  && ($0.line > position.line
                                                      || ($0.line == position.line && $0.column > position.character)) }) {
                result.append(Symbol(name: fieldName, kind: .field, keyword: nil, container: owner.name,
                                     typeText: "Stash<\(component)>", file: 0,
                                     line: Int32(position.line), column: Int32(position.character),
                                     length: Int32(j - nameStart)))
            }
            i = j
        }
        return result
    }

    @inline(__always) private static func isNameUnit(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c > 0x7F
    }

    /// `using A.B;`, `global using A.B;`, `using static A.B;`, `using V = A.B;`.
    /// Строки внутри методов (`using var x = …;`, `using (…)`) отсеиваются формой.
    static func readUsings(_ model: SyntaxModel, into info: inout SourceFileInfo) {
        let units = model.units
        for line in 0..<model.lineCount {
            let range = model.lineRange(line)
            var i = range.lowerBound
            while i < range.upperBound, units[i] == 0x20 || units[i] == 0x09 { i += 1 }
            // Дёшево отсеиваем всё, что не начинается на `u` или `g`.
            guard i < range.upperBound, units[i] == 0x75 || units[i] == 0x67 else { continue }
            var text = String(decoding: units[i..<range.upperBound], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("global ") { text.removeFirst(7) }
            guard text.hasPrefix("using "), let semicolon = text.firstIndex(of: ";"),
                  !text.contains("(") else { continue }
            var body = text[text.index(text.startIndex, offsetBy: 6)..<semicolon]
                .trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("static ") { body = String(body.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            if let eq = body.firstIndex(of: "=") {
                let alias = body[..<eq].trimmingCharacters(in: .whitespaces)
                let target = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                // `using var x = …` — не псевдоним: слева два слова.
                guard !alias.isEmpty, !alias.contains(" "), !target.isEmpty else { continue }
                info.aliases[alias] = target
            } else if !body.isEmpty, !body.contains(" ") {
                info.usings.append(body)
            }
        }
    }

    // MARK: - Построение

    /// Разбирает все исходники проекта на всех ядрах — вызывать только из фона.
    /// Если воркспейс сменился, возвращает nil, а не половину индекса.
    static func build(root: URL, files: [String], shouldStop: @escaping () -> Bool) -> SymbolIndex? {
        let found = parse(root: root, files: files, shouldStop: shouldStop)
        if shouldStop() { return nil }

        let index = SymbolIndex(root: root)
        // Файл без объявлений держим только ради его `using` — по ним
        // разбираются одноимённые типы.
        for (info, symbols) in found.sorted(by: { $0.0.path < $1.0.path })
        where !symbols.isEmpty || !info.usings.isEmpty {
            index.append(file: info, symbols)
        }
        index.finish()
        return index
    }

    /// Те же исходники, но разобранные поверх готового индекса: символы файлов,
    /// которых нет в `changed` и `removed`, переносятся как есть — ни чтения
    /// диска, ни лексера на них не тратится. Старый индекс не меняется, он
    /// неизменяем и продолжает отвечать из фона, пока новый строится.
    ///
    /// В `removed` может лежать и папка: удалённая целиком, она приходит одним
    /// путём, а событий по своим файлам не присылает. Поэтому уходит и всё,
    /// что лежало под ней.
    static func updating(_ base: SymbolIndex, changed: [String], removed: Set<String> = [],
                         shouldStop: @escaping () -> Bool) -> SymbolIndex? {
        let parsed = parse(root: base.root, files: changed.filter { !removed.contains($0) },
                           shouldStop: shouldStop)
        if shouldStop() { return nil }

        // Всё, что назвали, из старого индекса уходит: файл мог опустеть,
        // мог перестать быть исходником, мог исчезнуть с диска.
        let handled = Set(changed).union(removed)

        // Символы каждого файла лежат подряд — и build, и deserialize пишут
        // их пофайлово. Границы находим одним проходом, без копирования.
        var end = [Int](repeating: 0, count: base.files.count)
        for (i, s) in base.symbols.enumerated() { end[Int(s.file)] = i + 1 }
        var cursor = 0
        var start = [Int](repeating: 0, count: base.files.count)
        for i in 0..<base.files.count {
            start[i] = cursor
            if end[i] < cursor { end[i] = cursor }   // файл без объявлений
            cursor = end[i]
        }

        let fresh = SymbolIndex(root: base.root)
        for (i, file) in base.files.enumerated() {
            if handled.contains(file.path) { continue }
            if !removed.isEmpty, removed.contains(where: { file.path.hasPrefix($0 + "/") }) { continue }
            fresh.append(file: file, base.symbols[start[i]..<end[i]])
        }
        // Перепарсенные и новые — следом. Общий порядок путей сбивается,
        // но на ответы он не влияет: сравнения путей везде явные.
        for (info, symbols) in parsed.sorted(by: { $0.0.path < $1.0.path })
        where !symbols.isEmpty || !info.usings.isEmpty {
            fresh.append(file: info, symbols)
        }
        if shouldStop() { return nil }
        fresh.finish()
        return fresh
    }

    /// Разбор пачки файлов на всех ядрах. Возвращает и пустые результаты —
    /// по ним видно, что файл разобран и объявлений в нём не осталось.
    /// Что среди исходников `files` поменялось с `since` относительно
    /// `base`: изменённые и появившиеся после (по времени файла) — к разбору,
    /// пропавшие — к удалению. `stat` на исходник — это доли секунды на проект, а
    /// разбирать заново все — десятки секунд.
    static func changes(from base: SymbolIndex, files: [String], since: Date)
        -> (changed: [String], removed: Set<String>) {
        // Запас: время файла и время начала прошлой сборки — разные часы.
        let cutoff = Int(since.timeIntervalSince1970) - 2
        let known = Set(base.files.map(\.path))
        var specs: [String: Bool] = [:]
        var present = Set<String>()
        var changed: [String] = []
        let root = base.root.path
        for path in files {
            let ext = (path as NSString).pathExtension.lowercased()
            let source = specs[ext] ?? {
                let found = spec(forPath: path) != nil
                specs[ext] = found
                return found
            }()
            guard source else { continue }
            present.insert(path)
            // Файла нет в индексе, но он не менялся с прошлой сборки — значит,
            // тогда в нём не нашлось ни объявлений, ни `using`: индекс такие
            // не хранит. Разбирать его снова незачем.
            if modificationTime(root + "/" + path) >= cutoff {
                changed.append(path)
            }
        }
        return (changed, known.subtracting(present))
    }

    /// Секунды времени изменения; `Int.max` — не удалось узнать, и тогда
    /// файл считается изменённым.
    private static func modificationTime(_ path: String) -> Int {
        var info = stat()
        guard stat(path, &info) == 0 else { return Int.max }
        #if os(Linux)
        return Int(info.st_mtim.tv_sec)
        #else
        return Int(info.st_mtimespec.tv_sec)
        #endif
    }

    private static func parse(root: URL, files: [String],
                              shouldStop: @escaping () -> Bool) -> [(SourceFileInfo, [Symbol])] {
        var specsByExtension: [String: LanguageSpec?] = [:]
        var candidates: [(path: String, spec: LanguageSpec)] = []
        for path in files {
            let ext = (path as NSString).pathExtension.lowercased()
            let spec: LanguageSpec?
            if let known = specsByExtension[ext] {
                spec = known
            } else {
                spec = Self.spec(forPath: path)
                specsByExtension[ext] = spec
            }
            if let spec { candidates.append((path, spec)) }
        }

        // Файлы раздаются по одному из общей очереди: крупные лежат кучно,
        // и нарезка заранее оставила бы часть ядер без дела.
        let lock = NSLock()
        var next = 0
        var found: [(SourceFileInfo, [Symbol])] = []
        let workers = max(1, min(candidates.count, ProcessInfo.processInfo.activeProcessorCount))

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var local: [(SourceFileInfo, [Symbol])] = []
            while !shouldStop() {
                lock.lock()
                let i = next
                next += 1
                lock.unlock()
                guard i < candidates.count else { break }

                let (path, spec) = candidates[i]
                // Без пула временные объекты Foundation копятся до конца всего
                // прохода: на 26 000 файлов это гигабайты.
                drainingAutoreleased {
                    guard let text = readSource(root.appendingPathComponent(path)) else { return }
                    local.append(extract(text: text, spec: spec, path: path))
                }
            }
            lock.lock()
            found.append(contentsOf: local)
            lock.unlock()
        }
        return found
    }

    /// Файлы больше этого почти всегда сгенерированы, а разбор одного такого
    /// съел бы больше времени, чем весь остальной проект.
    static let maxFileBytes = 1 << 20

    /// Читаем так же, как LoadedDocument: иначе колонки разъедутся на файлах не в UTF-8.
    static func readSource(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxFileBytes,
              !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Типы в форме индекса ⇧⇧ — чтобы не разбирать проект второй раз.
    func typeEntries() -> [(path: String, declarations: [TypeDeclaration])] {
        var result: [(path: String, declarations: [TypeDeclaration])] = []
        var current: Int32 = -1
        for s in symbols where s.kind == .type {
            guard let keyword = s.keyword, TypeIndex.typeKeywords.contains(keyword) else { continue }
            let declaration = TypeDeclaration(name: s.name, container: s.container, keyword: keyword,
                                              file: 0, line: s.line, column: s.column, length: s.length)
            if s.file != current {
                current = s.file
                result.append((files[Int(s.file)].path, []))
            }
            result[result.count - 1].declarations.append(declaration)
        }
        return result
    }

    // MARK: - Поиск (⌘T)

    /// До `limit` лучших объявлений. Запрос с точкой (`Player.Move`) матчится
    /// по полному имени с контейнером, без точки — только по имени.
    func search(_ queryString: String, limit: Int, shouldStop: () -> Bool) -> [SearchHit] {
        let q = FuzzyMatch.Query(queryString)
        guard !q.isEmpty else { return [] }
        let qualified = q.lower.contains(0x2E)

        var results: [SearchHit] = []
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var positions: [Int32]? = []
            for i in 0..<spans.count {
                if i & 0x3FF == 0 && shouldStop() { return }
                let span = spans[i]
                let skip = qualified ? 0 : Int(span.nameStart)
                let ptr = base + Int(span.start) + skip
                let len = Int(span.length) - skip
                guard FuzzyMatch.firstPass(q, ptr, len) != nil,
                      let s = FuzzyMatch.score(q, text: ptr, len: len,
                                               nameStart: Int(span.nameStart) - skip,
                                               positions: &positions) else { continue }
                let shift = Int32(Int(span.nameStart) - skip)
                let inName = (positions ?? []).compactMap { $0 >= shift ? $0 - shift : nil }
                results.append(SearchHit(id: Int32(i), score: s, positions: inName))
            }
        }
        if shouldStop() { return [] }

        // При равных очках: типы выше членов, короткое имя выше длинного.
        func rank(_ kind: OutlineKind) -> Int {
            switch kind {
            case .type: return 0
            case .method, .function, .initializer, .unityMessage: return 1
            case .property: return 2
            case .field, .variable, .serializedField: return 3
            case .enumCase: return 4
            case .namespace: return 5
            case .gameObject, .component, .prefab: return 6
            case .heading: return 7
            }
        }
        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = symbols[Int($0.id)], b = symbols[Int($1.id)]
            if rank(a.kind) != rank(b.kind) { return rank(a.kind) < rank(b.kind) }
            if a.name.utf8.count != b.name.utf8.count { return a.name.utf8.count < b.name.utf8.count }
            return files[Int(a.file)].path < files[Int(b.file)].path
        }
        if results.count > limit { results.removeSubrange(limit...) }
        return results
    }

    // MARK: - Кэш на диске
    //
    // Текстом. `F<tab>путь<tab>namespaces<tab>usings<tab>aliases` открывает файл,
    // дальше по строке на объявление. Списки — через `;`, псевдонимы — `имя=цель`.

    private static let cacheHeader = "pilot-symbols 2"

    func serialized() -> String {
        var out = [Self.cacheHeader]
        out.reserveCapacity(symbols.count + files.count + 1)
        var current: Int32 = -1
        // Поле — одна строка без табуляций, элемент списка — ещё и без `;`.
        // Текст из исходника бывает любым: параметр шейдера с `#ifdef` на
        // следующей строке разрывал запись, и весь кэш не читался.
        func field(_ text: String) -> String {
            guard text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { return text }
            return String(text.map { $0 == "\t" || $0 == "\n" || $0 == "\r" ? " " : $0 })
        }
        func list(_ items: [String]) -> String {
            items.map { field($0).replacingOccurrences(of: ";", with: ",") }.joined(separator: ";")
        }
        func flushFile(_ f: SourceFileInfo) {
            let aliases = list(f.aliases.map { "\($0.key)=\($0.value)" }.sorted())
            out.append("F\t\(field(f.path))\t\(list(f.namespaces))\t\(list(f.usings))\t\(aliases)")
        }
        var written = Set<Int32>()
        for s in symbols {
            if s.file != current {
                current = s.file
                flushFile(files[Int(s.file)])
                written.insert(s.file)
            }
            out.append([String(s.kind.rawValue), field(s.name), field(s.keyword ?? ""), field(s.container ?? ""),
                        field(s.typeText ?? ""), list(s.bases), list(s.genericParams), list(s.parameters),
                        String(s.line), String(s.column), String(s.length)].joined(separator: "\t"))
        }
        // Файлы без объявлений (только using) тоже нужны — ради псевдонимов.
        for (i, f) in files.enumerated() where !written.contains(Int32(i)) { flushFile(f) }
        return out.joined(separator: "\n")
    }

    /// nil, если формат чужой или битый — тогда просто ждём свежего индекса.
    static func deserialize(_ text: String, root: URL) -> SymbolIndex? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard lines.next() == Substring(cacheHeader) else { return nil }

        func list(_ s: Substring) -> [String] {
            s.isEmpty ? [] : s.split(separator: ";").map(String.init)
        }

        let index = SymbolIndex(root: root)
        var file: SourceFileInfo?
        var pending: [Symbol] = []
        func flush() {
            if let file { index.append(file: file, pending) }
            pending.removeAll(keepingCapacity: true)
        }

        while let line = lines.next() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.first == "F" {
                guard fields.count == 5 else { return nil }
                flush()
                var aliases: [String: String] = [:]
                for pair in list(fields[4]) {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 { aliases[String(parts[0])] = String(parts[1]) }
                }
                file = SourceFileInfo(path: String(fields[1]), namespaces: list(fields[2]),
                                      usings: list(fields[3]), aliases: aliases)
                continue
            }
            // Битая строка стоит одного объявления, а не всего кэша.
            guard file != nil, fields.count == 11,
                  let raw = UInt8(fields[0]), let kind = OutlineKind(rawValue: raw),
                  let row = Int32(fields[8]), let column = Int32(fields[9]),
                  let length = Int32(fields[10]) else { continue }
            pending.append(Symbol(
                name: String(fields[1]), kind: kind,
                keyword: fields[2].isEmpty ? nil : String(fields[2]),
                container: fields[3].isEmpty ? nil : String(fields[3]),
                typeText: fields[4].isEmpty ? nil : String(fields[4]),
                bases: list(fields[5]), genericParams: list(fields[6]),
                parameters: list(fields[7]),
                file: 0, line: row, column: column, length: length))
        }
        flush()
        index.finish()
        return index
    }
}
