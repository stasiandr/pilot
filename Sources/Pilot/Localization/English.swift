import Foundation

/// Английский перевод: русская строка из кода → английская.
///
/// Таблица собрана из частей по областям интерфейса (`English/*.swift`) —
/// так её проще читать и дополнять. Части — списки пар, а не словари:
/// повтор ключа в словарном литерале роняет приложение при запуске, а здесь
/// выигрывает первый, и тесты ядра говорят о повторе с другим переводом.
enum English {
    static let parts: [[(String, String)]] = [
        app, settings, model, ui, services, nuget, unity, commit, update, extensions,
    ]

    static let table: [String: String] = Dictionary(parts.joined().map { $0 }, uniquingKeysWith: { first, _ in first })
}
