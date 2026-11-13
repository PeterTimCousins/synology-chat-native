import AppKit
import Darwin
import XCTest
@testable import SynologyChatNative

final class NativeAttachmentImagePreviewTests:XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-image-review-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url
    }
    func testLocalImageIsBoundedAndOriginalBytesAreUnchanged() throws {
        let file = try folder().appendingPathComponent("image.PNG")
        try NativeSyntheticClipboardImage.data.write(to:file)
        let image = try XCTUnwrap(NativeAttachmentImageLoader.load(file))
        XCTAssertEqual(image.width,320);XCTAssertEqual(image.height,180)
        XCTAssertEqual(try Data(contentsOf:file),NativeSyntheticClipboardImage.data)
    }
    func testUnsupportedAndRemotePathsAreNotPreviewed() throws {
        let file = try folder().appendingPathComponent("note.txt");try NativeSyntheticClipboardImage.data.write(to:file)
        XCTAssertFalse(NativeAttachmentImageLoader.supports(file));XCTAssertNil(NativeAttachmentImageLoader.load(file))
        let remote = URL(string:"https://synthetic.invalid/picture.png")!
        XCTAssertFalse(NativeAttachmentImageLoader.supports(remote));XCTAssertNil(NativeAttachmentImageLoader.load(remote))
    }
    func testSymlinkDirectoryMissingAndPipeAreRejectedWithoutBlocking() throws {
        let root = try folder(),file = root.appendingPathComponent("original.png"),link = root.appendingPathComponent("alias.png"),directory = root.appendingPathComponent("folder.png"),pipe = root.appendingPathComponent("pipe.png")
        try NativeSyntheticClipboardImage.data.write(to:file)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        XCTAssertEqual(mkfifo(pipe.path,0o600),0)
        for invalid in [link,directory,pipe,root.appendingPathComponent("missing.png")] { XCTAssertNil(NativeAttachmentImageLoader.load(invalid)) }
    }
    func testOversizedSparseFileIsRejectedBeforeDecode() throws {
        let file = try folder().appendingPathComponent("too-large.png")
        XCTAssertTrue(FileManager.default.createFile(atPath:file.path,contents:NativeSyntheticClipboardImage.data))
        let handle = try FileHandle(forWritingTo:file);try handle.truncate(atOffset:UInt64(NativeAttachmentImageLoader.maximumBytes+1));try handle.close()
        XCTAssertNil(NativeAttachmentImageLoader.load(file))
    }
    func testCorruptEmptyAndNonImageDataHaveNoPreview() throws {
        let root = try folder()
        for (name,data) in [("broken.png",Data([1,2,3])),("empty.jpg",Data()),("document.png",Data("%PDF-1.4\nSynthetic text".utf8))] {
            let file = root.appendingPathComponent(name);try data.write(to:file);XCTAssertNil(NativeAttachmentImageLoader.load(file))
        }
    }
    func testCancelledWorkDoesNotPublishAnImage() async throws {
        let file = try folder().appendingPathComponent("image.png");try NativeSyntheticClipboardImage.data.write(to:file)
        let task = Task { () -> CGImage? in
            do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { }
            return NativeAttachmentImageLoader.load(file)
        }
        task.cancel();let image = await task.value;XCTAssertNil(image)
    }
    func testAttachmentMetadataReflectsSamePathFileReplacement() throws {
        let file = try folder().appendingPathComponent("image.png");try Data([1,2,3]).write(to:file)
        let item = NativeAttachmentItem(file:file,caption:"Keep this caption")
        XCTAssertEqual(item.size,3)
        try NativeSyntheticClipboardImage.data.write(to:file,options:.atomic)
        XCTAssertEqual(item.size,Int64(NativeSyntheticClipboardImage.data.count))
        XCTAssertEqual(item.caption,"Keep this caption");XCTAssertEqual(item.state,.queued)
    }
    func testRetryReadsReplacementRatherThanCachedOriginal() throws {
        let file = try folder().appendingPathComponent("image.png");try NativeSyntheticClipboardImage.data.write(to:file)
        XCTAssertNotNil(NativeAttachmentImageLoader.load(file))
        try Data("Not an image anymore".utf8).write(to:file,options:.atomic)
        XCTAssertNil(NativeAttachmentImageLoader.load(file))
        try NativeSyntheticClipboardImage.data.write(to:file,options:.atomic)
        XCTAssertNotNil(NativeAttachmentImageLoader.load(file))
    }
}
