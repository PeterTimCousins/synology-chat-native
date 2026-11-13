import Foundation

struct ChatNotificationSettings:Decodable,Equatable {
    let notification_showmessage:Bool
    let notification_browser_active:Bool
    let notification_mute:Bool
    let snooze:Int64
    let snooze_schedule_enable:Bool
    let snooze_schedule_start:Int?
    let snooze_schedule_end:Int?
    func validate() throws {
        guard snooze >= 0,snooze <= 8_000_000_000_000_000,
              !snooze_schedule_enable || (snooze_schedule_start.map { (0..<86400).contains($0) } == true && snooze_schedule_end.map { (0..<86400).contains($0) } == true && snooze_schedule_start != snooze_schedule_end) else { throw ChatAPIError.invalidResponse }
    }
    var fields:[String:ChatParameter] {
        var result:[String:ChatParameter] = ["notification_showmessage":.bool(notification_showmessage),"notification_browser_active":.bool(notification_browser_active),"notification_mute":.bool(notification_mute),"snooze":.integer(snooze),"snooze_schedule_enable":.bool(snooze_schedule_enable)]
        if let start = snooze_schedule_start { result["snooze_schedule_start"] = .integer(Int64(start)) }
        if let end = snooze_schedule_end { result["snooze_schedule_end"] = .integer(Int64(end)) }
        return result
    }
    func matches(_ other:Self,keys:Set<String>) -> Bool {
        keys.allSatisfy { key in
            guard let first = fields[key],let second = other.fields[key] else { return fields[key] == nil && other.fields[key] == nil }
            return (try? JSONEncoder().encode(first)) == (try? JSONEncoder().encode(second))
        }
    }
}
struct ChatNotificationSettingsDraft:Equatable {
    var showMessage:Bool
    var notifyVisible:Bool
    var mute:Bool
    var scheduleEnabled:Bool
    var start:Int
    var end:Int
    init(_ source:ChatNotificationSettings) {
        showMessage = source.notification_showmessage;notifyVisible = source.notification_browser_active;mute = source.notification_mute
        scheduleEnabled = source.snooze_schedule_enable;start = source.snooze_schedule_start ?? 64800;end = source.snooze_schedule_end ?? 32400
    }
    func patch(from source:ChatNotificationSettings) throws -> [String:ChatParameter] {
        var result:[String:ChatParameter] = [:]
        if showMessage != source.notification_showmessage { result["notification_showmessage"] = .bool(showMessage) }
        if notifyVisible != source.notification_browser_active { result["notification_browser_active"] = .bool(notifyVisible) }
        if mute != source.notification_mute { result["notification_mute"] = .bool(mute) }
        if scheduleEnabled {
            if !source.snooze_schedule_enable || start != source.snooze_schedule_start || end != source.snooze_schedule_end {
                guard (0..<86400).contains(start),(0..<86400).contains(end),start%1800 == 0,end%1800 == 0,start != end else { throw ChatTransferError(message:"Choose different start and end times in half-hour steps.") }
                result["snooze_schedule_enable"] = .bool(true);result["snooze_schedule_start"] = .integer(Int64(start));result["snooze_schedule_end"] = .integer(Int64(end))
            }
        } else if source.snooze_schedule_enable { result["snooze_schedule_enable"] = .bool(false) }
        return result
    }
}
struct ChatServerClock {
    let offset:TimeInterval
    func date(now:Date = Date())->Date { now.addingTimeInterval(offset) }
    func milliseconds(now:Date = Date())->Int64 { Int64((date(now:now).timeIntervalSince1970*1000).rounded(.down)) }
}
struct ChatNotificationSettingsSnapshot {
    let settings:ChatNotificationSettings
    let clock:ChatServerClock
    let timeZone:TimeZone?
    let accountGeneration:Int
}
struct ChatPreferenceUpdateFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}

extension ChatNotificationPreferences {
    var hasSnoozeConfiguration:Bool { (snooze ?? 0) > 0 || snooze_schedule_enable == true }
    func pausesAlerts(at date:Date,timeZone:TimeZone?) -> Bool {
        if let snooze,Double(snooze) > date.timeIntervalSince1970*1000 { return true }
        guard snooze_schedule_enable == true else { return false }
        guard let timeZone,let start = snooze_schedule_start,let end = snooze_schedule_end,(0..<86400).contains(start),(0..<86400).contains(end),start != end else { return true }
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour,.minute,.second],from:date),seconds = (parts.hour ?? 0)*3600+(parts.minute ?? 0)*60+(parts.second ?? 0)
        return start < end ? seconds >= start && seconds < end : seconds >= start || seconds < end
    }
}
