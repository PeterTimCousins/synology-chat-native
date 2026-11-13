import Foundation

/// Monotonic input activity. Polling observes the deadline; it never renews it.
struct NativeUserActivityDeadline: Sendable {
    static let idleInterval: TimeInterval = 180
    static let pollingInterval: TimeInterval = 10
    private var lastActivity: TimeInterval?
    private var lastObservation: TimeInterval?

    mutating func recordActivity(at uptime: TimeInterval) {
        guard accept(uptime) else { return }
        lastActivity = uptime
    }

    mutating func isActive(at uptime: TimeInterval) -> Bool {
        guard accept(uptime), let lastActivity else { return false }
        guard uptime - lastActivity < Self.idleInterval else {
            self.lastActivity = nil
            return false
        }
        return true
    }

    mutating func reset() { lastActivity = nil; lastObservation = nil }

    private mutating func accept(_ uptime: TimeInterval) -> Bool {
        guard uptime.isFinite, uptime >= 0 else {
            lastActivity = nil; lastObservation = nil
            return false
        }
        if let lastObservation, uptime < lastObservation {
            lastActivity = nil; self.lastObservation = uptime
            return false
        }
        lastObservation = uptime
        return true
    }
}
