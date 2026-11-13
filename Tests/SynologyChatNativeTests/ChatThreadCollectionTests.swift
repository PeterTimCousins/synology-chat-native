import XCTest
@testable import SynologyChatNative

@MainActor final class ChatThreadCollectionTests: XCTestCase {
    private func post(_ id:Int,channel:Int = 93,time:Int = 1000,thread:Int = 0) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":id,"channel_id":channel,"creator_id":10,"message":"Synthetic thread","type":"normal","create_at":time,"thread_id":thread,"comment_count":1]))
    }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ThreadCollectionStub.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover();return api
    }
    private func channel(subscriptions:[Int]) throws -> ChatChannel {
        try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:["channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"subscribes":subscriptions]))
    }
    private func model(subscriptions:[Int] = [1]) async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:try await api(),restoreNotificationPreference:false)
        model.channels = [try channel(subscriptions:subscriptions)];model.selection = 93;model.connected = true;model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func tearDown() { ThreadCollectionStub.handler = nil;ThreadCollectionStub.holdWrites = false;ThreadCollectionStub.held = nil;super.tearDown() }
    func testAggregateOrdersByLatestActivityAndRejectsUnrelatedReplies() async throws {
        let store = NativeThreadsStore()
        store.load(channelIDs:[93,94]) { id,offset in
            XCTAssertEqual(offset,0)
            if id == 93 {
                return ChatThreadCollectionPage(search_results:[try self.post(1)],related_posts:[try self.post(11,time:4000,thread:1),try self.post(999,channel:94,time:9000,thread:1),try self.post(998,time:8000,thread:2)],total:1)
            }
            return ChatThreadCollectionPage(search_results:[try self.post(2,channel:94,time:2000)],related_posts:[try self.post(21,channel:94,time:3000,thread:2)],total:1)
        }
        await store.task?.value
        XCTAssertEqual(store.entries.map(\.id),[1,2]);XCTAssertEqual(store.entries.map { $0.latest?.id },[11,21]);XCTAssertFalse(store.hasMore)
    }
    func testIndependentOffsetsOverlapAndPartialFailureRecoverWithoutLosingOtherThreads() async throws {
        let store = NativeThreadsStore();var requests:[String] = []
        store.load(channelIDs:[93,94]) { id,offset in
            requests.append("\(id):\(offset)")
            if id == 94 { throw ChatAPIError.connection }
            return ChatThreadCollectionPage(search_results:try (1...25).map { try self.post($0) },related_posts:[],total:27)
        }
        await store.task?.value
        XCTAssertEqual(store.entries.count,25);XCTAssertEqual(store.failures.count,1);XCTAssertTrue(store.hasMore)
        store.load(channelIDs:[93,94],more:true) { id,offset in
            requests.append("\(id):\(offset)")
            return ChatThreadCollectionPage(search_results:[try self.post(id == 93 ? 25 : 100,channel:Int(id)),try self.post(id == 93 ? 26 : 101,channel:Int(id))],related_posts:[],total:id == 93 ? 27 : 2)
        }
        await store.task?.value
        XCTAssertEqual(requests,["93:0","94:0","93:25","94:0"])
        XCTAssertEqual(store.entries.count,28);XCTAssertTrue(store.failures.isEmpty);XCTAssertFalse(store.hasMore)
    }
    func testChangingScopeDiscardsLateUncancellableOldResponse() async throws {
        let store = NativeThreadsStore();var pending:CheckedContinuation<ChatThreadCollectionPage,Error>?
        store.load(channelIDs:[93]) { _,_ in try await withCheckedThrowingContinuation { pending = $0 } }
        let old = store.task
        while pending == nil { await Task.yield() }
        store.load(channelIDs:[94]) { _,_ in ChatThreadCollectionPage(search_results:[try self.post(2,channel:94)],related_posts:[],total:1) }
        await store.task?.value
        pending?.resume(returning:ChatThreadCollectionPage(search_results:[try post(1)],related_posts:[],total:1));await old?.value
        XCTAssertEqual(store.entries.map(\.id),[2]);XCTAssertFalse(store.loading)
        store.clear();XCTAssertTrue(store.entries.isEmpty)
    }
    func testAPIUsesDocumentedThreadPageAndSubscriptionParameters() async throws {
        var methods:[String] = []
        ThreadCollectionStub.handler = { fields in
            methods.append(fields["method"]!)
            if fields["method"] == "thread_list" {
                XCTAssertEqual(fields["channel_id"],"93");XCTAssertEqual(fields["offset"],"25");XCTAssertEqual(fields["limit"],"25");XCTAssertEqual(fields["related_comment_count"],"1");XCTAssertEqual(fields["version"],"5")
                return Data(#"{"success":true,"data":{"search_results":[],"related_posts":[],"total":0}}"#.utf8)
            }
            XCTAssertEqual(fields["version"],"1");XCTAssertEqual(fields["post_id"],"123");XCTAssertNil(fields["channel_id"])
            return Data(#"{"success":true}"#.utf8)
        }
        let api = try await api();_ = try await api.threadCollection(channelID:93,offset:25)
        try await api.setThreadSubscription(postID:123,enabled:true);try await api.setThreadSubscription(postID:123,enabled:false)
        do { _ = try await api.threadCollection(channelID:0);XCTFail("Invalid scope") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(methods,["thread_list","create","delete"])
    }
    func testSubscriptionUsesCanonicalChannelStateAndRejectsRepliesOrUnconfirmedChange() async throws {
        var follows = true;var confirm = true;var writes = 0
        ThreadCollectionStub.handler = { fields in
            if fields["api"] == "SYNO.Chat.Channel" {
                return try JSONSerialization.data(withJSONObject:["success":true,"data":["channels":[["channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"subscribes":follows ? [1] : []]]]])
            }
            writes += 1
            if confirm { follows = fields["method"] == "create" }
            return Data(#"{"success":true}"#.utf8)
        }
        let model = try await model();let root = try post(1);model.posts = [root]
        let stopped = await model.setThreadSubscription(root,enabled:false);XCTAssertTrue(stopped);XCTAssertEqual(model.followsThread(root),false)
        let restored = await model.setThreadSubscription(root,enabled:true);XCTAssertTrue(restored);XCTAssertEqual(model.followsThread(root),true)
        let reply = try post(2,thread:1)
        let rejected = await model.setThreadSubscription(reply,enabled:false);XCTAssertFalse(rejected);XCTAssertEqual(writes,2)
        confirm = false
        let mismatch = await model.setThreadSubscription(root,enabled:false);XCTAssertFalse(mismatch);XCTAssertEqual(model.followsThread(root),true)
        XCTAssertNotNil(model.error);XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testSignOutDuringSubscriptionWriteCannotReadOldAccountChannels() async throws {
        let started = expectation(description:"Write started");ThreadCollectionStub.holdWrites = true
        ThreadCollectionStub.handler = { fields in XCTAssertEqual(fields["method"],"delete");started.fulfill();return Data(#"{"success":true}"#.utf8) }
        let model = try await model();let root = try post(1)
        let task = Task { await model.setThreadSubscription(root,enabled:false) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        ThreadCollectionStub.held?.finish(Data(#"{"success":true}"#.utf8));let result = await task.value
        XCTAssertFalse(result);XCTAssertTrue(model.channels.isEmpty);XCTAssertNil(model.error)
    }
    func testForeignChannelRootFailsAPIValidation() async throws {
        ThreadCollectionStub.handler = { _ in Data(#"{"success":true,"data":{"search_results":[{"post_id":1,"channel_id":94,"creator_id":10,"message":"Synthetic","type":"normal","create_at":1000}],"related_posts":[],"total":1}}"#.utf8) }
        let api = try await api()
        do { _ = try await api.threadCollection(channelID:93);XCTFail("Cross-channel root accepted") } catch ChatAPIError.invalidResponse { }
    }
}

private final class ThreadCollectionStub: URLProtocol {
    static var handler:(([String:String]) throws -> Data)?
    static var holdWrites = false
    static var held:ThreadCollectionStub?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") {
            finish(Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"},"SYNO.Chat.Post.Subscribe":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"},"SYNO.Chat.Channel":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"}}}"#.utf8));return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };data.append(contentsOf:buffer.prefix(count)) }
        }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        do {
            if Self.holdWrites && fields["api"] == "SYNO.Chat.Post.Subscribe" { Self.held = self;_ = try Self.handler?(fields);return }
            finish(try Self.handler?(fields) ?? Data(#"{"success":true}"#.utf8))
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    func finish(_ data:Data) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
