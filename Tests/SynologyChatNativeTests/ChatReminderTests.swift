import XCTest
@testable import SynologyChatNative

@MainActor final class ChatReminderTests:XCTestCase {
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ReminderProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://reminder-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover();return api
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:try await api(),restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        model.directory = try [10,6].map { try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:["user_id":$0,"nickname":"Synthetic Peter","type":"human"])) }
        model.selection = 93;model.connected = true;model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    private func post() throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:ReminderProtocol.source)) }
    override func setUp() { super.setUp();ReminderProtocol.reset() }
    override func tearDown() { ReminderProtocol.observer = nil;ReminderProtocol.held = nil;super.tearDown() }
    func testPersonalReminderWireUsesPostIDAndMillisecondTimeWithoutChannelOrConnectionOnWrite() async throws {
        let api = try await api(),date = Date(timeIntervalSince1970:ceil(Date().timeIntervalSince1970+3600)),time = try ChatReminderTime.future(date)
        var methods:[String] = []
        ReminderProtocol.observer = { fields in
            guard fields["api"] == "SYNO.Chat.Post.Reminder" else { return }
            methods.append(fields["method"]!);XCTAssertEqual(fields["version"],"1")
            if fields["method"] == "list" { XCTAssertEqual(fields["channel_id"],"93");XCTAssertNil(fields["post_id"]) }
            else { XCTAssertEqual(fields["post_id"],"766");XCTAssertNil(fields["channel_id"]) }
            if fields["method"] == "set" { XCTAssertEqual(fields["remind_at"],String(Int64(time))) }
            XCTAssertNil(fields["conn_id"]);XCTAssertNil(fields["cronjob_id"])
        }
        try await api.setReminder(postID:766,date:date)
        let actual = try await api.reminderTime(postID:766);XCTAssertEqual(actual,time)
        let list = try await api.reminders(channelID:93);XCTAssertEqual(list.first?.remindAt,time)
        try await api.removeReminder(postID:766);XCTAssertEqual(methods,["set","get","list","delete"])
        do { _ = try await api.reminderTime(postID:0);XCTFail("Invalid ID sent") } catch ChatAPIError.invalidResponse { }
        do { _ = try await api.reminders(channelID:0);XCTFail("Unsupported global channel sent") } catch ChatAPIError.invalidResponse { }
        do { try await api.removeReminder(postID:-1);XCTFail("Invalid ID sent") } catch ChatAPIError.invalidResponse { }
    }
    func testTimeBoundsDoNotTrapOrAcceptPastDates() throws {
        let now = Date(timeIntervalSince1970:1000)
        XCTAssertEqual(try ChatReminderTime.future(Date(timeIntervalSince1970:2000.125),now:now),2000125)
        for time in [Double.infinity,Double.nan,-1,0,999,1000,253402300800] {
            XCTAssertThrowsError(try ChatReminderTime.future(Date(timeIntervalSince1970:time),now:now))
        }
        for time in [Double.nan,Double.infinity,-1,1.5,253402300800000] { XCTAssertFalse(ChatReminderTime.valid(time)) }
        XCTAssertTrue(ChatReminderTime.valid(0))
    }
    func testListRejectsCrossConversationDuplicatesAndMalformedReminderMetadata() async throws {
        let api = try await api();var first = ReminderProtocol.source;first["props"] = ["remind_at":2000]
        var second = first;second["post_id"] = 765;second["props"] = ["remind_at":1000]
        ReminderProtocol.page = [first,second]
        let list = try await api.reminders(channelID:93);XCTAssertEqual(list.map(\.id),[765,766])
        var cross = first;cross["channel_id"] = 94
        var missing = first;missing["props"] = [:]
        var invalid = first;invalid["props"] = ["remind_at":-1]
        for page in [[first,first],[cross],[missing],[invalid]] {
            ReminderProtocol.page = page
            do { _ = try await api.reminders(channelID:93);XCTFail("Bad list accepted") } catch { }
        }
        ReminderProtocol.invalidTime = -1
        do { _ = try await api.reminderTime(postID:766);XCTFail("Bad get accepted") } catch ChatAPIError.invalidResponse { }
    }
    func testCanonicalCreateEditRemoveRoundTripPreservesMessageAndComposerDraft() async throws {
        let model = try await model(),post = try post();model.posts = [post];model.draft = "Unsent ordinary draft"
        let first = Date(timeIntervalSinceNow:3600),second = Date(timeIntervalSinceNow:7200),revision = model.reminderRevision
        let created = try await model.changeReminder(post,date:first,expectedTime:0)
        XCTAssertEqual(created,try ChatReminderTime.future(first));XCTAssertNotEqual(model.reminderRevision,revision)
        let edited = try await model.changeReminder(post,date:second,expectedTime:created)
        XCTAssertEqual(edited,try ChatReminderTime.future(second))
        let removed = try await model.changeReminder(post,date:nil,expectedTime:edited);XCTAssertEqual(removed,0)
        XCTAssertEqual(ReminderProtocol.writes,["set","set","delete"])
        XCTAssertEqual(model.draft,"Unsent ordinary draft");XCTAssertEqual(model.posts.first?.message,post.message)
        XCTAssertTrue(model.pendingMessageActions.isEmpty);XCTAssertFalse(model.reminderBusy)
    }
    func testStaleReminderChangedByOtherClientIsNotOverwritten() async throws {
        let model = try await model();ReminderProtocol.time = 1000
        do { _ = try await model.changeReminder(try post(),date:Date(timeIntervalSinceNow:3600),expectedTime:0);XCTFail("Stale reminder replaced") }
        catch let failure as ChatReminderFailure { XCTAssertFalse(failure.uncertain) }
        XCTAssertTrue(ReminderProtocol.writes.isEmpty);XCTAssertFalse(model.reminderBusy)
    }
    func testDeletedOrChangedSourceFailsBeforeMutation() async throws {
        let model = try await model(),original = try post()
        for change:[String:Any] in [["delete_at":1000],["thread_id":123],["type":"system"],["channel_id":94]] {
            ReminderProtocol.source = ReminderProtocol.originalSource.merging(change,uniquingKeysWith:{ _,new in new })
            do { _ = try await model.changeReminder(original,date:Date(timeIntervalSinceNow:3600),expectedTime:0);XCTFail("Unavailable source mutated") } catch { }
        }
        XCTAssertTrue(ReminderProtocol.writes.isEmpty)
    }
    func testSuccessEnvelopeWithoutCanonicalChangeIsUncertainAndCannotPublishSuccessRevision() async throws {
        let model = try await model(),revision = model.reminderRevision;ReminderProtocol.ignoreWrite = true
        do { _ = try await model.changeReminder(try post(),date:Date(timeIntervalSinceNow:3600),expectedTime:0);XCTFail("No-op confirmed") }
        catch let failure as ChatReminderFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(model.reminderRevision,revision);XCTAssertEqual(ReminderProtocol.writes,["set"])
        XCTAssertTrue(model.pendingMessageActions.isEmpty);XCTAssertFalse(model.reminderBusy)
    }
    func testReplySourcePreflightIncludesThreadAndReminderRemainsPostScoped() async throws {
        ReminderProtocol.source["thread_id"] = 735;ReminderProtocol.source["creator_id"] = 6
        let model = try await model();var sawThread = false
        ReminderProtocol.observer = { fields in if fields["api"] == "SYNO.Chat.Post" { sawThread = fields["thread_id"] == "735" } }
        _ = try await model.changeReminder(try post(),date:Date(timeIntervalSinceNow:3600),expectedTime:0)
        XCTAssertTrue(sawThread);XCTAssertEqual(ReminderProtocol.writes,["set"])
    }
    func testSignOutAfterDispatchCannotReadOrPublishOldAccountReceipt() async throws {
        let model = try await model(),started = expectation(description:"Reminder write held");ReminderProtocol.holdWrite = true
        ReminderProtocol.observer = { if $0["method"] == "set" { started.fulfill() } }
        let task = Task { try await model.changeReminder(try post(),date:Date(timeIntervalSinceNow:3600),expectedTime:0) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();let revision = model.reminderRevision
        ReminderProtocol.held?.finish(["success":true])
        do { _ = try await task.value;XCTFail("Old session accepted") } catch is CancellationError { }
        XCTAssertEqual(model.reminderRevision,revision);XCTAssertFalse(model.reminderBusy);XCTAssertTrue(model.pendingMessageActions.isEmpty)
        XCTAssertEqual(ReminderProtocol.gets,1)
    }
    func testEncryptedOrOfflineSourceDoesNotAllowReminderChanges() async throws {
        let model = try await model();model.liveStatus = .offline
        XCTAssertFalse(model.canRemind(try post()))
        model.liveStatus = .live
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":true,"unread":0}"#.utf8))]
        XCTAssertFalse(model.canRemind(try post()));XCTAssertFalse(model.canBrowseReminders(channelID:93))
        XCTAssertTrue(ReminderProtocol.writes.isEmpty)
    }
    func testPollAndBotMessagesDoNotOfferReminderWorkflow() async throws {
        let model = try await model()
        ReminderProtocol.source["type"] = "vote";XCTAssertFalse(model.canRemind(try post()))
        ReminderProtocol.source = ReminderProtocol.originalSource
        model.directory = [try JSONDecoder().decode(ChatUser.self,from:Data(#"{"user_id":10,"nickname":"Synthetic bot","type":"bot"}"#.utf8))]
        XCTAssertFalse(model.canRemind(try post()))
    }
    func testRemoteReminderBroadcastInvalidatesCollectionRevision() async throws {
        let model = try await model(),revision = model.reminderRevision
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("post.reminder.set"),"data":.object(["channel_id":.integer(93),"post_id":.integer(766)])])))
        XCTAssertNotEqual(model.reminderRevision,revision)
    }
}

