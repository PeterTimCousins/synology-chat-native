import XCTest
@testable import SynologyChatNative

@MainActor final class ChatCalendarTests: XCTestCase {
    override func setUp() { super.setUp(); CalendarProtocol.reset() }
    private func api() async throws -> ChatAPIClient {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [CalendarProtocol.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://calendar.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: c))
        try await api.discover(); return api
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [CalendarProtocol.self]
            return try ChatAPIClient(session: session, network: URLSession(configuration: c))
        })
        await model.connect(using: .init(session: .init(baseURL: URL(string: "https://calendar.invalid")!, sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false))
        model.liveStatus = .live; model.selection = 93; XCTAssertTrue(model.connected)
        addTeardownBlock { @MainActor in model.signOutLocally() }; return model
    }
    private var post: ChatPost { try! JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":123,"channel_id":93,"creator_id":10,"message":"Meet on 15 January 2030 at 10:00","type":"normal","create_at":1000}"#.utf8)) }
    private func draft(_ calendar: ChatCalendar) -> ChatCalendarDraft {
        .init(calendarID: calendar.id, title: "Synthetic event", start: Date(timeIntervalSince1970: 1894701600), end: Date(timeIntervalSince1970: 1894705200), allDay: false, timeZoneID: "Europe/London")
    }
    func testCalendarPreferenceUsesSingleFieldPatchAndVerifiedReadback() async throws {
        let model = try await model(),before = try await model.loadCalendarDetectionPreference()
        XCTAssertTrue(before.enabled)
        let after = try await model.saveCalendarDetectionPreference(false,original:before)
        XCTAssertFalse(after.enabled);XCTAssertEqual(model.calendarDetection,false)
        XCTAssertEqual(CalendarProtocol.preferenceWrites,1)
        XCTAssertEqual(Set(CalendarProtocol.lastPreferencePatch?.keys.map { $0 } ?? []),["api","method","version","calendar_enable"])
        XCTAssertEqual(CalendarProtocol.lastPreferencePatch?["calendar_enable"],"false")
        XCTAssertFalse(model.calendarSettingsNeedRefresh);XCTAssertFalse(model.calendarSettingsBusy)
    }
    func testCalendarPreferenceRejectsChangedServerAndStaleAccountWithoutWriting() async throws {
        let model = try await model(),before = try await model.loadCalendarDetectionPreference()
        CalendarProtocol.enabled = false
        do { _ = try await model.saveCalendarDetectionPreference(false,original:before);XCTFail("Overwrote external change") } catch {}
        XCTAssertEqual(CalendarProtocol.preferenceWrites,0)
        model.signOutLocally()
        do { _ = try await model.saveCalendarDetectionPreference(false,original:before);XCTFail("Accepted old account") } catch {}
        XCTAssertEqual(CalendarProtocol.preferenceWrites,0)
    }
    func testUnconfirmedCalendarPreferenceRequiresReadBeforeAnotherWrite() async throws {
        let model = try await model(),before = try await model.loadCalendarDetectionPreference()
        CalendarProtocol.refusePreference = true
        do { _ = try await model.saveCalendarDetectionPreference(false,original:before);XCTFail("Accepted unconfirmed write") } catch {}
        XCTAssertTrue(model.calendarSettingsNeedRefresh);XCTAssertEqual(CalendarProtocol.preferenceWrites,1)
        do { _ = try await model.saveCalendarDetectionPreference(false,original:before);XCTFail("Repeated uncertain write") } catch {}
        XCTAssertEqual(CalendarProtocol.preferenceWrites,1)
        _ = try await model.loadCalendarDetectionPreference();XCTAssertFalse(model.calendarSettingsNeedRefresh)
    }
    func testCancelledCalendarPreferenceSaveDoesNotPublishReadbackAndBlocksRetry() async throws {
        let model = try await model(),before = try await model.loadCalendarDetectionPreference(),started = expectation(description:"Preference dispatched")
        CalendarProtocol.holdPreference = true;CalendarProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.saveCalendarDetectionPreference(false,original:before) }
        await fulfillment(of:[started],timeout:2);action.cancel()
        CalendarProtocol.held?.finish(["success":true,"data":[:]]);CalendarProtocol.held = nil
        do { _ = try await action.value;XCTFail("Cancelled save published") } catch {}
        XCTAssertTrue(model.calendarSettingsNeedRefresh);XCTAssertFalse(model.calendarSettingsBusy)
        XCTAssertEqual(model.calendarDetection,true);XCTAssertEqual(CalendarProtocol.preferenceWrites,1)
    }
    func testCalendarDetectionPreservesCodeURLsAndUnicodeAndRoundTripsStrictDestinations() throws {
        let text = ChatMessageFormatting.inline("👋 Meet on 15 January 2030 at 10:00. `15 January 2030` https://example.test/2030-01-15", calendarLinks: true)
        let dates = text.runs.compactMap(\.link).filter { $0.scheme == "synology-chat-calendar" }
        XCTAssertEqual(dates.count, 1)
        let date = try XCTUnwrap(dates.first.flatMap(ChatDateLinks.selection)); XCTAssertFalse(date.allDay)
        XCTAssertEqual(date.destination, dates.first)
        XCTAssertTrue(text.runs.contains { $0.link?.scheme == "https" })
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.link == nil })
        XCTAssertTrue(ChatMessageFormatting.inline("15 January 2030").runs.allSatisfy { $0.link == nil })
        let allDay = ChatMessageFormatting.inline("15 January 2030", calendarLinks: true)
        XCTAssertTrue(try XCTUnwrap(allDay.runs.compactMap(\.link).first.flatMap(ChatDateLinks.selection)).allDay)
        for raw in ["synology-chat-calendar://event?date=-1&allDay=1&text=date", "synology-chat-calendar://event?date=1&allDay=1&text=date&extra=1", "https://event?date=1&allDay=1&text=date", "synology-chat-calendar://event?date=1&allDay=1&text=date#fragment"] {
            XCTAssertNil(ChatDateLinks.selection(URL(string: raw)!))
        }
    }
    func testAllDayUsesCivilUTCAndExclusiveEndAcrossDSTAndTimedUsesInstants() throws {
        let cal = try JSONDecoder().decode(ChatCalendar.self, from: JSONSerialization.data(withJSONObject: CalendarProtocol.calendar))
        var d = draft(cal)
        let iso = ISO8601DateFormatter()
        d.start = iso.date(from: "2026-03-28T18:00:00Z")!; d.end = iso.date(from: "2026-03-29T18:00:00Z")!; d.allDay = true
        let p = try d.parameters(calendar: cal)
        XCTAssertEqual(try encoded(p["dtstart"]), "1774656000") // March 28 UTC civil midnight
        XCTAssertEqual(try encoded(p["dtend"]), "1774828800") // March 30 exclusive
        XCTAssertEqual(try encoded(p["tz_id"]), #""""#)
        d.allDay = false
        let timed = try d.parameters(calendar: cal)
        XCTAssertEqual(try encoded(timed["dtstart"]), String(Int64(d.start.timeIntervalSince1970)))
        for invalid in ["", "Invalid/Zone"] { d.timeZoneID = invalid; XCTAssertThrowsError(try d.parameters(calendar: cal)) }
        d.timeZoneID = "Europe/London"; d.end = d.start; XCTAssertThrowsError(try d.parameters(calendar: cal))
        d.end = d.start.addingTimeInterval(3600); d.title = "  \n"; XCTAssertThrowsError(try d.parameters(calendar: cal))
    }
    private func encoded(_ p: ChatParameter?) throws -> String { String(decoding: try JSONEncoder().encode(XCTUnwrap(p)), as: UTF8.self) }
    func testOnlyOwnExplicitlyUnsharedCalendarsCanCreateAndUnknownACLsFailClosed() async throws {
        let api = try await api(), cal = try await api.calendars()[0]
        _ = try await api.privateCalendar(cal, owner: "synthetic")
        for acl: [String: Any] in [["DSM_USER": [["name": "other"]], "DSM_GROUP": []], ["DSM_USER": [], "DSM_GROUP": [], "NEW_TYPE": []], ["DSM_USER": []]] {
            CalendarProtocol.acl = acl
            do { _ = try await api.privateCalendar(cal, owner: "synthetic"); XCTFail("Sharing was accepted") } catch { }
        }
        CalendarProtocol.acl = ["DSM_USER": [], "DSM_GROUP": []]
        for patch: [String: Any] in [["original_ug_name": "other"], ["cal_privilege": "RO"], ["cal_public_sharing_id": "public"]] {
            CalendarProtocol.calendar.merge(patch) { _, new in new }
            do { _ = try await api.privateCalendar(cal, owner: "synthetic"); XCTFail("Unsafe calendar accepted") } catch { }
            CalendarProtocol.resetCalendar()
        }
        XCTAssertEqual(CalendarProtocol.writes, 0)
    }
    func testCreateUsesEmptyAttendeesAndRemindersAndCanonicalReadbackWithoutChangingChat() async throws {
        let model = try await model(), options = try await model.loadCalendarEventOptions(for: post)
        model.draft = "Keep unsent"
        let result = try await model.createCalendarEvent(draft(options.calendars[0]), post: post, snapshot: options)
        XCTAssertEqual(result.summary, "Synthetic event"); XCTAssertTrue(result.participant.isEmpty)
        XCTAssertEqual(CalendarProtocol.writes, 1); XCTAssertEqual(CalendarProtocol.eventReads, 1)
        XCTAssertEqual(CalendarProtocol.lastCreate?["participant"], "[]"); XCTAssertEqual(CalendarProtocol.lastCreate?["notify_setting"], "[]")
        XCTAssertNil(CalendarProtocol.lastCreate?["need_invite_response"])
        XCTAssertFalse(model.calendarBusy); XCTAssertTrue(model.uncertainCalendarPosts.isEmpty)
        XCTAssertEqual(model.draft, "Keep unsent"); XCTAssertEqual(model.selection, 93)
    }
    func testSharingOrPreferenceChangesBeforeCreatePreventDispatch() async throws {
        let model = try await model(), options = try await model.loadCalendarEventOptions(for: post), d = draft(options.calendars[0])
        CalendarProtocol.acl["DSM_GROUP"] = [["name": "other"]]
        do { _ = try await model.createCalendarEvent(d, post: post, snapshot: options); XCTFail("New share ignored") } catch { }
        CalendarProtocol.acl = ["DSM_USER": [], "DSM_GROUP": []]; CalendarProtocol.enabled = false
        do { _ = try await model.createCalendarEvent(d, post: post, snapshot: options); XCTFail("Disabled preference ignored") } catch { }
        XCTAssertEqual(CalendarProtocol.writes, 0); XCTAssertTrue(model.uncertainCalendarPosts.isEmpty)
    }
    func testUnconfirmedCreationBlocksRepeatingEvenAfterRefreshingOptions() async throws {
        let model = try await model(), options = try await model.loadCalendarEventOptions(for: post), d = draft(options.calendars[0]); CalendarProtocol.mismatch = true
        do { _ = try await model.createCalendarEvent(d, post: post, snapshot: options); XCTFail("Mismatch confirmed") } catch { }
        XCTAssertTrue(model.uncertainCalendarPosts.contains(post.id))
        do { _ = try await model.createCalendarEvent(d, post: post, snapshot: options); XCTFail("Repeated create") } catch { }
        do { _ = try await model.loadCalendarEventOptions(for: post); XCTFail("Uncertain state forgotten") } catch { }
        XCTAssertEqual(CalendarProtocol.writes, 1); XCTAssertFalse(model.calendarBusy)
    }
    func testLostPermissionsAndOldAccountSnapshotCannotCreate() async throws {
        let model = try await model(), options = try await model.loadCalendarEventOptions(for: post), d = draft(options.calendars[0])
        let channels = model.channels; model.channels = []
        do { _ = try await model.createCalendarEvent(d, post: post, snapshot: options); XCTFail("Lost channel accepted") } catch { }
        model.channels = channels; model.signOutLocally()
        do { _ = try await model.createCalendarEvent(d, post: post, snapshot: options); XCTFail("Old account accepted") } catch { }
        XCTAssertEqual(CalendarProtocol.writes, 0)
    }
    func testCancellationAfterDispatchCannotRetryOrReadOldResult() async throws {
        let model = try await model(), options = try await model.loadCalendarEventOptions(for: post), started = expectation(description: "Event dispatched")
        CalendarProtocol.hold = true; CalendarProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.createCalendarEvent(draft(options.calendars[0]), post: post, snapshot: options) }
        await fulfillment(of: [started], timeout: 2); action.cancel(); CalendarProtocol.held?.finish(["success": true, "data": CalendarProtocol.event]); CalendarProtocol.held = nil
        do { _ = try await action.value; XCTFail("Cancelled create published") } catch { }
        XCTAssertTrue(model.uncertainCalendarPosts.contains(post.id)); XCTAssertEqual(CalendarProtocol.eventReads, 0); XCTAssertFalse(model.calendarBusy)
    }
    func testSignOutAfterDispatchDoesNotReadBackIntoNewAccount() async throws {
        let model = try await model(), options = try await model.loadCalendarEventOptions(for: post), started = expectation(description: "Event dispatched")
        CalendarProtocol.hold = true; CalendarProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.createCalendarEvent(draft(options.calendars[0]), post: post, snapshot: options) }
        await fulfillment(of: [started], timeout: 2); model.signOutLocally(); CalendarProtocol.held?.finish(["success": true, "data": CalendarProtocol.event]); CalendarProtocol.held = nil
        do { _ = try await action.value; XCTFail("Old result published") } catch is CancellationError { }
        XCTAssertEqual(CalendarProtocol.eventReads, 0); XCTAssertFalse(model.calendarBusy); XCTAssertNil(model.calendarDetection)
    }
}

