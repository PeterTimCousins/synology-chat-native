import XCTest
@testable import SynologyChatNative

@MainActor final class ChatChannelAlertsTests: XCTestCase {
    override func setUp() { super.setUp(); ChannelAlertsProtocol.reset() }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ChannelAlertsProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://channel-alerts.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"owner",importedFromOfficialApp:false))
        XCTAssertTrue(model.connected,model.error ?? "Failed connection");model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    func testDirtyDesktopWriteUsesPersonalV3AndPreservesMobileMuteKeysAndDraft() async throws {
        let model = try await model();model.selection = 93;model.draft = "Keep this draft"
        let source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "none"
        let saved = try await model.saveChannelAlerts(original:source,draft:draft)
        XCTAssertEqual(saved.settings.notification_desktop,"none");XCTAssertEqual(saved.settings.notification_mobile,"all")
        let fields = try XCTUnwrap(ChannelAlertsProtocol.writes.first)
        XCTAssertEqual(fields["api"],"SYNO.Chat.Channel.Preference");XCTAssertEqual(fields["version"],"3");XCTAssertEqual(fields["channel_id"],"93");XCTAssertEqual(fields["notification_desktop"],"\"none\"")
        XCTAssertNil(fields["notification_mobile"]);XCTAssertNil(fields["notification_mute"]);XCTAssertNil(fields["channel_key_enc"]);XCTAssertNil(fields["user_id"])
        XCTAssertEqual(ChannelAlertsProtocol.settings["notification_mute"] as? Bool,false);XCTAssertEqual(model.selection,93);XCTAssertEqual(model.draft,"Keep this draft")
    }
    func testMobileEditPreservesUnsupportedDesktopAndUnchangedLegacyMode() async throws {
        ChannelAlertsProtocol.settings["notification_desktop"] = "future-mode"
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.mobile = "none"
        let saved = try await model.saveChannelAlerts(original:source,draft:draft)
        XCTAssertEqual(saved.settings.notification_desktop,"future-mode");XCTAssertNil(ChannelAlertsProtocol.writes.first?["notification_desktop"])
    }
    func testNamedMentionModesAndRawServerDefaultArePreserved() async throws {
        ChannelAlertsProtocol.settings["notification_desktop"] = "by_admin_console"
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:1);var draft = ChatChannelAlertsDraft(source.settings);draft.mobile = "mention_subscribe"
        let saved = try await model.saveChannelAlerts(original:source,draft:draft)
        XCTAssertEqual(saved.settings.notification_desktop,"by_admin_console");XCTAssertEqual(saved.settings.notification_mobile,"mention_subscribe");XCTAssertNil(ChannelAlertsProtocol.writes.first?["notification_desktop"])
    }
    func testDirectAndEncryptedChannelsCannotIntroduceMentionModes() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "mention"
        do {_ = try await model.saveChannelAlerts(original:source,draft:draft);XCTFail()}catch{}
        ChannelAlertsProtocol.encrypted = true
        let encrypted = try await model.loadChannelAlerts(channelID:1)
        XCTAssertEqual(ChatChannelAlertMode.choices(encrypted.channel),[.all,.none]);XCTAssertTrue(ChannelAlertsProtocol.writes.isEmpty)
    }
    func testStaleChangedFieldRejectsBeforeWriteButUnrelatedFieldMayMerge() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "none"
        ChannelAlertsProtocol.settings["notification_desktop"] = "none"
        do {_ = try await model.saveChannelAlerts(original:source,draft:draft);XCTFail()}catch let error as ChatPreferenceUpdateFailure {XCTAssertFalse(error.uncertain)}
        XCTAssertTrue(ChannelAlertsProtocol.writes.isEmpty)
        ChannelAlertsProtocol.settings["notification_desktop"] = "all";ChannelAlertsProtocol.settings["notification_mobile"] = "none"
        let saved = try await model.saveChannelAlerts(original:source,draft:draft)
        XCTAssertEqual(saved.settings.notification_mobile,"none");XCTAssertNil(ChannelAlertsProtocol.writes.first?["notification_mobile"])
    }
    func testChangedMembershipCannotSaveReviewedConversation() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "none"
        ChannelAlertsProtocol.members = [10,7]
        do {_ = try await model.saveChannelAlerts(original:source,draft:draft);XCTFail()}catch{}
        XCTAssertTrue(ChannelAlertsProtocol.writes.isEmpty)
    }
    func testClosedChannelOrEncryptionEnvelopeChangeRejectsBeforeWrite() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "none"
        ChannelAlertsProtocol.closed = true
        do {_ = try await model.saveChannelAlerts(original:source,draft:draft);XCTFail()}catch{}
        ChannelAlertsProtocol.closed = false;ChannelAlertsProtocol.encrypted = true
        do {_ = try await model.saveChannelAlerts(original:source,draft:draft);XCTFail()}catch{}
        XCTAssertTrue(ChannelAlertsProtocol.writes.isEmpty)
    }
    func testIgnoredWriteBlocksUntilExplicitReadOnlyRefresh() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "none";ChannelAlertsProtocol.ignoreWrite = true
        do {_ = try await model.saveChannelAlerts(original:source,draft:draft);XCTFail()}catch let error as ChatPreferenceUpdateFailure {XCTAssertTrue(error.uncertain)}
        XCTAssertTrue(model.channelAlertsNeedRefresh.contains(93))
        do {_ = try await model.saveChannelAlerts(original:source,draft:draft);XCTFail()}catch{}
        XCTAssertEqual(ChannelAlertsProtocol.writes.count,1)
        let fresh = try await model.loadChannelAlerts(channelID:93);XCTAssertFalse(model.channelAlertsNeedRefresh.contains(93));XCTAssertEqual(fresh.settings.notification_desktop,"all");XCTAssertEqual(ChannelAlertsProtocol.writes.count,1)
    }
    func testLostAppliedReplyDoesNotRetryAndRefreshFindsActualMode() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "none";ChannelAlertsProtocol.loseReply = true
        do {_ = try await model.saveChannelAlerts(original:source,draft:draft);XCTFail()}catch{}
        let checked = try await model.loadChannelAlerts(channelID:93)
        XCTAssertEqual(checked.settings.notification_desktop,"none");XCTAssertEqual(ChannelAlertsProtocol.writes.count,1);XCTAssertFalse(model.channelAlertsNeedRefresh.contains(93))
    }
    func testCancellationAfterDispatchLeavesRefreshRequiredAndSerializesSaves() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "none"
        let started = expectation(description:"Write held");ChannelAlertsProtocol.holdWrite = true;ChannelAlertsProtocol.onHeld = {started.fulfill()}
        let operation = Task {try await model.saveChannelAlerts(original:source,draft:draft)}
        await fulfillment(of:[started],timeout:2)
        do {_ = try await model.saveChannelAlerts(original:source,draft:draft);XCTFail()}catch{}
        operation.cancel();ChannelAlertsProtocol.release()
        do {_ = try await operation.value;XCTFail()}catch{}
        XCTAssertEqual(ChannelAlertsProtocol.writes.count,1);XCTAssertFalse(model.channelAlertsBusy);XCTAssertTrue(model.channelAlertsNeedRefresh.contains(93))
    }
    func testSignOutDuringReadCannotDispatchOrRetainBusyState() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "none"
        let started = expectation(description:"Read held");ChannelAlertsProtocol.holdRead = true;ChannelAlertsProtocol.onHeld = {started.fulfill()}
        let operation = Task {try await model.saveChannelAlerts(original:source,draft:draft)}
        await fulfillment(of:[started],timeout:2);model.signOutLocally();ChannelAlertsProtocol.release()
        do {_ = try await operation.value;XCTFail()}catch is CancellationError{}
        XCTAssertTrue(ChannelAlertsProtocol.writes.isEmpty);XCTAssertFalse(model.channelAlertsBusy);XCTAssertTrue(model.channelAlertsNeedRefresh.isEmpty)
    }
    func testSignOutDuringWriteCannotPublishIntoSignedOutState() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93);var draft = ChatChannelAlertsDraft(source.settings);draft.desktop = "none"
        let started = expectation(description:"Write held");ChannelAlertsProtocol.holdWrite = true;ChannelAlertsProtocol.onHeld = {started.fulfill()}
        let operation = Task {try await model.saveChannelAlerts(original:source,draft:draft)}
        await fulfillment(of:[started],timeout:2);model.signOutLocally();ChannelAlertsProtocol.release()
        do {_ = try await operation.value;XCTFail()}catch is CancellationError{}
        XCTAssertTrue(model.channels.isEmpty);XCTAssertTrue(model.channelAlertsNeedRefresh.isEmpty);XCTAssertFalse(model.channelAlertsBusy)
    }
    func testAPIRejectsExtraneousFieldsAndUnknownNewModesBeforeRequest() async throws {
        let model = try await model(), source = try await model.loadChannelAlerts(channelID:93)
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ChannelAlertsProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://channel-alerts.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config));try await api.discover()
        for patch in [["notification_mute":"true"],["channel_key_enc":"key"],["notification_desktop":"by_admin_console"],["notification_desktop":"unknown"],[String:String]()] {
            do {try await api.setChannelAlerts(channel:source.channel,patch:patch);XCTFail()}catch{}
        }
        XCTAssertTrue(ChannelAlertsProtocol.writes.isEmpty)
    }
}

