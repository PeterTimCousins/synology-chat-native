import Foundation

struct ChatNASRoot:Decodable,Identifiable {
    let spath:String
    let text:String
    var id:String {spath}
}
struct ChatNASFile:Decodable,Equatable,Identifiable {
    struct Details:Decodable,Equatable {
        struct Times:Decodable,Equatable {let mtime:Double;let ctime:Double?}
        struct Permission:Decodable,Equatable {struct ACL:Decodable,Equatable {let read:Bool};let acl:ACL}
        let size:Int64
        let time:Times
        let perm:Permission
        let type:String?
    }
    let path:String
    let name:String
    let isdir:Bool
    let additional:Details
    var id:String {path}
    var valid:Bool {Self.validPath(path) && !name.isEmpty && name.utf8.count <= 1024 && !name.contains("/") && additional.size >= 0 && additional.time.mtime.isFinite && additional.time.ctime?.isFinite != false}
    var selectable:Bool {valid && !isdir && additional.perm.acl.read}
    func matchesForSend(_ other:Self)->Bool {selectable && other.selectable && path == other.path && name == other.name && additional.size == other.additional.size && additional.time.mtime == other.additional.time.mtime && additional.time.ctime == other.additional.time.ctime}
    static func validPath(_ path:String)->Bool {path.hasPrefix("/") && path.utf8.count <= 8192 && !path.contains("\0") && !path.contains("//") && !path.split(separator:"/").contains(where:{$0 == "." || $0 == ".."})}
}
struct ChatNASPage:Decodable {
    let files:[ChatNASFile]
    let offset:Int
    let total:Int
}
struct ChatNASUploadPolicy:Decodable {
    let allow_ds_upload:Bool
    let file_size_limit:Int64
    func allows(_ file:ChatNASFile)->Bool {
        guard allow_ds_upload,file_size_limit >= 0,file.selectable else {return false}
        if file_size_limit == 0 {return true}
        let (limit,overflow) = file_size_limit.multipliedReportingOverflow(by:1024*1024)
        return !overflow && file.additional.size <= limit
    }
}
struct ChatNASSelection {
    let files:[ChatNASFile]
    let channelID:Int64
    let rootID:Int64?
    let accountGeneration:Int
}
struct ChatNASPreflightFailure:LocalizedError {
    let message:String
    var errorDescription:String? {message}
}
