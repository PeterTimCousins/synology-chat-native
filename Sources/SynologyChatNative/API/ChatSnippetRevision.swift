import Foundation
import CryptoKit

/// In-memory content revision; reactions, pins and read counts do not change it.
/// Hash UTF-8 bytes so canonically equivalent Unicode edits remain distinct code.
struct ChatSnippetRevision:Equatable {
    let postID,channelID,creatorID,threadID:Int64
    let createdAt:Double
    let updatedAt:Double?
    let filename:Data?
    let caption:Data
    let preview:Data?
    let size:Int64?
    let lines:Int?
    let previewMore:Bool?
    init?(_ post:ChatPost) {
        guard post.id > 0,post.channel_id > 0,post.creator_id > 0,post.type == "file",post.file_props?.is_snippet == true,
              (post.delete_at ?? 0) == 0,(!post.isReply || (post.thread_id ?? 0) > 0) else { return nil }
        postID = post.id;channelID = post.channel_id;creatorID = post.creator_id;threadID = post.isReply ? post.thread_id ?? 0 : 0
        createdAt = post.create_at;updatedAt = post.update_at
        filename = (post.file_props?.name).map(Self.digest);caption = Self.digest(post.message);preview = (post.file_props?.snippet_preview).map(Self.digest)
        size = post.file_props?.size;lines = post.file_props?.snippet_lines;previewMore = post.file_props?.snippet_preview_more
    }
    func sameIdentity(as other:Self) -> Bool {
        postID == other.postID && channelID == other.channelID && creatorID == other.creatorID && threadID == other.threadID && createdAt == other.createdAt
    }
    static func digest(_ text:String) -> Data { Data(SHA256.hash(data:Data(text.utf8))) }
}
extension ChatChannel {
    var supportsSnippetReading:Bool { id > 0 && !encrypted && is_joined != false && is_closed != true && (hide_global_at ?? 0) == 0 }
}
struct ChatSnippetReview {
    let revision:ChatSnippetRevision
    let contentDigest:Data
    let channelType:String
    let accountGeneration:Int
}
struct ChatSnippetSnapshot {
    let content:String
    let review:ChatSnippetReview
}
struct ChatSnippetEditFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}
