import AppKit
import SwiftUI

/// Multiple root/thread observers can share one window. Restore its prior
/// mouse-movement setting only after the final observer releases ownership.
@MainActor final class NativeWindowMouseMovementLease {
    @MainActor private final class Entry {
        weak var window: NSWindow?
        let original: Bool
        var count = 0
        init(window: NSWindow) { self.window = window; original = window.acceptsMouseMovedEvents }
    }
    private static var entries: [ObjectIdentifier: Entry] = [:]
    private let entry: Entry
    private let key: ObjectIdentifier
    private var released = false
    private init(entry: Entry, key: ObjectIdentifier) { self.entry = entry; self.key = key }
    static func acquire(for window: NSWindow) -> NativeWindowMouseMovementLease {
        let key = ObjectIdentifier(window)
        let entry: Entry
        if let existing = entries[key], existing.window === window { entry = existing }
        else { entry = Entry(window: window); entries[key] = entry }
        entry.count += 1; window.acceptsMouseMovedEvents = true
        return NativeWindowMouseMovementLease(entry: entry, key: key)
    }
    func release() {
        guard !released else { return }; released = true
        entry.count -= 1
        guard entry.count == 0 else { return }
        entry.window?.acceptsMouseMovedEvents = entry.original
        if Self.entries[key] === entry { Self.entries[key] = nil }
    }
}

/// Scope read receipts to this window, while optionally reporting app activity
/// through native modal windows. Only local input timing is observed.
struct NativeWindowActivity: NSViewRepresentable {
    var userActivityChanged: ((Bool) -> Void)? = nil
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> Observer {
        let view = Observer(); view.changed = changed; view.userActivityChanged = userActivityChanged; return view
    }
    func updateNSView(_ view: Observer, context: Context) { view.changed = changed; view.userActivityChanged = userActivityChanged }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.uninstall(); view.changed = nil; view.userActivityChanged = nil }

    final class Observer: NSView {
        struct ActivityContext {
            var windowVisible: Bool
            var windowKey: Bool
            var applicationActive: Bool
            var applicationHidden: Bool
            var miniaturized: Bool
            var appCanBeActive: Bool { windowVisible && !miniaturized && applicationActive && !applicationHidden }
        }
        var changed: ((Bool) -> Void)?
        var userActivityChanged: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var eventMonitor: Any?
        private var timer: Timer?
        private var deadline = NativeUserActivityDeadline()
        private let elapsed: () -> TimeInterval
        private let activityContext: (NSWindow) -> ActivityContext
        private weak var observedWindow: NSWindow?
        private(set) var attachmentID: UUID?
        private var lastPublishedApplicationActivity: Bool?
        private var mouseMovementLease: NativeWindowMouseMovementLease?
        var isMonitoringUserActivity: Bool { eventMonitor != nil }
        var isPollingUserActivity: Bool { timer != nil }
        init(elapsed: (() -> TimeInterval)? = nil, activityContext: ((NSWindow) -> ActivityContext)? = nil) {
            let clock = ContinuousClock(), origin = clock.now
            self.elapsed = elapsed ?? {
                let duration = origin.duration(to: clock.now).components
                return Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000
            }
            self.activityContext = activityContext ?? { window in
                .init(windowVisible: window.isVisible, windowKey: window.isKeyWindow,
                      applicationActive: NSApp.isActive, applicationHidden: NSApp.isHidden, miniaturized: window.isMiniaturized)
            }
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A redundant same-window callback is layout, not fresh user input.
            if let window, observedWindow === window, attachmentID != nil { return }
            uninstall()
            guard let window else { return }
            observedWindow = window
            let attachment = UUID(); attachmentID = attachment
            mouseMovementLease = NativeWindowMouseMovementLease.acquire(for: window)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let self else { return }
                    if [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
                        NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification].contains(notification.name) {
                        self.recordInput()
                    } else { self.pollActivity() }
                })
            }
            let input: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
                .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: input) { [weak self] event in
                // Do not inspect characters, locations, targets or clipboard
                // contents. The monitor remains confined to this application.
                self?.recordInput(publishWhileActive: false)
                return event
            }
            let timer = Timer(timeInterval: NativeUserActivityDeadline.pollingInterval, repeats: true) { [weak self] _ in self?.pollActivity() }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            recordInput()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attachmentID == attachment else { return }
                self.pollActivity()
            }
        }
        private var currentContext: ActivityContext? {
            guard attachmentID != nil, let observedWindow, window === observedWindow else { return nil }
            return activityContext(observedWindow)
        }
        func recordInput(publishWhileActive: Bool = true) {
            guard let context = currentContext else { return }
            if context.appCanBeActive { deadline.recordActivity(at: elapsed()) }
            // Pointer movement can arrive at display frequency. Renew only the
            // timestamp while already active; a resumed idle user publishes at
            // once, and focus notifications always reevaluate window ownership.
            if publishWhileActive || lastPublishedApplicationActivity != true { pollActivity() }
        }
        func pollActivity() {
            guard let context = currentContext else { return }
            let active = context.appCanBeActive && deadline.isActive(at: elapsed())
            let activityChanged = lastPublishedApplicationActivity != active
            lastPublishedApplicationActivity = active
            changed?(active && context.windowKey)
            if activityChanged { userActivityChanged?(active) }
        }
        func uninstall() {
            attachmentID = nil; observedWindow = nil
            timer?.invalidate(); timer = nil
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; eventMonitor = nil
            tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
            mouseMovementLease?.release(); mouseMovementLease = nil
            deadline.reset()
            let activityChanged = lastPublishedApplicationActivity != false
            lastPublishedApplicationActivity = false
            changed?(false)
            if activityChanged { userActivityChanged?(false) }
        }
        deinit {
            timer?.invalidate()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            tokens.forEach(NotificationCenter.default.removeObserver)
            MainActor.assumeIsolated { mouseMovementLease?.release() }
        }
    }
}

