import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeInlineImagePreviewTests: XCTestCase {
    func testImageFitsSmallTilesWithoutForcingAnImageSizedMinimum() throws {
        let image = try XCTUnwrap(NativeInlineImagePreview.decode(NativeSyntheticAnimatedImage.gif()))
        let raster = NativeInlineImageRaster()
        raster.image = image
        XCTAssertEqual(raster.intrinsicContentSize,.zero)
        for bounds in [CGSize(width:88,height:72),CGSize(width:320,height:240)] {
            let size = NativeInlineImageLayout.fit(image.size,proposal:.init(width:bounds.width,height:bounds.height))
            XCTAssertLessThanOrEqual(size.width,bounds.width)
            XCTAssertLessThanOrEqual(size.height,bounds.height)
            XCTAssertEqual(size.width / size.height,image.size.width / image.size.height,accuracy:0.0001)
        }
        XCTAssertEqual(NativeInlineImageLayout.fit(image.size,proposal:.zero),.zero)
        XCTAssertEqual(NativeInlineImageLayout.fit(image.size,proposal:.unspecified),image.size)
    }
    func testSmallGIFRetainsDistinctFramesAndAccountsForWholeAnimation() throws {
        let data = try NativeSyntheticAnimatedImage.gif()
        let image = try XCTUnwrap(NativeInlineImagePreview.decode(data))
        XCTAssertEqual(NativeInlineImagePreview.frameCount(image),2)
        XCTAssertEqual(NativeInlineImagePreview.memoryCost(image,encodedBytes:data.count),360 * 220 * 4 * 2 + data.count)
        let rep = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        rep.setProperty(.currentFrame,withValue:0)
        let first = rep.colorAt(x:180,y:10)
        rep.setProperty(.currentFrame,withValue:1)
        XCTAssertNotEqual(first,rep.colorAt(x:180,y:10))
    }

    func testFrameDimensionAndTotalPixelBudgetsFallBackToStaticPreview() throws {
        let fixtures = [
            try NativeSyntheticAnimatedImage.gif(frames:61,width:1,height:1),
            try NativeSyntheticAnimatedImage.gif(frames:2,width:641,height:2),
            try NativeSyntheticAnimatedImage.gif(frames:12,width:640,height:640)
        ]
        for data in fixtures {
            let image = try XCTUnwrap(NativeInlineImagePreview.decode(data))
            XCTAssertEqual(NativeInlineImagePreview.frameCount(image),1)
            XCTAssertLessThanOrEqual(max(image.size.width,image.size.height),640)
        }
    }

    func testOversizedLogicalCanvasNeverRetainsAnInlineAnimation() throws {
        var data = try NativeSyntheticAnimatedImage.gif(frames:2,width:1,height:1)
        data.replaceSubrange(6..<10,with:[UInt8(0x81),0x02,0x81,0x02])
        // A hand-edited logical canvas may be rejected by ImageIO entirely.
        // If it can be decoded, it must still use the bounded static fallback.
        if let image = NativeInlineImagePreview.decode(data) {
            XCTAssertEqual(NativeInlineImagePreview.frameCount(image),1)
            XCTAssertLessThanOrEqual(max(image.size.width,image.size.height),640)
        }
    }

    func testEncodedBudgetFallsBackWithoutDiscardingTheThumbnail() throws {
        var data = try NativeSyntheticAnimatedImage.gif(width:2,height:2)
        data.append(Data(repeating:0,count:NativeInlineImagePreview.maximumEncodedBytes))
        let image = try XCTUnwrap(NativeInlineImagePreview.decode(data))
        XCTAssertEqual(NativeInlineImagePreview.frameCount(image),1)
        XCTAssertNil(NativeInlineImagePreview.decode(Data("invalid image".utf8)))
    }

    func testInlineRasterDoesNotConsumeTheContainingImageButtonsClicks() {
        let image = NativeInlineImageRaster(frame:NSRect(x:0,y:0,width:100,height:100))
        XCTAssertNil(image.hitTest(NSPoint(x:50,y:50)))
    }
}
