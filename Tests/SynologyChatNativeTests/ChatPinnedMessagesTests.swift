import XCTest
@testable import SynologyChatNative

@MainActor final class ChatPinnedMessagesTests:XCTestCase {
    private func post(_ id:Int = 1,channel:Int = 93,pin:Int = 0,sticky:Bool = false,thread:Int = 0,type:String = "normal") throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":id,"channel_id":channel,"creator_id":10,"message":"Synthetic pin message","type":type,"create_at":1000,"last_pin_at":pin,"is_sticky":sticky,"thread_id":thread,"comment_count":0]))
    }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [PinStub.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover();return api
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:try await api(),restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        model.connected = true;model.liveStatus = .live;model.selection = 93
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func tearDown() { PinStub.handler = nil;PinStub.hold = false;PinStub.held = nil;super.tearDown() }
    func testAPIUsesPinUnpinAndPinnedBulletinContract() async throws {
        var methods:[String] = []
        PinStub.handler = { fields in
            methods.append(fields["method"]!);XCTAssertEqual(fields["version"],"5")
            if fields["method"] == "search" {
                XCTAssertEqual(fields["in"],"[93]");XCTAssertEqual(fields["has"],#"["pin"]"#)
                XCTAssertEqual(fields["sort_by"],#""last_pin_at""#);XCTAssertEqual(fields["sort_by_array"],#"["is_sticky","last_pin_at"]"#)
                XCTAssertEqual(fields["offset"],"25");XCTAssertEqual(fields["limit"],"25")
                return Data(#"{"success":true,"data":{"search_results":[],"total":0}}"#.utf8)
            }
            XCTAssertEqual(fields["post_id"],"1");XCTAssertNil(fields["channel_id"]);XCTAssertNil(fields["thread_id"])
            return Data(#"{"success":true}"#.utf8)
        }
        let api = try await api();try await api.setPinned(postID:1,enabled:true);try await api.setPinned(postID:1,enabled:false)
        _ = try await api.pinnedMessages(channelID:93,query:"synthetic",offset:25)
        do { try await api.setPinned(postID:0,enabled:true);XCTFail("Invalid pin ID sent") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(methods,["pin","unpin","search"])
    }
    func testCanonicalPinRoundTripUpdatesMainAndRootThreadMetadata() async throws {
        var pinned = false
        PinStub.handler = { fields in
            switch fields["method"] {
            case "pin":pinned = true
            case "unpin":pinned = false
            case "list":
                XCTAssertNil(fields["thread_id"],"Pin changes thread_id; canonical root read must use main context")
                return try JSONSerialization.data(withJSONObject:["success":true,"data":["posts":[["post_id":1,"channel_id":93,"creator_id":10,"message":"Synthetic pin message","type":"normal","create_at":1000,"thread_id":pinned ? 1 : 0,"last_pin_at":pinned ? 2000 : 0,"comment_count":0]]]])
            default:XCTFail("Unexpected method")
            }
            return Data(#"{"success":true}"#.utf8)
        }
        let model = try await model();let target = try post();model.posts = [target];model.threadRoot = target
        let added = await model.setPinned(target,enabled:true);XCTAssertTrue(added)
        XCTAssertEqual(model.posts.first?.isPinned,true);XCTAssertEqual(model.posts.first?.thread_id,1);XCTAssertEqual(model.threadRoot?.isPinned,true)
        let removed = await model.setPinned(model.posts[0],enabled:false);XCTAssertTrue(removed)
        XCTAssertEqual(model.posts.first?.isPinned,false);XCTAssertEqual(model.posts.first?.thread_id,0)
        XCTAssertEqual(model.posts.first?.message,target.message);XCTAssertEqual(model.posts.first?.comment_count,0);XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testRepliesEncryptedSystemAndMissingChannelsCannotPinAndFailureDoesNotChangeFlag() async throws {
        var requests = 0
        PinStub.handler = { _ in requests += 1;return Data(#"{"success":false,"error":{"code":500}}"#.utf8) }
        let model = try await model()
        for target in [try post(2,thread:1),try post(type:"system"),try post(channel:94)] {
            XCTAssertFalse(model.canPin(target));let result = await model.setPinned(target,enabled:true);XCTAssertFalse(result)
        }
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Locked","type":"private","encrypted":true,"unread":0}"#.utf8))]
        let locked = try post();XCTAssertFalse(model.canPin(locked));let denied = await model.setPinned(locked,enabled:true);XCTAssertFalse(denied);XCTAssertEqual(requests,0)
        let unencrypted = try await self.model();let target = try post();unencrypted.posts = [target]
        let failure = await unencrypted.setPinned(target,enabled:true);XCTAssertFalse(failure);XCTAssertFalse(unencrypted.posts[0].isPinned);XCTAssertNotNil(unencrypted.error);XCTAssertTrue(unencrypted.pendingMessageActions.isEmpty)
        PinStub.handler = { fields in
            if fields["method"] == "pin" { return Data(#"{"success":true}"#.utf8) }
            return Data(#"{"success":true,"data":{"posts":[{"post_id":1,"channel_id":93,"creator_id":10,"message":"Synthetic pin message","type":"normal","create_at":1000,"last_pin_at":0}]}}"#.utf8)
        }
        let mismatch = await unencrypted.setPinned(target,enabled:true);XCTAssertFalse(mismatch);XCTAssertFalse(unencrypted.posts[0].isPinned)
    }
    func testPinnedCollectionUsesStickyThenPinTimeAndExcludesRepliesForeignAndUnpinned() async throws {
        let store = NativeConversationLibraryStore()
        let values = [try post(1,pin:1000),try post(2,pin:999,sticky:true),try post(3,pin:2000),try post(4,pin:3000,thread:1),try post(5),try post(6,channel:94,pin:4000)]
        store.load(kind:.pins,query:"",channelID:93) { _,_,filters in
            XCTAssertEqual(filters.attribute,.pin);return ChatSearchPage(search_results:values,total:6)
        }
        await store.task?.value;XCTAssertEqual(store.posts.map(\.id),[2,3,1]);XCTAssertFalse(store.hasMore)
    }
    func testSignOutDuringPinWritePreventsOldAccountReadbackOrPublication() async throws {
        let started = expectation(description:"Pin write held");PinStub.hold = true
        PinStub.handler = { fields in XCTAssertEqual(fields["method"],"pin");started.fulfill();return Data(#"{"success":true}"#.utf8) }
        let model = try await model();let target = try post();model.posts = [target]
        let task = Task { await model.setPinned(target,enabled:true) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();PinStub.held?.finish(Data(#"{"success":true}"#.utf8))
        let result = await task.value;XCTAssertFalse(result);XCTAssertTrue(model.posts.isEmpty);XCTAssertNil(model.error)
    }
    private func stickyBody(_ sticky: Bool, pin: Int = 2000) throws -> Data {
        try JSONSerialization.data(withJSONObject:["success":true,"data":["posts":[["post_id":1,"channel_id":93,"creator_id":10,"message":"Synthetic pin message","type":"normal","create_at":1000,"last_pin_at":pin,"is_sticky":sticky,"thread_id":pin > 0 ? 1 : 0]]]])
    }
    func testStickyTransportAndEverySortUseObservedV5Contract() async throws {
        var methods:[String] = []
        PinStub.handler = { fields in
            methods.append(fields["method"]!);XCTAssertEqual(fields["version"],"5")
            if fields["method"] == "search" {
                let sort = try XCTUnwrap(fields["sort_by"])
                XCTAssertEqual(fields["sort_by_array"],"[\"is_sticky\",\(sort)]")
                XCTAssertEqual(fields["has"],#"["pin"]"#);XCTAssertEqual(fields["in"],"[93]")
                return Data(#"{"success":true,"data":{"search_results":[],"total":0}}"#.utf8)
            }
            XCTAssertEqual(fields["post_id"],"1");XCTAssertNil(fields["is_sticky"]);return Data(#"{"success":true}"#.utf8)
        }
        let api = try await api();try await api.setPinSticky(postID:1,enabled:true);try await api.setPinSticky(postID:1,enabled:false)
        for sort in ChatPinSort.allCases { _ = try await api.pinnedMessages(channelID:93,query:"",offset:0,sort:sort) }
        do { try await api.setPinSticky(postID:0,enabled:true);XCTFail() } catch { }
        XCTAssertEqual(methods,["stick","unstick","search","search","search"])
    }
    func testStickyRoundTripConfirmsPinAndBodyBeforePublishing() async throws {
        var sticky = false;var writes = 0
        PinStub.handler = { fields in
            if fields["method"] == "list" { XCTAssertNil(fields["thread_id"]);return try self.stickyBody(sticky) }
            writes += 1;sticky = fields["method"] == "stick";return Data(#"{"success":true}"#.utf8)
        }
        let model = try await model();let target = try post(pin:2000);model.posts = [target]
        let set = await model.setPinSticky(target,enabled:true);XCTAssertTrue(set)
        XCTAssertEqual(model.posts.first?.is_sticky,true);XCTAssertEqual(model.posts.first?.message,target.message)
        let unset = await model.setPinSticky(model.posts[0],enabled:false);XCTAssertTrue(unset)
        XCTAssertEqual(model.posts.first?.is_sticky,false);XCTAssertEqual(model.posts.first?.last_pin_at,2000)
        XCTAssertEqual(writes,2);XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testStickyAlreadyDesiredDoesNotReplayAndRepinnedSourceConflicts() async throws {
        var pin = 2000;var writes = 0
        PinStub.handler = { fields in
            if fields["method"] == "list" { return try self.stickyBody(true,pin:pin) }
            writes += 1;return Data(#"{"success":true}"#.utf8)
        }
        let model = try await model();let target = try post(pin:2000);model.posts = [target]
        let noWrite = await model.setPinSticky(target,enabled:true);XCTAssertTrue(noWrite);XCTAssertEqual(writes,0)
        pin = 3000
        let conflict = await model.setPinSticky(model.posts[0],enabled:false);XCTAssertFalse(conflict);XCTAssertEqual(writes,0)
        XCTAssertTrue(model.pinStateNeedsRefresh.isEmpty)
    }
    func testLostStickyReplyBlocksAllPinWritesUntilExplicitVerification() async throws {
        var sticky = false;var lose = true;var writes = 0
        PinStub.handler = { fields in
            if fields["method"] == "list" { return try self.stickyBody(sticky) }
            writes += 1;sticky = fields["method"] == "stick"
            if lose { throw URLError(.networkConnectionLost) }
            return Data(#"{"success":true}"#.utf8)
        }
        let model = try await model();let target = try post(pin:2000);model.posts = [target]
        let uncertain = await model.setPinSticky(target,enabled:true);XCTAssertFalse(uncertain)
        XCTAssertTrue(model.pinStateNeedsRefresh.contains(1));XCTAssertFalse(model.canPin(target));XCTAssertFalse(model.canKeepPinOnTop(target))
        let blocked = await model.setPinSticky(target,enabled:true);XCTAssertFalse(blocked);XCTAssertEqual(writes,1)
        let verified = await model.refreshPinState(target);XCTAssertTrue(verified);XCTAssertTrue(model.pinStateNeedsRefresh.isEmpty);XCTAssertNil(model.error)
        XCTAssertEqual(model.posts.first?.is_sticky,true)
        lose = false;let restored = await model.setPinSticky(model.posts[0],enabled:false);XCTAssertTrue(restored);XCTAssertEqual(writes,2)
    }
    func testStickyRejectsUnpinnedRepliesAndSystemMessages() async throws {
        var writes = 0;PinStub.handler = { _ in writes += 1;return Data(#"{"success":true}"#.utf8) }
        let model = try await model()
        for value in [try post(),try post(pin:2000,thread:2),try post(pin:2000,type:"system")] {
            XCTAssertFalse(model.canKeepPinOnTop(value));let result = await model.setPinSticky(value,enabled:true);XCTAssertFalse(result)
        }
        XCTAssertEqual(writes,0)
    }
    func testSignOutDuringStickyDispatchDropsReceiptAndRefreshMarkers() async throws {
        let started = expectation(description:"Sticky write held")
        PinStub.handler = { fields in
            if fields["method"] == "list" { PinStub.hold = true;return try self.stickyBody(false) }
            XCTAssertEqual(fields["method"],"stick");started.fulfill();return Data(#"{"success":true}"#.utf8)
        }
        let model = try await model();let target = try post(pin:2000);model.posts = [target]
        let operation = Task { await model.setPinSticky(target,enabled:true) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();PinStub.held?.finish(Data(#"{"success":true}"#.utf8))
        let result = await operation.value;XCTAssertFalse(result);XCTAssertTrue(model.posts.isEmpty);XCTAssertTrue(model.pinStateNeedsRefresh.isEmpty)
    }
    func testAllSortsKeepStickyFirstAndUseTheirOwnTimestamp() throws {
        func value(_ id:Int,create:Int,pin:Int,reply:Int,sticky:Bool = false) throws -> ChatPost {
            try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":id,"channel_id":93,"creator_id":10,"message":"Synthetic","type":"normal","create_at":create,"last_pin_at":pin,"last_comment_at":reply,"is_sticky":sticky]))
        }
        let values = [try value(1,create:300,pin:100,reply:200),try value(2,create:100,pin:300,reply:100),try value(3,create:200,pin:200,reply:300),try value(4,create:0,pin:0,reply:0,sticky:true)]
        XCTAssertEqual(values.sorted(by:ChatPinSort.pinned.precedes).map(\.id),[4,2,3,1])
        XCTAssertEqual(values.sorted(by:ChatPinSort.activity.precedes).map(\.id),[4,3,1,2])
        XCTAssertEqual(values.sorted(by:ChatPinSort.message.precedes).map(\.id),[4,1,3,2])
    }
    func testReplySortWithMissingOrZeroTimestampPreservesBackendOrderAcrossPages() async throws {
        let values = [try post(1,pin:1000),try post(3,pin:2000),try post(2,pin:3000),try post(4,pin:4000,sticky:true)]
        XCTAssertEqual(ChatPinSort.activity.ordered(values).map(\.id),[4,1,3,2])
        let zeroValues = try [5,6].map { id in
            try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":id,"channel_id":93,"creator_id":10,"message":"Synthetic","type":"normal","create_at":1000,"last_pin_at":2000,"last_comment_at":0]))
        }
        XCTAssertEqual(ChatPinSort.activity.ordered(zeroValues).map(\.id),[5,6])
        let store = NativeConversationLibraryStore()
        let first = try (1...25).map { try post($0,pin:1000) }
        store.load(kind:.pins,query:"",channelID:93,pinSort:.activity) { _,_,_ in .init(search_results:first,total:27) }
        await store.task?.value
        XCTAssertEqual(store.posts.map(\.id),first.map(\.id));XCTAssertTrue(store.hasMore)
        store.load(kind:.pins,query:"",channelID:93,more:true,pinSort:.activity) { _,offset,_ in
            XCTAssertEqual(offset,25);return .init(search_results:[try self.post(27,pin:1000),try self.post(26,pin:1000)],total:27)
        }
        await store.task?.value
        XCTAssertEqual(store.posts.map(\.id),first.map(\.id)+[27,26]);XCTAssertFalse(store.hasMore)
    }
    func testChangedSortCancelsOldLibraryResult() async throws {
        let store = NativeConversationLibraryStore();var resume:CheckedContinuation<ChatSearchPage,Never>?
        store.load(kind:.pins,query:"",channelID:93,pinSort:.activity) { _,_,_ in await withCheckedContinuation { resume = $0 } }
        while resume == nil { await Task.yield() };let old = store.task
        let newest = try post(2,pin:2000)
        store.load(kind:.pins,query:"",channelID:93,pinSort:.message) { _,_,_ in .init(search_results:[newest],total:1) }
        await store.task?.value;resume?.resume(returning:.init(search_results:[try post(1,pin:3000)],total:1));await old?.value
        XCTAssertEqual(store.posts.map(\.id),[2])
    }

}

private final class PinStub:URLProtocol {
    static var handler:(([String:String]) throws -> Data)?
    static var hold = false
    static var held:PinStub?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8));return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };data.append(contentsOf:buffer.prefix(count)) }
        }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        do {
            if Self.hold { Self.held = self;_ = try Self.handler?(fields);return }
            finish(try Self.handler?(fields) ?? Data(#"{"success":true}"#.utf8))
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    func finish(_ data:Data) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
