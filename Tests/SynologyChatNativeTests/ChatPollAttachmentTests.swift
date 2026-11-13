import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatPollAttachmentTests:XCTestCase {
    override func setUp() { super.setUp();PollAttachmentProtocol.reset() }
    override func tearDown() { PollAttachmentProtocol.observer = nil;PollAttachmentProtocol.held = nil;super.tearDown() }
    private func network()->URLSession { let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [PollAttachmentProtocol.self];return URLSession(configuration:c) }
    private func client() async throws -> ChatAPIClient {
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://poll-attachment.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network)
        try await api.discover();return api
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            func network()->URLSession { let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [PollAttachmentProtocol.self];return URLSession(configuration:c) }
            return try ChatAPIClient(session:session,network:network(),makeAttachmentNetwork:network)
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://poll-attachment.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 93
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    private func draft()->ChatPollDraft { var d = ChatPollDraft();d.question = "Synthetic attachment poll";d.choices = [.init(text:"Option A"),.init(text:"Option B")];return d }
    private func file() throws -> ChatPollLocalFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-poll-attachment-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("synthetic.txt");try Data("Synthetic file".utf8).write(to:url);return try ChatPollLocalFile(url)
    }
    private func nas() throws -> ChatNASFile { try JSONDecoder().decode(ChatNASFile.self,from:JSONSerialization.data(withJSONObject:PollAttachmentProtocol.file())) }
    func testMultipartPollFieldsAndBinaryBytesUseSingleVoteOperation() throws {
        let file = try file(),fields = try draft().multipartFields(channelID:93)
        XCTAssertEqual(fields["api"],"SYNO.Chat.Post.Vote");XCTAssertEqual(fields["version"],"1");XCTAssertEqual(fields["message"],draft().question)
        XCTAssertNil(fields["thread_id"]);XCTAssertNil(fields["type"]);XCTAssertNil(fields["ds_file"])
        let body = try ChatMultipartBody.write(file:file.url,fields:fields,boundary:"SyntheticPollBoundary",limitBytes:1000)
        defer { NativeSnippetTemporaryFiles.shared.remove(body) }
        let bytes = try Data(contentsOf:body),text = String(decoding:bytes,as:UTF8.self)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"synthetic.txt\""));XCTAssertTrue(text.contains("Synthetic file\r\n--SyntheticPollBoundary--"))
        XCTAssertTrue(text.contains("name=\"choices\""));XCTAssertTrue(text.contains("name=\"options\""));XCTAssertEqual(try Data(contentsOf:file.url),Data("Synthetic file".utf8))
    }
    func testLocalCreateUsesMultipartAndPublishesOnlyCanonicalAttachedPoll() async throws {
        let model = try await model(),file = try file(),draft = draft();model.pollDrafts[93] = draft;model.pollAttachments[93] = .local(file)
        let post = try await model.createPoll(draft,attachment:.local(file))
        XCTAssertEqual(post.type,"vote");XCTAssertEqual(post.file_props?.name,"synthetic.txt");XCTAssertEqual(post.file_props?.size,14)
        XCTAssertEqual(PollAttachmentProtocol.creates,1);XCTAssertEqual(PollAttachmentProtocol.ordinaryCreates,0);XCTAssertGreaterThan(PollAttachmentProtocol.postReads,0)
        XCTAssertEqual(PollAttachmentProtocol.routing?["api"],"SYNO.Chat.Post.Vote");XCTAssertEqual(PollAttachmentProtocol.routing?["version"],"1")
        XCTAssertTrue(PollAttachmentProtocol.uploadType?.hasPrefix("multipart/form-data; boundary=NativePoll-") == true);XCTAssertGreaterThan(PollAttachmentProtocol.uploadLength,14)
        XCTAssertTrue(String(decoding:PollAttachmentProtocol.uploadBody,as:UTF8.self).contains("Synthetic file"));XCTAssertNil(model.pollDrafts[93]);XCTAssertNil(model.pollAttachments[93]);XCTAssertEqual(model.selection,93);XCTAssertFalse(model.sending)
        XCTAssertEqual(try Data(contentsOf:file.url),Data("Synthetic file".utf8))
    }
    func testNASCreateUsesReviewedPathAndMetadataWithoutOrdinaryFilePost() async throws {
        let model = try await model(),file = try nas(),draft = draft()
        let post = try await model.createPoll(draft,attachment:.nas(file))
        XCTAssertEqual(post.file_props?.name,file.name);XCTAssertEqual(PollAttachmentProtocol.creates,1);XCTAssertEqual(PollAttachmentProtocol.ordinaryCreates,0)
        let path = try JSONDecoder().decode(String.self,from:Data(XCTUnwrap(PollAttachmentProtocol.lastFields?["ds_file"]).utf8))
        XCTAssertEqual(path,"/Synthetic/synthetic.txt");XCTAssertTrue(PollAttachmentProtocol.uploadType?.hasPrefix("application/x-www-form-urlencoded") == true);XCTAssertEqual(PollAttachmentProtocol.infoReads,1)
    }
    func testChangedOrOversizedLocalFileIsKnownUnsentAndDraftIsRetained() async throws {
        let model = try await model(),file = try file(),draft = draft();model.pollDrafts[93] = draft;model.pollAttachments[93] = .local(file)
        try Data("Changed file".utf8).write(to:file.url)
        do { _ = try await model.createPoll(draft,attachment:.local(file));XCTFail() } catch let failure as ChatPollCreationFailure { XCTAssertTrue(failure.knownUnsent) }
        XCTAssertEqual(PollAttachmentProtocol.creates,0);XCTAssertNotNil(model.pollDrafts[93]);XCTAssertNotNil(model.pollAttachments[93])
        let second = try self.file();PollAttachmentProtocol.limit = 0.000001
        do { _ = try await model.createPoll(draft,attachment:.local(second));XCTFail() } catch let failure as ChatPollCreationFailure { XCTAssertTrue(failure.knownUnsent) }
        XCTAssertEqual(PollAttachmentProtocol.creates,0)
    }
    func testNASPolicyPermissionAndMetadataChangesStopBeforeCreate() async throws {
        let model = try await model(),file = try nas(),draft = draft()
        for kind in 0..<3 {
            PollAttachmentProtocol.allowed = kind != 0;PollAttachmentProtocol.readable = kind != 1;PollAttachmentProtocol.modified = kind == 2 ? 2000 : 1000
            do { _ = try await model.createPoll(draft,attachment:.nas(file));XCTFail() } catch let failure as ChatPollCreationFailure { XCTAssertTrue(failure.knownUnsent) }
            XCTAssertEqual(PollAttachmentProtocol.creates,0)
        }
    }
    func testUnknownReceiptAndMalformedResponseNeverPublishOrClearDraft() async throws {
        let model = try await model(),file = try file(),draft = draft();model.pollDrafts[93] = draft;model.pollAttachments[93] = .local(file)
        for mode in ["wrong-receipt","html","missing-error","bad-canonical","read-error"] {
            PollAttachmentProtocol.mode = mode
            let before = PollAttachmentProtocol.creates
            do { _ = try await model.createPoll(draft,attachment:.local(file));XCTFail() } catch let failure as ChatPollCreationFailure { XCTAssertFalse(failure.knownUnsent) }
            XCTAssertEqual(PollAttachmentProtocol.creates,before+1);XCTAssertNotNil(model.pollDrafts[93]);XCTAssertNotNil(model.pollAttachments[93]);XCTAssertFalse(model.sending)
            XCTAssertFalse(model.posts.contains(where:{$0.id == 1001}))
        }
    }
    func testExplicitServerRejectionIsPreservedWithoutFollowupOrAutomaticRetry() async throws {
        let model = try await model(),file = try file();PollAttachmentProtocol.mode = "rejected";let before = PollAttachmentProtocol.postReads
        do { _ = try await model.createPoll(draft(),attachment:.local(file));XCTFail() } catch ChatAPIError.server(407) { }
        XCTAssertEqual(PollAttachmentProtocol.creates,1);XCTAssertEqual(PollAttachmentProtocol.postReads,before)
    }
    func testSignOutDuringNASPreflightCannotCreateAndLateCreateCannotReadNewAccount() async throws {
        let model = try await model(),nas = try nas(),file = try file(),draft = draft()
        PollAttachmentProtocol.observer = { api,method in if api == "SYNO.FileStation.List" { model.signOutLocally() } }
        do { _ = try await model.createPoll(draft,attachment:.nas(nas));XCTFail() } catch let failure as ChatPollCreationFailure { XCTAssertTrue(failure.knownUnsent) }
        XCTAssertEqual(PollAttachmentProtocol.creates,0)
        PollAttachmentProtocol.observer = nil;let second = try await self.model()
        PollAttachmentProtocol.observer = { api,method in if api == "SYNO.Chat.Post.Vote",method == "create" { second.signOutLocally() } }
        let before = PollAttachmentProtocol.postReads
        do { _ = try await second.createPoll(draft,attachment:.local(file));XCTFail() } catch let failure as ChatPollCreationFailure { XCTAssertFalse(failure.knownUnsent) }
        XCTAssertEqual(PollAttachmentProtocol.creates,1);XCTAssertEqual(PollAttachmentProtocol.postReads,before);XCTAssertTrue(second.posts.isEmpty)
    }
    func testPollAttachmentsOfferDocumentPreviewAndIsolatedImageGallery() async throws {
        let model = try await model();let post = try PollAttachmentProtocol.decodedPost();model.posts = [post]
        XCTAssertTrue(model.canPreviewDocument(post))
        PollAttachmentProtocol.image = true;let image = try PollAttachmentProtocol.decodedPost();model.posts = [image];model.openPollImage(image)
        XCTAssertEqual(model.imageViewerPost?.id,image.id);XCTAssertEqual(model.imageViewerCount,1);XCTAssertFalse(model.canViewPreviousImage);XCTAssertFalse(model.canViewNextImage)
        model.closeImageViewer();model.signOutLocally();model.openPollImage(image);XCTAssertNil(model.imageViewerPost)
    }
    func testFreshChannelScopeChangesPreventAnyPollCreate() async throws {
        let model = try await model(),file = try file()
        for values:[String:Any] in [["encrypted":true],["is_joined":false],["is_closed":true],["hide_global_at":1000],["type":"anonymous"]] {
            PollAttachmentProtocol.channelOverrides = values
            do { _ = try await model.createPoll(draft(),attachment:.local(file));XCTFail() } catch let failure as ChatPollCreationFailure { XCTAssertTrue(failure.knownUnsent) }
            XCTAssertEqual(PollAttachmentProtocol.creates,0)
        }
    }
    func testPollPreviewOwnershipReleasesOnlyItsOwnViewerAndResetsOnSignOut() async throws {
        let model = try await model(),owner = UUID(),other = UUID()
        PollAttachmentProtocol.image = true;let post = try PollAttachmentProtocol.decodedPost();model.posts = [post]
        model.pollAttachmentOwner = owner;model.openPollImage(post)
        model.releasePollAttachmentPresentation(other)
        XCTAssertEqual(model.pollAttachmentOwner,owner);XCTAssertEqual(model.imageViewerPost?.id,post.id)
        model.pollAttachmentOwner = other;model.releasePollAttachmentPresentation(owner)
        XCTAssertEqual(model.pollAttachmentOwner,other);XCTAssertEqual(model.imageViewerPost?.id,post.id)
        model.releasePollAttachmentPresentation(other)
        XCTAssertNil(model.pollAttachmentOwner);XCTAssertNil(model.imageViewerPost);XCTAssertNil(model.imageViewerTask)
        model.pollAttachmentOwner = owner;model.pollAttachments[93] = .local(try file());model.signOutLocally()
        XCTAssertNil(model.pollAttachmentOwner);XCTAssertTrue(model.pollAttachments.isEmpty)
    }
}

