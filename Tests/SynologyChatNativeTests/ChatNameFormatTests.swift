import XCTest
@testable import SynologyChatNative

@MainActor final class ChatNameFormatTests:XCTestCase {
    override func setUp(){super.setUp();NameProtocol.reset()}
    private func user(_ id:Int = 6,username:String? = "alice",nickname:String = "Zoe",type:String = "human",human:String = "dsm")throws->ChatUser{
        var value:[String:Any] = ["user_id":id,"nickname":nickname,"type":type,"human_type":human];if let username{value["username"] = username}
        return try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:value))
    }
    private func model()async throws->NativeChatPreviewModel{
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{session in
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [NameProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://names.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"owner",importedFromOfficialApp:false))
        XCTAssertTrue(model.connected,model.error ?? "Connection failed");model.liveStatus = .live
        addTeardownBlock{@MainActor in model.signOutLocally()};return model
    }
    func testPrimaryAndAdditionalHumanNamesUseInversePreference()throws{
        let person = try user()
        XCTAssertEqual(ChatNameFormat.username.display(person),"alice");XCTAssertEqual(ChatNameFormat.username.additional(person),"Zoe")
        XCTAssertEqual(ChatNameFormat.nickname.display(person),"Zoe");XCTAssertEqual(ChatNameFormat.nickname.additional(person),"alice")
    }
    func testMissingAndEqualFieldsHaveUsableNonduplicateFallbacks()throws{
        for format in ChatNameFormat.allCases{
            XCTAssertEqual(format.display(try user(username:nil,nickname:"名")),"名")
            XCTAssertEqual(format.display(try user(nickname:"")),"alice")
            XCTAssertEqual(format.display(try user(username:nil,nickname:"")),"User 6")
            XCTAssertNil(format.additional(try user(username:"same",nickname:"same")))
        }
    }
    func testBotsKeepNicknameAndGuestsUseShortGuestNameIndependentOfPreference()throws{
        let bot = try user(16,username:"internal-service",nickname:"Build Bot",type:"bot")
        let guest = try user(8,username:"guest_abc",nickname:"",human:"guest")
        for format in ChatNameFormat.allCases{
            XCTAssertEqual(format.display(bot),"Build Bot");XCTAssertNil(format.additional(bot))
            XCTAssertEqual(format.display(guest),"abc (Guest)");XCTAssertEqual(format.display(guest,shortGuest:true),"abc")
            XCTAssertEqual(format.display(try user(8,username:"guest_abc",nickname:"Guest Person",human:"guest")),"Guest Person (Guest)")
        }
    }
    func testAliasesRemainSearchableAndUnicodeIsNotRewritten()throws{
        let person = try user(username:"alice",nickname:"東京 Zoe")
        XCTAssertTrue(ChatNameFormat.matches(person,query:"ALICE"));XCTAssertTrue(ChatNameFormat.matches(person,query:"東京"))
        XCTAssertEqual(ChatNameFormat.nickname.display(person),"東京 Zoe");XCTAssertFalse(ChatNameFormat.matches(person,query:"missing"))
    }
    func testBootstrapAppliesServerUsernamePreferenceToNamesAndDerivedDMTitles()async throws{
        let model = try await model()
        XCTAssertEqual(model.nameFormat,.username);XCTAssertEqual(model.names[6],"alice")
        XCTAssertEqual(model.title(try XCTUnwrap(model.channels.first{$0.id==93})),"alice")
        XCTAssertEqual(model.title(try XCTUnwrap(model.channels.first{$0.id==94})),"alice, bob")
        XCTAssertEqual(model.title(try XCTUnwrap(model.channels.first{$0.id==1})),"General")
    }
    func testSingleFieldWriteRefreshesNamesAndTitlesWithoutChangingIdentityDraftOrPosts()async throws{
        let model = try await model();model.selection = 93;model.draft = "Keep @u:6 unchanged"
        let source = try await model.loadNameSettings(),reads = NameProtocol.postReads;let result = try await model.saveNameSettings(original:source,format:.nickname)
        XCTAssertEqual(result.settings.prefer_user_name_format,.nickname);XCTAssertEqual(model.names[6],"Zoe")
        XCTAssertEqual(model.title(try XCTUnwrap(model.selectedChannel)),"Zoe");XCTAssertEqual(model.title(try XCTUnwrap(model.channels.first{$0.id==94})),"Aaron, Zoe")
        XCTAssertEqual(model.selection,93);XCTAssertEqual(model.draft,"Keep @u:6 unchanged");XCTAssertEqual(NameProtocol.postReads,reads)
        XCTAssertEqual(model.mentionNames[6],"alice");XCTAssertEqual(model.mentionNames[16],"Build Bot")
        let fields = try XCTUnwrap(NameProtocol.writes.first)
        XCTAssertEqual(fields["prefer_user_name_format"],"\"nickname\"");XCTAssertEqual(fields["version"],"4")
        XCTAssertNil(fields["nickname"]);XCTAssertNil(fields["username"]);XCTAssertNil(fields["user_id"]);XCTAssertNil(fields["sidebar_pinning_unread"]);XCTAssertNil(fields["notification_mute"])
        XCTAssertEqual(NameProtocol.starts,0);XCTAssertEqual(NameProtocol.posts,0)
    }
    func testDirectoryRefreshCannotRestoreOldNicknameCacheUnderUsernameMode()async throws{
        let model = try await model();NameProtocol.peerNickname = "New nickname";try await model.refreshUserProfiles()
        XCTAssertEqual(model.names[6],"alice");XCTAssertEqual(model.title(try XCTUnwrap(model.channels.first{$0.id==93})),"alice")
        let source = try await model.loadNameSettings();_ = try await model.saveNameSettings(original:source,format:.nickname)
        XCTAssertEqual(model.names[6],"New nickname");XCTAssertEqual(model.title(try XCTUnwrap(model.channels.first{$0.id==93})),"New nickname")
    }
    func testPolicyIsAccountScopedRatherThanGlobalMutableState()async throws{
        let first = try await model();NameProtocol.mode = "nickname";let second = try await model()
        XCTAssertEqual(first.names[6],"alice");XCTAssertEqual(second.names[6],"Zoe")
        second.signOutLocally();XCTAssertEqual(first.names[6],"alice");XCTAssertNil(second.nameSettings)
    }
    func testQuickSwitchRebuildUsesPreferredLabelsButRawIdentitiesRemainValid()async throws{
        NameProtocol.mode = "nickname";let model = try await model(),snapshot = try await model.loadQuickSwitcher(),entry = try XCTUnwrap(snapshot.entries.first{$0.channel?.id==93})
        XCTAssertEqual(entry.title,"Zoe")
        let source = try await model.loadNameSettings();_ = try await model.saveNameSettings(original:source,format:.username)
        let opened = try await model.openQuickSwitch(entry,snapshot:snapshot);XCTAssertTrue(opened);XCTAssertEqual(model.selection,93)
        let fresh = try await model.loadQuickSwitcher();XCTAssertEqual(fresh.entries.first{$0.channel?.id==93}?.title,"alice")
        XCTAssertEqual(NameProtocol.starts,0)
    }
    func testSidebarSearchRetainsBothAliasesUnderUsernameMode() async throws {
        let model = try await model()
        XCTAssertEqual(model.title(try XCTUnwrap(model.channels.first{$0.id==93})),"alice")
        XCTAssertTrue(model.sidebarSections(query:"Zoe").flatMap(\.channels).contains{$0.id==93})
        XCTAssertTrue(model.sidebarSections(query:"ALICE").flatMap(\.channels).contains{$0.id==93})
    }
    func testUnknownOrMissingServerModeCannotBeGuessedOrWritten()async throws{
        NameProtocol.mode = "future";let model = try await model();XCTAssertNil(model.nameSettings)
        do{_ = try await model.loadNameSettings();XCTFail()}catch{}
        NameProtocol.mode = nil
        do{_ = try await model.loadNameSettings();XCTFail()}catch{}
        XCTAssertTrue(NameProtocol.writes.isEmpty)
    }
    func testStaleModeRejectsBeforeDispatchAndOtherFieldsAreNotComparedOrWritten()async throws{
        let model = try await model(),source = try await model.loadNameSettings();NameProtocol.mode = "nickname"
        do{_ = try await model.saveNameSettings(original:source,format:.nickname);XCTFail()}catch let error as ChatPreferenceUpdateFailure{XCTAssertFalse(error.uncertain)}
        XCTAssertTrue(NameProtocol.writes.isEmpty)
    }
    func testIgnoredOrLostWriteRequiresReadOnlyRefreshWithoutReplay()async throws{
        let model = try await model(),source = try await model.loadNameSettings();NameProtocol.ignore = true
        do{_ = try await model.saveNameSettings(original:source,format:.nickname);XCTFail()}catch let error as ChatPreferenceUpdateFailure{XCTAssertTrue(error.uncertain)}
        do{_ = try await model.saveNameSettings(original:source,format:.nickname);XCTFail()}catch{}
        XCTAssertEqual(NameProtocol.writes.count,1);let refreshed = try await model.loadNameSettings();XCTAssertFalse(model.nameSettingsNeedRefresh)
        NameProtocol.ignore = false;NameProtocol.lose = true
        do{_ = try await model.saveNameSettings(original:refreshed,format:.nickname);XCTFail()}catch{}
        let confirmed = try await model.loadNameSettings();XCTAssertEqual(confirmed.settings.prefer_user_name_format,.nickname);XCTAssertEqual(NameProtocol.writes.count,2)
    }
    func testCancellationAfterDispatchSerializesChangesAndLeavesRefreshRequired()async throws{
        let model = try await model(),source = try await model.loadNameSettings(),held = expectation(description:"Name write held")
        NameProtocol.hold = true;NameProtocol.onHeld = {held.fulfill()}
        let operation = Task{try await model.saveNameSettings(original:source,format:.nickname)}
        await fulfillment(of:[held],timeout:2)
        do{_ = try await model.loadNameSettings();XCTFail()}catch{}
        operation.cancel();NameProtocol.release()
        do{_ = try await operation.value;XCTFail()}catch{}
        XCTAssertFalse(model.nameSettingsBusy);XCTAssertTrue(model.nameSettingsNeedRefresh);XCTAssertEqual(NameProtocol.writes.count,1)
    }
    func testSignOutDuringWriteCannotPublishNamesOrOldScopeFlags()async throws{
        let model = try await model(),source = try await model.loadNameSettings(),held = expectation(description:"Name write held")
        NameProtocol.hold = true;NameProtocol.onHeld = {held.fulfill()}
        let operation = Task{try await model.saveNameSettings(original:source,format:.nickname)}
        await fulfillment(of:[held],timeout:2);model.signOutLocally();NameProtocol.release()
        do{_ = try await operation.value;XCTFail()}catch is CancellationError{}
        XCTAssertNil(model.nameSettings);XCTAssertTrue(model.names.isEmpty);XCTAssertFalse(model.nameSettingsBusy);XCTAssertFalse(model.nameSettingsNeedRefresh)
    }
}
private final class NameProtocol:URLProtocol{
    static var mode:String? = "username",peerNickname = "Zoe"
    static var ignore = false,lose = false,hold = false,writes:[[String:String]] = [],held:NameProtocol?,onHeld:(()->Void)?
    static var starts = 0,posts = 0,postReads = 0
    static func reset(){mode = "username";peerNickname = "Zoe";ignore = false;lose = false;hold = false;writes = [];held = nil;onHeld = nil;starts = 0;posts = 0;postReads = 0}
    static func channel(_ id:Int,_ name:String,_ type:String)->[String:Any]{["channel_id":id,"name":name,"type":type,"encrypted":false,"unread":0,"is_joined":true]}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        guard request.url?.host == "names.invalid" else{client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return}
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info"{finish(Dictionary(uniqueKeysWithValues:["SYNO.Chat.User.Preference","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Misc","SYNO.Chat.Post","SYNO.Chat.Channel.Anonymous"].map{($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any])}));return}
        var data = request.httpBody ?? Data();if data.isEmpty,let stream = request.httpBodyStream{stream.open();defer{stream.close()};var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable{let n = stream.read(&b,maxLength:b.count);if n<=0{break};data.append(contentsOf:b.prefix(n))}}
        var q = URLComponents();q.percentEncodedQuery = String(decoding:data,as:UTF8.self);let f = Dictionary((q.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{_,v in v})
        if api == "SYNO.Chat.User.Preference"{
            if f["method"] == "set"{Self.writes.append(f);if !Self.ignore,let raw = f["prefer_user_name_format"]{Self.mode = try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:.fragmentsAllowed) as? String};if Self.hold{Self.hold = false;Self.held = self;Self.onHeld?();return};if Self.lose{Self.lose = false;client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return};finish([:]);return}
            var prefs:[String:Any] = ["sidebar_pinning_unread":true,"notification_mute":false,"calendar_enable":true];if let mode = Self.mode{prefs["prefer_user_name_format"] = mode};finish(["preferences":prefs]);return
        }
        if api == "SYNO.Chat.User"{finish(["users":[["user_id":10,"username":"owner","nickname":"Owner","type":"human","human_type":"dsm"],["user_id":6,"username":"alice","nickname":Self.peerNickname,"type":"human","human_type":"dsm"],["user_id":7,"username":"bob","nickname":"Aaron","type":"human","human_type":"dsm"],["user_id":16,"username":"service","nickname":"Build Bot","type":"bot","bot_type":"chatbot"]]]);return}
        if api == "SYNO.Chat.Channel"{finish(["channels":[Self.channel(1,"General","public"),Self.channel(93,"","anonymous"),Self.channel(94,"","anonymous")]]);return}
        if api == "SYNO.Chat.Channel.Member"{finish(["user_ids":f["channel_id"] == "94" ? [10,6,7] : [10,6]]);return}
        if api == "SYNO.Chat.Channel.Anonymous"{Self.starts+=1;finish(Self.channel(99,"","anonymous"));return}
        if api == "SYNO.Chat.Post"{if f["method"] == "create"{Self.posts+=1}else{Self.postReads+=1};finish(["posts":[]]);return}
        finish(["acls":[["acl_name":"channel_anonymous","allow":true]]])
    }
    static func release(){if let held{Self.held = nil;held.finish([:])}}
    func finish(_ payload:[String:Any]){let data = try! JSONSerialization.data(withJSONObject:["success":true,"data":payload]);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading(){}
}
