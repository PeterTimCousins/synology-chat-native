import XCTest
@testable import SynologyChatNative

@MainActor final class ChatReadReceiptRetryTests: XCTestCase {
    private let connection = "synthetic-receipt-connection"
    private let mainTarget = ChatReadState.Target(channelID: 1, timestamp: 100)
    private let threadTarget = ChatThreadReadState.Target(channelID: 1, rootID: 100, lastPostID: 101)

    func testMainTransportFailureRetriesWithoutOptimisticCursorOrDuplicateReadCallback() async throws {
        let api = ReceiptRetryAPI(), clock = ReceiptRetryClock(), waiting = expectation(description: "Backoff"), read = expectation(description: "Confirmed read")
        api.mainErrors = [ChatAPIError.connection]; clock.onWait = { waiting.fulfill() }
        let state = ChatReadState(api: api, connectionID: connection, retrySleep: clock.sleep)
        defer { state.stop() }
        var callbacks: [Int64] = []; state.onRead = { callbacks.append($0); read.fulfill() }
        state.update(mainTarget); await fulfillment(of: [waiting], timeout: 2)
        XCTAssertTrue(callbacks.isEmpty); XCTAssertEqual(api.mainAttempts, [ReceiptRetryAPI.Attempt((1, 100))])
        clock.releaseNext(); await fulfillment(of: [read], timeout: 2)
        state.update(mainTarget); state.update(.init(channelID: 1, timestamp: 99))
        await Task.yield()
        XCTAssertEqual(callbacks, [1]); XCTAssertEqual(api.mainAttempts.count, 2)
        XCTAssertEqual(api.connections, [connection, connection, connection])
        XCTAssertEqual(clock.delays, [0.5])
    }

    func testMainSwitchDuringBackoffRetiresOldRetryAndSerializesLeaveEnter() async throws {
        let api = ReceiptRetryAPI(), clock = ReceiptRetryClock(), waiting = expectation(description: "Old target backoff"), read = expectation(description: "New target confirmed")
        api.mainErrors = [URLError(.timedOut)]; clock.onWait = { waiting.fulfill() }
        let state = ChatReadState(api: api, connectionID: connection, retrySleep: clock.sleep)
        defer { state.stop() }
        var callbacks: [Int64] = []; state.onRead = { callbacks.append($0); read.fulfill() }
        state.update(mainTarget); await fulfillment(of: [waiting], timeout: 2)
        state.update(.init(channelID: 2, timestamp: 200)); await fulfillment(of: [read], timeout: 2)
        XCTAssertEqual(api.operations, ["enter:1", "view:1:100", "leave", "enter:2", "view:2:200"])
        XCTAssertEqual(callbacks, [2]); XCTAssertEqual(clock.pendingCount, 0)
    }

    func testMainHideOrStopDuringBackoffCannotRetryOldTarget() async throws {
        for stop in [false, true] {
            let api = ReceiptRetryAPI(), clock = ReceiptRetryClock(), waiting = expectation(description: "Backoff before visibility change"), noRead = expectation(description: "No hidden receipt")
            noRead.isInverted = true; api.mainErrors = [ChatAPIError.connection]; clock.onWait = { waiting.fulfill() }
            let state = ChatReadState(api: api, connectionID: connection, retrySleep: clock.sleep)
            state.onRead = { _ in noRead.fulfill() }
            state.update(mainTarget); await fulfillment(of: [waiting], timeout: 2)
            if stop { state.stop(); state.update(.init(channelID: 2, timestamp: 200)) } else { state.update(nil) }
            await fulfillment(of: [noRead], timeout: 0.04)
            XCTAssertEqual(api.mainAttempts.count, 1); XCTAssertEqual(clock.pendingCount, 0)
            XCTAssertEqual(api.operations, stop ? ["enter:1", "view:1:100"] : ["enter:1", "view:1:100", "leave"])
            state.stop()
        }
    }

    func testMainHideThenShowSameTargetGetsFreshBudgetRatherThanCancelledOldWait() async throws {
        let api = ReceiptRetryAPI(), clock = ReceiptRetryClock(), first = expectation(description: "First backoff"), second = expectation(description: "New visibility backoff"), read = expectation(description: "Same target confirmed after return")
        api.mainErrors = [ChatAPIError.connection, ChatAPIError.connection]
        clock.onWait = { if clock.delays.count == 1 { first.fulfill() } else { second.fulfill() } }
        let state = ChatReadState(api: api, connectionID: connection, retryDelays: [0], retrySleep: clock.sleep)
        defer { state.stop() }; state.onRead = { _ in read.fulfill() }
        state.update(mainTarget); await fulfillment(of: [first], timeout: 2)
        state.update(nil); state.update(mainTarget)
        await fulfillment(of: [second], timeout: 2)
        clock.releaseNext(); await fulfillment(of: [read], timeout: 2)
        XCTAssertEqual(api.mainAttempts.count, 3); XCTAssertEqual(clock.delays.count, 2)
    }

