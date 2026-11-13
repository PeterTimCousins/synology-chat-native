import XCTest
@testable import SynologyChatNative

@MainActor final class ChatBotSubscriptionTests: XCTestCase {
    override func setUp() { super.setUp(); BotSubscriptionProtocol.reset() }
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-bot-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }; return folder
    }
    private func model(journal: ChatBotSubscriptionJournal? = nil) async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [BotSubscriptionProtocol.self]
            return try ChatAPIClient(session: session, network: URLSession(configuration: c))
        }, botSubscriptionJournal: journal)
        await model.connect(using: account())
        XCTAssertTrue(model.connected, model.error ?? "Connection failed"); model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() }; return model
    }
    private func account() -> ChatAccount { .init(session: .init(baseURL: URL(string: "https://bot-subscriptions.invalid")!, sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false) }
    private func entry(_ model: NativeChatPreviewModel) async throws -> (ChatBotCatalogue, ChatBotEntry) { let c = try await model.loadBots(); return (c, try XCTUnwrap(c.entries.first { $0.id == 16 })) }
    func testFixtureNetworkCannotReachAnyNonFixtureHost() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BotSubscriptionProtocol.self]
        let network = URLSession(configuration: config); defer { network.invalidateAndCancel() }
        do { _ = try await network.data(from: URL(string: "https://not-the-fixture.invalid/never")!); XCTFail("Non-fixture request escaped") } catch let error as URLError { XCTAssertEqual(error.code, .unsupportedURL) }
        XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
    }
    func testCatalogueIncludesHiddenExistingBotButNeverUndiscoveredHiddenBotsOrOtherUserTypes() async throws {
        let model = try await model(); BotSubscriptionProtocol.hidden = true
        var c = try await model.loadBots(); XCTAssertEqual(c.entries.map(\.id), [16])
        BotSubscriptionProtocol.hasChannel = false; c = try await model.loadBots(); XCTAssertTrue(c.entries.isEmpty)
        BotSubscriptionProtocol.hidden = false; c = try await model.loadBots(); XCTAssertEqual(c.entries.map(\.id), [16])
        BotSubscriptionProtocol.disabled = true; c = try await model.loadBots(); XCTAssertTrue(c.entries.isEmpty)
        BotSubscriptionProtocol.disabled = false; BotSubscriptionProtocol.deleted = true; c = try await model.loadBots(); XCTAssertTrue(c.entries.isEmpty)
        BotSubscriptionProtocol.deleted = false; BotSubscriptionProtocol.kind = "slash"; c = try await model.loadBots(); XCTAssertTrue(c.entries.isEmpty)
        XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
    }
    func testDuplicateBotChannelsAndMalformedPropertiesFailClosed() async throws {
        let model = try await model(); BotSubscriptionProtocol.malformedProps = true
        let c = try await model.loadBots(); XCTAssertTrue(c.entries.isEmpty)
        BotSubscriptionProtocol.malformedProps = false; BotSubscriptionProtocol.duplicateChannel = true
        do { _ = try await model.loadBots(); XCTFail("Duplicate bot channel accepted") } catch { }
        XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
    }
    func testBlockedListRejectsDuplicateAndReservedIDs() async throws {
        let model = try await model()
        for ids: [Int64] in [[16, 16], [1], [-1]] {
            BotSubscriptionProtocol.blockedOverride = ids
            do { _ = try await model.loadBots(); XCTFail("Malformed blocked list accepted") } catch { }
        }
        XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
    }
    func testOpenExistingBotRoutesWithoutInitiationAndPreservesOtherDraft() async throws {
        let model = try await model(), (c, bot) = try await entry(model)
        model.selection = 93; model.draft = "Keep this human conversation draft"
        let opened = try await model.openBot(bot, catalogue: c); XCTAssertTrue(opened); XCTAssertEqual(model.selection, 46)
        XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
        model.selection = 93; XCTAssertEqual(model.draft, "Keep this human conversation draft")
    }
    func testRefreshingBotCataloguePreservesClosedChannelExclusionAndDraft() async throws {
        let model = try await model(); model.selection = 93; model.draft = "Keep closed chat draft"
        BotSubscriptionProtocol.closedHuman = true
        _ = try await model.loadBots()
        XCTAssertFalse(model.channels.contains { $0.id == 93 }); XCTAssertNil(model.selection)
        model.selection = 93; XCTAssertEqual(model.draft, "Keep closed chat draft")
        XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
    }
    func testOpeningBotWithOtherHumanMemberIsRejectedWithoutAction() async throws {
        let model = try await model(), (c, bot) = try await entry(model)
        model.selection = 93; BotSubscriptionProtocol.botMembers = [10, 6]
        do { _ = try await model.openBot(bot, catalogue: c); XCTFail("Other human bot channel opened") } catch { }
        XCTAssertEqual(model.selection, 93); XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
    }
    func testNewSubscriptionUsesOnlyUserIDAndVerifiesCanonicalMembership() async throws {
        BotSubscriptionProtocol.hasChannel = false
        let model = try await model(), (c, bot) = try await entry(model)
        let opened = try await model.openBot(bot, catalogue: c); XCTAssertTrue(opened); XCTAssertEqual(model.selection, 46)
        XCTAssertTrue(model.pendingBotSubscriptions.isEmpty)
        let f = try XCTUnwrap(BotSubscriptionProtocol.mutations.first)
        XCTAssertEqual(f["api"], "SYNO.Chat.Channel.Chatbot"); XCTAssertEqual(f["version"], "1"); XCTAssertEqual(f["method"], "initiate"); XCTAssertEqual(f["user_id"], "16")
        XCTAssertNil(f["message"]); XCTAssertNil(f["url"]); XCTAssertNil(f["channel_id"])
        XCTAssertEqual(BotSubscriptionProtocol.mutations.count, 1); XCTAssertEqual(BotSubscriptionProtocol.postCreates, 0)
    }
    func testUnsubscribeChangesOnlyPersonalBlockedStateAndPreservesDraft() async throws {
        let model = try await model(), (c, bot) = try await entry(model)
        model.selection = 46; model.draft = "Unsent bot draft"
        let after = try await model.unsubscribeBot(bot, catalogue: c)
        XCTAssertTrue(after.blockedIDs.contains(16)); XCTAssertNil(model.selection); XCTAssertFalse(model.channels.contains { $0.id == 46 })
        model.selection = 46; XCTAssertEqual(model.draft, "Unsent bot draft"); XCTAssertFalse(model.canRead(46))
        XCTAssertEqual(BotSubscriptionProtocol.mutations.map { $0["method"] ?? "" }, ["block"])
        XCTAssertEqual(BotSubscriptionProtocol.mutations.first?["user_id"], "16"); XCTAssertNil(BotSubscriptionProtocol.mutations.first?["real_delete"])
    }
    func testUnsubscribeRefusesSharedMembershipAndChangedMetadata() async throws {
        let model = try await model(), (c, bot) = try await entry(model)
        BotSubscriptionProtocol.botMembers = [10, 6]
        do { _ = try await model.unsubscribeBot(bot, catalogue: c); XCTFail() } catch { }
        BotSubscriptionProtocol.botMembers = [10]; BotSubscriptionProtocol.name = "Changed elsewhere"
        do { _ = try await model.unsubscribeBot(bot, catalogue: c); XCTFail() } catch { }
        XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
    }
    func testAnotherClientCompletingSubscriptionAfterInitialCheckDoesNotCauseDuplicateRequest() async throws {
        BotSubscriptionProtocol.hasChannel = false
        let model = try await model(), (c, bot) = try await entry(model)
        BotSubscriptionProtocol.subscribeAfterNextCatalogue = true
        let routed = try await model.openBot(bot, catalogue: c)
        XCTAssertTrue(routed); XCTAssertEqual(model.selection, 46)
        XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty); XCTAssertTrue(model.pendingBotSubscriptions.isEmpty)
    }
    func testLostSubscribeReplyPersistsAcrossRelaunchWithoutRetryAndReadResolvesIt() async throws {
        BotSubscriptionProtocol.hasChannel = false
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (c, bot) = try await entry(model)
        BotSubscriptionProtocol.loseReply = true
        do { _ = try await model.openBot(bot, catalogue: c); XCTFail() } catch { }
        XCTAssertNotNil(model.pendingBotSubscriptions[16]); XCTAssertEqual(BotSubscriptionProtocol.mutations.count, 1)
        model.signOutLocally()
        let next = try await self.model(journal: .init(directory: dir))
        XCTAssertNotNil(next.pendingBotSubscriptions[16]); XCTAssertEqual(BotSubscriptionProtocol.mutations.count, 1)
        let (resolved, existing) = try await entry(next)
        XCTAssertTrue(next.pendingBotSubscriptions.isEmpty); let opened = try await next.openBot(existing, catalogue: resolved); XCTAssertTrue(opened)
        XCTAssertEqual(BotSubscriptionProtocol.mutations.count, 1)
    }
    func testUnappliedUnknownSubscriptionCannotRepeatEvenAfterReload() async throws {
        BotSubscriptionProtocol.hasChannel = false
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (c, bot) = try await entry(model)
        BotSubscriptionProtocol.loseReply = true; BotSubscriptionProtocol.ignoreMutation = true
        do { _ = try await model.openBot(bot, catalogue: c); XCTFail() } catch { }
        _ = try await model.loadBots(); do { _ = try await model.openBot(bot, catalogue: c); XCTFail() } catch { }
        model.signOutLocally(); let next = try await self.model(journal: .init(directory: dir)), (latest, same) = try await entry(next)
        XCTAssertNotNil(next.pendingBotSubscriptions[16]); do { _ = try await next.openBot(same, catalogue: latest); XCTFail() } catch { }
        XCTAssertEqual(BotSubscriptionProtocol.mutations.count, 1)
    }
    func testLostUnsubscribeReplyBlocksComposerAndReadOnlyRecoveryRestoresState() async throws {
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (c, bot) = try await entry(model)
        model.selection = 46; model.draft = "Do not send"; BotSubscriptionProtocol.loseReply = true
        do { _ = try await model.unsubscribeBot(bot, catalogue: c); XCTFail() } catch { }
        XCTAssertFalse(model.canRead(46)); XCTAssertFalse(model.canInteract); XCTAssertFalse(model.canSend)
        model.selection = 93; XCTAssertTrue(model.canInteract)
        model.signOutLocally(); let next = try await self.model(journal: .init(directory: dir))
        XCTAssertNotNil(next.pendingBotSubscriptions[16]); let loaded = try await next.loadBots()
        XCTAssertTrue(loaded.blockedIDs.contains(16)); XCTAssertTrue(next.pendingBotSubscriptions.isEmpty); XCTAssertEqual(BotSubscriptionProtocol.mutations.count, 1)
    }
    func testInitiateWithWrongChannelTypeOrMembersRemainsUnconfirmed() async throws {
        for badType in [true, false] {
            BotSubscriptionProtocol.reset(); BotSubscriptionProtocol.hasChannel = false
            let model = try await model(), (c, bot) = try await entry(model)
            if badType { BotSubscriptionProtocol.responseType = "anonymous" } else { BotSubscriptionProtocol.botMembers = [10, 6] }
            do { _ = try await model.openBot(bot, catalogue: c); XCTFail() } catch { }
            XCTAssertNotNil(model.pendingBotSubscriptions[16]); XCTAssertNil(model.selection); XCTAssertEqual(BotSubscriptionProtocol.mutations.count, 1)
        }
    }
    func testLateAcknowledgementDoesNotSwitchNewConversationOrDuplicateSubscription() async throws {
        BotSubscriptionProtocol.hasChannel = false
        let model = try await model(), (c, bot) = try await entry(model), held = expectation(description: "Subscribe held")
        model.selection = 93; BotSubscriptionProtocol.holdReply = true; BotSubscriptionProtocol.onHeld = { held.fulfill() }
        let action = Task { try await model.openBot(bot, catalogue: c) }
        await fulfillment(of: [held], timeout: 2); model.selection = 94
        BotSubscriptionProtocol.release()
        let routed = try await action.value; XCTAssertFalse(routed); XCTAssertEqual(model.selection, 94); XCTAssertTrue(model.pendingBotSubscriptions.isEmpty)
        XCTAssertEqual(BotSubscriptionProtocol.mutations.count, 1)
    }
    func testSignOutBeforeDispatchClearsOnlyUndispatchedReceipt() async throws {
        BotSubscriptionProtocol.hasChannel = false
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (c, bot) = try await entry(model), held = expectation(description: "Post-journal read held")
        BotSubscriptionProtocol.holdBlockedReadAt = BotSubscriptionProtocol.blockedReads + 2
        BotSubscriptionProtocol.onHeld = { held.fulfill() }
        let action = Task { try await model.openBot(bot, catalogue: c) }
        await fulfillment(of: [held], timeout: 2); XCTAssertNotNil(model.pendingBotSubscriptions[16]); model.signOutLocally(); BotSubscriptionProtocol.release()
        do { _ = try await action.value; XCTFail() } catch is CancellationError { }
        let next = try await self.model(journal: .init(directory: dir))
        XCTAssertTrue(next.pendingBotSubscriptions.isEmpty); XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
    }
    func testSignOutDuringRequestRetainsDurableReceiptAndCannotRouteOldAccount() async throws {
        BotSubscriptionProtocol.hasChannel = false
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (c, bot) = try await entry(model), held = expectation(description: "Subscribe held")
        BotSubscriptionProtocol.holdReply = true; BotSubscriptionProtocol.onHeld = { held.fulfill() }
        let action = Task { try await model.openBot(bot, catalogue: c) }
        await fulfillment(of: [held], timeout: 2); model.signOutLocally(); BotSubscriptionProtocol.release()
        do { _ = try await action.value; XCTFail() } catch is CancellationError { }
        XCTAssertFalse(model.connected); XCTAssertNil(model.selection)
        let next = try await self.model(journal: .init(directory: dir)); XCTAssertNotNil(next.pendingBotSubscriptions[16])
        _ = try await next.loadBots(); XCTAssertTrue(next.pendingBotSubscriptions.isEmpty); XCTAssertEqual(BotSubscriptionProtocol.mutations.count, 1)
    }
    func testCorruptedJournalDisablesMutationsWithoutBreakingAccountSignIn() async throws {
        let dir = try folder(), scope = try XCTUnwrap(ChatNotificationAccountScope.make(account: account(), userID: 10))
        try Data("corrupt".utf8).write(to: dir.appendingPathComponent(scope + ".json"))
        let model = try await model(journal: .init(directory: dir)), (c, bot) = try await entry(model)
        XCTAssertNotNil(model.botSubscriptionRecoveryError); model.selection = 46; XCTAssertFalse(model.canInteract)
        do { _ = try await model.openBot(bot, catalogue: c); XCTFail() } catch { }
        do { _ = try await model.unsubscribeBot(bot, catalogue: c); XCTFail() } catch { }
        XCTAssertTrue(BotSubscriptionProtocol.mutations.isEmpty)
    }
    func testJournalScopesPermissionsNoNamesAndStaleWriterProtection() throws {
        let dir = try folder(), scope = String(repeating: "a", count: 64), first = ChatBotSubscriptionJournal(directory: dir), second = ChatBotSubscriptionJournal(directory: dir)
        let old = ChatBotSubscriptionIntent(botID: 16, blocked: true, priorChannelID: 46)
        _ = try first.activate(scope: scope); try first.remember(old); XCTAssertEqual(try second.activate(scope: scope), [old])
        let file = dir.appendingPathComponent(scope + ".json"), raw = try String(contentsOf: file)
        XCTAssertFalse(raw.contains("Calendar")); XCTAssertFalse(raw.contains("token")); XCTAssertFalse(raw.contains("https"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try second.remove(old); let replacement = ChatBotSubscriptionIntent(botID: 16, blocked: false, priorChannelID: 46); try second.remember(replacement)
        XCTAssertThrowsError(try first.remove(old)); XCTAssertThrowsError(try first.remember(old))
        XCTAssertEqual(try ChatBotSubscriptionJournal(directory: dir).activate(scope: scope), [replacement])
        XCTAssertTrue(try ChatBotSubscriptionJournal(directory: dir).activate(scope: String(repeating: "b", count: 64)).isEmpty)
    }
    func testUndispatchedCleanupIsBoundToOriginalAccountAndOperation() throws {
        let dir = try folder(), a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64), journal = ChatBotSubscriptionJournal(directory: dir)
        let old = ChatBotSubscriptionIntent(botID: 16, blocked: false, priorChannelID: nil)
        _ = try journal.activate(scope: a); try journal.remember(old)
        _ = try journal.activate(scope: b); let current = ChatBotSubscriptionIntent(botID: 16, blocked: true, priorChannelID: 46); try journal.remember(current)
        try journal.removeUndispatched(old, originalScope: a)
        XCTAssertEqual(try ChatBotSubscriptionJournal(directory: dir).activate(scope: b), [current])
        XCTAssertTrue(try ChatBotSubscriptionJournal(directory: dir).activate(scope: a).isEmpty)
    }
    func testJournalRejectsInvalidIDsAndSymlinkOrWrongScopeFiles() throws {
        let dir = try folder(), scope = String(repeating: "a", count: 64), journal = ChatBotSubscriptionJournal(directory: dir)
        XCTAssertThrowsError(try journal.activate(scope: "invalid")); _ = try journal.activate(scope: scope)
        for record in [ChatBotSubscriptionIntent(botID: 1, blocked: true, priorChannelID: nil), .init(botID: 16, blocked: false, priorChannelID: 0)] { XCTAssertThrowsError(try journal.remember(record)) }
        let file = dir.appendingPathComponent(scope + ".json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: dir.appendingPathComponent("missing"))
        XCTAssertThrowsError(try ChatBotSubscriptionJournal(directory: dir).activate(scope: scope))
        try FileManager.default.removeItem(at: file)
        let payload: [String: Any] = ["version": 1, "scope": String(repeating: "b", count: 64), "records": []]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        XCTAssertThrowsError(try ChatBotSubscriptionJournal(directory: dir).activate(scope: scope))
    }
}

private final class BotSubscriptionProtocol: URLProtocol, @unchecked Sendable {
    static var blockedReads = 0, holdBlockedReadAt: Int?
    static var subscribeAfterNextCatalogue = false
    static var closedHuman = false
    static var hasChannel = true, blocked = false, hidden = false, disabled = false, deleted = false, malformedProps = false, duplicateChannel = false
    static var loseReply = false, ignoreMutation = false, holdReply = false
    static var name = "Calendar", kind = "chatbot", responseType = "chatbot"
    static var botMembers: [Int64] = [10], blockedOverride: [Int64]?
    static var mutations: [[String: String]] = [], postCreates = 0
    static var held: (BotSubscriptionProtocol, [String: Any])?, onHeld: (() -> Void)?
    static func reset() { blockedReads = 0; holdBlockedReadAt = nil; subscribeAfterNextCatalogue = false; closedHuman = false; hasChannel = true; blocked = false; hidden = false; disabled = false; deleted = false; malformedProps = false; duplicateChannel = false; loseReply = false; ignoreMutation = false; holdReply = false; name = "Calendar"; kind = "chatbot"; responseType = "chatbot"; botMembers = [10]; blockedOverride = nil; mutations = []; postCreates = 0; held = nil; onHeld = nil }
    static var human: [String: Any] { ["user_id": 10, "username": "synthetic", "nickname": "Peter", "type": "human", "human_type": "dsm"] }
    static var bot: [String: Any] {
        let props: [String: Any] = malformedProps ? ["purpose": "Missing privacy field"] : ["hide_from_user": hidden, "purpose": "Synthetic calendar bot", "welcome_note": "Welcome"]
        return ["user_id": 16, "nickname": name, "type": "bot", "bot_type": kind, "is_disabled": disabled, "deleted": deleted, "chatbot_props": props]
    }
    static var channel: [String: Any] { ["channel_id": 46, "name": "", "type": "chatbot", "creator_id": 16, "encrypted": false, "unread": 0, "is_joined": !blocked, "hide_global_at": 0] }
    static var humanChannels: [[String: Any]] { [93, 94].map { ["channel_id": $0, "name": "Synthetic human chat \($0)", "is_closed": closedHuman && $0 == 93, "type": "anonymous", "encrypted": false, "unread": 0, "is_joined": true] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "bot-subscriptions.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" { finish(Dictionary(uniqueKeysWithValues: ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Channel.Member", "SYNO.Chat.Channel.Chatbot", "SYNO.Chat.Post"].map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 5, "requestFormat": "JSON"] as [String: Any]) })); return }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var b = [UInt8](repeating: 0, count: 2048); while stream.hasBytesAvailable { let n = stream.read(&b, maxLength: b.count); if n <= 0 { break }; data.append(contentsOf: b.prefix(n)) } }
        var query = URLComponents(); query.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let f = Dictionary((query.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last }), method = f["method"] ?? ""
        if api == "SYNO.Chat.User" { finish(["users": [Self.human, Self.bot]]); return }
        if api == "SYNO.Chat.Channel" {
            if method != "list" { finish([:]); return }
            var bots = Self.hasChannel && (f["is_joined"] == "false") == Self.blocked ? [Self.channel] : []
            if Self.duplicateChannel && !bots.isEmpty { var duplicate = Self.channel; duplicate["channel_id"] = 47; bots.append(duplicate) }
            finish(["channels": (f["is_joined"] == "false" ? [] : Self.humanChannels) + bots]); return
        }
        if api == "SYNO.Chat.Channel.Member" { finish(["user_ids": f["channel_id"] == "46" ? Self.botMembers : [10, 6]]); return }
        if api == "SYNO.Chat.Post" { if method == "create" { Self.postCreates += 1 }; finish(["posts": []]); return }
        guard api == "SYNO.Chat.Channel.Chatbot" else { finish([:]); return }
        if method == "list_blocked" { Self.blockedReads += 1; let value = Self.blockedOverride ?? (Self.blocked ? [16] : []); if Self.holdBlockedReadAt == Self.blockedReads { Self.holdBlockedReadAt = nil; Self.held = (self, ["blocked_user_ids": value]); Self.onHeld?(); return }; if Self.subscribeAfterNextCatalogue { Self.subscribeAfterNextCatalogue = false; Self.hasChannel = true; Self.blocked = false }; finish(["blocked_user_ids": value]); return }
        Self.mutations.append(f)
        if !Self.ignoreMutation { if method == "initiate" { Self.hasChannel = true; Self.blocked = false } else if method == "block" { Self.blocked = true } }
        var value = method == "initiate" ? Self.channel : [:]; if method == "initiate" { value["type"] = Self.responseType }
        if Self.holdReply { Self.holdReply = false; Self.held = (self, value); Self.onHeld?(); return }
        if Self.loseReply { Self.loseReply = false; client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        finish(value)
    }
    static func release() { if let held { Self.held = nil; held.0.finish(held.1) } }
    private func finish(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: ["success": true, "data": value]); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
