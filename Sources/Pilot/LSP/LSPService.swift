import SwiftUI
import Foundation

/// Оркестровка языковых серверов для одного воркспейса.
///
/// Главный принцип: сервер никогда не блокирует просмотр. Пока Roslyn грузит
/// solution, Pilot полностью работоспособен: поиск, просмотр, подсветка не
/// зависят от него ни одной строкой кода.
///
/// Сервер, которому нужен solution, поднимается сразу при открытии проекта:
/// пока ищешь нужный файл, он успевает загрузиться. Остальные — при первом
/// файле своего языка. Поднимается сервер через демона (LSPDaemon): тот
/// держит серверы между запусками Pilot, и повторное открытие проекта застаёт
/// Roslyn уже прогретым. Если с демоном не вышло — запускаем сервер сами.
@MainActor
final class LSPService: ObservableObject {

    @Published private(set) var state: LSPState = .stopped
    @Published private(set) var serverName: String?

    private var client: LSPClient?
    private var root: URL?
    private var startedForExtension: String?
    /// Сервер общий, из демона: индекс символов прогревает демон.
    private var viaDaemon = false
    /// Файл, открытый, пока сервер инициализируется: didOpen раньше ответа
    /// на initialize протокол не допускает. Отправим, когда можно.
    private var pendingDocument: LoadedDocument?

    // Загрузка проектов текущего клиента. initialize у Roslyn проходит за
    // полсекунды, а solution грузится ещё десятки: всё это время сервер
    // отвечает, но пустотой. Поэтому готовность — не конец initialize,
    // а уведомление «проекты загружены».
    private var initialized = false
    private var projectsFinished = false
    private var projectsLoaded = 0
    private var projectsTotal = 0

    var isReady: Bool { state == .ready }

    // MARK: - Жизненный цикл

    func workspaceChanged(to newRoot: URL?) {
        client?.stop()
        client = nil
        startedForExtension = nil
        pendingDocument = nil
        root = newRoot
        state = .stopped
        serverName = nil

        // Solution в корне — значит, сейчас будут читать его код.
        if let newRoot, let config = ServerRegistry.solutionServer(root: newRoot) {
            startedForExtension = "solution"
            launch(config: config, root: newRoot)
        }
    }

    /// Вызывается при открытии файла. Если для его языка есть сервер и он
    /// ещё не запущен — поднимаем. В остальное время это но-оп.
    func documentOpened(_ document: LoadedDocument) {
        guard let root else { return }
        let ext = document.url.pathExtension.lowercased()
        guard !ext.isEmpty else { return }

        if let client, client.config.fileExtensions.contains(ext) {
            if initialized {
                client.didOpen(url: document.url, languageId: client.config.languageId, text: document.text)
            } else {
                pendingDocument = document
            }
            return
        }
        guard startedForExtension == nil,
              let config = ServerRegistry.server(forExtension: ext, root: root) else { return }

        startedForExtension = ext
        pendingDocument = document
        launch(config: config, root: root)
    }

