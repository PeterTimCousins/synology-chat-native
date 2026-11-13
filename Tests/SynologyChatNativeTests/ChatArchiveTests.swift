import XCTest
@testable import SynologyChatNative

@MainActor final class ChatArchiveTests:XCTestCase {
    override func setUp() { super.setUp();ArchiveProtocol.reset() }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ArchiveProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://archive-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config));try await api.discover();return api
    }
    private func archive(_ mutate:((inout [String:Any])->Void)? = nil) throws -> ChatArchive {
        var value = ArchiveProtocol.record;mutate?(&value);return try JSONDecoder().decode(ChatArchive.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testNamesAndArchiveScopeUseObservedReadOnlyWireContract() async throws {
        let api = try await api();let name = "Literal <archive> & name"
        let names = try await api.archiveNames(kind:.private);XCTAssertEqual(names,[name])
        let values = try await api.archives(kind:.private,name:name)
        XCTAssertEqual(values.map(\.id),[6]);XCTAssertEqual(ArchiveProtocol.calls.map { $0["method"]! },["list_name","list"])
        XCTAssertEqual(ArchiveProtocol.calls.last?["channel_name"],"\"Literal <archive> & name\"")
        XCTAssertTrue(ArchiveProtocol.calls.allSatisfy { $0["type"] == "\"private\"" && $0["version"] == "1" })
    }
    func testArchivedPostReadsAlwaysCarryArchiveAndChannelIDs() async throws {
        let api = try await api(),source = try archive();let posts = try await api.archivePosts(source,before:30)
        XCTAssertEqual(posts.map(\.id),[10,20]);let fields = try XCTUnwrap(ArchiveProtocol.calls.last)
        XCTAssertEqual(fields["archive_id"],"6");XCTAssertEqual(fields["channel_id"],"4");XCTAssertEqual(fields["post_id"],"30");XCTAssertEqual(fields["prev_count"],"30");XCTAssertEqual(fields["next_count"],"0")
        XCTAssertFalse(fields.keys.contains("last_view_at"))
    }
    func testCrossChannelAndOutOfPeriodPostsFailClosed() async throws {
        let api = try await api(),source = try archive()
        for field in ["channel_id","post_id","create_at"] {
            ArchiveProtocol.posts = [ArchiveProtocol.post(20)];ArchiveProtocol.posts[0][field] = field == "channel_id" ? 999 : 9999
            do { _ = try await api.archivePosts(source);XCTFail("Accepted mismatched \(field)") } catch { }
        }
    }
    func testDuplicateAndNonProgressingPageHandling() async throws {
        let api = try await api(),source = try archive()
        ArchiveProtocol.posts = [ArchiveProtocol.post(20),ArchiveProtocol.post(20)]
        do { _ = try await api.archivePosts(source);XCTFail("Accepted duplicate") } catch { }
        ArchiveProtocol.posts = [ArchiveProtocol.post(20)]
        let end = try await api.archivePosts(source,before:20);XCTAssertTrue(end.isEmpty)
    }
    func testEncryptedAndInvalidPeriodAreRejectedBeforePostRequest() async throws {
        let api = try await api()
        for value in [try archive { v in var props = v["props"] as! [String:Any];var channel = props["channel"] as! [String:Any];channel["encrypted"] = true;props["channel"] = channel;v["props"] = props },try archive { $0["post_end"] = 500 }] {
            XCTAssertFalse(value.isReadable)
            do { _ = try await api.archivePosts(value);XCTFail("Unsupported archive read") } catch { }
        }
        XCTAssertTrue(ArchiveProtocol.calls.isEmpty)
    }
    func testMissingAndEncryptedFreshArchivePreventPostFetch() async throws {
        let api = try await api(),model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false),source = try archive();model.connected = true
        defer { model.signOutLocally() }
        ArchiveProtocol.records = []
        do { _ = try await model.loadArchivePosts(kind:.private,name:"x",archive:source);XCTFail("Missing archive read") } catch { }
        XCTAssertTrue(ArchiveProtocol.calls.allSatisfy { $0["api"] == "SYNO.Chat.Archive" })
        var encrypted = ArchiveProtocol.record;var props = encrypted["props"] as! [String:Any];var channel = props["channel"] as! [String:Any];channel["encrypted"] = true;props["channel"] = channel;encrypted["props"] = props;ArchiveProtocol.records = [encrypted]
        do { _ = try await model.loadArchivePosts(kind:.private,name:"x",archive:source);XCTFail("Encrypted archive read") } catch { }
        XCTAssertTrue(ArchiveProtocol.calls.allSatisfy { $0["api"] == "SYNO.Chat.Archive" })
    }
    func testArchiveBrowsingDoesNotChangeLiveSelectionOrDraft() async throws {
        let api = try await api(),model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false);model.connected = true;model.selection = 93;model.draft = "Unsent live draft"
        defer { model.signOutLocally() }
        let values = try await model.loadArchives(kind:.private,name:"x");_ = try await model.loadArchivePosts(kind:.private,name:"x",archive:values[0])
        XCTAssertEqual(model.selection,93);XCTAssertEqual(model.draft,"Unsent live draft");XCTAssertTrue(model.posts.isEmpty)
        XCTAssertFalse(ArchiveProtocol.calls.contains { ["set","enter","read","delete"].contains($0["method"] ?? "") })
    }
    func testSignOutDuringArchiveLookupCannotReturnOldAccountNames() async throws {
        let api = try await api(),model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false);model.connected = true
        ArchiveProtocol.observer = { _ in model.signOutLocally() }
        do { _ = try await model.loadArchiveNames(kind:.private);XCTFail("Old account names returned") } catch is CancellationError { } catch { XCTFail("Expected session cancellation") }
    }
    func testSignOutBeforeFreshArchiveResponsePreventsPostDispatch() async throws {
        let api = try await api(),model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false),source = try archive();model.connected = true
        ArchiveProtocol.observer = { _ in model.signOutLocally() }
        do { _ = try await model.loadArchivePosts(kind:.private,name:"x",archive:source);XCTFail("Old account post returned") } catch is CancellationError { } catch { XCTFail("Expected session cancellation") }
        XCTAssertEqual(ArchiveProtocol.calls.count,1);XCTAssertEqual(ArchiveProtocol.calls.first?["api"],"SYNO.Chat.Archive")
    }
    func testArchivedThreadWireScopeAndCursorOverlap() async throws {
        let api = try await api(),source = try archive()
        ArchiveProtocol.posts = [ArchiveProtocol.post(10),ArchiveProtocol.post(20),ArchiveProtocol.post(30)]
        for index in 1...2 { ArchiveProtocol.posts[index]["thread_id"] = 10 }
        let replies = try await api.archivePosts(source,before:30,threadID:10)
        XCTAssertEqual(replies.map(\.id),[20]);XCTAssertEqual(ArchiveProtocol.calls.last?["archive_id"],"6");XCTAssertEqual(ArchiveProtocol.calls.last?["thread_id"],"10")
    }
    func testUnrelatedArchivedThreadRepliesAreRejected() async throws {
        let api = try await api(),source = try archive();ArchiveProtocol.posts = [ArchiveProtocol.post(20)];ArchiveProtocol.posts[0]["thread_id"] = 15
        do { _ = try await api.archivePosts(source,threadID:10);XCTFail("Cross-thread reply accepted") } catch { }
        XCTAssertEqual(ArchiveProtocol.calls.count,1)
    }
    func testInvalidThreadRootRejectedWithoutDispatch() async throws {
        let api = try await api(),source = try archive()
        for root:Int64 in [0,31] {
            do { _ = try await api.archivePosts(source,threadID:root);XCTFail("Out-of-period root") } catch { }
        }
        XCTAssertTrue(ArchiveProtocol.calls.isEmpty)
    }
    func testInclusiveArchiveStartAndNoEarlierDispatchAtBoundary() async throws {
        let api = try await api(),source = try archive { $0["post_id_start"] = 10 }
        let values = try await api.archivePosts(source);XCTAssertEqual(values.map(\.id),[10,20,30])
        let calls = ArchiveProtocol.calls.count
        let earlier = try await api.archivePosts(source,before:10);XCTAssertTrue(earlier.isEmpty);XCTAssertEqual(ArchiveProtocol.calls.count,calls)
        ArchiveProtocol.posts = [ArchiveProtocol.post(10),ArchiveProtocol.post(20)];ArchiveProtocol.posts[1]["thread_id"] = 10
        let replies = try await api.archivePosts(source,threadID:10);XCTAssertEqual(replies.map(\.id),[20])
    }
    func testArchiveSearchAlwaysUsesExplicitArchiveIDsAndLiteralKeyword() async throws {
        let api = try await api(),source = try archive()
        let page = try await api.searchArchives(scopes:[source],query:"literal <term> & \"quote\"",collection:.messages,offset:25)
        XCTAssertEqual(page.matches.map { $0.archive.id },[6,6,6]);XCTAssertEqual(page.nextOffset,28)
        let fields = try XCTUnwrap(ArchiveProtocol.calls.last)
        XCTAssertEqual(fields["archives"],"[6]");XCTAssertEqual(fields["in"],"[]");XCTAssertEqual(fields["offset"],"25");XCTAssertEqual(fields["limit"],"25")
        XCTAssertFalse(fields.keys.contains("archive_id"));XCTAssertFalse(fields.keys.contains("channel_id"))
        XCTAssertEqual(try JSONDecoder().decode(String.self,from:Data(fields["keyword"]!.utf8)),"literal <term> & \"quote\"")
    }
    func testArchivedCollectionFiltersMatchOfficialContract() async throws {
        let api = try await api(),source = try archive()
        for category in [ChatArchiveCollection.pinned,.saved,.files,.links] {
            _ = try await api.searchArchives(scopes:[source],query:"",collection:category)
            let fields = ArchiveProtocol.calls.last!
            switch category {
            case .pinned:XCTAssertEqual(fields["has"],"[\"pin\"]");XCTAssertEqual(fields["sort_by_array"],"[\"is_sticky\",\"last_pin_at\"]")
            case .saved:XCTAssertEqual(fields["has"],"[\"star\"]")
            case .files:XCTAssertEqual(fields["post_type"],"[\"file\"]");XCTAssertEqual(fields["sort_by"],"\"create_at\"")
            case .links:XCTAssertEqual(fields["has"],"[\"url\"]")
            default:break
            }
            XCTAssertEqual(fields["archives"],"[6]")
        }
    }
    func testMultipleArchivePeriodsMapEachSearchResultWithoutReordering() async throws {
        let api = try await api()
        let first = try archive { $0["post_id_end"] = 15 },second = try archive { $0["archive_id"] = 7;$0["post_id_start"] = 16 }
        let result = try await api.searchArchives(scopes:[first,second],query:"",collection:.messages)
        XCTAssertEqual(result.matches.map { $0.post.id },[10,20,30]);XCTAssertEqual(result.matches.map { $0.archive.id },[6,7,7])
        XCTAssertEqual(ArchiveProtocol.calls.last?["archives"],"[6,7]")
    }
    func testMissingEncryptedAndAmbiguousArchiveSearchScopesAreRejected() async throws {
        let api = try await api(),source = try archive(),other = try archive { $0["archive_id"] = 7 }
        do { _ = try await api.searchArchives(scopes:[],query:"",collection:.messages);XCTFail("Unscoped search") } catch { }
        do { _ = try await api.searchArchives(scopes:[source,other],query:"",collection:.messages);XCTFail("Ambiguous post mapped") } catch { }
        ArchiveProtocol.searchPosts[0]["channel_id"] = 99
        do { _ = try await api.searchArchives(scopes:[source],query:"",collection:.messages);XCTFail("Foreign channel post") } catch { }
    }
    func testArchiveSearchValidationRejectsOversizedPageAndKeyword() async throws {
        let api = try await api(),source = try archive()
        do { _ = try await api.searchArchives(scopes:[source],query:String(repeating:"x",count:1001),collection:.messages);XCTFail("Oversized keyword") } catch { }
        XCTAssertTrue(ArchiveProtocol.calls.isEmpty)
        ArchiveProtocol.searchPosts = (1...26).map { ArchiveProtocol.post(Int64($0)) }
        do { _ = try await api.searchArchives(scopes:[source],query:"",collection:.messages);XCTFail("Oversized page") } catch { }
    }
    func testSearchRevalidatesArchiveAndStopsOnAccountChangeBeforeDispatch() async throws {
        let api = try await api(),model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false),source = try archive();model.connected = true
        ArchiveProtocol.observer = { _ in model.signOutLocally() }
        do { _ = try await model.searchArchivedMessages(kind:.private,name:"x",scopes:[source],query:"",collection:.saved);XCTFail("Old account search") } catch is CancellationError { } catch { XCTFail("Expected cancellation") }
        XCTAssertEqual(ArchiveProtocol.calls.count,1);XCTAssertEqual(ArchiveProtocol.calls.first?["api"],"SYNO.Chat.Archive")
    }
    func testOrdinarySearchContextRetainsLiveSelectionDraftAndArchiveScope() async throws {
        let api = try await api(),model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false),source = try archive();model.connected = true;model.selection = 93;model.draft = "Keep me"
        defer { model.signOutLocally() }
        let post = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:ArchiveProtocol.post(20)))
        let result = try await model.archivedMessageContext(kind:.private,name:"x",match:.init(archive:source,post:post))
        XCTAssertNil(result.root);XCTAssertTrue(result.posts.contains { $0.id == 20 });XCTAssertEqual(model.selection,93);XCTAssertEqual(model.draft,"Keep me");XCTAssertTrue(model.posts.isEmpty)
        XCTAssertEqual(ArchiveProtocol.calls.last?["archive_id"],"6");XCTAssertEqual(ArchiveProtocol.calls.last?["post_id"],"20")
    }
    func testReplySearchContextResolvesArchivedRootAndExactReply() async throws {
        let api = try await api(),model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false),source = try archive();model.connected = true
        defer { model.signOutLocally() }
        ArchiveProtocol.posts = [ArchiveProtocol.post(20),ArchiveProtocol.post(30)]
        for index in 0...1 { ArchiveProtocol.posts[index]["thread_id"] = 10 }
        let reply = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:ArchiveProtocol.posts[0]))
        let result = try await model.archivedMessageContext(kind:.private,name:"x",match:.init(archive:source,post:reply))
        XCTAssertEqual(result.root?.id,10);XCTAssertEqual(result.posts.map(\.id),[20,30]);XCTAssertEqual(ArchiveProtocol.calls.last?["thread_id"],"10")
        XCTAssertTrue(ArchiveProtocol.calls.filter { $0["api"] == "SYNO.Chat.Post" }.allSatisfy { $0["archive_id"] == "6" })
    }
    func testContextMissingTargetFailsInsteadOfOpeningWrongArchivedMessage() async throws {
        let api = try await api(),source = try archive();ArchiveProtocol.posts = [ArchiveProtocol.post(10)]
        do { _ = try await api.archiveContext(source,postID:20);XCTFail("Wrong context accepted") } catch { }
    }
    func testArchiveBroadcastClearsOldLiveRowsAndRetainsComposerDraft() async throws {
        let api = try await api(),model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false),source = try archive()
        model.connected = true;model.liveStatus = .live;model.channels = [source.props.channel];model.selection = 4;model.draft = "Keep unsent draft"
        defer { model.signOutLocally() }
        let post = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:ArchiveProtocol.post(20)))
        model.posts = [post];XCTAssertTrue(model.canAct(on:post));ArchiveProtocol.posts = []
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("channel.archive"),"data":.object(["channel_id":.integer(4)])])))
        XCTAssertTrue(model.posts.isEmpty);XCTAssertEqual(model.draft,"Keep unsent draft");XCTAssertEqual(model.selection,4);XCTAssertFalse(model.canAct(on:post))
        await model.historyTask?.value;XCTAssertTrue(model.posts.isEmpty)
    }
    func testOtherChannelArchiveDoesNotClearSelectedTimeline() async throws {
        let api = try await api(),model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false),source = try archive()
        model.connected = true;model.liveStatus = .live;model.channels = [source.props.channel];model.selection = 4
        defer { model.signOutLocally() }
        let post = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:ArchiveProtocol.post(20)));model.posts = [post]
        model.handleLiveEvent(.init(name:"client.channel.archive",payload:.object(["channel_id":.integer(99)])))
        XCTAssertEqual(model.posts.map(\.id),[20]);XCTAssertTrue(model.canAct(on:post))
    }
    func testDuplicateArchiveNamesAndIDsRejected() async throws {
        let api = try await api();ArchiveProtocol.names = ["x","x"]
        do { _ = try await api.archiveNames(kind:.anonymous);XCTFail("Duplicate name") } catch { }
        ArchiveProtocol.records = [ArchiveProtocol.record,ArchiveProtocol.record]
        do { _ = try await api.archives(kind:.private,name:"x");XCTFail("Duplicate archive ID") } catch { }
    }
    func testModelArchiveDeletionPreservesLiveDraftSelectionAndTimeline() async throws {
        let api = try await api(), model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false), source = try archive()
        model.connected = true; model.liveStatus = .live; model.selection = 93; model.draft = "Unsent live draft"
        model.archiveDeletions.activate(scope: String(repeating: "a", count: 64), ownerID: 10)
        defer { model.signOutLocally() }
        let preparation = try await model.prepareArchiveDeletion(source, kind: .private, name: "x")
        try await model.deleteArchive(preparation)
        XCTAssertEqual(ArchiveProtocol.calls.filter { $0["method"] == "delete" }.count, 1)
        XCTAssertEqual(model.selection, 93); XCTAssertEqual(model.draft, "Unsent live draft")
        XCTAssertTrue(model.posts.isEmpty); XCTAssertTrue(model.archiveDeletions.pending.isEmpty)
        XCTAssertEqual(ArchiveProtocol.calls.last?["method"], "list")
    }
    func testModelSignOutInvalidatesReviewedArchiveDeletionBeforeNetwork() async throws {
        let api = try await api(), model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false), source = try archive()
        model.connected = true
        model.archiveDeletions.activate(scope: String(repeating: "a", count: 64), ownerID: 10)
        let preparation = try await model.prepareArchiveDeletion(source, kind: .private, name: "x")
        let before = ArchiveProtocol.calls.count
        model.signOutLocally()
        do { try await model.deleteArchive(preparation); XCTFail("Retired account dispatched") } catch { }
        XCTAssertEqual(ArchiveProtocol.calls.count, before)
        XCTAssertTrue(model.archiveDeletions.pending.isEmpty)
    }
    func testModelAccountRetirementDuringFreshArchiveReadCannotDelete() async throws {
        let api = try await api(), model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false), source = try archive()
        model.connected = true
        model.archiveDeletions.activate(scope: String(repeating: "a", count: 64), ownerID: 10)
        let preparation = try await model.prepareArchiveDeletion(source, kind: .private, name: "x")
        ArchiveProtocol.observer = { _ in model.signOutLocally() }
        do { try await model.deleteArchive(preparation); XCTFail("Retired account dispatched") }
        catch is CancellationError { } catch { XCTFail("Expected account retirement cancellation") }
        XCTAssertFalse(ArchiveProtocol.calls.contains { $0["method"] == "delete" })
        XCTAssertTrue(model.archiveDeletions.pending.isEmpty)
    }
}
private final class ArchiveProtocol:URLProtocol {
    static let record:[String:Any] = ["archive_id":6,"post_start":1000,"post_end":2000,"post_id_start":0,"post_id_end":30,"props":["reason":"channel_closed","trigger_user_id":10,"channel":["channel_id":4,"name":"Old channel","purpose":"","type":"private","encrypted":false,"unread":0]]]
    static func post(_ id:Int64)->[String:Any] { ["post_id":id,"channel_id":4,"creator_id":10,"message":"Archived synthetic message","type":"text","create_at":1500] }
    static var names = ["Literal <archive> & name"],records = [record],posts = [post(10),post(20),post(30)]
    static var searchPosts = [post(10),post(20),post(30)]
    static var calls:[[String:String]] = []
    static var observer:((String)->Void)?
    static func reset() { names = ["Literal <archive> & name"];records = [record];posts = [post(10),post(20),post(30)];searchPosts = [post(10),post(20),post(30)];calls = [];observer = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Archive","SYNO.Chat.Post"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        var fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });fields["api"] = request.url!.lastPathComponent;Self.calls.append(fields)
        if fields["api"] == "SYNO.Chat.Archive", fields["method"] == "delete" {
            guard fields["archive_id"] == "6" else { finish(["success":false,"error":["code":404]]);return }
            Self.records = [];finish(["success":true]);return
        }
        let result:[String:Any]
        if fields["api"] == "SYNO.Chat.Post" {
            if fields["method"] == "search" { result = ["search_results":Self.searchPosts,"total":Self.searchPosts.count] }
            else if fields["prev_count"] == "0" && fields["next_count"] == "0" { result = ["posts":[Self.post(10)]] }
            else { result = ["posts":Self.posts] }
        } else { result = fields["method"] == "list_name" ? ["channel_names":Self.names] : ["archives":Self.records] }
        if let observer = Self.observer { DispatchQueue.main.async { observer(fields["api"] ?? "");self.finish(["success":true,"data":result]) } } else { finish(["success":true,"data":result]) }
    }
    func finish(_ object:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:object);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
