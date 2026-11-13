import XCTest
@testable import SynologyChatNative

@MainActor
final class NativeConversationBootstrapTests: XCTestCase {
    private func channel(_ id: Int64, type: String = "anonymous", name: String = "", creator: Int64? = nil) throws -> ChatChannel {
        var value: [String: Any] = ["channel_id": id, "name": name, "type": type, "encrypted": false, "unread": 0]
        if let creator { value["creator_id"] = creator }
        return try JSONDecoder().decode(ChatChannel.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testMixedMemberFailureRetainsOtherNamesAndUnknownMembership() async throws {
        let channels = try [channel(93), channel(94), channel(95)]
        var calls: [Int64] = []
        let result = try await NativeConversationBootstrap.resolve(channels: channels, names: [10: "Me", 6: "Peter", 7: "Jane"], currentUserID: 10) { id in
            calls.append(id)
            if id == 94 { throw URLError(.timedOut) }
            return id == 93 ? [10, 6] : [7, 10]
        }
        XCTAssertEqual(calls, [93, 94, 95])
        XCTAssertEqual(result.titles[93], "Peter")
        XCTAssertEqual(result.titles[94], "Conversation 94 (members unavailable)")
        XCTAssertEqual(result.titles[95], "Jane")
        XCTAssertEqual(result.memberIDs[93], [10, 6])
        XCTAssertEqual(result.memberIDs[95], [7, 10])
        XCTAssertNil(result.memberIDs[94], "A failed read must not fabricate authoritative empty membership")
        XCTAssertEqual(result.unavailableMemberChannelIDs, [94])
    }

    func testNamedChannelsAndKnownBotsDoNotNeedMemberLookup() async throws {
        let channels = try [channel(1, type: "public", name: "General"), channel(90, type: "chatbot", creator: 8), channel(93)]
        var calls: [Int64] = []
        let result = try await NativeConversationBootstrap.resolve(channels: channels, names: [8: "Calendar"], currentUserID: 10) { id in
            calls.append(id); return []
        }
        XCTAssertEqual(calls, [93])
        XCTAssertEqual(result.titles[90], "Calendar")
        XCTAssertNil(result.titles[1])
        XCTAssertEqual(result.memberIDs[93], [], "A successfully returned empty list is distinct from a failed lookup")
        XCTAssertTrue(result.unavailableMemberChannelIDs.isEmpty)
    }

    func testReconnectCanReplaceUnavailableLabelWithCanonicalNames() async throws {
        let channels = try [channel(93)]
        let first = try await NativeConversationBootstrap.resolve(channels: channels, names: [6: "Peter"], currentUserID: 10) { _ in throw ChatAPIError.server(117) }
        XCTAssertEqual(first.unavailableMemberChannelIDs, [93])
        let second = try await NativeConversationBootstrap.resolve(channels: channels, names: [6: "Peter"], currentUserID: 10) { _ in [10, 6] }
        XCTAssertEqual(second.titles[93], "Peter")
        XCTAssertEqual(second.memberIDs[93], [10, 6])
        XCTAssertTrue(second.unavailableMemberChannelIDs.isEmpty)
    }

    func testAuthenticationAndIncompatibleAPIFailWithoutReadingLaterChannels() async throws {
        let errors: [Error] = [ChatAPIError.server(105), ChatAPIError.server(106), ChatAPIError.server(107), ChatAPIError.server(119), ChatAPIError.http(401), ChatAPIError.http(403), ChatAPIError.unsupportedAPI, ChatAPIError.invalidServer, ChatAPIError.connection]
        for error in errors {
            var calls: [Int64] = []
            do {
                _ = try await NativeConversationBootstrap.resolve(channels: try [channel(93), channel(94)], names: [:], currentUserID: 10) { id in
                    calls.append(id); throw error
                }
                XCTFail("Authentication or compatibility error must fail startup")
            } catch { }
            XCTAssertEqual(calls, [93])
        }
    }

    func testCancelledAndTLSFailuresCannotBeDowngradedToMissingNames() {
        for error: Error in [CancellationError(), URLError(.cancelled), URLError(.secureConnectionFailed), URLError(.serverCertificateUntrusted), URLError(.serverCertificateHasUnknownRoot), URLError(.clientCertificateRequired), URLError(.appTransportSecurityRequiresSecureConnection), URLError(.userAuthenticationRequired)] {
            XCTAssertFalse(NativeConversationBootstrap.canDeferMemberFailure(error))
        }
        for error: Error in [URLError(.timedOut), URLError(.notConnectedToInternet), ChatAPIError.server(404), ChatAPIError.server(117), ChatAPIError.invalidResponse] {
            XCTAssertTrue(NativeConversationBootstrap.canDeferMemberFailure(error))
        }
    }

    func testAccountChangeDuringSuccessfulOrFailedReadCannotPublishFallback() async throws {
        for fail in [false, true] {
            var stale = false, calls = 0
            do {
                _ = try await NativeConversationBootstrap.resolve(channels: try [channel(93), channel(94)], names: [6: "Peter"], currentUserID: 10, members: { _ in
                    calls += 1; stale = true
                    if fail { throw URLError(.timedOut) }
                    return [10, 6]
                }, checkCurrent: { if stale { throw CancellationError() } })
                XCTFail("Account-stale results must fail before any snapshot is returned")
            } catch is CancellationError { }
            XCTAssertEqual(calls, 1)
        }
    }

    func testCancelledTaskBeforeEmptyCatalogueCannotReturnSnapshot() async throws {
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await NativeConversationBootstrap.resolve(channels: [], names: [:], currentUserID: 10) { _ in [] }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError { }
    }
}
