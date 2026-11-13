import XCTest
@testable import SynologyChatNative

@MainActor final class ChatNotificationSettingsTests:XCTestCase {
    override func setUp() { super.setUp();PreferenceProtocol.reset() }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [PreferenceProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://preferences.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config));try await api.discover();return api
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:try await api(),restoreNotificationPreference:false);model.connected = true;model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    func testAbsentDisabledTimesHaveOfficialDefaultsWithoutWritingThemAndMidnightIsPreserved() async throws {
        let settings = try await api().notificationSettings();var draft = ChatNotificationSettingsDraft(settings)
        XCTAssertEqual(draft.start,64800);XCTAssertEqual(draft.end,32400);XCTAssertTrue(try draft.patch(from:settings).isEmpty)
        PreferenceProtocol.preferences["snooze_schedule_start"] = 0
        let midnight = try await api().notificationSettings();XCTAssertEqual(ChatNotificationSettingsDraft(midnight).start,0)
        draft.scheduleEnabled = true;draft.start = 0
        let patch = try draft.patch(from:settings);XCTAssertNotNil(patch["snooze_schedule_start"])
    }
    func testScheduleValidationAllowsOvernightButRejectsEqualOrNonHalfHourTimes() async throws {
        let source = try await api().notificationSettings();var draft = ChatNotificationSettingsDraft(source);draft.scheduleEnabled = true
        XCTAssertNoThrow(try draft.patch(from:source))
        for pair in [(0,0),(-1800,3600),(3600,86400),(900,3600)] { draft.start = pair.0;draft.end = pair.1;XCTAssertThrowsError(try draft.patch(from:source)) }
    }
    func testUnchangedLegacyScheduleIsNotRewrittenByAlertEdits() async throws {
        PreferenceProtocol.preferences["snooze_schedule_enable"] = true;PreferenceProtocol.preferences["snooze_schedule_start"] = 900;PreferenceProtocol.preferences["snooze_schedule_end"] = 3600
        let model = try await model(),source = try await model.loadNotificationSettings();var draft = ChatNotificationSettingsDraft(source.settings);draft.mute = true
        _ = try await model.saveNotificationSettings(original:source,draft:draft)
        XCTAssertNil(PreferenceProtocol.lastPatch?["snooze_schedule_start"]);XCTAssertEqual(PreferenceProtocol.lastPatch?["notification_mute"],"true")
    }
    func testDirtyPatchWritesOnlyChangedFieldsAndDisabledScheduleKeepsStoredTimes() async throws {
        let model = try await model(),source = try await model.loadNotificationSettings();model.selection = 93;model.draft = "Unsent draft";var draft = ChatNotificationSettingsDraft(source.settings);draft.showMessage = false
        let updated = try await model.saveNotificationSettings(original:source,draft:draft)
        XCTAssertFalse(updated.settings.notification_showmessage);XCTAssertEqual(model.selection,93);XCTAssertEqual(model.draft,"Unsent draft")
        XCTAssertEqual(PreferenceProtocol.lastPatch?["notification_showmessage"],"false");XCTAssertNil(PreferenceProtocol.lastPatch?["snooze"]);XCTAssertNil(PreferenceProtocol.lastPatch?["snooze_schedule_start"])
        XCTAssertEqual(PreferenceProtocol.lastPatch?["version"],"4");XCTAssertEqual(PreferenceProtocol.lastPatch?["api"],"SYNO.Chat.User.Preference")
        var schedule = ChatNotificationSettingsDraft(updated.settings);schedule.scheduleEnabled = true;_ = try await model.saveNotificationSettings(original:updated,draft:schedule)
        let enabled = try await model.loadNotificationSettings();var disabled = ChatNotificationSettingsDraft(enabled.settings);disabled.scheduleEnabled = false
        let after = try await model.saveNotificationSettings(original:enabled,draft:disabled)
        XCTAssertEqual(after.settings.snooze_schedule_start,64800);XCTAssertEqual(after.settings.snooze_schedule_end,32400);XCTAssertNil(PreferenceProtocol.lastPatch?["snooze_schedule_start"])
    }
    func testManualPauseUsesFreshServerTimeAndResumeWritesZero() async throws {
        let model = try await model(),source = try await model.loadNotificationSettings()
        PreferenceProtocol.offset = 7200
        let before = Date().timeIntervalSince1970*1000
        let paused = try await model.setNotificationSnooze(minutes:20,original:source)
        XCTAssertEqual(Double(paused.settings.snooze)-before,8_400_000,accuracy:500)
        XCTAssertNil(PreferenceProtocol.lastPatch?["snooze_schedule_enable"])
        let resumed = try await model.setNotificationSnooze(minutes:0,original:paused);XCTAssertEqual(resumed.settings.snooze,0)
    }
    func testRemoteChangedFieldRejectsButUnrelatedPreferencesArePreserved() async throws {
        let model = try await model(),source = try await model.loadNotificationSettings();var draft = ChatNotificationSettingsDraft(source.settings);draft.showMessage = false
        PreferenceProtocol.preferences["notification_showmessage"] = false
        do { _ = try await model.saveNotificationSettings(original:source,draft:draft);XCTFail("Stale preference overwrote") } catch let error as ChatPreferenceUpdateFailure { XCTAssertFalse(error.uncertain) }
        XCTAssertEqual(PreferenceProtocol.writes,0)
        PreferenceProtocol.preferences["notification_showmessage"] = true;PreferenceProtocol.preferences["notification_mute"] = true
        let after = try await model.saveNotificationSettings(original:source,draft:draft)
        XCTAssertTrue(after.settings.notification_mute);XCTAssertNil(PreferenceProtocol.lastPatch?["notification_mute"])
    }
    func testIgnoredWriteRequiresAuthoritativeRefreshBeforeAnotherMutation() async throws {
        let model = try await model(),source = try await model.loadNotificationSettings();PreferenceProtocol.ignoreWrite = true
        do { _ = try await model.setNotificationSnooze(minutes:20,original:source);XCTFail("Ignored pause confirmed") } catch let error as ChatPreferenceUpdateFailure { XCTAssertTrue(error.uncertain) }
        XCTAssertTrue(model.notificationPreferencesNeedRefresh)
        do { _ = try await model.setNotificationSnooze(minutes:20,original:source);XCTFail("Uncertain pause repeated") } catch { }
        XCTAssertEqual(PreferenceProtocol.writes,1)
        let refreshed = try await model.loadNotificationSettings();XCTAssertFalse(model.notificationPreferencesNeedRefresh)
        PreferenceProtocol.ignoreWrite = false;_ = try await model.setNotificationSnooze(minutes:20,original:refreshed)
        XCTAssertEqual(PreferenceProtocol.writes,2)
    }
    func testSignOutAfterDispatchCannotPublishPreferenceReadback() async throws {
        let model = try await model(),source = try await model.loadNotificationSettings(),started = expectation(description:"Preference held")
        PreferenceProtocol.holdWrite = true;PreferenceProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.setNotificationSnooze(minutes:20,original:source) }
        await fulfillment(of:[started],timeout:2);let reads = PreferenceProtocol.reads;model.signOutLocally();PreferenceProtocol.held?.finish(["success":true]);PreferenceProtocol.held = nil
        do { _ = try await action.value;XCTFail("Old account preferences published") } catch is CancellationError { }
        XCTAssertEqual(PreferenceProtocol.reads,reads);XCTAssertFalse(model.notificationPreferencesBusy)
    }
    func testCancellationAfterDispatchKeepsRefreshRequired() async throws {
        let model = try await model(),source = try await model.loadNotificationSettings(),started = expectation(description:"Preference held")
        PreferenceProtocol.holdWrite = true;PreferenceProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.setNotificationSnooze(minutes:20,original:source) }
        await fulfillment(of:[started],timeout:2);action.cancel();PreferenceProtocol.held?.finish(["success":true]);PreferenceProtocol.held = nil
        do { _ = try await action.value;XCTFail("Cancelled pause confirmed") } catch { }
        XCTAssertTrue(model.notificationPreferencesNeedRefresh);XCTAssertEqual(PreferenceProtocol.writes,1)
    }
    func testInvalidDurationAndUnexpectedPreferenceCannotWrite() async throws {
        let model = try await model(),source = try await model.loadNotificationSettings(),api = try await api()
        for minutes in [-1,1,Int.max] { do { _ = try await model.setNotificationSnooze(minutes:minutes,original:source);XCTFail("Invalid duration sent") } catch { } }
        for patch:[String:ChatParameter] in [["password":.string("synthetic")],["notification_mute":.string("true")],["snooze":.integer(-1)],["snooze_schedule_enable":.bool(true)],["snooze_schedule_enable":.bool(true),"snooze_schedule_start":.integer(0),"snooze_schedule_end":.integer(0)]] { do { try await api.setNotificationSettings(patch);XCTFail("Invalid patch sent") } catch { } }
        XCTAssertEqual(PreferenceProtocol.writes,0)
    }
    func testSnoozeFieldsDecodeAndSuppressActualNotificationUntilExpiry() throws {
        let prefs = try JSONDecoder().decode(ChatNotificationPreferences.self,from:Data(#"{"notification_showmessage":true,"notification_browser_active":true,"notification_mute":false,"snooze":2000000,"snooze_schedule_enable":false}"#.utf8))
        XCTAssertEqual(prefs.snooze,2_000_000)
        let payload = try JSONDecoder().decode(ChatJSON.self,from:Data(#"{"post":{"post_id":200,"channel_id":93,"creator_id":6,"type":"normal","message":"Synthetic","create_at":1000}}"#.utf8))
        let event = ChatLiveEvent(name:"client.notification.create",payload:payload)
        XCTAssertNil(ChatNotificationMessage.make(event:event,preferences:prefs,currentUserID:10,visibleChannelID:nil,channelTitle:"Peter",now:Date(timeIntervalSince1970:1000)))
        XCTAssertNotNil(ChatNotificationMessage.make(event:event,preferences:prefs,currentUserID:10,visibleChannelID:nil,channelTitle:"Peter",now:Date(timeIntervalSince1970:2000)))
    }
    func testQuietHoursUseAccountTimezoneAndOvernightBoundaries() throws {
        var prefs = ChatNotificationPreferences(notification_showmessage:true,notification_browser_active:true,notification_mute:false,snooze:0,snooze_schedule_enable:true,snooze_schedule_start:64800,snooze_schedule_end:32400)
        let zone = TimeZone(identifier:"America/New_York")!,formatter = ISO8601DateFormatter()
        for (iso,paused) in [("2026-10-18T21:59:59Z",false),("2026-10-18T22:00:00Z",true),("2026-10-19T12:59:59Z",true),("2026-10-19T13:00:00Z",false),("2026-11-01T05:30:00Z",true),("2026-11-01T06:30:00Z",true)] { XCTAssertEqual(prefs.pausesAlerts(at:formatter.date(from:iso)!,timeZone:zone),paused) }
        XCTAssertTrue(prefs.pausesAlerts(at:Date(),timeZone:nil))
        prefs.snooze_schedule_start = 32400;prefs.snooze_schedule_end = 61200
        XCTAssertTrue(prefs.pausesAlerts(at:formatter.date(from:"2026-10-19T14:00:00Z")!,timeZone:zone))
        XCTAssertFalse(prefs.pausesAlerts(at:formatter.date(from:"2026-10-19T22:00:00Z")!,timeZone:zone))
        prefs.snooze_schedule_enable = false;prefs.snooze = 2_000_000
        XCTAssertTrue(prefs.pausesAlerts(at:Date(timeIntervalSince1970:1000),timeZone:nil));XCTAssertFalse(prefs.pausesAlerts(at:Date(timeIntervalSince1970:2000),timeZone:nil))
    }
}

private final class PreferenceProtocol:URLProtocol {
    static let initial:[String:Any] = ["notification_showmessage":true,"notification_browser_active":true,"notification_mute":false,"snooze":0,"snooze_schedule_enable":false]
    static var preferences = initial
    static var writes = 0,reads = 0
    static var offset:TimeInterval = 0
    static var ignoreWrite = false,holdWrite = false
    static var lastPatch:[String:String]?
    static var held:PreferenceProtocol?
    static var onWrite:(()->Void)?
    static func reset() { preferences = initial;writes = 0;reads = 0;offset = 0;ignoreWrite = false;holdWrite = false;lastPatch = nil;held = nil;onWrite = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.User.Preference","SYNO.Chat.Misc"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":4,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        var fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });fields["api"] = request.url!.lastPathComponent
        if fields["api"] == "SYNO.Chat.Misc" { finish(["success":true,"data":["time":(Date().timeIntervalSince1970+Self.offset)*1000]]);return }
        if fields["method"] == "set" {
            Self.writes += 1;Self.lastPatch = fields
            if !Self.ignoreWrite { for (key,value) in fields where Self.initial[key] != nil || key.hasPrefix("snooze_schedule_") { if let decoded = try? JSONSerialization.jsonObject(with:Data(value.utf8),options:.fragmentsAllowed) { Self.preferences[key] = decoded } } }
            if Self.holdWrite { Self.held = self;Self.onWrite?();return };finish(["success":true]);return
        }
        Self.reads += 1;finish(["success":true,"data":["preferences":Self.preferences]])
    }
    func finish(_ value:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
