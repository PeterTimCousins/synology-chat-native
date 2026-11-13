import XCTest
import AppKit
@testable import SynologyChatNative

@MainActor
final class ChatReconnectTests: XCTestCase {
    private let session = ChatSession(baseURL: URL(string: "https://chat.example.test")!, sid: "synthetic", synoToken: "synthetic")

    func testLateOldPresenceCompletionCannotReleaseReplacementPresenceTask() async throws {
        let firstHeld = expectation(description: "Old socket presence held")
        let replacementHeld = expectation(description: "Replacement socket presence held")
        let oldReturned = expectation(description: "Old send returns after replacement")
        let premature = expectation(description: "Replacement presence must stay serialized")
        premature.isInverted = true
        let corrected = expectation(description: "Latest presence follows replacement acknowledgement")
        var oldResume: CheckedContinuation<Void, Never>?
        var replacementResume: CheckedContinuation<Void, Never>?
        var releasedReplacement = false
        var sockets: [SyntheticSocket] = []
        let live = ChatLiveConnection(session: session, version: "test", makeSocket: { _ in
            let index = sockets.count
            let socket = SyntheticSocket(id: "socket-\(index)")
            socket.onSend = { text in
                if text == "42[\"client.user.activate\"]" {
                    if index == 0 {
                        await withCheckedContinuation { oldResume = $0; firstHeld.fulfill() }
                        oldReturned.fulfill()
                    } else {
                        await withCheckedContinuation { replacementResume = $0; replacementHeld.fulfill() }
                    }
                } else if index == 1, text == "42[\"client.user.deactivate\"]" {
                    if releasedReplacement { corrected.fulfill() } else { premature.fulfill() }
                }
            }
            sockets.append(socket); return socket
        }, retryDelay: { _ in 0.001 })
        defer { live.stop() }
        live.setUserActive(true); live.start()
        await fulfillment(of: [firstHeld], timeout: 1)
        sockets[0].fail()
        await fulfillment(of: [replacementHeld], timeout: 1)
        oldResume?.resume()
        await fulfillment(of: [oldReturned], timeout: 1)
        live.setUserActive(false)
        await fulfillment(of: [premature], timeout: 0.05)
        releasedReplacement = true
        replacementResume?.resume()
        await fulfillment(of: [corrected], timeout: 1)
        XCTAssertEqual(sockets[1].sent.filter { $0.contains("deactivate") }.count, 1)
        XCTAssertEqual(live.connectionID, "socket-1")
    }

    func testStoppedHandshakeCannotPublishLiveAfterDelayedAcknowledgement() async throws {
        let started = expectation(description: "Handshake acknowledgement held")
        let lateReady = expectation(description: "Stopped handshake must not publish ready")
        lateReady.isInverted = true
        var resume: CheckedContinuation<Void, Never>?
        var statuses: [ChatLiveStatus] = []
        let socket = SyntheticSocket(id: "old")
        socket.onSend = { text in
            if text == "42[\"client.initdone\"]" {
                await withCheckedContinuation { resume = $0; started.fulfill() }
            }
        }
        let live = ChatLiveConnection(session: session, version: "test", makeSocket: { _ in socket })
        defer { live.stop() }
        live.onStatus = { statuses.append($0) }
        live.onReady = { lateReady.fulfill() }
        live.start()
        await fulfillment(of: [started], timeout: 1)
        XCTAssertNil(live.connectionID, "An unacknowledged handshake is not a usable connection")
        live.stop()
        resume?.resume()
        await fulfillment(of: [lateReady], timeout: 0.05)
        XCTAssertNil(live.connectionID)
        XCTAssertEqual(statuses.last, .offline)
        XCTAssertFalse(statuses.contains(.live))
    }

    func testOldAcknowledgementCannotRepublishReadyAfterReplacementHandshake() async throws {
        let started = expectation(description: "Old acknowledgement held")
        let replacement = expectation(description: "Replacement acknowledged")
        let extraReady = expectation(description: "Old acknowledgement must not trigger another resync")
        extraReady.isInverted = true
        var resume: CheckedContinuation<Void, Never>?
        var sockets: [SyntheticSocket] = []
        var readyCount = 0
        var liveCount = 0
        let live = ChatLiveConnection(session: session, version: "test", makeSocket: { _ in
            let socket = SyntheticSocket(id: "connection-\(sockets.count)")
            if sockets.isEmpty {
                socket.onSend = { text in
                    if text == "42[\"client.initdone\"]" {
                        await withCheckedContinuation { resume = $0; started.fulfill() }
                    }
                }
            }
            sockets.append(socket); return socket
        })
        defer { live.stop() }
        live.onStatus = { if $0 == .live { liveCount += 1 } }
        live.onReady = {
            readyCount += 1
            if readyCount == 1 { replacement.fulfill() } else { extraReady.fulfill() }
        }
        live.start()
        await fulfillment(of: [started], timeout: 1)
        live.start()
        await fulfillment(of: [replacement], timeout: 1)
        XCTAssertEqual(live.connectionID, "connection-1")
        resume?.resume()
        await fulfillment(of: [extraReady], timeout: 0.05)
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(liveCount, 1)
        XCTAssertEqual(live.connectionID, "connection-1")
        XCTAssertTrue(sockets[0].cancelled)
    }

