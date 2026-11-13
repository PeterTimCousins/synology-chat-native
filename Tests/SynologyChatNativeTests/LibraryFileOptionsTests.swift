import XCTest
@testable import SynologyChatNative

@MainActor final class LibraryFileOptionsTests: XCTestCase {
    override func tearDown() { LibraryFileStub.handler = nil; LibraryFileStub.hold = false; LibraryFileStub.held = nil; super.tearDown() }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LibraryFileStub.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://library.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover();return api
    }
    private func post(_ id: Int, name: String? = nil, image: Bool = false, type: String = "file") throws -> ChatPost {
        var props:[String:Any] = ["is_image":image]
        if let name { props["name"] = name }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":id,"channel_id":93,"creator_id":10,"message":"Synthetic library test","type":type,"create_at":id,"file_props":props]))
    }
    private func model(_ api:ChatAPIClient) throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false)
        model.connected = true;model.liveStatus = .live;model.selection = 93
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Synthetic","type":"private","encrypted":false,"unread":0}"#.utf8))]
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    func testAllOptionCombinationsUseScopedV5FileSearchAndClearImageFilter() async throws {
        var calls:[[String:String]] = []
        LibraryFileStub.handler = { fields in calls.append(fields);return Data(#"{"success":true,"data":{"search_results":[],"total":0}}"#.utf8) }
        let api = try await api()
        for category in ChatLibraryFileOptions.Category.allCases {
            for sort in ChatLibraryFileOptions.Sort.allCases {
                _ = try await api.conversationFiles(channelID:93,query:"synthetic",offset:25,options:.init(sort:sort,category:category))
                let call = try XCTUnwrap(calls.last)
                XCTAssertEqual(call["method"],"search");XCTAssertEqual(call["version"],"5")
                XCTAssertEqual(call["in"],"[93]");XCTAssertEqual(call["post_type"],#"["file"]"#)
                XCTAssertEqual(call["file_type"],category == .images ? #"["image"]"# : "[]")
                XCTAssertEqual(call["sort_by"],"\"\(sort.rawValue)\"");XCTAssertEqual(call["offset"],"25");XCTAssertEqual(call["limit"],"25")
                XCTAssertNil(call["has"])
            }
        }
        XCTAssertEqual(calls.count,4)
        for (channel,offset) in [(Int64(0),0),(Int64(93),-1)] {
            do { _ = try await api.conversationFiles(channelID:channel,query:"",offset:offset,options:.init());XCTFail() } catch { }
        }
        XCTAssertEqual(calls.count,4)
    }
    func testNameAndNewestOrderAndEqualNameTie() throws {
        let values = [try post(1,name:"z.txt"),try post(2,name:"a.txt"),try post(3,name:"a.txt")]
        XCTAssertEqual(ChatLibraryFileOptions(sort:.newest).ordered(values).map(\.id),[3,2,1])
        XCTAssertEqual(ChatLibraryFileOptions(sort:.name).ordered(values).map(\.id),[2,3,1])
        let reverse = [try post(4,name:"a.txt"),try post(5,name:"z.txt"),try post(6,name:"b.txt")]
        XCTAssertEqual(ChatLibraryFileOptions(sort:.name).ordered(reverse).map(\.id),[4,6,5])
        XCTAssertEqual(ChatLibraryFileOptions(sort:.newest).ordered(reverse).map(\.id),[6,5,4])
    }
    func testMissingNamesPreserveServerOrderInsteadOfInventingLabels() throws {
        let values = [try post(2,name:"z.txt"),try post(1)]
        XCTAssertEqual(ChatLibraryFileOptions(sort:.name).ordered(values).map(\.id),[2,1])
    }
    func testImageCategoryRejectsUnprovenImagesAndNonFileRows() throws {
        let images = ChatLibraryFileOptions(category:.images)
        XCTAssertTrue(images.includes(try post(1,name:"a.png",image:true)))
        XCTAssertFalse(images.includes(try post(2,name:"pretend.png")))
        XCTAssertFalse(images.includes(try post(3,name:"a.png",image:true,type:"normal")))
    }
    func testFilteredPagingAdvancesByRawServerRows() async throws {
        let store = NativeConversationLibraryStore();let options = ChatLibraryFileOptions(category:.images)
        let first = try (1...25).map { try post($0,name:"synthetic-\($0)",image:$0 == 1 || $0 == 25) }
        store.load(kind:.files,query:"",channelID:93,fileOptions:options) { _,offset,_ in
            XCTAssertEqual(offset,0);return .init(search_results:first,total:26)
        }
        await store.task?.value;XCTAssertEqual(store.posts.map(\.id),[25,1]);XCTAssertTrue(store.hasMore)
        store.load(kind:.files,query:"",channelID:93,more:true,fileOptions:options) { _,offset,_ in
            XCTAssertEqual(offset,25);return .init(search_results:[try self.post(26,name:"latest.png",image:true)],total:26)
        }
        await store.task?.value;XCTAssertEqual(store.posts.map(\.id),[26,25,1]);XCTAssertFalse(store.hasMore)
    }
    func testOptionChangeCannotPublishOldUncooperativeResult() async throws {
        let store = NativeConversationLibraryStore();var resume:CheckedContinuation<ChatSearchPage,Never>?
        store.load(kind:.files,query:"",channelID:93,fileOptions:.init()) { _,_,_ in await withCheckedContinuation { resume = $0 } }
        while resume == nil { await Task.yield() };let old = store.task
        let image = try post(2,name:"current.png",image:true)
        store.load(kind:.files,query:"",channelID:93,fileOptions:.init(sort:.name,category:.images)) { _,_,_ in .init(search_results:[image],total:1) }
        await store.task?.value;resume?.resume(returning:.init(search_results:[try post(1,name:"old.txt")],total:1));await old?.value
        XCTAssertEqual(store.posts.map(\.id),[2]);XCTAssertNil(store.failure)
    }
    func testModelRejectsClosedEncryptedUnknownAndDisconnectedChannels() async throws {
        var requests = 0;LibraryFileStub.handler = { _ in requests += 1;return Data(#"{"success":true,"data":{"search_results":[]}}"#.utf8) }
        let model = try model(await api())
        for channel in [Int64(99),93] {
            if channel == 93 { model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Closed","type":"private","encrypted":false,"unread":0,"is_closed":true}"#.utf8))] }
            do { _ = try await model.conversationFiles(channelID:channel,query:"",offset:0,options:.init());XCTFail() } catch { }
        }
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Locked","type":"private","encrypted":true,"unread":0}"#.utf8))]
        do { _ = try await model.conversationFiles(channelID:93,query:"",offset:0,options:.init());XCTFail() } catch { }
        model.signOutLocally()
        do { _ = try await model.conversationFiles(channelID:93,query:"",offset:0,options:.init());XCTFail() } catch { }
        XCTAssertEqual(requests,0)
    }
    func testModelDropsFilePageAfterSignOut() async throws {
        let started = expectation(description:"File page held")
        LibraryFileStub.hold = true;LibraryFileStub.handler = { _ in started.fulfill();return Data() }
        let model = try model(await api())
        let operation = Task { try await model.conversationFiles(channelID:93,query:"",offset:0,options:.init()) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        LibraryFileStub.held?.finish(Data(#"{"success":true,"data":{"search_results":[],"total":0}}"#.utf8))
        do { _ = try await operation.value;XCTFail() } catch { }
        XCTAssertTrue(model.posts.isEmpty)
    }
}

private final class LibraryFileStub: URLProtocol {
    static var handler:(([String:String]) throws -> Data)?
    static var hold = false
    static var held:LibraryFileStub?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8));return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer {stream.close()};var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 {break};bytes.append(contentsOf:buffer.prefix(count)) }
        }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{_,last in last})
        do { let value = try Self.handler?(fields) ?? Data();if Self.hold {Self.held = self} else {finish(value)} }
        catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    func finish(_ data:Data) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
