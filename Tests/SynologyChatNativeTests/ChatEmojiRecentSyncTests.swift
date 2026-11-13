import XCTest
@testable import SynologyChatNative

@MainActor final class ChatEmojiRecentSyncTests: XCTestCase {
    private func snapshot(_ names:[String] = ["eyes"],extra:String = "keep") throws -> ChatEmojiRecentSettings {
        try .init(.object([ChatEmojiRecentSettings.namespace:.object(["recent_emojies":.array(names.map(ChatJSON.string)),"last_channel":.integer(93),"future":.object(["value":.string(extra)])]),"Personal":.object(["language":.string("keep")])]))
    }
    private func preferences() -> ChatEmojiPreferences { let p = ChatEmojiPreferences();p.activate(scope:String(repeating:"a",count:64));return p }
    func testSnapshotPreservesUnknownFieldsAndNamesWhileProjectingKnownExactVariants() throws {
        let original = try snapshot(["future_emoji","heart","heart","thumbsup_tone3"])
        let next = try original.adding([.heart,.eyes])
        XCTAssertEqual(next.names,["eyes","heart","future_emoji","thumbsup_tone3"])
        XCTAssertEqual(next.recent.map(\.rawValue),["eyes","heart","thumbsup_tone3"])
        XCTAssertEqual(next.application["future"],original.application["future"]);XCTAssertEqual(next.application["last_channel"],.integer(93))
        guard case .object(let root) = next.payload else { return XCTFail() };XCTAssertEqual(Set(root.keys),[ChatEmojiRecentSettings.namespace])
        let many = try snapshot().adding(Array(ChatReactionKind.allCases.prefix(40)))
        XCTAssertEqual(many.names,Array(ChatReactionKind.allCases.prefix(40).reversed().prefix(24)).map(\.rawValue))
    }
    func testMalformedApplicationRecentShapeAndUnsafeNamesCannotBeWritten() throws {
        for value in [ChatJSON.string("bad"),.object(["recent_emojies":.null]),.object(["recent_emojies":.array([.integer(1)])]),.object(["recent_emojies":.array([.string("https://private.invalid")])])] {
            XCTAssertThrowsError(try ChatEmojiRecentSettings(.object([ChatEmojiRecentSettings.namespace:value])))
        }
        XCTAssertTrue(try ChatEmojiRecentSettings(.object([:])).names.isEmpty)
    }
    func testImportIsReadOnlyAndLeavesLocalToneUnchanged() async throws {
        let prefs = preferences();prefs.setSkinTone(4);prefs.record(.heart)
        let sync = ChatEmojiRecentSync(preferences:prefs);var writes = 0
        sync.attach(read:{try self.snapshot(["eyes","thumbsup_tone2"])},write:{_ in writes += 1});await sync.task?.value
        XCTAssertEqual(writes,0);XCTAssertEqual(prefs.recent.map(\.rawValue),["eyes","thumbsup_tone2"]);XCTAssertEqual(prefs.skinTone,4)
        XCTAssertFalse(prefs.recentSyncing);XCTAssertNil(prefs.recentSyncNotice);sync.attach(nil)
    }
    func testChoiceDuringHeldInitialReadSurvivesAndSyncsAgainstFreshOtherClientState() async throws {
        let prefs = preferences(),sync = ChatEmojiRecentSync(preferences:prefs);var server = try snapshot();var resume:CheckedContinuation<ChatEmojiRecentSettings,Never>?
        var reads = 0,writes = 0
        sync.attach(read:{ reads += 1;if reads == 1 { return await withCheckedContinuation { resume = $0 } };return server },write:{server = $0;writes += 1})
        while resume == nil { await Task.yield() }
        prefs.record(.heart);prefs.record(.tada)
        server = try snapshot(["cat","eyes"],extra:"Changed by another client")
        resume?.resume(returning:try snapshot());await sync.task?.value
        XCTAssertEqual(writes,1);XCTAssertEqual(server.names,["tada","heart","cat","eyes"]);XCTAssertEqual(prefs.recent.map(\.rawValue),server.names)
        XCTAssertEqual(server.application["future"],.object(["value":.string("Changed by another client")]));sync.attach(nil)
    }
    func testChoicesDuringHeldWriteAreSerializedAndNotLostOnCanonicalReadback() async throws {
        let prefs = preferences(),sync = ChatEmojiRecentSync(preferences:prefs);var server = try snapshot(),batches:[[String]] = []
        var resume:CheckedContinuation<Void,Never>?
        sync.attach(read:{server},write:{ value in
            batches.append(value.names)
            if batches.count == 1 { await withCheckedContinuation { resume = $0 } }
            server = value
        });await sync.task?.value;prefs.record(.heart)
        while resume == nil { await Task.yield() };prefs.record(.tada);prefs.record(.heart)
        resume?.resume();await sync.task?.value
        XCTAssertEqual(batches,[["heart","eyes"],["heart","tada","eyes"]]);XCTAssertEqual(prefs.recent.map(\.rawValue),["heart","tada","eyes"]);sync.attach(nil)
    }
    func testLostWriteResponseBlocksAutomaticReplayAndRefreshOnlyReadsServerState() async throws {
        let prefs = preferences(),sync = ChatEmojiRecentSync(preferences:prefs);var server = try snapshot();var writes = 0
        sync.attach(read:{server},write:{ value in server = value;writes += 1;throw URLError(.networkConnectionLost) });await sync.task?.value
        prefs.record(.heart);await sync.task?.value
        XCTAssertTrue(sync.needsRefresh);XCTAssertNotNil(prefs.recentSyncNotice);XCTAssertEqual(writes,1)
        prefs.record(.tada);await sync.task?.value;XCTAssertEqual(writes,1);XCTAssertEqual(prefs.recent.first,.tada)
        sync.refresh();await sync.task?.value
        XCTAssertEqual(writes,1);XCTAssertFalse(sync.needsRefresh);XCTAssertEqual(prefs.recent.map(\.rawValue),["heart","eyes"]);sync.attach(nil)
    }
    func testDetachAndNewAccountRejectLateOldReadAndDisableOldCallbacks() async throws {
        let prefs = preferences(),sync = ChatEmojiRecentSync(preferences:prefs);var resume:CheckedContinuation<ChatEmojiRecentSettings,Never>?;var writes = 0
        sync.attach(read:{await withCheckedContinuation{resume = $0}},write:{_ in writes += 1})
        while resume == nil { await Task.yield() };let old = sync.task
        sync.attach(nil);prefs.activate(scope:String(repeating:"b",count:64));prefs.record(.tada)
        resume?.resume(returning:try snapshot(["heart"]));await old?.value
        XCTAssertEqual(prefs.recent,[.tada]);XCTAssertEqual(writes,0);XCTAssertNil(prefs.refreshRecents);XCTAssertNil(prefs.didRecord)
    }
    func testFailedCanonicalConfirmationKeepsLocalChoiceAndDoesNotRetry() async throws {
        let prefs = preferences(),sync = ChatEmojiRecentSync(preferences:prefs);var writes = 0
        sync.attach(read:{try self.snapshot()},write:{_ in writes += 1});await sync.task?.value
        prefs.record(.heart);await sync.task?.value
        XCTAssertEqual(writes,1);XCTAssertTrue(sync.needsRefresh);XCTAssertEqual(prefs.recent.first,.heart);sync.attach(nil)
    }
    func testTransportUsesUserSettingsV1AndOnlyChatNamespaceInEncodedData() async throws {
        let configuration = URLSessionConfiguration.ephemeral;configuration.protocolClasses = [EmojiSettingsProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.test")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:configuration))
        defer { EmojiSettingsProtocol.written = nil }
        try await api.discover();let snapshot = try await api.emojiRecentSettings();try await api.applyEmojiRecentSettings(snapshot.adding([.heart]))
        let fields = try XCTUnwrap(EmojiSettingsProtocol.written)
        XCTAssertEqual(fields["method"],"apply");XCTAssertEqual(fields["version"],"1")
        let string = try JSONDecoder().decode(String.self,from:Data(try XCTUnwrap(fields["data"]).utf8))
        let value = try JSONDecoder().decode(ChatJSON.self,from:Data(string.utf8))
        XCTAssertEqual(value,try snapshot.adding([.heart]).payload)
        XCTAssertNil(value["Personal"]);XCTAssertEqual(value[ChatEmojiRecentSettings.namespace]?["last_channel"],.integer(93))
    }
}

private final class EmojiSettingsProtocol: URLProtocol {
    static var written: [String:String]?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body:String
        if request.url!.lastPathComponent == "SYNO.API.Info" {
            body = #"{"success":true,"data":{"SYNO.Core.UserSettings":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"}}}"#
        } else {
            var data = request.httpBody ?? Data()
            if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
            var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
            let fields = Dictionary((parts.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{$1})
            if fields["method"] == "apply" { Self.written = fields;body = #"{"success":true}"# }
            else { body = #"{"success":true,"data":{"SYNO.SDS.Chat.Application":{"recent_emojies":["eyes"],"last_channel":93,"future":{"value":"keep"}},"Personal":{"language":"keep"}}}"# }
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