    func testMainRetryBudgetIsCappedAndSameTargetUpdatesCannotRestartIt() async throws {
        let api = ReceiptRetryAPI(), exhausted = expectation(description: "Fourth failed attempt"), read = expectation(description: "New target can recover")
        api.mainErrors = Array(repeating: ChatAPIError.connection, count: 4)
        api.onMainAttempt = { if api.mainAttempts.count == 4 { exhausted.fulfill() } }
        var delays: [TimeInterval] = []
        let state = ChatReadState(api: api, connectionID: connection, retryDelays: [0, 0, 0, 0, 0], retrySleep: { delays.append($0) })
        defer { state.stop() }; var callbacks = 0; state.onRead = { _ in callbacks += 1; read.fulfill() }
        state.update(mainTarget); await fulfillment(of: [exhausted], timeout: 2)
        for _ in 0..<20 { state.update(mainTarget) }
        await Task.yield(); await Task.yield()
        XCTAssertEqual(api.mainAttempts.count, 4); XCTAssertEqual(delays.count, 3); XCTAssertEqual(callbacks, 0)
        state.update(.init(channelID: 1, timestamp: 200)); await fulfillment(of: [read], timeout: 2)
        XCTAssertEqual(callbacks, 1); XCTAssertEqual(api.mainAttempts.count, 5)
    }

    func testServerAuthAndUnprovenHTTPOrServerCodesDoNotRetryOrHotLoop() async throws {
        for error: Error in [ChatAPIError.server(106), ChatAPIError.server(117), ChatAPIError.http(503), ChatAPIError.invalidResponse, URLError(.serverCertificateUntrusted)] {
            let api = ReceiptRetryAPI(), attempt = expectation(description: "One permanent attempt"), noRetry = expectation(description: "No backoff for unproven transient code"), noRead = expectation(description: "No successful duplicate")
            noRetry.isInverted = true; noRead.isInverted = true
            api.mainErrors = [error]; api.onMainAttempt = { attempt.fulfill() }
            let state = ChatReadState(api: api, connectionID: connection, retrySleep: { _ in noRetry.fulfill() })
            state.onRead = { _ in noRead.fulfill() }; state.update(mainTarget)
            await fulfillment(of: [attempt], timeout: 2)
            api.onMainAttempt = nil
            for _ in 0..<20 { state.update(mainTarget) }
            await fulfillment(of: [noRetry, noRead], timeout: 0.03)
            XCTAssertEqual(api.mainAttempts.count, 1); state.stop()
        }
    }

    func testThreadTransportFailureRetriesOnlyUntilSuccessfulCanonicalReceipt() async throws {
        let api = ReceiptRetryAPI(), clock = ReceiptRetryClock(), waiting = expectation(description: "Thread backoff"), read = expectation(description: "Thread confirmed")
        api.threadErrors = [URLError(.networkConnectionLost)]; clock.onWait = { waiting.fulfill() }
        let state = ChatThreadReadState(api: api, retrySleep: clock.sleep)
        defer { state.stop() }; var callbacks: [Int64] = []; state.onRead = { callbacks.append($0); read.fulfill() }
        state.update(threadTarget); await fulfillment(of: [waiting], timeout: 2)
        XCTAssertTrue(callbacks.isEmpty)
        clock.releaseNext(); await fulfillment(of: [read], timeout: 2)
        state.update(threadTarget); await Task.yield()
        XCTAssertEqual(api.threadAttempts, [100, 100]); XCTAssertEqual(callbacks, [1])
    }

    func testThreadSwitchDuringBackoffCannotReadOldRootAgain() async throws {
        let api = ReceiptRetryAPI(), clock = ReceiptRetryClock(), waiting = expectation(description: "Old thread backoff"), read = expectation(description: "New thread confirmed")
        api.threadErrors = [ChatAPIError.connection]; clock.onWait = { waiting.fulfill() }
        let state = ChatThreadReadState(api: api, retrySleep: clock.sleep)
        defer { state.stop() }; var callbacks: [Int64] = []; state.onRead = { callbacks.append($0); read.fulfill() }
        state.update(threadTarget); await fulfillment(of: [waiting], timeout: 2)
        state.update(.init(channelID: 2, rootID: 200, lastPostID: 201))
        await fulfillment(of: [read], timeout: 2)
        XCTAssertEqual(api.threadAttempts, [100, 200]); XCTAssertEqual(callbacks, [2]); XCTAssertEqual(clock.pendingCount, 0)
    }

