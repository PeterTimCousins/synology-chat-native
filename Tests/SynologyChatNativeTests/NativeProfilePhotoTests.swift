import XCTest
import ImageIO
@testable import SynologyChatNative

final class NativeProfilePhotoTests:XCTestCase {
    func testCropGeometryUsesTopLeftNormalizedPositionAndZoom() throws {
        XCTAssertEqual(try NativeProfilePhoto.cropRect(width:800,height:400,zoom:1,x:0,y:0),CGRect(x:0,y:0,width:400,height:400))
        XCTAssertEqual(try NativeProfilePhoto.cropRect(width:800,height:400,zoom:1,x:1,y:1),CGRect(x:400,y:0,width:400,height:400))
        XCTAssertEqual(try NativeProfilePhoto.cropRect(width:400,height:800,zoom:2,x:1,y:1),CGRect(x:200,y:600,width:200,height:200))
        for zoom in [Double.nan,Double.infinity,0.0,5.0] { XCTAssertThrowsError(try NativeProfilePhoto.cropRect(width:400,height:800,zoom:zoom,x:0.5,y:0.5)) }
        XCTAssertThrowsError(try NativeProfilePhoto.cropRect(width:400,height:800,zoom:1,x:-1,y:0.5))
    }
    func testCropProducesFixedSquarePNGFromChosenAreaWithoutMetadata() throws {
        let context = CGContext(data:nil,width:800,height:400,bitsPerComponent:8,bytesPerRow:3200,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));context.fill(CGRect(x:0,y:0,width:400,height:400))
        context.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));context.fill(CGRect(x:400,y:0,width:400,height:400))
        let tagged = NSMutableData(),dest = CGImageDestinationCreateWithData(tagged,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(dest,context.makeImage()!,[kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:51.5,kCGImagePropertyGPSLatitudeRef:"N"],kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2020:01:01 00:00:00"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let image = try NativeProfilePhoto.decode(tagged as Data),left = try NativeProfilePhoto.render(image,x:0),right = try NativeProfilePhoto.render(image,x:1)
        XCTAssertNotEqual(left,right)
        for data in [left,right] {
            let source = CGImageSourceCreateWithData(data as CFData,nil)!,props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as! [CFString:Any]
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int,256);XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int,256)
            XCTAssertNil(props[kCGImagePropertyGPSDictionary]);XCTAssertNil((props[kCGImagePropertyExifDictionary] as? [CFString:Any])?[kCGImagePropertyExifDateTimeOriginal])
            XCTAssertEqual(try NativeProfilePhoto.decode(data).width,256)
        }
    }
    func testInvalidAndOversizedInputsRejectedBeforeDecode() throws {
        XCTAssertThrowsError(try NativeProfilePhoto.decode(Data()))
        XCTAssertThrowsError(try NativeProfilePhoto.decode(Data("fake.png".utf8)))
        XCTAssertThrowsError(try NativeProfilePhoto.decode(Data(repeating:0,count:NativeProfilePhoto.maximumBytes+1)))
        XCTAssertThrowsError(try NativeProfilePhoto.load(FileManager.default.temporaryDirectory))
    }
}
