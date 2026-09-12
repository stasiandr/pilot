import SwiftUI
import Foundation

/// Оркестровка языковых серверов для одного воркспейса.
///
/// Главный принцип: сервер стартует **лениво** — только когда впервые открыт
/// файл соответствующего языка, и никогда при запуске приложения. Пока Roslyn
/// грузит solution, Pilot полностью работоспособен: поиск, просмотр,
/// подсветка не зависят от него ни одной строкой кода.
@MainActor
final class LSPService: ObservableObject {

    @Published private(set) var state: LSPState = .stopped
    @Published private(set) var serverName: String?

    private var client: LSPClient?
    private var root: URL?
    private var startedForExtension: String?

    var isReady: Bool { state == .ready }

    // MARK: - Жизненный цикл

    func workspaceChanged(to newRoot: URL?) {
        client?.stop()
        client = nil
        startedForExtension = nil
        root = newRoot
        state = .stopped
        serverName = nil
    }

    /// Вызывается при открытии файла. Если для его языка есть сервер и он
    /// ещё не запущен — поднимаем. В остальное время это но-оп.
    func documentOpened(_ document: LoadedDocument) {
        guard let root else { return }
        let ext = document.url.pathExtension.lowercased()
        guard !ext.isEmpty else { return }

        if let client, client.config.fileExtensions.contains(ext) {
            client.didOpen(url: document.url,
                           languageId: client.config.languageId,
                           text: document.text)
            return
        }
        guard startedForExtension == nil,
              let config = ServerRegistry.server(forExtension: ext, root: root) else { return }

        startedForExtension = ext
        launch(config: config, root: root, firstDocument: document)
    }

    private func launch(config: ServerConfig, root: URL, firstDocument: LoadedDocument) {
        let client = LSPClient(config: config, root: root)
        self.client = client
        serverName = config.displayName
        state = .starting("запускается")

        client.onStatus = { [weak self] text in
            Task { @MainActor in
                guard let self, case .starting = self.state else { return }
                self.state = .starting(text)
            }
        }
        client.onExit = { [weak self] reason in
            Task { @MainActor in
                self?.state = .failed(reason)
            }
        }

        Task {
            do {
                try client.start()
                state = .starting("инициализация")
                try await client.initialize()
                state = .ready
                client.didOpen(url: firstDocument.url,
                               languageId: config.languageId,
                               text: firstDocument.text)
            } catch {
                state = .failed(error.localizedDescription)
            }
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
                                                     timeout: 20) else { return [] }
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
        guard let result = try? await client.request("workspace/symbol", ["query": query],
                                                     timeout: 10) else { return [] }
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
