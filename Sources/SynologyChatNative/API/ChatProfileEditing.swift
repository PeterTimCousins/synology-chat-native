import Foundation

struct ChatProfileEditingPolicy:Decodable {
    let readonly_profile:[String]
    func allows(_ field:String)->Bool { !readonly_profile.contains(field) }
}
struct ChatProfileEditSnapshot {
    let userID:Int64
    let nickname:String
    let description:String
    let policy:ChatProfileEditingPolicy
    let accountGeneration:Int
    var avatarVersion:Int64? = nil
}
struct ChatProfileTextDraft {
    var nickname:String
    var description:String
    init(_ snapshot:ChatProfileEditSnapshot) { nickname = snapshot.nickname;description = snapshot.description }
    func patch(from original:ChatProfileEditSnapshot) throws -> [String:ChatParameter] {
        let name = nickname.trimmingCharacters(in:.whitespacesAndNewlines),desc = description.trimmingCharacters(in:.whitespacesAndNewlines)
        if nickname != original.nickname {
            guard nickname.utf16.count <= 255 else {throw ChatTransferError(message:"Display names can contain up to 255 characters.")}
            guard !nickname.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else {throw ChatTransferError(message:"Display names cannot contain tabs, line breaks or control characters.")}
        }
        if description != original.description {
            guard description.utf16.count <= 256 else {throw ChatTransferError(message:"Descriptions can contain up to 256 characters.")}
        }
        var patch:[String:ChatParameter] = [:]
        if name != original.nickname {
            guard original.policy.allows("nickname") else { throw ChatTransferError(message:"Your administrator manages your display name.") }
            patch["nickname"] = .string(name)
        }
        if desc != original.description {
            guard original.policy.allows("description") else { throw ChatTransferError(message:"Your administrator manages your description.") }
            patch["description"] = .string(desc)
        }
        return patch
    }
}
struct ChatProfileEditFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}

struct ChatProfilePhotoSnapshot {
    let profile:ChatProfileEditSnapshot
    let image:Data?
}