private final class CalendarProtocol: URLProtocol {
    static var calendar: [String: Any] = [:], acl: [String: Any] = [:], event: [String: Any] = [:]
    static var enabled = true, mismatch = false, hold = false
    static var writes = 0, eventReads = 0
    static var preferenceWrites = 0,refusePreference = false,holdPreference = false
    static var lastPreferencePatch:[String:String]?
    static var lastCreate: [String: String]?
    static var held: CalendarProtocol?
    static var onWrite: (() -> Void)?
    static func resetCalendar() { calendar = ["cal_id": "own", "original_cal_id": "original", "cal_displayname": "My private calendar", "original_ug_name": "synthetic", "cal_privilege": "RW", "cal_type": "event", "cal_public_sharing_id": "", "is_hidden_in_list": false] }
    static func reset() { preferenceWrites = 0;refusePreference = false;holdPreference = false;lastPreferencePatch = nil;resetCalendar(); acl = ["DSM_USER": [], "DSM_GROUP": []]; event = [:]; enabled = true; mismatch = false; hold = false; writes = 0; eventReads = 0; lastCreate = nil; held = nil; onWrite = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let name = request.url!.lastPathComponent
        if name == "SYNO.API.Info" {
            let names = ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Misc", "SYNO.Chat.User.Preference", "SYNO.Cal.Cal", "SYNO.Cal.Sharing", "SYNO.Cal.Setting", "SYNO.Cal.Event"]
            finish(["success": true, "data": Dictionary(uniqueKeysWithValues: names.map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 5, "requestFormat": "JSON"] as [String: Any]) })]); return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) } }
        var q = URLComponents(); q.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let fields = Dictionary((q.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        if name == "SYNO.Chat.User" { finish(["success": true, "data": ["users": [["user_id": 10, "username": "synthetic", "nickname": "Synthetic", "type": "human", "human_type": "dsm"]]]]); return }
        if name == "SYNO.Chat.Channel" { finish(["success": true, "data": ["channels": [["channel_id": 93, "name": "Peter", "type": "anonymous", "encrypted": false, "unread": 0, "is_joined": true]]]]); return }
        if name == "SYNO.Chat.Misc" { finish(["success": true, "data": ["acls": []]]); return }
        if name == "SYNO.Chat.User.Preference",fields["method"] == "set" {
            Self.preferenceWrites += 1;Self.lastPreferencePatch = fields
            if !Self.refusePreference { Self.enabled = fields["calendar_enable"] == "true" }
            if Self.holdPreference { Self.held = self;Self.onWrite?();return }
            finish(["success":true,"data":[:]]);return
        }
        if name == "SYNO.Chat.User.Preference" { finish(["success": true, "data": ["preferences": ["calendar_enable": Self.enabled]]]); return }
        if name == "SYNO.Cal.Cal" {
            let payload: [String: Any] = fields["method"] == "list" ? ["list": [Self.calendar]] : Self.calendar
            finish(["success": true, "data": payload]); return
        }
        if name == "SYNO.Cal.Sharing" { finish(["success": true, "data": ["own": Self.acl]]); return }
        if name == "SYNO.Cal.Setting" { finish(["success": true, "data": ["time_zone": "Europe/London"]]); return }
        if name == "SYNO.Cal.Event", fields["method"] == "create" {
            Self.writes += 1; Self.lastCreate = fields
            Self.event = ["evt_id": 1234, "participant": [], "notify_setting": [], "is_repeat_evt": false]
            for key in ["original_cal_id", "summary", "dtstart", "dtend", "is_all_day", "tz_id"] { Self.event[key] = try! JSONSerialization.jsonObject(with: Data(fields[key]!.utf8), options: .fragmentsAllowed) }
            if Self.hold { Self.held = self; Self.onWrite?(); return }
            finish(["success": true, "data": Self.event]); return
        }
        if name == "SYNO.Cal.Event", fields["method"] == "get" { Self.eventReads += 1; var e = Self.event; if Self.mismatch { e["summary"] = "Changed elsewhere" }; finish(["success": true, "data": e]); return }
        finish(["success": false, "error": ["code": 102]])
    }
    func finish(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: value); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
