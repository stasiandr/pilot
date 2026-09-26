import SwiftUI
import Foundation

/// Оркестровка языковых серверов для одного воркспейса.
///
/// Главный принцип: сервер никогда не блокирует просмотр. Пока он
/// поднимается, Pilot полностью работоспособен: поиск, просмотр, подсветка не
/// зависят от него ни одной строкой кода.
///
/// Сервер поднимается при первом файле своего языка. C# сюда не попадает
/// вовсе: его понимает Rustlyn, в процессе, и сервер ему не нужен.
@MainActor
final class LSPService: ObservableObject {

    @Published private(set) var state: LSPState = .stopped
    @Published private(set) var serverName: String?

    private var client: LSPClient?
    private var root: URL?
    private var startedForExtension: String?
    /// Файл, открытый, пока сервер инициализируется: didOpen раньше ответа
    /// на initialize протокол не допускает. Отправим, когда можно.
    private var pendingDocument: LoadedDocument?

    private var initialized = false

    var isReady: Bool { state == .ready }

    // MARK: - Жизненный цикл

    func workspaceChanged(to newRoot: URL?) {
        pendingFullSync.removeAll()
        fullSyncTask?.cancel()
        client?.stop()
        client = nil
        startedForExtension = nil
        pendingDocument = nil
        root = newRoot
        state = .stopped
        serverName = nil
    }

    /// Вызывается при открытии файла. Если для его языка есть сервер и он
    /// ещё не запущен — поднимаем. В остальное время это но-оп.
    func documentOpened(_ document: LoadedDocument) {
        guard let root, !Rustlyn.understands(document.url) else { return }
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
        state = .starting(L("запускается"))
        initialized = false

        // Колбэки приходят с потока чтения пайпа. `self.client === client`
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
        Task {
            do {
                try client.start()
                state = .starting(L("инициализация"))
                try await client.initialize()
                guard self.client === client else { return }
                initialized = true
                if let document = pendingDocument {
                    pendingDocument = nil
                    client.didOpen(url: document.url, languageId: config.languageId, text: document.text)
                }
                state = .ready
            } catch {
                guard self.client === client else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Правки

    /// Документы, чей полный текст ещё не отправлен (сервер без
    /// инкрементальной синхронизации). Отправляются с задержкой — и
    /// обязательно перед любым запросом, иначе сервер ответит по старому тексту.
    private var pendingFullSync: [URL: LoadedDocument] = [:]
    private var fullSyncTask: Task<Void, Never>?

    /// Правка в открытом документе: `range` — в координатах до правки.
    func documentEdited(_ document: LoadedDocument, range: LSPRange, text: String) {
        guard let client, client.isOpen(document.url) else { return }
        switch client.capabilities.syncKind {
        case 2:
            client.didChange(url: document.url, changes: [[
                "range": ["start": ["line": range.start.line, "character": range.start.character],
                          "end": ["line": range.end.line, "character": range.end.character]],
                "text": text,
            ]])
        case 1:
            pendingFullSync[document.url] = document
            fullSyncTask?.cancel()
            fullSyncTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.flushPendingChanges()
            }
        default:
            break
        }
    }

    private func flushPendingChanges() {
        guard let client, !pendingFullSync.isEmpty else { return }
        for (url, document) in pendingFullSync {
            client.didChange(url: url, changes: [["text": document.text]])
        }
        pendingFullSync.removeAll()
    }

    /// Буфер выгружен: сервер забывает документ, а при следующем открытии
    /// получит текст с диска заново — вдруг файл поменяли снаружи.
    func documentClosed(_ url: URL) {
        pendingFullSync[url] = nil
        client?.didClose(url: url)
    }

    func documentSaved(_ url: URL) {
        flushPendingChanges()
        client?.didSave(url: url)
    }

    /// Файл обслуживается готовым сервером, который умеет дополнение.
    func providesCompletion(for url: URL) -> Bool {
        guard let client, isReady, client.capabilities.completion else { return false }
        return client.config.fileExtensions.contains(url.pathExtension.lowercased())
    }

    var completionTriggers: [String] { client?.capabilities.completionTriggers ?? [] }

    // MARK: - Запросы
    //
    // Все возвращают пустой результат вместо ошибки: для читателя кода
    // «не нашлось» и «сервер ещё не прогрелся» — одно и то же, и ни то,
    // ни другое не повод показывать диалог с ошибкой.

    /// nil — сервер не ответил или не умеет; пустой список — вариантов нет.
    func completion(url: URL, position: LSPPosition, trigger: String?, retrigger: Bool) async -> CompletionList? {
        guard let client, isReady, client.capabilities.completion else { return nil }
        flushPendingChanges()
        var context: [String: Any] = ["triggerKind": retrigger ? 3 : (trigger == nil ? 1 : 2)]
        if let trigger { context["triggerCharacter"] = trigger }
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": position.line, "character": position.character],
            "context": context,
        ]
        guard let result = try? await client.request("textDocument/completion", params,
                                                     timeout: 5) else { return nil }
        return CompletionList.parse(result)
    }

    func definition(url: URL, position: LSPPosition) async -> [LSPLocation] {
        guard let client, isReady, client.capabilities.definition else { return [] }
        flushPendingChanges()
        let params: [String: Any] = [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": position.line, "character": position.character],
        ]
        guard let result = try? await client.request("textDocument/definition", params) else { return [] }
        return LSPLocation.parse(result)
    }

    func references(url: URL, position: LSPPosition) async -> [LSPLocation] {
        guard let client, isReady, client.capabilities.references else { return [] }
        flushPendingChanges()
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
