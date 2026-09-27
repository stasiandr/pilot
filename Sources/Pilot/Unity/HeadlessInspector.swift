import SwiftUI
import AppKit

/// Инспектор Unity без окна — тот же разбор и та же форма, что у ⌥⌘0, в PNG:
///
///     Pilot --render-inspector Файл.prefab[:строка] [--object fileID | --name GameObject]
///           [--width 330] [--height 1400] [--scale 1] [--out inspector.png]
///           [--scheme catppuccin-latte] [--lang en] [--expand] [--debug-fields] [--read-only]
///           [--click x,y]… [--dump] [--list]
///           [--window 1496x938 [--compact] [--tabs] [--pair clm-server] [--console]]
///
/// Файл читается так же, как при открытии (`LoadedDocument.load`), объект
/// выбирается так же, как курсором: строкой, fileID или именем GameObject'а;
/// без них — как курсор в начале файла. Проект Unity — ближайшая папка над
/// файлом с `Assets` и `ProjectSettings`, индекс GUID — из кэша прошлого
/// запуска Pilot: проект должен хоть раз открываться, иначе вместо имён
/// ассетов будут GUID.
///
/// Окно не показывается, приложение не активируется: форма рисуется в
/// невидимом окне, которое никогда не выходит на экран (`OffscreenWindow`).
/// `--click x,y` — щелчок мышью по точке от левого верхнего угла до снимка;
/// что сделала кнопка, печатается в stdout (`reveal &…`, `open …`, `commit …`),
/// правки в файл не пишутся. `--dump` — поля, флажки и кнопки с рамками (по
/// ним удобно целиться), `--list` — объекты файла. `--expand` раскрывает все
/// списки и структуры, `--debug-fields` — служебные поля, как жучок в шапке,
/// `--read-only` — как версия из мерж-реквеста. `--window` — колонка в окне
/// проекта с тулбаром (`InspectorWindowPreview`): `--compact` — компактный
/// тулбар, `--tabs` — полоса вкладок окна (пара проектов вкладками),
/// `--pair` — кнопка второй половины пары, `--console` — консоль Unity под
/// редактором. Настройки, которые при этом трогают AppKit и жучок отладки,
/// возвращаются как были. Код выхода 2 — не разобрать аргументы или файл.
@MainActor
enum HeadlessInspector {

    static var isRequested: Bool { CommandLine.arguments.contains("--render-inspector") }

    static func run() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        if let language = value("--lang").flatMap(AppLanguage.init(rawValue:)) { Localization.current = language }
        // До первого обращения к ThemeStore: схема читается при его создании.
        if let scheme = value("--scheme") { UserDefaults.standard.register(defaults: ["pilot.colorScheme": scheme]) }
        // Настройки окна-заглушки AppKit пишет сам — их потом убираем, а
        // жучок отладки (он @AppStorage) читается из своего, пустого набора:
        // настройки самого Pilot не трогаются, даже если он сейчас открыт.
        let settings = SettingsGuard()
        defer { settings.restore() }

