import SwiftUI
import AppKit

/// Окна Pilot: в каждом свой проект со своим воркспейсом — индексом,
/// компиляцией, git и вкладками. Клиент и сервер одного продукта открыты рядом,
/// и ни один не выгружает другого.
///
/// Здесь решается, куда идёт просьба открыть проект или файл: в окно, где
/// этот проект уже открыт; в пустое окно со стартовым экраном; или в новое.
/// Одного проекта в двух окнах не бывает — вторая просьба выводит вперёд
/// первое окно.
@MainActor
final class ProjectWindows {
    static let shared = ProjectWindows()

    /// Идентификатор сцены окна проекта в PilotApp.
    static let sceneID = "project"

    private final class Entry {
        weak var workspace: Workspace?
        init(_ workspace: Workspace) { self.workspace = workspace }
    }
    private var entries: [Entry] = []

    /// Что открыть в окне, которое сейчас появится.
    private enum Pending {
        /// `behind` — окно, которое должно остаться впереди: вторая
        /// половина пары открывается рядом, а не вместо.
        case root(URL, behind: Workspace?)
        /// Вкладкой окна `host` — вторая половина пары по её кнопке.
        case tab(URL, host: Workspace)
        case request(OpenRequest)
    }
    private var pending: [Pending] = []
    /// Просьбы, пришедшие раньше первого окна: `open -a Pilot File.cs`
    /// запускает Pilot сразу с файлом, и событие обгоняет окно.
    private var early: [OpenRequest] = []
    private var launched = false
    /// Открыть окно умеет только SwiftUI; действие берётся у окна из окружения.
    var openWindow: OpenWindowAction?

    /// Открытые окна, в порядке появления.
    var workspaces: [Workspace] { entries.compactMap(\.workspace) }

    /// Воркспейс окна, которое сейчас впереди.
    var front: Workspace? {
        workspaces.first { $0.window?.isKeyWindow == true }
            ?? workspaces.first { $0.window?.isMainWindow == true }
    }

    // MARK: - Жизнь окон

    func appeared(_ workspace: Workspace) {
        entries.removeAll { $0.workspace == nil || $0.workspace === workspace }
        entries.append(Entry(workspace))
        if !pending.isEmpty {
            switch pending.removeFirst() {
            case .root(let url, let behind):
                workspace.open(root: url)
                if let behind { DispatchQueue.main.async { behind.bringToFront() } }
            case .tab(let url, let host):
                workspace.open(root: url)
                join(workspace, into: host)
            case .request(let request): workspace.open(request)
            }
        }
        // Первое окно: путь из командной строки, затем присланное снаружи.
        // Без того и другого остаётся стартовый экран.
        if !launched {
            launched = true
            let requests = (OpenRequest.launch.map { [$0] } ?? []) + early
            early = []
            requests.forEach { open($0) }
        }
    }

    func disappeared(_ workspace: Workspace) {
        entries.removeAll { $0.workspace == nil || $0.workspace === workspace }
    }

    // MARK: - Куда открыть

    /// Finder, Unity, `pilot` из терминала.
    func open(_ request: OpenRequest, from origin: Workspace? = nil) {
        guard launched else {
            early.append(request)
            return
        }
        let windows = workspaces
        if let owner = windows.first(where: { $0.accepts(request) }) {
            owner.open(request)
            owner.bringToFront()
            return
        }
        // Пути нет на диске (Unity присылает и такие) — просто показаться.
        guard let resolved = Workspace.resolve(request) else {
            (origin ?? front ?? windows.first)?.bringToFront()
            return
        }
        if let owner = windows.first(where: { $0.root?.path == resolved.project.path }) {
            owner.open(request)
            owner.bringToFront()
        } else if let empty = emptyWindow(preferring: origin) {
            empty.open(request)
            empty.bringToFront()
        } else {
            newWindow(.request(request))
        }
    }

    /// Проект из «Открыть папку…», недавних или стартового экрана.
    func open(root url: URL, from origin: Workspace?) {
        if let owner = workspaces.first(where: { $0.root?.path == url.path }) {
            owner.bringToFront()
        } else if let empty = emptyWindow(preferring: origin) {
            empty.open(root: url)
            empty.bringToFront()
        } else {
            newWindow(.root(url, behind: nil))
        }
    }

    // MARK: - Пара

    static let togetherKey = "pilot.pairOpensTogether"

