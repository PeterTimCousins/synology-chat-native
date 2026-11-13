import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor
final class ChatWindowLifecycleTests: XCTestCase {
    func testHiddenApplicationCannotAdvertiseActiveDespiteLateFocusState() {
        let model = NativeChatPreviewModel()
        model.updateWindowVisibility(true, applicationActive: true)
        XCTAssertTrue(model.windowIsActive)
        model.updateWindowActivity(true, applicationHidden: true)
        XCTAssertFalse(model.windowIsActive)
        model.updateWindowVisibility(true, applicationActive: true, applicationHidden: true)
        XCTAssertFalse(model.windowIsActive, "A stale visible/key-window callback must not reactivate a hidden app")
        model.updateWindowActivity(true, applicationHidden: false)
        XCTAssertTrue(model.windowIsActive)
    }

    func testWindowObserverPublishesHideAndUnhideWithoutNeedingFocusNotification() {
        _ = NSApplication.shared
        // Attach without ever showing or activating a window. Application
        // notifications must still be observed for this live attachment.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let originalMouseMovement = window.acceptsMouseMovedEvents
        let observer = NativeWindowActivity.Observer()
        var updates: [Bool] = []
        observer.changed = { updates.append($0) }
        window.contentView = observer
        defer {
            window.contentView = nil
            XCTAssertFalse(observer.isMonitoringUserActivity); XCTAssertFalse(observer.isPollingUserActivity)
            XCTAssertEqual(window.acceptsMouseMovedEvents, originalMouseMovement)
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(observer.isMonitoringUserActivity); XCTAssertTrue(observer.isPollingUserActivity)
        let before = updates.count
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
        XCTAssertEqual(updates.count, before + 1)
        XCTAssertEqual(updates.last, false)
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: NSApp)
        XCTAssertEqual(updates.count, before + 2)
        XCTAssertEqual(updates.last, false, "An observer without a key window must remain unreadable")
    }

    func testDetachedWindowObserverRemovesInputPollingAndApplicationObservers() {
        let observer = NativeWindowActivity.Observer()
        var updates: [Bool] = [], appUpdates: [Bool] = []
        observer.changed = { updates.append($0) }; observer.userActivityChanged = { appUpdates.append($0) }
        observer.viewDidMoveToWindow()
        XCTAssertEqual(updates, [false]); XCTAssertEqual(appUpdates, [false])
        XCTAssertFalse(observer.isMonitoringUserActivity); XCTAssertFalse(observer.isPollingUserActivity)
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: nil)
        XCTAssertEqual(updates, [false]); XCTAssertEqual(appUpdates, [false])
    }

    func testSharedMouseMovementLeasesRestoreOnlyAfterFinalOwner() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = false
        let first = NativeWindowMouseMovementLease.acquire(for: window)
        let second = NativeWindowMouseMovementLease.acquire(for: window)
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        first.release(); XCTAssertTrue(window.acceptsMouseMovedEvents)
        second.release(); XCTAssertFalse(window.acceptsMouseMovedEvents)
        let next = NativeWindowMouseMovementLease.acquire(for: window)
        first.release(); second.release()
        XCTAssertTrue(window.acceptsMouseMovedEvents, "Repeated release must not retire a new owner's lease")
        next.release(); XCTAssertFalse(window.acceptsMouseMovedEvents)
        XCTAssertFalse(window.isVisible)
    }

    func testMouseMovementLeasePreservesAnOriginallyEnabledWindow() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        let lease = NativeWindowMouseMovementLease.acquire(for: window)
        lease.release()
        XCTAssertTrue(window.acceptsMouseMovedEvents); XCTAssertFalse(window.isVisible)
    }

    func testLateAppFocusCallbackCannotReactivateClosedWindowPresence() {
        let model = NativeChatPreviewModel()
        model.updateWindowVisibility(true, applicationActive: true)
        XCTAssertTrue(model.windowIsActive)
        model.previewDidDisappear()
        model.updateWindowActivity(true)
        XCTAssertFalse(model.windowIsActive, "AppKit may keep the app active with no visible window")
    }

    func testReopenAndMinimizeCombineWindowVisibilityWithAppFocus() {
        let model = NativeChatPreviewModel()
        model.updateWindowVisibility(true, applicationActive: false)
        XCTAssertFalse(model.windowIsActive)
        model.updateWindowActivity(true)
        XCTAssertTrue(model.windowIsActive)
        model.updateWindowVisibility(false, applicationActive: true)
        model.updateWindowActivity(true)
        XCTAssertFalse(model.windowIsActive)
        model.updateWindowVisibility(true, applicationActive: true)
        XCTAssertTrue(model.windowIsActive)
        model.updateWindowActivity(false)
        XCTAssertFalse(model.windowIsActive)
    }
}
