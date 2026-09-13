import Foundation

/// GUID ассета Unity — 32 шестнадцатеричных символа из его `.meta`.
///
/// Хранится двумя словами, а не строкой: словарь на десятки тысяч ассетов
/// не держит по строке на ключ, а сравнение — две инструкции.
struct UnityGUID: Hashable, Sendable, CustomStringConvertible {
    let hi: UInt64
    let lo: UInt64

    init(hi: UInt64, lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }

    init?(_ string: String) {
        let units = Array(string.utf16)
        guard units.count == 32, let guid = UnityGUID.parse(units, at: 0) else { return nil }
        self = guid
    }

    /// Ровно 32 hex-символа начиная с `start`, и следом не hex-символ:
    /// иначе это кусок чего-то длиннее, а не GUID.
    static func parse<C: RandomAccessCollection>(_ c: C, at start: Int) -> UnityGUID?
    where C.Element: FixedWidthInteger, C.Index == Int {
        guard start >= c.startIndex, start + 32 <= c.endIndex else { return nil }
        if start + 32 < c.endIndex, hexValue(UInt32(truncatingIfNeeded: c[start + 32])) != nil { return nil }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for k in 0..<32 {
            guard let v = hexValue(UInt32(truncatingIfNeeded: c[start + k])) else { return nil }
            if k < 16 { hi = (hi << 4) | UInt64(v) } else { lo = (lo << 4) | UInt64(v) }
        }
        return UnityGUID(hi: hi, lo: lo)
    }

    @inline(__always)
    static func hexValue(_ c: UInt32) -> UInt8? {
        switch c {
        case 0x30...0x39: return UInt8(c - 0x30)
        case 0x61...0x66: return UInt8(c - 0x61 + 10)
        case 0x41...0x46: return UInt8(c - 0x41 + 10)
        default: return nil
        }
    }

    var description: String { String(format: "%016llx%016llx", hi, lo) }

    /// ASCII-байты GUID в нижнем регистре — так Unity пишет их в файлы.
    var asciiBytes: [UInt8] { Array(description.utf8) }

    /// Встроенные ресурсы Unity (`0000000000000000e000000000000000` и
    /// родственники) и пустая ссылка. В проекте их нет и быть не должно,
    /// поэтому битыми ссылками они не считаются.
    var isBuiltin: Bool { hi == 0 }
}

/// Что известно про Unity-проект без самого Unity.
struct UnityProjectInfo: Sendable, Equatable {
    let root: URL
    /// `6000.3.14f1` — из `ProjectSettings/ProjectVersion.txt`.
    let editorVersion: String?
    /// Где Unity-проект внутри открытой папки: `""` — это она сама,
    /// `"Game"` — если открыт репозиторий, а проект лежит в `Game/`.
    var workspacePrefix: String = ""

