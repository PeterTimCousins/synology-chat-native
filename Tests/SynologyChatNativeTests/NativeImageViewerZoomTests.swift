import XCTest
import CoreGraphics
@testable import SynologyChatNative

final class NativeImageViewerZoomTests: XCTestCase {
    func testFitPreservesAspectAndInsetsForLargeImages() {
        let zoom = NativeImageViewerZoom()
        let size = zoom.layoutSize(imageSize:.init(width:4000,height:2000),viewport:.init(width:848,height:648),displayScale:2)
        XCTAssertEqual(size.width,800,accuracy:0.00001)
        XCTAssertEqual(size.height,400,accuracy:0.00001)
        XCTAssertEqual(zoom.fraction(imageSize:.init(width:4000,height:2000),viewport:.init(width:848,height:648),displayScale:2),0.4,accuracy:0.00001)
    }

    func testSmallImageFitDoesNotUpscaleOriginalPixelsOnRetina() {
        let zoom = NativeImageViewerZoom()
        XCTAssertEqual(zoom.layoutSize(imageSize:.init(width:200,height:100),viewport:.init(width:800,height:600),displayScale:2),CGSize(width:100,height:50))
        XCTAssertEqual(zoom.layoutSize(imageSize:.init(width:200,height:100),viewport:.init(width:800,height:600),displayScale:1),CGSize(width:200,height:100))
    }

    func testActualSizeIsIndependentOfFitAndTracksPhysicalDisplayScale() {
        var zoom = NativeImageViewerZoom(); zoom.actualSize()
        let pixels = CGSize(width:4000,height:2000)
        XCTAssertEqual(zoom.layoutSize(imageSize:pixels,viewport:.init(width:800,height:600),displayScale:2),CGSize(width:2000,height:1000))
        XCTAssertEqual(zoom.layoutSize(imageSize:pixels,viewport:.init(width:1000,height:800),displayScale:1),pixels)
        XCTAssertFalse(zoom.isFit)
        zoom.fit(); XCTAssertTrue(zoom.isFit)
    }

    func testZoomStepsUseAbsolutePercentagesRatherThanMultiplesOfFit() {
        var zoom = NativeImageViewerZoom()
        let image = CGSize(width:4000,height:2000), viewport = CGSize(width:848,height:648)
        XCTAssertEqual(zoom.next(1,imageSize:image,viewport:viewport,displayScale:2),0.5)
        zoom.step(1,imageSize:image,viewport:viewport,displayScale:2)
        XCTAssertEqual(zoom.layoutSize(imageSize:image,viewport:viewport,displayScale:2),CGSize(width:1000,height:500))
        zoom.step(1,imageSize:image,viewport:viewport,displayScale:2)
        XCTAssertEqual(zoom.fraction(imageSize:image,viewport:viewport,displayScale:2),0.75)
        zoom.step(-1,imageSize:image,viewport:viewport,displayScale:2)
        XCTAssertEqual(zoom.fraction(imageSize:image,viewport:viewport,displayScale:2),0.5)
    }

    func testExtremeImageCanStepBackToItsTinyFitAndNeverExceedFourHundredPercent() {
        var zoom = NativeImageViewerZoom()
        let image = CGSize(width:32768,height:1), viewport = CGSize(width:100,height:100)
        let fit = zoom.fraction(imageSize:image,viewport:viewport,displayScale:1)
        XCTAssertLessThan(fit,0.05)
        zoom.step(1,imageSize:image,viewport:viewport,displayScale:1)
        XCTAssertEqual(zoom.fraction(imageSize:image,viewport:viewport,displayScale:1),0.05)
        zoom.step(-1,imageSize:image,viewport:viewport,displayScale:1)
        XCTAssertEqual(zoom.fraction(imageSize:image,viewport:viewport,displayScale:1),fit)
        XCTAssertNil(zoom.next(-1,imageSize:image,viewport:viewport,displayScale:1))
        for _ in 0..<30 { zoom.step(1,imageSize:image,viewport:viewport,displayScale:1) }
        XCTAssertEqual(zoom.fraction(imageSize:image,viewport:viewport,displayScale:1),4)
        XCTAssertNil(zoom.next(1,imageSize:image,viewport:viewport,displayScale:1))
    }

    func testFitRespondsToResizeWhileExplicitPercentageIsStable() {
        var zoom = NativeImageViewerZoom()
        let image = CGSize(width:4000,height:2000)
        let small = CGSize(width:448,height:348), large = CGSize(width:848,height:648)
        XCTAssertEqual(zoom.layoutSize(imageSize:image,viewport:small,displayScale:1).width,400)
        XCTAssertEqual(zoom.layoutSize(imageSize:image,viewport:large,displayScale:1).width,800)
        zoom.actualSize()
        XCTAssertEqual(zoom.layoutSize(imageSize:image,viewport:small,displayScale:1),zoom.layoutSize(imageSize:image,viewport:large,displayScale:1))
    }

