import Foundation

enum ChatDriveLocation:String,CaseIterable,Identifiable {
    case myDrive,teamFolders,shared,starred,recent,labels
    var id:String {rawValue}
    var title:String {switch self {case .myDrive:return "My Drive";case .teamFolders:return "Team folders";case .shared:return "Shared with me";case .starred:return "Starred";case .recent:return "Recent";case .labels:return "Labels"}}
    var method:String {switch self {case .myDrive,.teamFolders:return "list";case .shared:return "shared_with_me";case .starred:return "list_starred";case .recent:return "recent";case .labels:return "list_labelled"}}
}
struct ChatDrivePolicy:Decodable {
    struct Permission:Decodable {let public_sharing:Bool;let internal_link_sharing:Bool;let invite_sharing:Bool;let public_force_password:Bool?;let public_force_expiration_days:Int?}
    let sharing_permission:Permission?
    let enable_normal_user_sharing:Bool?
    var allowsPublicWithoutAdvancedSetup:Bool {sharing_permission?.public_sharing == true && sharing_permission?.public_force_password == false && sharing_permission?.public_force_expiration_days == 0}
    var allowsLinks:Bool {sharing_permission.map {$0.public_sharing || $0.internal_link_sharing || $0.invite_sharing} ?? (enable_normal_user_sharing == true)}
}
struct ChatDriveFile:Decodable,Equatable,Identifiable {
    struct Capabilities:Decodable,Equatable {let can_read:Bool;let can_organize:Bool;let can_share:Bool}
    let file_id:String
    let name:String
    let type:String
    let size:Int64
    let modified_time:Double
    let version_id:String
    let hash:String
    let encrypted:Bool
    let removed:Bool
    let transient:Bool
    let capabilities:Capabilities
    let shared_with:[ChatJSON]
    var id:String {file_id}
    var isFolder:Bool {type == "dir"}
    static func validID(_ id:String)->Bool {!id.isEmpty && id.utf8.count <= 256 && id.allSatisfy {$0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")}}
    var valid:Bool {Self.validID(id) && !name.isEmpty && name.utf8.count <= 4096 && !name.contains("\0") && ["file","dir"].contains(type) && size >= 0 && modified_time.isFinite && shared_with.count <= 10000}
    var selectable:Bool {valid && capabilities.can_read && !removed && !encrypted && !transient}
    func sameSelection(_ other:Self)->Bool {self == other && selectable && other.selectable}
}
struct ChatDriveTeamFolder:Decodable,Identifiable {
    let file_id:String
    let name:String
    let capabilities:ChatDriveFile.Capabilities
    var id:String {file_id}
}
struct ChatDrivePage:Decodable {let items:[ChatDriveFile];let total:Int?}
struct ChatDriveBrowsePage {
    let files:[ChatDriveFile]
    let teams:[ChatDriveTeamFolder]
    var labels:[ChatDriveLabel] = []
    let hasMore:Bool
}
struct ChatDriveReview {
    let file:ChatDriveFile
    let policy:ChatDrivePolicy
    let recipients:[ChatDriveRecipient]
    let memberIDs:[Int64]
    let accountGeneration:Int
    let channelID:Int64
    let rootID:Int64?
}
struct ChatDriveLink:Decodable {
    let url:String
    func validatedURL(base:URL)->URL? {
        guard url.utf8.count <= 8192,!url.contains("\n"),!url.contains("\r"),let resolved = URL(string:url,relativeTo:base)?.absoluteURL,let parts = URLComponents(url:resolved,resolvingAgainstBaseURL:false),parts.scheme?.lowercased() == "https",let host = parts.host,!host.isEmpty,parts.user == nil,parts.password == nil,
              !(parts.queryItems ?? []).contains(where:{["_sid","sid","synotoken","password"].contains($0.name.lowercased())}) else {return nil}
        return resolved
    }
}

enum ChatDriveAccessScope:String,CaseIterable,Identifiable {case keep,members,internalLink,publicLink
    var id:String {rawValue}
    var title:String {switch self {case .keep:return "Keep existing permissions";case .members:return "Conversation members";case .internalLink:return "People on this NAS with the link";case .publicLink:return "Anyone with the link"}}
}
enum ChatDriveRole:String,CaseIterable,Identifiable {
    case previewer,viewer,editor,organizer,commenter,preview_commenter
    var id:String {rawValue}
    var title:String {switch self {case .previewer:return "Preview only";case .viewer:return "View and download";case .editor:return "Edit";case .organizer:return "Manage";case .commenter:return "Comment";case .preview_commenter:return "Preview and comment"}}
}
struct ChatDriveAccessDraft:Equatable {
    var scope:ChatDriveAccessScope = .keep
    var role:ChatDriveRole = .viewer
}
struct ChatDriveRecipient:Equatable,Identifiable {
    let chatID:Int64
    let uid:Int64
    let username:String
    let name:String
    var id:Int64 {chatID}
}
extension ChatDriveFile {
    var isOfficeItem:Bool {["odoc","osheet","oslides"].contains((name as NSString).pathExtension.lowercased())}
    func roles(for scope:ChatDriveAccessScope)->[ChatDriveRole] {
        let base:[ChatDriveRole] = scope == .members ? [.previewer,.viewer,.editor,.organizer] : [.viewer,.editor]
        return base+(isOfficeItem ? (scope == .members ? [.commenter,.preview_commenter] : [.commenter]) : [])
    }
    func permissionEdits(_ draft:ChatDriveAccessDraft,recipients:[ChatDriveRecipient],policy:ChatDrivePolicy)->[ChatParameter]? {
        if draft.scope == .keep {return []}
        guard selectable,capabilities.can_organize,roles(for:draft.scope).contains(draft.role) else {return nil}
        func update(_ member:[String:ChatParameter])->ChatParameter {.object(["action":.string("update"),"member":.object(member),"role":.string(draft.role.rawValue)])}
        switch draft.scope {
        case .keep:return []
        case .members:
            guard policy.sharing_permission?.invite_sharing == true,!recipients.isEmpty,recipients.count <= 1000,Set(recipients.map(\.uid)).count == recipients.count,recipients.allSatisfy({$0.uid > 0}) else {return nil}
            return recipients.map {update(["type":.string("user"),"uid":.integer($0.uid)])}
        case .internalLink,.publicLink:
            let target = draft.scope == .internalLink ? "internal" : "public"
            guard draft.scope == .internalLink ? policy.sharing_permission?.internal_link_sharing == true : policy.allowsPublicWithoutAdvancedSetup else {return nil}
            // Match the official policy switch without touching individual/group ACL entries.
            // Inherited link access cannot be edited safely from this item.
            let groups = shared_with.filter {["internal","public"].contains($0["type"]?.string ?? "")}
            guard !groups.contains(where:{$0["inherited"] == .bool(true)}),groups.count <= 1 else {return nil}
            var edits:[ChatParameter] = groups.filter {$0["type"]?.string != target}.compactMap {entry in guard let type = entry["type"]?.string else {return nil};return .object(["action":.string("delete"),"member":.object(["type":.string(type)])])}
            edits.append(update(["type":.string(target)]));return edits
        }
    }
    func confirms(_ draft:ChatDriveAccessDraft,recipients:[ChatDriveRecipient])->Bool {
        func has(type:String,recipient:ChatDriveRecipient? = nil)->Bool {shared_with.contains {entry in
            let identity:Bool
            if let recipient {identity = entry["uid"]?.integer.map {$0 == recipient.uid && (entry["name"]?.string == nil || entry["name"]?.string == recipient.username)} ?? (entry["name"]?.string == recipient.username)} else {identity = true}
            return entry["type"]?.string == type && identity && entry["role"]?.string == draft.role.rawValue && entry["inherited"] != .bool(true)
        }}
        switch draft.scope {case .keep:return true;case .members:return !recipients.isEmpty && recipients.allSatisfy {has(type:"user",recipient:$0)};case .internalLink:return has(type:"internal") && !shared_with.contains {$0["type"]?.string == "public"};case .publicLink:return has(type:"public") && !shared_with.contains {$0["type"]?.string == "internal"}}
    }
}

extension ChatDriveFile {
    func unrelatedPermissionsMatch(_ before:Self,draft:ChatDriveAccessDraft,recipients:[ChatDriveRecipient])->Bool {
        func untouched(_ entries:[ChatJSON])->[Data] {
            let encoder = JSONEncoder();encoder.outputFormatting = .sortedKeys
            return entries.filter {entry in
                let type = entry["type"]?.string ?? ""
                if draft.scope == .members {return type != "user" || !recipients.contains {$0.uid == entry["uid"]?.integer || $0.username == entry["name"]?.string}}
                return !["public","internal"].contains(type)
            }.compactMap {try? encoder.encode($0)}.sorted {$0.lexicographicallyPrecedes($1)}
        }
        return untouched(shared_with) == untouched(before.shared_with)
    }
}

struct ChatDriveLabel:Decodable,Identifiable {
    enum ID:Decodable,Equatable,Hashable {
        case text(String),number(Int64)
        init(from decoder:Decoder) throws {let c = try decoder.singleValueContainer();if let n = try? c.decode(Int64.self) {self = .number(n)} else {self = .text(try c.decode(String.self))}}
        var parameter:ChatParameter {switch self {case .text(let s):return .string(s);case .number(let n):return .integer(n)}}
        var valid:Bool {switch self {case .text(let s):return ChatDriveFile.validID(s);case .number(let n):return n > 0}}
    }
    let label_id:ID
    let name:String
    var id:ID {label_id}
    var valid:Bool {id.valid && !name.isEmpty && name.utf8.count <= 4096 && !name.contains("\0")}
}
