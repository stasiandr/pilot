import AppKit

/// Подсказка Copilot: чем заменить `range`, чтобы получилось продолжение.
struct CopilotSuggestion: Equatable {
    /// Текст целиком, вместе с уже набранным началом строки.
    var insertText: String
    var range: LSPRange
    /// Сырой элемент ответа: его же отдаём серверу, когда подсказку
    /// показали и когда её приняли.
    var item: [String: Any]
    /// Команда, которой сервер считает принятие.
    var command: [String: Any]?

    static func == (a: Self, b: Self) -> Bool { a.insertText == b.insertText && a.range == b.range }
}

/// GitHub Copilot: подсказки в коде серым текстом.
///
/// Один сервер на всё приложение, а не на окно: он весит сотни мегабайт
/// памяти и умеет несколько проектов сразу. Воркспейсы шлют сюда открытие,
/// правки и закрытие документов и спрашивают подсказку у курсора.
@MainActor
final class CopilotService: ObservableObject {
    static let shared = CopilotService()

    enum Status: Equatable {
        case off
        case installing(Double)
        case starting
        case signedOut
        /// Код для github.com/login/device.
        case signingIn(code: String, url: URL)
        case ready(user: String?)
        case failed(String)
    }

    @Published private(set) var status: Status = .off {
        didSet {
            if case .installing = status, case .installing = oldValue { return }
            if status != oldValue { NSLog("[copilot] %@", String(describing: status)) }
        }
    }

