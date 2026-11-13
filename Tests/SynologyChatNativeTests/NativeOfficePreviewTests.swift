import XCTest
@testable import SynologyChatNative

@MainActor final class NativeOfficePreviewTests: XCTestCase {
    private let rtf = Data("{\\rtf1\\ansi Synthetic office preview.}".utf8)
    private func store() throws -> (URL, NativeMediaTemporaryFiles) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-office-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, NativeMediaTemporaryFiles(root: root, namespace: "unit-tests", purpose: "office-preview", acceptsFilename: {
            $0.hasPrefix("attachment.") && NativeOfficePreviewFormat.supportedExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }))
    }
    func testOfficeCatalogueExcludesActiveWebAndMacroEnabledExtensions() {
        for ext in NativeOfficePreviewFormat.supportedExtensions { XCTAssertEqual(NativeDocumentKind.forFilename("Fixture." + ext.uppercased()), .quickLook) }
        for ext in ["exe", "htmlx", "svg", "docm", "xlsm", "pptm", "zip", "rtfd", "pages"] { XCTAssertNil(NativeDocumentKind.forFilename("Fixture." + ext)) }
        XCTAssertEqual(NativeDocumentKind.forFilename("Fixture.html"), .text)
    }
    func testContainerHeaderBoundsAndSuffixMustAgreeBeforeCreatingAnyFile() throws {
        XCTAssertEqual(try NativeOfficePreviewFormat.validate(rtf, filename: "Fixture.RTF"), "rtf")
        let ole = Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
        XCTAssertNoThrow(try NativeOfficePreviewFormat.validate(ole, filename: "Fixture.doc"))
        let zip = Data([0x50, 0x4b, 0x03, 0x04]) + Data(repeating: 0, count: 18)
        XCTAssertNoThrow(try NativeOfficePreviewFormat.validate(zip, filename: "Fixture.docx"))
        // Header validation selects the decoder; only Quick Look establishes whether a real document renders.
        for (data, name) in [(rtf, "Fixture.docx"), (zip, "Fixture.doc"), (ole, "Fixture.rtf"), (Data(), "Fixture.docx"), (Data("MZ executable".utf8), "Fixture.docx"), (rtf, "Fixture.docm"), (Data(repeating: 65, count: NativeDocumentKind.quickLook.limit + 1), "Fixture.rtf")] {
            XCTAssertThrowsError(try NativeOfficePreviewFormat.validate(data, filename: name))
        }
    }
    func testOriginalBytesPrivateModesAndExplicitCleanupArePreserved() throws {
        let (root, files) = try store()
        let unrelated = root.appendingPathComponent("unrelated.txt"); try Data("retain".utf8).write(to: unrelated)
        let resource = try NativeOfficePreview.load(rtf, filename: "../../Original RTF.rtf", files: files)
        XCTAssertEqual(resource.file.lastPathComponent, "attachment.rtf")
        XCTAssertEqual(try Data(contentsOf: resource.file), rtf)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: resource.file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: resource.file.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        resource.dispose(); resource.dispose()
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.file.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("retain".utf8))
    }
    func testResourceReleaseRemovesOnlyItsOwnLease() throws {
        let (_, files) = try store()
        var resource: NativeOfficePreview? = try NativeOfficePreview.load(rtf, filename: "original.rtf", files: files)
        let file = try XCTUnwrap(resource?.file)
        resource = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }
    func testCancelledLoadCreatesNoPlaintextLease() async throws {
        let (root, files) = try store(); let bytes = rtf
        let task = Task { try NativeOfficePreview.load(bytes, filename: "original.rtf", files: files) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled document staged") } catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
