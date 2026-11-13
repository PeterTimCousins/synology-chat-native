import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeWindowActivityObserverTests: XCTestCase {
    private final class State {
        var now: TimeInterval = 0
        var context = NativeWindowActivity.Observer.ActivityContext(windowVisible: true, windowKey: true,
            applicationActive: true, applicationHidden: false, miniaturized: false)
        var reads: [Bool] = []
        var activity: [Bool] = []
    }
    private func attach(_ state: State) -> (NSWindow, NativeWindowActivity.Observer) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = false
        let observer = NativeWindowActivity.Observer(elapsed: { state.now }, activityContext: { _ in state.context })
        observer.changed = { state.reads.append($0) }; observer.userActivityChanged = { state.activity.append($0) }
        window.contentView = observer
        XCTAssertFalse(window.isVisible, "The injected context must not require showing or activating a test window")
        addTeardownBlock { @MainActor in window.contentView = nil; observer.uninstall() }
        return (window, observer)
    }

    func testActualObserverExpiresAt180SecondsAndPollsNeverReviveIt() {
        let state = State(), (_, observer) = attach(state)
        XCTAssertEqual(state.reads.last, true); XCTAssertEqual(state.activity.last, true)
        state.now = 179.999; observer.pollActivity()
        XCTAssertEqual(state.reads.last, true)
        state.now = 180; observer.pollActivity()
        XCTAssertEqual(state.reads.last, false); XCTAssertEqual(state.activity.last, false)
        let transitions = state.activity
        for time in [190.0, 200, 1000] { state.now = time; observer.pollActivity() }
        XCTAssertEqual(state.activity, transitions, "Periodic polls must not renew activity or repeat the same app transition")
        XCTAssertEqual(state.reads.last, false)
    }

    func testActualInputOperationResumesAndRenewsObserverDeadline() {
        let state = State(), (_, observer) = attach(state)
        state.now = 180; observer.pollActivity()
        state.now = 181; observer.recordInput(publishWhileActive: false)
        XCTAssertEqual(state.reads.last, true); XCTAssertEqual(state.activity.last, true)
        state.now = 350; observer.recordInput(publishWhileActive: false)
        state.now = 529.999; observer.pollActivity(); XCTAssertEqual(state.activity.last, true)
        state.now = 530; observer.pollActivity(); XCTAssertEqual(state.activity.last, false)
    }

    func testModalInputKeepsAppActiveWithoutRootReadVisibility() {
        let state = State(), (_, observer) = attach(state)
        state.context.windowKey = false
        state.now = 100; observer.recordInput(publishWhileActive: false); observer.pollActivity()
        XCTAssertEqual(state.reads.last, false); XCTAssertEqual(state.activity.last, true)
        state.now = 279.999; observer.pollActivity()
        XCTAssertEqual(state.reads.last, false); XCTAssertEqual(state.activity.last, true)
        state.now = 280; observer.pollActivity()
        XCTAssertEqual(state.reads.last, false); XCTAssertEqual(state.activity.last, false)
        state.context.windowKey = true
        state.now = 281; observer.recordInput()
        XCTAssertEqual(state.reads.last, true); XCTAssertEqual(state.activity.last, true)
    }

    func testHiddenOrInvisibleContextCannotRenewDeadline() {
        let state = State(), (_, observer) = attach(state)
        state.context.applicationHidden = true
        state.now = 100; observer.recordInput(); XCTAssertEqual(state.activity.last, false)
        state.context.applicationHidden = false
        state.now = 181; observer.pollActivity(); XCTAssertEqual(state.activity.last, false)
        state.now = 182; observer.recordInput(); XCTAssertEqual(state.activity.last, true)
        state.context.windowVisible = false
        state.now = 300; observer.recordInput(); XCTAssertEqual(state.activity.last, false)
        state.context.windowVisible = true
        state.now = 363; observer.pollActivity(); XCTAssertEqual(state.activity.last, false)
    }

    func testRedundantSameWindowMoveDoesNotRenewDeadlineOrCycleResources() throws {
        let state = State(), (window, observer) = attach(state)
        let attachment = try XCTUnwrap(observer.attachmentID), reads = state.reads, activity = state.activity
        state.now = 179; observer.viewDidMoveToWindow()
        XCTAssertEqual(observer.attachmentID, attachment)
        XCTAssertTrue(observer.isMonitoringUserActivity); XCTAssertTrue(observer.isPollingUserActivity)
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        XCTAssertEqual(state.reads, reads); XCTAssertEqual(state.activity, activity)
        state.now = 180; observer.pollActivity()
        XCTAssertEqual(state.reads.last, false); XCTAssertEqual(state.activity.last, false)
    }

    func testCallbackReplacementReceivesNextTransitionAndOldClosureIsNotUsed() {
        let state = State(), (_, observer) = attach(state)
        let oldReads = state.reads, oldActivity = state.activity
        var newReads: [Bool] = [], newActivity: [Bool] = []
        observer.changed = { newReads.append($0) }; observer.userActivityChanged = { newActivity.append($0) }
        state.now = 180; observer.pollActivity()
        state.now = 190; observer.pollActivity()
        XCTAssertEqual(state.reads, oldReads); XCTAssertEqual(state.activity, oldActivity)
        XCTAssertEqual(newReads, [false, false]); XCTAssertEqual(newActivity, [false])
        state.now = 191; observer.recordInput()
        XCTAssertEqual(newReads.last, true); XCTAssertEqual(newActivity, [false, true])
    }

    func testDetachRetiresCallbacksResourcesLeaseAndQueuedAttachmentPublication() async {
        let state = State(), (window, observer) = attach(state)
        XCTAssertTrue(observer.isMonitoringUserActivity); XCTAssertTrue(observer.isPollingUserActivity)
        window.contentView = nil
        XCTAssertNil(observer.attachmentID)
        XCTAssertFalse(observer.isMonitoringUserActivity); XCTAssertFalse(observer.isPollingUserActivity)
        XCTAssertFalse(window.acceptsMouseMovedEvents)
        XCTAssertEqual(state.reads.last, false); XCTAssertEqual(state.activity.last, false)
        let reads = state.reads, activity = state.activity
        state.now = 10; observer.pollActivity(); observer.recordInput()
        // Drain the one initial queued publication; no timer delay or input is
        // synthesized, and the retired attachment must not publish again.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(state.reads, reads); XCTAssertEqual(state.activity, activity)
        XCTAssertFalse(window.isVisible)
    }
}
