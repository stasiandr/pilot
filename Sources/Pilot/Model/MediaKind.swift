import Foundation

/// Файл, который показывается не текстом: картинка, модель, шрифт, PDF.
/// Узнаётся по расширению — открывать такой файл как текст бессмысленно,
/// даже если он случайно без нулевых байтов (SVG, ASCII FBX).
enum MediaKind: String, Sendable, Equatable {
    case image, model, font, pdf

    init?(filename: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if Self.imageExtensions.contains(ext) { self = .image }
        else if Self.modelExtensions.contains(ext) { self = .model }
        else if Self.fontExtensions.contains(ext) { self = .font }
        else if ext == "pdf" { self = .pdf }
        else { return nil }
    }

    /// Всё, что читает ImageIO: вместе с обычными форматами — текстуры
    /// Unity (`tga`, `psd`, `exr`, `hdr`, `dds`, `ktx`). SVG NSImage
    /// рисует сам, начиная с macOS 14.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "tif", "tiff", "bmp", "ico",
        "icns", "cur", "psd", "tga", "exr", "hdr", "dds", "ktx", "ktx2", "astc", "pvr", "jp2",
        "sgi", "pbm", "svg",
    ]

    /// FBX разбирает сам Pilot (см. FBX), остальное — ModelIO и SceneKit.
    static let modelExtensions: Set<String> = [
        "fbx", "obj", "dae", "usd", "usda", "usdc", "usdz", "stl", "ply", "abc", "scn",
    ]

    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont", "woff", "woff2"]

    /// Подпись в статус-строке вместо имени языка.
    var title: String {
        switch self {
        case .image: return L("Изображение")
        case .model: return L("3D-модель")
        case .font:  return L("Шрифт")
        case .pdf:   return "PDF"
        }
    }
}
