import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatImageHistoryTests: XCTestCase {
    private func row(_ id:Int,channel:Int = 93,thread:Int = 0,image:Bool = true,deleted:Bool = false) -> [String:Any] {
        ["post_id":id,"channel_id":channel,"creator_id":10,"message":"Synthetic gallery image","type":"file","create_at":id,"thread_id":thread,"delete_at":deleted ? 1 : 0,"file_props":["name":"synthetic.png","is_image":image,"size":10]]
    }
    private func post(_ id:Int,thread:Int = 0) throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:row(id,thread:thread))) }
    private func page(_ rows:[[String:Any]]) -> Data { try! JSONSerialization.data(withJSONObject:["success":true,"data":["posts":rows]]) }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [GalleryProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.test")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config),makeAttachmentNetwork:{ URLSession(configuration:config) })
        try await api.discover();return api
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:try await api(),restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Synthetic","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 93;model.connected = true;model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func setUp() {
        super.setUp();GalleryProtocol.history = nil
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        GalleryProtocol.png = bitmap.representation(using:.png,properties:[:])!
    }
    override func tearDown() { GalleryProtocol.history = nil;super.tearDown() }

    func testImageOnlyPageRejectsOtherChannelsThreadsNonimagesDeletedAndAmbiguousAnchors() throws {
        let valid = try [1,2,3].map { try post($0) }
        let result = try ChatImageHistoryPage(posts:valid.reversed(),channelID:93,anchorID:2,threadID:nil,direction:.around)
        XCTAssertEqual(result.posts.map(\.id),[1,2,3]);XCTAssertFalse(result.hasOlder);XCTAssertFalse(result.hasNewer)
        let invalid = [row(1,channel:94),row(1,thread:9),row(1,image:false),row(1,deleted:true)]
        for value in invalid {
            let bad = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:value))
            XCTAssertThrowsError(try ChatImageHistoryPage(posts:[bad,valid[1]],channelID:93,anchorID:2,threadID:nil,direction:.around))
        }
        for values in [[valid[0]],[valid[1],valid[1]]] {
            XCTAssertThrowsError(try ChatImageHistoryPage(posts:values,channelID:93,anchorID:2,threadID:nil,direction:.around))
        }
        XCTAssertThrowsError(try ChatImageHistoryPage(posts:valid,channelID:93,anchorID:2,threadID:nil,direction:.older))
    }
    func testTransportMatchesOfficialAnchoredImageFilterAndDirectionalCounts() async throws {
        let api = try await api();var requests:[[String:String]] = []
        GalleryProtocol.history = { request,fields in requests.append(fields);request.respond(self.page([self.row(100,thread:9)])) }
        for direction in [ChatImageHistoryDirection.around,.older,.newer] { _ = try await api.imageHistory(channelID:93,anchorID:100,threadID:9,direction:direction) }
        XCTAssertEqual(requests.map{$0["prev_count"]},["50","50","0"]);XCTAssertEqual(requests.map{$0["next_count"]},["50","0","50"])
        for request in requests {
            XCTAssertEqual(request["thread_id"],"9");XCTAssertEqual(request["post_id"],"100");XCTAssertEqual(request["version"],"5")
            XCTAssertEqual(try JSONDecoder().decode([String].self,from:Data(request["file_type"]!.utf8)),["image"])
        }
    }
    func testRemoteImagesExtendGalleryWithoutChangingTimelineOrSelectedImage() async throws {
        GalleryProtocol.history = { request,_ in request.respond(self.page([self.row(1),self.row(50),self.row(100)])) }
        let model = try await model(),current = try post(100);model.posts = [current]
        model.openImage(current);await model.imageHistoryTask?.value;await model.imageViewerTask?.value
        XCTAssertEqual(model.imageViewerCount,3);XCTAssertEqual(model.imageViewerPost?.id,100);XCTAssertEqual(model.posts.map(\.id),[100])
        XCTAssertEqual(model.imageViewerPosition,3);XCTAssertTrue(model.canViewPreviousImage);XCTAssertFalse(model.canViewNextImage)
        model.moveViewerImage(by:-1);await model.imageViewerTask?.value;XCTAssertEqual(model.imageViewerPost?.id,50)
    }
    func testBothGalleryEdgesFetchAnotherPageAndAdvanceExactlyOneImage() async throws {
        for older in [true,false] {
            var anchors:[Int] = []
            GalleryProtocol.history = { request,fields in
                let anchor = Int(fields["post_id"]!)!;anchors.append(anchor)
                let ids = anchors.count == 1 ? (older ? Array(51...101) : Array(1...51)) : (older ? Array(2...51) : Array(51...100))
                request.respond(self.page(ids.map { self.row($0) }))
            }
            let model = try await model(),current = try post(older ? 101 : 1);model.posts = [current]
            model.openImage(current);await model.imageHistoryTask?.value
            for _ in 0..<50 { model.moveViewerImage(by:older ? -1 : 1) }
            XCTAssertEqual(model.imageViewerPost?.id,51)
            model.moveViewerImage(by:older ? -1 : 1);await model.imageHistoryTask?.value
            XCTAssertEqual(anchors,[older ? 101 : 1,51]);XCTAssertEqual(model.imageViewerPost?.id,older ? 50 : 52)
            XCTAssertEqual(model.imageViewerCount,100);XCTAssertEqual(model.posts.map(\.id),[current.id])
            model.closeImageViewer()
        }
    }
    func testFailedMetadataReadKeepsCurrentImageAndRetryLoadsHistory() async throws {
        GalleryProtocol.history = { request,_ in request.respond(Data(#"{"success":false,"error":{"code":500}}"#.utf8)) }
        let model = try await model(),current = try post(2);model.posts = [current]
        model.openImage(current);await model.imageHistoryTask?.value;await model.imageViewerTask?.value
        XCTAssertNotNil(model.imageHistoryError);XCTAssertNil(model.imageViewerError);XCTAssertNotNil(model.imageViewerImage);XCTAssertEqual(model.imageViewerPost?.id,2)
        GalleryProtocol.history = { request,_ in request.respond(self.page([self.row(1),self.row(2)])) }
        model.retryImageHistory();await model.imageHistoryTask?.value
        XCTAssertNil(model.imageHistoryError);XCTAssertEqual(model.imageViewerCount,2)
    }
    func testCloseAndReopenCannotReceiveHeldPreviousGalleryResponse() async throws {
        var held:GalleryProtocol?;let started = expectation(description:"History request held")
        GalleryProtocol.history = { request,_ in held = request;started.fulfill() }
        let model = try await model(),first = try post(2),second = try post(100);model.posts = [first,second]
        model.openImage(first);await fulfillment(of:[started],timeout:1);let old = model.imageHistoryTask
        model.closeImageViewer();GalleryProtocol.history = { request,_ in request.respond(self.page([self.row(100),self.row(101)])) }
        model.openImage(second);await model.imageHistoryTask?.value
        held?.respond(page([row(1),row(2)]));await old?.value
        XCTAssertEqual(model.imageViewerPost?.id,100);XCTAssertEqual(model.imageViewerCount,2);XCTAssertFalse(model.canViewPreviousImage)
    }
    func testLibraryGallerySkipsMultipleNonimagePagesUsingRawOffsets() async throws {
        let library = NativeConversationLibraryStore();var offsets:[Int] = []
        let rows = try (1...100).reversed().map { id in try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:row(id,image:id == 100 || id == 1))) }
        library.load(kind:.files,query:"synthetic",channelID:93,accountGeneration:7) { query,offset,_ in
            XCTAssertEqual(query,"synthetic");offsets.append(offset);return .init(search_results:Array(rows.dropFirst(offset).prefix(25)),total:rows.count)
        };await library.task?.value
        let model = try await model();model.posts = [try post(999)]
        model.openLibraryImage(rows[0],context:library.posts,hasMore:library.hasMore,loadMore:library.imageGalleryLoader())
        XCTAssertEqual(model.imageViewerCount,1);XCTAssertTrue(model.canViewNextImage)
        model.moveViewerImage(by:1);await model.imageHistoryTask?.value
        XCTAssertEqual(offsets,[0,25,50,75]);XCTAssertEqual(library.posts.count,100)
        XCTAssertEqual(model.imageViewerPost?.id,1);XCTAssertEqual(model.imageViewerCount,2);XCTAssertFalse(model.canViewNextImage)
        XCTAssertEqual(model.posts.map(\.id),[999])
    }
    func testLibraryPageFailureCanRetryWithoutSkippingRawRowsOrLosingCurrentImage() async throws {
        let library = NativeConversationLibraryStore();var offsets:[Int] = [];var fail = true
        let rows = try (1...31).reversed().map { id in try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:row(id,image:id == 31 || id == 1))) }
        library.load(kind:.files,query:"",channelID:93,accountGeneration:7) { _,offset,_ in
            offsets.append(offset);if offset == 25 && fail { throw URLError(.networkConnectionLost) }
            return .init(search_results:Array(rows.dropFirst(offset).prefix(25)),total:rows.count)
        };await library.task?.value
        let model = try await model();model.openLibraryImage(rows[0],context:library.posts,hasMore:library.hasMore,loadMore:library.imageGalleryLoader())
        model.moveViewerImage(by:1);await model.imageHistoryTask?.value;await model.imageViewerTask?.value
        XCTAssertNotNil(model.imageHistoryError);XCTAssertEqual(model.imageViewerPost?.id,31);XCTAssertNotNil(model.imageViewerImage)
        fail = false;model.retryImageHistory();await model.imageHistoryTask?.value
        XCTAssertEqual(offsets,[0,25,0,25]);XCTAssertNil(model.imageHistoryError);XCTAssertEqual(model.imageViewerPost?.id,1);XCTAssertEqual(library.posts.count,31)
    }
    func testLibraryGalleryKeepsResultOrderAndRejectsLateClosedViewerPage() async throws {
        let model = try await model(),first = try post(10),second = try post(20),next = try post(5)
        var resume:CheckedContinuation<ChatLibraryImagePage,Never>?;let entered = expectation(description:"Library continuation held")
        model.openLibraryImage(second,context:[first,second],hasMore:true) {
            entered.fulfill();return await withCheckedContinuation { resume = $0 }
        }
        model.moveViewerImage(by:1);await fulfillment(of:[entered],timeout:1);let old = model.imageHistoryTask
        model.closeImageViewer();model.openLibraryImage(first,context:[first,next])
        resume?.resume(returning:.init(posts:[first,second,next],hasMore:false,cursor:50));await old?.value
        XCTAssertEqual(model.imageViewerPost?.id,10);XCTAssertEqual(model.imageViewerCount,2)
        model.moveViewerImage(by:1);XCTAssertEqual(model.imageViewerPost?.id,5,"Library order must not be replaced by timeline ID ordering")
    }
    func testLibraryGalleryStopsWhenCurrentSourceDisappearsOrCursorDoesNotAdvance() async throws {
        let model = try await model(),current = try post(10)
        model.openLibraryImage(current,context:[current],hasMore:true) { .init(posts:[],hasMore:false,cursor:25) }
        model.moveViewerImage(by:1);await model.imageHistoryTask?.value;XCTAssertNil(model.imageViewerPost)
        var reads = 0
        model.openLibraryImage(current,context:[current],hasMore:true) { reads += 1;return .init(posts:[current],hasMore:true,cursor:25) }
        model.moveViewerImage(by:1);await model.imageHistoryTask?.value
        XCTAssertEqual(reads,2);XCTAssertNotNil(model.imageHistoryError);XCTAssertEqual(model.imageViewerPost?.id,10)
    }
    func testThreadRootAndLibraryStayIsolatedWhileReplyHistoryIncludesThreadID() async throws {
        var requests:[String:String] = [:];var count = 0
        GalleryProtocol.history = { request,fields in count += 1;requests = fields;request.respond(self.page([self.row(11,thread:10),self.row(12,thread:10)])) }
        let model = try await model(),root = try post(10),reply = try post(12,thread:10)
        model.posts = [root];model.threadRoot = root;model.replies = [reply]
        model.openImage(root);await model.imageHistoryTask?.value;XCTAssertEqual(count,0);XCTAssertEqual(model.imageViewerCount,1)
        model.openImage(reply);await model.imageHistoryTask?.value
        XCTAssertEqual(requests["thread_id"],"10");XCTAssertEqual(model.imageViewerCount,2);XCTAssertEqual(model.imageViewerPost?.id,12)
        model.closeImageViewer();model.threadRoot = nil
        model.openLibraryImage(root,context:[root]);await model.imageHistoryTask?.value
        XCTAssertEqual(count,1);XCTAssertEqual(model.imageViewerCount,1)
    }
    private func searchChannel(_ id:Int,overrides:[String:Any] = [:]) throws -> ChatChannel {
        var fields:[String:Any] = ["channel_id":id,"name":"Synthetic \(id)","type":"public","encrypted":false,"is_joined":true,"unread":0]
        fields.merge(overrides,uniquingKeysWith:{ _,new in new });return try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:fields))
    }
    private func searchPost(_ id:Int,channel:Int = 93,image:Bool = true,thread:Int = 0) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:row(id,channel:channel,thread:thread,image:image)))
    }
    func testSearchGalleryPreservesMixedConversationResultOrderAndUnsentDraft() async throws {
        let model = try await model(),a = try searchPost(20,channel:94),b = try searchPost(5),owner = UUID()
        model.channels.append(try searchChannel(94));model.posts = [b];model.draft = "Keep this unsent text";var historyReads = 0
        GalleryProtocol.history = { _,_ in historyReads += 1 }
        model.openSearchImage(a,context:[a,b],owner:owner);await model.imageViewerTask?.value
        XCTAssertEqual(model.searchImageOwner,owner);XCTAssertEqual(model.imageViewerPost?.channel_id,94);XCTAssertEqual(model.selection,93);XCTAssertEqual(model.imageViewerPosition,1);XCTAssertEqual(model.imageViewerCount,2)
        XCTAssertNotNil(model.imageViewerImage);XCTAssertEqual(historyReads,0)
        model.moveViewerImage(by:1);XCTAssertEqual(model.imageViewerPost?.id,5);model.moveViewerImage(by:-1);XCTAssertEqual(model.imageViewerPost?.id,20)
        XCTAssertEqual(model.draft,"Keep this unsent text");XCTAssertEqual(model.posts.map(\.id),[5])
    }
    func testSearchGalleryRejectsUnavailableSourcesAndConflictingClickedIdentity() async throws {
        let model = try await model(),a = try searchPost(1),other = try searchPost(1,channel:94),owner = UUID();model.channels.append(try searchChannel(94))
        model.openSearchImage(a,context:[a,other],owner:owner);XCTAssertNil(model.imageViewerPost)
        let nonimage = try searchPost(2,image:false);model.openSearchImage(nonimage,context:[nonimage],owner:owner);XCTAssertNil(model.imageViewerPost)
        for override in [["encrypted":true],["is_joined":false],["is_closed":true],["hide_global_at":1000]] as [[String:Any]] {
            model.channels = [try searchChannel(93,overrides:override)];model.openSearchImage(a,context:[a],owner:owner);XCTAssertNil(model.imageViewerPost)
        }
        model.channels = [try searchChannel(93)];model.signOutLocally();model.openSearchImage(a,context:[a],owner:owner);XCTAssertNil(model.imageViewerPost)
    }
    func testSearchImagePaginationSkipsMixedNonimagePagesAndKeepsRawResultOrder() async throws {
        let model = try await model(),first = try searchPost(10),next = try searchPost(8,channel:94),owner = UUID(),text = try searchPost(9,image:false)
        model.channels.append(try searchChannel(94));var calls = 0
        model.openSearchImage(first,context:[first],owner:owner,hasMore:true) {
            calls += 1
            if calls == 1 { return .init(posts:[first,text],hasMore:true,cursor:25) }
            return .init(posts:[first,text,next],hasMore:false,cursor:50)
        }
        model.moveViewerImage(by:1);await model.imageHistoryTask?.value
        XCTAssertEqual(calls,2);XCTAssertEqual(model.imageViewerPost?.id,8);XCTAssertEqual(model.imageViewerPost?.channel_id,94);XCTAssertEqual(model.imageViewerCount,2);XCTAssertFalse(model.canViewNextImage);XCTAssertEqual(model.selection,93)
    }
    func testLateSearchGalleryPageCannotReplaceNewOwnerOrReopenAfterClose() async throws {
        let model = try await model(),first = try searchPost(10),next = try searchPost(20,channel:94),newOwner = UUID();model.channels.append(try searchChannel(94))
        var resume:CheckedContinuation<ChatLibraryImagePage,Never>?;let began = expectation(description:"Search page held")
        model.openSearchImage(first,context:[first],owner:UUID(),hasMore:true) { began.fulfill();return await withCheckedContinuation { resume = $0 } }
        model.moveViewerImage(by:1);await fulfillment(of:[began],timeout:1);let old = model.imageHistoryTask
        model.closeImageViewer();model.openSearchImage(next,context:[next],owner:newOwner)
        resume?.resume(returning:.init(posts:[first,next],hasMore:false,cursor:25));await old?.value
        XCTAssertEqual(model.searchImageOwner,newOwner);XCTAssertEqual(model.imageViewerPost?.id,20);XCTAssertEqual(model.imageViewerCount,1)
    }
    func testSearchGalleryPrunesRevokedConversationsAndCannotNavigateBackToThem() async throws {
        let model = try await model(),a = try searchPost(10),b = try searchPost(20,channel:94);model.channels.append(try searchChannel(94))
        model.openSearchImage(a,context:[a,b],owner:UUID());XCTAssertEqual(model.imageViewerCount,2)
        model.channels = [try searchChannel(93),try searchChannel(94,overrides:["is_joined":false])]
        XCTAssertEqual(model.imageViewerCount,1);XCTAssertFalse(model.canViewNextImage)
        model.channels = [try searchChannel(93,overrides:["is_closed":true])]
        XCTAssertNil(model.imageViewerPost);XCTAssertNil(model.searchImageOwner)
    }
    func testSearchImageSourceJumpSelectsCorrectChannelAndOriginalThreadAnchor() async throws {
        let model = try await model(),reply = try searchPost(20,channel:94,thread:10);model.channels.append(try searchChannel(94))
        model.openSearchImage(reply,context:[reply],owner:UUID());XCTAssertEqual(model.selection,93)
        XCTAssertTrue(model.jumpFromImageViewer());XCTAssertEqual(model.selection,94);XCTAssertNil(model.imageViewerPost);XCTAssertNil(model.searchImageOwner)
        var requests:[[String:String]] = []
        GalleryProtocol.history = { request,fields in requests.append(fields);request.respond(self.page([])) }
        model.loadSelection();await model.historyTask?.value
        XCTAssertEqual(requests.first?["channel_id"],"94");XCTAssertEqual(requests.first?["post_id"],"10")
    }

}

private final class GalleryProtocol: URLProtocol {
    static var history: ((GalleryProtocol,[String:String])->Void)?
    static var png = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" {
            respond(Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"},"SYNO.Chat.Post.File":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"}}}"#.utf8));return
        }
        if request.url!.lastPathComponent == "SYNO.Chat.Post" {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream,data.isEmpty { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
            var components = URLComponents();components.percentEncodedQuery = String(decoding:data,as:UTF8.self)
            Self.history?(self,Dictionary((components.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{$1}));return
        }
        respond(Self.png,mime:"image/png")
    }
    func respond(_ data:Data,mime:String = "application/json") {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":mime])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
