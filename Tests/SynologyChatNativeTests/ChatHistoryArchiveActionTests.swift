import XCTest
@testable import SynologyChatNative

@MainActor final class ChatHistoryArchiveActionTests:XCTestCase {
    override func setUp() { super.setUp();HistoryArchiveProtocol.reset() }
    private func setup(journal:ChatChannelActionJournal? = nil) async throws -> (ChatAPIClient,NativeChatPreviewModel) {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [HistoryArchiveProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://archive-action.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config));try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,channelActionJournal:journal);model.connected = true;model.liveStatus = .live
        _ = try await model.loadChannelDetails(channelID:97)
        addTeardownBlock { @MainActor in model.signOutLocally() };return (api,model)
    }
    func testPendingArchiveSurvivesRestartAndFindsReceiptWithoutStoredName() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),scope = String(repeating:"a",count:64)
        defer { try? FileManager.default.removeItem(at:folder) }
        let (api,first) = try await setup(journal:.init(directory:folder));first.restoreChannelActions(scope:scope,loaded:first.channels)
        let review = try await first.prepareHistoryArchive(channelID:97);HistoryArchiveProtocol.hideReceipt = true
        do { _ = try await first.archiveHistory(review);XCTFail("Missing receipt confirmed") } catch { }
        first.signOutLocally()
        let second = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,channelActionJournal:.init(directory:folder));second.connected = true;second.liveStatus = .live
        defer { second.signOutLocally() }
        second.restoreChannelActions(scope:scope,loaded:[])
        XCTAssertEqual(second.pendingHistoryArchives[97]?.channel.name,"Channel 97")
        do { _ = try await second.prepareHistoryArchive(channelID:97);XCTFail("Recovered archive dispatched") } catch { }
        HistoryArchiveProtocol.hideReceipt = false;HistoryArchiveProtocol.channel["name"] = "Renamed-after-archive"
        _ = try await second.checkHistoryArchive(channelID:97)
        XCTAssertEqual(HistoryArchiveProtocol.writes,1);XCTAssertTrue(second.pendingHistoryArchives.isEmpty)
        XCTAssertTrue(try ChatChannelActionJournal(directory:folder).activate(scope:scope).isEmpty)
    }
    func testConfirmedArchiveUsesObservedWireAndRetainsConversationDraft() async throws {
        let (_,model) = try await setup();model.selection = 97;model.draft = "Keep this draft"
        let review = try await model.prepareHistoryArchive(channelID:97)
        XCTAssertEqual(HistoryArchiveProtocol.writes,0)
        let receipt = try await model.archiveHistory(review)
        XCTAssertEqual(model.selection,97);XCTAssertEqual(receipt.id,26);XCTAssertEqual(model.draft,"Keep this draft");XCTAssertTrue(model.pendingHistoryArchives.isEmpty)
        XCTAssertEqual(HistoryArchiveProtocol.writes,1)
        let fields = try XCTUnwrap(HistoryArchiveProtocol.archiveWire)
        XCTAssertEqual(fields["version"],"2");XCTAssertEqual(fields["channel_id"],"97")
        XCTAssertNil(fields["archive_id"]);XCTAssertNil(fields["type"])
    }
    func testNewMessageAfterReviewRequiresAnotherConfirmation() async throws {
        let (_,model) = try await setup(),review = try await model.prepareHistoryArchive(channelID:97)
        HistoryArchiveProtocol.latest = 201
        do { _ = try await model.archiveHistory(review);XCTFail("Changed history archived") } catch { }
        XCTAssertEqual(HistoryArchiveProtocol.writes,0);XCTAssertTrue(model.pendingHistoryArchives.isEmpty)
    }
    func testRevokedPermissionPreventsDispatch() async throws {
        let (_,model) = try await setup(),review = try await model.prepareHistoryArchive(channelID:97)
        HistoryArchiveProtocol.allowed = false
        do { _ = try await model.archiveHistory(review);XCTFail("Revoked permission wrote") } catch { }
        XCTAssertEqual(HistoryArchiveProtocol.writes,0)
    }
    func testEmptyHistoryAndUnsupportedChannelsNeverDispatch() async throws {
        let (api,model) = try await setup()
        HistoryArchiveProtocol.empty = true
        do { _ = try await model.prepareHistoryArchive(channelID:97);XCTFail("Empty history accepted") } catch { }
        HistoryArchiveProtocol.empty = false
        for patch:[String:Any] in [["type":"public"],["encrypted":true],["channel_id":1],["channel_id":2],["is_joined":false],["is_closed":true],["hide_global_at":1]] {
            let value = HistoryArchiveProtocol.initial.merging(patch,uniquingKeysWith:{ _,new in new })
            let channel = try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:value))
            XCTAssertFalse(channel.supportsHistoryArchiving)
            do { try await api.archivePrivateChannelHistory(channel);XCTFail("Unsupported channel wrote") } catch { }
        }
        XCTAssertEqual(HistoryArchiveProtocol.writes,0)
    }
    func testUnconfirmedRequestCannotRepeatAndReadOnlyCheckCanReconcile() async throws {
        let (_,model) = try await setup(),review = try await model.prepareHistoryArchive(channelID:97)
        HistoryArchiveProtocol.hideReceipt = true
        do { _ = try await model.archiveHistory(review);XCTFail("Missing receipt accepted") } catch { }
        XCTAssertNotNil(model.pendingHistoryArchives[97]);XCTAssertFalse(model.canArchiveHistory(review.channel))
        do { _ = try await model.archiveHistory(review);XCTFail("Uncertain mutation repeated") } catch { }
        do { _ = try await model.prepareHistoryArchive(channelID:97);XCTFail("Uncertain guard bypassed") } catch { }
        HistoryArchiveProtocol.hideReceipt = false
        let result = try await model.checkHistoryArchive(channelID:97)
        XCTAssertEqual(result.id,26);XCTAssertEqual(HistoryArchiveProtocol.writes,1);XCTAssertTrue(model.pendingHistoryArchives.isEmpty)
    }
    func testWrongArchiveRangeAndChannelNeverConfirm() async throws {
        let (_,model) = try await setup(),review = try await model.prepareHistoryArchive(channelID:97)
        HistoryArchiveProtocol.receiptEnd = 199
        do { _ = try await model.archiveHistory(review);XCTFail("Out of range receipt accepted") } catch { }
        HistoryArchiveProtocol.receiptEnd = 200;HistoryArchiveProtocol.receiptChannel = 999
        do { _ = try await model.checkHistoryArchive(channelID:97);XCTFail("Other channel confirmed") } catch { }
        XCTAssertNotNil(model.pendingHistoryArchives[97]);XCTAssertEqual(HistoryArchiveProtocol.writes,1)
    }
    func testAccountChangeAfterReviewRejectsDispatch() async throws {
        let (_,model) = try await setup(),review = try await model.prepareHistoryArchive(channelID:97)
        model.signOutLocally()
        do { _ = try await model.archiveHistory(review);XCTFail("Old account review dispatched") } catch { }
        XCTAssertEqual(HistoryArchiveProtocol.writes,0);XCTAssertTrue(model.pendingHistoryArchives.isEmpty)
    }
    func testSignOutAfterDispatchCannotPublishReceipt() async throws {
        let (_,model) = try await setup(),review = try await model.prepareHistoryArchive(channelID:97)
        let started = expectation(description:"Archive dispatched");HistoryArchiveProtocol.holdWrite = true;HistoryArchiveProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.archiveHistory(review) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();HistoryArchiveProtocol.held?.finish(["success":true]);HistoryArchiveProtocol.held = nil
        do { _ = try await action.value;XCTFail("Old account published archive") } catch is CancellationError { }
        XCTAssertTrue(model.pendingHistoryArchives.isEmpty);XCTAssertFalse(model.channelManagementBusy)
    }
    func testCancellationAfterDispatchLeavesUncertainGuard() async throws {
        let (_,model) = try await setup(),review = try await model.prepareHistoryArchive(channelID:97)
        let started = expectation(description:"Archive dispatched");HistoryArchiveProtocol.holdWrite = true;HistoryArchiveProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.archiveHistory(review) }
        await fulfillment(of:[started],timeout:2);action.cancel();HistoryArchiveProtocol.held?.finish(["success":true]);HistoryArchiveProtocol.held = nil
        do { _ = try await action.value;XCTFail("Cancelled archive confirmed") } catch { }
        XCTAssertNotNil(model.pendingHistoryArchives[97]);XCTAssertFalse(model.channelManagementBusy);XCTAssertEqual(HistoryArchiveProtocol.writes,1)
    }
    func testRenameAfterReviewDoesNotArchiveAnotherScope() async throws {
        let (_,model) = try await setup(),review = try await model.prepareHistoryArchive(channelID:97)
        HistoryArchiveProtocol.channel["name"] = "Changed-name"
        do { _ = try await model.archiveHistory(review);XCTFail("Stale channel review accepted") } catch { }
        XCTAssertEqual(HistoryArchiveProtocol.writes,0)
    }
}

