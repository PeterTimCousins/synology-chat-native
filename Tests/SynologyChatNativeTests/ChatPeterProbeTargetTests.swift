import XCTest
@testable import SynologyChatNative

final class ChatPeterProbeTargetTests: XCTestCase {
    private func user(_ id: Int64, _ name: String) throws -> ChatUser {
        try JSONDecoder().decode(ChatUser.self, from: JSONSerialization.data(withJSONObject: ["user_id": id, "username": name, "nickname": "Any renamed display"]))
    }
    private func channel(_ id: Int64 = 93, encrypted: Bool = false) throws -> ChatChannel {
        try JSONDecoder().decode(ChatChannel.self, from: JSONSerialization.data(withJSONObject: ["channel_id": id, "name": "Any renamed display", "type": "anonymous", "encrypted": encrypted, "is_joined": true, "unread": 0]))
    }
    func testBothVerifiedRolesResolveWithoutDependingOnDisplayName() throws {
        let users = try [user(6, "Peter"), user(10, "PeterCousins")]
        XCTAssertEqual(try ChatPeterProbeTarget.resolve(username: "peter", users: users, channels: [channel()], members: [10, 6]), .init(ownerID: 6, peerID: 10))
        XCTAssertEqual(try ChatPeterProbeTarget.resolve(username: "PeterCousins", users: users, channels: [channel()], members: [6, 10]), .init(ownerID: 10, peerID: 6))
    }
    func testChangedAudienceDuplicateIdentityAndWrongConversationReject() throws {
        let users = try [user(6, "Peter"), user(10, "PeterCousins"), user(11, "Unrelated")]
        for members: [Int64] in [[6, 11], [6, 10, 11], [6, 6], [], [10]] {
            XCTAssertThrowsError(try ChatPeterProbeTarget.resolve(username: "Peter", users: users, channels: [channel()], members: members))
        }
        XCTAssertThrowsError(try ChatPeterProbeTarget.resolve(username: "Unrelated", users: users, channels: [channel()], members: [6, 10]))
        XCTAssertThrowsError(try ChatPeterProbeTarget.resolve(username: "Peter", users: users + [user(6, "duplicate")], channels: [channel()], members: [6, 10]))
        XCTAssertThrowsError(try ChatPeterProbeTarget.resolve(username: "Peter", users: users, channels: [channel(94)], members: [6, 10]))
        XCTAssertThrowsError(try ChatPeterProbeTarget.resolve(username: "Peter", users: users, channels: [channel(encrypted: true)], members: [6, 10]))
    }
}
