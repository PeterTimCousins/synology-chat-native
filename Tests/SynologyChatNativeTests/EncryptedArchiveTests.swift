import XCTest
@testable import SynologyChatNative

@MainActor final class EncryptedArchiveTests:XCTestCase {
    private struct Fixture:Decodable {
        let password,publicKey,wrappedPrivateKey,wrappedChannelKey,message,encryptedMessage,filename,encryptedFilename,attachment,encryptedAttachment:String
    }
    private func setup() async throws -> (NativeChatPreviewModel,ChatArchive,ChatPost,Fixture) {
        let f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"ChatCrypto",withExtension:"json",subdirectory:"Fixtures"))))
        ArchiveCryptoProtocol.record = ["archive_id":6,"post_start":1000,"post_end":2000,"post_id_start":1,"post_id_end":30,"props":["reason":"channel_closed","trigger_user_id":10,"channel":["channel_id":23,"name":"Synthetic","type":"private","encrypted":true,"unread":0,"channel_key_enc":f.wrappedChannelKey]]]
        ArchiveCryptoProtocol.post = ["post_id":20,"channel_id":23,"creator_id":10,"message":f.encryptedMessage,"type":"file","create_at":1500,"file_props":["name":f.encryptedFilename,"size":296,"is_image":true],"props":["encrypted":true]]
        ArchiveCryptoProtocol.payload = try ChatContentCrypto.decodeBase64(f.encryptedAttachment)
        ArchiveCryptoProtocol.fields = [];ArchiveCryptoProtocol.posts = nil;ArchiveCryptoProtocol.onFile = nil;ArchiveCryptoProtocol.onArchive = nil
        func network()->URLSession { let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ArchiveCryptoProtocol.self];return URLSession(configuration:c) }
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://archive-crypto.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network)
        try await api.discover()
        let keys = ChatEncryptionSession();try keys.unlock(.init(public_key:f.publicKey,private_key_enc:f.wrappedPrivateKey),password:f.password)
        let m = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,encryption:keys);m.connected = true;m.selection = 93;m.draft = "Keep ordinary draft"
        addTeardownBlock { @MainActor in m.signOutLocally();ArchiveCryptoProtocol.onFile = nil;ArchiveCryptoProtocol.onArchive = nil }
        return (m,try decode(ChatArchive.self,ArchiveCryptoProtocol.record),try decode(ChatPost.self,ArchiveCryptoProtocol.post),f)
    }
    private func decode<T:Decodable>(_ type:T.Type,_ value:[String:Any]) throws -> T { try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value)) }
    private func directory() throws -> URL {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-archive-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:p,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:p) };return p
    }
    func testArchiveLocalDecryptionDoesNotRequireLiveChannelAndLocksWithoutCiphertextFallback() async throws {
        let(m,a,p,f) = try await setup()
        XCTAssertTrue(m.channels.isEmpty);XCTAssertTrue(m.canReadArchive(a))
        XCTAssertEqual(m.archiveMessageText(p,archive:a),f.message);XCTAssertEqual(m.archiveFilename(p,archive:a),f.filename)
        m.channels = [try decode(ChatChannel.self,["channel_id":23,"name":"Different live key","type":"private","encrypted":true,"unread":0,"channel_key_enc":"unusable live key"])]
        XCTAssertFalse(m.canRead(23));XCTAssertEqual(m.archiveMessageText(p,archive:a),f.message)
        XCTAssertTrue(m.canOpenArchiveAttachment(p,archive:a))
        m.lockEncryption(reload:false)
        XCTAssertFalse(m.canReadArchive(a));XCTAssertFalse(m.canOpenArchiveAttachment(p,archive:a))
        XCTAssertFalse(m.archiveMessageText(p,archive:a).contains(f.encryptedMessage))
        XCTAssertEqual(m.archiveFilename(p,archive:a),"Encrypted attachment")
    }
    func testArchivePostsAndSearchUseArchivedScopeWithoutTouchingLiveDraft() async throws {
        let(m,a,p,f) = try await setup()
        let posts = try await m.loadArchivePosts(kind:.private,name:"Synthetic",archive:a)
        XCTAssertEqual(posts.map(\.id),[p.id]);XCTAssertEqual(m.archiveMessageText(posts[0],archive:a),f.message)
        let found = try await m.searchArchivedMessages(kind:.private,name:"Synthetic",scopes:[a],query:"",collection:.files)
        XCTAssertEqual(found.matches.count,1);XCTAssertEqual(m.archiveFilename(found.matches[0].post,archive:a),f.filename)
        XCTAssertEqual(m.selection,93);XCTAssertEqual(m.draft,"Keep ordinary draft");XCTAssertTrue(m.posts.isEmpty)
        XCTAssertTrue(ArchiveCryptoProtocol.fields.contains { $0["archives"] == "[6]" })
    }
    func testArchivedThreadUsesHistoricalScopeForRootAndReplies() async throws {
        let(m,a,_,f) = try await setup()
        var root = ArchiveCryptoProtocol.post,reply = ArchiveCryptoProtocol.post
        root["post_id"] = 5;root["type"] = "normal";root.removeValue(forKey:"file_props")
        reply["thread_id"] = 5
        ArchiveCryptoProtocol.posts = [root,reply]
        let replies = try await m.loadArchivePosts(kind:.private,name:"Synthetic",archive:a,threadID:5)
        XCTAssertEqual(replies.map(\.id),[20]);XCTAssertEqual(m.archiveMessageText(replies[0],archive:a),f.message)
        let post = try decode(ChatPost.self,reply)
        let context = try await m.archivedMessageContext(kind:.private,name:"Synthetic",match:.init(archive:a,post:post))
        XCTAssertEqual(context.root?.id,5);XCTAssertEqual(context.posts.map(\.id),[20])
        XCTAssertTrue(ArchiveCryptoProtocol.fields.contains { $0["thread_id"] == "5" && $0["archive_id"] == "6" })
    }
    func testLockDuringFreshArchiveLookupPreventsSubsequentPostDispatch() async throws {
        let(m,a,_,_) = try await setup()
        ArchiveCryptoProtocol.onArchive = { m.lockEncryption(reload:false) }
        do { _ = try await m.loadArchivePosts(kind:.private,name:"Synthetic",archive:a);XCTFail("Lock ignored") } catch { }
        XCTAssertTrue(ArchiveCryptoProtocol.fields.allSatisfy { $0["api"] == "SYNO.Chat.Archive" })
    }
    func testArchivePreviewDecryptsExistingFileRouteAndRejectsLockBeforePublishing() async throws {
        let(m,a,p,f) = try await setup()
        let bytes = try await m.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:a,post:p,maximumBytes:512,expectedAccount:m.accountGeneration)
        XCTAssertEqual(bytes,try ChatContentCrypto.decodeBase64(f.attachment))
        let file = try XCTUnwrap(ArchiveCryptoProtocol.fields.first { $0["api"] == "SYNO.Chat.Post.File" })
        XCTAssertEqual(file["post_id"],"20");XCTAssertNil(file["archive_id"])
        ArchiveCryptoProtocol.onFile = { m.lockEncryption(reload:false) }
        do { _ = try await m.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:a,post:p,maximumBytes:512,expectedAccount:m.accountGeneration);XCTFail("Locked preview published") } catch { }
    }
    func testEncryptedSaveAndOpenUseArchiveKeyAndLockRetiresReceiptActions() async throws {
        let(m,a,p,f) = try await setup(),folder = try directory(),destination = folder.appendingPathComponent("saved.png")
        try await m.saveArchivedAttachment(kind:.private,name:"Synthetic",archive:a,post:p,to:destination,expectedAccount:m.accountGeneration)
        XCTAssertEqual(try Data(contentsOf:destination),try ChatContentCrypto.decodeBase64(f.attachment))
        let record = try XCTUnwrap(m.downloadHistory.first);XCTAssertTrue(record.encrypted);XCTAssertTrue(m.canUseSavedDownload(record));XCTAssertFalse(m.downloadIsLocked(record));XCTAssertEqual(m.downloadName(record),destination.lastPathComponent)
        var opened = false
        await m.openDownload(record.id,opener:{ _ in opened = true;return true },confirmOpening:{ _ in .open })
        XCTAssertTrue(opened)
        m.lockEncryption(reload:false);XCTAssertFalse(m.canUseSavedDownload(record));XCTAssertTrue(m.downloadIsLocked(record));XCTAssertEqual(m.downloadName(record),"Encrypted attachment")
        XCTAssertTrue(FileManager.default.fileExists(atPath:destination.path))
    }
    func testLockRetiresEncryptedRetryBeforeDestinationChoiceCanResume() async throws {
        let(m,a,p,_) = try await setup(),folder = try directory(),destination = folder.appendingPathComponent("preserved.txt")
        let old = Data("Original destination".utf8);try old.write(to:destination)
        ArchiveCryptoProtocol.payload = Data("Invalid encrypted file".utf8)
        do { try await m.saveArchivedAttachment(kind:.private,name:"Synthetic",archive:a,post:p,to:destination,expectedAccount:m.accountGeneration);XCTFail("Malformed file saved") } catch { }
        let failed = try XCTUnwrap(m.downloadHistory.first)
        XCTAssertTrue(m.canRetryDownload(failed))
        let requests = ArchiveCryptoProtocol.fields.count
        await m.retryDownload(failed.id,chooseDestination:{ _ in
            XCTAssertEqual(m.downloadHistory.first?.state,.choosing)
            m.lockEncryption(reload:false)
            XCTAssertEqual(m.downloadHistory.first?.state,.cancelled)
            return destination
        })
        XCTAssertEqual(ArchiveCryptoProtocol.fields.count,requests)
        XCTAssertEqual(try Data(contentsOf:destination),old)
    }
    func testEnvelopeReplacementRejectsReadAndSaveWithoutOverwritingDestination() async throws {
        let(m,a,p,_) = try await setup(),folder = try directory(),destination = folder.appendingPathComponent("preserved.txt")
        let old = Data("Original destination".utf8);try old.write(to:destination)
        var props = ArchiveCryptoProtocol.record["props"] as! [String:Any],channel = props["channel"] as! [String:Any]
        channel["channel_key_enc"] = "changed envelope";props["channel"] = channel;ArchiveCryptoProtocol.record["props"] = props
        do { _ = try await m.loadArchivePosts(kind:.private,name:"Synthetic",archive:a);XCTFail("Stale envelope read") } catch { }
        do { try await m.saveArchivedAttachment(kind:.private,name:"Synthetic",archive:a,post:p,to:destination,expectedAccount:m.accountGeneration);XCTFail("Stale envelope save") } catch { }
        XCTAssertEqual(try Data(contentsOf:destination),old)
        XCTAssertFalse(ArchiveCryptoProtocol.fields.contains { $0["api"] == "SYNO.Chat.Post.File" })
    }
    func testLockDuringSavePreservesDestinationAndLockedArchiveCannotDispatchFile() async throws {
        let(m,a,p,_) = try await setup(),folder = try directory(),destination = folder.appendingPathComponent("preserved.txt")
        let old = Data("Original destination".utf8);try old.write(to:destination)
        ArchiveCryptoProtocol.onFile = { m.lockEncryption(reload:false) }
        do { try await m.saveArchivedAttachment(kind:.private,name:"Synthetic",archive:a,post:p,to:destination,expectedAccount:m.accountGeneration);XCTFail("Locked save committed") } catch { }
        XCTAssertEqual(try Data(contentsOf:destination),old)
        let count = ArchiveCryptoProtocol.fields.count
        do { _ = try await m.archivedAttachmentPreview(kind:.private,name:"Synthetic",archive:a,post:p,maximumBytes:512,expectedAccount:m.accountGeneration);XCTFail("Locked file dispatched") } catch { }
        XCTAssertEqual(ArchiveCryptoProtocol.fields.count,count)
    }
}

