import Foundation

/// Post/list may include the cursor itself. Availability is based only on
/// distinct posts strictly on the requested side of that cursor.
enum ChatHistoryWindow {
    static func validated(_ posts:[ChatPost],channelID:Int64) throws -> [ChatPost] {
        guard posts.allSatisfy({ $0.id > 0 && $0.channel_id == channelID }) else { throw ChatAPIError.invalidResponse }
        return ChatTimeline.merge([],posts)
    }
    static func count(_ posts:[ChatPost],before anchor:Int64) -> Int {
        Set(posts.filter { $0.id < anchor }.map(\.id)).count
    }
}
