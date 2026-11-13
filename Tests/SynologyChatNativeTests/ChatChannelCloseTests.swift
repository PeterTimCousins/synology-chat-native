import XCTest
@testable import SynologyChatNative

@MainActor final class ChatChannelCloseTests:XCTestCase {
    override func setUp() { super.setUp();CloseProtocol.reset() }
    private func setup(journal:ChatChannelActionJournal? = nil) async throws -> (ChatAPIClient,NativeChatPreviewModel) {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [CloseProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://channel-close.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config));try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,channelActionJournal:journal);model.connected = true;model.liveStatus = .live
        _ = try await model.loadChannelDetails(channelID:97)
        addTeardownBlock { @MainActor in model.signOutLocally() };return (api,model)
    }
    func testPendingCloseSurvivesRestartAndReconcilesWithoutSecondWrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),scope = String(repeating:"a",count:64)
        defer { try? FileManager.default.removeItem(at:folder) }
        let (api,first) = try await setup(journal:.init(directory:folder));first.restoreChannelActions(scope:scope,loaded:first.channels)
        let review = try await first.prepareChannelClose(channelID:97);CloseProtocol.ignoreWrite = true
        do { _ = try await first.closeChannel(review);XCTFail("Ignored close confirmed") } catch { }
        first.signOutLocally()
        let second = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,channelActionJournal:.init(directory:folder));second.connected = true;second.liveStatus = .live
        defer { second.signOutLocally() }
        second.restoreChannelActions(scope:scope,loaded:[])
        XCTAssertEqual(second.pendingChannelClosures[97]?.channel.name,"Channel 97")
        do { _ = try await second.prepareChannelClose(channelID:97);XCTFail("Recovered close dispatched") } catch { }
        CloseProtocol.closed = true;_ = try await second.checkChannelClose(channelID:97)
        XCTAssertEqual(CloseProtocol.writes,1);XCTAssertTrue(second.pendingChannelClosures.isEmpty)
        XCTAssertTrue(try ChatChannelActionJournal(directory:folder).activate(scope:scope).isEmpty)
    }
    func testJournalWriteFailurePreventsCloseDispatch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),scope = String(repeating:"a",count:64)
        defer { try? FileManager.default.removeItem(at:folder) }
        let (_,model) = try await setup(journal:.init(directory:folder));model.restoreChannelActions(scope:scope,loaded:model.channels)
        let review = try await model.prepareChannelClose(channelID:97)
        try FileManager.default.removeItem(at:folder);try Data("Unavailable directory".utf8).write(to:folder)
        do { _ = try await model.closeChannel(review);XCTFail("Unjournaled close dispatched") } catch { }
        XCTAssertEqual(CloseProtocol.writes,0);XCTAssertNotNil(model.channelActionRecoveryError);XCTAssertFalse(model.canCloseChannel(review.channel))
    }
    func testCorruptRecoveryDisablesArchiveAndCloseWithoutLosingRecord() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),scope = String(repeating:"a",count:64)
        defer { try? FileManager.default.removeItem(at:folder) }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file = folder.appendingPathComponent(scope+".json"),original = Data("Corrupt record".utf8);try original.write(to:file)
        let (_,model) = try await setup(journal:.init(directory:folder));model.restoreChannelActions(scope:scope,loaded:model.channels)
        let channel = try XCTUnwrap(model.channels.first)
        XCTAssertNotNil(model.channelActionRecoveryError);XCTAssertFalse(model.canCloseChannel(channel));XCTAssertFalse(model.canArchiveHistory(channel))
        do { _ = try await model.prepareChannelClose(channelID:97);XCTFail("Corrupt recovery permitted request") } catch { }
        XCTAssertEqual(CloseProtocol.writes,0);XCTAssertEqual(try Data(contentsOf:file),original)
        // Simulate storage repaired outside the app. Retrying only reloads local
        // state; it must not submit any channel action.
        try Data(("{\"version\":1,\"accountScope\":\""+scope+"\",\"records\":[]}").utf8).write(to:file)
        model.retryChannelActionRecovery();XCTAssertNil(model.channelActionRecoveryError);XCTAssertTrue(model.canCloseChannel(channel));XCTAssertEqual(CloseProtocol.writes,0)
    }
    func testCloseWireCanonicalArchiveAndDraftRetention() async throws {
        let (_,model) = try await setup();model.selection = 97;model.draft = "Copy this unsent draft"
        let review = try await model.prepareChannelClose(channelID:97);XCTAssertEqual(CloseProtocol.writes,0)
        let receipt = try await model.closeChannel(review)
        XCTAssertEqual(receipt.id,27);XCTAssertEqual(CloseProtocol.writes,1)
        XCTAssertEqual(CloseProtocol.closeFields?["version"],"4");XCTAssertEqual(CloseProtocol.closeFields?["channel_id"],"97");XCTAssertNil(CloseProtocol.closeFields?["archive_id"])
        XCTAssertNil(model.selection);XCTAssertEqual(model.drafts[97],"Copy this unsent draft");XCTAssertTrue(model.channels.isEmpty);XCTAssertTrue(model.pendingChannelClosures.isEmpty);XCTAssertTrue(model.knownClosedChannelIDs.contains(97))
    }
    func testPublicAnonymousAndEncryptedCloseDoNotSendKeysOrRequireDecryption() async throws {
        for type in ["public","anonymous"] {
            CloseProtocol.reset();let (_,model) = try await setup();CloseProtocol.channel["type"] = type;CloseProtocol.channel["encrypted"] = true
            let review = try await model.prepareChannelClose(channelID:97)
            XCTAssertTrue(model.canCloseChannel(review.channel))
            _ = try await model.closeChannel(review)
            XCTAssertNil(CloseProtocol.closeFields?["channel_key_enc"]);XCTAssertEqual(CloseProtocol.writes,1)
            model.signOutLocally()
        }
    }
    func testChangedNameMembershipOrEncryptionRequiresFreshReview() async throws {
        let (_,model) = try await setup(),review = try await model.prepareChannelClose(channelID:97)
        for patch:[String:Any] in [["name":"Renamed"],["total_member_count":2],["encrypted":true],["type":"public"]] {
            CloseProtocol.channel = CloseProtocol.initial.merging(patch,uniquingKeysWith:{ _,new in new })
            do { _ = try await model.closeChannel(review);XCTFail("Changed channel closed") } catch { }
        }
        XCTAssertEqual(CloseProtocol.writes,0)
    }
    func testRevokedACLAndUnjoinedSourcePreventWrite() async throws {
        let (_,model) = try await setup(),review = try await model.prepareChannelClose(channelID:97)
        CloseProtocol.allow = false
        do { _ = try await model.closeChannel(review);XCTFail("Revoked permission wrote") } catch { }
        CloseProtocol.allow = true;CloseProtocol.closed = true
        do { _ = try await model.closeChannel(review);XCTFail("Missing source wrote") } catch { }
        XCTAssertEqual(CloseProtocol.writes,0)
    }
    func testUnsupportedChannelCannotReachCloseEndpoint() async throws {
        let (api,_) = try await setup()
        for patch:[String:Any] in [["channel_id":1],["channel_id":2],["type":"synobot"],["type":"chatbot"],["type":"unexpected"],["is_joined":false],["is_closed":true],["hide_global_at":1]] {
            let fields = CloseProtocol.initial.merging(patch,uniquingKeysWith:{ _,new in new })
            let channel = try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:fields))
            XCTAssertFalse(channel.supportsClosing)
            do { try await api.closeChatChannel(channel);XCTFail("Unsupported close sent") } catch { }
        }
        XCTAssertEqual(CloseProtocol.writes,0)
    }
    func testUnconfirmedCloseCannotRepeatAndLaterReceiptReconcilesReadOnly() async throws {
        let (_,model) = try await setup();model.selection = 97
        let review = try await model.prepareChannelClose(channelID:97);CloseProtocol.ignoreWrite = true
        do { _ = try await model.closeChannel(review);XCTFail("Ignored close confirmed") } catch { }
        XCTAssertNotNil(model.pendingChannelClosures[97]);model.draft = "Do not send while closing";XCTAssertFalse(model.canSend);XCTAssertFalse(model.canInteract);XCTAssertFalse(model.canCloseChannel(review.channel))
        do { _ = try await model.closeChannel(review);XCTFail("Uncertain request repeated") } catch { }
        CloseProtocol.closed = true
        let receipt = try await model.checkChannelClose(channelID:97)
        XCTAssertEqual(receipt.id,27);XCTAssertEqual(CloseProtocol.writes,1);XCTAssertTrue(model.pendingChannelClosures.isEmpty)
    }
    func testMissingWrongOrDuplicateArchiveCannotConfirmClosure() async throws {
        let (_,model) = try await setup(),review = try await model.prepareChannelClose(channelID:97)
        CloseProtocol.hideArchive = true
        do { _ = try await model.closeChannel(review);XCTFail("Missing archive confirmed") } catch { }
        CloseProtocol.hideArchive = false;CloseProtocol.reason = "user_trigger"
        do { _ = try await model.checkChannelClose(channelID:97);XCTFail("Wrong reason confirmed") } catch { }
        CloseProtocol.reason = "channel_closed";CloseProtocol.receiptChannel = 999
        do { _ = try await model.checkChannelClose(channelID:97);XCTFail("Other channel receipt confirmed") } catch { }
        CloseProtocol.receiptChannel = 97;CloseProtocol.duplicate = true
        do { _ = try await model.checkChannelClose(channelID:97);XCTFail("Duplicate receipt confirmed") } catch { }
        XCTAssertEqual(CloseProtocol.writes,1);XCTAssertNotNil(model.pendingChannelClosures[97])
    }
    func testNestedCloseEventInvalidatesOldTimelineAndPreservesDraft() async throws {
        let (_,model) = try await setup();let channel = try XCTUnwrap(model.channels.first)
        let post = try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":200,"channel_id":97,"creator_id":10,"type":"text","message":"Synthetic","create_at":1000}"#.utf8))
        model.selection = 97;model.draft = "Keep me";model.posts = [post]
        XCTAssertTrue(model.canAct(on:post))
        let event = ChatLiveEvent(name:"client.channel.close",payload:.object(["channel":.object(["channel_id":.integer(97)])]))
        XCTAssertEqual(event.channelID,97);model.handleLiveEvent(event)
        XCTAssertNil(model.selection);XCTAssertTrue(model.posts.isEmpty);XCTAssertEqual(model.drafts[97],"Keep me");XCTAssertFalse(model.canAct(on:post))
        model.channels = [channel];model.selection = 97 // A stale read must not unlock closed content.
        XCTAssertNil(model.selectedChannel);XCTAssertFalse(model.canRead(97));XCTAssertFalse(model.canSend);XCTAssertFalse(model.canAct(on:post))
    }
    func testOtherChannelCloseLeavesCurrentConversationUntouched() async throws {
        let (_,model) = try await setup();model.selection = 97;model.draft = "Unsent"
        model.handleLiveEvent(.init(name:"client.channel.close",payload:.object(["channel":.object(["channel_id":.integer(123)])])))
        XCTAssertEqual(model.selection,97);XCTAssertEqual(model.draft,"Unsent");XCTAssertTrue(model.canRead(97))
    }
    func testSignOutAfterDispatchCannotPublishOldReceipt() async throws {
        let (_,model) = try await setup(),review = try await model.prepareChannelClose(channelID:97)
        let started = expectation(description:"Close dispatched");CloseProtocol.holdWrite = true;CloseProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.closeChannel(review) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();CloseProtocol.held?.finish(["success":true]);CloseProtocol.held = nil
        do { _ = try await action.value;XCTFail("Old close published") } catch is CancellationError { }
        XCTAssertTrue(model.pendingChannelClosures.isEmpty);XCTAssertTrue(model.knownClosedChannelIDs.isEmpty)
    }
    func testCancellationAfterDispatchRetainsUncertainGuard() async throws {
        let (_,model) = try await setup(),review = try await model.prepareChannelClose(channelID:97)
        let started = expectation(description:"Close dispatched");CloseProtocol.holdWrite = true;CloseProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.closeChannel(review) }
        await fulfillment(of:[started],timeout:2);action.cancel();CloseProtocol.held?.finish(["success":true]);CloseProtocol.held = nil
        do { _ = try await action.value;XCTFail("Cancelled close confirmed") } catch { }
        XCTAssertNotNil(model.pendingChannelClosures[97]);XCTAssertFalse(model.channelManagementBusy);XCTAssertEqual(CloseProtocol.writes,1)
    }
}