private final class ArchiveCryptoProtocol:URLProtocol {
    static var record:[String:Any] = [:],post:[String:Any] = [:],payload = Data(),fields:[[String:String]] = []
    static var posts:[[String:Any]]?
    static var onFile:(()->Void)?,onArchive:(()->Void)?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") {
            json(Dictionary(uniqueKeysWithValues:["SYNO.Chat.Archive","SYNO.Chat.Post","SYNO.Chat.Post.File"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) }));return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 {break};data.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let f = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{_,last in last})
        Self.fields.append(f)
        DispatchQueue.main.async {
            switch self.request.url!.lastPathComponent {
            case "SYNO.Chat.Archive": Self.onArchive?();self.json(["archives":[Self.record]])
            case "SYNO.Chat.Post.File":Self.onFile?();self.respond(Self.payload,headers:["Content-Type":"application/octet-stream","Content-Disposition":"attachment; filename=encrypted"])
            default:
                var posts = Self.posts ?? [Self.post]
                if f["prev_count"] == "0",f["next_count"] == "0",let id = f["post_id"].flatMap(Int64.init) { posts = posts.filter { ($0["post_id"] as? Int64 ?? Int64($0["post_id"] as? Int ?? 0)) == id } }
                self.json(f["method"] == "search" ? ["search_results":posts,"total":posts.count] : ["posts":posts])
            }
        }
    }
    private func json(_ data:[String:Any]) { respond(try! JSONSerialization.data(withJSONObject:["success":true,"data":data]),headers:["Content-Type":"application/json"]) }
    private func respond(_ data:Data,headers:[String:String]) { client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
