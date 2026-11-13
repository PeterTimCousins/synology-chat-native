import XCTest
@testable import SynologyChatNative

@MainActor final class ChatConversationOrganizationTests:XCTestCase {
    private func channel(_ changes:[String:Any] = [:]) throws -> ChatChannel {
        try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:OrganizationProtocol.initial.merging(changes,uniquingKeysWith:{ _,new in new })))
    }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [OrganizationProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://organization-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover();return api
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:try await api(),restoreNotificationPreference:false)
        model.channels = [try channel()];model.selection = 93;model.connected = true;model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func setUp() { super.setUp();OrganizationProtocol.reset() }
    override func tearDown() { OrganizationProtocol.observer = nil;OrganizationProtocol.held = nil;super.tearDown() }
    func testStarHideWireUsesPersonalChannelV2ActionsWithoutGlobalOrMembershipMutations() async throws {
        let api = try await api()
        OrganizationProtocol.observer = { fields in
            XCTAssertEqual(fields["api"],"SYNO.Chat.Channel");XCTAssertEqual(fields["version"],"2");XCTAssertEqual(fields["channel_id"],"93")
            XCTAssertNil(fields["user_id"]);XCTAssertNil(fields["hide_global_at"]);XCTAssertNil(fields["is_joined"])
        }
        for change:ChatConversationOrganizationChange in [.star(true),.star(false),.hide] { try await api.changeConversationOrganization(channelID:93,change:change) }
        XCTAssertEqual(OrganizationProtocol.writes,["star","unstar","hide"])
        do { try await api.changeConversationOrganization(channelID:0,change:.hide);XCTFail("Invalid ID sent") } catch ChatAPIError.invalidResponse { }
    }
    func testDirectHiddenRulesRevealSelectedUnreadAndFollowedThreadActivity() throws {
        let hidden = try channel(["last_hide_at":2000]);XCTAssertTrue(hidden.hiddenFromSidebar(selectedID:nil));XCTAssertFalse(hidden.hiddenFromSidebar(selectedID:93))
        for value:[String:Any] in [["unread":1],["unread_thread":["735":1]],["last_view_at":3000],["last_hide_at":0]] {
            XCTAssertFalse(try channel(["last_hide_at":2000].merging(value,uniquingKeysWith:{ _,new in new })).hiddenFromSidebar(selectedID:nil))
        }
        XCTAssertFalse(try channel(["type":"synobot","last_hide_at":2000]).hiddenFromSidebar(selectedID:nil))
        XCTAssertTrue(try channel(["type":"chatbot","last_hide_at":2000]).hiddenFromSidebar(selectedID:nil))
        XCTAssertFalse(try channel(["type":"chatbot","last_hide_at":2000,"unread":1]).hiddenFromSidebar(selectedID:nil))
    }
    func testNamedHiddenRulesRespectMentionsThreadsNotificationModeAndGlobalHide() throws {
        let base:[String:Any] = ["type":"private","last_hide_at":2000,"unread":2]
        XCTAssertTrue(try channel(base).hiddenFromSidebar(selectedID:nil))
        for value:[String:Any] in [["unread_mention":1],["unread_thread":["735":1]],["preferences":["notification_desktop":"all"]],["preferences":["notification_desktop":"by_admin_console"]],["preferences":["notification_desktop":"unknown"]]] {
            XCTAssertFalse(try channel(base.merging(value,uniquingKeysWith:{ _,new in new })).hiddenFromSidebar(selectedID:nil))
        }
        XCTAssertTrue(try channel(["type":"public","hide_global_at":1000]).hiddenFromSidebar(selectedID:nil))
        XCTAssertFalse(try channel(["hide_global_at":1000]).supportsOrganization(.hide))
    }
    func testCanonicalStarHideAndOpenRetainDraftAndUseOrdinaryPresenceForRestore() async throws {
        let model = try await model();model.draft = "Unsent Peter draft"
        try await model.organizeConversation(model.channels[0],change:.star(true));XCTAssertEqual(model.channels[0].is_star,true);XCTAssertEqual(model.selection,93)
        try await model.organizeConversation(model.channels[0],change:.star(false));XCTAssertEqual(model.channels[0].is_star,false)
        try await model.organizeConversation(model.channels[0],change:.hide);XCTAssertNil(model.selection);XCTAssertTrue(model.channels[0].hiddenFromSidebar(selectedID:nil))
        XCTAssertEqual(model.drafts[93],"Unsent Peter draft")
        let route = model.hiddenConversationRoute
        try model.openHiddenConversation(model.channels[0]);XCTAssertEqual(model.selection,93);XCTAssertNotEqual(model.hiddenConversationRoute,route)
        // Selecting the conversation lets the existing serialized presence consumer
        // perform enter/unhide. Navigation itself must not send an independent show.
        XCTAssertEqual(model.drafts[93],"Unsent Peter draft")
        XCTAssertEqual(OrganizationProtocol.writes,["star","unstar","hide"]);XCTAssertFalse(model.conversationOrganizationBusy)
    }
    func testChangedRemoteStarIsNotOverwrittenFromStaleSnapshot() async throws {
        let model = try await model();OrganizationProtocol.value["is_star"] = true
        do { try await model.organizeConversation(model.channels[0],change:.star(true));XCTFail("Stale action sent") } catch let failure as ChatConversationOrganizationFailure { XCTAssertFalse(failure.uncertain) }
        XCTAssertTrue(OrganizationProtocol.writes.isEmpty)
        try await model.refreshConversationOrganization();XCTAssertEqual(model.channels[0].is_star,true)
    }
    func testNoOpResponseIsUncertainBlocksRetryAndRequiresFreshList() async throws {
        let model = try await model();OrganizationProtocol.ignoreWrite = true
        do { try await model.organizeConversation(model.channels[0],change:.star(true));XCTFail("Ignored write confirmed") } catch let failure as ChatConversationOrganizationFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(model.channels[0].is_star,false);XCTAssertTrue(model.unresolvedOrganization.contains(93))
        XCTAssertFalse(model.canOrganizeConversation(model.channels[0],change:.star(true)))
        do { try await model.organizeConversation(model.channels[0],change:.star(true));XCTFail("Uncertain action repeated") } catch { }
        XCTAssertEqual(OrganizationProtocol.writes,["star"])
        try await model.refreshConversationOrganization();XCTAssertTrue(model.unresolvedOrganization.isEmpty)
        OrganizationProtocol.ignoreWrite = false
        try await model.organizeConversation(model.channels[0],change:.star(true));XCTAssertEqual(model.channels[0].is_star,true)
    }
    func testHideDoesNotDiscardUnsavedEditAndMySpaceCannotBeHidden() async throws {
        let model = try await model(),owner = UUID();model.beginMessageEditing(owner:owner)
        XCTAssertFalse(model.canOrganizeConversation(model.channels[0],change:.hide))
        do { try await model.organizeConversation(model.channels[0],change:.hide);XCTFail("Unsaved edit lost") } catch { }
        XCTAssertThrowsError(try model.openHiddenConversation(model.channels[0]))
        XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertEqual(model.selection,93)
        XCTAssertFalse(try channel(["type":"synobot"]).supportsOrganization(.hide))
        XCTAssertTrue(OrganizationProtocol.writes.isEmpty)
    }
    func testSignOutAfterWriteDoesNotPublishOldOrganizationOrIssueReceiptReads() async throws {
        let model = try await model(),started = expectation(description:"Star held");OrganizationProtocol.holdWrite = true
        OrganizationProtocol.observer = { if $0["method"] == "star" { started.fulfill() } }
        let task = Task { try await model.organizeConversation(model.channels[0],change:.star(true)) }
        await fulfillment(of:[started],timeout:2);let reads = OrganizationProtocol.reads;model.signOutLocally();OrganizationProtocol.held?.finish(["success":true])
        do { try await task.value;XCTFail("Old account result accepted") } catch is CancellationError { }
        XCTAssertTrue(model.channels.isEmpty);XCTAssertEqual(OrganizationProtocol.reads,reads);XCTAssertFalse(model.conversationOrganizationBusy);XCTAssertTrue(model.unresolvedOrganization.isEmpty)
    }
    func testCancelledDispatchedChangeIsUncertainUntilRefreshed() async throws {
        let model = try await model(),started = expectation(description:"Hide held");OrganizationProtocol.holdWrite = true
        OrganizationProtocol.observer = { if $0["method"] == "hide" { started.fulfill() } }
        let task = Task { try await model.organizeConversation(model.channels[0],change:.hide) }
        await fulfillment(of:[started],timeout:2);task.cancel();OrganizationProtocol.held?.finish(["success":true])
        do { try await task.value;XCTFail("Cancelled receipt accepted") } catch let failure as ChatConversationOrganizationFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertTrue(model.unresolvedOrganization.contains(93));XCTAssertEqual(model.selection,93)
    }
    func testLateRefreshFailureAfterSignOutIsCancellationNotNewAccountError() async throws {
        let model = try await model(),started = expectation(description:"Refresh held");OrganizationProtocol.holdRead = true
        OrganizationProtocol.observer = { if $0["method"] == "list" { started.fulfill() } }
        let task = Task { try await model.refreshConversationOrganization() }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        OrganizationProtocol.held?.client?.urlProtocol(OrganizationProtocol.held!,didFailWithError:URLError(.cannotConnectToHost))
        do { try await task.value;XCTFail("Old account failure escaped") } catch is CancellationError { }
        XCTAssertTrue(model.channels.isEmpty);XCTAssertNil(model.error)
    }
    func testMissingChannelOrUnavailableMetadataCannotMutateAndDuplicateReadbackCannotPublish() async throws {
        let model = try await model();OrganizationProtocol.page = []
        do { try await model.organizeConversation(model.channels[0],change:.star(true));XCTFail("Absent channel mutated") } catch { }
        XCTAssertTrue(OrganizationProtocol.writes.isEmpty)
        OrganizationProtocol.page = [OrganizationProtocol.initial,OrganizationProtocol.initial]
        do { try await model.refreshConversationOrganization();XCTFail("Duplicate list published") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(model.channels.count,1)
        XCTAssertFalse(try channel(["is_joined":false]).supportsOrganization(.star(true)))
    }
}

