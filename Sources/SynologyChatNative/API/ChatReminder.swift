import Foundation

/// Personal reminder metadata comes from Post.Reminder/list, not ordinary timeline posts.
struct ChatReminder:Identifiable {
    let post:ChatPost
    let remindAt:Double
    var id:Int64 { post.id }
    var date:Date { Date(timeIntervalSince1970:remindAt/1000) }
    init(post:ChatPost) throws {
        guard post.id > 0,post.channel_id > 0,let time = post.props?.remind_at,
              ChatReminderTime.valid(time),time > 0 else { throw ChatAPIError.invalidResponse }
        self.post = post;remindAt = time
    }
}

enum ChatReminderTime {
    static func valid(_ value:Double) -> Bool { value.isFinite && value >= 0 && value < 253402300800000 && value.rounded(.down) == value }
    static func future(_ date:Date,now:Date = Date()) throws -> Double {
        let time = (date.timeIntervalSince1970*1000).rounded(.down)
        guard valid(time),time > now.timeIntervalSince1970*1000 else { throw ChatReminderFailure(uncertain:false,message:"Choose a reminder time in the future.") }
        return time
    }
}

struct ChatReminderFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}
