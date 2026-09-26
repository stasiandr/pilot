import SwiftUI
import AppKit

// MARK: - Загрузка

/// Что сейчас в предпросмотре.
enum PreviewContent {
    case text(FilePreview)
    case image(NSImage)
    case message(String)
}

/// Грузит предпросмотр выбранной в палитре строки.
///
/// Чтение и первый проход лексера — в фоне. Пока держат стрелку, выделение
/// бежит быстрее, чем читается диск, поэтому устаревшие запросы
/// отбрасываются, так и не начавшись: очередь последовательная, и из
/// накопившихся выполняется только последний. Недавние файлы кэшируются —
/// ходить стрелками туда-обратно по одним и тем же результатам мгновенно.
@MainActor
final class PreviewLoader: ObservableObject {
    /// Что показано сейчас. Шапка и содержимое меняются вместе.
    @Published private(set) var target: NavTarget?
    @Published private(set) var content: PreviewContent?
    @Published private(set) var isLoading = false

    private var requested: NavTarget?
    private let queue = DispatchQueue(label: "pilot.preview", qos: .userInitiated)
    private let generation = AtomicCounter()
    private var cache: [URL: SyntaxModel] = [:]
    private var cacheOrder: [URL] = []

    /// Больше — не показываем: первый проход лексера по такому файлу
    /// заметно дольше, чем длится взгляд на строку в палитре.
    nonisolated static let maxBytes = 8 * 1024 * 1024
    static let cacheLimit = 12
    nonisolated static let imageExtensions: Set<String> = MediaKind.imageExtensions.union(["pdf"])

    /// `document` — открытый в редакторе файл: он уже разобран, диск не нужен.
    /// `archive` — открытый APK или JAR: его файлы читаются не с диска, а из jadx.
    func show(_ target: NavTarget?, document: LoadedDocument?, archive: ArchiveSession? = nil) {
        guard target != requested else { return }
        requested = target
        let current = generation.bump()

        guard let target else {
            present(nil, for: nil)
            return
        }
        if let document, document.url == target.url {
            present(Self.content(model: document.model, range: target.range), for: target)
            return
        }
        if let model = cache[target.url] {
            present(Self.content(model: model, range: target.range), for: target)
            return
        }

        isLoading = true
        let counter = generation
        queue.async { [weak self] in
            guard counter.isCurrent(current) else { return }
            let loaded = Self.load(target.url, archive: archive)
            Task { @MainActor in
                guard let self, counter.isCurrent(current) else { return }
                switch loaded {
                case .success(.model(let model)):
                    self.remember(model, for: target.url)
                    self.present(Self.content(model: model, range: target.range), for: target)
                case .success(.image(let image)):
                    self.present(.image(image), for: target)
                case .failure(let error):
                    self.present(.message(error.localizedDescription), for: target)
                }
            }
        }
    }

    private func present(_ content: PreviewContent?, for target: NavTarget?) {
        self.target = target
        self.content = content
        isLoading = false
    }

    private func remember(_ model: SyntaxModel, for url: URL) {
        cache[url] = model
        cacheOrder.removeAll { $0 == url }
        cacheOrder.append(url)
        if cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private static func content(model: SyntaxModel, range: LSPRange?) -> PreviewContent {
        if model.units.isEmpty { return .message(L("Пустой файл")) }
        return .text(FilePreview.make(model: model, range: range))
    }

    private enum Loaded {
        case model(SyntaxModel)
        case image(NSImage)
    }

    private nonisolated static func load(_ url: URL, archive: ArchiveSession?) -> Result<Loaded, Error> {
        if let archive, archive.owns(url) {
            return Result {
                .model(SyntaxModel(text: try archive.textSync(for: url),
                                   spec: Languages.detect(filename: url.lastPathComponent)))
            }
        }
        if imageExtensions.contains(url.pathExtension.lowercased()),
           let image = NSImage(contentsOf: url) {
            return .success(.image(image))
        }
        // Сборку .NET показываем так же, как в редакторе: её объявлениями.
        if AssemblySource.isAssembly(url) {
            return Result { .model(SyntaxModel(text: try AssemblySource.text(of: url), spec: Languages.csharp)) }
        }
        return Result {
            let text = try LoadedDocument.readText(url: url, maxBytes: maxBytes)
            return .model(SyntaxModel(text: text, spec: Languages.detect(filename: url.lastPathComponent)))
        }
    }
}

// MARK: - Вьюха

/// Панель предпросмотра: шапка с путём и строкой, под ней код.
struct PalettePreview: View {
    @ObservedObject var loader: PreviewLoader
    let root: URL?
    /// Двойной клик по предпросмотру — то же, что Return.
    var onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onOpen)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let url = loader.target?.url {
                let icon = Theme.fileIcon(forName: url.lastPathComponent)
                Image(systemName: icon.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: icon.color))
                Text(relativePath(url))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            if loader.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            if case .text(let preview) = loader.content {
                Text(lineLabel(preview))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        switch loader.content {
        case .text(let preview):
            PreviewCode(preview: preview)
                .id(targetKey)
        case .image(let image):
            VStack(spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        case .message(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(20)
        case nil:
            Color.clear
        }
    }

    /// Смена цели пересоздаёт код-вьюху: так прокрутка к строке срабатывает
    /// заново, даже если новая цель — в том же файле.
    private var targetKey: String {
        guard let target = loader.target else { return "" }
        return "\(target.url.path):\(target.range?.start.line ?? -1):\(target.range?.start.character ?? -1)"
    }

    private func lineLabel(_ preview: FilePreview) -> String {
        if let line = preview.focusLine { return L("стр. \(line + 1) из \(preview.lineCount)") }
        return Theme.count(preview.lineCount, "строка", "строки", "строк")
    }

    private func relativePath(_ url: URL) -> String {
        guard let root, url.path.hasPrefix(root.path + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.path.count + 1))
    }
}

/// Строки фрагмента с номерами — в шрифте и цветах редактора.
private struct PreviewCode: View {
    let preview: FilePreview
    private let font = Font(Theme.editorFont(size: 12) as CTFont)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.lines) { line in
                        row(line)
                    }
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                // После первой раскладки — иначе прокручивать ещё нечего.
                guard let focus = preview.focusLine else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(focus, anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
        }
        .background(Color(nsColor: Theme.editorBackground))
    }

    private func row(_ line: FilePreview.Line) -> some View {
        let isFocus = line.number == preview.focusLine
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(line.number + 1)")
                .foregroundColor(Color(nsColor: isFocus ? Theme.gutterTextCurrent : Theme.gutterText))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 12)
            Text(attributed(line))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(font)
        .padding(.vertical, 1)
        .background(isFocus ? Color(nsColor: Theme.currentLine) : .clear)
        .id(line.number)
    }

    private var gutterWidth: CGFloat {
        CGFloat(String(preview.lineCount).count) * 7.5 + 12
    }

    private func attributed(_ line: FilePreview.Line) -> AttributedString {
        var result = AttributedString()
        for segment in line.segments {
            var part = AttributedString(segment.text)
            part.foregroundColor = Color(nsColor: Theme.color(segment.kind))
            if segment.focused {
                part.backgroundColor = Color(nsColor: NSColor.findHighlightColor.withAlphaComponent(0.45))
            }
            result += part
        }
        return result
    }
}
