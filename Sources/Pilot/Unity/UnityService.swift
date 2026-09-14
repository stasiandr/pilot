import SwiftUI
import AppKit

/// Unity-слой воркспейса: распознаёт проект, держит индекс GUID,
/// переходит по ссылкам сериализованных файлов и ищет использования ассетов.
///
/// Как и языковой сервер, он никогда не блокирует интерфейс: индекс GUID
/// строится фоном, и пока его нет, всё остальное работает как обычно —
/// просто у скриптов в сценах ещё нет имён.
@MainActor
final class UnityService: ObservableObject {

    @Published private(set) var project: UnityProjectInfo?
    @Published private(set) var assets: UnityAssetIndex?
    @Published private(set) var isIndexingAssets = false
    /// Растёт, когда меняется то, от чего зависит раскраска ссылок.
    @Published private(set) var decorationsVersion = 0

    /// Индекс ассетов готов — пора заново разобрать открытый файл.
    var onAssetsReady: (() -> Void)?

    /// Разобранные скрипты — для типов полей в инспекторе.
    private var scriptInfos: [String: UnityCSharp.ScriptInfo] = [:]

    private let generation = AtomicCounter()
    private let queue = DispatchQueue(label: "pilot.unity", qos: .utility)

    var isActive: Bool { project != nil }

    /// Снимок для фонового разбора файла.
    var context: UnityContext? {
        project.map { UnityContext(project: $0, assets: assets) }
    }

    // MARK: - Жизненный цикл

    /// Только распознаёт проект — это мгновенно, и файл уже можно разобрать
    /// как Unity-файл. Индекс GUID — отдельно, `indexAssets()`: Pilot,
    /// открытый ради файла, строит его после того, как файл показан.
    func workspaceChanged(to root: URL?) {
        _ = generation.bump()
        assets = nil
        scriptInfos = [:]
        isIndexingAssets = false
        decorationsVersion += 1
        project = root.flatMap(UnityProjectInfo.find(inWorkspace:))
    }

    func indexAssets() {
        guard let project, assets == nil, !isIndexingAssets else { return }
        let current = generation.bump()
        isIndexingAssets = true
        let counter = generation
        let started = Date()
        queue.async { [weak self] in
            let index = UnityAssetIndex.build(root: project.root,
                                              shouldStop: { !counter.isCurrent(current) })
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Task { @MainActor in
                guard let self, counter.isCurrent(current) else { return }
                NSLog("[unity] индекс GUID: %d ассетов за %d мс", index.count, ms)
                self.assets = index
                self.isIndexingAssets = false
                self.decorationsVersion += 1
                self.onAssetsReady?()
            }
        }
    }

    // MARK: - Где что лежит

    func url(forAsset relPath: String) -> URL? {
        project?.root.appendingPathComponent(relPath)
    }

