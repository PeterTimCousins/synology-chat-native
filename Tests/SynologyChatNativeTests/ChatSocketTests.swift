import XCTest
@testable import SynologyChatNative

final class ChatSocketTests: XCTestCase {
    func testObservedEngineV3HandshakeAndControlPackets() throws {
        XCTAssertEqual(try ChatSocketFrame.parse(#"0{"sid":"synthetic","upgrades":[],"pingInterval":25000,"pingTimeout":60000}"#),
                       .open(pingInterval: 25_000, pingTimeout: 60_000))
        XCTAssertEqual(try ChatSocketFrame.parse("40"), .connected)
        XCTAssertEqual(try ChatSocketFrame.parse("3"), .pong)
        XCTAssertEqual(try ChatSocketFrame.parse("2probe"), .ping("probe"))
        XCTAssertEqual(try ChatSocketFrame.parse("41"), .closed)
        XCTAssertEqual(try ChatSocketFrame.parse(#"44{"code":119}"#), .rejected)
    }

    func testMetadataOnlyCreateEventRetainsExactPostIdentifier() throws {
        let packet = #"42["client.post.create",{"channel_id":23,"user_id":10,"data":{"post_id":9007199254740993,"thread_id":0}}]"#
        guard case .event(let event) = try ChatSocketFrame.parse(packet) else { return XCTFail("Expected event") }
        XCTAssertEqual(event.name, "client.post.create")
        XCTAssertEqual(event.channelID, 23)
        XCTAssertEqual(event.postID, 9_007_199_254_740_993)
        XCTAssertNil(event.payload["data"]?["message"])
    }

    func testBroadcastEditsAreNormalizedToTheSamePostEventContract() throws {
        let packet = #"42["client.broadcast",{"type":"post.update","data":{"channel_id":23,"post_id":123}}]"#
        guard case .event(let event) = try ChatSocketFrame.parse(packet) else { return XCTFail("Expected event") }
        XCTAssertEqual(event.normalized.name, "client.post.update")
        XCTAssertEqual(event.normalized.channelID, 23)
        XCTAssertEqual(event.normalized.postID, 123)
    }

    func testMalformedEventsAndUnsafeHeartbeatIntervalsFail() {
        for frame in ["42[]", "42[1,{}]", "42[not-json]", #"0{"pingInterval":0,"pingTimeout":60000}"#] {
            XCTAssertThrowsError(try ChatSocketFrame.parse(frame))
        }
    }

    func testSocketUsesScopedCookieAndCorrectProxyPath() throws {
        let credentials = ChatSession(baseURL: URL(string: "https://chat.test:5001/proxy/?ignored=1#ignored")!, sid: "synthetic-sid", synoToken: "token&=?")
        let request = try ChatLiveConnection.request(session: credentials, version: "test-version")
        let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/proxy/sc/socket.io/")
        XCTAssertNil(url.fragment)
        let query = Dictionary(uniqueKeysWithValues: url.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["EIO"], "3")
        XCTAssertEqual(query["SynoToken"], "token&=?")
        XCTAssertNil(query["_sid"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=synthetic-sid")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://chat.test:5001")
    }

    func testSocketRejectsCookieHeaderInjection() {
        for sid in ["x\r\nInjected: yes", "x; other=value"] {
            XCTAssertThrowsError(try ChatLiveConnection.request(session: ChatSession(baseURL: URL(string: "https://chat.test")!, sid: sid, synoToken: "t"), version: "v"))
        }
    }

    func testSendResponseAndSocketReadbackDoNotDuplicateOrOverwriteNewerMessage() throws {
        func post(_ message: String, updated: Int) throws -> ChatPost {
            let data = Data("""
            {"post_id":123,"channel_id":23,"creator_id":10,"message":"\(message)","type":"normal","create_at":1000,"update_at":\(updated)}
            """.utf8)
            return try JSONDecoder().decode(ChatPost.self, from: data)
        }
        let original = try post("Original", updated: 1000)
        let edited = try post("Edited", updated: 2000)
        let merged = ChatTimeline.merge([original], [edited, original, edited])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.message, "Edited")
        XCTAssertTrue(ChatTimeline.merge([edited], [original], excluding: [edited.id]).isEmpty)
    }
}
