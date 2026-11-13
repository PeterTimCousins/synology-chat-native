import XCTest
@testable import SynologyChatNative

@MainActor final class ChatBookmarkTests: XCTestCase {
    private func post(_ id:Int = 1, channel:Int = 93, starred:Bool = false, starAt:Int = 0, thread:Int = 0) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:[
            "post_id":id,"channel_id":channel,"creator_id":10,"message":"Synthetic saved message","type":"normal",
            "create_at":1000,"is_star":starred,"star_at":starAt,"thread_id":thread]))
    }
    private func api() async throws -> ChatAPIClient {
        let configuration = URLSessionConfiguration.ephemeral;configuration.protocolClasses = [BookmarkStub.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:configuration))
        try await api.discover();return api
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:try await api(),restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 93;model.connected = true;model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func tearDown() { BookmarkStub.handler = nil;BookmarkStub.held = nil;BookmarkStub.holdWrites = false;super.tearDown() }
    func testAPIUsesPersonalStarUnstarV5AndRejectsInvalidIDs() async throws {
        var methods:[String] = []
        BookmarkStub.handler = { fields in
            XCTAssertEqual(fields["version"],"5");XCTAssertEqual(fields["post_id"],"123")
            XCTAssertNil(fields["channel_id"]);XCTAssertNil(fields["is_star"])
            methods.append(fields["method"]!);return Data(#"{"success":true}"#.utf8)
        }
        let api = try await api()
        try await api.setBookmark(postID:123,enabled:true);try await api.setBookmark(postID:123,enabled:false)
        do { try await api.setBookmark(postID:0,enabled:true);XCTFail("Invalid ID sent") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(methods,["star","unstar"])
    }
    func testModelPublishesReadbackInMainAndThreadWithoutChangingMessage() async throws {
        var enabled = false
        BookmarkStub.handler = { fields in
            switch fields["method"] {
            case "star":enabled = true
            case "unstar":enabled = false
            case "list":
                let id = Int(fields["post_id"]!)!
                return try JSONSerialization.data(withJSONObject:["success":true,"data":["posts":[[
                    "post_id":id,"channel_id":93,"creator_id":10,"message":"Synthetic saved message","type":"normal",
                    "create_at":1000,"is_star":enabled,"star_at":enabled ? 2000 : 0,"thread_id":id == 2 ? 1 : 0]]]])
            default:XCTFail("Unexpected method")
            }
            return Data(#"{"success":true}"#.utf8)
        }
        let model = try await model();let root = try post();let reply = try post(2,thread:1)
        model.posts = [root];model.threadRoot = root;model.replies = [reply]
        let saved = await model.setBookmark(root,enabled:true);XCTAssertTrue(saved)
        XCTAssertEqual(model.posts.first?.is_star,true);XCTAssertEqual(model.threadRoot?.is_star,true)
        let savedReply = await model.setBookmark(reply,enabled:true);XCTAssertTrue(savedReply)
        XCTAssertEqual(model.replies.first?.is_star,true);XCTAssertEqual(model.replies.first?.thread_id,1)
        let removed = await model.setBookmark(model.posts[0],enabled:false);XCTAssertTrue(removed)
        XCTAssertEqual(model.posts.first?.is_star,false);XCTAssertEqual(model.posts.first?.message,root.message)
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testFailureAndMismatchedReadbackDoNotOptimisticallyChangeBookmark() async throws {
        for failWrite in [true,false] {
            BookmarkStub.handler = { fields in
                if fields["method"] == "star" { return Data((failWrite ? #"{"success":false,"error":{"code":500}}"# : #"{"success":true}"#).utf8) }
                return Data(#"{"success":true,"data":{"posts":[{"post_id":1,"channel_id":93,"creator_id":10,"message":"Synthetic saved message","type":"normal","create_at":1000,"is_star":false}]}}"#.utf8)
            }
            let model = try await model();let target = try post();model.posts = [target]
            let result = await model.setBookmark(target,enabled:true)
            XCTAssertFalse(result);XCTAssertEqual(model.posts.first?.is_star,false)
            XCTAssertNotNil(model.error);XCTAssertTrue(model.pendingMessageActions.isEmpty)
        }
    }
    func testSignOutWhileWriteIsInFlightCannotPublishOrReadUsingOldAccount() async throws {
        let started = expectation(description:"Write held")
        BookmarkStub.holdWrites = true
        BookmarkStub.handler = { fields in
            XCTAssertEqual(fields["method"],"star");started.fulfill();return Data(#"{"success":true}"#.utf8)
        }
        let model = try await model();let target = try post();model.posts = [target]
        let task = Task { await model.setBookmark(target,enabled:true) }
        await fulfillment(of:[started],timeout:2)
        model.signOutLocally();BookmarkStub.held?.finish(Data(#"{"success":true}"#.utf8))
        let result = await task.value
        XCTAssertFalse(result);XCTAssertTrue(model.posts.isEmpty);XCTAssertNil(model.error)
    }
    func testSavedCollectionSpansConversationsFiltersUnstarredAndSortsBySaveTime() async throws {
        let store = NativeConversationLibraryStore()
        let values = [try post(1,starred:true,starAt:3000),try post(2,channel:94,starred:true,starAt:4000),try post(3,starred:true,starAt:4000),try post(4)]
        store.load(kind:.bookmarks,query:"",channelID:nil) { _,_,filters in
            XCTAssertEqual(filters.attribute,.star)
            return ChatSearchPage(search_results:values,total:4)
        }
        await store.task?.value
        XCTAssertEqual(store.posts.map(\.id),[3,2,1]);XCTAssertFalse(store.hasMore)
    }
}

private final class BookmarkStub: URLProtocol {
    static var handler: (([String:String]) throws -> Data)?
    static var holdWrites = false
    static var held: BookmarkStub?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") {
            finish(Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8));return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };data.append(contentsOf:buffer.prefix(count)) }
        }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        do {
            if Self.holdWrites && fields["method"] == "star" { Self.held = self;_ = try Self.handler?(fields);return }
            finish(try Self.handler?(fields) ?? Data(#"{"success":true}"#.utf8))
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    func finish(_ data:Data) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
