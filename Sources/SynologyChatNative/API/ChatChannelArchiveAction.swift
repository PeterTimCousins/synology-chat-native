import Foundation

extension ChatChannel {
    var supportsHistoryArchiving:Bool {
        id > 2 && type == "private" && !encrypted && is_joined == true && is_closed != true && (hide_global_at ?? 0) == 0
    }
}

struct ChatHistoryArchivePreparation {
    let channel:ChatChannel
    let latestPostID:Int64
    let priorArchiveIDs:Set<Int64>
    let accountGeneration:Int
}
