import Foundation

/// Keep the six official grid fields with their original scalar types for unpair.
struct ChatPairedDevice:Decodable,Equatable,Identifiable {
    let id:Int64
    let device_name:String
    let identity:String
    let package:String
    let firmware_version:ChatDeviceVersion
    let app_version:ChatDeviceVersion
    var valid:Bool { id > 0 && package == "Chat" && !identity.isEmpty && identity.utf8.count <= 4096 && device_name.utf8.count <= 1024 }
    var parameter:ChatParameter { .object(["id":.integer(id),"device_name":.string(device_name),"identity":.string(identity),"package":.string(package),"firmware_version":firmware_version.parameter,"app_version":app_version.parameter]) }
}
enum ChatDeviceVersion:Decodable,Equatable {
    case integer(Int64),number(Double),text(String)
    init(from decoder:Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int64.self),n >= 0 { self = .integer(n) }
        else if let n = try? c.decode(Double.self),n.isFinite,n >= 0 { self = .number(n) }
        else { let s = try c.decode(String.self);guard s.utf8.count <= 256 else { throw ChatAPIError.invalidResponse };self = .text(s) }
    }
    var display:String { switch self { case .integer(let n):return String(n);case .number(let n):return String(n);case .text(let s):return s.isEmpty ? "Unknown" : s } }
    var parameter:ChatParameter { switch self { case .integer(let n):return .integer(n);case .number(let n):return .number(n);case .text(let s):return .string(s) } }
}
struct ChatPairedDevicesSnapshot {
    let devices:[ChatPairedDevice]
    let accountGeneration:Int
}
struct ChatDeviceUpdateFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}
