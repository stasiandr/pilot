import SwiftUI
import AppKit
import PDFKit
import SceneKit
import ModelIO
import SceneKit.ModelIO
import CoreText
import ImageIO

/// Вместо редактора — просмотр файла, который не текст.
struct MediaView: View {
    let url: URL
    let kind: MediaKind

    var body: some View {
        switch kind {
        case .image: ImageViewer(url: url)
        case .pdf:   PDFViewer(url: url)
        case .font:  FontViewer(url: url)
        case .model: ModelViewer(url: url)
        }
    }
}

/// Подпись поверх просмотра: размеры, формат, вес файла.
private struct InfoCapsule<Trailing: View>: View {
    let items: [String]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(items.joined(separator: "  ·  "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(nsColor: Theme.chromeBackground).opacity(0.92)))
        .overlay(Capsule().stroke(Color(nsColor: Theme.separator), lineWidth: 1))
        .padding(10)
    }
}

private func fileSize(_ url: URL) -> String? {
    guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

private struct MediaMessage: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MediaButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Картинки

struct ImageViewer: View {
    let url: URL

    private struct Loaded {
        let image: NSImage
        let pixels: CGSize
        let info: [String]
    }

    @State private var loaded: Loaded?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var command = ImageScrollView.Command(seq: 0, kind: .fit)

    var body: some View {
        Group {
            if let loaded {
                ImageScrollView(image: loaded.image, pixels: loaded.pixels, command: command, zoom: $zoom)
                    .overlay(alignment: .bottom) {
                        InfoCapsule(items: loaded.info + ["\(Int((zoom * 100).rounded()))%"]) {
                            MediaButton(symbol: "arrow.up.left.and.arrow.down.right", help: L("Вписать в окно")) {
                                command = .init(seq: command.seq + 1, kind: .fit)
                            }
                            MediaButton(symbol: "1.square", help: L("Реальный размер")) {
                                command = .init(seq: command.seq + 1, kind: .actual)
                            }
                        }
                    }
            } else if failed {
                MediaMessage(icon: "photo.badge.exclamationmark", text: L("Картинку не прочитать"))
            } else {
                Color.clear
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let url = self.url
        let result: Loaded? = await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: url) else { return nil }
            var pixels = image.size
            var info: [String] = []
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                pixels = CGSize(width: w, height: h)
                let frames = CGImageSourceGetCount(source)
                if frames > 1 { info.append(Localization.count(frames, "кадр", "кадра", "кадров")) }
                if props[kCGImagePropertyHasAlpha] as? Bool == true { info.append(L("альфа")) }
            } else if let rep = image.representations.first, rep.pixelsWide > 0 {
                pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
            info.insert("\(Int(pixels.width)) × \(Int(pixels.height))", at: 0)
            info.insert(url.pathExtension.uppercased(), at: 1)
            if let size = fileSize(url) { info.append(size) }
            return Loaded(image: image, pixels: pixels, info: info)
        }.value
        loaded = result
        failed = result == nil
    }
}

/// Прокрутка с увеличением: картинка по центру, под ней шахматка —
/// чтобы было видно прозрачность. При увеличении пиксели не размываются:
/// в текстурах важно видеть, что там на самом деле.
struct ImageScrollView: NSViewRepresentable {
    let image: NSImage
    let pixels: CGSize
    let command: Command
    @Binding var zoom: CGFloat

    struct Command: Equatable {
        var seq: Int
        var kind: Kind
        enum Kind { case fit, actual }
    }

    final class Coordinator: NSObject {
        var parent: ImageScrollView
        var appliedCommand = -1
        var observer: NSObjectProtocol?
        init(_ parent: ImageScrollView) { self.parent = parent }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 64
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = Theme.editorBackground
        scroll.contentView = clip

        let imageView = CheckerImageView()
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.frame = NSRect(origin: .zero, size: pixels)
        scroll.documentView = imageView

        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main
        ) { [weak scroll] _ in
            guard let scroll else { return }
            MainActor.assumeIsolated { context.coordinator.parent.zoom = scroll.magnification }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.appliedCommand != command.seq else { return }
        context.coordinator.appliedCommand = command.seq
        // Размер окна становится известен после раскладки.
        DispatchQueue.main.async {
            let bounds = scroll.contentSize
            var magnification: CGFloat = 1
            if command.kind == .fit, pixels.width > 0, pixels.height > 0, bounds.width > 0 {
                // Поля — чтобы плашка с размерами не легла на картинку.
                let fit = min((bounds.width - 48) / pixels.width, (bounds.height - 110) / pixels.height)
                magnification = min(1, max(fit, scroll.minMagnification))
                // Мелкие иконки и спрайты — крупнее, иначе их не разглядеть.
                if max(pixels.width, pixels.height) <= 64 { magnification = min(8, max(1, floor(fit))) }
            }
            scroll.magnification = magnification
            zoom = magnification
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Держит документ по центру, пока он меньше окна.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

private final class CheckerImageView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        let cell: CGFloat = 8
        NSColor(white: 0.30, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.38, alpha: 1).setFill()
        let startX = Int(dirtyRect.minX / cell), endX = Int(dirtyRect.maxX / cell)
        let startY = Int(dirtyRect.minY / cell), endY = Int(dirtyRect.maxY / cell)
        for y in startY...endY {
            for x in startX...endX where (x + y) % 2 == 0 {
                NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).intersection(bounds).fill()
            }
        }
        NSGraphicsContext.current?.imageInterpolation = (enclosingScrollView?.magnification ?? 1) > 1.5 ? .none : .high
        super.draw(dirtyRect)
    }
}

// MARK: - PDF

struct PDFViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = Theme.editorBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

// MARK: - Шрифты

struct FontViewer: View {
    let url: URL

    struct Face: Identifiable {
        let id: Int
        let font: CTFont
        let family: String
        let style: String
        let details: [String]
        let scripts: [(name: String, supported: Bool)]
        let glyphs: [String]
    }

    @State private var faces: [Face]?
    @State private var sample = ""

    private static let sizes: [CGFloat] = [12, 16, 24, 36, 48, 72]
    private static let pangramRU = "Съешь же ещё этих мягких французских булок, да выпей чаю"
    private static let pangramEN = "The quick brown fox jumps over the lazy dog"

    var body: some View {
        Group {
            if let faces, faces.isEmpty {
                MediaMessage(icon: "textformat", text: L("Шрифт не прочитать"))
            } else if let faces {
                ScrollView {
                    VStack(alignment: .leading, spacing: 36) {
                        ForEach(faces) { face in faceView(face) }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let url = self.url
            faces = await Task.detached(priority: .userInitiated) { Self.load(url) }.value
        }
    }

    @ViewBuilder
    private func faceView(_ face: Face) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(face.family)
                    .font(Font(CTFontCreateCopyWithAttributes(face.font, 34, nil, nil)))
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Text(face.style).foregroundStyle(.secondary)
                    ForEach(face.details, id: \.self) { Text("·  " + $0).foregroundStyle(.tertiary) }
                }
                .font(.system(size: 12))
                HStack(spacing: 12) {
                    ForEach(face.scripts, id: \.name) { script in
                        Label(script.name, systemImage: script.supported ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(script.supported ? Color.green.opacity(0.8) : Color.red.opacity(0.8))
                    }
                }
                .font(.system(size: 11))
            }

            TextField(L("Свой текст для образца"), text: $sample)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.sizes, id: \.self) { size in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(Int(size))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .trailing)
                        Text(sample.isEmpty ? (size <= 24 ? Self.pangramRU : Self.pangramEN) : sample)
                            .font(Font(CTFontCreateCopyWithAttributes(face.font, size, nil, nil)))
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(["ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz",
                         "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ", "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
                         "0123456789 !?.,:;«»\"'()[]{}<>/\\|@#$%^&*+-=_~№"], id: \.self) { row in
                    Text(row).font(Font(CTFontCreateCopyWithAttributes(face.font, 22, nil, nil)))
                }
            }

            if !face.glyphs.isEmpty {
                Text(L("Символы (\(face.glyphs.count))"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
                    ForEach(Array(face.glyphs.enumerated()), id: \.offset) { _, glyph in
                        Text(glyph)
                            .font(Font(CTFontCreateCopyWithAttributes(face.font, 22, nil, nil)))
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Theme.tabActive).opacity(0.5)))
                            .help(String(format: "U+%04X", glyph.unicodeScalars.first?.value ?? 0))
                    }
                }
            }
        }
        .foregroundStyle(Color(nsColor: Theme.color(.plain)))
    }

    /// Шрифт не регистрируется в системе: CTFont создаётся прямо из файла
    /// и живёт, пока открыт просмотр.
    nonisolated static func load(_ url: URL) -> [Face] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return descriptors.enumerated().map { index, descriptor in
            let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
            func name(_ key: CFString) -> String? { CTFontCopyName(font, key) as String? }
            var details: [String] = []
            details.append(Localization.count(CTFontGetGlyphCount(font), "глиф", "глифа", "глифов"))
            if let version = name(kCTFontVersionNameKey) { details.append(version) }
            if let designer = name(kCTFontManufacturerNameKey) ?? name(kCTFontDesignerNameKey) { details.append(designer) }
            if let size = fileSize(url) { details.append(size) }

            let charset = CTFontCopyCharacterSet(font) as CharacterSet
            func covers(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { charset.contains($0) } }
            let scripts = [(L("Латиница"), covers("AZaz")), (L("Кириллица"), covers("АЯаяЁё")),
                           (L("Цифры"), covers("0123456789")), ("₽ € $", covers("₽€$"))]

            var glyphs: [String] = []
            // Базовая плоскость Unicode, не больше 3000 символов: иероглифические
            // шрифты на десятки тысяч знаков просмотр не тянет, и не нужно.
            for value in 0x20..<0x10000 {
                guard let scalar = Unicode.Scalar(value), charset.contains(scalar),
                      !scalar.properties.isWhitespace, scalar.properties.generalCategory != .control else { continue }
                glyphs.append(String(scalar))
                if glyphs.count >= 3000 { break }
            }
            return Face(id: index, font: font,
                        family: name(kCTFontFamilyNameKey) ?? url.deletingPathExtension().lastPathComponent,
                        style: name(kCTFontStyleNameKey) ?? "",
                        details: details, scripts: scripts, glyphs: glyphs)
        }
    }
}

