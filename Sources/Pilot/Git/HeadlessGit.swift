import SwiftUI
import AppKit

/// Окно git без окна — вкладка в PNG, как `--render-inspector`:
///
///     Pilot --render-git Репозиторий [--tab commit|history|branches|stash|journal|changes|popover|merge]
///           [--path файл] [--select хэш] [--width 1100] [--height 700] [--out git.png]
///           [--mode mine|mainline|graph] [--expand first|хэш]
///           [--lang en] [--wait 4] [--click x,y]… [--dump]
///
/// `--path` — для merge: файл в конфликте; для commit — какой файл
/// выбрать; для history — история этого файла. `--select` — коммит в
/// истории. Приложение не активируется, окно не показывается, git только
/// читается: щелчки (`--click`) по кнопкам, которые меняют репозиторий, —
/// на совести того, кто щёлкает.
enum HeadlessGit {
    static var isRequested: Bool { CommandLine.arguments.contains("--render-git") }

    @MainActor
    static func run() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        if let language = value("--lang").flatMap(AppLanguage.init(rawValue:)) { Localization.current = language }
        guard let target = value("--render-git") else {
            HeadlessInspector.log("нужно: --render-git Репозиторий")
            return 2
        }
        let url = URL(fileURLWithPath: target).standardizedFileURL
        guard let repository = Git.repositoryRoot(for: url) else {
            HeadlessInspector.log("не git-репозиторий: \(target)")
            return 2
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        ThemeStore.shared.applyAppearance()

        let workspace = Workspace()
        workspace.commits.workspaceChanged(to: repository)
        workspace.gitClient.workspaceChanged(to: repository)
        workspace.gitHistory.open(repository: repository)
        workspace.commits.refresh()
        workspace.gitClient.refresh()
        let path = value("--path")
        let tab = value("--tab") ?? "commit"

        let size = CGSize(width: value("--width").flatMap(Double.init) ?? 1100,
                          height: value("--height").flatMap(Double.init) ?? 700)
        let content: AnyView
        switch tab {
        case "merge":
            guard let path else {
                HeadlessInspector.log("для merge нужен --path")
                return 2
            }
            let session = MergeSession(repository: repository, path: path,
                                       yamlMerge: MergeSession.locateYAMLMerge(editorContents: nil))
            session.load()
            content = AnyView(MergeView(workspace: workspace, session: session))
        case "changes":
            content = AnyView(ChangesNavigator(workspace: workspace, commits: workspace.commits))
        case "popover":
            content = AnyView(BranchPopover(workspace: workspace, client: workspace.gitClient))
        default:
            guard let windowTab = GitWindowTab(rawValue: tab) else {
                HeadlessInspector.log("нет вкладки \(tab)")
                return 2
            }
            workspace.gitClient.windowTab = windowTab
            if windowTab == .history, let mode = value("--mode").flatMap(GitHistoryModel.Mode.init(rawValue:)) {
                workspace.gitHistory.mode = mode
            }
            if windowTab == .history, let path { workspace.gitHistory.filter.path = path }
            if windowTab == .history, let expand = value("--expand") {
                // Раскрыть MR с этим началом хэша, когда список придёт.
                let until = Date(timeIntervalSinceNow: 8)
                while workspace.gitHistory.mainline.isEmpty && Date() < until {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                }
                let target = expand == "first" ? workspace.gitHistory.mainline.first(where: { $0.commit.isMerge })?.id
                    : workspace.gitHistory.mainline.first(where: { $0.id.hasPrefix(expand) })?.id
                if let target { workspace.gitHistory.expanded.insert(target) }
            }
            content = AnyView(GitWindowView(workspace: workspace, client: workspace.gitClient))
        }

        let host = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: Theme.swiftUIEditorBackground))
            .environment(\.colorScheme, Theme.current.isDark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = OffscreenWindow(size: size)
        window.contentView = host

        // git отвечает в фоне — ждём, пока придёт то, что надо показать.
        let deadline = Date(timeIntervalSinceNow: value("--wait").flatMap(Double.init) ?? 4)
        func loaded() -> Bool {
            switch tab {
            case "history": return workspace.gitHistory.details != nil
            case "branches", "popover": return !workspace.gitClient.branches.isEmpty
            default: return workspace.commits.isLoaded
            }
        }
        while !loaded() && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if tab == "commit", let path { workspace.commits.selection = GitCommitService.Selection(path: path, staged: false) }
        if tab == "history", let hash = value("--select"),
           let commit = workspace.gitHistory.commits.first(where: { $0.hash.hasPrefix(hash) }) {
            workspace.gitHistory.selection = commit.hash
        }
        // Дифф и файлы коммита — ещё один ответ git.
        let settleUntil = Date(timeIntervalSinceNow: 0.6)
        while Date() < settleUntil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        HeadlessInspector.settle(host)

        for click in arguments.indices.filter({ arguments[$0] == "--click" && $0 + 1 < arguments.count }) {
            let parts = arguments[click + 1].split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { HeadlessInspector.log("щелчок — это x,y"); return 2 }
            print("click \(Int(parts[0])),\(Int(parts[1]))")
            window.click(at: CGPoint(x: parts[0], y: parts[1]))
            let until = Date(timeIntervalSinceNow: 0.5)
            while Date() < until { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
            HeadlessInspector.settle(host)
        }
        if arguments.contains("--dump") {
            HeadlessInspector.controls(in: host).forEach { print($0) }
        }
        guard let png = HeadlessInspector.snapshot(host, scale: value("--scale").flatMap(Double.init)) else {
            HeadlessInspector.log("не снять картинку")
            return 2
        }
        let out = URL(fileURLWithPath: value("--out") ?? "git.png")
        do {
            try png.write(to: out)
        } catch {
            HeadlessInspector.log(error.localizedDescription)
            return 2
        }
        return 0
    }
}
