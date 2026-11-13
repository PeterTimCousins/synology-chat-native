import XCTest
@testable import SynologyChatNative

@MainActor final class ChatMessageEditConflictTests:XCTestCase {
    private func fields(_ id:Int64 = 100,message:String = "Original café 😀",revision:Double = 1000,thread:Int64 = 0,deleted:Double = 0)->[String:Any] {
        ["post_id":id,"channel_id":23,"creator_id":10,"message":message,"type":"normal","thread_id":thread,"create_at":1000,"update_at":revision,"delete_at":deleted]
    }
    private func post(_ value:[String:Any]) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:value))
    }
    private func setup() async throws -> NativeChatPreviewModel {
        EditConflictProtocol.writes = 0;EditConflictProtocol.route = nil
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [EditConflictProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        },notificationDefaults:nil)
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://edit-conflict.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        model.selection = 23;model.liveStatus = .live
        XCTAssertTrue(model.connected);XCTAssertEqual(model.userID,10)
        addTeardownBlock { @MainActor in model.signOutLocally();EditConflictProtocol.route = nil }
        return model
    }
    private func begin(_ model:NativeChatPreviewModel,_ value:ChatPost)->UUID {
        model.posts = [value];let owner = UUID();model.beginMessageEditing(owner:owner,post:value);return owner
    }
    private func assertConflict(_ model:NativeChatPreviewModel,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertEqual(EditConflictProtocol.writes,0,file:file,line:line)
        let text = model.error?.lowercased() ?? ""
        XCTAssertTrue(text.contains("changed") || text.contains("refresh"),file:file,line:line)
    }
    func testUnchangedMainAndThreadEditsReadThenWriteThenRead() async throws {
        for thread:Int64 in [0,900] {
            let model = try await setup(),original = try post(fields(100,thread:thread)),owner = begin(model,original)
            if thread != 0 { model.threadRoot = try post(fields(900));model.posts = [try post(fields(900))];model.replies = [original] }
            var current = fields(100,thread:thread),calls:[String] = []
            EditConflictProtocol.route = { request in
                calls.append(request.method)
                if request.method == "set" { current["message"] = request.decoded("message");current["update_at"] = 2000;request.reply([:]) }
                else { request.reply(["posts":[current]]) }
            }
            let result = await model.edit(original,text:"Edited exact text 😀",owner:owner)
            XCTAssertTrue(result);XCTAssertEqual(calls,["list","set","list"]);XCTAssertEqual(EditConflictProtocol.writes,1)
            XCTAssertEqual((thread == 0 ? model.posts : model.replies).first { $0.id == 100 }?.message,"Edited exact text 😀")
            XCTAssertTrue(model.pendingMessageActions.isEmpty)
        }
    }
    func testOwnedEditorUsesCapturedOriginalEvenWhenRenderedPostAlreadyChanged() async throws {
        let model = try await setup(),original = try post(fields()),owner = begin(model,original)
        let changedFields = fields(message:"Remote change",revision:2000),changed = try post(changedFields)
        model.posts = [changed];model.draft = "Unsent composer"
        EditConflictProtocol.route = { $0.reply(["posts":[changedFields]]) }
        let result = await model.edit(changed,text:"Local edit from original",owner:owner)
        XCTAssertFalse(result);assertConflict(model);XCTAssertEqual(model.activeMessageEditor,owner)
        XCTAssertEqual(model.draft,"Unsent composer")
    }
    func testRevisionOnlyAndExactUnicodeWireChangesRefuseWrite() async throws {
        for remote in [fields(revision:2000),fields(message:"Original cafe\u{301} 😀")] {
            let model = try await setup(),original = try post(fields()),owner = begin(model,original)
            EditConflictProtocol.route = { $0.reply(["posts":[remote]]) }
            let result = await model.edit(original,text:"Local edit",owner:owner)
            XCTAssertFalse(result);assertConflict(model);XCTAssertEqual(model.activeMessageEditor,owner)
        }
    }
    func testDeletedPreflightAndUnownedEditDuringActiveEditorRefuseWrite() async throws {
        let model = try await setup(),original = try post(fields()),owner = begin(model,original)
        var reads = 0
        EditConflictProtocol.route = { request in reads += 1;request.reply(["posts":[self.fields(deleted:3000)]]) }
        let unowned = await model.edit(original,text:"Unowned request")
        XCTAssertFalse(unowned);XCTAssertEqual(reads,0);XCTAssertEqual(EditConflictProtocol.writes,0)
        let deleted = await model.edit(original,text:"Local edit",owner:owner)
        XCTAssertFalse(deleted);XCTAssertEqual(EditConflictProtocol.writes,0)
    }
    func testOwnerlessPathStillRequiresFreshOriginalBaseline() async throws {
        for changed in [false,true] {
            let model = try await setup(),original = try post(fields());model.posts = [original]
            var calls:[String] = []
            EditConflictProtocol.route = { request in
                calls.append(request.method)
                if request.method == "set" { request.reply([:]) }
                else {
                    let message = calls.contains("set") ? "Ownerless edited" : changed ? "Changed elsewhere" : "Original café 😀"
                    request.reply(["posts":[self.fields(message:message,revision:changed || calls.contains("set") ? 2000 : 1000)]])
                }
            }
            let result = await model.edit(original,text:"Ownerless edited")
            XCTAssertEqual(result,!changed)
            XCTAssertEqual(EditConflictProtocol.writes,changed ? 0 : 1)
            XCTAssertEqual(calls,changed ? ["list"] : ["list","set","list"])
        }
    }
    func testHeldPreflightRejectsEndRebeginDifferentOwnerAccountKeyAndAccessChanges() async throws {
        for mutation in 0..<6 {
            let model = try await setup(),original = try post(fields()),owner = begin(model,original)
            var held:EditConflictProtocol?;let began = expectation(description:"Held edit preflight \(mutation)")
            EditConflictProtocol.route = { request in held = request;began.fulfill() }
            let pending = Task { await model.edit(original,text:"Must not write",owner:owner) }
            await fulfillment(of:[began],timeout:2)
            switch mutation {
            case 0:model.endMessageEditing(owner:owner)
            case 1:model.endMessageEditing(owner:owner);model.beginMessageEditing(owner:owner,post:original)
            case 2:model.beginMessageEditing(owner:UUID(),post:original)
            case 3:model.signOutLocally()
            case 4:
                model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic","type":"private","encrypted":false,"channel_key_enc":"changed-key","unread":0}"#.utf8))]
            default:model.channels = []
            }
            held?.reply(["posts":[fields()]]);let result = await pending.value
            XCTAssertFalse(result);XCTAssertEqual(EditConflictProtocol.writes,0,"Mutation \(mutation) must retire the preflight")
        }
    }
    func testPreflightFailureAndTaskCancellationNeverWriteAndKeepOwner() async throws {
        for cancel in [false,true] {
            let model = try await setup(),original = try post(fields()),owner = begin(model,original)
            var held:EditConflictProtocol?;let began = expectation(description:"Preflight starts")
            EditConflictProtocol.route = { request in held = request;began.fulfill() }
            let pending = Task { await model.edit(original,text:"Local edit",owner:owner) }
            await fulfillment(of:[began],timeout:2)
            if cancel { pending.cancel();held?.reply(["posts":[fields()]]) } else { held?.fail() }
            let result = await pending.value
            XCTAssertFalse(result);XCTAssertEqual(EditConflictProtocol.writes,0);XCTAssertEqual(model.activeMessageEditor,owner)
            XCTAssertTrue(model.pendingMessageActions.isEmpty)
        }
    }
    func testQueuedOldSessionCannotSaveIntoReopenedSameOwnerEditor() async throws {
        let model = try await setup(),original = try post(fields()),owner = begin(model,original)
        let oldSession = try XCTUnwrap(model.messageEditorSession(owner:owner))
        model.endMessageEditing(owner:owner);model.beginMessageEditing(owner:owner,post:original)
        let newSession = try XCTUnwrap(model.messageEditorSession(owner:owner))
        XCTAssertNotEqual(oldSession,newSession)
        var reads = 0
        EditConflictProtocol.route = { request in reads += 1;request.reply(["posts":[self.fields()]]) }
        let result = await model.edit(original,text:"Stale queued local text",owner:owner,session:oldSession)
        XCTAssertFalse(result);XCTAssertEqual(reads,0);XCTAssertEqual(EditConflictProtocol.writes,0)
        XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertEqual(model.messageEditorSession(owner:owner),newSession)
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testDuplicateSaveWhilePreflightHeldDispatchesOnlyOnce() async throws {
        let model = try await setup(),original = try post(fields()),owner = begin(model,original)
        var held:EditConflictProtocol?;var lists = 0;let began = expectation(description:"First preflight held")
        EditConflictProtocol.route = { request in
            if request.method == "set" { request.reply([:]) }
            else { lists += 1;if lists == 1 { held = request;began.fulfill() } else { request.reply(["posts":[self.fields(message:"Edited",revision:2000)]]) } }
        }
        let first = Task { await model.edit(original,text:"Edited",owner:owner) }
        await fulfillment(of:[began],timeout:2)
        let second = await model.edit(original,text:"Duplicate",owner:owner)
        XCTAssertFalse(second);held?.reply(["posts":[fields()]]);let success = await first.value
        XCTAssertTrue(success);XCTAssertEqual(EditConflictProtocol.writes,1)
    }
    func testLostWriteReplyIsUncertainWithoutAutomaticReplay() async throws {
        let model = try await setup(),original = try post(fields()),owner = begin(model,original)
        EditConflictProtocol.route = { request in if request.method == "set" { request.fail() } else { request.reply(["posts":[self.fields()]]) } }
        let result = await model.edit(original,text:"Possibly accepted",owner:owner)
        XCTAssertFalse(result);XCTAssertEqual(EditConflictProtocol.writes,1);XCTAssertEqual(model.activeMessageEditor,owner)
        XCTAssertTrue(model.pendingMessageActions.isEmpty);XCTAssertNotNil(model.error)
    }
    func testAcknowledgedNoOpWriteDoesNotClaimConfirmedEditOrCloseOwner() async throws {
        let model = try await setup(),original = try post(fields()),owner = begin(model,original)
        let session = try XCTUnwrap(model.messageEditorSession(owner:owner))
        var reads = 0
        EditConflictProtocol.route = { request in
            if request.method == "set" { request.reply([:]) }
            else { reads += 1;request.reply(["posts":[self.fields()]]) }
        }
        let result = await model.edit(original,text:"Server did not apply this text",owner:owner,session:session)
        XCTAssertFalse(result);XCTAssertEqual(EditConflictProtocol.writes,1);XCTAssertEqual(reads,2)
        XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertEqual(model.messageEditorSession(owner:owner),session)
        XCTAssertEqual(model.posts.first { $0.id == original.id }?.message,original.message)
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        let error = model.error?.lowercased() ?? ""
        XCTAssertTrue(error.contains("confirm") || error.contains("check"))
    }
    func testDelayedReadbackCannotRollbackNewerLiveCanonicalEdit() async throws {
        let model = try await setup(),original = try post(fields()),owner = begin(model,original)
        var held:EditConflictProtocol?;var lists = 0;let began = expectation(description:"Edit readback held")
        EditConflictProtocol.route = { request in
            if request.method == "set" { request.reply([:]) }
            else { lists += 1;if lists == 1 { request.reply(["posts":[self.fields()]]) } else if lists == 2 { held = request;began.fulfill() } else { request.reply(["posts":[self.fields(message:"Newer live canonical",revision:4000)]]) } }
        }
        let pending = Task { await model.edit(original,text:"Our accepted edit",owner:owner) }
        await fulfillment(of:[began],timeout:2)
        model.handleLiveEvent(.init(name:"client.post.update",payload:.object(["channel_id":.integer(23),"post_id":.integer(100)])))
        for task in Array(model.eventTasks.values) { await task.value }
        held?.reply(["posts":[fields(message:"Our accepted edit",revision:2000)]]);_ = await pending.value
        XCTAssertEqual(model.posts.first { $0.id == 100 }?.message,"Newer live canonical")
        XCTAssertEqual(EditConflictProtocol.writes,1)
    }
}

