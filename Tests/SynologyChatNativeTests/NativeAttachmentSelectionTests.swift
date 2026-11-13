import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeAttachmentSelectionTests:XCTestCase {
    override func setUp() { super.setUp();AttachmentPreflightProtocol.reset() }
    override func tearDown() { AttachmentPreflightProtocol.reset();super.tearDown() }
    private func folder() throws -> URL {
        let folder = URL(fileURLWithPath:"/private/tmp").appendingPathComponent("native-selection-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:folder) };return folder
    }
    private func file(_ name:String = "Synthetic.txt",bytes:Int = 20) throws -> URL {
        let file = try folder().appendingPathComponent(name)
        try Data(repeating:65,count:bytes).write(to:file);return file
    }
    private func reference(_ name:String)->URL { URL(fileURLWithPath:"/private/tmp/"+name) }
    private func board(_ values:[(NSPasteboard.PasteboardType,String)])->NSPasteboard {
        let board = NSPasteboard.withUniqueName();addTeardownBlock { board.releaseGlobally() }
        board.writeObjects(values.map { type,value in let item = NSPasteboardItem();item.setString(value,forType:type);return item });return board
    }
    private func model() throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Synthetic","type":"private","encrypted":false,"unread":0}"#.utf8))]
        model.connected = true;model.liveStatus = .live;model.selection = 93;model.draft = "Main caption 👀\nretained  "
        model.threadRoot = try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":5,"channel_id":93,"creator_id":10,"type":"normal","message":"Synthetic root","create_at":1}"#.utf8))
        model.replyDraft = "Reply caption 🌍\nretained  "
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    private func nasFile(_ number:Int)->ChatNASFile {
        try! JSONDecoder().decode(ChatNASFile.self,from:Data("{\"path\":\"/Synthetic/file-\(number).txt\",\"name\":\"file-\(number).txt\",\"isdir\":false,\"additional\":{\"size\":10,\"time\":{\"mtime\":1},\"perm\":{\"acl\":{\"read\":true}}}}".utf8))
    }
    private func api() async throws -> ChatAPIClient {
        func network()->URLSession { let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [AttachmentPreflightProtocol.self];return URLSession(configuration:config) }
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://attachment-preflight.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:{ AttachmentPreflightProtocol.transferSessions += 1;return network() })
        try await api.discover();return api
    }
    func testCompleteLocalReferenceValidationPreservesOrderAndRejectsMalformedBatch() throws {
        let a = reference("😀 a% #.txt"),b = reference("second.txt")
        XCTAssertEqual(try ChatAttachmentSelection.localFiles([a,b,a]),[a,b])
        for invalid in ["https://remote.invalid/file.txt","file://remote.invalid/tmp/file.txt","file:///tmp/a%00b.txt","file:///tmp/file.txt?query=1","file:///tmp/file.txt#fragment","file:relative.txt"] {
            XCTAssertThrowsError(try ChatAttachmentSelection.localFiles([a,try XCTUnwrap(URL(string:invalid))]))
        }
        XCTAssertThrowsError(try ChatAttachmentSelection.localReference(Data(repeating:65,count:16_385)))
        XCTAssertThrowsError(try ChatAttachmentSelection.localFiles((0...100).map { reference("file-\($0).txt") }))
    }
    func testComposerPasteRejectsMixedOrMalformedItemsWithoutReturningValidPrefix() {
        let good = reference("valid.txt").absoluteString
        for bad in [(NSPasteboard.PasteboardType.fileURL,"https://remote.invalid/file.txt"),(.fileURL,"file://remote.invalid/tmp/file.txt"),(.fileURL,"file:///tmp/a%00b.txt"),(.string,"Unrelated item")] {
            let pasteboard = board([(.fileURL,good),bad])
            guard case .invalid = NativeComposerAttachmentReader.read(pasteboard) else { return XCTFail("Part of an invalid selection was accepted") }
        }
        guard case .invalid = NativeComposerAttachmentReader.read(board(Array(repeating:(.fileURL,good),count:101))) else { return XCTFail("Over-limit paste accepted") }
        guard case .files(let urls) = NativeComposerAttachmentReader.read(board([(.fileURL,good),(.fileURL,good)])) else { return XCTFail("Valid duplicate references rejected") }
        XCTAssertEqual(urls,[reference("valid.txt")])
    }
    func testInvalidModelAppendPreservesAllItemsCaptionsDraftsAndSelection() throws {
        for inThread in [false,true] {
            let model = try model(),a = reference("first.txt"),b = reference("second.txt")
            model.stageAttachments([a],inThread:inThread)
            let batch = try XCTUnwrap(model.attachmentBatch),ids = batch.items.map(\.id),main = model.drafts,replies = model.threadDrafts
            batch.caption(batch.items[0].id,text:"Edited review caption")
            model.stageAttachments([b,URL(string:"https://remote.invalid/file.txt")!],inThread:inThread)
            XCTAssertEqual(model.attachmentBatch?.id,batch.id);XCTAssertEqual(batch.items.map(\.id),ids)
            XCTAssertEqual(batch.items.map(\.caption),["Edited review caption"])
            XCTAssertEqual(model.drafts,main);XCTAssertEqual(model.threadDrafts,replies);XCTAssertEqual(model.selection,93)
            XCTAssertNotNil(model.error);XCTAssertFalse(model.sending)
            model.dismissAttachmentBatch();XCTAssertEqual(model.drafts,main);XCTAssertEqual(model.threadDrafts,replies)
        }
    }
    func testLocalAndNASAppendsShareWholeReviewLimitAndKeepStateOnOverflow() {
        let batch = NativeAttachmentBatch(files:[],caption:"Original caption",channelID:93,channelTitle:"Synthetic",rootID:nil,encrypted:false,keyEnvelope:nil)
        XCTAssertTrue(batch.appendNAS((0..<99).map(nasFile)))
        let ids = batch.items.map(\.id)
        XCTAssertFalse(batch.append([reference("a.txt"),reference("b.txt")]))
        XCTAssertEqual(batch.items.map(\.id),ids);XCTAssertNotNil(batch.validationError)
        XCTAssertTrue(batch.append([reference("a.txt")]));XCTAssertEqual(batch.items.count,100);XCTAssertNil(batch.validationError)
        XCTAssertFalse(batch.appendNAS([nasFile(100)]));XCTAssertEqual(batch.items.count,100)
        XCTAssertTrue(batch.appendNAS([nasFile(0)]));XCTAssertEqual(batch.items.count,100)
        XCTAssertEqual(batch.items.first?.caption,"Original caption")
        XCTAssertFalse(batch.append(Array(repeating:reference("a.txt"),count:101)));XCTAssertEqual(batch.items.count,100)
    }
    func testPickerStyleSelectionAndAppendOverflowNeverStagePartialReview() throws {
        let model = try model(),files = (0..<100).map { reference("file-\($0).txt") },main = model.drafts,replies = model.threadDrafts
        model.stageAttachments(files+[reference("overflow.txt")]);XCTAssertNil(model.attachmentBatch);XCTAssertNotNil(model.error)
        model.stageAttachments(files);let batch = try XCTUnwrap(model.attachmentBatch),ids = batch.items.map(\.id)
        model.stageAttachments([files[0],reference("overflow.txt")]);XCTAssertEqual(batch.items.map(\.id),ids);XCTAssertNotNil(model.error)
        XCTAssertEqual(model.drafts,main);XCTAssertEqual(model.threadDrafts,replies);XCTAssertEqual(model.selection,93)
    }
    func testMissingUnreadableDirectoryAndOversizedPreflightAreBlockedRemovableAndNeverDispatch() async throws {
        let api = try await api(),missing = try folder().appendingPathComponent("missing.txt"),unreadable = try file("Unreadable.txt"),directory = try folder(),oversized = try file("Oversized.txt",bytes:1024*1024+1)
        try FileManager.default.setAttributes([.posixPermissions:0o000],ofItemAtPath:unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:unreadable.path) }
        for bad in [missing,unreadable,directory,oversized] {
            let model = try model(),main = model.drafts,replies = model.threadDrafts
            model.stageAttachments([bad]);let batch = try XCTUnwrap(model.attachmentBatch),id = try XCTUnwrap(batch.items.first?.id)
            await batch.run(canContinue:{true},send:{ item in try await api.uploadAttachment(channelID:93,file:try XCTUnwrap(item.localFile),caption:item.caption,connectionID:"synthetic") },received:{_,_ in XCTFail("Known-unsent file received")})
            let state = try XCTUnwrap(batch.items.first?.state)
            guard case .blocked(let message) = state else { return XCTFail("Known-unsent preparation marked uncertain") }
            XCTAssertTrue(message.contains("not sent"));XCTAssertEqual(batch.unconfirmedCount,0)
            XCTAssertEqual(model.drafts,main);XCTAssertEqual(model.threadDrafts,replies)
            batch.remove(id);XCTAssertTrue(batch.items.isEmpty)
            model.dismissAttachmentBatch();XCTAssertEqual(model.drafts,main);XCTAssertEqual(model.threadDrafts,replies)
        }
        XCTAssertEqual(AttachmentPreflightProtocol.uploads,0);XCTAssertEqual(AttachmentPreflightProtocol.transferSessions,0)
    }
    func testAdminSettingAndMissingCreateRouteFailuresRemainKnownUnsent() async throws {
        let file = try file(),api = try await api()
        _ = NativeSnippetTemporaryFiles.shared
        let namespace = (Bundle.main.bundleIdentifier ?? "native-tests").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        func staging() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath:FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("native-chat-upload-v1-"+namespace+"-") })
        }
        let before = try staging()
        AttachmentPreflightProtocol.failSettings = true
        do { _ = try await api.uploadAttachment(channelID:93,file:file,caption:"Caption",connectionID:"synthetic");XCTFail("Settings failure accepted") } catch is ChatAttachmentPreflightFailure { }
        AttachmentPreflightProtocol.failSettings = false;AttachmentPreflightProtocol.omitCreateAPI = true
        let missingRoute = try await self.api()
        do { _ = try await missingRoute.uploadAttachment(channelID:93,file:file,caption:"Caption",connectionID:"synthetic");XCTFail("Missing create route accepted") } catch is ChatAttachmentPreflightFailure { }
        XCTAssertEqual(AttachmentPreflightProtocol.uploads,0);XCTAssertEqual(AttachmentPreflightProtocol.transferSessions,0)
        XCTAssertEqual(try staging(),before)
    }
    func testCancellationBeforePreparationIsKnownUnsentWithoutCreatingTransfer() async throws {
        let api = try await api(),file = try file()
        let operation = Task { try await api.uploadAttachment(channelID:93,file:file,caption:"Caption",connectionID:"synthetic") }
        operation.cancel()
        do { _ = try await operation.value;XCTFail("Cancelled preparation succeeded") } catch is ChatAttachmentPreflightFailure { }
        XCTAssertEqual(AttachmentPreflightProtocol.uploads,0);XCTAssertEqual(AttachmentPreflightProtocol.transferSessions,0)
    }
    func testPostDispatchLostOrMalformedResponseStaysUnconfirmedAndCannotBeRemovedOrRetried() async throws {
        let api = try await api(),file = try file()
        for response in ["lost","malformed"] {
            AttachmentPreflightProtocol.uploadResponse = response
            let batch = NativeAttachmentBatch(files:[file],caption:"Original caption",channelID:93,channelTitle:"Synthetic",rootID:nil,encrypted:false,keyEnvelope:nil)
            await batch.run(canContinue:{true},send:{ item in try await api.uploadAttachment(channelID:93,file:try XCTUnwrap(item.localFile),caption:item.caption,connectionID:"synthetic") },received:{_,_ in XCTFail("Unknown delivery published")})
            let id = try XCTUnwrap(batch.items.first?.id)
            let state = try XCTUnwrap(batch.items.first?.state)
            guard case .unconfirmed = state else { return XCTFail("Post-dispatch failure misclassified safe") }
            let before = AttachmentPreflightProtocol.uploads
            batch.remove(id);batch.caption(id,text:"Cannot edit attempted item")
            XCTAssertEqual(batch.items.count,1);XCTAssertEqual(batch.items.first?.caption,"Original caption")
            await batch.run(canContinue:{true},send:{ _ in XCTFail("Unknown delivery retried");throw ChatAPIError.invalidResponse },received:{_,_ in})
            XCTAssertEqual(AttachmentPreflightProtocol.uploads,before);XCTAssertEqual(batch.unconfirmedCount,1)
        }
        XCTAssertEqual(AttachmentPreflightProtocol.uploads,2)
    }
}

private final class AttachmentPreflightProtocol:URLProtocol {
    static var uploads = 0,transferSessions = 0,failSettings = false,omitCreateAPI = false,uploadResponse = "lost"
    static func reset() { uploads = 0;transferSessions = 0;failSettings = false;omitCreateAPI = false;uploadResponse = "lost" }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "attachment-preflight.invalid" else {client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return}
        let path = request.url!.path
        if path.contains("SYNO.API.Info") {
            var endpoints:[String:Any] = ["SYNO.Chat.Admin.Setting":["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"]]
            if !Self.omitCreateAPI {endpoints["SYNO.Chat.Post"] = ["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"]}
            finish(try! JSONSerialization.data(withJSONObject:["success":true,"data":endpoints]));return
        }
        if path.contains("SYNO.Chat.Admin.Setting") {
            finish(Data(#"{"success":true,"data":{"file_size_limit":1}}"#.utf8),status:Self.failSettings ? 503 : 200);return
        }
        Self.uploads += 1
        if Self.uploadResponse == "lost" {client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return}
        finish(Data("not a JSON upload receipt".utf8))
    }
    private func finish(_ data:Data,status:Int = 200) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
