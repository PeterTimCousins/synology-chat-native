import Foundation

/// Notification diagnostics are typed presentation data, never control state
/// inferred from a localized sentence. Resource lookup happens only on display.
enum NativeNotificationDiagnostic:Equatable {
    case noEvents
    case submittingTest
    case serverEvents(Int,enabled:Bool)
    case snoozeClockUnavailable
    case submitting
    case filtered
    case postsWithoutNotification(Int)
    case accepted
    case rejected(Int)

    func text(language:NativeInterfaceLanguage = .system,bundle:Bundle? = nil)->String {
        func label(_ key:String)->String {
            NativeLocalizedStrings.text(key,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
        }
        func count(_ key:String,_ value:Int)->String {
            NativeLocalizedStrings.count(key,Int64(value),language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
        }
        switch self {
        case .noEvents: return label("No server notification events received this session")
        case .submittingTest: return label("Submitting local test to macOS")
        case .serverEvents(let value,let enabled):
            return count(enabled ? "Server notification events: %lld" : "Server notification events: %lld · notifications disabled",value)
        case .snoozeClockUnavailable: return label("Notification held: could not validate snooze timing")
        case .submitting: return label("Submitting notification to macOS")
        case .filtered: return label("Server notification filtered: snoozed, own, deleted, visible, or unsupported event")
        case .postsWithoutNotification(let value): return count("Post events: %lld · no server notification event yet",value)
        case .accepted: return label("Last notification accepted by macOS")
        case .rejected(let code): return NativeLocalizedStrings.integer("macOS rejected the last notification (code %lld)",Int64(code),language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
        }
    }
}
