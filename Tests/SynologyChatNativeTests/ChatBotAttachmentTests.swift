import XCTest
@testable import SynologyChatNative

@MainActor final class ChatBotAttachmentTests: XCTestCase {
    override func setUp() { super.setUp(); BotProtocol.reset() }
    private func api() async throws -> ChatAPIClient {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [BotProtocol.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://bot.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: c))
        try await api.discover(); return api
    }
    private func model(journal: ChatBotActionJournal? = nil) async throws -> NativeChatPreviewModel {
        let api = try await api()
        let model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false, makeClient: { _ in api }, botActionJournal: journal)
        model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":93,"name":"Synthetic","type":"anonymous","encrypted":false,"unread":0,"is_joined":true}"#.utf8))]
        model.connected = true; model.liveStatus = .live; model.selection = 93; model.posts = [try BotProtocol.post()]
        addTeardownBlock { @MainActor in model.signOutLocally() }; return model
    }
    private func selection(_ post: ChatPost, card: Int = 1, action: Int = 1) throws -> ChatBotActionSelection {
        .init(attachmentIndex: card, actionIndex: action, attachment: try XCTUnwrap(post.props?.attachments?[card]))
    }
    private func journalFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-bot-action-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }; return folder
    }
    func testLostResponseRemainsBlockedAcrossModelAndJournalRecreationWithoutReplay() async throws {
        let folder = try journalFolder(), scope = String(repeating: "a", count: 64)
        let journal = ChatBotActionJournal(directory: folder); _ = try journal.activate(scope: scope)
        let first = try await model(journal: journal), post = try BotProtocol.post(), selected = try selection(post)
        first.restoreBotActionRecovery(scope: scope); BotProtocol.loseReply = true
        do { try await first.triggerBotAction(post, selection: selected); XCTFail("Lost response confirmed") } catch { }
        XCTAssertEqual(BotProtocol.writes, 1); first.signOutLocally()
        let restoredJournal = ChatBotActionJournal(directory: folder)
        let restored = try await model(journal: restoredJournal); restored.restoreBotActionRecovery(scope: scope)
        XCTAssertNotNil(restored.pendingBotActionReceipts[post.id]); XCTAssertFalse(restored.canTriggerBotAction(post, selection: selected))
        XCTAssertTrue(restored.botActionStatus[post.id]?.contains("unknown") == true)
        try await restored.checkBotActionMessage(post)
        XCTAssertNotNil(restored.pendingBotActionReceipts[post.id]); XCTAssertEqual(BotProtocol.writes, 1)
        BotProtocol.card["text"] = "Canonical changed card, review new actions"
        try await restored.checkBotActionMessage(post)
        XCTAssertNil(restored.pendingBotActionReceipts[post.id])
        XCTAssertTrue(try ChatBotActionJournal(directory: folder).activate(scope: scope).isEmpty)
        XCTAssertEqual(BotProtocol.writes, 1, "Restoration and checks must not replay callbacks")
    }
    func testAcknowledgedCallbackClearsDurableReceiptBeforeRestart() async throws {
        let folder = try journalFolder(), scope = String(repeating: "b", count: 64)
        let journal = ChatBotActionJournal(directory: folder); _ = try journal.activate(scope: scope)
        let m = try await model(journal: journal), post = try BotProtocol.post()
        m.restoreBotActionRecovery(scope: scope)
        try await m.triggerBotAction(post, selection: selection(post))
        XCTAssertTrue(m.pendingBotActionReceipts.isEmpty)
        XCTAssertTrue(try ChatBotActionJournal(directory: folder).activate(scope: scope).isEmpty)
        XCTAssertEqual(BotProtocol.writes, 1)
    }
    func testReceiptStorageFailurePreventsAnyCallbackDispatch() async throws {
        let folder = try journalFolder(), scope = String(repeating: "c", count: 64)
        let journal = ChatBotActionJournal(directory: folder); _ = try journal.activate(scope: scope)
        let m = try await model(journal: journal), post = try BotProtocol.post()
        m.restoreBotActionRecovery(scope: scope)
        try FileManager.default.removeItem(at: folder); try Data("Synthetic non-directory".utf8).write(to: folder)
        do { try await m.triggerBotAction(post, selection: selection(post)); XCTFail("Callback dispatched without recoverable receipt") } catch { }
        XCTAssertEqual(BotProtocol.writes, 0); XCTAssertTrue(m.pendingBotActionReceipts.isEmpty)
    }
    func testCorruptSavedReceiptDisablesActionsWithoutDiscardingRecoveryFile() async throws {
        let folder = try journalFolder(), scope = String(repeating: "d", count: 64)
        let file = folder.appendingPathComponent(scope + ".json"), bytes = Data("Synthetic corrupt receipt".utf8)
        try bytes.write(to: file)
        let m = try await model(journal: .init(directory: folder)), post = try BotProtocol.post()
        m.restoreBotActionRecovery(scope: scope)
        XCTAssertNotNil(m.botActionRecoveryError)
        XCTAssertFalse(m.canTriggerBotAction(post, selection: try selection(post)))
        XCTAssertFalse(m.canCheckBotActionMessage(post)); XCTAssertEqual(BotProtocol.writes, 0)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testReconnectRetiresOldPendingUIAndLateCallbackKeepsOnlyOriginalReceipt() async throws {
        let folder = try journalFolder(), scope = String(repeating: "e", count: 64)
        let journal = ChatBotActionJournal(directory: folder); _ = try journal.activate(scope: scope)
        let m = try await model(journal: journal), post = try BotProtocol.post(), selected = try selection(post)
        m.restoreBotActionRecovery(scope: scope)
        let sent = expectation(description: "Synthetic action held")
        BotProtocol.hold = true; BotProtocol.onWrite = { sent.fulfill() }
        let task = Task { try await m.triggerBotAction(post, selection: selected) }
        await fulfillment(of: [sent], timeout: 2)
        // Explicit supplied identity + injected client: no official session,
        // Keychain or external connection. Bootstrap is deliberately unsupported.
        await m.connect(using: .init(session: .init(baseURL: URL(string: "https://bot.invalid")!, sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false))
        XCTAssertTrue(m.botActionsPending.isEmpty); XCTAssertTrue(m.uncertainBotActions.isEmpty)
        XCTAssertTrue(m.botActionStatus.isEmpty); XCTAssertTrue(m.pendingBotActionReceipts.isEmpty)
        BotProtocol.held?.finish(["success": true]); BotProtocol.held = nil
        do { try await task.value; XCTFail("Retired account callback published") } catch is CancellationError { }
        XCTAssertTrue(m.botActionStatus.isEmpty); XCTAssertTrue(m.pendingBotActionReceipts.isEmpty)
        XCTAssertEqual(try ChatBotActionJournal(directory: folder).activate(scope: scope).count, 1)
        XCTAssertEqual(BotProtocol.writes, 1)
    }
    func testRestoredReceiptWithRemovedCardsCanBeCheckedAndRetiredWithoutCallback() async throws {
        let folder = try journalFolder(), scope = String(repeating: "f", count: 64)
        let post = try BotProtocol.post(), selected = try selection(post)
        let journal = ChatBotActionJournal(directory: folder); _ = try journal.activate(scope: scope)
        try journal.remember(.init(post: post, selection: selected))
        BotProtocol.cardsRemoved = true
        let m = try await model(journal: .init(directory: folder)); m.restoreBotActionRecovery(scope: scope)
        let current = try XCTUnwrap(m.posts.first)
        XCTAssertTrue(m.botAttachments(for: current).isEmpty)
        XCTAssertNotNil(m.pendingBotActionReceipts[current.id]); XCTAssertNotNil(m.botActionStatus[current.id])
        XCTAssertTrue(m.canCheckBotActionMessage(current))
        try await m.checkBotActionMessage(current)
        XCTAssertTrue(m.pendingBotActionReceipts.isEmpty)
        XCTAssertTrue(try ChatBotActionJournal(directory: folder).activate(scope: scope).isEmpty)
        XCTAssertEqual(BotProtocol.writes, 0)
    }
    func testTriggerV1UsesOriginalIndicesAndLosslessCallbackValuesOnly() async throws {
        let api = try await api(), post = try BotProtocol.post(), selected = try selection(post)
        try await api.triggerBotAttachment(postID: post.id, selection: selected)
        let fields = try XCTUnwrap(BotProtocol.lastFields), payload = try XCTUnwrap(fields["payload"]?.data(using: .utf8))
        let value = try JSONDecoder().decode(ChatJSON.self, from: payload)
        XCTAssertEqual(fields["version"], "1"); XCTAssertEqual(fields["post_id"], "700"); XCTAssertNil(fields["channel_id"])
        XCTAssertEqual(value["idx"], .integer(1)); XCTAssertEqual(value["callback_id"], .string("callback-👋"))
        guard case .array(let actions) = value["actions"] else { return XCTFail("Missing actions") }
        XCTAssertEqual(actions.count, 1); XCTAssertEqual(actions[0]["idx"], .integer(1)); XCTAssertEqual(actions[0]["name"], .null)
        XCTAssertEqual(actions[0]["value"]?["id"], .integer(9_007_199_254_740_993)); XCTAssertNil(actions[0]["url"]); XCTAssertNil(actions[0]["text"])
        XCTAssertEqual(BotProtocol.writes, 1)
    }
    func testMalformedOptionalCardsPreserveMessageAndOriginalArrayIndices() async throws {
        let model = try await model(), post = try BotProtocol.post(), cards = model.botAttachments(for: post)
        XCTAssertEqual(cards.map(\.index), [1]); XCTAssertEqual(cards[0].actions.map(\.index), [0, 1]); XCTAssertEqual(cards[0].actions[0].type, "select")
        var fields = BotProtocol.fields; fields["props"] = ["safe_url": true, "attachments": "malformed"]
        let malformed = try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(malformed.message, "Synthetic bot"); XCTAssertEqual(malformed.props?.safe_url, true); XCTAssertTrue(model.botAttachments(for: malformed).isEmpty)
    }
    func testAcknowledgedActionRefreshesCanonicalCardWithoutChangingDraftAndNoAutomaticRepeat() async throws {
        let model = try await model(), post = try BotProtocol.post(), selected = try selection(post)
        model.draft = "Keep unsent"
        try await model.triggerBotAction(post, selection: selected)
        XCTAssertEqual(BotProtocol.writes, 1); XCTAssertEqual(model.botActionStatus[post.id], "Action sent")
        XCTAssertEqual(model.posts.first?.props?.attachments?[1]["text"]?.string, "Canonical updated card")
        XCTAssertTrue(model.uncertainBotActions.isEmpty); XCTAssertTrue(model.botActionsPending.isEmpty); XCTAssertFalse(model.pendingMessageActions.contains(post.id)); XCTAssertEqual(model.draft, "Keep unsent")
    }
    func testFreshChangedActionIsRenderedAndRejectedBeforeDispatch() async throws {
        let model = try await model(), post = try BotProtocol.post(), selected = try selection(post)
        BotProtocol.card["callback_id"] = "changed-callback"
        do { try await model.triggerBotAction(post, selection: selected); XCTFail("Stale callback submitted") } catch let e as ChatBotActionFailure { XCTAssertFalse(e.uncertain) }
        XCTAssertEqual(BotProtocol.writes, 0); XCTAssertEqual(model.posts.first?.props?.attachments?[1]["callback_id"]?.string, "changed-callback")
    }
    func testDeletedOrDifferentAuthorCannotReceiveAction() async throws {
        let model = try await model(), post = try BotProtocol.post(), selected = try selection(post)
        BotProtocol.creatorID = 11
        do { try await model.triggerBotAction(post, selection: selected); XCTFail("Changed author accepted") } catch { }
        BotProtocol.creatorID = 6; BotProtocol.deleted = true
        do { try await model.triggerBotAction(post, selection: selected); XCTFail("Deleted message accepted") } catch { }
        XCTAssertEqual(BotProtocol.writes, 0)
    }
    func testUnknownOutcomeCannotRepeatAndUnchangedReadDoesNotClearIt() async throws {
        let model = try await model(), post = try BotProtocol.post(), selected = try selection(post)
        BotProtocol.loseReply = true
        do { try await model.triggerBotAction(post, selection: selected); XCTFail("Lost reply confirmed") } catch let e as ChatBotActionFailure { XCTAssertTrue(e.uncertain) }
        XCTAssertNotNil(model.uncertainBotActions[post.id]); XCTAssertFalse(model.canTriggerBotAction(post, selection: selected))
        do { try await model.triggerBotAction(post, selection: selected); XCTFail("Uncertain action repeated") } catch { }
        try await model.checkBotActionMessage(post)
        XCTAssertNotNil(model.uncertainBotActions[post.id]); XCTAssertEqual(BotProtocol.writes, 1)
        BotProtocol.card["text"] = "Changed elsewhere"
        try await model.checkBotActionMessage(post)
        XCTAssertTrue(model.uncertainBotActions.isEmpty); XCTAssertEqual(BotProtocol.writes, 1)
    }
    func testAcknowledgementWithFailedRefreshStaysAcknowledged() async throws {
        let model = try await model(), post = try BotProtocol.post(), selected = try selection(post)
        BotProtocol.rejectReadsAfterWrite = true
        try await model.triggerBotAction(post, selection: selected)
        XCTAssertEqual(BotProtocol.writes, 1); XCTAssertTrue(model.uncertainBotActions.isEmpty)
        XCTAssertTrue(model.botActionStatus[post.id]?.hasPrefix("Action sent.") == true)
    }
    func testCancellationAfterDispatchRetainsUnknownOutcomeAndNoOldReadback() async throws {
        let model = try await model(), post = try BotProtocol.post(), selected = try selection(post), sent = expectation(description: "Attachment held")
        BotProtocol.hold = true; BotProtocol.onWrite = { sent.fulfill() }
        let task = Task { try await model.triggerBotAction(post, selection: selected) }
        await fulfillment(of: [sent], timeout: 2); task.cancel(); BotProtocol.held?.finish(["success": true]); BotProtocol.held = nil
        do { try await task.value; XCTFail("Cancelled action published") } catch { }
        XCTAssertEqual(BotProtocol.writes, 1); XCTAssertNotNil(model.uncertainBotActions[post.id]); XCTAssertTrue(model.botActionsPending.isEmpty)
    }
    func testSignOutAfterDispatchCannotRestoreActionStateOrMessages() async throws {
        let model = try await model(), post = try BotProtocol.post(), selected = try selection(post), sent = expectation(description: "Attachment held")
        BotProtocol.hold = true; BotProtocol.onWrite = { sent.fulfill() }
        let task = Task { try await model.triggerBotAction(post, selection: selected) }
        await fulfillment(of: [sent], timeout: 2); model.signOutLocally(); BotProtocol.held?.finish(["success": true]); BotProtocol.held = nil
        do { try await task.value; XCTFail("Old account action published") } catch is CancellationError { }
        XCTAssertTrue(model.botActionStatus.isEmpty); XCTAssertTrue(model.uncertainBotActions.isEmpty); XCTAssertTrue(model.posts.isEmpty); XCTAssertTrue(model.botActionsPending.isEmpty)
    }
    func testUnsupportedMalformedOversizedAndOverdeepPayloadsCannotBeSubmitted() async throws {
        let api = try await api(), post = try BotProtocol.post()
        let unsupported = try selection(post, action: 0)
        do { try await api.triggerBotAttachment(postID: post.id, selection: unsupported); XCTFail("Select submitted") } catch { }
        var raw = try XCTUnwrap(post.props?.attachments?[1])
        guard case .object(var card) = raw else { return XCTFail("Missing card") }
        card["callback_id"] = .string(String(repeating: "x", count: 8193)); raw = .object(card)
        XCTAssertThrowsError(try ChatBotActionSelection(attachmentIndex: 1, actionIndex: 1, attachment: raw).payload())
        var deep = ChatJSON.string("value")
        for _ in 0..<10 { deep = .object(["nested": deep]) }
        card["callback_id"] = deep
        XCTAssertThrowsError(try ChatBotActionSelection(attachmentIndex: 1, actionIndex: 1, attachment: .object(card)).payload())
        XCTAssertEqual(BotProtocol.writes, 0)
    }
    func testReplyActionRefreshesTheCurrentThreadWithoutChangingItsRoot() async throws {
        let model = try await model()
        BotProtocol.threadID = 500
        let reply = try BotProtocol.post(), selected = try selection(reply)
        var rootFields = BotProtocol.fields; rootFields["post_id"] = 500; rootFields["thread_id"] = 0
        let root = try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: rootFields))
        model.posts = [root]; model.threadRoot = root; model.replies = [reply]
        try await model.triggerBotAction(reply, selection: selected)
        XCTAssertEqual(BotProtocol.writes, 1); XCTAssertEqual(model.threadRoot?.id, 500)
        XCTAssertEqual(model.replies.first?.props?.attachments?[1]["text"]?.string, "Canonical updated card")
        XCTAssertTrue(model.uncertainBotActions.isEmpty)
    }
    func testForwardedOfflineWrongChannelAndMissingThreadContextAreReadOnly() async throws {
        let model = try await model(), post = try BotProtocol.post(), selected = try selection(post)
        model.liveStatus = .offline; XCTAssertFalse(model.canTriggerBotAction(post, selection: selected))
        model.liveStatus = .live; model.selection = nil; XCTAssertFalse(model.canTriggerBotAction(post, selection: selected))
        model.selection = 93
        var fields = BotProtocol.fields; fields["thread_id"] = 500
        let reply = try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertFalse(model.canTriggerBotAction(reply, selection: try selection(reply)))
        var props = fields["props"] as! [String: Any]; props["encrypted"] = true; fields["props"] = props
        let encrypted = try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertTrue(model.botAttachments(for: encrypted).isEmpty); XCTAssertFalse(model.canTriggerBotAction(encrypted, selection: selected))
        fields["thread_id"] = 0; props["encrypted"] = false
        props["forward"] = ["origin_channel_id": 93, "origin_post_id": 600, "origin_user_id": 6]
        fields["props"] = props
        let forwarded = try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertNotNil(forwarded.props?.forward); XCTAssertFalse(model.canTriggerBotAction(forwarded, selection: selected))
        XCTAssertEqual(BotProtocol.writes, 0)
    }
}

