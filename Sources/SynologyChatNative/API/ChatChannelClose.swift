import Foundation

extension ChatChannel {
    var supportsClosing:Bool {
        id > 2 && ["private","public","anonymous"].contains(type) && is_joined == true && is_closed != true && (hide_global_at ?? 0) == 0
    }
    var archiveKind:ChatArchiveKind? { ChatArchiveKind(rawValue:type) }
}
struct ChatChannelClosePreparation {
    let channel:ChatChannel
    let priorArchiveIDs:Set<Int64>
    let accountGeneration:Int
}
