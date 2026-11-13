import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeConversationRasterDropTests: XCTestCase {
    private func image(_ format: NSBitmapImageRep.FileType = .png) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 120, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
    }
    private func provider(_ data: Data, type: String = UTType.png.identifier) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { callback in callback(data, nil); return nil }
        return provider
    }
    private func remove(_ result: NativeConversationDropAttachments) {
        for file in result.generatedImageFiles { NativeComposerAttachmentReader.removeImage(file) }
    }
    func testActualRasterProvidersPreserveOrderAndNormalizeTIFF() async throws {
        let png = try image(), jpeg = try image(.jpeg), gif = try image(.gif), tiff = try image(.tiff)
        let result = try await NativeConversationFileDropReader.readAttachments([
            provider(png), provider(jpeg, type: UTType.jpeg.identifier),
            provider(gif, type: UTType.gif.identifier), provider(tiff, type: UTType.tiff.identifier)])
        defer { remove(result) }
        XCTAssertEqual(result.files.count, 4); XCTAssertEqual(result.generatedImageFiles.count, 4)
        XCTAssertEqual(result.files.map(\.pathExtension), ["png", "jpg", "gif", "png"])
        XCTAssertEqual(try Data(contentsOf: result.files[0]), png)
        XCTAssertEqual(try Data(contentsOf: result.files[1]), jpeg)
        XCTAssertEqual(try Data(contentsOf: result.files[2]), gif)
        XCTAssertNotNil(NSImage(contentsOf: result.files[3]))
    }
    func testFileFlavorTakesPriorityAndLegacyReaderRemainsFileOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("raster-drop-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("original.png"); try image().write(to: file)
        let mixed = provider(Data("invalid image flavor".utf8))
        mixed.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { callback in
            callback(Data(file.absoluteString.utf8), nil); return nil
        }
        let result = try await NativeConversationFileDropReader.readAttachments([mixed, NSItemProvider(object: file as NSURL)])
        XCTAssertEqual(result.files, [file.standardizedFileURL]); XCTAssertTrue(result.generatedImageFiles.isEmpty)
        do { _ = try await NativeConversationFileDropReader.read([provider(try image())]); XCTFail("Legacy file-only API accepted raster") } catch { }
    }
    func testMalformedSuffixCleansEarlierGeneratedImageWithoutPartialResult() async throws {
        var generatedBeforeFailure: [URL] = []
        let broken = NSItemProvider()
        broken.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
            let root = FileManager.default.temporaryDirectory
            generatedBeforeFailure = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("native-chat-paste-") }
            callback(Data("not a PNG".utf8), nil); return nil
        }
        let before = Set((try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [])
        do { _ = try await NativeConversationFileDropReader.readAttachments([provider(try image()), broken]); XCTFail() } catch { }
        let owned = generatedBeforeFailure.filter { !before.contains($0) }
        XCTAssertEqual(owned.count, 1)
        XCTAssertTrue(owned.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        do { _ = try await NativeConversationFileDropReader.readAttachments([provider(try image()), provider(Data(), type: UTType.plainText.identifier)]); XCTFail("Unsupported mixed suffix accepted") } catch { }
    }
    func testRasterProviderCancellationAndTimeoutCancelProgressAndIgnoreLateData() async throws {
        for cancel in [false, true] {
            let gate = RasterDropGate(), held = NSItemProvider()
            held.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in gate.start(callback) }
            let task = Task { try await NativeConversationFileDropReader.readAttachments([held], timeoutNanoseconds: cancel ? 5_000_000_000 : 100_000_000) }
            for _ in 0..<100 where !gate.started { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(gate.started)
            if cancel { task.cancel() }
            do { let result = try await task.value; remove(result); XCTFail("Held raster completed") } catch { }
            XCTAssertTrue(gate.progress.isCancelled)
            gate.finish(try image())
        }
    }
    func testNativeViewportRoutesRasterAndRejectsMixedUnsupportedPasteboard() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let raster = NSPasteboardItem(); raster.setData(try image(), forType: .png)
        board.writeObjects([raster])
        let container = NativeConversationDropContainer(content: AnyView(Text("Owned synthetic viewport")))
        XCTAssertTrue(container.registeredDraggedTypes.contains(.png))
        XCTAssertTrue(container.host.registeredDraggedTypes.contains(.png))
        container.canReceive = { true }
        var received: [NSItemProvider] = []
        container.receive = { received = $0; return true }
        let drag = SyntheticFileDraggingInfo(board)
        XCTAssertEqual(container.host.draggingEntered(drag), .copy)
        XCTAssertTrue(container.host.performDragOperation(drag))
        let result = try await NativeConversationFileDropReader.readAttachments(received); defer { remove(result) }
        XCTAssertEqual(result.files.count, 1); XCTAssertEqual(result.generatedImageFiles.count, 1)
        let text = NSPasteboardItem(); text.setString("Unsupported item", forType: .string)
        let mixedRaster = NSPasteboardItem(); mixedRaster.setData(try image(), forType: .png)
        board.clearContents(); board.writeObjects([mixedRaster, text]); received = []
        XCTAssertEqual(container.host.draggingEntered(drag), [])
        XCTAssertFalse(container.host.performDragOperation(drag)); XCTAssertTrue(received.isEmpty)
    }
}

private final class RasterDropGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, Error?) -> Void)?
    let progress = Progress(totalUnitCount: 1)
    var started: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
    func start(_ callback: @escaping (Data?, Error?) -> Void) -> Progress {
        lock.lock(); self.callback = callback; lock.unlock(); return progress
    }
    func finish(_ data: Data) {
        lock.lock(); let callback = callback; self.callback = nil; lock.unlock(); callback?(data, nil)
    }
}