    /// Проект пары открывает и вторую половину — рядом, в своём окне.
    /// Только если включили в меню «Пара»: по умолчанию вторая половина
    /// открывается, когда её просят (⌃⌘P).
    var pairOpensTogether: Bool {
        get { UserDefaults.standard.object(forKey: Self.togetherKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: Self.togetherKey) }
    }

    /// В окне открылся проект: его пара, если она ещё не открыта, — следом.
    func projectOpened(_ workspace: Workspace) {
        guard pairOpensTogether, let partner = workspace.partner,
              !workspaces.contains(where: { $0.root?.path == partner.path }) else { return }
        // Окно под неё уже просили, но оно ещё не появилось.
        let requested = pending.contains {
            if case .root(let url, _) = $0 { return url.path == partner.path }
            return false
        }
        guard !requested else { return }
        if let empty = workspaces.first(where: { $0 !== workspace && $0.root == nil }) {
            empty.open(root: partner)
            workspace.bringToFront()
        } else {
            newWindow(.root(partner, behind: workspace))
        }
    }

    /// Проект — вкладкой окна `host`: кнопка второй половины пары. Уже открыт
    /// в своём окне — переезжает вкладкой сюда.
    func openAsTab(root url: URL, in host: Workspace) {
        if let owner = workspaces.first(where: { $0.root?.path == url.path }) {
            join(owner, into: host)
        } else if let empty = workspaces.first(where: { $0 !== host && $0.root == nil }) {
            empty.open(root: url)
            join(empty, into: host)
        } else {
            newWindow(.tab(url, host: host))
        }
    }

    private func join(_ workspace: Workspace, into host: Workspace) {
        guard let window = workspace.window, let hostWindow = host.window, window !== hostWindow else {
            workspace.bringToFront()
            return
        }
        if !(hostWindow.tabbedWindows ?? []).contains(window) {
            // С выключенными вкладками проектов окна их запрещают; для пары —
            // разрешить на время объединения.
            let modes = (hostWindow.tabbingMode, window.tabbingMode)
            hostWindow.tabbingMode = .preferred
            window.tabbingMode = .preferred
            hostWindow.addTabbedWindow(window, ordered: .above)
            hostWindow.tabbingMode = modes.0
            window.tabbingMode = modes.1
        }
        workspace.bringToFront()
    }

    /// Новое окно со стартовым экраном — ⇧⌘N.
    func openEmptyWindow() {
        newWindow(nil)
    }

    /// «Открыть папку…», когда впереди нет окна проекта (настройки).
    func promptForFolder() {
        if let front { front.promptForFolder(); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = ArchiveLayout.openPanelTypes
        panel.allowsOtherFileTypes = false
        panel.prompt = "Открыть"
        if panel.runModal() == .OK, let url = panel.url {
            open(root: url, from: nil)
        }
    }

    /// Окно со стартовым экраном: то, откуда просили, переднее или любое.
    private func emptyWindow(preferring origin: Workspace?) -> Workspace? {
        [origin, front].compactMap { $0 }.first { $0.root == nil }
            ?? workspaces.first { $0.root == nil }
    }

    private func newWindow(_ what: Pending?) {
        guard let openWindow else {
            // Окон ещё нет — первое само заберёт просьбу.
            if case .request(let request) = what { early.append(request) }
            return
        }
        if let what { pending.append(what) }
        openWindow(id: Self.sceneID)
    }

    // MARK: - Выход

    /// Перед выходом — про несохранённое во всех окнах.
    func confirmUnsavedChanges() -> Bool {
        workspaces.allSatisfy { $0.confirmUnsavedChanges() }
    }
}

/// Красная кнопка окна: сначала спросить про несохранённые правки проекта.
///
/// Раньше окно было одно, и его закрытие было выходом — про правки спрашивал
/// `applicationShouldTerminate`. Теперь закрытое окно — это закрытый проект,
/// а приложение с другим окном живёт дальше. Делегат окна принадлежит SwiftUI,
/// поэтому перехватывается сама кнопка, а не `windowShouldClose`.
@MainActor
final class WindowCloseGuard: NSObject {
    private weak var window: NSWindow?
    private let confirm: () -> Bool

    init(window: NSWindow, confirm: @escaping () -> Bool) {
        self.window = window
        self.confirm = confirm
        super.init()
        let button = window.standardWindowButton(.closeButton)
        button?.target = self
        button?.action = #selector(close(_:))
    }

    @objc private func close(_ sender: Any?) {
        guard let window, confirm() else { return }
        window.close()
    }
}
