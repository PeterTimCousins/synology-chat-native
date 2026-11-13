import CommonCrypto
import XCTest
@testable import SynologyChatNative

final class OfficialChatSessionTests: XCTestCase {
    private func session(_ username: String = "synthetic") throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["ip": "synthetic.test:5001", "isHTTPS": true,
            "sid": "synthetic-sid", "synotoken": "synthetic-token", "username": username])
        let key = [UInt8](repeating: 7, count: 32), iv = [UInt8](repeating: 8, count: 16)
        var output = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        var written = 0
        let status = payload.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, bytes.baseAddress, payload.count, &output, output.count, &written)
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return (Data(key) + Data(iv) + Data(output.prefix(written))).base64EncodedString()
    }
    private func record(_ id: String, data: Any) -> [String: Any] { ["_id": id, "type": "session", "data": data] }
    private func load(_ records: [[String: Any]], suffix: String = "") throws -> ChatAccount {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n" + suffix
        try Data(text.utf8).write(to: file, options: .atomic)
        defer { XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), text, "Import must be read-only") }
        return try OfficialChatSessionLoader.load(from: file)
    }
    func testDeletedSessionCannotBeResurrectedFromEarlierLogRecord() throws {
        XCTAssertThrowsError(try load([record("session", data: session()), ["_id": "session", "$$deleted": true]]))
    }
    func testReplacementWithoutSessionTypeInvalidatesEarlierSession() throws {
        XCTAssertThrowsError(try load([record("session", data: session()), ["_id": "session", "type": "settings"]]))
    }
    func testLatestReplacementIsImportedWithoutModifyingDatabase() throws {
        let account = try load([record("session", data: session("old")), record("session", data: session("new")),
                                ["$$indexCreated": ["fieldName": "type"]]])
        XCTAssertEqual(account.username, "new")
        XCTAssertEqual(account.session.baseURL.absoluteString, "https://synthetic.test:5001")
        XCTAssertTrue(account.importedFromOfficialApp)
    }
    func testDeletingAnotherRecordDoesNotDiscardCurrentSession() throws {
        let account = try load([record("old", data: session("old")), record("current", data: session("current")),
                                ["_id": "old", "$$deleted": true]])
        XCTAssertEqual(account.username, "current")
    }
    func testMalformedNewestStateDoesNotFallBackToOldCredential() throws {
        let old = try record("session", data: session())
        for invalid: Any in [17, "not-base64", ""] {
            XCTAssertThrowsError(try load([old, record("session", data: invalid)]))
        }
        XCTAssertThrowsError(try load([old], suffix: "{incomplete"))
        XCTAssertThrowsError(try load([["type": "session", "data": try session()]]))
    }
}
