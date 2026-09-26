import SwiftUI

/// Консоль Unity в Pilot: `Editor.log` следом за редактором. Лог один на
/// все Unity, поэтому показывается, только если его пишет этот проект.
///
/// Файл опрашивается дважды в секунду — `stat` почти ничего не стоит, а
/// опрос переживает то, на чём спотыкаются события ФС: Unity при запуске
/// переименовывает старый лог в `Editor-prev.log` и начинает новый.
@MainActor
final class UnityConsole: ObservableObject {
    @Published private(set) var entries: [UnityLogEntry] = []
    /// Лог пишет другой проект — путь к нему; до «Показать всё равно» сообщения скрыты.
    @Published private(set) var foreignProject: String?
    @Published var showsForeign = false
    @Published private(set) var isMissing = false
    @Published var isVisible = false {
        didSet { if isVisible { unreadErrors = 0 } }
    }
    /// Ошибки, пришедшие, пока консоль скрыта, — для значка в строке состояния.
    @Published private(set) var unreadErrors = 0

    /// Больше не держим: старое уходит.
    static let limit = 5000
    /// При открытии — только хвост большого лога.
    static let initialTail = 8 * 1024 * 1024

    private var projectRoot: URL?
    private let url: URL
    private var timer: Timer?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    /// Незаконченный блок: Unity ещё не дописала пустую строку за ним.
    private var pending = ""
    private var pendingPolls = 0
    private var parser = UnityLog.Parser()
    private let queue = DispatchQueue(label: "pilot.unity.console", qos: .utility)
    private var reading = false

    init(url: URL = UnityLog.editorLog) {
        self.url = url
    }

    var isForeign: Bool { foreignProject != nil && !showsForeign }

    var errorCount: Int { isForeign ? 0 : entries.lazy.filter { $0.level == .error }.count }

    // MARK: - Проект

    func workspaceChanged(to unityRoot: URL?) {
        timer?.invalidate()
        timer = nil
        projectRoot = unityRoot
        reset()
        guard unityRoot != nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func clear() {
        entries = []
        unreadErrors = 0
    }

    private func reset() {
        entries = []
        inode = 0
        offset = 0
        pending = ""
        pendingPolls = 0
        parser = UnityLog.Parser()
        foreignProject = nil
        showsForeign = false
        unreadErrors = 0
    }

    // MARK: - Чтение

    private func poll() {
        guard projectRoot != nil, !reading else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let node = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            isMissing = true
            return
        }
        isMissing = false
        // Unity перезапустили: новый файл или тот же, но короче.
        if node != inode || size < offset {
            let fresh = inode == 0
            reset()
            inode = node
            offset = size > UInt64(Self.initialTail) ? size - UInt64(Self.initialTail) : 0
            readHeader()
            if !fresh { NSLog("[unity] Editor.log начат заново") }
        }
        guard size > offset else {
            flushPendingIfStale()
            return
        }
        let from = offset
        let skipToBlock = from > 0 && entries.isEmpty && pending.isEmpty
        reading = true
        let url = self.url
        queue.async { [weak self] in
            var data = Data()
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.seek(toOffset: from)
                data = (try? handle.read(upToCount: Int(size - from))) ?? Data()
                try? handle.close()
            }
            var text = String(decoding: data, as: UTF8.self)
            // С середины файла — с начала следующего блока.
            if skipToBlock, let start = text.range(of: "\n\n") { text = String(text[start.upperBound...]) }
            Task { @MainActor in
                guard let self else { return }
                self.reading = false
                guard self.inode == node else { return }
                self.offset = from + UInt64(data.count)
                self.append(text)
            }
        }
    }

    private func readHeader() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 64 * 1024)) ?? Data(), as: UTF8.self)
        guard let root = projectRoot, let path = UnityLog.projectPath(inHeader: head) else { return }
        let theirs = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let ours = root.resolvingSymlinksInPath().standardizedFileURL.path
        foreignProject = theirs.caseInsensitiveCompare(ours) == .orderedSame ? nil : path
    }

    private func append(_ text: String) {
        pending += text
        guard let cut = pending.range(of: "\n\n", options: .backwards) else {
            pendingPolls = 0
            return
        }
        let complete = String(pending[..<cut.upperBound])
        pending = String(pending[cut.upperBound...])
        pendingPolls = 0
        add(parser.parse(complete))
    }

    /// Хвост без пустой строки за ним ждёт секунду и уходит как есть:
    /// последнее сообщение не должно висеть, пока Unity не напишет следующее.
    private func flushPendingIfStale() {
        guard !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingPolls += 1
        guard pendingPolls >= 2 else { return }
        let text = pending
        pending = ""
        pendingPolls = 0
        add(parser.parse(text))
    }

    private func add(_ new: [UnityLogEntry]) {
        guard !new.isEmpty else { return }
        entries.append(contentsOf: new)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        if !isVisible, !isForeign { unreadErrors += new.lazy.filter { $0.level == .error }.count }
    }

    // MARK: - Переход

    /// Путь из лога — файл на диске: от корня проекта Unity или абсолютный.
    func fileURL(for path: String) -> URL? {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if let root = projectRoot {
            url = root.appendingPathComponent(path.hasPrefix("./") ? String(path.dropFirst(2)) : path)
        } else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
    }
}
