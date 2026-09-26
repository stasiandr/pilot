import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Как APK, JAR или DEX выглядит проектом: какие файлы считаются архивом
/// и по каким путям внутри «папки» лежат декомпилированные классы и ресурсы.
///
/// Корень проекта — сам файл архива, а пути внутри — от него, как у папки:
/// `/x/app.apk/sources/com/foo/Bar.java`. Всё, что считает путь относительно
/// корня (дерево, ⌘P, jump bar), работает с такими адресами без изменений.
enum ArchiveLayout {
    static let extensions: Set<String> = ["apk", "apks", "apkm", "xapk", "aab", "aar", "jar", "dex"]

    static let sourcesFolder = "sources"
    static let resourcesFolder = "resources"

    #if canImport(UniformTypeIdentifiers)
    /// Что предлагает панель «Открыть»: папки и архивы.
    static var openPanelTypes: [UTType] {
        [.folder] + extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }
    #endif

    static func isArchive(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Архив на диске — файл, а не папка, названная `lib.jar`.
    static func isArchiveFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return isArchive(url) && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// `com.foo.Bar` → `sources/com/foo/Bar.java`; класс без пакета — прямо в `sources`.
    static func sourcePath(className: String) -> String {
        "\(sourcesFolder)/\(className.split(separator: ".").joined(separator: "/")).java"
    }

    /// `AndroidManifest.xml`, `res/layout/main.xml` и файлы, разобранные из resources.arsc.
    static func resourcePath(_ name: String) -> String {
        "\(resourcesFolder)/\(name)"
    }

    /// Имя класса по короткому имени и пакету — для ⇧⇧.
    static func split(className: String) -> (name: String, package: String?) {
        guard let dot = className.lastIndex(of: ".") else { return (className, nil) }
        return (String(className[className.index(after: dot)...]), String(className[..<dot]))
    }

    /// Ключевое слово для ⇧⇧ по виду класса из движка: c, i, e, a.
    static func keyword(kind: String) -> String {
        switch kind {
        case "i": return "interface"
        case "e": return "enum"
        case "a": return "annotation"
        default:  return "class"
        }
    }
}