    func testTransportFailureEstablishesNewConnectionAndResyncCallback() async throws {
        var sockets: [SyntheticSocket] = []
        let live = ChatLiveConnection(session: session, version: "test", makeSocket: { _ in
            let socket = SyntheticSocket(id: "connection-\(sockets.count)")
            sockets.append(socket)
            return socket
        }, retryDelay: { _ in 0.001 })
        defer { live.stop() }
        let replacement = expectation(description: "Replacement connection ready for authoritative resync")
        var ready = 0
        var statuses: [ChatLiveStatus] = []
        live.onStatus = { statuses.append($0) }
        live.onReady = {
            ready += 1
            if ready == 1 { sockets[0].fail() }
            if ready == 2 { replacement.fulfill() }
        }
        live.start()
        await fulfillment(of: [replacement], timeout: 2)
        XCTAssertEqual(live.connectionID, "connection-1")
        XCTAssertEqual(sockets.count, 2)
        XCTAssertTrue(sockets[0].cancelled)
        XCTAssertTrue(statuses.contains(.reconnecting))
        XCTAssertEqual(sockets[1].sent.first, "42[\"client.initdone\"]")
    }

    func testStopDoesNotReconnectAndLateOldFramesCannotReplaceNewSession() async throws {
        var sockets: [SyntheticSocket] = []
        let live = ChatLiveConnection(session: session, version: "test", makeSocket: { _ in
            let socket = SyntheticSocket(id: "connection-\(sockets.count)")
            sockets.append(socket)
            return socket
        }, retryDelay: { _ in 0.001 })
        defer { live.stop() }
        let first = expectation(description: "First connection")
        live.onReady = { first.fulfill() }
        live.start()
        await fulfillment(of: [first], timeout: 2)
        live.stop()
        XCTAssertNil(live.connectionID)
        let second = expectation(description: "New explicit connection")
        live.onReady = { second.fulfill() }
        live.start()
        sockets[0].emit("42[\"client.init\",{\"id\":\"stale\"}]")
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(live.connectionID, "connection-1")
        live.stop()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sockets.count, 2)
        XCTAssertNil(live.connectionID)
    }

    func testForegroundStateIsSentAfterInitAndRestoredAfterReconnect() async throws {
        var sockets: [SyntheticSocket] = []
        let live = ChatLiveConnection(session: session, version: "test", makeSocket: { _ in
            let socket = SyntheticSocket(id: "connection-\(sockets.count)")
            sockets.append(socket); return socket
        }, retryDelay: { _ in 0.001 })
        defer { live.stop() }
        live.setUserActive(true)
        live.start()
        for _ in 0..<100 where sockets.first?.sent.last != "42[\"client.user.activate\"]" {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(sockets.first?.sent, ["42[\"client.initdone\"]", "42[\"client.user.activate\"]"])
        live.setUserActive(false)
        live.setUserActive(false)
        for _ in 0..<100 where sockets.first?.sent.last != "42[\"client.user.deactivate\"]" {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(sockets.first?.sent.filter { $0.contains("deactivate") }.count, 1)
        sockets[0].fail()
        for _ in 0..<100 where sockets.count < 2 || sockets.last?.sent.last != "42[\"client.user.deactivate\"]" {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(sockets.last?.sent, ["42[\"client.initdone\"]", "42[\"client.user.deactivate\"]"])
    }

    func testSleepPausesConnectionAndWakeCreatesFreshHandshakeAndResync() async throws {
        let center = NotificationCenter()
        var sockets: [SyntheticSocket] = []
        let live = ChatLiveConnection(session: session, version: "test", makeSocket: { _ in
            let socket = SyntheticSocket(id: "connection-\(sockets.count)")
            sockets.append(socket); return socket
        }, sleepNotifications: center, retryDelay: { _ in 0.001 })
        defer { live.stop() }
        let first = expectation(description: "Initial connection")
        live.onReady = { first.fulfill() }
        live.setUserActive(false)
        live.start()
        await fulfillment(of: [first], timeout: 2)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertTrue(sockets[0].cancelled)
        XCTAssertNil(live.connectionID)
        // Duplicate sleep notifications must not lose the intent to reconnect.
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        let replacement = expectation(description: "Fresh wake handshake invokes resync")
        live.onReady = { replacement.fulfill() }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        sockets[0].emit("42[\"client.init\",{\"id\":\"stale\"}]")
        await fulfillment(of: [replacement], timeout: 2)
        for _ in 0..<100 where sockets.last?.sent.last != "42[\"client.user.deactivate\"]" { await Task.yield() }
        XCTAssertEqual(live.connectionID, "connection-1")
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets.last?.sent, ["42[\"client.initdone\"]", "42[\"client.user.deactivate\"]"])
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(sockets.count, 2, "Duplicate wake must not start another socket")
    }

    func testExplicitStopDuringSleepCannotBeReversedByWake() async throws {
        let center = NotificationCenter()
        var sockets: [SyntheticSocket] = []
        let live = ChatLiveConnection(session: session, version: "test", makeSocket: { _ in
            let socket = SyntheticSocket(id: "synthetic")
            sockets.append(socket); return socket
        }, sleepNotifications: center, retryDelay: { _ in 0.001 })
        let ready = expectation(description: "Initial connection")
        live.onReady = { ready.fulfill() }
        live.start()
        await fulfillment(of: [ready], timeout: 2)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        live.stop()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertNil(live.connectionID)
    }

    func testStartWhileAsleepWaitsForWakeAndUnstartedConnectionStaysStopped() async throws {
        let center = NotificationCenter()
        var sockets: [SyntheticSocket] = []
        let live = ChatLiveConnection(session: session, version: "test", makeSocket: { _ in
            let socket = SyntheticSocket(id: "after-wake")
            sockets.append(socket); return socket
        }, sleepNotifications: center)
        defer { live.stop() }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertTrue(sockets.isEmpty, "Wake is not authorization to start an unused connection")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        live.start()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(sockets.isEmpty)
        let ready = expectation(description: "Deferred start after wake")
        live.onReady = { ready.fulfill() }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(live.connectionID, "after-wake")
    }

    func testSleepObserversAreRemovedWhenConnectionOwnerIsReleased() {
        let center = NotificationCenter()
        var calls = 0
        var monitor: ChatSystemSleepMonitor? = ChatSystemSleepMonitor(center: center,
            willSleep: { calls += 1 }, didWake: { calls += 1 })
        weak var weakMonitor = monitor
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(calls, 1)
        monitor = nil
        XCTAssertNil(weakMonitor)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(calls, 1, "Replaced connections must not leave process-lifetime observers")
    }

    func testLocalCancellationWakesPendingReceiveWithoutPeerResponse() async throws {
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let socket = ChatURLSessionSocket(socket: network.webSocketTask(with: URL(string: "wss://chat.example.test")!))
        let finished = expectation(description: "Receive stream cancelled immediately")
        let reader = Task {
            do {
                for try await _ in socket.messages { XCTFail("Unstarted socket cannot receive frames") }
                XCTFail("Cancellation must terminate with an error")
            } catch is CancellationError { finished.fulfill() }
            catch { XCTFail("Unexpected error"); finished.fulfill() }
        }
        defer { reader.cancel() }
        socket.cancel()
        await fulfillment(of: [finished], timeout: 1)
    }
}

@MainActor
private final class SyntheticSocket: ChatSocketTransport {
    let messages: AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>
    private let output: AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.Continuation
    private let id: String
    var sent: [String] = []
    var onSend: ((String) async throws -> Void)?
    var cancelled = false
    init(id: String) {
        self.id = id
        var source: AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.Continuation!
        messages = AsyncThrowingStream { source = $0 }
        output = source
    }
    func resume() {
        emit("0{\"pingInterval\":25000,\"pingTimeout\":60000}")
        emit("40")
        emit("42[\"client.init\",{\"id\":\"\(id)\"}]")
    }
    func emit(_ text: String) { output.yield(.string(text)) }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if case .string(let text) = message {
            sent.append(text)
            try await onSend?(text)
        }
    }
    func fail() { output.finish(throwing: URLError(.networkConnectionLost)) }
    func cancel() { cancelled = true; output.finish(throwing: CancellationError()) }
}
