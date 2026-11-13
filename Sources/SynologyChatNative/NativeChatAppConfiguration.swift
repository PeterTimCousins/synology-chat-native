import Foundation

/// Keep the existing wrapper's startup and Dock behavior independent from the API app.
enum NativeChatAppConfiguration {
    static func isNativeClient(bundleID: String?, arguments: [String]) -> Bool {
        arguments.contains("--native-preview") || [
            "com.costwisegroup.synology-chat-native.api-preview",
            "com.costwisegroup.synology-chat-native.api"
        ].contains(bundleID ?? "")
    }
    static func automaticallyRestoresSavedSession(bundleID: String?) -> Bool {
        // Development rebuilds must not trigger protected credential prompts.
        // The preview offers explicit saved-session and official-app-session actions.
        bundleID == "com.costwisegroup.synology-chat-native.api"
    }
    static var automaticallyRestoresSavedSession: Bool { automaticallyRestoresSavedSession(bundleID: Bundle.main.bundleIdentifier) }
    static var standalone: Bool { isNativeClient(bundleID: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments) }
    /// Explicit candidate-only opt-in until physical controls and parity review
    /// accept this reader. The wrapper and ordinary launches keep their defaults.
    static func enablesNativeMessageViewport(bundleID:String?,arguments:[String])->Bool {
        isNativeClient(bundleID:bundleID,arguments:arguments) && arguments.contains("--native-message-viewport")
    }
    static var usesNativeMessageViewport:Bool { enablesNativeMessageViewport(bundleID:Bundle.main.bundleIdentifier,arguments:CommandLine.arguments) }
    static var developmentUI: Bool { Bundle.main.bundleIdentifier != "com.costwisegroup.synology-chat-native.api" }
    static func allowsOfficialSessionImport(bundleID: String?, debugBuild: Bool) -> Bool {
        debugBuild && bundleID != "com.costwisegroup.synology-chat-native.api"
    }
    static var allowsOfficialSessionImport: Bool {
        #if DEBUG
        return allowsOfficialSessionImport(bundleID: Bundle.main.bundleIdentifier, debugBuild: true)
        #else
        return false
        #endif
    }
    static var productName: String { developmentUI ? "Chat Native Preview" : "Chat Native" }
    static var windowTitle: String { productName }
}
