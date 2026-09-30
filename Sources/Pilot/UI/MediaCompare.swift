import SwiftUI
import AppKit

/// Две версии картинки, модели, шрифта или PDF — рядом, тем же
/// просмотрщиком, что открывает файл в редакторе. Картинки — ещё и
/// наложением: ползунок плавно переводит «было» в «стало», и видно, что
/// поменялось. Версии достаются из git (и из LFS) в фоне.
struct MediaCompareView: View {
    struct Side: Equatable {
        var title: String
        var revision: GitBlobs.Revision
    }

    let repository: URL
    let path: String
    /// Откуда: для переименованного — старый путь.
    var originalPath: String? = nil
    let before: Side
    let after: Side

    @State private var urls: (before: URL?, after: URL?)?
    @State private var mode: Mode = .difference
    @State private var mix = 1.0

    /// Картинки: рядом, рядом с подсветкой изменённого, или наложением.
    enum Mode: Hashable { case sideBySide, difference, overlay }
    private var overlay: Bool { mode == .overlay }

    private var kind: MediaKind? { MediaKind(filename: path) }

    var body: some View {
        VStack(spacing: 0) {
            if kind == .image, let urls, urls.before != nil, urls.after != nil {
                HStack {
                    Picker("", selection: $mode) {
                        Text(L("Разница")).tag(Mode.difference)
                        Text(L("Рядом")).tag(Mode.sideBySide)
                        Text(L("Наложением")).tag(Mode.overlay)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if overlay {
                        Text(before.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $mix, in: 0...1).frame(maxWidth: 220)
                        Text(after.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                Divider()
            }
            content
        }
        .task(id: before.title + after.title + path) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let kind, let urls {
            if overlay, kind == .image, let old = urls.before, let new = urls.after {
                ZStack {
                    OverlayImage(url: old)
                    OverlayImage(url: new).opacity(mix)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mode == .difference, kind == .image, let old = urls.before, let new = urls.after {
                // Справа — что изменилось, красным поверх новой версии.
                HStack(spacing: 0) {
                    titled(before.title) { ImageDiffPane(url: old) }
                    Rectangle().fill(Color(nsColor: Theme.separator)).frame(width: 1)
                    titled(after.title) { ImageDiffPane(url: new, base: old) }
                }
            } else {
                HStack(spacing: 0) {
                    pane(before.title, url: urls.before, kind: kind, missing: L("Файла не было"))
                    Rectangle().fill(Color(nsColor: Theme.separator)).frame(width: 1)
                    pane(after.title, url: urls.after, kind: kind, missing: L("Файл удалён"))
                }
            }
        } else if kind == nil {
            Text(L("Двоичный файл — показать нечего")).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func titled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 22)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pane(_ title: String, url: URL?, kind: MediaKind, missing: String) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            if let url {
                MediaView(url: url, kind: kind)
                    .id(url)
            } else {
                Text(missing).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        urls = nil
        let repository = repository, path = path, original = originalPath ?? path
        let before = before.revision, after = after.revision
        urls = await Task.detached(priority: .userInitiated) {
            (GitBlobs.file(original, at: before, in: repository), GitBlobs.file(path, at: after, in: repository))
        }.value
    }
}

/// Картинка целиком, вписанная в место, — для наложения двух версий.
private struct OverlayImage: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            Text(url.lastPathComponent).foregroundStyle(.tertiary)
        }
    }
}

/// Окно сравнения версий из истории: картинка или модель в коммите и до него.
struct MediaCompareWindow: View {
    static let sceneID = "media-compare"
    /// `корень проекта` + `\n` + ключ сравнения в воркспейсе.
    let target: String?

    var body: some View {
        Group {
            if let target, let found = resolve(target), let repository = found.workspace.git.repository {
                MediaCompareView(repository: repository, path: found.comparison.path,
                                 originalPath: found.comparison.originalPath,
                                 before: found.comparison.before, after: found.comparison.after)
                    .navigationTitle((found.comparison.path as NSString).lastPathComponent)
            } else {
                Text(L("Проект этого окна закрыт")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 420)
        .background(Color(nsColor: Theme.swiftUIEditorBackground))
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
    }

    private func resolve(_ target: String) -> (workspace: Workspace, comparison: MediaComparison)? {
        let parts = target.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, let workspace = ProjectWindows.shared.workspaces.first(where: { $0.root?.path == parts[0] }),
              let comparison = workspace.mediaComparisons[parts[1]] else { return nil }
        return (workspace, comparison)
    }
}

// MARK: - Разница картинок

/// Картинка, вписанная в место, и поверх неё — красным то, что изменилось
/// относительно `base`. Подпись — сколько и где.
struct ImageDiffPane: View {
    let url: URL
    var base: URL? = nil
    var showsMask = true

    @State private var image: NSImage?
    @State private var diff: ImageDiff?
    @State private var caption = ""

    var body: some View {
        VStack(spacing: 6) {
            if let image {
                ZStack {
                    Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    if showsMask, let mask = diff?.mask {
                        Image(decorative: mask, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .task(id: url.path + (base?.path ?? "")) {
            let url = url, base = base
            let (loaded, computed, size, baseSize) = await Task.detached(priority: .userInitiated) {
                (NSImage(contentsOf: url), base.flatMap { ImageDiff.compare(url, $0) }, ImageDiff.size(of: url),
                 base.flatMap(ImageDiff.size(of:)))
            }.value
            image = loaded
            diff = computed
            let dimensions = size.map { "\($0.0)×\($0.1)" } ?? ""
            if let computed {
                caption = dimensions + " · " + computed.summary
            } else if let size, let baseSize, size != baseSize {
                caption = L("\(baseSize.0)×\(baseSize.1) → \(size.0)×\(size.1): размер изменился")
            } else {
                caption = dimensions
            }
        }
    }
}

// MARK: - Конфликт двоичного файла

/// Конфликт картинки, модели, шрифта: сливать нечего, выбирают одну
/// версию. Чтобы выбрать с толком — три колонки: наша, общий предок, их,
/// и у сторон видно, что каждая изменила. Картинки — маской изменённых
/// пикселей, модели — общей камерой и таблицей «было / наше / их».
struct BinaryMergeView: View {
    @ObservedObject var session: MergeSession
    let finish: (@escaping () async -> Bool) -> Void

    @State private var urls: [GitBlobs.Revision: URL?] = [:]
    @State private var showsMask = true
    @State private var facts: [Int: ModelFacts] = [:]
    @State private var sync = CameraSync()

    private var kind: MediaKind? { MediaKind(filename: session.path) }

    var body: some View {
        VStack(spacing: 0) {
            if kind == .image {
                HStack {
                    Toggle(L("Подсвечивать, что изменила каждая сторона"), isOn: $showsMask).toggleStyle(.checkbox)
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .frame(height: 30)
                Divider()
            }
            HStack(spacing: 0) {
                column(stage: 2, title: L("Наша: \(session.oursName)"))
                Divider()
                column(stage: 1, title: L("Было — общий предок"))
                Divider()
                column(stage: 3, title: session.theirsName.isEmpty ? L("Их версия") : L("Их: \(session.theirsName)"))
            }
            if kind == .model, facts.count > 1 {
                Divider()
                ModelFactsTable(base: facts[1], ours: facts[2], theirs: facts[3])
            }
            Divider()
            HStack(spacing: 8) {
                if let error = session.error {
                    Text(error).foregroundStyle(Color(nsColor: Theme.diagnosticError)).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                if session.busy { ProgressView().controlSize(.small) }
                Button(L("Взять нашу")) { finish { await session.takeWhole(true) } }
                if url(1) != nil {
                    Button(L("Оставить как было")) { finish { await session.takeBase() } }
                        .help(L("Ни одной из правок — версия общего предка"))
                }
                Button(L("Взять их")) { finish { await session.takeWhole(false) } }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(session.busy)
            .font(.system(size: 12))
            .padding(10)
        }
        .task(id: session.path) { await load() }
    }

    private func url(_ stage: Int) -> URL? { urls[.stage(stage)] ?? nil }

    @ViewBuilder
    private func column(stage: Int, title: String) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity).frame(height: 26)
            if urls[.stage(stage)] == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let file = url(stage), let kind {
                switch kind {
                case .image:
                    // У сторон — что изменилось относительно предка; у предка — он сам.
                    ImageDiffPane(url: file, base: stage == 1 ? nil : url(1), showsMask: showsMask)
                case .model:
                    ModelViewer(url: file, sync: sync, onLoad: { scene in facts[stage] = scene.facts })
                default:
                    MediaView(url: file, kind: kind)
                }
            } else {
                Text(stage == 1 ? L("Файла не было — обе стороны его добавили") : L("Файл удалён"))
                    .foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        let repository = session.repository, path = session.path
        let loaded = await Task.detached(priority: .userInitiated) { () -> [GitBlobs.Revision: URL?] in
            var result: [GitBlobs.Revision: URL?] = [:]
            for stage in 1...3 { result[.stage(stage)] = .some(GitBlobs.file(path, at: .stage(stage), in: repository)) }
            return result
        }.value
        urls = loaded
    }
}

/// Модели в конфликте — числами: что у предка, у нас и у них. Изменённое
/// стороной относительно предка подсвечено; ниже — какие сетки и
/// материалы каждая добавила или убрала.
struct ModelFactsTable: View {
    let base: ModelFacts?
    let ours: ModelFacts?
    let theirs: ModelFacts?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                GridRow {
                    Text("")
                    Text(L("Наша")).fontWeight(.medium)
                    Text(L("Было")).fontWeight(.medium)
                    Text(L("Их")).fontWeight(.medium)
                }
                row(L("Сетки")) { "\($0.meshes)" }
                row(L("Треугольники")) { "\($0.triangles)" }
                row(L("Вершины")) { $0.vertices.map(String.init) ?? "—" }
                row(L("Размер")) { $0.size ?? "—" }
                row(L("Материалы")) { "\($0.materials)" }
                row(L("Кости")) { "\($0.bones)" }
                row(L("Анимации")) { "\($0.animations)" }
            }
            .font(.system(size: 11, design: .monospaced))
            changes(L("Наша"), ours)
            changes(L("Их"), theirs)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: @escaping (ModelFacts) -> String) -> some View {
        let b = base.map(value)
        return GridRow {
            Text(title).foregroundStyle(.secondary)
            cell(ours.map(value), changed: ours.map(value) != b)
            Text(b ?? "—")
            cell(theirs.map(value), changed: theirs.map(value) != b)
        }
    }

    private func cell(_ text: String?, changed: Bool) -> some View {
        Text(text ?? "—")
            .foregroundStyle(changed ? Color.orange : .primary)
            .fontWeight(changed ? .semibold : .regular)
    }

    @ViewBuilder
    private func changes(_ side: String, _ facts: ModelFacts?) -> some View {
        if let facts, let base {
            let meshes = diff(base.meshNames, facts.meshNames), materials = diff(base.materialNames, facts.materialNames)
            let parts = [describe(L("сетки"), meshes), describe(L("материалы"), materials)].compactMap { $0 }
            if !parts.isEmpty {
                Text("\(side): " + parts.joined(separator: "; "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
        }
    }

    private func diff(_ old: [String], _ new: [String]) -> (added: [String], removed: [String]) {
        (new.filter { !old.contains($0) }, old.filter { !new.contains($0) })
    }

    private func describe(_ what: String, _ change: (added: [String], removed: [String])) -> String? {
        var parts: [String] = []
        if !change.added.isEmpty { parts.append("+" + change.added.prefix(6).joined(separator: ", ")) }
        if !change.removed.isEmpty { parts.append("−" + change.removed.prefix(6).joined(separator: ", ")) }
        return parts.isEmpty ? nil : "\(what) " + parts.joined(separator: " ")
    }
}