private final class CloseProtocol:URLProtocol {
    static let initial:[String:Any] = ["channel_id":97,"name":"Synthetic-close-test","type":"private","encrypted":false,"unread":0,"is_joined":true,"total_member_count":1]
    static var channel = initial
    static var closed = false,allow = true,ignoreWrite = false,hideArchive = false,duplicate = false,holdWrite = false
    static var writes = 0,receiptChannel = 97
    static var reason = "channel_closed"
    static var closeFields:[String:String]?
    static var held:CloseProtocol?
    static var onWrite:(()->Void)?
    static func reset() { channel = initial;closed = false;allow = true;ignoreWrite = false;hideArchive = false;duplicate = false;holdWrite = false;writes = 0;receiptChannel = 97;reason = "channel_closed";closeFields = nil;held = nil;onWrite = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Archive","SYNO.Chat.Post"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),method = fields["method"] ?? "",api = request.url!.lastPathComponent
        if api == "SYNO.Chat.Misc" { finish(["success":true,"data":["acls":[["acl_name":"channel_close","allow":Self.allow],["acl_name":"channel_archive","allow":true],["acl_name":"channel_set","allow":true]]]]);return }
        if api == "SYNO.Chat.Channel",method == "close" { Self.writes += 1;Self.closeFields = fields;if !Self.ignoreWrite { Self.closed = true };if Self.holdWrite { Self.held = self;Self.onWrite?();return };finish(["success":true]);return }
        if api == "SYNO.Chat.Channel",method == "get" { finish(["success":true,"data":["channel":Self.channel]]);return }
        if api == "SYNO.Chat.Channel" { finish(["success":true,"data":["channels":Self.closed ? [] : [Self.channel]]]);return }
        if api == "SYNO.Chat.Archive",method == "list_name" { finish(["success":true,"data":["channel_names":["Synthetic-close-test"]]]);return }
        if api == "SYNO.Chat.Archive" {
            var channel = Self.channel;channel["channel_id"] = Self.receiptChannel
            let record:[String:Any] = ["archive_id":27,"post_start":0,"post_end":2000,"post_id_start":0,"post_id_end":200,"props":["channel":channel,"reason":Self.reason,"trigger_user_id":10]]
            finish(["success":true,"data":["archives":Self.closed && !Self.hideArchive ? (Self.duplicate ? [record,record] : [record]) : []]]);return
        }
        finish(["success":false,"error":["code":102]])
    }
    func finish(_ value:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
