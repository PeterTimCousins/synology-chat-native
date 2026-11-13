import Foundation

enum ChatMessageText {
    // The official JavaScript client measures this limit in UTF-16 code units.
    static let maximumLength = 2_000
    static func isAllowed(_ text: String) -> Bool { text.utf16.count <= maximumLength }
    static func warning(for text: String) -> String? {
        guard !isAllowed(text) else { return nil }
        return "Message is too long (\(text.utf16.count.formatted())/2,000 characters). Shorten it to continue."
    }
}
