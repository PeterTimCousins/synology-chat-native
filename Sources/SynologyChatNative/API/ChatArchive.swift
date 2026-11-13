import Foundation

enum ChatArchiveKind:String,CaseIterable,Identifiable {
    case `private`, `public`, anonymous, chatbot
    var id:String { rawValue }
    var title:String { switch self { case .private:return "Private channels";case .public:return "Public channels";case .anonymous:return "Conversations";case .chatbot:return "Bots" } }
}
struct ChatArchive:Decodable,Identifiable {
    struct Properties:Decodable {
        let channel:ChatChannel
        let reason:String
        let trigger_user_id:Int64
    }
    let archive_id:Int64
    let post_start:Double
    let post_end:Double
    let post_id_start:Int64
    let post_id_end:Int64
    let props:Properties
    var id:Int64 { archive_id }
    // Structural wire eligibility; the model separately requires an unlocked key.
    var isReadable:Bool { archive_id > 0 && props.channel.id > 0 && (!props.channel.encrypted || props.channel.channel_key_enc?.isEmpty == false) && post_start.isFinite && post_end.isFinite && post_start <= post_end && post_id_start >= 0 && post_id_end >= post_id_start }
    func hasSameContentScope(as other:ChatArchive) -> Bool {
        id == other.id && props.channel.id == other.props.channel.id && props.channel.type == other.props.channel.type &&
        props.channel.encrypted == other.props.channel.encrypted && props.channel.channel_key_enc == other.props.channel.channel_key_enc &&
        post_start == other.post_start && post_end == other.post_end && post_id_start == other.post_id_start && post_id_end == other.post_id_end
    }
    var reasonTitle:String {
        switch props.reason {
        case "channel_closed":return "Channel closed"
        case "channel_archived":return "Channel archived"
        case "user_trigger":return "Archived manually"
        default:return props.reason.replacingOccurrences(of:"_",with:" ").capitalized
        }
    }
    func validatePosts(_ posts:[ChatPost],before:Int64?,threadID:Int64? = nil) throws -> [ChatPost] {
        guard isReadable,Set(posts.map(\.id)).count == posts.count,
              posts.allSatisfy({ $0.channel_id == props.channel.id && $0.id > 0 && $0.id >= post_id_start && $0.id <= post_id_end && $0.create_at.isFinite && $0.create_at >= post_start && $0.create_at <= post_end }) else { throw ChatAPIError.invalidResponse }
        if let threadID {
            guard threadID > 0,threadID >= post_id_start,threadID <= post_id_end,posts.allSatisfy({ $0.id == threadID || $0.thread_id == threadID }) else { throw ChatAPIError.invalidResponse }
        }
        return posts.filter { (before == nil || $0.id < before!) && (threadID == nil || $0.id != threadID) }.sorted { $0.id < $1.id }
    }
}
struct ChatArchiveNames:Decodable { let channel_names:[String] }
struct ChatArchiveList:Decodable { let archives:[ChatArchive] }

enum ChatArchiveCollection:String,CaseIterable,Identifiable {
    case messages,pinned,saved,files,links
    var id:String { rawValue }
    var title:String { switch self { case .messages:return "Messages";case .pinned:return "Pinned";case .saved:return "Saved";case .files:return "Files";case .links:return "Links" } }
    var parameters:[String:ChatParameter] {
        switch self {
        case .messages:return [:]
        case .pinned:return ["has":.array([.string("pin")]),"sort_by":.string("last_pin_at"),"sort_by_array":.array([.string("is_sticky"),.string("last_pin_at")])]
        case .saved:return ["has":.array([.string("star")])]
        case .files:return ["post_type":.array([.string("file")]),"sort_by":.string("create_at")]
        case .links:return ["has":.array([.string("url")])]
        }
    }
}
struct ChatArchiveMatch:Identifiable {
    let archive:ChatArchive
    let post:ChatPost
    var id:String { "\(archive.id):\(post.id)" }
    static func resolve(_ posts:[ChatPost],scopes:[ChatArchive]) throws -> [ChatArchiveMatch] {
        guard Set(posts.map(\.id)).count == posts.count else { throw ChatAPIError.invalidResponse }
        return try posts.map { post in
            let candidates = scopes.filter { $0.isReadable && $0.props.channel.id == post.channel_id && post.id > 0 && post.id >= $0.post_id_start && post.id <= $0.post_id_end }
            guard candidates.count == 1,let archive = candidates.first else { throw ChatAPIError.invalidResponse }
            _ = try archive.validatePosts([post],before:nil)
            return .init(archive:archive,post:post)
        }
    }
}
struct ChatArchiveSearchResult {
    let matches:[ChatArchiveMatch]
    let total:Int?
    let nextOffset:Int
}

extension ChatPost {
    var supportsArchiveAttachment:Bool {
        id > 0 && type == "file" && file_props != nil && (delete_at ?? 0) == 0 && props?.encrypted != true
    }
    var archiveFilename:String { ChatMultipartBody.safeFilename(file_props?.name ?? "Attachment") }
}