// MARK: - 3D-модели

struct ModelViewer: View {
    let url: URL

    @State private var loaded: ModelScene?
    @State private var error: String?
    @State private var wireframe = false

    var body: some View {
        Group {
            if let loaded {
                SceneView3D(model: loaded, wireframe: wireframe)
                    .overlay(alignment: .bottom) {
                        InfoCapsule(items: loaded.info) {
                            MediaButton(symbol: "square.grid.3x3", help: L("Каркас"), active: wireframe) {
                                wireframe.toggle()
                            }
                        }
                    }
            } else if let error {
                MediaMessage(icon: "cube.transparent", text: error)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            let url = self.url
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ModelScene, Error> in
                Result { try ModelScene.load(url) }
            }.value
            switch result {
            case .success(let scene): loaded = scene
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

final class ModelScene: @unchecked Sendable {
    let scene: SCNScene
    let center: SCNVector3
    let radius: CGFloat
    let info: [String]

    init(scene: SCNScene, center: SCNVector3, radius: CGFloat, info: [String]) {
        self.scene = scene
        self.center = center
        self.radius = radius
        self.info = info
    }

    private var camera: SCNNode?

    /// Камера три четверти сверху, как превью ассета в Unity, со светом,
    /// привязанным к ней: модель освещена, с какой стороны ни смотри.
    func cameraNode() -> SCNNode {
        if let camera { return camera }
        let r = radius
        let settings = SCNCamera()
        settings.zNear = Double(r) * 0.01
        settings.zFar = Double(r) * 100
        settings.fieldOfView = 40
        let node = SCNNode()
        node.camera = settings
        let distance = r / tan(20 * .pi / 180) * 0.9
        let direction = SCNVector3(0.6, 0.45, 1.0)
        let length = sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
        node.position = SCNVector3(center.x + direction.x / length * distance,
                                   center.y + direction.y / length * distance,
                                   center.z + direction.z / length * distance)
        node.look(at: center)
        scene.rootNode.addChildNode(node)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 350
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 900
        key.eulerAngles = SCNVector3(-0.5, 0.4, 0)
        node.addChildNode(key)
        camera = node
        return node
    }

    enum LoadError: LocalizedError {
        case empty
        case unsupported
        var errorDescription: String? {
            switch self {
            case .empty: return L("В файле нет геометрии — только кости или анимация")
            case .unsupported: return L("Этот формат модели не прочитать")
            }
        }
    }

    static func load(_ url: URL) throws -> ModelScene {
        let ext = url.pathExtension.lowercased()
        if ext == "fbx" { return try loadFBX(url) }

        let scene: SCNScene
        if ext == "scn" || ext == "dae" {
            scene = try SCNScene(url: url, options: [.checkConsistency: false])
        } else if MDLAsset.canImportFileExtension(ext) {
            let asset = MDLAsset(url: url)
            asset.loadTextures()
            scene = SCNScene(mdlAsset: asset)
        } else {
            throw LoadError.unsupported
        }
        var triangles = 0, meshes = 0
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            meshes += 1
            for element in geometry.elements where element.primitiveType == .triangles {
                triangles += element.primitiveCount
            }
            for material in geometry.materials { material.isDoubleSided = true }
        }
        guard meshes > 0 else { throw LoadError.empty }
        let (lo, hi) = scene.rootNode.boundingBox
        return make(scene: scene, lo: lo, hi: hi, info: [
            ext.uppercased(), count(meshes, "сетка", "сетки", "сеток"),
            count(triangles, "треугольник", "треугольника", "треугольников"),
        ] + [fileSize(url)].compactMap { $0 })
    }

    private static func loadFBX(_ url: URL) throws -> ModelScene {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let fbx = try FBX.scene(from: data)
        guard !fbx.meshes.isEmpty else {
            var parts = [L("В файле нет геометрии")]
            if fbx.bones > 0 { parts.append(count(fbx.bones, "кость", "кости", "костей")) }
            if fbx.animations > 0 { parts.append(count(fbx.animations, "анимация", "анимации", "анимаций")) }
            throw NSError(domain: "Pilot", code: 1, userInfo: [NSLocalizedDescriptionKey: parts.joined(separator: " — ")])
        }

        let palette: [NSColor] = [
            NSColor(srgbRed: 0.80, green: 0.82, blue: 0.88, alpha: 1),
            NSColor(srgbRed: 0.54, green: 0.68, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.65, green: 0.85, blue: 0.58, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.66, blue: 0.50, alpha: 1),
            NSColor(srgbRed: 0.78, green: 0.63, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.93, green: 0.83, blue: 0.62, alpha: 1),
        ]
        let materials: [SCNMaterial] = fbx.materials.enumerated().map { index, source in
            let material = SCNMaterial()
            material.name = source.name
            material.lightingModel = .blinn
            // Цвет — как в файле; без цвета слоты различаются палитрой.
            if let c = source.color {
                material.diffuse.contents = NSColor(srgbRed: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1)
            } else {
                material.diffuse.contents = palette[index % palette.count]
            }
            material.isDoubleSided = true
            return material
        }
        let fallback = SCNMaterial()
        fallback.diffuse.contents = palette[0]
        fallback.lightingModel = .blinn
        fallback.isDoubleSided = true

        let scene = SCNScene()
        for mesh in fbx.meshes {
            let count = mesh.positions.count / 3
            let vertices = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
            let normals = mesh.normals.withUnsafeBufferPointer { Data(buffer: $0) }
            let sources = [
                SCNGeometrySource(data: vertices, semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12),
                SCNGeometrySource(data: normals, semantic: .normal, vectorCount: count, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12),
            ]
            let elements = mesh.parts.map { part in
                SCNGeometryElement(data: part.indices.withUnsafeBufferPointer { Data(buffer: $0) },
                                   primitiveType: .triangles, primitiveCount: part.indices.count / 3, bytesPerIndex: 4)
            }
            let geometry = SCNGeometry(sources: sources, elements: elements)
            geometry.materials = mesh.parts.map { part in part.material.map { materials[$0] } ?? fallback }
            let node = SCNNode(geometry: geometry)
            node.name = mesh.name
            scene.rootNode.addChildNode(node)
        }

        let lo = SCNVector3(CGFloat(fbx.boundsMin.0), CGFloat(fbx.boundsMin.1), CGFloat(fbx.boundsMin.2))
        let hi = SCNVector3(CGFloat(fbx.boundsMax.0), CGFloat(fbx.boundsMax.1), CGFloat(fbx.boundsMax.2))
        let meters = fbx.metersPerUnit
        func dimension(_ v: Float) -> String {
            let m = Double(v) * meters
            return m >= 1 ? String(format: "%.2f", m) : String(format: "%.3f", m)
        }
        let size = "\(dimension(fbx.boundsMax.0 - fbx.boundsMin.0)) × \(dimension(fbx.boundsMax.1 - fbx.boundsMin.1)) × \(dimension(fbx.boundsMax.2 - fbx.boundsMin.2))"
        var info = [
            count(fbx.meshes.count, "сетка", "сетки", "сеток"),
            count(fbx.triangles, "треугольник", "треугольника", "треугольников"),
            count(fbx.controlPoints, "вершина", "вершины", "вершин"),
            L("\(size) м"),
        ]
        if !fbx.materials.isEmpty { info.append(count(fbx.materials.count, "материал", "материала", "материалов")) }
        if fbx.bones > 0 { info.append(count(fbx.bones, "кость", "кости", "костей")) }
        if fbx.animations > 0 { info.append(count(fbx.animations, "анимация", "анимации", "анимаций")) }
        return make(scene: scene, lo: lo, hi: hi, info: info)
    }

    private static func make(scene: SCNScene, lo: SCNVector3, hi: SCNVector3, info: [String]) -> ModelScene {
        let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let dx = hi.x - lo.x, dy = hi.y - lo.y, dz = hi.z - lo.z
        let radius = max(sqrt(dx * dx + dy * dy + dz * dz) / 2, 0.001)
        return ModelScene(scene: scene, center: center, radius: radius, info: info)
    }

    private static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        Theme.count(n, one, few, many)
    }
}

struct SceneView3D: NSViewRepresentable {
    let model: ModelScene
    let wireframe: Bool

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = model.scene
        view.backgroundColor = Theme.editorBackground
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.pointOfView = model.cameraNode()
        view.defaultCameraController.target = model.center
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        view.debugOptions = wireframe ? [.renderAsWireframe] : []
    }
}
