import XCTest
@testable import SynologyChatNative

@MainActor final class ChatPollTests:XCTestCase {
    private func json(_ value:Any) throws -> Data { try JSONSerialization.data(withJSONObject:value) }
    private func fixture() throws -> [String:Any] { try JSONSerialization.jsonObject(with:Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"ChatPoll",withExtension:"json",subdirectory:"Fixtures")))) as! [String:Any] }
    private func post() throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:json(PollProtocol.post)) }
    private func client() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [PollProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://poll-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config));try await api.discover();return api
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [PollProtocol.self];return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://poll-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 93;model.posts = [try post()]
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func setUpWithError() throws { PollProtocol.post = try fixture();PollProtocol.observer = nil;PollProtocol.hold = false;PollProtocol.held = nil;PollProtocol.errorOnWrite = false;PollProtocol.ignoreWrites = false }
    override func tearDown() { PollProtocol.observer = nil;PollProtocol.hold = false;PollProtocol.held = nil;super.tearDown() }
    func testNASPollDecodesStringChoiceIDsAndResultOrderWithoutInventingVoters() throws {
        let value = try post();let poll = try XCTUnwrap(value.props?.vote)
        XCTAssertEqual(value.type,"vote");XCTAssertTrue(poll.isOpen());XCTAssertTrue(poll.options.multiple)
        XCTAssertTrue(poll.choices[0].id.contains("-"));XCTAssertEqual(poll.totalSelections,0)
        let choices = [ChatPollChoice(id:"a",text:"A",count:1),ChatPollChoice(id:"b",text:"B",count:3),ChatPollChoice(id:"c",text:"C",count:3)]
        let closed = ChatPoll(state:"close",options:poll.options,choices:choices)
        XCTAssertEqual(closed.sortedResults.map(\.id),["b","c","a"]);XCTAssertTrue(closed.selected(by:10).isEmpty)
        XCTAssertThrowsError(try poll.replacingChoices([choices[0],choices[0]]))
    }
    func testPollDraftUsesOfficialUTF16LimitUniqueTrimmedOptionsAndFutureExpiry() throws {
        var draft = ChatPollDraft();draft.question = String(repeating:"😀",count:60);draft.choices = [.init(text:" A "),.init(text:"B"),.init(text:" ")]
        let valid = try draft.validated();XCTAssertEqual(valid.choices.map(\.text),["A","B"])
        draft.question += "x";XCTAssertThrowsError(try draft.validated());draft.question = "Question"
        draft.choices[1].text = "A";XCTAssertThrowsError(try draft.validated());draft.choices[1].text = "B"
        draft.expires = true;draft.expiry = Date().addingTimeInterval(-1);XCTAssertThrowsError(try draft.validated())
        draft.expiry = Date().addingTimeInterval(3600);XCTAssertNoThrow(try draft.validated())
    }
    func testCreateVoteAndEditWireUseStructuredObjectsAndPartialEditOmitsFrozenFields() async throws {
        let api = try await client();var calls:[[String:String]] = [];PollProtocol.observer = { _,fields in calls.append(fields) }
        var draft = ChatPollDraft();draft.question = "Question";draft.choices = [.init(text:"A"),.init(text:"B")];draft.multiple = true
        _ = try await api.createPoll(channelID:93,draft:draft)
        let choices = try await api.pollChoices(postID:399431958754)
        try await api.votePoll(postID:399431958754,choices:[choices[0].id],connectionID:"synthetic-connection")
        try await api.votePoll(postID:399431958754,choices:[],connectionID:nil)
        try await api.addPollOption(postID:399431958754,text:" C ",connectionID:"synthetic-connection")
        try await api.editPoll(postID:399431958754,channelID:93,draft:draft,full:false)
        try await api.closePoll(postID:399431958754)
        let first = calls[0]
        XCTAssertEqual(first["method"],"create");XCTAssertEqual(first["version"],"1")
        let options = try JSONSerialization.jsonObject(with:Data(first["options"]!.utf8)) as! [String:Any]
        XCTAssertEqual(options["multiple"] as? Bool,true);XCTAssertEqual(options["anonymous"] as? Bool,false)
        XCTAssertEqual(try JSONSerialization.jsonObject(with:Data(first["choices"]!.utf8)) as? [[String:String]],[["text":"A"],["text":"B"]])
        XCTAssertEqual(calls[2]["conn_id"],#""synthetic-connection""#);XCTAssertEqual(calls[3]["choice_ids"],"[]")
        XCTAssertEqual(calls[4]["text"],#""C""#)
        XCTAssertNil(calls[5]["message"]);XCTAssertNil(calls[5]["choices"])
        let partial = try JSONSerialization.jsonObject(with:Data(calls[5]["options"]!.utf8)) as! [String:Any]
        XCTAssertNil(partial["anonymous"]);XCTAssertNil(partial["multiple"])
    }
    func testCanonicalMultipleVotingWithdrawalAndAddedOptionUpdateModel() async throws {
        let model = try await model(),target = try post();let ids = try XCTUnwrap(target.props?.vote?.choices.map(\.id))
        let voted = try await model.updatePoll(target,action:.vote(ids))
        XCTAssertEqual(voted.poll.selected(by:10),ids);XCTAssertEqual(voted.poll.totalSelections,2)
        let withdrawn = try await model.updatePoll(target,action:.vote([]));XCTAssertEqual(withdrawn.poll.totalSelections,0)
        let added = try await model.updatePoll(target,action:.addOption("Native option C"));XCTAssertEqual(added.poll.choices.last?.text,"Native option C")
        XCTAssertEqual(model.posts.first?.props?.vote?.choices.count,3);XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testPolicyRejectsInvalidChoicesWrongAuthorAndEncryptedChannelBeforeWrite() async throws {
        let model = try await model(),target = try post();var writes = 0;PollProtocol.observer = { api,f in if api == "SYNO.Chat.Post.Vote",f["method"] != "get_choices" { writes += 1 } }
        do { _ = try await model.updatePoll(target,action:.vote(["missing"]));XCTFail() } catch { }
        do { _ = try await model.updatePoll(target,action:.addOption("Native option A"));XCTFail() } catch { }
        PollProtocol.post["creator_id"] = 11
        do { _ = try await model.updatePoll(target,action:.close);XCTFail() } catch { }
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Encrypted","type":"private","encrypted":true,"unread":0}"#.utf8))]
        do { _ = try await model.updatePoll(target,action:.vote([]));XCTFail() } catch { }
        XCTAssertEqual(writes,0);XCTAssertFalse(model.canCreatePoll);XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testVotesFreezeQuestionChoicesAndAnonymityButKeepAllowedOptionSettingsEditable() async throws {
        let model = try await model(),target = try post();let id = try XCTUnwrap(target.props?.vote?.choices[0].id)
        let voted = try await model.updatePoll(target,action:.vote([id]));var draft = ChatPollDraft(details:voted)
        draft.question = "Changed after vote"
        do { _ = try await model.updatePoll(target,action:.edit(draft));XCTFail() } catch let error as ChatPollError { XCTAssertTrue(error.message.contains("Votes have arrived")) }
        draft = ChatPollDraft(details:voted);draft.allowAdd = false
        let changed = try await model.updatePoll(target,action:.edit(draft));XCTAssertFalse(changed.poll.options.add_option);XCTAssertEqual(changed.post.message,target.message)
        let closed = try await model.updatePoll(target,action:.close);XCTAssertFalse(closed.poll.isOpen())
        do { _ = try await model.updatePoll(target,action:.vote([]));XCTFail() } catch { }
    }
    func testServerFailureDoesNotOptimisticallyVoteOrRetryCreates() async throws {
        let model = try await model(),target = try post();PollProtocol.errorOnWrite = true;var writes = 0
        PollProtocol.observer = { api,f in if api == "SYNO.Chat.Post.Vote",f["method"] != "get_choices" { writes += 1 } }
        do { _ = try await model.updatePoll(target,action:.vote([target.props!.vote!.choices[0].id]));XCTFail() } catch { }
        XCTAssertEqual(model.posts[0].props?.vote?.totalSelections,0);XCTAssertTrue(model.pendingMessageActions.isEmpty)
        var draft = ChatPollDraft();draft.question = "Question";draft.choices = [.init(text:"A"),.init(text:"B")]
        do { _ = try await model.createPoll(draft);XCTFail() } catch { }
        XCTAssertEqual(writes,2);XCTAssertFalse(model.sending)
    }
    func testSuccessfulEnvelopeWithoutCanonicalPollChangeIsNotConfirmation() async throws {
        let model = try await model(),target = try post();PollProtocol.ignoreWrites = true
        for action in [ChatPollAction.vote([target.props!.vote!.choices[0].id]),.addOption("Unconfirmed option"),.close] {
            do { _ = try await model.updatePoll(target,action:action);XCTFail("Unchanged canonical poll was accepted") } catch ChatAPIError.invalidResponse { }
        }
        XCTAssertEqual(model.posts[0].props?.vote?.totalSelections,0);XCTAssertTrue(model.posts[0].props!.vote!.isOpen())
    }
    func testClearingPollStoreCancelsPendingResultAndCannotRestoreAfterSignOut() async throws {
        let model = try await model(),target = try post(),store = NativePollStore()
        model.pollDrafts[93] = ChatPollDraft()
        let started = expectation(description:"Poll choices loading")
        PollProtocol.hold = true;PollProtocol.observer = { _,f in if f["method"] == "get_choices" { started.fulfill() } }
        store.refresh(model:model,post:target);let task = store.task
        await fulfillment(of:[started],timeout:2);store.clear();model.signOutLocally();await task?.value
        XCTAssertNil(store.details);XCTAssertNil(store.failure);XCTAssertFalse(store.busy);XCTAssertTrue(model.pollDrafts.isEmpty)
    }
}

private final class PollProtocol:URLProtocol {
    static var post:[String:Any] = [:]
    static var observer:((String,[String:String])->Void)?
    static var hold = false
    static var held:PollProtocol?
    static var errorOnWrite = false
    static var ignoreWrites = false
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&b,maxLength:b.count);if n<=0 { break };bytes.append(contentsOf:b.prefix(n)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let api = request.url!.lastPathComponent,method = fields["method"] ?? ""
        do {
            if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Post.Vote","SYNO.Chat.Post","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Admin.Setting"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
            Self.observer?(api,fields)
            var result:[String:Any] = [:]
            switch (api,method) {
            case ("SYNO.Chat.User","list"):result = ["users":[["user_id":10,"username":"synthetic","nickname":"Peter"],["user_id":11,"username":"peer","nickname":"Peer"]]]
            case ("SYNO.Chat.Channel","list"):result = ["channels":[["channel_id":93,"name":"Peter","type":"public","encrypted":false,"unread":0]]]
            case ("SYNO.Chat.Misc",_):result = ["acls":[]]
            case ("SYNO.Chat.Admin.Setting",_):result = ["hide_post_url_preview":true]
            case ("SYNO.Chat.Post","list"):result = ["posts":[Self.post]]
            case ("SYNO.Chat.Post.Vote",_):
                if Self.ignoreWrites,method != "get_choices" { finish(["success":true,"data":[:]]);return }
                if Self.errorOnWrite,method != "get_choices" { finish(["success":false,"error":["code":551]]);return }
                var props = Self.post["props"] as! [String:Any],poll = props["vote"] as! [String:Any],choices = poll["choices"] as! [[String:Any]],options = poll["options"] as! [String:Any]
                func field(_ key:String) throws -> Any { try JSONSerialization.jsonObject(with:Data(fields[key]!.utf8),options:.fragmentsAllowed) }
                if method == "get_choices",Self.hold { Self.held = self;return }
                switch method {
                case "get_choices":result = ["choices":choices]
                case "create":Self.post["message"] = try field("message");choices = (try field("choices") as! [[String:Any]]).enumerated().map { ["id":"new-\($0.offset)","text":$0.element["text"]!,"count":0,"voters":[]] };poll["options"] = try field("options")
                case "vote":let ids = try field("choice_ids") as! [String];choices = choices.map { value in var c = value;let voted = ids.contains(c["id"] as! String);c["count"] = voted ? 1 : 0;c["voters"] = voted ? [10] : [];return c }
                case "create_option":choices.append(["id":"added","text":try field("text"),"count":0,"voters":[]])
                case "close":poll["state"] = "close"
                case "set":for (key,value) in try field("options") as! [String:Any] { options[key] = value };poll["options"] = options
                default:break
                }
                poll["choices"] = choices;props["vote"] = poll;Self.post["props"] = props
                if method == "create" { result = Self.post }
            default:finish(["success":false,"error":["code":400]]);return
            }
            finish(["success":true,"data":result])
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    private func finish(_ value:[String:Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject:value)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if Self.held === self { Self.held = nil } }
}
