import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decode once with orientation applied. Crop coordinates are normalized from the top-left.
enum NativeProfilePhoto {
    static let outputSize = 256
    static let maximumBytes = 20*1024*1024
    static func load(_ url:URL) throws -> CGImage {
        let scoped = url.startAccessingSecurityScopedResource();defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile == true,let size = values.fileSize,size > 0,size <= maximumBytes else { throw ChatTransferError(message:"Choose an image file up to 20 MB.") }
        let input = try FileHandle(forReadingFrom:url);defer { try? input.close() }
        let data = try input.read(upToCount:maximumBytes+1) ?? Data()
        return try decode(data)
    }
    static func decode(_ data:Data) throws -> CGImage {
        guard !data.isEmpty,data.count <= maximumBytes,let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0,height > 0,width <= 16384,height <= 16384,width*height <= 64*1024*1024,
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2048,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw ChatTransferError(message:"This image could not be read. Choose a supported photo.") }
        return image
    }
    static func cropRect(width:Int,height:Int,zoom:Double,x:Double,y:Double) throws -> CGRect {
        guard width > 0,height > 0,zoom.isFinite,x.isFinite,y.isFinite,(1...4).contains(zoom),(0...1).contains(x),(0...1).contains(y) else { throw ChatAPIError.invalidResponse }
        let side = max(1,floor(Double(min(width,height))/zoom))
        return CGRect(x:floor((Double(width)-side)*x),y:floor((Double(height)-side)*y),width:side,height:side)
    }
    static func render(_ image:CGImage,zoom:Double = 1,x:Double = 0.5,y:Double = 0.5) throws -> Data {
        let rect = try cropRect(width:image.width,height:image.height,zoom:zoom,x:x,y:y)
        guard let cropped = image.cropping(to:rect),let context = CGContext(data:nil,width:outputSize,height:outputSize,bitsPerComponent:8,bytesPerRow:outputSize*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ChatAPIError.invalidResponse }
        context.interpolationQuality = .high
        context.draw(cropped,in:CGRect(x:0,y:0,width:outputSize,height:outputSize))
        let data = NSMutableData()
        guard let result = context.makeImage(),let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw ChatAPIError.invalidResponse }
        // Re-encoding pixels excludes the source's GPS, EXIF, filename and other metadata.
        CGImageDestinationAddImage(destination,result,nil)
        guard CGImageDestinationFinalize(destination),data.length <= 2*1024*1024 else { throw ChatAPIError.invalidResponse }
        return data as Data
    }
}
