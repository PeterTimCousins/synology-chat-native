import AppKit
import ImageIO
import SwiftUI

/// Inline animation has a smaller budget than the explicit original-image viewer.
/// Oversized animations still get a bounded static thumbnail and remain openable.
enum NativeInlineImagePreview {
    static let maximumEncodedBytes = 2 * 1024 * 1024
    static let maximumFrames = 60
    static let maximumDimension = 640
    static let maximumAnimationPixels = 4_000_000

    static func decode(_ data: Data) -> NSImage? {
        guard data.count <= maximumEncodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif" else {
            return NativeImagePreview.decode(data)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= maximumFrames else { return NativeImagePreview.decode(data) }
        var width = 0, height = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= maximumDimension, h <= maximumDimension else {
                return NativeImagePreview.decode(data)
            }
            width = max(width,w); height = max(height,h)
        }
        // Charge every frame at the full canvas size, including GIF subframes.
        guard width * height * count <= maximumAnimationPixels,
              let image = NSImage(data:data), frameCount(image) == count,
              let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              bitmap.pixelsWide <= maximumDimension, bitmap.pixelsHigh <= maximumDimension,
              bitmap.pixelsWide * bitmap.pixelsHigh * count <= maximumAnimationPixels else {
            return NativeImagePreview.decode(data)
        }
        image.size = NSSize(width:bitmap.pixelsWide,height:bitmap.pixelsHigh)
        return image
    }

    static func frameCount(_ image: NSImage) -> Int {
        max(1,image.representations.compactMap { $0 as? NSBitmapImageRep }.first?.value(forProperty:.frameCount) as? Int ?? 1)
    }

    static func memoryCost(_ image: NSImage, encodedBytes: Int) -> Int {
        let frames = frameCount(image)
        return Int(image.size.width * image.size.height * 4) * frames + (frames > 1 ? max(0,encodedBytes) : 0)
    }
}

/// The containing SwiftUI button owns clicks; this image must not swallow them.
final class NativeInlineImageRaster: NSImageView {
    // NSImageView's image-sized intrinsic minimum otherwise overflows small tiles.
    override var intrinsicContentSize: NSSize { .zero }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum NativeInlineImageLayout {
    static func fit(_ imageSize: CGSize, proposal: ProposedViewSize) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? imageSize.width
        let height = proposal.height.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? imageSize.height
        let scale = min(width / max(1,imageSize.width),height / max(1,imageSize.height))
        return CGSize(width:imageSize.width * scale,height:imageSize.height * scale)
    }
}

private struct NativeInlineRasterHost: NSViewRepresentable {
    let image: NSImage
    let playing: Bool
    let label: String
    func makeNSView(context: Context) -> NativeInlineImageRaster {
        let view = NativeInlineImageRaster()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = false
        return view
    }
    func updateNSView(_ view: NativeInlineImageRaster, context: Context) {
        if view.image !== image { view.animates = false; view.image = image }
        view.setAccessibilityLabel(label)
        view.animates = playing
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeInlineImageRaster, context: Context) -> CGSize? {
        NativeInlineImageLayout.fit(image.size,proposal:proposal)
    }
    static func dismantleNSView(_ view: NativeInlineImageRaster, coordinator: ()) {
        view.animates = false; view.image = nil
    }
}

struct NativeInlineImageView: View {
    let image: NSImage
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var applicationActive = false
    var body: some View {
        NativeInlineRasterHost(image:image,playing:visible && applicationActive && !reduceMotion && NativeInlineImagePreview.frameCount(image) > 1,label:label)
            .aspectRatio(image.size.width / max(1,image.size.height),contentMode:.fit)
            .allowsHitTesting(false)
            .onAppear { visible = true; applicationActive = NSApp.isActive && !NSApp.isHidden }
            .onDisappear { visible = false }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in applicationActive = !NSApp.isHidden }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didUnhideNotification)) { _ in applicationActive = NSApp.isActive }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didResignActiveNotification)) { _ in applicationActive = false }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didHideNotification)) { _ in applicationActive = false }
    }
}
