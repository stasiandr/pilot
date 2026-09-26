import SwiftUI

/// Файл, для которого открыто окно локальной истории.
struct LocalHistoryFile: Identifiable, Equatable {
    var url: URL
    var path: String
    var id: String { path }
}

/// Локальная история: когда писать версии и как открыть окно.
extension Workspace {
    /// Путь для истории: файл проекта, который правят как текст. Картинки,
    /// код из сборки, версии из MR и чужие файлы — мимо.
    func historyPath(for buffer: TextBuffer) -> String? {
        guard localHistory != nil, !buffer.isReadOnly, let root,
              buffer.url.path.hasPrefix(root.path + "/") else { return nil }
        return relativePath(for: buffer.url)
    }

    /// После сохранения. Первый раз — ещё и каким файл был до правок.
    func recordSaved(_ buffer: TextBuffer, before: String?) {
        guard let history = localHistory, let path = historyPath(for: buffer) else { return }
        let text = buffer.storage.string
        localHistoryQueue.async {
            if let before, !history.hasVersions(path) {
                history.record(before, path: path, reason: .original, date: Date().addingTimeInterval(-0.001))
            }
            history.record(text, path: path, reason: .saved)
        }
    }

    /// Открытый файл поменялся снаружи: и прежний текст, и новый.
    func recordExternal(_ buffer: TextBuffer, previous: String, text: String) {
        guard let history = localHistory, let path = historyPath(for: buffer) else { return }
        localHistoryQueue.async {
            if !history.hasVersions(path) {
                history.record(previous, path: path, reason: .original, date: Date().addingTimeInterval(-0.001))
            }
            history.record(text, path: path, reason: .external)
        }
    }

    /// Перед откатом правок из окна коммита: файл как есть — в историю,
    /// чтобы откат можно было откатить.
    func recordBeforeDiscard(_ url: URL) {
        guard let history = localHistory, let root, url.path.hasPrefix(root.path + "/"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let path = relativePath(for: url)
        localHistoryQueue.async {
            history.record(text, path: path, reason: .discarded)
        }
    }

    /// ⌃⌥H — история текущего файла.
    func showLocalHistory() {
        guard let buffer, let path = historyPath(for: buffer) else {
            showNotice(L("У этого файла локальной истории не бывает"))
            return
        }
        localHistoryFile = LocalHistoryFile(url: buffer.url, path: path)
    }
}
