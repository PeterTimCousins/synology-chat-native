import XCTest
@testable import SynologyChatNative

final class ChatAttachmentTests: XCTestCase {
    func testMultipartStreamsBinaryAndUsesRawStringFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.bin")
        let content = Data((0..<200_000).map { UInt8($0 % 251) })
        try content.write(to: file)
        let body = try ChatMultipartBody.write(file: file, fields: ["message": "Caption + & café", "type": "file"], boundary: "SyntheticBoundary", limitBytes: 0)
        defer { NativeSnippetTemporaryFiles.shared.remove(body) }
        let encoded = try Data(contentsOf: body)
        XCTAssertNotNil(encoded.range(of: content))
        XCTAssertTrue(encoded.starts(with: Data("--SyntheticBoundary\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\nCaption + & café\r\n".utf8)))
        XCTAssertTrue(encoded.suffix(Data("\r\n--SyntheticBoundary--\r\n".utf8).count) == Data("\r\n--SyntheticBoundary--\r\n".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: body.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testOrdinaryMultipartUploadDoesNotSendTruthyFalseThreadFlag() throws {
        let fields = ChatMultipartBody.postFields(channelID: 42, caption: "Synthetic + & café", connectionID: "synthetic")
        XCTAssertNil(fields["is_thread"])
        XCTAssertEqual(fields["thread_id"], "0")
        XCTAssertEqual(fields["channel_id"], "42")
        XCTAssertEqual(fields["message"], "Synthetic + & café")
    }

    func testReplyAttachmentUsesExplicitRootWithoutPromotingItToAThread() {
        let fields = ChatMultipartBody.postFields(channelID: 42, caption: "reply", connectionID: "synthetic", threadID: 1234)
        XCTAssertEqual(fields["thread_id"], "1234")
        XCTAssertEqual(fields["type"], "file")
        XCTAssertNil(fields["is_thread"])
    }

    func testOversizedFilesAndDirectoriesAreRejectedBeforeTransfer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.txt")
        try Data(repeating: 0, count: 20).write(to: file)
        XCTAssertThrowsError(try ChatMultipartBody.write(file: file, fields: [:], boundary: "test", limitBytes: 10))
        XCTAssertThrowsError(try ChatMultipartBody.write(file: directory, fields: [:], boundary: "test", limitBytes: 0))
    }

    func testRemoteFileNamesCannotBecomePathsOrInjectMultipartHeaders() {
        XCTAssertEqual(ChatMultipartBody.safeFilename("../../file.txt"), "file.txt")
        XCTAssertEqual(ChatMultipartBody.safeFilename("..\\..\\file.txt"), "file.txt")
        XCTAssertFalse(ChatMultipartBody.safeFilename("file\r\n\".txt").unicodeScalars.contains(where: { $0.value < 32 || $0 == "\"" }))
        XCTAssertEqual(ChatMultipartBody.safeFilename(".."), "attachment")
    }
}