    func testInvalidAndTinyGeometryCannotProduceNegativeOrNonfiniteFrames() {
        let zoom = NativeImageViewerZoom()
        for image in [CGSize.zero,.init(width:-1,height:10),.init(width:CGFloat.infinity,height:10),.init(width:CGFloat.nan,height:10)] {
            XCTAssertEqual(zoom.layoutSize(imageSize:image,viewport:.init(width:800,height:600),displayScale:2),.zero)
            XCTAssertNil(zoom.next(1,imageSize:image,viewport:.init(width:800,height:600),displayScale:2))
        }
        for viewport in [CGSize.zero,.init(width:1,height:1),.init(width:-10,height:10),.init(width:CGFloat.infinity,height:10)] {
            let size = zoom.layoutSize(imageSize:.init(width:100,height:50),viewport:viewport,displayScale:2)
            XCTAssertTrue(size.width.isFinite && size.width > 0 && size.height.isFinite && size.height > 0)
        }
        for scale in [CGFloat.zero,-1,.infinity,.nan] {
            XCTAssertEqual(zoom.layoutSize(imageSize:.init(width:100,height:50),viewport:.init(width:800,height:600),displayScale:scale),CGSize(width:100,height:50))
        }
    }

    func testPinchUsesContinuousAbsolutePercentagesAndPreservesOriginalStateUntilCommitted() {
        let zoom = NativeImageViewerZoom(),image = CGSize(width:4000,height:2000),viewport = CGSize(width:848,height:648)
        let first = zoom.magnified(1.1,imageSize:image,viewport:viewport,displayScale:2)
        let second = zoom.magnified(1.5,imageSize:image,viewport:viewport,displayScale:2)
        XCTAssertEqual(first.fraction(imageSize:image,viewport:viewport,displayScale:2),0.44,accuracy:0.000001)
        XCTAssertEqual(second.fraction(imageSize:image,viewport:viewport,displayScale:2),0.6,accuracy:0.000001)
        XCTAssertEqual(second.layoutSize(imageSize:image,viewport:viewport,displayScale:2).width,1200,accuracy:0.000001)
        XCTAssertTrue(zoom.isFit,"Live pinch rendering must not compound earlier gesture updates")
    }

    func testFinishedPinchBecomesStablePercentageForNextGestureAndResize() {
        var zoom = NativeImageViewerZoom();let image = CGSize(width:4000,height:2000),viewport = CGSize(width:848,height:648)
        zoom = zoom.magnified(1.5,imageSize:image,viewport:viewport,displayScale:2)
        XCTAssertFalse(zoom.isFit)
        zoom = zoom.magnified(2,imageSize:image,viewport:viewport,displayScale:2)
        XCTAssertEqual(zoom.fraction(imageSize:image,viewport:viewport,displayScale:2),1.2,accuracy:0.000001)
        XCTAssertEqual(zoom.layoutSize(imageSize:image,viewport:.init(width:448,height:348),displayScale:2).width,2400,accuracy:0.000001)
    }

    func testPinchBoundsHandleExtremeFactorsAndTinyFitWithoutNonfiniteFrames() {
        let zoom = NativeImageViewerZoom(),image = CGSize(width:32768,height:100),viewport = CGSize(width:100,height:100)
        let maximum = zoom.magnified(CGFloat.greatestFiniteMagnitude,imageSize:image,viewport:viewport,displayScale:2)
        XCTAssertEqual(maximum.fraction(imageSize:image,viewport:viewport,displayScale:2),4)
        let overflow = maximum.magnified(CGFloat.greatestFiniteMagnitude,imageSize:image,viewport:viewport,displayScale:2)
        XCTAssertEqual(overflow.fraction(imageSize:image,viewport:viewport,displayScale:2),4)
        let minimum = maximum.magnified(CGFloat.leastNonzeroMagnitude,imageSize:image,viewport:viewport,displayScale:2)
        XCTAssertEqual(minimum.fraction(imageSize:image,viewport:viewport,displayScale:2),zoom.fraction(imageSize:image,viewport:viewport,displayScale:2))
        XCTAssertTrue(minimum.layoutSize(imageSize:image,viewport:viewport,displayScale:2).width.isFinite)
    }

    func testInvalidOrCancelledPinchLeavesZoomUnchanged() {
        let zoom = NativeImageViewerZoom(),image = CGSize(width:4000,height:2000),viewport = CGSize(width:848,height:648)
        for factor: CGFloat in [0,-1,.nan,.infinity,1] {
            XCTAssertEqual(zoom.magnified(factor,imageSize:image,viewport:viewport,displayScale:2),zoom)
        }
        XCTAssertEqual(zoom.magnified(2,imageSize:.zero,viewport:viewport,displayScale:2),zoom)
        XCTAssertEqual(zoom.magnified(2,imageSize:image,viewport:.zero,displayScale:2),zoom)
    }

    func testDoubleClickTogglesBetweenActualSizeAndFitFromAnyZoom() {
        var zoom = NativeImageViewerZoom();let image = CGSize(width:4000,height:2000),viewport = CGSize(width:848,height:648)
        zoom.toggleActualSize();XCTAssertEqual(zoom.mode,.percentage(1))
        zoom.toggleActualSize();XCTAssertTrue(zoom.isFit)
        zoom = zoom.magnified(1.5,imageSize:image,viewport:viewport,displayScale:2)
        zoom.toggleActualSize();XCTAssertEqual(zoom.mode,.percentage(1))
        zoom.toggleActualSize();XCTAssertTrue(zoom.isFit)
    }

}