        guard let target = value("--render-inspector") else {
            log("нужно: --render-inspector Файл.prefab[:строка]")
            return 2
        }
        var path = target, line: Int?
        if let colon = target.lastIndex(of: ":"), let number = Int(target[target.index(after: colon)...]) {
            path = String(target[..<colon])
            line = number
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let unity = UnityService()
        unity.workspaceChanged(to: unityRoot(of: url))
        unity.adoptCachedAssets()
        if unity.project == nil { log("над \(url.path) нет Unity-проекта — ассеты будут без имён") }
        if unity.project != nil, unity.assets == nil { log("индекса GUID нет в кэше — ассеты будут без имён") }

        let document: LoadedDocument
        do {
            document = try LoadedDocument.load(url: url, unity: unity.context)
        } catch {
            log("не открыть \(url.path): \(error.localizedDescription)")
            return 2
        }
        guard let file = document.unityFile else {
            log("\(url.lastPathComponent) — не сериализованный файл Unity")
            return 2
        }
        let resolve: UnityYAMLFile.Resolver = { unity.assets?.displayName(for: $0) }
        if arguments.contains("--list") {
            for object in file.objects {
                print("\(object.fileID)\t\(object.typeName)\t\(file.displayName(of: object, resolve: resolve))")
            }
            return 0
        }

        // Курсор — туда, куда его поставил бы щелчок по объекту в иерархии.
        var caret = 0
        if let id = value("--object").flatMap(Int64.init) {
            guard let index = file.index(ofFileID: id) else { log("объекта &\(id) в файле нет"); return 2 }
            caret = file.objects[index].start
        } else if let name = value("--name") {
            guard let object = file.objects.first(where: { $0.isGameObject && $0.name == name })
                    ?? file.objects.first(where: { $0.isGameObject && ($0.name ?? "").contains(name) }) else {
                log("GameObject'а «\(name)» в файле нет")
                return 2
            }
            caret = object.start
        } else if let line {
            caret = document.model.offset(at: LSPPosition(line: max(0, line - 1), character: 0))
        }
        guard let content = UnityInspector.content(file: file, model: document.model, caret: caret,
                                                   resolve: resolve) else {
            log("в файле нет объектов")
            return 2
        }

        // AppKit без Dock, меню и активации: только чтобы рисовать.
        NSApplication.shared.setActivationPolicy(.prohibited)
        ThemeStore.shared.applyAppearance()
        let actions = UnityInspectorActions(
            commit: { edits, name in
                print("commit \(name): " + edits.map { "\($0.range.location)+\($0.range.length) → \($0.text)" }
                    .joined(separator: ", "))
            },
            reveal: { print("reveal &\($0)") },
            openAsset: { guid, fileID in
                print("open \(unity.assets?.path(for: guid) ?? guid.description)" + (fileID.map { " &\($0)" } ?? ""))
            })
        let form = UnityInspectorForm(
            content: content, file: file, parsing: false,
            readOnly: document.revision != nil || arguments.contains("--read-only"), unity: unity, actions: actions,
            expanded: arguments.contains("--expand")
                ? UnityInspectorForm.expansionKeys(of: content, debug: arguments.contains("--debug-fields")) : [])
            .defaultAppStorage(settings.store(debugFields: arguments.contains("--debug-fields")))
        let out = URL(fileURLWithPath: value("--out") ?? "inspector.png")

        let png: Data?
        if let spec = value("--window") {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            png = renderWindow(form, size: CGSize(width: parts.first ?? 1100, height: parts.count > 1 ? parts[1] : 720),
                               compact: arguments.contains("--compact"), tabs: arguments.contains("--tabs"),
                               pair: value("--pair"), console: arguments.contains("--console"))
        } else {
            let size = CGSize(width: value("--width").flatMap(Double.init) ?? 330,
                              height: value("--height").flatMap(Double.init) ?? 1400)
            let host = NSHostingView(rootView: form
                .frame(width: size.width, height: size.height)
                // Колонка инспектора — на фоне окна, как в приложении.
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, Theme.current.isDark ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: size)
            let window = OffscreenWindow(size: size)
            window.contentView = host
            settle(host)
            for click in arguments.indices.filter({ arguments[$0] == "--click" && $0 + 1 < arguments.count }) {
                let parts = arguments[click + 1].split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { log("щелчок — это x,y: «\(arguments[click + 1])»"); return 2 }
                print("click \(Int(parts[0])),\(Int(parts[1]))")
                window.click(at: CGPoint(x: parts[0], y: parts[1]))
                settle(host)
            }
            if arguments.contains("--dump") {
                controls(in: host).forEach { print($0) }
            }
            png = snapshot(host, scale: value("--scale").flatMap(Double.init))
        }
        guard let png else {
            log("не снять картинку")
            return 2
        }
        do {
            try png.write(to: out)
        } catch {
            log("не записать \(out.path): \(error.localizedDescription)")
            return 2
        }
        log("\(out.path): \(content.title), компонентов: \(content.sections.count)")
        return 0
    }

    // MARK: - Проект

