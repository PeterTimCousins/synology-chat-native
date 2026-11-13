import XCTest
@testable import SynologyChatNative

@MainActor final class ChatSidebarTests: XCTestCase {
    override func setUp(){super.setUp();SidebarProtocol.reset()}
    private func channel(_ id:Int,_ name:String,_ type:String = "anonymous",unread:Int = 0,mention:Int = 0,thread:Int = 0,star:Bool = false,encrypted:Bool = false,hidden:Bool = false,global:Bool = false,joined:Bool = true,closed:Bool = false)throws->ChatChannel{
        let value:[String:Any] = ["channel_id":id,"name":name,"type":type,"unread":unread,"unread_mention":mention,"unread_thread":["1":thread],"is_star":star,"encrypted":encrypted,"is_joined":joined,"is_closed":closed,"last_hide_at":hidden ? 10:0,"last_view_at":0,"hide_global_at":global ? 10:0]
        return try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:value))
    }
    private func groups(_ channels:[ChatChannel],pin:Bool = true,selected:Int64? = nil,anchor:ChatSidebarAnchor? = nil,query:String = "")->[ChatSidebarSection]{ChatSidebarProjection.sections(channels:channels,pinUnread:pin,selectedID:selected,anchor:anchor,closed:[],blockedBots:[],query:query,title:{$0.name})}
    private func model()async throws->NativeChatPreviewModel{
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [SidebarProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://sidebar.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config));try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false);model.connected = true;model.liveStatus = .live
        addTeardownBlock{@MainActor in model.signOutLocally()};return model
    }
    func testUnreadTakesPrecedenceOverStarredWithoutDuplicates()throws{
        let rows = try [channel(1,"One",unread:1,star:true),channel(2,"Two",star:true),channel(3,"Three","public"),channel(4,"Four","chatbot")]
        let sections = groups(rows)
        XCTAssertEqual(sections.map(\.group),[.unread,.starred,.channels,.bots]);XCTAssertEqual(sections.flatMap(\.channels).map(\.id),[1,2,3,4])
        XCTAssertEqual(groups(rows,pin:false).first?.channels.map(\.id),[1,2])
    }
    func testRawUnreadMakesSectionButBadgeUsesMentionsAndFollowedReplies()throws{
        let plain = try channel(1,"A","public",unread:20),mention = try channel(2,"Z","public",unread:5,mention:1),thread = try channel(3,"T",thread:2)
        XCTAssertEqual(plain.sidebarUnreadCount,20);XCTAssertEqual(plain.badgeUnreadCount,0)
        XCTAssertEqual(groups([plain,mention,thread]).first?.channels.map(\.id),[3,2,1])
        XCTAssertEqual(plain.sidebarUnreadDescription,"20 unread messages, 0 mentions or followed replies")
        XCTAssertEqual(thread.sidebarUnreadCount,2)
    }
    func testSelectedUnreadRemainsUntilLeavingAndKeepsSortPriority()throws{
        let unread = try channel(1,"Z",unread:1),read = try channel(1,"Z"),other = try channel(2,"A","public",unread:5)
        let anchor = ChatSidebarProjection.anchor(unread,pinUnread:true)
        XCTAssertEqual(groups([read,other],selected:1,anchor:anchor).first?.channels.map(\.id),[1,2])
        XCTAssertFalse(groups([read,other],selected:2,anchor:anchor).first?.channels.contains(where:{$0.id==1}) ?? true)
    }
    func testCurrentReadConversationDoesNotJumpWhenUnreadArrives()throws{
        let before = try channel(1,"Peter"),after = try channel(1,"Peter",unread:2),anchor = ChatSidebarProjection.anchor(before,pinUnread:true)
        XCTAssertEqual(groups([after],selected:1,anchor:anchor).first?.group,.conversations)
        XCTAssertEqual(groups([after],selected:nil,anchor:anchor).first?.group,.unread)
    }
    func testHiddenStarredIsVisibleButGlobalClosedUnjoinedNeverShowEvenSelectedOrSearched()throws{
        let rows = try [channel(1,"Star",star:true,hidden:true),channel(2,"Hidden",hidden:true),channel(3,"Global",global:true),channel(4,"Closed",closed:true),channel(5,"Left",joined:false)]
        XCTAssertEqual(groups(rows,pin:false).flatMap(\.channels).map(\.id),[1])
        XCTAssertEqual(groups(rows,pin:false,selected:2).flatMap(\.channels).map(\.id),[1,2])
        XCTAssertEqual(groups(rows,pin:false,selected:3,query:"Global").flatMap(\.channels).map(\.id),[])
        XCTAssertEqual(groups(rows,pin:false,query:"Hidden").flatMap(\.channels).map(\.id),[2])
    }
    func testFixedSortPlacesMySpaceThenEncryptedThenNaturalNames()throws{
        let rows = try [channel(1,"Room10"),channel(2,"Room2"),channel(3,"ZZZ",encrypted:true),channel(4,"My Space","synobot"),channel(5,"room2")]
        XCTAssertEqual(groups(rows,pin:false).first?.channels.map(\.id),[4,3,2,5,1])
        XCTAssertEqual(try channel(6,"My Space","synobot",unread:3,thread:1).badgeUnreadCount,4)
    }
    func testModelAnchorSurvivesReadUpdatesButResetsOnPreferenceChange()async throws{
        SidebarProtocol.pin = true;let model = try await model();_ = try await model.loadSidebarSettings()
        model.channels = [try channel(1,"Peter",unread:2)];model.selection = 1
        model.channels = [try channel(1,"Peter")]
        XCTAssertEqual(model.sidebarSections(query:"").first?.group,.unread)
        let source = try await model.loadSidebarSettings();_ = try await model.saveSidebarSettings(original:source,pinUnread:false)
        XCTAssertEqual(model.sidebarSections(query:"").first?.group,.conversations)
    }
    func testMissingPreferenceCannotBeGuessedOrSaved()async throws{
        let model = try await model();SidebarProtocol.missing = true
        do{_ = try await model.loadSidebarSettings();XCTFail()}catch{}
        XCTAssertNil(model.sidebarSettings);XCTAssertTrue(SidebarProtocol.writes.isEmpty)
    }
    func testWriteOnlySidebarFieldPreservesOtherSettingsSelectionAndDraft()async throws{
        let model = try await model();model.channels = [try channel(1,"Peter")];model.selection = 1;model.draft = "Keep draft"
        let source = try await model.loadSidebarSettings();let result = try await model.saveSidebarSettings(original:source,pinUnread:true)
        XCTAssertTrue(result.settings.sidebar_pinning_unread);XCTAssertEqual(model.draft,"Keep draft");XCTAssertEqual(model.selection,1)
        XCTAssertEqual(SidebarProtocol.writes.first?["sidebar_pinning_unread"],"true");XCTAssertEqual(SidebarProtocol.writes.first?["version"],"4");XCTAssertNil(SidebarProtocol.writes.first?["notification_mute"]);XCTAssertNil(SidebarProtocol.writes.first?["calendar_enable"])
    }
    func testStalePreferenceCannotOverwriteAnotherClient()async throws{
        let model = try await model(),source = try await model.loadSidebarSettings();SidebarProtocol.pin = true
        do{_ = try await model.saveSidebarSettings(original:source,pinUnread:true);XCTFail()}catch let error as ChatPreferenceUpdateFailure{XCTAssertFalse(error.uncertain)}
        XCTAssertTrue(SidebarProtocol.writes.isEmpty)
    }
    func testIgnoredOrLostWriteBlocksRepeatUntilReadOnlyRefresh()async throws{
        let model = try await model(),source = try await model.loadSidebarSettings();SidebarProtocol.ignore = true
        do{_ = try await model.saveSidebarSettings(original:source,pinUnread:true);XCTFail()}catch let error as ChatPreferenceUpdateFailure{XCTAssertTrue(error.uncertain)}
        do{_ = try await model.saveSidebarSettings(original:source,pinUnread:true);XCTFail()}catch{}
        XCTAssertEqual(SidebarProtocol.writes.count,1)
        let refreshed = try await model.loadSidebarSettings();XCTAssertFalse(model.sidebarSettingsNeedRefresh)
        SidebarProtocol.ignore = false;SidebarProtocol.lose = true
        do{_ = try await model.saveSidebarSettings(original:refreshed,pinUnread:true);XCTFail()}catch{}
        let checked = try await model.loadSidebarSettings();XCTAssertTrue(checked.settings.sidebar_pinning_unread);XCTAssertEqual(SidebarProtocol.writes.count,2)
    }
    func testCancellationAfterDispatchSerializesAndRequiresRefresh()async throws{
        let model = try await model(),source = try await model.loadSidebarSettings(),started = expectation(description:"Write held")
        SidebarProtocol.hold = true;SidebarProtocol.onHeld = {started.fulfill()}
        let operation = Task{try await model.saveSidebarSettings(original:source,pinUnread:true)}
        await fulfillment(of:[started],timeout:2)
        do{_ = try await model.loadSidebarSettings();XCTFail()}catch{}
        operation.cancel();SidebarProtocol.release()
        do{_ = try await operation.value;XCTFail()}catch{}
        XCTAssertTrue(model.sidebarSettingsNeedRefresh);XCTAssertFalse(model.sidebarSettingsBusy);XCTAssertEqual(SidebarProtocol.writes.count,1)
    }
    func testSignOutDuringWriteCannotPublishOrRetainOldScopeFlags()async throws{
        let model = try await model(),source = try await model.loadSidebarSettings(),started = expectation(description:"Write held")
        SidebarProtocol.hold = true;SidebarProtocol.onHeld = {started.fulfill()}
        let operation = Task{try await model.saveSidebarSettings(original:source,pinUnread:true)}
        await fulfillment(of:[started],timeout:2);model.signOutLocally();SidebarProtocol.release()
        do{_ = try await operation.value;XCTFail()}catch is CancellationError{}
        XCTAssertNil(model.sidebarSettings);XCTAssertFalse(model.sidebarSettingsBusy);XCTAssertFalse(model.sidebarSettingsNeedRefresh)
    }
}
private final class SidebarProtocol:URLProtocol{
    static var pin = false,missing = false,ignore = false,lose = false,hold = false
    static var writes:[[String:String]] = [],held:SidebarProtocol?,onHeld:(()->Void)?
    static func reset(){pin = false;missing = false;ignore = false;lose = false;hold = false;writes = [];held = nil;onHeld = nil}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        guard request.url?.host == "sidebar.invalid" else{client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return}
        if request.url!.lastPathComponent == "SYNO.API.Info"{finish(["SYNO.Chat.User.Preference":["path":"entry.cgi","minVersion":1,"maxVersion":4,"requestFormat":"JSON"]]);return}
        var data = request.httpBody ?? Data();if data.isEmpty,let stream = request.httpBodyStream{stream.open();defer{stream.close()};var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable{let n = stream.read(&b,maxLength:b.count);if n<=0{break};data.append(contentsOf:b.prefix(n))}}
        var q = URLComponents();q.percentEncodedQuery = String(decoding:data,as:UTF8.self);let fields = Dictionary((q.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{_,v in v})
        if fields["method"] == "set"{Self.writes.append(fields);if !Self.ignore{Self.pin = fields["sidebar_pinning_unread"] == "true"};if Self.hold{Self.hold = false;Self.held = self;Self.onHeld?();return};if Self.lose{Self.lose = false;client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return};finish([:]);return}
        var prefs:[String:Any] = ["notification_mute":false,"calendar_enable":true];if !Self.missing{prefs["sidebar_pinning_unread"] = Self.pin};finish(["preferences":prefs])
    }
    static func release(){if let held{Self.held = nil;held.finish([:])}}
    func finish(_ payload:[String:Any]){let data = try! JSONSerialization.data(withJSONObject:["success":true,"data":payload]);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading(){}
}
