import XCTest
@testable import SynologyChatNative

@MainActor final class ChatNASFilesTests:XCTestCase {
    override func setUp() {super.setUp();NASProtocol.reset()}
    private func model() async throws -> NativeChatPreviewModel {
        let m = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{session in let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [NASProtocol.self];return try ChatAPIClient(session:session,network:URLSession(configuration:c))})
        await m.connect(using:.init(session:.init(baseURL:URL(string:"https://nas.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        m.selection = 93;m.liveStatus = .live;XCTAssertTrue(m.connected);addTeardownBlock {@MainActor in m.signOutLocally()};return m
    }
    private func file() throws -> ChatNASFile {try JSONDecoder().decode(ChatNASFile.self,from:JSONSerialization.data(withJSONObject:NASProtocol.file()))}
    private func batch(_ file:ChatNASFile,root:Int64? = nil)->NativeAttachmentBatch {let b = NativeAttachmentBatch(files:[],caption:"Synthetic caption",channelID:93,channelTitle:"Peter",rootID:root,encrypted:false,keyEnvelope:nil);b.appendNAS([file]);return b}
    func testRootFolderPageAndFreshSendUseNASPathWithoutLocalUpload() async throws {
        let m = try await model(),f = try file(),b = batch(f),epoch = m.accountGeneration
        let roots = try await m.loadNASRoots(channelID:93,rootID:nil,epoch:epoch);XCTAssertEqual(roots.map(\.spath),["/Synthetic"])
        let page = try await m.loadNASFiles(folder:"/Synthetic",offset:0,channelID:93,rootID:nil,epoch:epoch);XCTAssertEqual(page.files.count,1)
        m.sending = true
        let post = try await m.sendReviewedNASFile(f,batch:b,caption:"Synthetic caption",connectionID:"synthetic",epoch:epoch)
        XCTAssertEqual(post.type,"file");XCTAssertEqual(post.file_props?.name,"synthetic.txt");XCTAssertEqual(NASProtocol.writes,1)
        XCTAssertEqual(try JSONDecoder().decode(String.self,from:Data(NASProtocol.lastWrite!["ds_file"]!.utf8)),"/Synthetic/synthetic.txt");XCTAssertEqual(NASProtocol.lastWrite?["version"],"5");XCTAssertEqual(NASProtocol.lastWrite?["is_thread"],"false");XCTAssertNil(NASProtocol.lastWrite?["file"])
        XCTAssertEqual(NASProtocol.metadataReads,1);XCTAssertEqual(NASProtocol.channelReads,2)
    }
    func testNASSelectionDeduplicatesAndRetainsTypedSourceCaption() async throws {
        let m = try await model(),f = try file();m.draft = "Original caption"
        m.stageNASFiles(.init(files:[f,f],channelID:93,rootID:nil,accountGeneration:m.accountGeneration))
        let b = try XCTUnwrap(m.attachmentBatch);XCTAssertEqual(b.items.count,1);XCTAssertEqual(b.items[0].displayName,"synthetic.txt");XCTAssertNil(b.items[0].localFile);XCTAssertNotNil(b.items[0].nasFile);XCTAssertEqual(b.items[0].caption,"Original caption");XCTAssertEqual(m.draft,"Original caption")
        b.append([URL(fileURLWithPath:"/private/tmp/synthetic-local.txt")]);XCTAssertEqual(b.items.count,2);XCTAssertNotNil(b.items[1].localFile)
    }
    func testGuestEncryptedAndOldContextCannotStage() async throws {
        let m = try await model(),f = try file(),epoch = m.accountGeneration
        m.stageNASFiles(.init(files:[f],channelID:94,rootID:nil,accountGeneration:epoch));XCTAssertNil(m.attachmentBatch)
        NASProtocol.guest = true;try await m.refreshUserProfiles();XCTAssertFalse(m.canChooseNASFiles())
        m.stageNASFiles(.init(files:[f],channelID:93,rootID:nil,accountGeneration:epoch));XCTAssertNil(m.attachmentBatch)
        NASProtocol.guest = false;try await m.refreshUserProfiles();m.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":true,"unread":0}"#.utf8))]
        XCTAssertFalse(m.canChooseNASFiles());m.stageNASFiles(.init(files:[f],channelID:93,rootID:nil,accountGeneration:epoch));XCTAssertNil(m.attachmentBatch)
    }
    func testChangedFilePermissionPolicyAndChannelBlockBeforePost() async throws {
        let m = try await model(),f = try file(),b = batch(f),epoch = m.accountGeneration
        for mode in ["mtime","size","permission","policy","channel","guest"] {
            NASProtocol.reset()
            switch mode {case "mtime":NASProtocol.mtime = 2000;case "size":NASProtocol.size = 9;case "permission":NASProtocol.read = false;case "policy":NASProtocol.allowed = false;case "channel":NASProtocol.encrypted = true;default:NASProtocol.guest = true}
            do {_ = try await m.sendReviewedNASFile(f,batch:b,caption:"Synthetic",connectionID:"synthetic",epoch:epoch);XCTFail("Changed source dispatched: \(mode)")} catch is ChatNASPreflightFailure {}
            XCTAssertEqual(NASProtocol.writes,0)
        }
    }
    func testBlockedPreflightIsRemovableAndNotAmbiguousDelivery() async throws {
        let m = try await model(),f = try file(),b = batch(f);NASProtocol.read = false
        await b.run(canContinue:{true},send:{item in try await m.sendReviewedNASFile(try XCTUnwrap(item.nasFile),batch:b,caption:item.caption,connectionID:"synthetic",epoch:m.accountGeneration)},received:{_,_ in XCTFail("Blocked file received")})
        guard case .blocked = b.items[0].state else {return XCTFail("Preflight marked uncertain")}
        XCTAssertEqual(b.unconfirmedCount,0);XCTAssertEqual(NASProtocol.writes,0);b.remove(b.items[0].id);XCTAssertTrue(b.items.isEmpty)
    }
    func testAmbiguousPostStopsBatchAndNeverRetriesIt() async throws {
        let m = try await model(),f = try file(),b = batch(f);NASProtocol.badReceipt = true
        await b.run(canContinue:{true},send:{item in try await m.sendReviewedNASFile(try XCTUnwrap(item.nasFile),batch:b,caption:item.caption,connectionID:"synthetic",epoch:m.accountGeneration)},received:{_,_ in XCTFail("Bad receipt published")})
        XCTAssertEqual(b.unconfirmedCount,1);XCTAssertEqual(NASProtocol.writes,1)
        await b.run(canContinue:{true},send:{_ in XCTFail("Retried uncertain copy");throw ChatAPIError.invalidResponse},received:{_,_ in})
        XCTAssertEqual(NASProtocol.writes,1)
    }
    func testSignOutWhileCheckingMetadataDoesNotDispatch() async throws {
        let m = try await model(),f = try file(),b = batch(f),epoch = m.accountGeneration,started = expectation(description:"Metadata held")
        NASProtocol.holdInfo = true;NASProtocol.onInfo = {started.fulfill()}
        let action = Task {try await m.sendReviewedNASFile(f,batch:b,caption:"Synthetic",connectionID:"synthetic",epoch:epoch)}
        await fulfillment(of:[started],timeout:2);m.signOutLocally();NASProtocol.held?.finish(["success":true,"data":["files":[NASProtocol.file()]]]);NASProtocol.held = nil
        do {_ = try await action.value;XCTFail("Old account dispatched")} catch is ChatNASPreflightFailure {}
        XCTAssertEqual(NASProtocol.writes,0)
    }
    func testThreadContextCanSendWhileSendingFlagIsSet() async throws {
        let m = try await model(),f = try file(),root = try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":50,"channel_id":93,"creator_id":10,"message":"Synthetic","type":"normal","create_at":1000}"#.utf8))
        m.threadRoot = root;m.sending = true;let b = batch(f,root:50)
        let p = try await m.sendReviewedNASFile(f,batch:b,caption:"Thread",connectionID:"synthetic",epoch:m.accountGeneration)
        XCTAssertEqual(p.thread_id,50);XCTAssertEqual(NASProtocol.lastWrite?["thread_id"],"50")
    }
    func testPathValidationAndSizeLimitOverflowFailClosed() throws {
        for path in ["relative/file","/Synthetic/../secret","/Synthetic//file","/Synthetic/\0bad"] {XCTAssertFalse(ChatNASFile.validPath(path))}
        let f = try file();XCTAssertTrue(ChatNASUploadPolicy(allow_ds_upload:true,file_size_limit:0).allows(f));XCTAssertFalse(ChatNASUploadPolicy(allow_ds_upload:true,file_size_limit:Int64.max).allows(f))
        NASProtocol.size = 2*1024*1024;XCTAssertFalse(ChatNASUploadPolicy(allow_ds_upload:true,file_size_limit:1).allows(try file()))
    }
}

private final class NASProtocol:URLProtocol {
    static var allowed = true,read = true,guest = false,encrypted = false,badReceipt = false,holdInfo = false
    static var size:Int64 = 4,mtime = 1000,writes = 0,metadataReads = 0,channelReads = 0
    static var lastWrite:[String:String]?,held:NASProtocol?,onInfo:(()->Void)?
    static func reset() {allowed = true;read = true;guest = false;encrypted = false;badReceipt = false;holdInfo = false;size = 4;mtime = 1000;writes = 0;metadataReads = 0;channelReads = 0;lastWrite = nil;held = nil;onInfo = nil}
    static func file()->[String:Any] {["path":"/Synthetic/synthetic.txt","name":"synthetic.txt","isdir":false,"additional":["size":size,"time":["mtime":mtime,"ctime":1000],"perm":["acl":["read":read]],"type":"txt"]]}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" {finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Core.File","SYNO.FileStation.List","SYNO.Chat.Admin.Setting","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Post","SYNO.Chat.Misc"].map {($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any])})]);return}
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream {stream.open();defer {stream.close()};var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable {let n = stream.read(&b,maxLength:b.count);if n <= 0 {break};data.append(contentsOf:b.prefix(n))}}
        var q = URLComponents();q.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let f = Dictionary((q.queryItems ?? []).map {($0.name,$0.value ?? "")},uniquingKeysWith:{_,last in last}),api = request.url!.lastPathComponent
        if api == "SYNO.Chat.Admin.Setting" {finish(["success":true,"data":["allow_ds_upload":Self.allowed,"file_size_limit":0]]);return}
        if api == "SYNO.Core.File" {
            if f["folder_path"].flatMap({try? JSONDecoder().decode(String.self,from:Data($0.utf8))}) == "/" {finish(["success":true,"data":[["spath":"/Synthetic","text":"Synthetic"],["spath":"/home","text":"Hidden alias"]]]);return}
            finish(["success":true,"data":["files":[Self.file()],"offset":0,"total":1]]);return
        }
        if api == "SYNO.FileStation.List" {Self.metadataReads += 1;if Self.holdInfo {Self.held = self;Self.onInfo?();return};finish(["success":true,"data":["files":[Self.file()]]]);return}
        if api == "SYNO.Chat.User" {finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Synthetic Peter","type":"human","human_type":Self.guest ? "guest" : "dsm"]]]]);return}
        if api == "SYNO.Chat.Channel" {Self.channelReads += 1;finish(["success":true,"data":["channels":[["channel_id":93,"name":"Peter","type":"anonymous","encrypted":Self.encrypted,"unread":0,"is_joined":true]]]]);return}
        if api == "SYNO.Chat.Post",f["method"] == "create" {
            Self.writes += 1;Self.lastWrite = f
            let thread = Int64(f["thread_id"] ?? "0") ?? 0
            finish(["success":true,"data":["post_id":100,"channel_id":Self.badReceipt ? 94 : 93,"creator_id":10,"message":"Synthetic","type":"file","create_at":1000,"thread_id":thread,"is_thread":thread > 0,"file_props":["name":"synthetic.txt","size":4,"type":"txt"]]]);return
        }
        if api == "SYNO.Chat.Post" {finish(["success":true,"data":["posts":[]]]);return}
        if api == "SYNO.Chat.Misc" {finish(["success":true,"data":["acls":[]]]);return}
        finish(["success":false,"error":["code":102]])
    }
    func finish(_ value:[String:Any]) {let d = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:d);client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading() {}
}
