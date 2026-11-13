import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeDroppedRasterBudgetTests: XCTestCase {
    private func image() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 120, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    private func provider(_ data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
            callback(data, nil); return nil
        }
        return provider
    }
    private func board(_ items: [NSPasteboardItem]) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(board.writeObjects(items))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }
    private func raster(_ data: Data) -> NSPasteboardItem {
        let item = NSPasteboardItem(); XCTAssertTrue(item.setData(data, forType: .png)); return item
    }
    private func remove(_ result: NativeConversationDropAttachments) {
        for file in result.generatedImageFiles { NativeComposerAttachmentReader.removeImage(file) }
    }
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("raster-budget-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Original.png")
        try Data(repeating: 65, count: 4096).write(to: file)
        return file
    }

    func testPasteboardRejectsWholeRasterBatchAboveAggregateBudget() throws {
        let png = try image(), board = board([raster(png), raster(png)])
        XCTAssertTrue(NativeConversationFileDropReader.hasAttachments(board))
        XCTAssertNil(NativeConversationFileDropReader.attachmentProviders(from: board, maximumImageBytes: png.count * 2 - 1))
    }

    func testExactAggregateLimitRetainsAndPreparesEveryImage() async throws {
        let png = try image(), board = board([raster(png), raster(png)])
        let providers = try XCTUnwrap(NativeConversationFileDropReader.attachmentProviders(from: board, maximumImageBytes: png.count * 2))
        XCTAssertEqual(providers.count, 2)
        let result = try await NativeConversationFileDropReader.readAttachments(providers, maximumImageBytes: png.count * 2)
        defer { remove(result) }
        XCTAssertEqual(result.files.count, 2); XCTAssertEqual(result.generatedImageFiles.count, 2)
        for file in result.files { XCTAssertEqual(try Data(contentsOf: file), png) }
    }

    func testAsyncOverflowRemovesEarlierGeneratedImageAndReturnsNoPrefix() async throws {
        let png = try image(), before = RasterBudgetFolderObservation.current(), observation = RasterBudgetFolderObservation()
        let second = NSItemProvider()
        second.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
            observation.capture(); callback(png, nil); return nil
        }
        do {
            let result = try await NativeConversationFileDropReader.readAttachments([provider(png), second], maximumImageBytes: png.count * 2 - 1)
            remove(result); XCTFail("An overflowing selection must not return its valid prefix")
        } catch {
            XCTAssertTrue((error as? ChatTransferError)?.message.contains("No files were added") == true)
        }
        let generated = observation.folders.subtracting(before)
        XCTAssertEqual(generated.count, 1, "The first image must have been written before the second exceeded the budget")
        XCTAssertTrue(generated.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFileReferencesPreferOriginalAndDoNotConsumeRasterBudget() async throws {
        let original = try file(), png = try image(), fileItem = raster(Data("Unused image flavor".utf8))
        XCTAssertTrue(fileItem.setString(original.absoluteString, forType: .fileURL))
        let mixed = board([fileItem, raster(png)])
        let providers = try XCTUnwrap(NativeConversationFileDropReader.attachmentProviders(from: mixed, maximumImageBytes: png.count))
        let result = try await NativeConversationFileDropReader.readAttachments(providers, maximumImageBytes: png.count)
        defer { remove(result) }
        XCTAssertEqual(result.files.count, 2); XCTAssertEqual(result.files.first, original.standardizedFileURL)
        XCTAssertEqual(result.generatedImageFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: original), Data(repeating: 65, count: 4096))
        let fileOnlyItem = raster(Data("Unused image flavor".utf8))
        XCTAssertTrue(fileOnlyItem.setString(original.absoluteString, forType: .fileURL))
        let fileOnly = board([fileOnlyItem])
        let fileProviders = try XCTUnwrap(NativeConversationFileDropReader.attachmentProviders(from: fileOnly, maximumImageBytes: 0))
        let files = try await NativeConversationFileDropReader.readAttachments(fileProviders, maximumImageBytes: 0)
        XCTAssertEqual(files.files, [original.standardizedFileURL]); XCTAssertTrue(files.generatedImageFiles.isEmpty)
    }
}

private final class RasterBudgetFolderObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = Set<URL>()
    var folders: Set<URL> { lock.lock(); defer { lock.unlock() }; return observed }
    func capture() { let folders = Self.current(); lock.lock(); observed = folders; lock.unlock() }
    static func current() -> Set<URL> {
        Set(((try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("native-chat-paste-") })
    }
}
