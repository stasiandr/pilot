import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO

/// Что изменилось в картинке относительно другой версии: доля изменённых
/// пикселей, их рамка и маска — полупрозрачный красный там, где пиксель
/// другой, пусто там, где тот же. По маске поверх версии сразу видно,
/// что сделала сторона: перевернула всё, перекрасила иконку или
/// поправила угол.
struct ImageDiff: Sendable {
    let width: Int
    let height: Int
    /// Сколько пикселей отличается, 0…1.
    let changed: Double
    /// Рамка изменённого, в пикселях, от левого верхнего угла; nil — ничего.
    let bounds: CGRect?
    let mask: CGImage?

    /// Разница меньше этого на всех каналах — не изменение (сжатие, дизеринг).
    static let tolerance = 8

    /// nil — не картинка или размеры разные (это видно и так — подписью).
    static func compare(_ a: URL, _ b: URL) -> ImageDiff? {
        guard let first = load(a), let second = load(b),
              first.width == second.width, first.height == second.height else { return nil }
        return compare(first, second)
    }

    static func size(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Обе картинки — в RGBA 8 бит одного размера, и попиксельно.
    static func compare(_ a: CGImage, _ b: CGImage) -> ImageDiff? {
        let width = a.width, height = a.height
        guard width == b.width, height == b.height, width > 0, height > 0 else { return nil }
        guard let pa = rgba(a), let pb = rgba(b) else { return nil }
        var mask = [UInt8](repeating: 0, count: width * height * 4)
        var count = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        let tolerance = Int32(Self.tolerance)
        pa.withUnsafeBufferPointer { x in
            pb.withUnsafeBufferPointer { y in
                for row in 0..<height {
                    for column in 0..<width {
                        let i = (row * width + column) * 4
                        let differs = abs(Int32(x[i]) - Int32(y[i])) > tolerance
                            || abs(Int32(x[i + 1]) - Int32(y[i + 1])) > tolerance
                            || abs(Int32(x[i + 2]) - Int32(y[i + 2])) > tolerance
                            || abs(Int32(x[i + 3]) - Int32(y[i + 3])) > tolerance
                        guard differs else { continue }
                        count += 1
                        // Предумноженный красный на 55%.
                        mask[i] = 140; mask[i + 1] = 0; mask[i + 2] = 0; mask[i + 3] = 140
                        minX = min(minX, column); maxX = max(maxX, column)
                        minY = min(minY, row); maxY = max(maxY, row)
                    }
                }
            }
        }
        let image: CGImage? = count == 0 ? nil : mask.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return ImageDiff(width: width, height: height, changed: Double(count) / Double(width * height),
                         bounds: count == 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
                         mask: image)
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Подпись: «изменено 12% · область 180×120» или «без изменений».
    var summary: String {
        guard let bounds else { return L("Пиксели те же") }
        let percent = changed * 100
        let share = percent < 0.1 ? "<0.1" : percent < 10 ? String(format: "%.1f", percent) : String(format: "%.0f", percent)
        return L("Изменено \(share)% пикселей · область \(Int(bounds.width))×\(Int(bounds.height))")
    }
}
#endif
