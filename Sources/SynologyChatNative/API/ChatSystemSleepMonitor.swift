import AppKit

/// Scoped observers; no global power settings or machine sleep actions.
@MainActor
final class ChatSystemSleepMonitor {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    init(center: NotificationCenter, willSleep: @escaping () -> Void, didWake: @escaping () -> Void) {
        self.center = center
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in willSleep() },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in didWake() }
        ]
    }
    deinit { observers.forEach(center.removeObserver) }
}
