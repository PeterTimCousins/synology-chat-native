import AppKit
import ImageIO

enum NativeImagePreview {
    /// Decode a single bounded frame instead of expanding the full-resolution image.
    static func decode(_ data: Data, maximumPixelSize: Int = 640) -> NSImage? {
        guard maximumPixelSize > 0, maximumPixelSize <= 4096 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