    func relativePath(of url: URL) -> String? {
        guard let root = project?.root, url.path.hasPrefix(root.path + "/") else { return nil }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    /// Файлы, где ссылки на ассеты — это GUID и fileID.
    func isReferenceFile(_ document: LoadedDocument) -> Bool {
        guard isActive else { return false }
        if UnitySemantics.isSerializedAsset(document.model.spec) { return true }
        return UnityUsages.isSearchable(document.url.lastPathComponent)
    }

    // MARK: - Переход по ссылке (⌘B)

    enum Jump {
        /// Под курсором не ссылка Unity — пусть работает обычный переход.
        case notReference
        case target(NavTarget)
        /// Ссылка есть, но вести некуда — объясняем почему.
        case unavailable(String)
    }

    func definition(in document: LoadedDocument, at offset: Int) async -> Jump {
        guard isReferenceFile(document) else { return .notReference }
        let model = document.model
        let line = model.line(containing: min(offset, max(0, model.units.count - 1)))
        guard let found = UnityYAMLFile.reference(in: model.units, line: model.lineRange(line),
                                                  at: offset) else { return .notReference }

        switch found.reference {
        case .local(let fileID):
            // Текст могли править после разбора — тогда разбираем заново:
            // позиции объектов сдвинулись.
            let file = document.isSemanticsFresh ? document.unityFile : UnityYAMLFile.parse(model.units)
            guard let file, let object = file.object(fileID) else {
                return .unavailable("Объекта &\(fileID) в этом файле нет")
            }
            let range = object.typeNameRange
            return .target(NavTarget(url: document.url, range: LSPRange(
                start: model.position(at: range.location),
                end: model.position(at: NSMaxRange(range)))))

        case .asset(let guid, let fileID):
            return await target(forAsset: guid, fileID: fileID)
        }
    }

    /// Куда именно вести внутри целевого файла: к объекту `&fileID` в сцене
    /// или префабе, к `class Имя` в скрипте. `nil` — просто открыть.
    nonisolated private static func landing(in url: URL, fileID: Int64?,
                                            className: String?) -> LSPRange? {
        let ext = url.pathExtension.lowercased()
        if ext == "cs", let className,
           let text = try? String(contentsOf: url, encoding: .utf8),
           let at = UnityCSharp.classDeclaration(named: className, in: text) {
            return LSPRange(start: LSPPosition(line: at.line, character: at.column),
                            end: LSPPosition(line: at.line, character: at.column + className.utf16.count))
        }
        guard ext == "prefab" || ext == "unity", let fileID, fileID != 0,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { bytes -> LSPRange? in
            guard let header = UnityYAMLFile.anchorLine(fileID: fileID, in: bytes) else { return nil }
            // Строка после заголовка — имя типа: `GameObject:`, `Transform:`.
            let typeLine = header + 1
            var line = 0, i = 0
            while i < bytes.count, line < typeLine {
                if bytes[i] == 0x0A { line += 1 }
                i += 1
            }
            var length = 0
            while i + length < bytes.count, bytes[i + length] != 0x3A, bytes[i + length] != 0x0A { length += 1 }
            return LSPRange(start: LSPPosition(line: typeLine, character: 0),
                            end: LSPPosition(line: typeLine, character: length))
        }
    }

    /// Переход к ассету по GUID — из инспектора. Скрипт открывается на
    /// объявлении класса, префаб — на объекте `fileID`.
    func target(forAsset guid: UnityGUID, fileID: Int64?) async -> Jump {
        if guid.isBuiltin { return .unavailable("Встроенный ресурс Unity — в проекте его нет") }
        guard let assets else { return .unavailable("Индекс ассетов ещё строится…") }
        guard let path = assets.path(for: guid), let url = url(forAsset: path) else {
            return .unavailable("Ассет \(guid) не найден — битая ссылка")
        }
        let range = await Task.detached(priority: .userInitiated) {
            Self.landing(in: url, fileID: fileID, className: assets.displayName(for: guid))
        }.value
        return .target(NavTarget(url: url, range: range))
    }

    // MARK: - Скрипты для инспектора

    /// Типы полей и enum'ы скрипта. Файлы маленькие, читаем синхронно
    /// и один раз за сессию проекта.
    func scriptInfo(for guid: UnityGUID?) -> UnityCSharp.ScriptInfo? {
        guard let guid, let path = assets?.path(for: guid), path.hasSuffix(".cs") else { return nil }
        return scriptInfo(atPath: path)
    }

    private func scriptInfo(atPath path: String) -> UnityCSharp.ScriptInfo? {
        if let cached = scriptInfos[path] { return cached }
        guard let url = url(forAsset: path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let info = UnityCSharp.scriptInfo(from: text)
        scriptInfos[path] = info
        return info
    }

    /// Значения enum'а: сначала в самом скрипте, потом в файле `Имя.cs`.
    func enumMembers(_ type: String, script: UnityGUID?) -> [UnityCSharp.EnumMember]? {
        let name = type.split(separator: ".").last.map(String.init) ?? type
        if let members = scriptInfo(for: script)?.enums[name] { return members }
        guard let path = assets?.scriptPath(named: name) else { return nil }
        return scriptInfo(atPath: path)?.enums[name]
    }

    // MARK: - Где используется ассет (⇧⌘R)

    /// Ассет, о котором спрашивают: для открытого `.meta` — сам ассет.
    func assetPath(for url: URL) -> String? {
        guard var rel = relativePath(of: url) else { return nil }
        if rel.hasSuffix(".meta") { rel.removeLast(5) }
        return rel
    }

    /// `relPath` — от корня Unity-проекта, `paths` — индекс воркспейса как есть;
    /// пути в результате — от корня Unity-проекта.
    func usages(ofAsset relPath: String, among paths: [String]) async -> Result<[UnityUsages.Hit], UsageError> {
        guard let project else { return .failure(.notUnity) }
        guard let assets else { return .failure(.indexing) }
        guard let guid = assets.guid(forAsset: relPath) else { return .failure(.noMeta) }
        let root = project.root
        let paths = paths.compactMap(project.projectPath(fromWorkspace:))
        let hits = await Task.detached(priority: .userInitiated) {
            UnityUsages.find(guid: guid, root: root, paths: paths,
                             resolve: { assets.displayName(for: $0) })
        }.value
        return .success(hits)
    }

    enum UsageError: Error {
        case notUnity, indexing, noMeta

        var message: String {
            switch self {
            case .notUnity: return "Это не Unity-проект"
            case .indexing: return "Индекс ассетов ещё строится — попробуйте через секунду"
            case .noMeta:   return "У файла нет .meta — Unity о нём не знает"
            }
        }
    }

    // MARK: - Раскраска ссылок

    /// Украшения для видимой части открытого файла. Замыкание — снимок:
    /// индекс поменяется, `decorationsVersion` вырастет, и вьюха возьмёт новое.
    func decorator() -> CodeDecorator? {
        guard isActive else { return nil }
        let assets = self.assets
        let complete = assets != nil && !isIndexingAssets

        return { document, range in
            var result: [TextDecoration] = []
            let visible = range.location..<NSMaxRange(range)

            if document.model.spec?.name == Languages.csharp.name {
                for item in document.outline where visible.contains(item.range.location) {
                    switch item.kind {
                    case .unityMessage:
                        result.append(TextDecoration(range: item.range, color: Theme.unityEvent,
                                                     toolTip: "Сообщение Unity — вызывает движок"))
                    case .serializedField:
                        result.append(TextDecoration(range: item.range,
                                                     toolTip: "Сериализуется — видно в инспекторе"))
                    default:
                        break
                    }
                }
                return result
            }

            let units = document.model.units
            for (guidRange, guid) in UnityYAMLFile.guidRanges(in: units, visible) {
                if guid.isBuiltin {
                    result.append(TextDecoration(range: guidRange, toolTip: "Встроенный ресурс Unity"))
                } else if let path = assets?.path(for: guid) {
                    result.append(TextDecoration(
                        range: guidRange, color: Theme.assetLink, underline: true,
                        toolTip: UnityProjectInfo.prettyPath(path) + "\n⌘B или ⌘+клик — открыть"))
                } else if complete {
                    result.append(TextDecoration(
                        range: guidRange, color: Theme.brokenLink,
                        toolTip: "Ассета с таким GUID в проекте нет — битая ссылка (Missing)"))
                }
            }

            if let file = document.unityFile, document.isSemanticsFresh {
                let resolve: (UnityGUID) -> String? = { assets?.displayName(for: $0) }
                for (refRange, fileID) in UnityYAMLFile.localReferences(in: units, visible) {
                    guard let index = file.index(ofFileID: fileID) else { continue }
                    let object = file.objects[index]
                    let what = object.stripped
                        ? "\(object.typeName) из вложенного префаба"
                        : file.describe(objectAt: index, resolve: resolve)
                    result.append(TextDecoration(range: refRange, underline: true,
                                                 toolTip: "→ \(what)\n⌘B — перейти"))
                }
            }
            return result
        }
    }
}