private final class PollAttachmentProtocol:URLProtocol {
    static var creates = 0,ordinaryCreates = 0,postReads = 0,infoReads = 0,modified = 1000,uploadLength = 0
    static var allowed = true,readable = true,image = false,limit = 0.0,mode = ""
    static var uploadBody = Data()
    static var channelOverrides:[String:Any] = [:]
    static var lastFields:[String:String]?,routing:[String:String]?,uploadType:String?,held:PollAttachmentProtocol?
    static var observer:((String,String)->Void)?
    static func reset() { creates = 0;ordinaryCreates = 0;postReads = 0;infoReads = 0;modified = 1000;uploadLength = 0;uploadBody = Data();channelOverrides = [:];allowed = true;readable = true;image = false;limit = 0;mode = "";lastFields = nil;routing = nil;uploadType = nil;held = nil;observer = nil }
    static func file()->[String:Any] { ["path":"/Synthetic/synthetic.txt","name":"synthetic.txt","isdir":false,"additional":["size":14,"time":["mtime":modified,"ctime":1000],"perm":["acl":["read":readable]],"type":"txt"]] }
    static func post(canonical:Bool = false)->[String:Any] { ["post_id":1001,"channel_id":mode == "wrong-receipt" ? 94 : 93,"creator_id":10,"type":"vote","message":"Synthetic attachment poll","create_at":1000,"file_props":["name":mode == "bad-canonical" && canonical ? "changed.txt" : (image ? "synthetic.png" : "synthetic.txt"),"size":14,"is_image":image],"props":["vote":["state":"open","options":["multiple":false,"anonymous":false,"add_option":false,"expire_at":0],"choices":[["id":"a","text":"Option A","count":0,"voters":[]],["id":"b","text":"Option B","count":0,"voters":[]]]]]] }
    static func decodedPost() throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:post())) }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "poll-attachment.invalid",request.url?.scheme == "https" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buf = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&buf,maxLength:buf.count);if n <= 0 { break };bytes.append(contentsOf:buf.prefix(n)) } }
        var parts = URLComponents();if request.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("multipart/form-data") != true { parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self) }
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        DispatchQueue.main.async { self.route(fields,body:bytes) }
    }
    @MainActor private func route(_ fields:[String:String],body:Data) {
        let api = request.url!.lastPathComponent,isUpload = request.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("multipart/form-data") == true
        let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
        let routing = Dictionary(query.map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),method = isUpload ? routing["method"] ?? "" : fields["method"] ?? ""
        if api == "SYNO.API.Info" { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Post.Vote","SYNO.Chat.Post","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Admin.Setting","SYNO.FileStation.List"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        Self.observer?(api,method)
        switch (api,method) {
        case ("SYNO.Chat.User","list"):finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Synthetic","type":"human","human_type":"dsm"]]]])
        case ("SYNO.Chat.Channel","list"):
            var channel:[String:Any] = ["channel_id":93,"name":"Synthetic","type":"public","encrypted":false,"is_joined":true,"unread":0]
            channel.merge(Self.channelOverrides,uniquingKeysWith:{ _,new in new });finish(["success":true,"data":["channels":[channel]]])
        case ("SYNO.Chat.Admin.Setting",_):finish(["success":true,"data":["allow_ds_upload":Self.allowed,"file_size_limit":Self.limit,"hide_post_url_preview":true]])
        case ("SYNO.FileStation.List","getinfo"):Self.infoReads += 1;finish(["success":true,"data":["files":[Self.file()]]])
        case ("SYNO.Chat.Post.Vote","create"):
            Self.creates += 1;Self.uploadBody = body;Self.lastFields = fields;Self.routing = routing;Self.uploadType = request.value(forHTTPHeaderField:"Content-Type");Self.uploadLength = Int(request.value(forHTTPHeaderField:"Content-Length") ?? "0") ?? 0
            if Self.mode == "html" { raw(Data("<html>Sign in</html>".utf8));return }
            if Self.mode == "missing-error" { finish(["success":false]);return }
            if Self.mode == "rejected" { finish(["success":false,"error":["code":407]]);return }
            finish(["success":true,"data":Self.post()])
        case ("SYNO.Chat.Post","create"):Self.ordinaryCreates += 1;finish(["success":false,"error":["code":400]])
        case ("SYNO.Chat.Post","list"):Self.postReads += 1;if Self.mode == "read-error" { finish(["success":false,"error":["code":119]]);return };finish(["success":true,"data":["posts":fields["post_id"] == nil ? [] : [Self.post(canonical:true)]]])
        default:finish(["success":false,"error":["code":400]])
        }
    }
    func finish(_ object:Any) { raw(try! JSONSerialization.data(withJSONObject:object)) }
    private func raw(_ bytes:Data) { client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