private final class ChannelAlertsProtocol:URLProtocol {
    static var settings:[String:Any] = [:], writes:[[String:String]] = []
    static var members:[Int64] = [10,6]
    static var encrypted = false, closed = false, ignoreWrite = false, loseReply = false, holdWrite = false, holdRead = false
    static var held:(ChannelAlertsProtocol,[String:Any])?,onHeld:(()->Void)?
    static func reset(){settings = ["notification_desktop":"all","notification_mobile":"all","notification_mute":false,"channel_key_enc":"keep-wrapper"];writes = [];members = [10,6];encrypted = false;closed = false;ignoreWrite = false;loseReply = false;holdWrite = false;holdRead = false;held = nil;onHeld = nil}
    static func channel(_ id:Int,_ type:String)->[String:Any]{["channel_id":id,"name":id == 1 ? "General" : "","type":type,"encrypted":encrypted,"channel_key_enc":encrypted ? "wrapped" : "","unread":0,"is_joined":true,"is_closed":closed,"preferences":settings]}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        guard request.url?.host == "channel-alerts.invalid" else{client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return}
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" {finish(Dictionary(uniqueKeysWithValues:["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Channel.Preference","SYNO.Chat.Post","SYNO.Chat.Misc"].map{($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any])}));return}
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream{stream.open();defer{stream.close()};var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable{let n = stream.read(&b,maxLength:b.count);if n<=0{break};data.append(contentsOf:b.prefix(n))}}
        var q = URLComponents();q.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        var fields = Dictionary((q.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{_,v in v});fields["api"] = api
        if api == "SYNO.Chat.User"{finish(["users":[["user_id":10,"username":"owner","nickname":"Owner","type":"human","human_type":"dsm"],["user_id":6,"username":"peter","nickname":"Peter","type":"human","human_type":"dsm"]]]);return}
        if api == "SYNO.Chat.Channel"{finish(["channels":[Self.channel(1,"public"),Self.channel(93,"anonymous")]]);return}
        if api == "SYNO.Chat.Channel.Member"{finish(["user_ids":Self.members]);return}
        guard api == "SYNO.Chat.Channel.Preference" else{finish(api == "SYNO.Chat.Post" ? ["posts":[]] : [:]);return}
        if fields["method"] == "set"{
            Self.writes.append(fields)
            if !Self.ignoreWrite{for key in ["notification_desktop","notification_mobile"]{if let raw = fields[key],let value = try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:.fragmentsAllowed){Self.settings[key] = value}}}
            if Self.holdWrite{Self.holdWrite = false;Self.held = (self,[:]);Self.onHeld?();return}
            if Self.loseReply{Self.loseReply = false;client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return}
            finish([:]);return
        }
        let payload:[String:Any] = ["preferences":Self.settings]
        if Self.holdRead{Self.holdRead = false;Self.held = (self,payload);Self.onHeld?();return}
        finish(payload)
    }
    static func release(){if let held{Self.held = nil;held.0.finish(held.1)}}
    func finish(_ payload:[String:Any]){let data = try! JSONSerialization.data(withJSONObject:["success":true,"data":payload]);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading(){}
}
