#if DEBUG
import AppKit
import ImageIO

@MainActor enum NativeSyntheticAnimatedImage {
    static func gif(frames:Int = 2,width:Int = 360,height:Int = 220)throws->Data {
        let result = NSMutableData()
        guard frames > 0,width > 0,height > 0,let destination = CGImageDestinationCreateWithData(result,"com.compuserve.gif" as CFString,frames,nil) else {throw ChatAPIError.invalidResponse}
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for frame in 0..<frames {
            guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw ChatAPIError.invalidResponse}
            context.setFillColor(frame % 2 == 0 ? CGColor(red:0.15,green:0.75,blue:0.55,alpha:1) : CGColor(red:0.55,green:0.25,blue:0.85,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
            context.setFillColor(CGColor(gray:1,alpha:1));let x = frame % 2 == 0 ? 0 : width/2;context.fill(CGRect(x:x,y:height/4,width:max(1,width/2),height:max(1,height/2)))
            guard let image = context.makeImage() else {throw ChatAPIError.invalidResponse}
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.75,kCGImagePropertyGIFUnclampedDelayTime:0.75]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {throw ChatAPIError.invalidResponse};return result as Data
    }
}
#endif
