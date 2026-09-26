import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

/// Свёрстанный Markdown. Текст берётся из буфера, а не с диска: поправил
/// исходник, вернулся — видишь правку, даже несохранённую.
///
/// Страница и картинки из документа отдаются через свою схему `pilot-md:`:
/// WKWebView не пускает страницу, загруженную из строки, к файлам на диске.
struct MarkdownView: NSViewRepresentable {
    let buffer: TextBuffer
    /// Версия текста — чтобы пересобрать страницу после правок.
    let version: Int
    let reveal: Workspace.RevealRequest?
    let fontSize: CGFloat
    var onOpenFile: (URL) -> Void
    var onShowSource: (Int) -> Void

    static let scheme = "pilot-md"

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        var parent: MarkdownView
        weak var webView: WKWebView?
        var page = Data()
        var loaded: (buffer: ObjectIdentifier, version: Int, fontSize: CGFloat, scheme: String)?
        var appliedReveal: Int?
        var pendingReveal: Int?
        var isLoading = false

        init(_ parent: MarkdownView) {
            self.parent = parent
            super.init()
            // Стили страницы — в цветах схемы: сменили её — пересобираем.
            NotificationCenter.default.addObserver(
                self, selector: #selector(colorSchemeChanged), name: ThemeStore.didChange, object: nil)
        }

        @objc private func colorSchemeChanged() {
            webView?.underPageBackgroundColor = Theme.editorBackground
            load(parent)
        }

        // MARK: Страница и файлы

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let data: Data
            let mime: String
            if url.host == "page" {
                data = page
                mime = "text/html"
            } else if let file = Self.fileURL(url), let contents = try? Data(contentsOf: file) {
                data = contents
                mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            } else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        /// `pilot-md://file/abs/path` → файл на диске.
        static func fileURL(_ url: URL) -> URL? {
            guard url.scheme == MarkdownView.scheme, url.host == "file" else { return nil }
            return URL(fileURLWithPath: url.path)
        }

        // MARK: Переходы

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == MarkdownView.scheme, url.host == "page", action.navigationType != .linkActivated {
                return decisionHandler(.allow)
            }
            decisionHandler(.cancel)
            guard action.navigationType == .linkActivated else { return }
            if let file = Self.fileURL(url) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } else {
                        parent.onOpenFile(file)
                    }
                }
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            if let line = pendingReveal {
                pendingReveal = nil
                scroll(to: line)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let line = body["source"] as? Int {
                parent.onShowSource(line)
            } else if let y = body["scroll"] as? Double {
                parent.buffer.markdownScroll = y
            }
        }

        func scroll(to line: Int) {
            guard !isLoading else { pendingReveal = line; return }
            webView?.evaluateJavaScript("pilotReveal(\(line))")
        }

        // MARK: Сборка

        func load(_ view: MarkdownView) {
            guard let webView else { return }
            let key = (ObjectIdentifier(view.buffer), view.version, view.fontSize, Theme.current.id)
            if let loaded, loaded.buffer == key.0, loaded.version == key.1, loaded.fontSize == key.2,
               loaded.scheme == key.3 { return }
            let sameDocument = loaded?.buffer == key.0
            loaded = key
            if sameDocument {
                // Пересборка того же документа — на том же месте.
                webView.evaluateJavaScript("window.scrollY") { [weak self] y, _ in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        view.buffer.markdownScroll = (y as? Double) ?? view.buffer.markdownScroll
                        self.render(view)
                    }
                }
            } else {
                render(view)
            }
        }

        private func render(_ view: MarkdownView) {
            guard let webView else { return }
            let directory = view.buffer.url.deletingLastPathComponent().path
            let base = MarkdownView.scheme + "://file" + (directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory) + "/"
            let body = Markdown.html(view.buffer.model.text)
            let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <base href="\(Markdown.escape(base))">
            <style>\(Theme.markdownCSS) body{font-size:\(Int(view.fontSize + 2))px}</style>
            </head><body><main>\(body)</main>
            <script>\(MarkdownView.script(scroll: view.buffer.markdownScroll))</script>
            </body></html>
            """
            page = Data(html.utf8)
            isLoading = true
            webView.load(URLRequest(url: URL(string: MarkdownView.scheme + "://page/\(UUID().uuidString)")!))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: Self.scheme)
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: "pilot")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = Theme.editorBackground
        context.coordinator.webView = webView
        context.coordinator.appliedReveal = reveal?.seq
        context.coordinator.load(self)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.load(self)
        if let reveal, reveal.seq != coordinator.appliedReveal {
            coordinator.appliedReveal = reveal.seq
            if let line = reveal.range?.start.line { coordinator.scroll(to: line) }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pilot")
    }

    /// Прокрутка к строке исходника, двойной клик → исходник, якоря
    /// `#заголовок` внутри страницы и запоминание прокрутки.
    static func script(scroll: Double) -> String {
        """
        (function(){
          const post = m => window.webkit.messageHandlers.pilot.postMessage(m);
          window.scrollTo(0, \(scroll));
          window.pilotReveal = function(line){
            let best = null;
            for (const el of document.querySelectorAll('[data-line]')) {
              if (+el.dataset.line <= line) best = el; else break;
            }
            if (!best) return;
            best.scrollIntoView({block: 'start'});
            best.classList.remove('flash'); void best.offsetWidth; best.classList.add('flash');
          };
          document.addEventListener('dblclick', e => {
            if (e.target.closest('a')) return;
            const el = e.target.closest('[data-line]');
            if (el) post({source: +el.dataset.line});
          });
          document.addEventListener('click', e => {
            const a = e.target.closest('a[href]');
            if (!a) return;
            const href = a.getAttribute('href');
            if (href.startsWith('#')) {
              e.preventDefault();
              const target = document.getElementById(decodeURIComponent(href.slice(1)).toLowerCase());
              if (target) target.scrollIntoView({block: 'start'});
            }
          });
          let timer = null;
          window.addEventListener('scroll', () => {
            clearTimeout(timer);
            timer = setTimeout(() => post({scroll: window.scrollY}), 150);
          });
        })();
        """
    }
}

/// WKUserContentController держит обработчик сильно — без прокладки
/// координатор со всем документом не освобождался бы никогда.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