private final class EditConflictProtocol:URLProtocol {
    static var route:((EditConflictProtocol)->Void)?
    static var writes = 0
    var method:String { form["method"] ?? "" }
    private var cached:[String:String]?
    private var form:[String:String] {
        if let cached { return cached }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };bytes.append(contentsOf:buffer.prefix(n)) }
        }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let value = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{$1});cached = value;return value
    }
    func decoded(_ key:String)->String { (try? JSONDecoder().decode(String.self,from:Data((form[key] ?? "").utf8))) ?? "" }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "edit-conflict.invalid" else { fail();return }
        let api = request.url!.lastPathComponent
        if api == "SYNO.Chat.Post",Self.route != nil {
            if method == "set" { Self.writes += 1 }
            Self.route?(self);return
        }
        switch api {
        case "SYNO.API.Info":
            reply(Dictionary(uniqueKeysWithValues:["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Post","SYNO.Chat.Channel.Member"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) }))
        case "SYNO.Chat.User":reply(["users":[["user_id":10,"username":"synthetic","nickname":"Synthetic","type":"human","human_type":"dsm"]]])
        case "SYNO.Chat.Channel":reply(["channels":[["channel_id":23,"name":"Synthetic","type":"private","encrypted":false,"unread":0]]])
        case "SYNO.Chat.Misc":reply(["acls":[]])
        case "SYNO.Chat.Channel.Member":reply(["user_ids":[10]])
        case "SYNO.Chat.Post":reply(["posts":[]])
        default:reply([:]) // Missing live config intentionally prevents a socket.
        }
    }
    func fail() { client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost)) }
    func reply(_ data:[String:Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject:["success":true,"data":data])
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
