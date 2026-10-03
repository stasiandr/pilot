import Foundation
import CoreServices

/// Слежение за деревом проекта через FSEvents.
///
/// Здесь только перевод событий системы в `FileEvent` — всё, что с ними
/// делать, решает `FileChanges`, и это видно в тестах. Система сама копит
/// события за `latency` и склеивает повторы по одному пути, так что пачка
/// приходит уже свёрнутой: во время компиляции Unity их иначе были бы тысячи
/// в секунду.
@MainActor
final class FileWatcher {

    /// Пачка событий. Приходит на главном потоке.
    var onChange: (([FileEvent]) -> Void)?

    private var stream: FSEventStreamRef?
    private var box: Box?
    private let queue = DispatchQueue(label: "pilot.watch", qos: .utility)

    /// То, что получает колбэк FSEvents. Слабая ссылка: стрим останавливается
    /// на `queue` уже после `deinit`, и последняя пачка может прийти, когда
    /// наблюдателя нет. Держит коробку сам наблюдатель, а отпускает очередь —
    /// после того как стрим освобождён и колбэков больше не будет.
    private final class Box: @unchecked Sendable {
        weak var watcher: FileWatcher?
        init(_ watcher: FileWatcher) { self.watcher = watcher }
    }

    /// Сколько система копит события перед тем, как отдать их пачкой.
    /// Полсекунды: правку в другом редакторе замечаем сразу, а шквал от
    /// сборки сворачивается в несколько пачек вместо тысяч.
    private static let latency = 0.5

    deinit { Self.tearDown(stream, box, on: queue) }

    /// Следить за этим корнем; `nil` — перестать следить.
    func watch(root: URL?) {
        Self.tearDown(stream, box, on: queue)
        stream = nil
        box = nil
        guard let root else { return }

        let box = Box(self)
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        // kFSEventStreamCreateFlagFileEvents — события по файлам, а не по папкам:
        // иначе на правку одного файла пришлось бы перечитывать всю папку.
        // NoDefer — первая пачка приходит сразу, а накопление начинается после.
        // UseCFTypes — пути приходят массивом CFString. Без него это C-массив
        // `char *`, и чтение его как NSArray роняло Pilot на первой же пачке
        // событий снаружи: checkout, правка в другом редакторе.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(nil, Self.callback, &context,
                                                [root.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                Self.latency, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        // Start и Stop — синхронный запрос к fseventsd. Когда тот занят (чужая
        // сборка шуршит тысячами файлов), ответа можно ждать минутами, и на
        // главном потоке Pilot висел сразу после открытия проекта. На своей
        // очереди задержка стоит только слежения, а порядок start → stop
        // сохраняется, потому что очередь последовательная.
        nonisolated(unsafe) let started = created
        queue.async { FSEventStreamStart(started) }
        stream = created
        self.box = box
    }

    nonisolated private static func tearDown(_ stream: FSEventStreamRef?, _ box: Box?,
                                             on queue: DispatchQueue) {
        guard let stream else { return }
        nonisolated(unsafe) let stopped = stream
        queue.async {
            FSEventStreamStop(stopped)
            FSEventStreamInvalidate(stopped)
            FSEventStreamRelease(stopped)
            withExtendedLifetime(box) {}
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info, count > 0 else { return }
        let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
        guard let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }

        // Событий не хватило буфера или корень переехал — система просит
        // пересмотреть всё поддерево. Отдаём это как структурное изменение:
        // список файлов пересоберётся целиком.
        let rescanAll = UInt32(kFSEventStreamEventFlagMustScanSubDirs
                               | kFSEventStreamEventFlagRootChanged
                               | kFSEventStreamEventFlagMount
                               | kFSEventStreamEventFlagUnmount)
        let structural = UInt32(kFSEventStreamEventFlagItemCreated
                                | kFSEventStreamEventFlagItemRemoved
                                | kFSEventStreamEventFlagItemRenamed)

        var events: [FileEvent] = []
        events.reserveCapacity(min(count, list.count))
        for i in 0..<min(count, list.count) {
            let flag = flags[i]
            events.append(FileEvent(path: list[i],
                                    structural: flag & (structural | rescanAll) != 0,
                                    subtree: flag & rescanAll != 0))
        }
        guard !events.isEmpty else { return }
        Task { @MainActor in box.watcher?.onChange?(events) }
    }
}