private final class HistoryArchiveProtocol:URLProtocol {
    static let initial:[String:Any] = ["channel_id":97,"name":"Synthetic-archive-test","type":"private","encrypted":false,"unread":0,"is_joined":true]
    static var channel = initial
    static var latest = 200,receiptEnd = 200,receiptChannel = 97,writes = 0
    static var allowed = true,empty = false,hideReceipt = false
    static var archiveWire:[String:String]?
    static var held:HistoryArchiveProtocol?
    static var holdWrite = false
    static var onWrite:(()->Void)?
    static func reset() { channel = initial;latest = 200;receiptEnd = 200;receiptChannel = 97;writes = 0;allowed = true;empty = false;hideReceipt = false;archiveWire = nil;held = nil;holdWrite = false;onWrite = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Archive","SYNO.Chat.Post"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let api = request.url!.lastPathComponent
        if api == "SYNO.Chat.Misc" { finish(["success":true,"data":["acls":[["acl_name":"channel_archive","allow":Self.allowed],["acl_name":"channel_set","allow":true]]]]);return }
        if api == "SYNO.Chat.Channel",fields["method"] == "archive" { Self.writes += 1;Self.archiveWire = fields;if Self.holdWrite { Self.held = self;Self.onWrite?();return };finish(["success":true]);return }
        if api == "SYNO.Chat.Channel" { finish(["success":true,"data":["channels":[Self.channel]]]);return }
        if api == "SYNO.Chat.Post" { finish(["success":true,"data":["posts":Self.empty ? [] : [["post_id":Self.latest,"channel_id":97,"creator_id":10,"message":"Synthetic","type":"text","create_at":1000]]]]);return }
        if api == "SYNO.Chat.Archive",fields["method"] == "list_name" { finish(["success":true,"data":["channel_names":["Synthetic-archive-test"]]]);return }
        if api == "SYNO.Chat.Archive" {
            var channel = Self.channel;channel["channel_id"] = Self.receiptChannel
            let record:[String:Any] = ["archive_id":26,"post_start":0,"post_end":2000,"post_id_start":0,"post_id_end":Self.receiptEnd,"props":["channel":channel,"reason":"user_trigger","trigger_user_id":10]]
            finish(["success":true,"data":["archives":Self.writes > 0 && !Self.hideReceipt ? [record] : []]]);return
        }
        finish(["success":false,"error":["code":102]])
    }
    func finish(_ value:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
