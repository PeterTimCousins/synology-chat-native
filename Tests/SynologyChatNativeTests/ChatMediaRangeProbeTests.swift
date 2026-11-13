#if DEBUG
import XCTest
@testable import SynologyChatNative

final class ChatMediaRangeProbeTests: XCTestCase {
    private func request(method: String = "get", api: String = "SYNO.Chat.Post.File") throws -> URLRequest {
        let client = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.invalid")!, sid: "synthetic", synoToken: "synthetic"))
        return try client.makeRequest(api: api, method: method, version: 2, path: "entry.cgi",
                                      parameters: ["post_id": .integer(399431958752)], jsonParameters: true)
    }
    private func post(_ fixture: ChatMediaRangeFixture, change: (inout [String: Any]) -> Void = { _ in }) throws -> ChatPost {
        var value: [String: Any] = ["post_id": fixture.postID, "channel_id": 93, "creator_id": 10,
            "thread_id": 0, "create_at": 1000, "type": "file", "message": fixture.caption,
            "file_props": ["name": fixture.filename, "size": fixture.count]]
        change(&value)
        return try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testProbePinsOnlyHistoricalOwnSyntheticMedia() {
        XCTAssertEqual(ChatMediaRangeFixture.all.map(\.postID), [399431958752, 399431958753])
        XCTAssertEqual(ChatMediaRangeFixture.all.map(\.count), [132344, 2864])
        XCTAssertTrue(ChatMediaRangeFixture.all.allSatisfy { $0.sha256.count == 64 })
    }
    func testExactSyntheticMetadataAccepted() throws {
        for fixture in ChatMediaRangeFixture.all { XCTAssertNoThrow(try fixture.validate(post(fixture))) }
    }
    func testChangedIdentityAndContentMetadataRefuseRead() throws {
        let fixture = ChatMediaRangeFixture.all[0]
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["post_id"] = 399431958753 }, { $0["channel_id"] = 94 }, { $0["creator_id"] = 6 },
            { $0["thread_id"] = 1 }, { $0["type"] = "normal" }, { $0["message"] = "Changed" },
            { $0["delete_at"] = 1 }, { $0["props"] = ["encrypted": true] },
            { $0["file_props"] = ["name": fixture.filename, "size": fixture.count + 1] },
            { $0["file_props"] = ["name": "another.wav", "size": fixture.count] }
        ]
        for change in changes { XCTAssertThrowsError(try fixture.validate(post(fixture, change: change))) }
    }
    func testGetConversionRetainsOnlyExistingAuthAndExactReadRouting() throws {
        let original = try request(), result = try ChatMediaRangeProbe.getRequest(from: original)
        XCTAssertEqual(result.httpMethod, "GET"); XCTAssertNil(result.httpBody)
        XCTAssertNil(result.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(result.url?.host, original.url?.host)
        XCTAssertEqual(result.url?.path, original.url?.deletingLastPathComponent().path)
        let suffixed = try ChatMediaRangeProbe.getRequest(from: original, canonicalPath: false)
        XCTAssertEqual(suffixed.url?.path, original.url?.path)
        let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(result.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.count, 6); XCTAssertEqual(Set(items.map(\.name)).count, 6)
        for key in ["_sid", "SynoToken"] {
            let old = URLComponents(url: original.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
            XCTAssertEqual(items.first { $0.name == key }?.value, old)
        }
        XCTAssertEqual(items.first { $0.name == "method" }?.value, "get")
        XCTAssertEqual(items.first { $0.name == "version" }?.value, "2")
        XCTAssertEqual(items.first { $0.name == "post_id" }?.value, "399431958752")
    }
    func testGetConversionRefusesWritesUnknownAPIsAndDuplicateRouting() throws {
        XCTAssertThrowsError(try ChatMediaRangeProbe.getRequest(from: request(method: "delete")))
        XCTAssertThrowsError(try ChatMediaRangeProbe.getRequest(from: request(api: "SYNO.Chat.Post")))
        var missing = try request(); missing.httpBody = nil
        XCTAssertThrowsError(try ChatMediaRangeProbe.getRequest(from: missing))
        var duplicate = try request(), url = URLComponents(url: duplicate.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = (url.queryItems ?? []) + [.init(name: "method", value: "delete")]; duplicate.url = url.url
        XCTAssertThrowsError(try ChatMediaRangeProbe.getRequest(from: duplicate))
    }
}
#endif
