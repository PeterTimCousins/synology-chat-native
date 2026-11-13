import XCTest
@testable import SynologyChatNative

@MainActor final class ChatRegionalSettingsTests:XCTestCase {
    override func setUp() {super.setUp();RegionalProtocol.reset()}
    private func model() async throws -> NativeChatPreviewModel {
        let m = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [RegionalProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:c))
        })
        await m.connect(using:.init(session:.init(baseURL:URL(string:"https://regional.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        XCTAssertTrue(m.connected);addTeardownBlock {@MainActor in m.signOutLocally()};return m
    }
    func testFreshPersonalMergePreservesUnknownFieldsAndOtherSections() async throws {
        let m = try await model(),before = try await m.loadRegionalSettings();var draft = ChatRegionalDraft(before.personal);draft.timeFormat = "H:i"
        RegionalProtocol.personal["other"] = ["nested":[true,NSNull(),1.25]];RegionalProtocol.personal["lang"] = "enu"
        m.selection = 93;m.draft = "Keep unsent text"
        let result = try await m.saveRegionalSettings(draft,original:before)
        XCTAssertEqual(result.personal.language,"enu");XCTAssertEqual(result.personal.timeFormat,"H:i");XCTAssertEqual(m.draft,"Keep unsent text")
        let outer = RegionalProtocol.lastApplied!;XCTAssertEqual(Set(outer.keys),["Personal"])
        let personal = outer["Personal"] as! [String:Any];XCTAssertNotNil(personal["other"])
        XCTAssertEqual(RegionalProtocol.writes,1);XCTAssertEqual(RegionalProtocol.lastWrite?["version"],"1")
    }
    func testChangedDirtyFieldAndUnsupportedCodeDoNotDispatch() async throws {
        let m = try await model(),before = try await m.loadRegionalSettings();var draft = ChatRegionalDraft(before.personal);draft.timeFormat = "H:i";RegionalProtocol.personal["timeFormat"] = "system"
        do {_ = try await m.saveRegionalSettings(draft,original:before);XCTFail("Stale preference overwritten")} catch {}
        draft.timeFormat = "invented"
        do {_ = try await m.saveRegionalSettings(draft,original:before);XCTFail("Unsupported format wrote")} catch {}
        XCTAssertEqual(RegionalProtocol.writes,0)
    }
    func testNoOpAndAbsentDefaultsDoNotAddPersonalFields() async throws {
        let m = try await model();RegionalProtocol.personal = [:];let before = try await m.loadRegionalSettings()
        XCTAssertEqual(before.personal.language,"def");XCTAssertEqual(before.personal.dateFormat,"system")
        _ = try await m.saveRegionalSettings(ChatRegionalDraft(before.personal),original:before)
        XCTAssertEqual(RegionalProtocol.writes,0);XCTAssertTrue(RegionalProtocol.personal.isEmpty)
    }
    func testTimezoneOnlyPatchValidatesFreshCatalogueAndPolicy() async throws {
        let m = try await model(),before = try await m.loadRegionalSettings()
        let result = try await m.saveRegionalTimeZone("London",original:before)
        XCTAssertEqual(result.timezone,"London");XCTAssertEqual(RegionalProtocol.lastWrite?["timezone"],"\"London\"")
        for key in ["nickname","description","is_always_offline","email","user_id"] {XCTAssertNil(RegionalProtocol.lastWrite?[key])}
        RegionalProtocol.readonly = ["timezone"]
        do {_ = try await m.saveRegionalTimeZone("def",original:result);XCTFail("Managed timezone wrote")} catch {}
        RegionalProtocol.readonly = []
        do {_ = try await m.saveRegionalTimeZone("Invented",original:result);XCTFail("Unknown timezone wrote")} catch {}
        XCTAssertEqual(RegionalProtocol.writes,1)
    }
    func testDefaultTimezoneCanonicalEmptyRestoresWithoutFalseUncertainty() async throws {
        let m = try await model();RegionalProtocol.timezone = "";let before = try await m.loadRegionalSettings()
        _ = try await m.saveRegionalTimeZone("def",original:before);XCTAssertEqual(RegionalProtocol.writes,0)
        let london = try await m.saveRegionalTimeZone("London",original:before)
        let restored = try await m.saveRegionalTimeZone("def",original:london)
        XCTAssertEqual(restored.timezone,"");XCTAssertEqual(restored.selectedTimeZone,"def");XCTAssertFalse(m.regionalSettingsNeedRefresh);XCTAssertEqual(RegionalProtocol.lastWrite?["timezone"],"\"\"")
    }
    func testSocketProfileReadCanSupersedeReadbackWithoutRepeatingTimezoneWrite() async throws {
        let m = try await model(),before = try await m.loadRegionalSettings()
        RegionalProtocol.onTimezoneSet = {
            RegionalProtocol.onUserRead = { held in
                Task { @MainActor in
                    try await m.refreshUserProfiles()
                    held.finish(RegionalProtocol.userResponse())
                }
            }
        }
        let result = try await m.saveRegionalTimeZone("London",original:before)
        XCTAssertEqual(result.timezone,"London");XCTAssertEqual(RegionalProtocol.writes,1);XCTAssertFalse(m.regionalSettingsNeedRefresh)
    }
    func testChangedRemoteTimezonePreventsStaleWrite() async throws {
        let m = try await model(),before = try await m.loadRegionalSettings();RegionalProtocol.timezone = "Berlin"
        do {_ = try await m.saveRegionalTimeZone("London",original:before);XCTFail("Stale timezone wrote")} catch {}
        XCTAssertEqual(RegionalProtocol.writes,0)
    }
    func testIgnoredWriteRequiresRefreshAndCannotRepeat() async throws {
        let m = try await model(),before = try await m.loadRegionalSettings();var draft = ChatRegionalDraft(before.personal);draft.dateFormat = "Y/m/d";RegionalProtocol.ignoreWrite = true
        do {_ = try await m.saveRegionalSettings(draft,original:before);XCTFail("Ignored write accepted")} catch {}
        XCTAssertTrue(m.regionalSettingsNeedRefresh)
        do {_ = try await m.saveRegionalSettings(draft,original:before);XCTFail("Uncertain write repeated")} catch {}
        XCTAssertEqual(RegionalProtocol.writes,1);RegionalProtocol.invalidPersonal = true
        do {_ = try await m.loadRegionalSettings();XCTFail("Bad refresh accepted")} catch {}
        XCTAssertTrue(m.regionalSettingsNeedRefresh);RegionalProtocol.invalidPersonal = false
        _ = try await m.loadRegionalSettings();XCTAssertFalse(m.regionalSettingsNeedRefresh)
    }
    func testMissingSettingsAndInvalidTimezoneOffsetFailClosed() async throws {
        let m = try await model();RegionalProtocol.invalidPersonal = true
        do {_ = try await m.loadRegionalSettings();XCTFail("Missing Personal accepted")} catch {}
        RegionalProtocol.invalidPersonal = false;RegionalProtocol.invalidOffset = true
        do {_ = try await m.loadRegionalSettings();XCTFail("Invalid zone accepted")} catch {}
        XCTAssertEqual(RegionalProtocol.writes,0)
    }
    func testSignOutAfterApplyCannotPublishOldPreferences() async throws {
        let m = try await model(),before = try await m.loadRegionalSettings();var d = ChatRegionalDraft(before.personal);d.timeFormat = "H:i";let draft = d,started = expectation(description:"Apply held")
        RegionalProtocol.holdWrite = true;RegionalProtocol.onWrite = {started.fulfill()}
        let action = Task {try await m.saveRegionalSettings(draft,original:before)}
        await fulfillment(of:[started],timeout:2);m.signOutLocally();RegionalProtocol.held?.finish(["success":true]);RegionalProtocol.held = nil
        do {_ = try await action.value;XCTFail("Old preference published")} catch is CancellationError {}
        XCTAssertNil(m.regionalDisplay);XCTAssertFalse(m.regionalSettingsBusy)
    }
    func testCancelledApplyRequiresFreshRead() async throws {
        let m = try await model(),before = try await m.loadRegionalSettings();var d = ChatRegionalDraft(before.personal);d.timeFormat = "H:i";let draft = d,started = expectation(description:"Apply held")
        RegionalProtocol.holdWrite = true;RegionalProtocol.onWrite = {started.fulfill()}
        let action = Task {try await m.saveRegionalSettings(draft,original:before)}
        await fulfillment(of:[started],timeout:2);action.cancel();RegionalProtocol.held?.finish(["success":true]);RegionalProtocol.held = nil
        do {_ = try await action.value;XCTFail("Cancelled apply confirmed")} catch {}
        XCTAssertTrue(m.regionalSettingsNeedRefresh);XCTAssertEqual(RegionalProtocol.writes,1)
    }
    func testFormattingUsesCalendarYearAndSavedFormats() throws {
        let d = ISO8601DateFormatter().date(from:"2019-12-30T15:04:00Z")!,zone = TimeZone(secondsFromGMT:0)!,defaults = ChatRegionalDefaults(Session:.init(date_format:"Y-m-d",time_format:"H:i"))
        let a = ChatRegionalDisplay(personal:.init(Personal:["dateFormat":.string("d/m/Y"),"timeFormat":.string("h:i a")]),defaults:defaults)
        XCTAssertEqual(a.format(d,zone:zone),"30/12/2019 03:04 pm")
        XCTAssertEqual(a.format(d,timeOnly:true,zone:zone),"03:04 pm")
        let b = ChatRegionalDisplay(personal:.init(Personal:[:]),defaults:defaults)
        XCTAssertEqual(b.format(d,zone:zone),"2019-12-30 15:04")
        for format in ChatRegionalDisplay.dateFormats {let x = ChatRegionalDisplay(personal:.init(Personal:["dateFormat":.string(format)]),defaults:defaults);XCTAssertTrue(x.format(d,dateOnly:true,zone:zone).contains("2019"))}
    }
}

private final class RegionalProtocol:URLProtocol {
    static let initial:[String:Any] = ["lang":"def","dateFormat":"d-m-Y","timeFormat":"h:i a"]
    static var personal = initial
    static var timezone = "def",readonly:[String] = []
    static var writes = 0
    static var invalidPersonal = false,invalidOffset = false,ignoreWrite = false,holdWrite = false
    static var lastWrite:[String:String]?,lastApplied:[String:Any]?
    static var held:RegionalProtocol?
    static var onWrite:(()->Void)?
    static var onTimezoneSet:(()->Void)?
    static var onUserRead:((RegionalProtocol)->Void)?
    static func userResponse()->[String:Any] {["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Synthetic Peter","user_props":["timezone":Self.timezone,"timezoneUTC":"GMT"]]]]]}
    static func reset() {personal = initial;timezone = "def";readonly = [];writes = 0;invalidPersonal = false;invalidOffset = false;ignoreWrite = false;holdWrite = false;lastWrite = nil;lastApplied = nil;held = nil;onWrite = nil;onTimezoneSet = nil;onUserRead = nil}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" {finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Core.UserSettings","SYNO.Core.Desktop.Initdata","SYNO.Core.Region.NTP","SYNO.Chat.Admin.Setting","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc"].map {($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any])})]);return}
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream {stream.open();defer {stream.close()};var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable {let n = stream.read(&b,maxLength:b.count);if n <= 0 {break};data.append(contentsOf:b.prefix(n))}}
        var q = URLComponents();q.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((q.queryItems ?? []).map {($0.name,$0.value ?? "")},uniquingKeysWith:{_,last in last}),api = request.url!.lastPathComponent,method = fields["method"] ?? ""
        if api == "SYNO.Core.UserSettings",method == "get" {finish(["success":true,"data":Self.invalidPersonal ? [:] : ["Personal":Self.personal,"Desktop":["unrelated":true]]]);return}
        if api == "SYNO.Core.UserSettings",method == "apply" {
            Self.writes += 1;Self.lastWrite = fields
            if let raw = fields["data"],let inner = try? JSONDecoder().decode(String.self,from:Data(raw.utf8)),let value = try? JSONSerialization.jsonObject(with:Data(inner.utf8)) as? [String:Any] {Self.lastApplied = value;if !Self.ignoreWrite,let p = value["Personal"] as? [String:Any] {Self.personal = p}}
            if Self.holdWrite {Self.held = self;Self.onWrite?();return};finish(["success":true]);return
        }
        if api == "SYNO.Core.Desktop.Initdata" {finish(["success":true,"data":["Session":["date_format":"Y-m-d","time_format":"H:i"]]]);return}
        if api == "SYNO.Core.Region.NTP" {finish(["success":true,"data":["zonedata":[["value":"London","display":"(GMT+00:00) London","offset":Self.invalidOffset ? Int.min : 0],["value":"Berlin","display":"(GMT+01:00) Berlin","offset":3600]]]]);return}
        if api == "SYNO.Chat.Admin.Setting" {finish(["success":true,"data":["readonly_profile":Self.readonly]]);return}
        if api == "SYNO.Chat.User",method == "set" {Self.writes += 1;Self.lastWrite = fields;if !Self.ignoreWrite,let raw = fields["timezone"],let tz = try? JSONDecoder().decode(String.self,from:Data(raw.utf8)) {Self.timezone = tz == "def" ? "" : tz};Self.onTimezoneSet?();finish(["success":true]);return}
        if api == "SYNO.Chat.User" {if let handler = Self.onUserRead {Self.onUserRead = nil;handler(self);return};finish(Self.userResponse());return}
        if api == "SYNO.Chat.Channel" {finish(["success":true,"data":["channels":[["channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"is_joined":true]]]]);return}
        if api == "SYNO.Chat.Misc" {finish(["success":true,"data":["acls":[]]]);return}
        finish(["success":false,"error":["code":102]])
    }
    func finish(_ value:[String:Any]) {let d = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:d);client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading() {}
}
