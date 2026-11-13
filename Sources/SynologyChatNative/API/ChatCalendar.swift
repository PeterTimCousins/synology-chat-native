import Foundation

/// Calendar v5 and Sharing v1, recovered from Synology Calendar's external popup.
struct ChatCalendar: Decodable, Equatable, Identifiable {
    let cal_id: String
    let original_cal_id: String
    let cal_displayname: String
    let original_ug_name: String
    let cal_privilege: String
    let cal_type: String
    let cal_public_sharing_id: String?
    let is_hidden_in_list: Bool?
    var id: String { cal_id }
    func eligible(owner: String) -> Bool {
        !cal_id.isEmpty && !original_cal_id.isEmpty && original_ug_name == owner && cal_privilege == "RW" && cal_type == "event" && cal_public_sharing_id == "" && is_hidden_in_list != true
    }
}

struct ChatCalendarSettings: Decodable { let time_zone: String }
struct ChatCalendarFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct ChatCalendarDraft: Equatable {
    var calendarID: String
    var title: String
    var start: Date
    /// Inclusive civil end date for all-day events, exclusive instant otherwise.
    var end: Date
    var allDay: Bool
    var timeZoneID: String

    func parameters(calendar: ChatCalendar) throws -> [String: ChatParameter] {
        guard calendarID == calendar.id, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf16.count <= 1000, start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              let zone = TimeZone(identifier: timeZoneID) else { throw ChatAPIError.invalidResponse }
        let first: Double, last: Double
        if allDay {
            var local = Calendar(identifier: .gregorian); local.timeZone = zone
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let startParts = local.dateComponents([.year, .month, .day], from: start)
            let endParts = local.dateComponents([.year, .month, .day], from: end)
            guard let a = utc.date(from: startParts), let b = utc.date(from: endParts), b >= a,
                  let exclusive = utc.date(byAdding: .day, value: 1, to: b) else { throw ChatAPIError.invalidResponse }
            first = a.timeIntervalSince1970; last = exclusive.timeIntervalSince1970
        } else {
            first = floor(start.timeIntervalSince1970); last = floor(end.timeIntervalSince1970)
            guard last > first else { throw ChatAPIError.invalidResponse }
        }
        guard first >= 0, last <= 253_402_214_400 else { throw ChatAPIError.invalidResponse }
        return ["cal_id": .string(calendar.id), "original_cal_id": .string(calendar.original_cal_id),
                "summary": .string(title), "is_all_day": .bool(allDay), "tz_id": .string(allDay ? "" : zone.identifier),
                "dtstart": .integer(Int64(first)), "dtend": .integer(Int64(last)), "is_repeat_evt": .bool(false),
                "color": .string(""), "description": .string(""), "participant": .array([]), "notify_setting": .array([]),
                "from_syno_app_url": .object(["app": .string("SYNO.SDS.Chat.Application")])]
    }
}

struct ChatCalendarEvent: Decodable {
    let evt_id: ChatJSON
    let original_cal_id: String
    let summary: String
    let dtstart: Int64
    let dtend: Int64
    let is_all_day: Bool
    let participant: [ChatJSON]
    let notify_setting: [ChatJSON]
    let is_repeat_evt: Bool
    let tz_id: String
    var id: ChatParameter? {
        switch evt_id {
        case .string(let id) where !id.isEmpty: return .string(id)
        case .integer(let id) where id > 0: return .integer(id)
        default: return nil
        }
    }
    func matches(_ draft: ChatCalendarDraft, calendar: ChatCalendar) throws -> Bool {
        let p = try draft.parameters(calendar: calendar)
        guard case .integer(let first) = p["dtstart"], case .integer(let last) = p["dtend"] else { return false }
        return id != nil && original_cal_id == calendar.original_cal_id && summary == draft.title && dtstart == first && dtend == last && is_all_day == draft.allDay && participant.isEmpty && notify_setting.isEmpty && !is_repeat_evt && tz_id == (draft.allDay ? "" : draft.timeZoneID)
    }
}

extension ChatAPIClient {
    func calendarDetectionEnabled() async throws -> Bool {
        let value: ChatJSON = try await perform(requestForCall(api: "SYNO.Chat.User.Preference", method: "get", version: 4))
        guard case .bool(let enabled) = value["preferences"]?["calendar_enable"] else { throw ChatAPIError.invalidResponse }
        return enabled
    }
    func setCalendarDetectionEnabled(_ enabled:Bool) async throws {
        try await callVoid(api:"SYNO.Chat.User.Preference",method:"set",version:4,parameters:["calendar_enable":.bool(enabled)])
    }
    func calendars() async throws -> [ChatCalendar] {
        struct Response: Decodable { let list: [ChatCalendar] }
        let response: Response = try await perform(requestForCall(api: "SYNO.Cal.Cal", method: "list", version: 5, parameters: ["cal_type": .string("event")]))
        return response.list
    }
    func calendarSettings() async throws -> ChatCalendarSettings {
        try await perform(requestForCall(api: "SYNO.Cal.Setting", method: "get", version: 5))
    }
    func privateCalendar(_ calendar: ChatCalendar, owner: String) async throws -> ChatCalendar {
        let fresh: ChatCalendar = try await perform(requestForCall(api: "SYNO.Cal.Cal", method: "get", version: 5, parameters: ["cal_id": .string(calendar.id)]))
        guard fresh.eligible(owner: owner), fresh.original_cal_id == calendar.original_cal_id else { throw ChatCalendarFailure(message: "This calendar is no longer writable and private to your account. Choose another calendar.") }
        let sharing: ChatJSON = try await perform(requestForCall(api: "SYNO.Cal.Sharing", method: "get", version: 1, parameters: ["cal_id": .string(calendar.id)]))
        guard case .object(let acl) = sharing[calendar.id], Set(acl.keys) == ["DSM_USER", "DSM_GROUP"],
              acl.values.allSatisfy({ if case .array(let entries) = $0 { return entries.isEmpty }; return false }) else {
            throw ChatCalendarFailure(message: "This calendar has sharing permissions, or its privacy could not be verified. Use an unshared calendar owned by your account.")
        }
        return fresh
    }
    func createCalendarEvent(_ draft: ChatCalendarDraft, calendar: ChatCalendar) async throws -> ChatCalendarEvent {
        try await perform(requestForCall(api: "SYNO.Cal.Event", method: "create", version: 5, parameters: draft.parameters(calendar: calendar)))
    }
    func calendarEvent(_ event: ChatCalendarEvent) async throws -> ChatCalendarEvent {
        guard let id = event.id else { throw ChatAPIError.invalidResponse }
        return try await perform(requestForCall(api: "SYNO.Cal.Event", method: "get", version: 5, parameters: ["evt_id": id]))
    }
}
