import Foundation
import XCTest
@testable import SynologyChatNative

final class NativeLinkPreviewImageLayoutTests:XCTestCase {
    private let image = "https://example.invalid/preview.png"
    private func assertSize(_ actual:CGSize?,_ width:CGFloat,_ height:CGFloat,file:StaticString = #filePath,line:UInt = #line) {
        guard let actual else { XCTFail("Expected bounded image size",file:file,line:line);return }
        XCTAssertEqual(actual.width,width,accuracy:0.0001,file:file,line:line)
        XCTAssertEqual(actual.height,height,accuracy:0.0001,file:file,line:line)
    }
    func testKnownLandscapeSlotMatchesLoadedFootprint() {
        let metadata = CGSize(width:400,height:200)
        let before = NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:metadata)
        let after = NativeLinkPreviewImageLayout.displaySize(image:image,metadata:metadata,loaded:CGSize(width:640,height:320))
        assertSize(before,372,186);XCTAssertEqual(before,after)
    }
    func testPortraitAndSmallImagesPreserveCapsWithoutUpscaling() {
        assertSize(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:CGSize(width:400,height:800)),110,220)
        assertSize(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:CGSize(width:20,height:30)),20,30)
        assertSize(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:CGSize(width:1,height:1)),1,1)
        assertSize(NativeLinkPreviewImageLayout.displaySize(image:image,metadata:CGSize(width:16,height:16),loaded:CGSize(width:640,height:480)),16,16)
    }
    func testAbsentEmptyOrUnsupportedImageURLNeverReservesOrDisplaysSlot() {
        let invalidURLs:[String?] = [nil,""," \n ","file:///tmp/image.png","javascript:alert(1)","not a URL"]
        for value in invalidURLs {
            XCTAssertNil(NativeLinkPreviewImageLayout.reservedSize(image:value,metadata:CGSize(width:400,height:200)))
            XCTAssertNil(NativeLinkPreviewImageLayout.displaySize(image:value,metadata:CGSize(width:400,height:200),loaded:CGSize(width:400,height:200)))
        }
    }
    func testMissingOrInvalidMetadataDoesNotReserveSpace() {
        let invalid:[CGSize?] = [nil,CGSize.zero,CGSize(width:-1,height:20),CGSize(width:20,height:0),CGSize(width:CGFloat.nan,height:20),CGSize(width:20,height:CGFloat.infinity)]
        for value in invalid { XCTAssertNil(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:value)) }
    }
    func testUnknownMetadataUsesActualLoadedSizeOnceAvailable() {
        XCTAssertNil(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:nil))
        assertSize(NativeLinkPreviewImageLayout.displaySize(image:image,metadata:nil,loaded:CGSize(width:640,height:320)),372,186)
        assertSize(NativeLinkPreviewImageLayout.displaySize(image:image,metadata:CGSize(width:CGFloat.infinity,height:20),loaded:CGSize(width:24,height:24)),24,24)
        assertSize(NativeLinkPreviewImageLayout.displaySize(image:image,metadata:nil,loaded:CGSize(width:800,height:600)),293.333333,220)
    }
    func testInvalidLoadedSizeCannotProduceNonfiniteOrUnboundedGeometry() {
        for value in [CGSize.zero,CGSize(width:-1,height:20),CGSize(width:20,height:CGFloat.nan),CGSize(width:CGFloat.infinity,height:20)] {
            XCTAssertNil(NativeLinkPreviewImageLayout.displaySize(image:image,metadata:nil,loaded:value))
        }
        assertSize(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:CGSize(width:8_000,height:4_000)),372,186)
    }
    func testLargeFiniteMetadataRemainsUsableWithoutAnArbitraryPixelBudget() {
        assertSize(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:CGSize(width:16_000,height:16_000)),220,220)
        assertSize(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:CGSize(width:40_000,height:20_000)),372,186)
        assertSize(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:CGSize(width:20_000,height:40_000)),110,220)
        assertSize(NativeLinkPreviewImageLayout.displaySize(image:image,metadata:nil,loaded:CGSize(width:40_000,height:20_000)),372,186)
        assertSize(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:CGSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)),220,220)
    }
    func testExtremeAspectRatioUnderflowNeverCreatesAZeroSizedSlot() {
        let value = CGSize(width:CGFloat.leastNonzeroMagnitude,height:CGFloat.greatestFiniteMagnitude)
        XCTAssertNil(NativeLinkPreviewImageLayout.reservedSize(image:image,metadata:value))
        XCTAssertNil(NativeLinkPreviewImageLayout.displaySize(image:image,metadata:nil,loaded:value))
    }
    func testMismatchedMetadataKeepsSlotButNeverUpscalesDecodedImage() {
        let slot = NativeLinkPreviewImageLayout.displaySize(image:image,metadata:CGSize(width:400,height:200),loaded:CGSize(width:24,height:24))!
        assertSize(slot,372,186)
        assertSize(NativeLinkPreviewImageLayout.renderedSize(loaded:CGSize(width:24,height:24),slot:slot),24,24)
        assertSize(NativeLinkPreviewImageLayout.renderedSize(loaded:CGSize(width:640,height:640),slot:slot),186,186)
        assertSize(NativeLinkPreviewImageLayout.renderedSize(loaded:CGSize(width:640,height:320),slot:slot),372,186)
        XCTAssertNil(NativeLinkPreviewImageLayout.renderedSize(loaded:.zero,slot:slot))
        XCTAssertNil(NativeLinkPreviewImageLayout.renderedSize(loaded:CGSize(width:24,height:24),slot:.zero))
    }
}
