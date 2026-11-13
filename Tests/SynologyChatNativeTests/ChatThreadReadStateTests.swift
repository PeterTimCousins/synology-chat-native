import XCTest
@testable import SynologyChatNative

@MainActor
final class ChatThreadReadStateTests: XCTestCase {
    func testThreadChangedBeforeVisibilitySettlesDoesNotReadObsoleteThread() async throws {
        let api = ThreadReadFixture()
        let read = expectation(description: "Only the stable visible thread is read")
        api.onRead = { _, root in if root == 200 { read.fulfill() } }
        let state = ChatThreadReadState(api: api)
        defer { state.stop() }
        state.update(.init(channelID: 1, rootID: 100, lastPostID: 101))
        state.update(.init(channelID: 2, rootID: 200, lastPostID: 201))
        await fulfillment(of: [read], timeout: 2)
        XCTAssertEqual(api.roots, [200])
    }

    func testHiddenOrStoppedThreadCannotProduceReadReceipt() async throws {
        let api = ThreadReadFixture()
        let noRead = expectation(description: "Hidden and stopped threads never write")
        noRead.isInverted = true
        api.onRead = { _, _ in noRead.fulfill() }
        let state = ChatThreadReadState(api: api)
        state.update(.init(channelID: 1, rootID: 100, lastPostID: 101))
        state.update(nil)
        await Task.yield()
        state.stop()
        state.update(.init(channelID: 2, rootID: 200, lastPostID: 201))
        await fulfillment(of: [noRead], timeout: 0.25)
        XCTAssertTrue(api.roots.isEmpty)
    }

    func testSameOrOlderReplyDoesNotRepeatReceiptButNewReplyDoes() async throws {
        let api = ThreadReadFixture()
        let first = expectation(description: "Initial receipt")
        let second = expectation(description: "New reply receipt")
        api.onRead = { _, _ in if api.roots.count == 1 { first.fulfill() } else { second.fulfill() } }
        let state = ChatThreadReadState(api: api)
        defer { state.stop() }
        state.update(.init(channelID: 1, rootID: 100, lastPostID: 101))
        await fulfillment(of: [first], timeout: 2)
        state.update(.init(channelID: 1, rootID: 100, lastPostID: 101))
        state.update(.init(channelID: 1, rootID: 100, lastPostID: 100))
        await Task.yield()
        state.update(.init(channelID: 1, rootID: 100, lastPostID: 102))
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(api.roots, [100, 100])
    }
}

@MainActor
private final class ThreadReadFixture: ChatThreadReadStateAPI {
    var roots: [Int64] = []
    var onRead: ((Int64, Int64) -> Void)?
    func viewThread(channelID: Int64, rootID: Int64) async throws {
        roots.append(rootID)
        onRead?(channelID, rootID)
    }
}