    private func launch(config: ServerConfig, root: URL) {
        let client = LSPClient(config: config, root: root)
        self.client = client
        serverName = config.displayName
        state = .starting("запускается")
        viaDaemon = false
        initialized = false
        projectsFinished = false
        projectsLoaded = 0
        projectsTotal = 0

        // Колбэки приходят с потока чтения пайпа или сокета. `self.client === client`
        // отсекает запоздавшие сообщения от сервера, который уже заменён.
        client.onStatus = { [weak self, weak client] text in
            Task { @MainActor in
                guard let self, self.client === client, case .starting = self.state else { return }
                self.state = .starting(text)
            }
        }
        client.onExit = { [weak self, weak client] reason in
            Task { @MainActor in
                guard let self, self.client === client else { return }
                self.state = .failed(reason)
            }
        }
        client.onProjectLoaded = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, self.client === client else { return }
                self.projectsLoaded += 1
                self.showProjectProgress()
            }
        }
        client.onProjectsLoaded = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.projectsFinished = true
                // Уведомление может обогнать продолжение после initialize.
                if self.initialized { self.becomeReady(client) }
            }
        }

        Task {
            do {
                let shared = await Self.connectViaDaemon(client)
                // Пока подключались, проект могли закрыть или сменить.
                guard self.client === client else { client.stop(); return }
                viaDaemon = shared
                if !shared { try client.start() }
                state = .starting("инициализация")
                try await client.initialize()
                guard self.client === client else { return }
                initialized = true
                if let document = pendingDocument {
                    pendingDocument = nil
                    client.didOpen(url: document.url, languageId: config.languageId, text: document.text)
                }
                if let total = client.projectsToLoad, !projectsFinished {
                    projectsTotal = total
                    showProjectProgress()
                } else {
                    becomeReady(client)
                }
            } catch {
                guard self.client === client else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Подключает клиента к серверу в демоне, запуская демона, если его нет.
    /// false — демон выключен или недоступен, сервер запускаем сами.
    nonisolated private static func connectViaDaemon(_ client: LSPClient) async -> Bool {
        guard Experimental.lspDaemon, let executable = Bundle.main.executablePath else { return false }
        let socket = LSPDaemon.socketPath(executable: executable)
        let build = LSPDaemon.buildID(executable: executable)
        for attempt in 0..<2 {
            let fd = await Task.detached {
                LSPDaemon.connectOrLaunch(executable: executable, socketPath: socket)
            }.value
            guard let fd else { return false }
            client.connect(daemonSocket: fd)
            do {
                _ = try await client.attach(build: build)
                return true
            } catch RPCError.serverError(let code, _) where code == LSPDaemon.staleDaemonCode && attempt == 0 {
                // Демон от прошлой сборки Pilot уходит сам — поднимем свежий.
                client.stop()
                await Task.detached { LSPDaemon.waitUntilGone(socketPath: socket) }.value
            } catch {
                client.stop()
                return false
            }
        }
        return false
    }

    /// Демона включили или выключили. Сервер текущего проекта поднимается
    /// заново — уже новым способом, а выключенный демон уходит сам и уносит
    /// с собой серверы, которые держал.
    func daemonSettingChanged(reopening document: LoadedDocument?) {
        if !Experimental.lspDaemon, let executable = Bundle.main.executablePath {
            let socket = LSPDaemon.socketPath(executable: executable)
            Task.detached { LSPDaemon.requestQuit(socketPath: socket) }
        }
        workspaceChanged(to: root)
        if let document { documentOpened(document) }
    }

    private func showProjectProgress() {
        guard initialized, !projectsFinished else { return }
        if projectsTotal > 0 {
            state = .starting("проекты \(min(projectsLoaded, projectsTotal)) из \(projectsTotal)")
        } else {
            state = .starting(projectsLoaded > 0 ? "загружено проектов: \(projectsLoaded)"
                                                 : "загрузка проектов")
        }
    }

    private func becomeReady(_ client: LSPClient) {
        guard state != .ready else { return }   // повторное уведомление ничего не меняет
        state = .ready
        // Индекс символов строится около минуты — пусть это случится сейчас,
        // в фоне, а не на первом ⌘T. Общий сервер прогревает демон.
        if !viaDaemon {
            Task { await client.warmUpSymbolIndex() }
        }
    }

    // MARK: - Запросы
    //
    // Все возвращают пустой результат вместо ошибки: для читателя кода
    // «не нашлось» и «сервер ещё не прогрелся» — одно и то же, и ни то,
    // ни другое не повод показывать диалог с ошибкой.

    func definition(url: URL, position: LSPPosition) async -> [LSPLocation] {
        guard let client, isReady, client.capabilities.definition else { return [] }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": position.line, "character": position.character],
        ]
        guard let result = try? await client.request("textDocument/definition", params) else { return [] }
        return LSPLocation.parse(result)
    }

    func references(url: URL, position: LSPPosition) async -> [LSPLocation] {
        guard let client, isReady, client.capabilities.references else { return [] }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": position.line, "character": position.character],
            "context": ["includeDeclaration": false],
        ]
        guard let result = try? await client.request("textDocument/references", params,
                                                     timeout: 60) else { return [] }
        return LSPLocation.parse(result)
    }

    func hover(url: URL, position: LSPPosition) async -> String? {
        guard let client, isReady, client.capabilities.hover else { return nil }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": position.line, "character": position.character],
        ]
        guard let result = try? await client.request("textDocument/hover", params,
                                                     timeout: 4) else { return nil }
        return HoverContent.parse(result)
    }

    func symbols(matching query: String) async -> [LSPSymbol] {
        guard let client, isReady, client.capabilities.workspaceSymbol else { return [] }
        // Таймаут с запасом: если индекс символов ещё прогревается, запрос
        // дождётся его, а не вернёт пустоту. Устаревший запрос при наборе
        // следующей буквы снимается отменой задачи, а не таймаутом.
        guard let result = try? await client.request("workspace/symbol", ["query": query],
                                                     timeout: 60) else { return [] }
        return LSPSymbol.parse(result)
    }

    /// Файл, который сервер ещё не видел, нужно ему показать — иначе
    /// запросы по нему вернут пустоту.
    func ensureOpen(_ document: LoadedDocument) {
        guard let client, isReady,
              client.config.fileExtensions.contains(document.url.pathExtension.lowercased())
        else { return }
        client.didOpen(url: document.url,
                       languageId: client.config.languageId,
                       text: document.text)
    }

    func shutdown() {
        client?.stop()
        client = nil
        state = .stopped
    }
}
