import XCTest
@testable import SynologyChatNative

final class NativeFileAttachmentPresentationTests: XCTestCase {
    func testImageMetadataTakesPrecedenceOverMisleadingFilenameExtension() {
        let value = NativeFileAttachmentPresentation(filename:"photo.zip",isImage:true,size:20)
        XCTAssertEqual(value.typeLabel,"Image")
        XCTAssertEqual(value.symbol,"photo")
    }
    func testUnicodeAndMultipleDotFilenamesUseOnlyCaseInsensitiveFinalExtension() {
        let pdf = NativeFileAttachmentPresentation(filename:"Résumé.2026.final.PDF",isImage:false,size:nil)
        XCTAssertEqual(pdf.typeLabel,"PDF document")
        XCTAssertEqual(pdf.metadata,"PDF document")
        XCTAssertEqual(NativeFileAttachmentPresentation(filename:"backup.tar.GZ",isImage:false,size:nil).typeLabel,"Archive")
        XCTAssertEqual(NativeFileAttachmentPresentation(filename:"recording.M4A",isImage:false,size:nil).typeLabel,"Audio")
    }
    func testUntrustedExtensionsCannotExpandMetadataIntoUnboundedOrMultilineLabels() {
        for name in ["README","file." + String(repeating:"x",count:500),"file.bad\next","file.絵"] {
            let value = NativeFileAttachmentPresentation(filename:name,isImage:false,size:nil)
            XCTAssertEqual(value.typeLabel,"File",name)
            XCTAssertEqual(value.symbol,"doc")
        }
        XCTAssertEqual(NativeFileAttachmentPresentation(filename:"file.BIN",isImage:false,size:nil).typeLabel,"BIN file")
    }
    func testUnknownAndInvalidSizesAreOmittedWithoutInventingZeroBytes() {
        XCTAssertNil(NativeFileAttachmentPresentation(filename:"file.txt",isImage:false,size:nil).sizeLabel)
        XCTAssertNil(NativeFileAttachmentPresentation(filename:"file.txt",isImage:false,size:-1).sizeLabel)
        let zero = NativeFileAttachmentPresentation(filename:"file.txt",isImage:false,size:0)
        XCTAssertNotNil(zero.sizeLabel)
        XCTAssertTrue(zero.metadata.contains(" · "))
        XCTAssertNotNil(NativeFileAttachmentPresentation(filename:"file.txt",isImage:false,size:Int64.max).sizeLabel)
    }
}