    func testThreadHideAndStopDuringBackoffCancelPendingReceipt() async throws {
        for stop in [false, true] {
            let api = ReceiptRetryAPI(), clock = ReceiptRetryClock(), waiting = expectation(description: "Thread backoff before hide"), noRead = expectation(description: "No hidden thread receipt")
            noRead.isInverted = true; api.threadErrors = [ChatAPIError.connection]; clock.onWait = { waiting.fulfill() }
            let state = ChatThreadReadState(api: api, retrySleep: clock.sleep)
            state.onRead = { _ in noRead.fulfill() }; state.update(threadTarget)
            await fulfillment(of: [waiting], timeout: 2)
            if stop { state.stop(); state.update(.init(channelID: 2, rootID: 200, lastPostID: 201)) } else { state.update(nil) }
            await fulfillment(of: [noRead], timeout: 0.04)
            XCTAssertEqual(api.threadAttempts, [100]); XCTAssertEqual(clock.pendingCount, 0); state.stop()
        }
    }

    func testThreadHideAndShowSameRootUsesFreshVisibilityRevision() async throws {
        let api = ReceiptRetryAPI(), clock = ReceiptRetryClock(), first = expectation(description: "Old thread backoff"), second = expectation(description: "Returned thread backoff"), read = expectation(description: "Returned thread confirmed")
        api.threadErrors = [ChatAPIError.connection, ChatAPIError.connection]
        clock.onWait = { if clock.delays.count == 1 { first.fulfill() } else { second.fulfill() } }
        let state = ChatThreadReadState(api: api, retryDelays: [0], retrySleep: clock.sleep)
        defer { state.stop() }; state.onRead = { _ in read.fulfill() }
        state.update(threadTarget); await fulfillment(of: [first], timeout: 2)
        state.update(nil); state.update(threadTarget)
        await fulfillment(of: [second], timeout: 2)
        clock.releaseNext(); await fulfillment(of: [read], timeout: 2)
        XCTAssertEqual(api.threadAttempts, [100, 100, 100])
    }

    func testThreadExhaustionAndPermanentFailureStayBlockedUntilTargetChanges() async throws {
        for permanent in [false, true] {
            let api = ReceiptRetryAPI(), done = expectation(description: "Thread failed attempt"), recovered = expectation(description: "New reply target recovered")
            let expected = permanent ? 1 : 3
            api.threadErrors = permanent ? [ChatAPIError.server(119)] : Array(repeating: ChatAPIError.connection, count: expected)
            api.onThreadAttempt = { if api.threadAttempts.count == expected { done.fulfill() } }
            var delays = 0
            let state = ChatThreadReadState(api: api, retryDelays: [0, 0], retrySleep: { _ in delays += 1 })
            defer { state.stop() }; var callbacks = 0; state.onRead = { _ in callbacks += 1; recovered.fulfill() }
            state.update(threadTarget); await fulfillment(of: [done], timeout: 2)
            for _ in 0..<20 { state.update(threadTarget) }
            await Task.yield(); await Task.yield()
            XCTAssertEqual(api.threadAttempts.count, expected); XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(delays, permanent ? 0 : 2)
            state.update(.init(channelID: 1, rootID: 100, lastPostID: 102))
            await fulfillment(of: [recovered], timeout: 2)
            XCTAssertEqual(callbacks, 1); XCTAssertEqual(api.threadAttempts.count, expected + 1)
        }
    }
}

@MainActor private final class ReceiptRetryAPI: ChatReadStateAPI, ChatThreadReadStateAPI {
    struct Attempt: Equatable {
        let channelID: Int64
        let timestamp: Int64
        init(_ value: (Int64, Int64)) { channelID = value.0; timestamp = value.1 }
    }
    var mainErrors: [Error] = [], threadErrors: [Error] = []
    var operations: [String] = [], connections: [String] = [], threadAttempts: [Int64] = []
    var mainAttempts: [Attempt] = []
    var onMainAttempt: (() -> Void)?, onThreadAttempt: (() -> Void)?
    func enterChannel(_ id: Int64, connectionID: String) async throws { operations.append("enter:\(id)"); connections.append(connectionID) }
    func leaveChannel(connectionID: String) async throws { operations.append("leave"); connections.append(connectionID) }
    func viewChannel(_ id: Int64, through timestamp: Int64, connectionID: String) async throws {
        operations.append("view:\(id):\(timestamp)"); mainAttempts.append(.init((id, timestamp))); connections.append(connectionID); onMainAttempt?()
        if !mainErrors.isEmpty { throw mainErrors.removeFirst() }
    }
    func viewThread(channelID: Int64, rootID: Int64) async throws {
        threadAttempts.append(rootID); onThreadAttempt?()
        if !threadErrors.isEmpty { throw threadErrors.removeFirst() }
    }
}

@MainActor private final class ReceiptRetryClock {
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var order: [UUID] = []
    var delays: [TimeInterval] = []
    var onWait: (() -> Void)?
    var pendingCount: Int { continuations.count }
    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID(); delays.append(delay)
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation; order.append(id); onWait?()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } })
    }
    func releaseNext() {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let continuation = continuations.removeValue(forKey: id) { continuation.resume(); return }
        }
    }
    private func cancel(_ id: UUID) { continuations.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
