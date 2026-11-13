import AppKit
import ImageIO
import SwiftUI

struct NativeViewerImage {
    let image:NSImage
    let frameCount:Int
    static let maximumPixels = 64_000_000
    static let maximumFrames = 240
    /// The explicit viewer has a larger animation and resolution budget than inline thumbnails.
    static func decode(_ data:Data,original:Bool)->Self? {
        guard data.count <= 32*1024*1024,let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w = properties[kCGImagePropertyPixelWidth] as? Int,let h = properties[kCGImagePropertyPixelHeight] as? Int,w > 0,h > 0,w <= 32768,h <= 32768 else {return nil}
        let count = CGImageSourceGetCount(source),gif = (CGImageSourceGetType(source) as String?) == "com.compuserve.gif"
        if gif && count > 1 {
            guard count <= maximumFrames else {return nil}
            var pixels:Int64 = 0
            for index in 0..<count {
                guard let p = CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any],let width = p[kCGImagePropertyPixelWidth] as? Int,let height = p[kCGImagePropertyPixelHeight] as? Int,width > 0,height > 0,width <= 32768,height <= 32768 else {return nil}
                pixels += Int64(width)*Int64(height);guard pixels <= maximumPixels else {return nil}
            }
            guard let image = NSImage(data:data),let rep = image.representations.compactMap({$0 as? NSBitmapImageRep}).first,(rep.value(forProperty:.frameCount) as? Int ?? 0) == count else {return nil}
            image.size = NSSize(width:w,height:h);return .init(image:image,frameCount:count)
        }
        if !original {return NativeImagePreview.decode(data,maximumPixelSize:4096).map {.init(image:$0,frameCount:1)}}
        guard Int64(w)*Int64(h) <= maximumPixels,let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(w,h),kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {return nil}
        return .init(image:NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height)),frameCount:1)
    }
}

struct NativeImageRasterView:NSViewRepresentable {
    let image:NSImage
    let playing:Bool
    let label:String
    func makeNSView(context:Context)->NSImageView {let view = NSImageView();view.imageScaling = .scaleProportionallyUpOrDown;view.animates = false;return view}
    func updateNSView(_ view:NSImageView,context:Context) {
        if view.image !== image {view.animates = false;view.image = image}
        view.setAccessibilityLabel(label);view.animates = playing
    }
    static func dismantleNSView(_ view:NSImageView,coordinator:()) {view.animates = false;view.image = nil}
}
