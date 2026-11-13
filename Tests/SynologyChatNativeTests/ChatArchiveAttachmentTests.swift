import XCTest
@testable import SynologyChatNative

@MainActor final class ChatArchiveAttachmentTests:XCTestCase {
    override func setUp() { super.setUp();ArchiveFileProtocol.reset() }
    override func tearDown() { ArchiveFileProtocol.onFile = nil;ArchiveFileProtocol.onStop = nil;super.tearDown() }
    private func model() async throws -> NativeChatPreviewModel {
        func network()->URLSession { let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ArchiveFileProtocol.self];return URLSession(configuration:c) }
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://archive-file.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network);try await api.discover()
        let value = NativeChatPreviewModel(client:api,restoreNotificationPreference:false);value.connected = true;value.selection = 93;value.draft = "Keep live draft"
        addTeardownBlock { @MainActor in value.signOutLocally() };return value
    }
    private func source() throws -> ChatArchive { try JSONDecoder().decode(ChatArchive.self,from:JSONSerialization.data(withJSONObject:ArchiveFileProtocol.record)) }
    private func post(_ mutate:((inout [String:Any])->Void)? = nil) throws -> ChatPost { var p = ArchiveFileProtocol.post;mutate?(&p);return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:p)) }
    private func folder() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false);addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url }
    func testArchiveAttachmentPolicyRejectsDeletedEncryptedAndNonFilePosts() throws {
        XCTAssertTrue(try post().supportsArchiveAttachment)
        for value in [try post { $0["delete_at"] = 10 },try post { $0["props"] = ["encrypted":true] },try post { $0["type"] = "normal" },try post { $0.removeValue(forKey:"file_props") }] { XCTAssertFalse(value.supportsArchiveAttachment) }
        let traversal = try post { $0["file_props"] = ["name":"../../test.txt","size":1,"is_image":false] };XCTAssertEqual(traversal.archiveFilename,"test.txt")
    }
    func testArchivePreviewRevalidatesSourceAndKeepsLiveTimelineAndDraft() async throws {
        let model = try await model(),archive = try source(),post = try post()
        let bytes = try await model.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:archive,post:post,maximumBytes:1024,expectedAccount:model.accountGeneration)
        XCTAssertEqual(bytes,ArchiveFileProtocol.payload);XCTAssertEqual(model.selection,93);XCTAssertEqual(model.draft,"Keep live draft");XCTAssertTrue(model.posts.isEmpty)
        XCTAssertEqual(ArchiveFileProtocol.files,1);XCTAssertEqual(ArchiveFileProtocol.archiveReads,2)
        XCTAssertEqual(ArchiveFileProtocol.fileFields["post_id"],"20");XCTAssertEqual(ArchiveFileProtocol.fileFields["method"],"get");XCTAssertEqual(ArchiveFileProtocol.fileFields["version"],"2")
        XCTAssertNil(ArchiveFileProtocol.fileFields["archive_id"])
    }
    func testOversizedArchiveMetadataPreventsDownload() async throws {
        let model = try await model(),archive = try source();ArchiveFileProtocol.post["file_props"] = ["name":"synthetic.txt","size":5000,"is_image":false]
        do { _ = try await model.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:archive,post:try post(),maximumBytes:100,expectedAccount:model.accountGeneration);XCTFail("Oversized preview") } catch { }
        XCTAssertEqual(ArchiveFileProtocol.files,0)
    }
    func testChangedOrMissingCanonicalAttachmentPreventsDownload() async throws {
        let model = try await model(),archive = try source(),old = try post();ArchiveFileProtocol.post["file_props"] = ["name":"changed.txt","size":ArchiveFileProtocol.payload.count,"is_image":false]
        do { _ = try await model.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:archive,post:old,maximumBytes:1024,expectedAccount:model.accountGeneration);XCTFail("Stale file") } catch { }
        ArchiveFileProtocol.missingPost = true
        do { _ = try await model.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:archive,post:old,maximumBytes:1024,expectedAccount:model.accountGeneration);XCTFail("Missing file") } catch { }
        XCTAssertEqual(ArchiveFileProtocol.files,0)
    }
    func testStaleAccountAndUnavailableArchivePreventFileRequest() async throws {
        let model = try await model(),archive = try source(),post = try post()
        do { _ = try await model.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:archive,post:post,maximumBytes:1024,expectedAccount:model.accountGeneration - 1);XCTFail("Old account") } catch { }
        XCTAssertEqual(ArchiveFileProtocol.archiveReads,0)
        ArchiveFileProtocol.available = false
        do { _ = try await model.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:archive,post:post,maximumBytes:1024,expectedAccount:model.accountGeneration);XCTFail("Missing archive") } catch { }
        XCTAssertEqual(ArchiveFileProtocol.files,0)
    }
    func testSaveCommitsOriginalAfterFreshReadbackAndPreservesLiveState() async throws {
        let model = try await model(),archive = try source(),post = try post(),root = try folder(),destination = root.appendingPathComponent("saved.txt")
        try Data("old".utf8).write(to:destination)
        try await model.saveArchivedAttachment(kind:.private,name:"Synthetic",archive:archive,post:post,to:destination,expectedAccount:model.accountGeneration)
        XCTAssertEqual(try Data(contentsOf:destination),ArchiveFileProtocol.payload);XCTAssertEqual(ArchiveFileProtocol.archiveReads,2)
        let receipt = try XCTUnwrap(model.downloadHistory.first);XCTAssertEqual(receipt.state,.saved);XCTAssertEqual(receipt.filename,"saved.txt");XCTAssertEqual(receipt.fileBytes,Int64(ArchiveFileProtocol.payload.count));XCTAssertEqual(model.downloadPreferences.lastFolder?.path,root.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["saved.txt"]);XCTAssertEqual(model.selection,93);XCTAssertEqual(model.draft,"Keep live draft")
    }
    func testArchiveDisappearingDuringDownloadPreservesDestinationAndCleansStaging() async throws {
        let model = try await model(),archive = try source(),post = try post(),root = try folder(),destination = root.appendingPathComponent("saved.txt"),old = Data("Keep existing".utf8)
        try old.write(to:destination);ArchiveFileProtocol.onFile = { ArchiveFileProtocol.available = false }
        do { try await model.saveArchivedAttachment(kind:.private,name:"Synthetic",archive:archive,post:post,to:destination,expectedAccount:model.accountGeneration);XCTFail("Missing archive committed") } catch { }
        XCTAssertEqual(try Data(contentsOf:destination),old);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["saved.txt"])
    }
    func testSignOutDuringFileRetrievalCannotCommitDestination() async throws {
        let model = try await model(),archive = try source(),post = try post(),root = try folder(),destination = root.appendingPathComponent("saved.txt"),old = Data("Keep existing".utf8),expected = model.accountGeneration
        try old.write(to:destination);ArchiveFileProtocol.onFile = { model.signOutLocally() }
        do { try await model.saveArchivedAttachment(kind:.private,name:"Synthetic",archive:archive,post:post,to:destination,expectedAccount:expected);XCTFail("Signed-out save committed") } catch { }
        XCTAssertEqual(try Data(contentsOf:destination),old);XCTAssertEqual(ArchiveFileProtocol.archiveReads,1);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["saved.txt"])
    }
    func testPreviewRejectsDisappearedSourceAfterBytesArrive() async throws {
        let model = try await model(),archive = try source(),post = try post();ArchiveFileProtocol.onFile = { ArchiveFileProtocol.available = false }
        do { _ = try await model.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:archive,post:post,maximumBytes:1024,expectedAccount:model.accountGeneration);XCTFail("Invalidated preview published") } catch { }
        XCTAssertEqual(ArchiveFileProtocol.files,1)
    }
    func testCancelledSaveStopsDownloadAndPreservesExistingFile() async throws {
        let model = try await model(),archive = try source(),post = try post(),root = try folder(),destination = root.appendingPathComponent("saved.txt"),old = Data("Keep existing".utf8)
        try old.write(to:destination);let started = expectation(description:"Download started"),stopped = expectation(description:"Download stopped")
        ArchiveFileProtocol.stall = true;ArchiveFileProtocol.onFile = { started.fulfill() };ArchiveFileProtocol.onStop = { stopped.fulfill() }
        let task = Task { try await model.saveArchivedAttachment(kind:.private,name:"Synthetic",archive:archive,post:post,to:destination,expectedAccount:model.accountGeneration) }
        await fulfillment(of:[started],timeout:3);task.cancel()
        do { try await task.value;XCTFail("Cancelled save succeeded") } catch { }
        await fulfillment(of:[stopped],timeout:3)
        XCTAssertEqual(try Data(contentsOf:destination),old);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["saved.txt"])
    }
}
private final class ArchiveFileProtocol:URLProtocol {
    static let record:[String:Any] = ["archive_id":6,"post_start":1000,"post_end":2000,"post_id_start":0,"post_id_end":30,"props":["reason":"channel_closed","trigger_user_id":10,"channel":["channel_id":4,"name":"Synthetic","type":"private","encrypted":false,"unread":0]]]
    static var payload = Data("Synthetic archived attachment\n".utf8)
    static var post:[String:Any] = [:]
    static var available = true,missingPost = false,stall = false
    static var files = 0,archiveReads = 0
    static var fileFields:[String:String] = [:]
    static var onFile:(()->Void)?,onStop:(()->Void)?
    private var isFile = false
    static func reset() { available = true;missingPost = false;stall = false;files = 0;archiveReads = 0;fileFields = [:];onFile = nil;onStop = nil;post = ["post_id":20,"channel_id":4,"creator_id":10,"message":"Synthetic","type":"file","create_at":1500,"file_props":["name":"synthetic.txt","size":payload.count,"is_image":false]] }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Archive","SYNO.Chat.Post","SYNO.Chat.Post.File"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),api = request.url!.lastPathComponent
        if api == "SYNO.Chat.Post.File" {
            isFile = true;Self.files += 1;Self.fileFields = fields
            DispatchQueue.main.async { Self.onFile?();if !Self.stall { self.respond(Self.payload,headers:["Content-Type":"application/octet-stream","Content-Disposition":"attachment; filename=synthetic.txt"]) } };return
        }
        if api == "SYNO.Chat.Archive" { Self.archiveReads += 1;finish(["success":true,"data":["archives":Self.available ? [Self.record] : []]]);return }
        finish(["success":true,"data":["posts":Self.missingPost ? [] : [Self.post]]])
    }
    func finish(_ object:[String:Any]) { respond(try! JSONSerialization.data(withJSONObject:object),headers:["Content-Type":"application/json"]) }
    func respond(_ data:Data,headers:[String:String]) { client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { if isFile { DispatchQueue.main.async { Self.onStop?() } } }
}
