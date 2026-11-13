import Foundation

struct ChatScheduledMessage:Decodable,Identifiable,Equatable {
    let cronjob_id:Int64
    let message:String
    let send_at:Double
    var id:Int64 { cronjob_id }
    var date:Date { Date(timeIntervalSince1970:send_at/1000) }
    func validate() throws {
        guard id > 0,send_at.isFinite,send_at > 0,send_at < 253402300800000,ChatMessageText.isAllowed(message),!message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ChatAPIError.invalidResponse }
    }
}

struct ChatScheduleDraft:Equatable {
    var message = ""
    var date = Date(timeIntervalSince1970:ceil((Date().timeIntervalSince1970+600)/60)*60)
    // Only clear the ordinary composer if it still contains the draft that opened scheduling.
    var sourceComposerText:String? = nil
    var milliseconds:Double { (date.timeIntervalSince1970*1000).rounded(.down) }
    static func minutePrecision(_ date:Date) -> Date { Date(timeIntervalSince1970:floor(date.timeIntervalSince1970/60)*60) }
    func validated(now:Date = Date()) throws -> ChatScheduleDraft {
        guard ChatMessageText.isAllowed(message) else { throw ChatScheduleFailure(uncertain:false,message:"Scheduled messages have a 2,000-character limit.") }
        var value = self;value.message = message.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.message.isEmpty else { throw ChatScheduleFailure(uncertain:false,message:"Write a message before scheduling it.") }
        guard milliseconds.isFinite,milliseconds > now.timeIntervalSince1970*1000,milliseconds < 253402300800000 else { throw ChatScheduleFailure(uncertain:false,message:"Choose a time in the future.") }
        value.date = Date(timeIntervalSince1970:milliseconds/1000)
        return value
    }
}

struct ChatScheduleFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}
