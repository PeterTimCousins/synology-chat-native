import XCTest
@testable import SynologyChatNative

final class ChatReactionDetailsTests: XCTestCase {
    private func details(_ raw: String) throws -> ChatReactionDetails {
        ChatReactionDetails(try JSONDecoder().decode([ChatReaction].self, from: Data(raw.utf8)))
    }
    func testPeopleKeepServerOrderAndCollectTheirEmoji() throws {
        let d = try details(#"[{"sticker_name":"heart","user_ids":[20,10]},{"sticker_name":"eyes","user_ids":[10,30]}]"#)
        XCTAssertEqual(d.people().map(\.id), [20,10,30])
        XCTAssertEqual(d.people()[1].reactionNames, ["heart","eyes"])
        XCTAssertEqual(d.reactionCount, 4)
        XCTAssertEqual(d.people(reaction: "eyes").map(\.id), [10,30])
        XCTAssertEqual(d.people(reaction: "eyes")[0].reactionNames, ["eyes"])
    }
    func testDuplicateGroupsAndIDsDoNotInflateCounts() throws {
        let d = try details(#"[{"sticker_name":"heart","user_ids":[10,10,-1,0]},{"sticker_name":"heart","user_ids":[20,10]},{"sticker_name":"eyes","user_ids":[]},{"sticker_name":"","user_ids":[40]}]"#)
        XCTAssertEqual(d.groups, [.init(id: "heart", userIDs: [10,20])])
        XCTAssertEqual(d.reactionCount, 2)
    }
    func testUnknownEmojiAndUnavailableUsersRetainIdentity() throws {
        let d = try details(#"[{"sticker_name":"future_variant","user_ids":[99999]}]"#)
        XCTAssertEqual(d.people(), [.init(id: 99999, reactionNames: ["future_variant"])])
        XCTAssertEqual(d.people(reaction: "gone"), [])
    }
    func testEmptyDetailsAreValid() {
        let d = ChatReactionDetails([])
        XCTAssertTrue(d.groups.isEmpty); XCTAssertTrue(d.people().isEmpty); XCTAssertEqual(d.reactionCount, 0)
    }
}

@MainActor final class NativeReactionDetailsStoreTests: XCTestCase {
    func testClearDiscardsUncooperativeLateResult() async {
        let store = NativeReactionDetailsStore()
        var resume: CheckedContinuation<ChatReactionDetails, Never>?
        store.load { await withCheckedContinuation { resume = $0 } }
        while resume == nil { await Task.yield() }
        let old = store.task
        store.clear(); resume?.resume(returning: .init([])); await old?.value
        XCTAssertNil(store.details); XCTAssertNil(store.updatedAt); XCTAssertFalse(store.loading); XCTAssertNil(store.failure)
    }
    func testFailureCanRetryAndReplaceState() async {
        let store = NativeReactionDetailsStore()
        store.load { throw ChatAPIError.invalidResponse }; await store.task?.value
        XCTAssertNotNil(store.failure); XCTAssertNil(store.details); XCTAssertFalse(store.loading)
        store.load { .init([]) }; await store.task?.value
        XCTAssertNotNil(store.details); XCTAssertNotNil(store.updatedAt); XCTAssertNil(store.failure)
    }
    func testSupersededRequestCannotOverwriteNewDetails() async {
        let store = NativeReactionDetailsStore()
        var resume: CheckedContinuation<ChatReactionDetails, Never>?
        store.load { await withCheckedContinuation { resume = $0 } }
        while resume == nil { await Task.yield() }
        let old = store.task
        let current = ChatReactionDetails([try! JSONDecoder().decode(ChatReaction.self, from: Data(#"{"sticker_name":"heart","user_ids":[10]}"#.utf8))])
        store.load { current }; await store.task?.value
        resume?.resume(returning: .init([])); await old?.value
        XCTAssertEqual(store.details, current); XCTAssertFalse(store.loading)
    }
}