    /// Unity-проект в корне воркспейса или в одной из его папок первого
    /// уровня — так обычно и выглядит репозиторий игры. Если проектов
    /// несколько, какой из них главный — не угадать, и Unity-режим не включается.
    static func find(inWorkspace root: URL) -> UnityProjectInfo? {
        if let project = detect(root: root) { return project }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return nil }
        let found = children.compactMap { child -> UnityProjectInfo? in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  var project = detect(root: child) else { return nil }
            project.workspacePrefix = child.lastPathComponent
            return project
        }
        return found.count == 1 ? found[0] : nil
    }

    /// Unity-проект — это `Assets/` плюс `ProjectSettings/ProjectVersion.txt`.
    /// Один только `Assets/` бывает где угодно.
    static func detect(root: URL) -> UnityProjectInfo? {
        let fm = FileManager.default
        let versionFile = root.appendingPathComponent("ProjectSettings/ProjectVersion.txt")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: versionFile.path),
              fm.fileExists(atPath: root.appendingPathComponent("Assets").path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        let text = (try? String(contentsOf: versionFile, encoding: .utf8)) ?? ""
        return UnityProjectInfo(root: root, editorVersion: parseEditorVersion(text))
    }

    static func parseEditorVersion(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("m_EditorVersion:") {
            let value = line.dropFirst("m_EditorVersion:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Папки в корне, которые Unity генерирует сам. Обычно их прячет
    /// `.gitignore`, но без него одна `Library/` — это сотни тысяч файлов.
    static let generatedRootFolders: Set<String> = [
        "Library", "Temp", "Logs", "obj", "UserSettings", "MemoryCaptures", "Recordings",
    ]

    /// Что не попадает в индекс воркспейса с Unity-проектом.
    /// `relPath` — от корня воркспейса.
    ///
    /// `.meta` — служебные спутники каждого ассета: в поиске и в дереве это
    /// половина всех файлов и чистый шум. Их содержимое нужно только ради
    /// GUID, а для этого есть свой индекс (`UnityAssetIndex`).
    func excludedFromIndex(relPath: String, isDirectory: Bool) -> Bool {
        guard isDirectory else { return relPath.hasSuffix(".meta") }
        guard let local = projectPath(fromWorkspace: relPath) else { return false }
        return !local.contains("/") && Self.generatedRootFolders.contains(local)
    }

    /// Путь от корня воркспейса → путь от корня Unity-проекта.
    /// `nil` — файл лежит вне проекта.
    func projectPath(fromWorkspace relPath: String) -> String? {
        if workspacePrefix.isEmpty { return relPath }
        guard relPath.hasPrefix(workspacePrefix + "/") else { return nil }
        return String(relPath.dropFirst(workspacePrefix.count + 1))
    }

    /// `Library/PackageCache/com.unity.foo@1a2b3c/Runtime/X.cs` → `com.unity.foo/Runtime/X.cs`.
    /// Хэш версии в пути только мешает читать.
    static func prettyPath(_ relPath: String) -> String {
        let prefix = "Library/PackageCache/"
        guard relPath.hasPrefix(prefix) else { return relPath }
        let rest = relPath.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return String(rest) }
        var package = rest[..<slash]
        if let at = package.firstIndex(of: "@") { package = package[..<at] }
        return String(package) + String(rest[slash...])
    }
}

/// Что нужно знать о проекте при разборе открытого файла. Снимок:
/// индекс ассетов может дособраться позже — тогда файл разбирается заново.
struct UnityContext: Sendable {
    let project: UnityProjectInfo
    let assets: UnityAssetIndex?

    func assetName(_ guid: UnityGUID) -> String? { assets?.displayName(for: guid) }
}

/// Unity-смысл открытого файла.
enum UnitySemantics {

    struct Result {
        var outline: [OutlineItem]
        /// Разобранный сериализованный файл — для переходов по ссылкам.
        var serialized: UnityYAMLFile?
        /// Иерархия сцены или префаба — ветка под файлом в дереве проекта.
        var hierarchy: UnityHierarchy? = nil
    }

    static func isSerializedAsset(_ spec: LanguageSpec?) -> Bool {
        spec?.name == Languages.unityYAML.name
    }

    /// `nil` — Unity здесь ни при чём, структура остаётся лексической.
    static func analyze(model: SyntaxModel, lexicalOutline: [OutlineItem],
                        context: UnityContext?) -> Result? {
        if isSerializedAsset(model.spec) {
            // Формат узнаётся по содержимому, а не по расширению: `.asset`
            // бывает и бинарным, а в `.meta` объектов нет вовсе.
            guard let file = UnityYAMLFile.parse(model.units) else { return nil }
            let resolve: UnityYAMLFile.Resolver = { context?.assetName($0) }
            return Result(outline: file.outline(resolve: resolve), serialized: file,
                          hierarchy: UnityHierarchy.build(file: file, resolve: resolve))
        }
        if context != nil, model.spec?.name == Languages.csharp.name {
            return Result(outline: UnityCSharp.annotate(lexicalOutline, units: model.units),
                          serialized: nil)
        }
        return nil
    }

    /// Иконки для дерева и палитры.
    static func icon(forExtension ext: String) -> String? {
        switch ext {
        case "unity":                                   return "mountain.2"
        case "prefab":                                  return "cube"
        case "mat", "physicmaterial", "physicsmaterial2d": return "circle.lefthalf.filled"
        case "shader", "hlsl", "cginc", "compute", "shadergraph", "shadersubgraph", "glsl":
            return "wand.and.stars"
        case "anim":                                    return "figure.run"
        case "controller", "overridecontroller", "playable": return "point.3.connected.trianglepath.dotted"
        case "asset", "preset", "lighting":             return "doc.badge.gearshape"
        case "asmdef", "asmref":                        return "books.vertical"
        case "fbx", "obj", "blend", "dae", "3ds", "max": return "cube.transparent"
        case "wav", "mp3", "ogg", "aif", "aiff", "flac": return "waveform"
        case "tga", "psd", "exr", "hdr", "tif", "tiff", "bmp": return "photo"
        case "uxml", "uss", "tss":                      return "rectangle.3.group"
        case "inputactions":                            return "gamecontroller"
        case "mixer":                                   return "slider.vertical.3"
        case "rendertexture", "cubemap":                return "photo.on.rectangle"
        case "ttf", "otf", "fontsettings":              return "textformat"
        case "vfx":                                     return "sparkles"
        default:                                        return nil
        }
    }
}