private final class ReminderProtocol:URLProtocol {
    static let originalSource:[String:Any] = ["post_id":766,"channel_id":93,"creator_id":10,"message":"Synthetic reminder source","type":"normal","create_at":1000,"thread_id":0]
    static var source = originalSource
    static var time:Double = 0
    static var invalidTime:Double?
    static var page:[[String:Any]]?
    static var writes:[String] = []
    static var gets = 0
    static var ignoreWrite = false
    static var holdWrite = false
    static var held:ReminderProtocol?
    static var observer:(([String:String])->Void)?
    static func reset() { source = originalSource;time = 0;invalidTime = nil;page = nil;writes = [];gets = 0;ignoreWrite = false;holdWrite = false;held = nil;observer = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Post.Reminder","SYNO.Chat.Post"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        var fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });fields["api"] = request.url!.lastPathComponent
        let method = fields["method"] ?? ""
        if fields["api"] == "SYNO.Chat.Post" { Self.observer?(fields);finish(["success":true,"data":["posts":[Self.source]]]);return }
        if ["set","delete"].contains(method) {
            Self.writes.append(method)
            if !Self.ignoreWrite { Self.time = method == "delete" ? 0 : Double(fields["remind_at"] ?? "0") ?? 0 }
            if Self.holdWrite { Self.held = self;Self.observer?(fields);return }
        }
        if method == "get" { Self.gets += 1 }
        Self.observer?(fields)
        switch method {
        case "get":finish(["success":true,"data":["remind_at":Self.invalidTime ?? Self.time]])
        case "list":var post = Self.source;post["props"] = ["remind_at":Self.time];finish(["success":true,"data":["posts":Self.page ?? (Self.time > 0 ? [post] : [])]])
        case "set","delete":finish(["success":true])
        default:finish(["success":false,"error":["code":400]])
        }
    }
    func finish(_ object:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:object);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