private final class OrganizationProtocol:URLProtocol {
    static let initial:[String:Any] = ["channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"is_joined":true,"is_star":false,"last_hide_at":0,"last_view_at":1000,"hide_global_at":0]
    static var value = initial
    static var page:[[String:Any]]?
    static var writes:[String] = []
    static var reads = 0
    static var ignoreWrite = false
    static var holdWrite = false
    static var holdRead = false
    static var held:OrganizationProtocol?
    static var observer:(([String:String])->Void)?
    static func reset() { value = initial;page = nil;writes = [];reads = 0;ignoreWrite = false;holdWrite = false;holdRead = false;held = nil;observer = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":["SYNO.Chat.Channel":["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"]]]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        var fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });fields["api"] = request.url!.lastPathComponent
        let method = fields["method"] ?? ""
        if method == "list" { Self.reads += 1;if Self.holdRead { Self.held = self;Self.observer?(fields);return };Self.observer?(fields);finish(["success":true,"data":["channels":Self.page ?? [Self.value]]]);return }
        Self.writes.append(method)
        if !Self.ignoreWrite {
            switch method { case "star":Self.value["is_star"] = true;case "unstar":Self.value["is_star"] = false;case "hide":Self.value["last_hide_at"] = 2000;default:break }
        }
        if Self.holdWrite { Self.held = self;Self.observer?(fields);return }
        Self.observer?(fields);finish(["success":true])
    }
    func finish(_ object:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:object);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
