import XCTest
@testable import SynologyChatNative

@MainActor final class ChatTimelineHistoryTests:XCTestCase {
    private func row(_ id:Int64,channel:Int64 = 93,message:String = "Synthetic",updated:Int64 = 0) -> [String:Any] {
        ["post_id":id,"channel_id":channel,"creator_id":10,"message":message,"type":"normal","thread_id":0,"create_at":id,"update_at":updated]
    }
    private func page(_ ids:[Int64],channel:Int64 = 93) -> Data { response(ids.map { row($0,channel:channel) }) }
    private func response(_ rows:[[String:Any]]) -> Data { try! JSONSerialization.data(withJSONObject:["success":true,"data":["posts":rows]]) }
    private func model() async throws -> NativeChatPreviewModel {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [TimelineHistoryProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.test")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false)
        model.channels = try [93,94].map { id in
            try JSONDecoder().decode(ChatChannel.self,from:Data("{\"channel_id\":\(id),\"name\":\"Synthetic\",\"type\":\"anonymous\",\"encrypted\":false,\"unread\":0}".utf8))
        }
        model.selection = 93;model.connected = true;model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally();TimelineHistoryProtocol.route = nil }
        return model
    }
    private func openContext(_ model:NativeChatPreviewModel,anchor:Int64 = 100,ids:[Int64]) async {
        TimelineHistoryProtocol.route = { request,_ in request.respond(self.page(ids)) }
        model.navigateToMessage(channelID:93,postID:anchor);await model.historyTask?.value
    }
    func testRecentContextUsesStrictPrecedingCountAndOlderPageIgnoresInclusiveBoundary() async throws {
        let model = try await model();await openContext(model,ids:Array(85...100))
        XCTAssertTrue(model.canLoadOlder,"Fifteen preceding posts are a full older context side even with no following posts")
        XCTAssertTrue(model.canLoadNewer,"Context alone cannot establish the current latest boundary")
        var fields:[String:String] = [:]
        TimelineHistoryProtocol.route = { request,parameters in fields = parameters;request.respond(self.page(Array(55...85))) }
        await model.loadOlder()
        XCTAssertEqual(fields["post_id"],"85");XCTAssertEqual(fields["prev_count"],"30");XCTAssertEqual(fields["next_count"],"0")
        XCTAssertEqual(model.posts.map(\.id),Array(55...100));XCTAssertTrue(model.canLoadOlder)
        TimelineHistoryProtocol.route = { request,_ in request.respond(self.page([54,55])) }
        await model.loadOlder();XCTAssertEqual(model.posts.first?.id,54);XCTAssertFalse(model.canLoadOlder)
    }
    func testNewerPagesUseStrictCursorDeduplicateAndRemainReceiptConservativeAtExhaustion() async throws {
        let model = try await model();await openContext(model,ids:Array(85...100))
        var requests:[[String:String]] = []
        TimelineHistoryProtocol.route = { request,fields in
            requests.append(fields)
            request.respond(self.page(requests.count == 1 ? Array(100...130)+[130] : [130,131]))
        }
        await model.loadNewer()
        XCTAssertEqual(model.posts.map(\.id),Array(85...130));XCTAssertTrue(model.canLoadNewer)
        await model.loadNewer();XCTAssertEqual(model.posts.map(\.id),Array(85...131));XCTAssertFalse(model.canLoadNewer)
        XCTAssertEqual(requests.map{$0["post_id"]},["100","130"])
        XCTAssertTrue(requests.allSatisfy{$0["prev_count"] == "0" && $0["next_count"] == "30" && $0["version"] == "5"})
        XCTAssertTrue(model.viewingMessageContext)
        await model.loadNewer();XCTAssertEqual(requests.count,2)
        TimelineHistoryProtocol.route = { request,_ in request.respond(self.page(Array(102...131))) }
        model.loadSelection();await model.historyTask?.value
        XCTAssertFalse(model.viewingMessageContext);XCTAssertFalse(model.canLoadNewer)
    }
    func testBoundaryOnlyNewerPageExhaustsWithoutRepeatingOrDroppingPosts() async throws {
        let model = try await model();await openContext(model,ids:[99,100])
        TimelineHistoryProtocol.route = { request,_ in request.respond(self.page([100,100])) }
        await model.loadNewer()
        XCTAssertEqual(model.posts.map(\.id),[99,100]);XCTAssertFalse(model.canLoadNewer);XCTAssertTrue(model.viewingMessageContext)
    }
    func testExplicitBackToLatestPublishesBottomIntentWithoutPinningFutureScrollToAnOldPost() async throws {
        let model = try await model();await openContext(model,ids:Array(85...115))
        model.draft = "Unsent exact latest-return draft 😀"
        let initial = model.latestHistoryScrollRevision
        TimelineHistoryProtocol.route = { request,_ in request.respond(self.page(Array(130...159))) }
        model.loadSelection(returningToLatest:true);await model.historyTask?.value
        XCTAssertNotEqual(model.latestHistoryScrollRevision,initial)
        XCTAssertFalse(model.viewingMessageContext);XCTAssertNil(model.scrollPostID)
        XCTAssertEqual(model.posts.last?.id,159);XCTAssertEqual(model.draft,"Unsent exact latest-return draft 😀")
        let explicit = model.latestHistoryScrollRevision
        model.loadSelection();await model.historyTask?.value
        XCTAssertEqual(model.latestHistoryScrollRevision,explicit,"A background refresh must not manufacture another explicit latest jump")
    }
    func testReconnectRetainsReaderTicketAndInputWithoutPublishingNavigation() async throws {
        let model = try await model();await openContext(model,ids:Array(85...115))
        model.draft = "Unsent exact Unicode 😀"
        let oldToken = model.historyViewportToken
        let oldNavigation = model.scrollPostID,oldLatestIntent = model.latestHistoryScrollRevision
        model.noteTimelineViewport(postID:92,atBottom:false,token:oldToken,account:model.accountGeneration,channelID:93)
        var anchor:String?
        TimelineHistoryProtocol.route = { request,fields in
            anchor = fields["post_id"]
            let center = Int64(anchor ?? "") ?? 92
            request.respond(self.page(Array((center-15)...(center+15))))
        }
        model.loadSelection(preservingThread:true,preservingViewport:true)
        model.noteTimelineViewport(postID:107,atBottom:false,token:UUID(),account:model.accountGeneration,channelID:93)
        model.noteTimelineViewport(postID:100,atBottom:false,token:oldToken,account:model.accountGeneration,channelID:93)
        await model.historyTask?.value
        XCTAssertEqual(anchor,"92");XCTAssertEqual(model.scrollPostID,oldNavigation);XCTAssertEqual(model.latestHistoryScrollRevision,oldLatestIntent)
        XCTAssertEqual(model.historyViewportToken,oldToken);XCTAssertTrue(model.viewingMessageContext)
        XCTAssertEqual(model.draft,"Unsent exact Unicode 😀")
        model.loadSelection(preservingThread:true,preservingViewport:true);await model.historyTask?.value
        XCTAssertEqual(anchor,"100","The retained reader accepts input made while the previous read was pending; a foreign ticket is rejected")
        XCTAssertNil(model.error)
    }
    func testLatestReaderStaysLatestDuringBottomOrOlderReaderRecovery() async throws {
        let model = try await model()
        TimelineHistoryProtocol.route = { request,_ in request.respond(self.page(Array(71...100))) }
        model.loadSelection();await model.historyTask?.value
        model.noteTimelineViewport(postID:95,atBottom:true,token:model.historyViewportToken,account:model.accountGeneration,channelID:93)
        var anchor:String?
        TimelineHistoryProtocol.route = { request,fields in
            if fields["post_id"] != nil { anchor = fields["post_id"];request.respond(self.page(Array(65...95))) }
            else { request.respond(self.page(Array(71...100))) }
        }
        model.loadSelection(preservingViewport:true);await model.historyTask?.value
        XCTAssertNil(anchor);XCTAssertFalse(model.viewingMessageContext)
        model.noteTimelineViewport(postID:80,atBottom:false,token:model.historyViewportToken,account:model.accountGeneration,channelID:93)
        model.loadSelection(preservingViewport:true);await model.historyTask?.value
        XCTAssertEqual(anchor,"80");XCTAssertFalse(model.viewingMessageContext);XCTAssertNil(model.error)
    }
    func testLateNewerPageCannotPublishAfterChannelOrAccountChanges() async throws {
        for signOut in [false,true] {
            let model = try await model();await openContext(model,ids:[99,100])
            let began = expectation(description:"Page held")
            var held:TimelineHistoryProtocol?
            TimelineHistoryProtocol.route = { request,_ in held = request;began.fulfill() }
            let pending = Task { await model.loadNewer() };await fulfillment(of:[began],timeout:2)
            if signOut { model.signOutLocally() }
            else { model.selection = 94;model.posts = [] }
            held?.respond(page([100,101]));await pending.value
            XCTAssertTrue(model.posts.isEmpty);XCTAssertNil(model.error)
        }
    }
    func testPagingPreservesScrollMadeWhileEitherDirectionalRequestIsHeld() async throws {
        for newer in [false,true] {
            let model = try await model();await openContext(model,ids:Array(85...100))
            model.draft = "Keep the unsent draft"
            model.noteTimelineViewport(postID:90,atBottom:false,token:model.historyViewportToken,account:model.accountGeneration,channelID:93)
            let began = expectation(description:"Directional page held")
            var held:TimelineHistoryProtocol?
            TimelineHistoryProtocol.route = { request,_ in held = request;began.fulfill() }
            let pending = Task { if newer { await model.loadNewer() } else { await model.loadOlder() } }
            await fulfillment(of:[began],timeout:2)
            model.noteTimelineViewport(postID:97,atBottom:false,token:model.historyViewportToken,account:model.accountGeneration,channelID:93)
            held?.respond(page(newer ? Array(100...130) : Array(55...85)));await pending.value
            XCTAssertEqual(model.scrollPostID,97,"Completing the page must not undo input made while waiting")
            XCTAssertTrue(model.scrollAnchorAtTop);XCTAssertTrue(model.viewingMessageContext)
            XCTAssertEqual(model.draft,"Keep the unsent draft")
        }
    }
    func testWrongChannelPageIsRejectedWithoutChangingCurrentContext() async throws {
        let model = try await model();await openContext(model,ids:[99,100])
        TimelineHistoryProtocol.route = { request,_ in request.respond(self.page([100,101],channel:94)) }
        await model.loadNewer()
        XCTAssertEqual(model.posts.map(\.id),[99,100]);XCTAssertNotNil(model.error);XCTAssertTrue(model.canLoadNewer)
    }
    func testLiveEditsAndDeletionWinOverInFlightNewerSnapshot() async throws {
        let model = try await model();await openContext(model,ids:[99,100])
        let began = expectation(description:"Page held")
        var held:TimelineHistoryProtocol?
        TimelineHistoryProtocol.route = { request,fields in
            if fields["next_count"] == "30" { held = request;began.fulfill() }
            else { request.respond(self.response([self.row(101,message:"Canonical edit",updated:200)])) }
        }
        let pending = Task { await model.loadNewer() };await fulfillment(of:[began],timeout:2)
        model.handleLiveEvent(.init(name:"client.post.update",payload:.object(["channel_id":.integer(93),"post_id":.integer(101)])))
        for task in Array(model.eventTasks.values) { await task.value }
        model.handleLiveEvent(.init(name:"client.post.delete",payload:.object(["channel_id":.integer(93),"post_id":.integer(102)])))
        held?.respond(response([row(100),row(101,message:"Old snapshot"),row(102)]));await pending.value
        XCTAssertEqual(model.posts.map(\.id),[99,100,101]);XCTAssertEqual(model.posts.last?.message,"Canonical edit")
    }