    /// Ближайшая папка над файлом, которая сама Unity-проект.
    private static func unityRoot(of file: URL) -> URL? {
        var directory = file.deletingLastPathComponent()
        while directory.path != "/" {
            if UnityProjectInfo.detect(root: directory) != nil { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Отрисовка

    /// Дать SwiftUI разложить вид и доделать отложенные обновления: ширину
    /// колонки и высоту рамки окна форма узнаёт только после первого прохода.
    static func settle(_ view: NSView) {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    static func snapshot(_ view: NSView, scale: Double?) -> Data? {
        let bounds = view.bounds
        let factor = scale ?? view.window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * factor),
                                         pixelsHigh: Int(bounds.height * factor),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Элементы формы

    /// Что в форме можно нажать или править, с рамками от левого верхнего
    /// угла: поля, флажки и кнопки-ссылки — виды AppKit, у кнопок SwiftUI —
    /// рамка фокуса. Дерево доступности без клиента VoiceOver SwiftUI не
    /// строит, поэтому так, а не через него.
    static func controls(in host: NSView) -> [String] {
        var result: [String] = []
        func walk(_ view: NSView) {
            let frame = host.convert(view.bounds, from: view)
            let rect = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
            switch view {
            case let field as NSTextField where field.isEditable:
                result.append("поле \(rect) «\(field.stringValue)»" + (field.isEnabled ? "" : " (выключено)"))
                return
            case let popUp as NSPopUpButton:
                result.append("меню \(rect) «\(popUp.titleOfSelectedItem ?? "")»")
                return
            case let button as NSButton:
                result.append("\(type(of: button)) \(rect) state=\(button.state.rawValue)"
                              + (button.isEnabled ? "" : " (выключено)"))
                return
            default:
                if String(describing: type(of: view)) == "_FocusRingView" { result.append("кнопка \(rect)") }
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        return result
    }

    /// В stderr: stdout — для того, что сделали кнопки.
    static func log(_ text: String) {
        FileHandle.standardError.write(Data(("pilot: " + text + "\n").utf8))
    }
}

/// Что без окна могло бы остаться в настройках: у окна-заглушки AppKit
/// запоминает полосу вкладок и тулбар, форма — жучок отладки. Жучок живёт в
/// своём наборе, который в конце стирается; ключи заглушки — убираются.
@MainActor
private struct SettingsGuard {
    private static let suite = "pilot.headless-inspector"
    private let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    private let keys: Set<String>

    init() {
        keys = Set((UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).keys)
    }

    func store(debugFields: Bool) -> UserDefaults {
        let store = UserDefaults(suiteName: Self.suite) ?? .standard
        store.removePersistentDomain(forName: Self.suite)
        store.register(defaults: ["pilot.inspectorDebug": debugFields])
        return store
    }

    func restore() {
        UserDefaults.standard.removePersistentDomain(forName: Self.suite)
        let now = (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).keys
        for key in now where !keys.contains(key)
            && (key.contains("OffscreenWindow") || key.contains("pilot.inspector-preview")) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// Окно, которое никогда не выходит на экран: в нём SwiftUI раскладывает и
/// рисует форму, а щелчки доставляются прямо в него. Всё, что вывело бы его
/// вперёд или сделало ключевым, выключено.
final class OffscreenWindow: NSWindow {
    init(size: CGSize, titled: Bool = false) {
        super.init(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                   styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                                     : [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKeyAndOrderFront(_ sender: Any?) {}
    override func orderFront(_ sender: Any?) {}
    override func orderFrontRegardless() {}
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {}

    /// Нажать и отпустить левую кнопку в точке от левого верхнего угла.
    ///
    /// Невидимому окну NSWindow щелчков не разносит, поэтому вид под точкой
    /// ищется так же, как это делает он (`hitTest` рамки окна), и событие
    /// отдаётся виду прямо: дальше SwiftUI сам решает, чья это кнопка, —
    /// с теми же `contentShape`, фонами и жестами, что и в окне. Отпускание —
    /// заранее в очередь: контролы AppKit ждут его в своём цикле слежения;
    /// кто не дождался, получит его следом.
    func click(at point: CGPoint) {
        guard let content = contentView else { return }
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp),
              let target = content.superview?.hitTest(location) ?? content.hitTest(location) else { return }
        NSApp.postEvent(up, atStart: false)
        target.mouseDown(with: down)
        if NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {
            target.mouseUp(with: up)
        }
    }
}