    private static let enabledKey = "pilot.copilot.enabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            newValue ? start() : stop()
        }
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    private var client: LSPClient?
    private var folders: Set<URL> = []
    private var signInCommand: [String: Any]?

    private init() {}

    /// При запуске Pilot — если Copilot включён.
    func startIfEnabled() {
        if isEnabled { start() }
    }

    // MARK: - Сервер

    private func start() {
        guard client == nil else { return }
        switch status {
        case .installing, .starting: return
        default: break
        }
        guard CopilotInstaller.isInstalled else {
            install()
            return
        }
        launch()
    }

    private func install() {
        status = .installing(0)
        Task {
            do {
                try await CopilotInstaller.install { [weak self] fraction in
                    guard let self, case .installing = self.status else { return }
                    self.status = .installing(fraction)
                }
                guard isEnabled else { status = .off; return }
                launch()
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func launch() {
        status = .starting
        let config = ServerConfig(
            id: "copilot", languageId: "", fileExtensions: [],
            command: [CopilotInstaller.executable.path, "--stdio"],
            initializationOptions: [
                "editorInfo": ["name": "Pilot", "version": Self.appVersion],
                "editorPluginInfo": ["name": "pilot-copilot", "version": Self.appVersion],
            ],
            displayName: "Copilot")
        // Корень — первый открытый проект; остальные — папками рабочей области.
        let root = folders.first ?? FileManager.default.homeDirectoryForCurrentUser
        let client = LSPClient(config: config, root: root)
        self.client = client
        client.onNotification = { [weak self, weak client] method, params in
            let status = Self.statusChange(method, params)
            Task { @MainActor in
                guard let self, self.client === client, let status else { return }
                self.apply(status)
            }
        }
        client.onExit = { [weak self, weak client] reason in
            Task { @MainActor in
                guard let self, self.client === client else { return }
                self.client = nil
                self.status = .failed(reason)
            }
        }
        Task {
            do {
                try client.start()
                try await client.initialize()
                guard self.client === client else { return }
                if folders.count > 1 { addFolders(Array(folders.dropFirst())) }
                documents.values.forEach { open($0) }
                await checkStatus()
            } catch {
                guard self.client === client else { return }
                self.client = nil
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func stop() {
        client?.stop()
        client = nil
        signInCommand = nil
        status = .off
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Вход

    private func checkStatus() async {
        guard let client else { return }
        let result = try? await client.request("checkStatus", [:], timeout: 30)
        apply(Self.authStatus(result) ?? .signedOut)
    }

    /// Вход через GitHub: сервер выдаёт код, человек вводит его на
    /// github.com/login/device, а сервер ждёт, пока вход подтвердят.
    func signIn() {
        guard let client else { return }
        Task {
            do {
                let result = try await client.request("signIn", [:], timeout: 30) as? [String: Any] ?? [:]
                if let done = Self.authStatus(result), case .ready = done {
                    apply(done)
                    return
                }
                guard let code = result["userCode"] as? String,
                      let uri = (result["verificationUri"] as? String).flatMap(URL.init(string:)) else {
                    status = .failed(L("Copilot не выдал код для входа"))
                    return
                }
                status = .signingIn(code: code, url: uri)
                signInCommand = result["command"] as? [String: Any]
                openVerificationPage()
                // Ответ придёт, когда вход подтвердят в браузере.
                if let command = signInCommand {
                    let done = try await client.request("workspace/executeCommand", [
                        "command": command["command"] as? String ?? "github.copilot.finishDeviceFlow",
                        "arguments": command["arguments"] ?? [],
                    ], timeout: 15 * 60)
                    signInCommand = nil
                    // Ответ без статуса — спросить заново; ждать больше нечего.
                    if let result = Self.authStatus(done) {
                        status = result
                    } else {
                        status = .signedOut
                        await checkStatus()
                    }
                }
            } catch {
                guard self.client === client else { return }
                signInCommand = nil
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Код — в буфер обмена, страница входа — в браузере.
    func openVerificationPage() {
        guard case .signingIn(let code, let url) = status else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        NSWorkspace.shared.open(url)
    }

    func signOut() {
        guard let client else { return }
        Task {
            _ = try? await client.request("signOut", [:], timeout: 30)
            status = .signedOut
        }
    }

    private func apply(_ new: Status) {
        // Пока ждём подтверждения входа, промежуточное «не вошли» не
        // должно прятать код.
        if case .signingIn = status, case .signedOut = new { return }
        status = new
    }

    nonisolated private static func authStatus(_ result: Any?) -> Status? {
        guard let dict = result as? [String: Any], let value = dict["status"] as? String else { return nil }
        switch value {
        case "OK", "AlreadySignedIn", "MaybeOk":
            return .ready(user: dict["user"] as? String)
        case "NotSignedIn":
            return .signedOut
        case "NotAuthorized":
            return .failed(L("У аккаунта GitHub нет подписки Copilot"))
        default:
            return nil
        }
    }

    /// Состояние входа, пришедшее само: сервер шлёт его после проверки
    /// токена и когда тот протухает.
    nonisolated private static func statusChange(_ method: String, _ params: Any?) -> Status? {
        guard method == "didChangeStatus/v2",
              let statuses = (params as? [String: Any])?["statuses"] as? [[String: Any]] else { return nil }
        for entry in statuses where entry["category"] as? String == "auth" {
            if let result = authStatus(entry["result"]) { return result }
        }
        return nil
    }

    // MARK: - Документы

    private struct Document {
        let url: URL
        let languageId: String
        let text: () -> String
    }
    /// Открытые во всех окнах — чтобы отдать их серверу, поднятому позже.
    private var documents: [URL: Document] = [:]

    func projectOpened(_ root: URL) {
        guard folders.insert(root).inserted, client != nil else { return }
        addFolders([root])
    }

    private func addFolders(_ roots: [URL]) {
        client?.notify("workspace/didChangeWorkspaceFolders", [
            "event": [
                "added": roots.map { ["uri": $0.absoluteString, "name": $0.lastPathComponent] },
                "removed": [],
            ],
        ])
    }

    func documentOpened(_ document: LoadedDocument) {
        guard isEnabled, document.revision == nil else { return }
        let model = document.model
        let entry = Document(url: document.url, languageId: Self.languageId(for: document.url),
                             text: { model.text })
        documents[document.url] = entry
        open(entry)
        client?.notify("textDocument/didFocus", ["textDocument": ["uri": document.url.absoluteString]])
    }

    private func open(_ document: Document) {
        guard let client else { return }
        client.didOpen(url: document.url, languageId: document.languageId, text: document.text())
    }

    func documentEdited(_ url: URL, range: LSPRange, text: String) {
        guard let client, client.isOpen(url) else { return }
        client.didChange(url: url, changes: [[
            "range": ["start": ["line": range.start.line, "character": range.start.character],
                      "end": ["line": range.end.line, "character": range.end.character]],
            "text": text,
        ]])
    }

    func documentClosed(_ url: URL) {
        documents[url] = nil
        client?.didClose(url: url)
    }

    // MARK: - Подсказки

    /// Подсказка у курсора. nil — нечего подсказать, не вошли или сервер
    /// не успел: набор её не ждёт.
    func suggestion(url: URL, position: LSPPosition, tabSize: Int, insertSpaces: Bool) async -> CopilotSuggestion? {
        guard isReady, let client, let version = client.version(of: url) else { return nil }
        let result = try? await client.request("textDocument/inlineCompletion", [
            "textDocument": ["uri": url.absoluteString, "version": version],
            "position": ["line": position.line, "character": position.character],
            "context": ["triggerKind": 2],
            "formattingOptions": ["tabSize": tabSize, "insertSpaces": insertSpaces],
        ], timeout: 6)
        // Пока спрашивали, текст поменялся — ответ про старый.
        guard client.version(of: url) == version,
              let items = (result as? [String: Any])?["items"] as? [[String: Any]],
              let item = items.first,
              let text = item["insertText"] as? String ?? (item["insertText"] as? [String: Any])?["value"] as? String,
              let rangeDict = item["range"],
              let range = try? JSON.decode(LSPRange.self, from: rangeDict) else { return nil }
        return CopilotSuggestion(insertText: text, range: range, item: item,
                                 command: item["command"] as? [String: Any])
    }

    func suggestionShown(_ suggestion: CopilotSuggestion) {
        client?.notify("textDocument/didShowCompletion", ["item": suggestion.item])
    }

    func suggestionAccepted(_ suggestion: CopilotSuggestion) {
        guard let client, let command = suggestion.command, let name = command["command"] as? String else { return }
        Task { _ = try? await client.request("workspace/executeCommand", [
            "command": name, "arguments": command["arguments"] ?? [],
        ]) }
    }

    /// Идентификатор языка по LSP — по расширению; Copilot по нему решает,
    /// как продолжать код.
    static func languageId(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "cs": return "csharp"
        case "swift": return "swift"
        case "py": return "python"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "javascriptreact"
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "typescriptreact"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "go": return "go"
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "m": return "objective-c"
        case "mm": return "objective-cpp"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "rb": return "ruby"
        case "php": return "php"
        case "sh", "bash", "zsh": return "shellscript"
        case "yml", "yaml": return "yaml"
        case "xml", "csproj", "props", "targets": return "xml"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss": return "scss"
        case "sql": return "sql"
        case "lua": return "lua"
        case "shader", "hlsl", "cginc", "compute": return "hlsl"
        case "toml": return "toml"
        default: return "plaintext"
        }
    }
}
