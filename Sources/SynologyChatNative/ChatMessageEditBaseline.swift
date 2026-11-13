import Foundation

/// The original wire content/revision for one explicit edit. Benign message
/// metadata refreshes cannot invalidate it; changed content cannot alias through
/// Swift String's canonical Unicode equality.
struct ChatMessageEditBaseline {
    private let postID:Int64
    private let channelID:Int64
    private let creatorID:Int64
    private let threadID:Int64
    private let type:String
    private let createdAt:Double
    private let updatedAt:Double
    private let messageUTF8:Data
    private let wasNotDeleted:Bool

    init(_ post:ChatPost) {
        postID = post.id;channelID = post.channel_id;creatorID = post.creator_id
        threadID = post.isReply ? post.thread_id ?? 0 : 0
        type = post.type;createdAt = post.create_at;updatedAt = post.update_at ?? 0
        messageUTF8 = Data(post.message.utf8);wasNotDeleted = (post.delete_at ?? 0) <= 0
    }
    func matchesIdentity(_ fresh:ChatPost)->Bool {
        createdAt.isFinite && fresh.create_at.isFinite
            && fresh.id == postID && fresh.channel_id == channelID && fresh.creator_id == creatorID
            && (fresh.isReply ? fresh.thread_id ?? 0 : 0) == threadID && fresh.type == type
            && fresh.create_at == createdAt
    }
    func matches(_ fresh:ChatPost)->Bool {
        matchesIdentity(fresh) && wasNotDeleted && (fresh.delete_at ?? 0) <= 0
            && (fresh.update_at ?? 0) == updatedAt && Data(fresh.message.utf8) == messageUTF8
    }
}
