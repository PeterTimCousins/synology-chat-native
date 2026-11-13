import XCTest
@testable import SynologyChatNative

@MainActor
final class ChatReadStateTests: XCTestCase {
    func testDelayedEnterCannotMarkAnObsoleteChannelReadOrLeaveTheNewChannel() async throws {
        let api = ReadStateFixture()
        api.pauseFirstEnter = true
        let entered = expectation(description: "First enter is in flight")
        let latestRead = expectation(description: "Only the current target is marked read")
        api.onEnter = { id in if id == 1 { entered.fulfill() } }
        api.onView = { id, _ in if id == 2 { latestRead.fulfill() } }
        let state = ChatReadState(api: api, connectionID: "synthetic-connection")
        defer { state.stop() }
        state.update(.init(channelID: 1, timestamp: 100))
        await fulfillment(of: [entered], timeout: 1)
        state.update(.init(channelID: 2, timestamp: 200))
        api.releaseEnter()
        await fulfillment(of: [latestRead], timeout: 1)
        XCTAssertEqual(api.operations, ["enter:1", "leave", "enter:2", "view:2:200"])
    }

    func testReadCursorOnlyMovesForwardAndHiddenTargetLeavesChannel() async throws {
        let api = ReadStateFixture()
        let first = expectation(description: "First read")
        let next = expectation(description: "Advanced read")
        let left = expectation(description: "No longer visible")
        api.onView = { _, timestamp in
            if timestamp == 200 { first.fulfill() }
            if timestamp == 300 { next.fulfill() }
        }
        api.onLeave = { left.fulfill() }
        let state = ChatReadState(api: api, connectionID: "synthetic-connection")
        defer { state.stop() }
        state.update(.init(channelID: 1, timestamp: 200))
        await fulfillment(of: [first], timeout: 1)
        state.update(.init(channelID: 1, timestamp: 200))
        state.update(.init(channelID: 1, timestamp: 100))
        await Task.yield()
        state.update(.init(channelID: 1, timestamp: 300))
        await fulfillment(of: [next], timeout: 1)
        state.update(nil)
        await fulfillment(of: [left], timeout: 1)
        XCTAssertEqual(api.operations, ["enter:1", "view:1:200", "view:1:300", "leave"])
    }

    func testStoppingDuringEnterPreventsLaterReadAndRejectsStaleVisibilityUpdates() async throws {
        let api = ReadStateFixture()
        api.pauseFirstEnter = true
        let entered = expectation(description: "Pending enter")
        api.onEnter = { _ in entered.fulfill() }
        let state = ChatReadState(api: api, connectionID: "synthetic-connection")
        state.update(.init(channelID: 1, timestamp: 100))
        await fulfillment(of: [entered], timeout: 1)
        state.stop()
        state.update(.init(channelID: 2, timestamp: 200))
        api.releaseEnter()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(api.operations, ["enter:1"])
    }
}

@MainActor
private final class ReadStateFixture: ChatReadStateAPI {
    var operations: [String] = []
    var pauseFirstEnter = false
    var onEnter: ((Int64) -> Void)?
    var onView: ((Int64, Int64) -> Void)?
    var onLeave: (() -> Void)?
    private var gate: CheckedContinuation<Void, Never>?

    func enterChannel(_ id: Int64, connectionID: String) async throws {
        XCTAssertEqual(connectionID, "synthetic-connection")
        operations.append("enter:\(id)")
        if pauseFirstEnter {
            pauseFirstEnter = false
            await withCheckedContinuation { gate = $0; onEnter?(id) }
        } else { onEnter?(id) }
    }
    func releaseEnter() { gate?.resume(); gate = nil }
    func leaveChannel(connectionID: String) async throws {
        XCTAssertEqual(connectionID, "synthetic-connection")
        operations.append("leave"); onLeave?()
    }
    func viewChannel(_ id: Int64, through timestamp: Int64, connectionID: String) async throws {
        XCTAssertEqual(connectionID, "synthetic-connection")
        operations.append("view:\(id):\(timestamp)"); onView?(id, timestamp)
    }
}
