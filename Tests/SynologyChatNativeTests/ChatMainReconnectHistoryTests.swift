import XCTest
@testable import SynologyChatNative

@MainActor final class ChatMainReconnectHistoryTests:XCTestCase {
    private func row(_ id:Int64,channel:Int64 = 93,message:String = "Synthetic",thread:Int64 = 0)->[String:Any] {
        ["post_id":id,"channel_id":channel,"creator_id":10,"type":"normal","message":message,"thread_id":thread,"create_at":id,"update_at":0]
    }
    private func response(_ values:[[String:Any]])->Data {
        try! JSONSerialization.data(withJSONObject:["success":true,"data":["posts":values]])
    }
    private func page(_ ids:[Int64],channel:Int64 = 93)->Data { response(ids.map { row($0,channel:channel) }) }
    private func channel(_ id:Int64,encrypted:Bool = false,key:String? = nil) throws -> ChatChannel {
        var fields:[String:Any] = ["channel_id":id,"name":"Synthetic","type":"anonymous","encrypted":encrypted,"unread":0]
        if let key { fields["channel_key_enc"] = key }
        return try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:fields))
    }
    private func setup(context:Bool = false) async throws -> NativeChatPreviewModel {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [MainReconnectProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://main-reconnect.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,notificationDefaults:nil)
        model.channels = try [channel(93),channel(94)];model.selection = 93;model.connected = true;model.liveStatus = .live
        MainReconnectProtocol.route = { request,_ in request.respond(self.page(context ? Array(85...115) : Array(61...90))) }
        if context { model.navigateToMessage(channelID:93,postID:100) } else { model.loadSelection() }
        await model.historyTask?.value
        XCTAssertNil(model.error);XCTAssertFalse(model.posts.isEmpty)
        addTeardownBlock { @MainActor in MainReconnectProtocol.route = nil;model.signOutLocally() }
        return model
    }
    private func editor(_ model:NativeChatPreviewModel,id:Int64) throws -> UUID {
        let owner = UUID();model.beginMessageEditing(owner:owner,post:try XCTUnwrap(model.posts.first { $0.id == id }));return owner
    }
    func testHeldReconnectKeepsLoadedRowsEditorTicketDraftsAndNewestViewportInput() async throws {
        let model = try await setup()
        MainReconnectProtocol.route = { request,_ in request.respond(self.page(Array(31...61))) }
        await model.loadOlder()
        let owner = try editor(model,id:50),token = model.historyViewportToken,ids = model.posts.map(\.id)
        model.draft = "Exact main draft 😀";model.threadDrafts[800] = "Exact thread draft"
        model.noteTimelineViewport(postID:50,atBottom:false,token:token,account:model.accountGeneration,channelID:93)
        var held:MainReconnectProtocol?
        let started = expectation(description:"Anchored preserving read held")
        MainReconnectProtocol.route = { request,fields in
            if fields["post_id"] == "50" { held = request;started.fulfill() }
            else { request.respond(self.page(Array(62...91))) }
        }
        model.loadSelection(preservingThread:true,preservingViewport:true)
        let refresh = model.historyTask
        await fulfillment(of:[started],timeout:2)
        XCTAssertEqual(model.posts.map(\.id),ids);XCTAssertEqual(model.historyViewportToken,token)
        XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertFalse(model.viewingMessageContext)
        model.noteTimelineViewport(postID:55,atBottom:false,token:token,account:model.accountGeneration,channelID:93)
        held?.respond(page(Array(45...55)));await refresh?.value
        XCTAssertEqual(model.posts.map(\.id),Array(31...91));XCTAssertEqual(model.historyViewportToken,token)
        XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertFalse(model.viewingMessageContext)
        XCTAssertEqual(model.draft,"Exact main draft 😀");XCTAssertEqual(model.threadDrafts[800],"Exact thread draft")
        var anchors:[String] = []
        MainReconnectProtocol.route = { request,fields in
            if let anchor = fields["post_id"] { anchors.append(anchor);request.respond(self.page(Array(50...60))) }
            else { request.respond(self.page(Array(62...91))) }
        }
        model.loadSelection(preservingThread:true,preservingViewport:true);await model.historyTask?.value
        XCTAssertEqual(anchors.first,"55","Refresh must retain input received while its previous response was held")
        XCTAssertEqual(model.activeMessageEditor,owner)
    }
    func testContextCoverageKeepsOutsidePagesAndConcurrentCanonicalEditWhileDeletionWins() async throws {
        let model = try await setup(context:true)
        MainReconnectProtocol.route = { request,_ in request.respond(self.page(Array(55...85))) }
        await model.loadOlder()
        let token = model.historyViewportToken,owner = try editor(model,id:90)
        model.noteTimelineViewport(postID:90,atBottom:false,token:token,account:model.accountGeneration,channelID:93)
        var held:MainReconnectProtocol?
        let began = expectation(description:"Context response held")
        MainReconnectProtocol.route = { request,fields in
            if fields["prev_count"] == "0",fields["next_count"] == "0" {
                let id = Int64(fields["post_id"] ?? "") ?? 0
                request.respond(self.response([self.row(id,message:"New canonical edit",thread:id == 999 ? 700 : 0)]))
            } else { held = request;began.fulfill() }
        }
        model.loadSelection(preservingThread:true,preservingViewport:true);let pending = model.historyTask
        await fulfillment(of:[began],timeout:2)
        model.handleLiveEvent(.init(name:"client.post.update",payload:.object(["channel_id":.integer(93),"post_id":.integer(90)])))
        for task in Array(model.eventTasks.values) { await task.value }
        model.handleLiveEvent(.init(name:"client.post.delete",payload:.object(["channel_id":.integer(93),"post_id":.integer(91)])))
        model.handleLiveEvent(.init(name:"client.post.create",payload:.object(["channel_id":.integer(93),"post_id":.integer(999),"thread_id":.integer(700)])))
        for task in Array(model.eventTasks.values) { await task.value }
        held?.respond(page(Array(85...95).filter { $0 != 90 }));await pending?.value
        XCTAssertEqual(model.posts.map(\.id),Array(55...115).filter { $0 != 91 })
        XCTAssertEqual(model.posts.first { $0.id == 90 }?.message,"New canonical edit")
        XCTAssertTrue(model.viewingMessageContext);XCTAssertTrue(model.canLoadNewer)
        XCTAssertEqual(model.historyViewportToken,token);XCTAssertEqual(model.activeMessageEditor,owner)
    }
    func testSecondRefreshRejectsDelayedSameReaderResponse() async throws {
        let model = try await setup(),token = model.historyViewportToken
        var held:MainReconnectProtocol?;let began = expectation(description:"First refresh held")
        MainReconnectProtocol.route = { request,_ in held = request;began.fulfill() }
        model.loadSelection(preservingThread:true,preservingViewport:true);let first = model.historyTask
        await fulfillment(of:[began],timeout:2)
        MainReconnectProtocol.route = { request,_ in request.respond(self.page(Array(62...91))) }
        model.loadSelection(preservingThread:true,preservingViewport:true);await model.historyTask?.value
        held?.respond(page(Array(61...90)));await first?.value
        XCTAssertEqual(model.posts.map(\.id),Array(61...91));XCTAssertEqual(model.historyViewportToken,token)
        XCTAssertFalse(model.loadingHistory)
    }
    func testOldPagingCannotLandAfterPreservingRefresh() async throws {
        let model = try await setup(),token = model.historyViewportToken
        var held:MainReconnectProtocol?;let began = expectation(description:"Older page held")
        MainReconnectProtocol.route = { request,_ in held = request;began.fulfill() }
        let older = Task { await model.loadOlder() };await fulfillment(of:[began],timeout:2)
        MainReconnectProtocol.route = { request,_ in request.respond(self.page(Array(62...91))) }
        model.loadSelection(preservingThread:true,preservingViewport:true);await model.historyTask?.value
        held?.respond(page(Array(31...61)));await older.value
        XCTAssertEqual(model.posts.map(\.id),Array(61...91));XCTAssertEqual(model.historyViewportToken,token)
    }
    func testInvalidRefreshRetainsRowsEditorAndToken() async throws {
        let model = try await setup(),token = model.historyViewportToken,owner = try editor(model,id:70)
        MainReconnectProtocol.route = { request,_ in request.respond(self.page([90],channel:94)) }
        model.loadSelection(preservingThread:true,preservingViewport:true);await model.historyTask?.value
        XCTAssertEqual(model.posts.map(\.id),Array(61...90));XCTAssertEqual(model.historyViewportToken,token)
        XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertNotNil(model.error)
    }
    func testSignOutRejectsHeldPreservingResponseAndRetiresEditor() async throws {
        let model = try await setup();_ = try editor(model,id:70)
        let oldAccount = model.accountGeneration
        var held:MainReconnectProtocol?;let began = expectation(description:"Refresh held before sign out")
        MainReconnectProtocol.route = { request,_ in held = request;began.fulfill() }
        model.loadSelection(preservingThread:true,preservingViewport:true);let pending = model.historyTask
        await fulfillment(of:[began],timeout:2)
        model.signOutLocally();held?.respond(page(Array(62...91)));await pending?.value
        XCTAssertNotEqual(model.accountGeneration,oldAccount);XCTAssertTrue(model.posts.isEmpty)
        XCTAssertNil(model.activeMessageEditor);XCTAssertFalse(model.connected);XCTAssertFalse(model.loadingHistory)
    }
    func testExplicitNavigationAndLatestReturnResetEditorAndReader() async throws {
        let model = try await setup();_ = try editor(model,id:70)
        var token = model.historyViewportToken
        MainReconnectProtocol.route = { request,_ in request.respond(self.page(Array(185...215))) }
        model.navigateToMessage(channelID:93,postID:200);await model.historyTask?.value
        XCTAssertNotEqual(model.historyViewportToken,token);XCTAssertNil(model.activeMessageEditor);XCTAssertTrue(model.viewingMessageContext)
        _ = try editor(model,id:200);token = model.historyViewportToken
        MainReconnectProtocol.route = { request,_ in request.respond(self.page(Array(220...249))) }
        model.loadSelection(preservingThread:true,preservingViewport:true,returningToLatest:true);await model.historyTask?.value
        XCTAssertNotEqual(model.historyViewportToken,token);XCTAssertNil(model.activeMessageEditor);XCTAssertFalse(model.viewingMessageContext)
        XCTAssertEqual(model.posts.map(\.id),Array(220...249))
    }
    func testUnownedContextAnchorCannotCrossChannelOrKeyIdentity() async throws {
        for changeChannel in [true,false] {
            let model = try await setup(context:true),token = model.historyViewportToken
            _ = try editor(model,id:90)
            model.noteTimelineViewport(postID:90,atBottom:false,token:token,account:model.accountGeneration,channelID:93)
            if changeChannel { model.selection = 94 }
            else { model.channels = try [channel(93,key:"Changed synthetic context key"),channel(94)] }
            var fields:[[String:String]] = []
            MainReconnectProtocol.route = { request,parameters in
                fields.append(parameters);request.respond(self.page(Array(200...229),channel:changeChannel ? 94 : 93))
            }
            model.loadSelection(preservingThread:true,preservingViewport:true);await model.historyTask?.value
            XCTAssertEqual(fields.count,1);XCTAssertNil(fields.first?["post_id"],"An unowned reader anchor must never become a new-scope request")
            XCTAssertEqual(fields.first?["prev_count"],"30");XCTAssertEqual(fields.first?["next_count"],"0")
            XCTAssertEqual(model.posts.map(\.id),Array(200...229));XCTAssertFalse(model.viewingMessageContext)
            XCTAssertNotEqual(model.historyViewportToken,token);XCTAssertNil(model.activeMessageEditor);XCTAssertNil(model.error)
        }
    }
    func testChannelOrKeyChangeAndSignOutCannotRetainOldEditorScope() async throws {
        let model = try await setup();_ = try editor(model,id:70);let token = model.historyViewportToken
        model.selection = 94
        MainReconnectProtocol.route = { request,_ in request.respond(self.page(Array(200...229),channel:94)) }
        model.loadSelection(preservingThread:true,preservingViewport:true);await model.historyTask?.value
        XCTAssertNotEqual(model.historyViewportToken,token);XCTAssertNil(model.activeMessageEditor)
        XCTAssertTrue(model.posts.allSatisfy { $0.channel_id == 94 })
        _ = try editor(model,id:210);let channelToken = model.historyViewportToken
        model.channels = try [channel(93),channel(94,key:"Changed synthetic key identity")]
        model.loadSelection(preservingThread:true,preservingViewport:true);await model.historyTask?.value
        XCTAssertNotEqual(model.historyViewportToken,channelToken);XCTAssertNil(model.activeMessageEditor)
        _ = try editor(model,id:210);let beforeLock = model.historyViewportToken
        model.channels = try [channel(93),channel(94,encrypted:true,key:"Unavailable synthetic key")]
        model.loadSelection(preservingThread:true,preservingViewport:true);await model.historyTask?.value
        XCTAssertNotEqual(model.historyViewportToken,beforeLock);XCTAssertTrue(model.posts.isEmpty);XCTAssertNil(model.activeMessageEditor)
        model.signOutLocally();XCTAssertTrue(model.posts.isEmpty);XCTAssertNil(model.activeMessageEditor)
    }
}

private final class MainReconnectProtocol:URLProtocol {
    static var route:((MainReconnectProtocol,[String:String])->Void)?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "main-reconnect.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        if request.url?.lastPathComponent == "SYNO.API.Info" {
            respond(Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8));return
        }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };bytes.append(contentsOf:buffer.prefix(count)) }
        }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{$1})
        guard fields["method"] == "list",request.url?.lastPathComponent == "SYNO.Chat.Post" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        Self.route?(self,fields)
    }
    func respond(_ data:Data) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
