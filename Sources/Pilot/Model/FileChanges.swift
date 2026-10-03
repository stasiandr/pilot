import Foundation

/// Одно событие файловой системы — уже без подробностей FSEvents.
struct FileEvent: Equatable {
    /// Абсолютный путь, как его прислала система.
    var path: String
    /// Файл появился, исчез или переименован, — значит, список файлов проекта
    /// устарел. У простой правки содержимого этого флага нет.
    var structural: Bool
    /// Система просит пересмотреть всё поддерево: событий не хватило буфера
    /// или корень переехал.
    var subtree: Bool = false
}

/// Что принесла пачка событий.
struct FileChangeBatch: Equatable {
    /// Файлы, которые надо перечитать.
    var changed: Set<String> = []
    /// Пути, исчезнувшие с диска: файл или целая папка.
    var removed: Set<String> = []
    /// Список файлов проекта пора собрать заново.
    var needsRescan = false
    /// Тронут сам репозиторий: ветка, статус, индекс git.
    var gitTouched = false

    var isEmpty: Bool { changed.isEmpty && removed.isEmpty && !needsRescan && !gitTouched }
}

/// Разбор пачки событий файловой системы. Вынесен из `FileWatcher` нарочно:
/// FSEvents есть только на macOS, а вся логика, которую стоит проверять, —
/// здесь, и она попадает в тесты ядра.
enum FileChanges {

    /// Раскладывает события по корзинам.
    ///
    /// Правку от удаления отделяет не флаг события, а диск: флаги FSEvents
    /// склеиваются между собой, и «создан» вместе с «удалён» в одной пачке —
    /// обычное дело, а `exists` говорит, как есть сейчас.
    ///
    /// `known` — есть ли путь (файл или папка) в списке файлов проекта; без
    /// него любое создание и удаление считается изменением списка.
    ///
    /// `ownWrites` — то, что Pilot записал сам. Запись атомарная, через
    /// временный файл и переименование, и системе видна как создание файла;
    /// но список файлов проекта от своего же `⌘S` не меняется.
    static func classify(_ events: [FileEvent], root: URL, ignore: IgnoreMatcher,
                         ownWrites: Set<String> = [],
                         known: ((String) -> Bool)? = nil,
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> FileChangeBatch {
        var batch = FileChangeBatch()
        let prefix = root.path + "/"
        for event in events {
            guard event.path.hasPrefix(prefix) else {
                // Событие на самом корне: папку переименовали или пересоздали.
                if event.path == root.path { batch.needsRescan = true }
                continue
            }
            let rel = String(event.path.dropFirst(prefix.count))
            guard !rel.isEmpty else { continue }

            // Внутренности репозитория в индекс не идут, но по ним видно
            // переключение ветки: .git/HEAD и .git/index.
            if rel == ".git" || rel.hasPrefix(".git/") {
                batch.gitTouched = true
                continue
            }
            guard !isIgnored(rel, ignore) else { continue }

            if event.subtree { batch.needsRescan = true }
            if exists(event.path) {
                batch.changed.insert(rel)
                // Атомарная запись чужого редактора — тоже «создан», но файл,
                // который уже в списке, списка не меняет.
                if event.structural, !ownWrites.contains(rel), known?(rel) != true { batch.needsRescan = true }
            } else {
                batch.removed.insert(rel)
                // Временный файл той же записи исчез, не попав в список, —
                // список тоже прежний. `known` знает и папки: удалённая папка
                // его меняет.
                if known?(rel) ?? true { batch.needsRescan = true }
            }
        }
        return batch
    }

    /// Игнорируется ли путь сам или любая папка над ним: правило `/Library/`
    /// сказано про папку, а событие приходит на файл глубоко внутри неё.
    static func isIgnored(_ rel: String, _ ignore: IgnoreMatcher) -> Bool {
        if ignore.isIgnored(relPath: rel, name: lastComponent(rel), isDir: false) { return true }
        var from = rel.startIndex
        while let slash = rel[from...].firstIndex(of: "/") {
            let dir = String(rel[..<slash])
            if ignore.isIgnored(relPath: dir, name: lastComponent(dir), isDir: true) { return true }
            from = rel.index(after: slash)
        }
        return false
    }

    private static func lastComponent(_ rel: String) -> String {
        guard let slash = rel.lastIndex(of: "/") else { return rel }
        return String(rel[rel.index(after: slash)...])
    }

    /// Правила для отсева шума: корневой `.gitignore` плюс всегдашние мусорные
    /// папки. Вложенные `.gitignore` сюда не входят — их промах стоит лишнего
    /// пересканирования, а не неверного ответа, зато проверка остаётся дешёвой.
    /// Для Unity этого хватает: `/[Ll]ibrary/` и `/[Tt]emp/`, куда во время
    /// компиляции летят тысячи событий, перечислены в корневом файле.
    static func rootMatcher(root: URL) -> IgnoreMatcher {
        guard let text = try? String(contentsOfFile: root.path + "/.gitignore", encoding: .utf8) else {
            // .gitignore нет вовсе — тогда те же типовые папки, что и у обхода.
            return IgnoreMatcher(layers: [], useSoftSkip: true)
        }
        let rules = text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { IgnoreRule(line: String($0)) }
        return IgnoreMatcher(layers: [IgnoreLayer(rules: rules, base: "")], useSoftSkip: false)
    }
}
