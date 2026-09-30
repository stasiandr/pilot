import SwiftUI
import AppKit
import SceneKit

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

/// Конфликт картинки, модели, шрифта — как слияние текста: слева наша
/// версия, справа их, посередине — чем они отличаются. Выбор — одна из
/// двух: слить картинку или модель по кускам нельзя.
///
/// Разница — у картинки маской отличающихся пикселей или наложением с
/// ползунком; у модели — обе в одной сцене, наша оранжевым, их синим, и у
/// всех трёх просмотрщиков общая камера.
struct BinaryMergeView: View {
    @ObservedObject var session: MergeSession
    let finish: (@escaping () async -> Bool) -> Void

    @State private var ours: URL??
    @State private var theirs: URL??
    @State private var facts: [Int: ModelFacts] = [:]
    @State private var sync = CameraSync()
    @State private var blend = false
    @State private var mix = 0.5

    private var kind: MediaKind? { MediaKind(filename: session.path) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                column(title: L("Наша: \(session.oursName)"), url: ours, stage: 2)
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text(L("Чем отличаются")).font(.system(size: 12, weight: .medium))
                        if kind == .image {
                            Picker("", selection: $blend) {
                                Text(L("Маска")).tag(false)
                                Text(L("Наложение")).tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 26)
                    difference
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                column(title: session.theirsName.isEmpty ? L("Их версия") : L("Их: \(session.theirsName)"), url: theirs, stage: 3)
            }
            if kind == .model, facts[2] != nil || facts[3] != nil {
                Divider()
                ModelFactsTable(left: facts[2], right: facts[3])
            }
            Divider()
            HStack(spacing: 8) {
                Button(L("← Взять левое")) { finish { await session.takeWhole(true) } }
                    .disabled(ours == .some(nil))
                if let error = session.error {
                    Text(error).foregroundStyle(Color(nsColor: Theme.diagnosticError)).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                if session.busy { ProgressView().controlSize(.small) }
                Button(L("Взять правое →")) { finish { await session.takeWhole(false) } }
                    .disabled(theirs == .some(nil))
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.busy)
            .font(.system(size: 12))
            .padding(10)
        }
        .task(id: session.path) { await load() }
    }

    @ViewBuilder
    private func column(title: String, url: URL??, stage: Int) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity).frame(height: 26)
            switch url {
            case .none:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(.none):
                Text(L("Файл удалён")).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(.some(let file)):
                switch kind {
                case .image?: ImageDiffPane(url: file)
                case .model?: ModelViewer(url: file, sync: sync, onLoad: { scene in facts[stage] = scene.facts })
                case let other?: MediaView(url: file, kind: other)
                case nil: Text(file.lastPathComponent).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var difference: some View {
        if case .some(.some(let left)) = ours, case .some(.some(let right)) = theirs {
            switch kind {
            case .image?:
                if blend {
                    VStack(spacing: 6) {
                        ZStack {
                            OverlayImage(url: left)
                            OverlayImage(url: right).opacity(mix)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        HStack {
                            Text(L("левое")).font(.system(size: 11)).foregroundStyle(.secondary)
                            Slider(value: $mix, in: 0...1)
                            Text(L("правое")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 320)
                    }
                    .padding(8)
                } else {
                    // Поверх левой — красным, где правая другая.
                    ImageDiffPane(url: left, base: right)
                }
            case .model?:
                ModelOverlayViewer(left: left, right: right, sync: sync)
            default:
                Text(L("Сравнить можно только глазами — слева и справа"))
                    .foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if ours == nil || theirs == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(L("Одна сторона файл удалила")).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        let repository = session.repository, path = session.path
        let (left, right) = await Task.detached(priority: .userInitiated) {
            (GitBlobs.file(path, at: .stage(2), in: repository), GitBlobs.file(path, at: .stage(3), in: repository))
        }.value
        ours = .some(left)
        theirs = .some(right)
    }
}

/// Две модели в одной сцене: левая оранжевым, правая синим, обе
/// полупрозрачные. Где совпадают — смешанный цвет, где разошлись — видно,
/// чья деталь.
struct ModelOverlayViewer: View {
    let left: URL
    let right: URL
    var sync: CameraSync? = nil

    @State private var model: ModelScene?
    @State private var error: String?

    var body: some View {
        Group {
            if let model {
                SceneView3D(model: model, wireframe: false, sync: sync)
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 14) {
                            legend(.orange, L("левое"))
                            legend(.blue, L("правое"))
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .padding(8)
                    }
            } else if let error {
                Text(error).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: left.path + right.path) {
            let left = left, right = right
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ModelScene, Error> in
                Result { try ModelScene.overlay(try ModelScene.load(left), try ModelScene.load(right)) }
            }.value
            switch result {
            case .success(let scene): model = scene
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

extension ModelScene {
    /// Сцена из двух моделей: у каждой свой полупрозрачный цвет.
    static func overlay(_ left: ModelScene, _ right: ModelScene) -> ModelScene {
        let scene = SCNScene()
        func add(_ source: ModelScene, _ color: NSColor) {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.transparency = 0.55
            material.isDoubleSided = true
            material.lightingModel = .blinn
            material.writesToDepthBuffer = false
            let root = source.scene.rootNode.clone()
            root.enumerateHierarchy { node, _ in
                if node.camera != nil || node.light != nil { node.removeFromParentNode(); return }
                if let geometry = node.geometry?.copy() as? SCNGeometry {
                    geometry.materials = [material]
                    node.geometry = geometry
                }
            }
            scene.rootNode.addChildNode(root)
        }
        add(left, NSColor.systemOrange)
        add(right, NSColor.systemBlue)
        let radius = max(left.radius, right.radius)
        let center = SCNVector3((left.center.x + right.center.x) / 2, (left.center.y + right.center.y) / 2,
                                (left.center.z + right.center.z) / 2)
        return ModelScene(scene: scene, center: center, radius: radius, info: [])
    }
}

/// Модели в конфликте — числами: левая и правая, различия подсвечены;
/// ниже — какие сетки и материалы есть только у одной из них.
struct ModelFactsTable: View {
    let left: ModelFacts?
    let right: ModelFacts?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                GridRow {
                    Text("")
                    Text(L("Левое")).fontWeight(.medium)
                    Text(L("Правое")).fontWeight(.medium)
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
            if let left, let right {
                only(L("Только слева"), left, right)
                only(L("Только справа"), right, left)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: @escaping (ModelFacts) -> String) -> some View {
        let l = left.map(value), r = right.map(value)
        return GridRow {
            Text(title).foregroundStyle(.secondary)
            cell(l, differs: l != r)
            cell(r, differs: l != r)
        }
    }

    private func cell(_ text: String?, differs: Bool) -> some View {
        Text(text ?? "—")
            .foregroundStyle(differs ? Color.orange : .primary)
            .fontWeight(differs ? .semibold : .regular)
    }

    @ViewBuilder
    private func only(_ title: String, _ a: ModelFacts, _ b: ModelFacts) -> some View {
        let meshes = a.meshNames.filter { !b.meshNames.contains($0) }
        let materials = a.materialNames.filter { !b.materialNames.contains($0) }
        if !meshes.isEmpty || !materials.isEmpty {
            let parts = [meshes.isEmpty ? nil : L("сетки ") + meshes.prefix(8).joined(separator: ", "),
                         materials.isEmpty ? nil : L("материалы ") + materials.prefix(8).joined(separator: ", ")].compactMap { $0 }
            Text("\(title): " + parts.joined(separator: "; "))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }
    }
}