    func testThreadContextRefreshKeepsConcurrentCanonicalEditAndDeletionButExcludesUnrelatedNewReply() async throws {
        let model = try await model()
        let root = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:row(1)))
        func reply(_ id:Int64,message:String = "Synthetic snapshot") -> [String:Any] {
            var value = row(id,message:message);value["thread_id"] = 1;return value
        }
        TimelineHistoryProtocol.route = { request,_ in request.respond(self.response((46...75).map { reply(Int64($0)) })) }
        await model.openThread(root,around:60)
        let began = expectation(description:"Context window held")
        var held:TimelineHistoryProtocol?
        TimelineHistoryProtocol.route = { request,fields in
            if fields["prev_count"] == "15" { held = request;began.fulfill() }
            else if fields["post_id"] == "60" { request.respond(self.response([reply(60,message:"New canonical edit")])) }
            else if fields["post_id"] == "999" { request.respond(self.response([reply(999,message:"Unrelated newest reply")])) }
            else { request.respond(self.response([self.row(1)])) }
        }
        let pending = Task { await model.refreshOpenThreadPreservingReader() }
        await fulfillment(of:[began],timeout:2)
        for id:Int64 in [60,999] {
            model.handleLiveEvent(.init(name:"client.post.update",payload:.object(["channel_id":.integer(93),"post_id":.integer(id),"thread_id":.integer(1)])))
            for task in Array(model.eventTasks.values) { await task.value }
        }
        model.handleLiveEvent(.init(name:"client.post.delete",payload:.object(["channel_id":.integer(93),"post_id":.integer(61),"thread_id":.integer(1)])))
        held?.respond(response((55...65).filter { $0 != 60 }.map { reply(Int64($0)) }));await pending.value
        XCTAssertEqual(model.replies.map(\.id),Array(46...75).filter { $0 != 61 })
        XCTAssertEqual(model.replies.first(where:{ $0.id == 60 })?.message,"New canonical edit")
        XCTAssertFalse(model.replies.contains(where:{ $0.id == 999 }));XCTAssertTrue(model.threadViewingContext)
    }
    func testForwardReplyPageKeepsCanonicalEditAndConfirmedDeletionOverHeldSnapshot() async throws {
        let model = try await model()
        let root = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:row(1)))
        func reply(_ id:Int64,message:String = "Synthetic stale reply")->[String:Any] {
            var value = row(id,message:message);value["thread_id"] = 1;return value
        }
        TimelineHistoryProtocol.route = { request,_ in request.respond(self.response([reply(89),reply(90)])) }
        await model.openThread(root,around:90)
        let began = expectation(description:"Forward reply page held"),token = model.nativeThreadViewportToken
        var held:TimelineHistoryProtocol?
        TimelineHistoryProtocol.route = { request,fields in
            if fields["next_count"] == "30" { held = request;began.fulfill() }
            else if fields["post_id"] == "91" { request.respond(self.response([reply(91,message:"Canonical later edit")])) }
            else { request.respond(self.response([self.row(1)])) }
        }
        let pending = Task { await model.loadNewerReplies() };await fulfillment(of:[began],timeout:2)
        model.handleLiveEvent(.init(name:"client.post.update",payload:.object(["channel_id":.integer(93),"post_id":.integer(91),"thread_id":.integer(1)])))
        for task in Array(model.eventTasks.values) { await task.value }
        model.handleLiveEvent(.init(name:"client.post.delete",payload:.object(["channel_id":.integer(93),"post_id":.integer(92),"thread_id":.integer(1)])))
        held?.respond(response([reply(90),reply(91),reply(92)]));await pending.value
        XCTAssertEqual(model.replies.map(\.id),[89,90,91]);XCTAssertEqual(model.replies.last?.message,"Canonical later edit")
        XCTAssertEqual(model.nativeThreadViewportToken,token);XCTAssertTrue(model.threadViewingContext)
        XCTAssertFalse(model.canLoadNewerReplies);XCTAssertFalse(model.loadingThread)
    }
}

private final class TimelineHistoryProtocol:URLProtocol {
    static var route:((TimelineHistoryProtocol,[String:String])->Void)?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" {
            respond(Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8));return
        }
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream,data.isEmpty {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };data.append(contentsOf:buffer.prefix(count)) }
        }
        var components = URLComponents();components.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((components.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{$1})
        Self.route?(self,fields)
    }
    func respond(_ data:Data) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