private final class BotProtocol: URLProtocol {
    static var card: [String: Any] = [:]
    static var writes = 0, creatorID = 6
    static var threadID: Int64 = 0
    static var deleted = false, loseReply = false, hold = false, rejectReadsAfterWrite = false, cardsRemoved = false
    static var lastFields: [String: String]?, held: BotProtocol?, onWrite: (() -> Void)?
    static var fields: [String: Any] { ["post_id": 700, "channel_id": 93, "creator_id": creatorID, "thread_id": threadID, "type": "normal", "message": "Synthetic bot", "create_at": 1000, "delete_at": deleted ? 2000 : 0, "props": ["safe_url": true, "attachments": cardsRemoved ? [] : [NSNull(), card]]] }
    static func post() throws -> ChatPost { try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: fields)) }
    static func reset() { card = ["text": "Synthetic card", "callback_id": "callback-👋", "actions": [["type": "select", "text": "Unsupported"], ["type": "button", "name": NSNull(), "value": ["id": Int64(9_007_199_254_740_993)], "text": "Run action", "style": "primary", "url": "https://ignored.invalid/callback"]]]; writes = 0; creatorID = 6; threadID = 0; deleted = false; loseReply = false; hold = false; rejectReadsAfterWrite = false; cardsRemoved = false; lastFields = nil; held = nil; onWrite = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" {
            let names = ["SYNO.Chat.Post", "SYNO.Chat.Post.Attachment", "SYNO.Chat.Channel"]
            finish(["success": true, "data": Dictionary(uniqueKeysWithValues: names.map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 5, "requestFormat": "JSON"] as [String: Any]) })]); return
        }
        if api == "SYNO.Chat.Post" {
            if Self.rejectReadsAfterWrite, Self.writes > 0 { finish(["success": false, "error": ["code": 117]]); return }
            finish(["success": true, "data": ["posts": [Self.fields]]]); return
        }
        if api == "SYNO.Chat.Channel" { finish(["success": true]); return }
        if api == "SYNO.Chat.Post.Attachment" {
            Self.writes += 1
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) } }
            var q = URLComponents(); q.percentEncodedQuery = String(decoding: data, as: UTF8.self)
            Self.lastFields = Dictionary((q.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            if Self.hold { Self.held = self; Self.onWrite?(); return }
            if Self.loseReply { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            Self.card["text"] = "Canonical updated card"; finish(["success": true]); return
        }
        finish(["success": false, "error": ["code": 102]])
    }
    func finish(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: value); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
