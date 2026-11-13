import Foundation

struct ChatManualPresenceSnapshot {
    let userID:Int64
    let away:Bool
    let accountGeneration:Int
}
struct ChatManualPresenceFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}
