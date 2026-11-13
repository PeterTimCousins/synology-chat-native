import XCTest
@testable import SynologyChatNative

@MainActor final class ChatWebhookTests: XCTestCase {
    override func setUp() { super.setUp(); WebhookProtocol.reset() }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WebhookProtocol.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://webhooks.invalid/chat")!, sid: "synthetic-session", synoToken: "synthetic-csrf"), network: URLSession(configuration: config))
        try await api.discover(); return api
    }
    private func model(journal:ChatWebhookActionJournal? = nil,server:String = "webhooks.invalid") async throws -> NativeChatPreviewModel {
        let m = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WebhookProtocol.self]
            return try ChatAPIClient(session: session, network: URLSession(configuration: config))
        },webhookActionJournal:journal)
        await m.connect(using: .init(session: .init(baseURL: URL(string: "https://" + server)!, sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false))
        XCTAssertTrue(m.connected, m.error ?? "No error")
        addTeardownBlock { @MainActor in m.signOutLocally() }; return m
    }
    private func recoveryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath:"/private/tmp/native-webhook-recovery-test-" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return directory
    }
    func testLostCreationRemainsBlockedAfterNewModelAndDoesNotPersistSecrets() async throws {
        let directory = try recoveryDirectory(),first = try await model(journal:.init(directory:directory))
        let catalogue = try await first.loadWebhooks();WebhookProtocol.record = [:];WebhookProtocol.loseMethod = "create"
        do { _ = try await first.createWebhook(kind:.incoming,original:catalogue);XCTFail("Accepted lost creation") } catch {}
        first.signOutLocally()
        let restored = try await model(journal:.init(directory:directory)),fresh = try await restored.loadWebhooks()
        XCTAssertTrue(restored.uncertainWebhookCreates.contains(.incoming));XCTAssertNil(restored.pendingWebhookActions.values.first?.webhookID)
        let count = WebhookProtocol.writes.count
        do { _ = try await restored.createWebhook(kind:.incoming,original:fresh);XCTFail("Repeated lost creation") } catch {}
        XCTAssertEqual(WebhookProtocol.writes.count,count)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first { $0.pathExtension == "json" })
        let text = try String(contentsOf:file,encoding:.utf8)
        for secret in ["secret-token","new-secret","synthetic-session","synthetic-csrf","callback.invalid"] { XCTAssertFalse(text.contains(secret)) }
    }
    func testAnotherModelCannotClearOrAcknowledgeAnInFlightMultiStepEdit() async throws {
        WebhookProtocol.record["is_disabled"] = false
        let directory = try recoveryDirectory(),first = try await model(journal:.init(directory:directory))
        let original = try await first.loadWebhook(100,kind:.incoming);var draft = ChatWebhookDraft(original.detail);draft.nickname = "Final edited name"
        let started = expectation(description:"Disable stage dispatched")
        WebhookProtocol.holdMethod = "disable";WebhookProtocol.onWrite = { started.fulfill() }
        let action = Task { try await first.saveWebhook(draft,original:original) }
        await fulfillment(of:[started],timeout:2)
        let second = try await model(journal:.init(directory:directory))
        _ = try await second.loadWebhook(100,kind:.incoming)
        let record = try XCTUnwrap(second.pendingWebhookActions.values.first)
        XCTAssertTrue(second.uncertainWebhookIDs.contains(100))
        do { _ = try await second.acknowledgeWebhookOutcome(record);XCTFail("Cleared an active operation") } catch {}
        XCTAssertTrue(second.uncertainWebhookIDs.contains(100));XCTAssertEqual(WebhookProtocol.writes.count,1)
        let response = try XCTUnwrap(WebhookProtocol.heldResponse)
        WebhookProtocol.held?.finish(response);WebhookProtocol.held = nil;WebhookProtocol.heldResponse = nil
        _ = try await action.value
        let final = try await second.loadWebhook(100,kind:.incoming)
        XCTAssertEqual(final.detail.nickname,draft.nickname);XCTAssertFalse(final.detail.is_disabled)
        XCTAssertTrue(second.pendingWebhookActions.isEmpty)
        XCTAssertEqual(WebhookProtocol.writes.map { $0["method"] ?? "" },["disable","set","enable"])
    }
    func testKnownCreationCannotBeClearedWhileItsDisablePipelineIsStillRunning() async throws {
        let directory = try recoveryDirectory(),first = try await model(journal:.init(directory:directory))
        let original = try await first.loadWebhooks();WebhookProtocol.record = [:]
        let started = expectation(description:"Created resource disable dispatched")
        WebhookProtocol.holdMethod = "disable";WebhookProtocol.onWrite = { started.fulfill() }
        let action = Task { try await first.createWebhook(kind:.incoming,original:original) }
        await fulfillment(of:[started],timeout:2)
        let second = try await model(journal:.init(directory:directory))
        _ = try await second.loadWebhook(101,kind:.incoming)
        let record = try XCTUnwrap(second.pendingWebhookActions.values.first)
        XCTAssertEqual(record.webhookID,101);XCTAssertTrue(second.uncertainWebhookCreates.contains(.incoming))
        do { _ = try await second.acknowledgeWebhookOutcome(record);XCTFail("Cleared an active creation") } catch {}
        XCTAssertTrue(second.uncertainWebhookIDs.contains(101));XCTAssertEqual(WebhookProtocol.writes.count,2)
        let response = try XCTUnwrap(WebhookProtocol.heldResponse)
        WebhookProtocol.held?.finish(response);WebhookProtocol.held = nil;WebhookProtocol.heldResponse = nil
        _ = try await action.value
        let final = try await second.loadWebhook(101,kind:.incoming)
        XCTAssertTrue(final.detail.is_disabled);XCTAssertTrue(second.pendingWebhookActions.isEmpty)
        XCTAssertEqual(WebhookProtocol.writes.map { $0["method"] ?? "" },["create","disable"])
    }
    func testLostRotationRestoresFingerprintAndCanonicalReadResolvesWithoutAnotherWrite() async throws {
        let directory = try recoveryDirectory(),first = try await model(journal:.init(directory:directory))
        let original = try await first.loadWebhook(100,kind:.incoming);WebhookProtocol.loseMethod = "regen_token"
        do { _ = try await first.rotateWebhook(original);XCTFail("Accepted lost rotation") } catch {}
        first.signOutLocally()
        let restored = try await model(journal:.init(directory:directory))
        XCTAssertTrue(restored.uncertainWebhookIDs.contains(100));XCTAssertEqual(restored.pendingWebhookActions.values.first?.previousTokenFingerprint,original.detail.token?.fingerprint)
        let count = WebhookProtocol.writes.count
        do { _ = try await restored.rotateWebhook(original);XCTFail("Repeated lost rotation") } catch {}
        let current = try await restored.loadWebhook(100,kind:.incoming)
        XCTAssertNotEqual(current.detail.token,original.detail.token);XCTAssertTrue(restored.pendingWebhookActions.isEmpty)
        XCTAssertEqual(WebhookProtocol.writes.count,count)
    }
    func testUnchangedRotationRequiresExplicitLocalReviewAndAcknowledgementNeverDispatches() async throws {
        let directory = try recoveryDirectory(),first = try await model(journal:.init(directory:directory))
        let original = try await first.loadWebhook(100,kind:.incoming);WebhookProtocol.noRotate = true
        do { _ = try await first.rotateWebhook(original);XCTFail("Accepted unchanged rotation") } catch {}
        first.signOutLocally()
        let restored = try await model(journal:.init(directory:directory))
        _ = try await restored.loadWebhook(100,kind:.incoming)
        XCTAssertTrue(restored.uncertainWebhookIDs.contains(100))
        let record = try XCTUnwrap(restored.pendingWebhookActions.values.first),count = WebhookProtocol.writes.count
        _ = try await restored.acknowledgeWebhookOutcome(record)
        XCTAssertTrue(restored.pendingWebhookActions.isEmpty);XCTAssertEqual(WebhookProtocol.writes.count,count)
    }
    func testUnreadableRecoveryStorageAllowsInspectionButPreventsAllMutations() async throws {
        let directory = try recoveryDirectory(),blocked = directory.appendingPathComponent("not-a-folder")
        try Data("synthetic storage obstacle".utf8).write(to:blocked)
        let model = try await model(journal:.init(directory:blocked))
        XCTAssertNotNil(model.webhookRecoveryError)
        let catalogue = try await model.loadWebhooks(),original = try await model.loadWebhook(100,kind:.incoming)
        var draft = ChatWebhookDraft(original.detail);draft.nickname = "Do not send"
        do { _ = try await model.createWebhook(kind:.incoming,original:catalogue);XCTFail() } catch {}
        do { _ = try await model.rotateWebhook(original);XCTFail() } catch {}
        do { _ = try await model.saveWebhook(draft,original:original);XCTFail() } catch {}
        do { _ = try await model.removeWebhook(original);XCTFail() } catch {}
        XCTAssertTrue(WebhookProtocol.writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf:blocked),Data("synthetic storage obstacle".utf8))
    }
    func testLateCreationAcknowledgementIsCheckpointedOnlyInOriginalAccount() async throws {
        let directory = try recoveryDirectory(),first = try await model(journal:.init(directory:directory))
        let catalogue = try await first.loadWebhooks(),started = expectation(description:"Create dispatched")
        WebhookProtocol.record = [:];WebhookProtocol.holdMethod = "create";WebhookProtocol.onWrite = { started.fulfill() }
        let action = Task { try await first.createWebhook(kind:.incoming,original:catalogue) }
        await fulfillment(of:[started],timeout:2);first.signOutLocally()
        let other = try await model(journal:.init(directory:directory),server:"another-webhooks.invalid")
        XCTAssertTrue(other.pendingWebhookActions.isEmpty)
        let response = try XCTUnwrap(WebhookProtocol.heldResponse)
        WebhookProtocol.held?.finish(response);WebhookProtocol.held = nil;WebhookProtocol.heldResponse = nil
        do { _ = try await action.value;XCTFail("Published old account result") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(other.pendingWebhookActions.isEmpty)
        let restored = try await model(journal:.init(directory:directory))
        XCTAssertEqual(restored.pendingWebhookActions.values.first?.webhookID,101)
        XCTAssertTrue(restored.uncertainWebhookIDs.contains(101));XCTAssertTrue(restored.uncertainWebhookCreates.contains(.incoming))
        XCTAssertEqual(WebhookProtocol.writes.map { $0["method"] ?? "" },["create"],"No old-account disable/readback action may run after sign-out")
    }
    func testLostEditAndRemovalRestoreForInspectionWithoutReplay() async throws {
        let directory = try recoveryDirectory(),first = try await model(journal:.init(directory:directory))
        let original = try await first.loadWebhook(100,kind:.incoming);var draft = ChatWebhookDraft(original.detail);draft.nickname = "Saved despite loss"
        WebhookProtocol.loseMethod = "set"
        do { _ = try await first.saveWebhook(draft,original:original);XCTFail() } catch {}
        first.signOutLocally()
        let restored = try await model(journal:.init(directory:directory));XCTAssertTrue(restored.uncertainWebhookIDs.contains(100))
        let current = try await restored.loadWebhook(100,kind:.incoming)
        XCTAssertEqual(current.detail.nickname,draft.nickname);XCTAssertTrue(restored.pendingWebhookActions.isEmpty)
        WebhookProtocol.loseMethod = "delete"
        do { _ = try await restored.removeWebhook(current);XCTFail() } catch {}
        restored.signOutLocally()
        let third = try await model(journal:.init(directory:directory)),count = WebhookProtocol.writes.count
        XCTAssertTrue(third.uncertainWebhookIDs.contains(100))
        let list = try await third.loadWebhooks()
        XCTAssertFalse(list.entries.contains { $0.id == 100 });XCTAssertTrue(third.pendingWebhookActions.isEmpty)
        XCTAssertEqual(WebhookProtocol.writes.count,count)
    }
    func testSecretDescriptionsAndCallbackRemainRedacted() async throws {
        let value = try await api().webhookDetail(kind: .incoming, id: 100)
        XCTAssertFalse(String(describing: value).contains("secret-token")); XCTAssertFalse(String(reflecting: value).contains("callback-secret"))
        XCTAssertEqual(value.token?.reveal(), "secret-token"); XCTAssertEqual(value.token?.fingerprint.count, 64)
        XCTAssertFalse(String(reflecting: ChatWebhookDraft(value)).contains("callback-secret"))
    }
    func testIncomingURLHasTokenAndNoAccountSessionOrCSRF() async throws {
        let api = try await api(), url = try api.incomingWebhookURL(token: .init("a\" &+?#secret"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/chat/webapi/entry.cgi")
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(Set(fields.keys), ["api", "method", "version", "token"])
        XCTAssertEqual(fields["api"], "SYNO.Chat.External"); XCTAssertEqual(fields["version"], "2"); XCTAssertEqual(fields["method"], "incoming")
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(try XCTUnwrap(fields["token"]).utf8)), "a\" &+?#secret")
        XCTAssertFalse(url.absoluteString.contains("synthetic-session")); XCTAssertFalse(url.absoluteString.contains("synthetic-csrf"))
    }
    func testDeletedAppManagedAndOtherOwnerCannotBeEditedOrHaveSecretsRead() async throws {
        let m = try await model()
        for patch in [["deleted": true], ["app_id": "calendar"], ["creator_id": 6]] as [[String: Any]] {
            WebhookProtocol.reset(); WebhookProtocol.record.merge(patch) { _, new in new }
            do { _ = try await m.loadWebhook(100, kind: .incoming); XCTFail("Unauthorized detail read") } catch { }
            XCTAssertEqual(WebhookProtocol.detailReads, 0); XCTAssertTrue(WebhookProtocol.writes.isEmpty)
        }
    }
    func testACLRemovedPreventsEvenReadingCredentials() async throws {
        let m = try await model(); WebhookProtocol.allowed = false
        do { _ = try await m.loadWebhook(100, kind: .incoming); XCTFail() } catch { }
        XCTAssertEqual(WebhookProtocol.detailReads, 0)
    }
    func testValidationRequiresUnencryptedAvailableDestinationAndValidOutgoingURL() async throws {
        let m = try await model(), original = try await m.loadWebhook(100, kind: .incoming)
        var d = ChatWebhookDraft(original.detail); d.channelID = 999
        XCTAssertThrowsError(try d.validate(kind: .incoming, channels: original.catalogue.channels))
        d.channelID = 0; d.triggerWord = ""; d.callbackURL = "https://callback.invalid/secret"
        XCTAssertThrowsError(try d.validate(kind: .outgoing, channels: original.catalogue.channels))
        d.triggerWord = "ping"; XCTAssertNoThrow(try d.validate(kind: .outgoing, channels: original.catalogue.channels))
        for bad in ["file:///tmp/callback", "javascript:alert(1)", "https://callback.invalid/#fragment", "https://callback.invalid/?SynoToken=secret"] {
            d.callbackURL = bad; XCTAssertThrowsError(try d.validate(kind: .outgoing, channels: original.catalogue.channels))
        }
        d.callbackURL = "https://callback.invalid/"; d.nickname = String(repeating: "😀", count: 17)
        XCTAssertThrowsError(try d.validate(kind: .outgoing, channels: original.catalogue.channels))
    }
    func testActiveSettingsChangeDisablesBeforeConfigAndReenablesOnlyAfterVerification() async throws {
        WebhookProtocol.record["is_disabled"] = false
        let m = try await model(), original = try await m.loadWebhook(100, kind: .incoming)
        var d = ChatWebhookDraft(original.detail); d.nickname = "Renamed"
        let result = try await m.saveWebhook(d, original: original)
        XCTAssertEqual(result.detail.nickname, "Renamed"); XCTAssertFalse(result.detail.is_disabled)
        XCTAssertEqual(WebhookProtocol.writes.map { $0["method"] ?? "missing" }, ["disable", "set", "enable"])
        XCTAssertTrue(WebhookProtocol.writes.allSatisfy { $0["avatar"] == nil && $0["sticker"] == nil })
    }
    func testConcurrentChangeDuringDisableStopsFurtherConfigurationWrites() async throws {
        WebhookProtocol.record["is_disabled"] = false
        let m = try await model(), original = try await m.loadWebhook(100, kind: .incoming)
        var d = ChatWebhookDraft(original.detail); d.nickname = "My change"
        WebhookProtocol.changeOnDisable = true
        do { _ = try await m.saveWebhook(d, original: original); XCTFail() } catch let e as ChatWebhookFailure { XCTAssertTrue(e.uncertain) }
        XCTAssertEqual(WebhookProtocol.writes.map { $0["method"] ?? "missing" }, ["disable"])
        XCTAssertEqual(WebhookProtocol.record["nickname"] as? String, "Concurrent change")
        XCTAssertEqual(WebhookProtocol.record["is_disabled"] as? Bool, true)
    }
    func testChangedRemoteConfigurationStopsAllWrites() async throws {
        let m = try await model(), original = try await m.loadWebhook(100, kind: .incoming)
        var d = ChatWebhookDraft(original.detail); d.nickname = "My change"; WebhookProtocol.record["nickname"] = "Remote change"
        do { _ = try await m.saveWebhook(d, original: original); XCTFail() } catch { }
        XCTAssertTrue(WebhookProtocol.writes.isEmpty)
    }
    func testLostSaveResponseBlocksRepeatUntilCanonicalRead() async throws {
        let m = try await model(), original = try await m.loadWebhook(100, kind: .incoming)
        var d = ChatWebhookDraft(original.detail); d.nickname = "Saved despite loss"; WebhookProtocol.loseMethod = "set"
        do { _ = try await m.saveWebhook(d, original: original); XCTFail() } catch let e as ChatWebhookFailure { XCTAssertTrue(e.uncertain) }
        XCTAssertTrue(m.uncertainWebhookIDs.contains(100)); let count = WebhookProtocol.writes.count
        do { _ = try await m.saveWebhook(d, original: original); XCTFail() } catch { }
        XCTAssertEqual(WebhookProtocol.writes.count, count)
        let refreshed = try await m.loadWebhook(100, kind: .incoming)
        XCTAssertEqual(refreshed.detail.nickname, d.nickname); XCTAssertFalse(m.uncertainWebhookIDs.contains(100))
    }
    func testCreateReturnsKnownDisabledResourceAndLostCreateCannotRepeat() async throws {
        let m = try await model(), catalogue = try await m.loadWebhooks()
        WebhookProtocol.record = [:]
        let result = try await m.createWebhook(kind: .incoming, original: catalogue)
        XCTAssertTrue(result.detail.is_disabled); XCTAssertEqual(result.detail.user_id, 101)
        XCTAssertEqual(WebhookProtocol.writes.map { $0["method"] ?? "missing" }, ["create", "disable"])
        WebhookProtocol.record = [:]; WebhookProtocol.loseMethod = "create"
        do { _ = try await m.createWebhook(kind: .incoming, original: catalogue); XCTFail() } catch { }
        XCTAssertTrue(m.uncertainWebhookCreates.contains(.incoming)); let count = WebhookProtocol.writes.count
        do { _ = try await m.createWebhook(kind: .incoming, original: catalogue); XCTFail() } catch { }
        XCTAssertEqual(WebhookProtocol.writes.count, count)
    }
    func testLostRotationBlocksRepeatAndReadReconcilesNewFingerprint() async throws {
        let m = try await model(), original = try await m.loadWebhook(100, kind: .incoming)
        WebhookProtocol.loseMethod = "regen_token"
        do { _ = try await m.rotateWebhook(original); XCTFail() } catch { }
        let count = WebhookProtocol.writes.count
        do { _ = try await m.rotateWebhook(original); XCTFail() } catch { }
        XCTAssertEqual(WebhookProtocol.writes.count, count)
        let new = try await m.loadWebhook(100, kind: .incoming)
        XCTAssertNotEqual(new.detail.token, original.detail.token); XCTAssertFalse(m.uncertainWebhookIDs.contains(100))
    }
    func testRotationDoesNotUnlockOnUnchangedCredential() async throws {
        let m = try await model(), original = try await m.loadWebhook(100, kind: .incoming)
        WebhookProtocol.noRotate = true
        do { _ = try await m.rotateWebhook(original); XCTFail() } catch { }
        _ = try await m.loadWebhook(100, kind: .incoming)
        XCTAssertTrue(m.uncertainWebhookIDs.contains(100))
    }
    func testRemovalAlwaysSoftDeletesAndVerifiesTombstone() async throws {
        let m = try await model(), original = try await m.loadWebhook(100, kind: .incoming)
        let result = try await m.removeWebhook(original)
        XCTAssertTrue(result.entries.isEmpty); XCTAssertEqual(WebhookProtocol.writes.last?["real_delete"], "false")
    }
    func testStaleAccountSnapshotCannotMutateAndClearsUnknownState() async throws {
        let m = try await model(), original = try await m.loadWebhook(100, kind: .incoming)
        m.signOutLocally()
        do { _ = try await m.removeWebhook(original); XCTFail() } catch { }
        XCTAssertTrue(WebhookProtocol.writes.isEmpty); XCTAssertTrue(m.uncertainWebhookIDs.isEmpty)
    }
    func testOutgoingWireRetainsTriggerAndCallbackAndExcludesIncomingToken() async throws {
        let api = try await api(); var draft = ChatWebhookDraft(); draft.channelID = 93; draft.triggerWord = " hello "; draft.callbackURL = "https://callback.invalid/callback-secret"
        try await api.setWebhookDetails(id: 100, kind: .outgoing, draft: draft)
        let fields = try XCTUnwrap(WebhookProtocol.writes.last)
        XCTAssertEqual(fields["api"], "SYNO.Chat.Webhook.Outgoing"); XCTAssertEqual(fields["version"], "1"); XCTAssertEqual(fields["trigger_word"], "\"hello\"")
        XCTAssertNil(fields["token"]); XCTAssertNil(fields["message"]); XCTAssertEqual(fields["channel_id"], "93")
    }
}

private final class WebhookProtocol: URLProtocol, @unchecked Sendable {
    static var record: [String: Any] = [:], writes: [[String: String]] = []
    static var allowed = true, noRotate = false, changeOnDisable = false
    static var detailReads = 0, nextID = 101
    static var loseMethod: String?
    static var holdMethod:String?,held:WebhookProtocol?,heldResponse:[String:Any]?
    static var onWrite:(()->Void)?
    static func reset() { holdMethod = nil;held = nil;heldResponse = nil;onWrite = nil;record = ["user_id": 100, "creator_id": 10, "nickname": "Synthetic webhook", "type": "bot", "bot_type": "incoming", "channel_id": 93, "is_disabled": true, "deleted": false, "token": "secret-token", "url": "https://callback.invalid/callback-secret", "trigger_word": "ping"]; writes = []; allowed = true; noRotate = false; changeOnDisable = false; detailReads = 0; loseMethod = nil; nextID = 101 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" {
            let names = ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Misc", "SYNO.Chat.Webhook.Incoming", "SYNO.Chat.Webhook.Outgoing", "SYNO.Chat.Bot", "SYNO.Chat.External", "SYNO.Chat.Channel.Member"]
            finish(Dictionary(uniqueKeysWithValues: names.map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 5, "requestFormat": "JSON"] as [String: Any]) })); return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var b = [UInt8](repeating: 0, count: 2048); while stream.hasBytesAvailable { let n = stream.read(&b, maxLength: b.count); if n <= 0 { break }; data.append(contentsOf: b.prefix(n)) } }
        var q = URLComponents(); q.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let f = Dictionary((q.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last }), method = f["method"] ?? ""
        if api == "SYNO.Chat.Misc" { finish(["acls": ["webhook_read", "webhook_create"].map { ["acl_name": $0, "allow": Self.allowed] as [String: Any] }]); return }
        if api == "SYNO.Chat.User" { finish(["users": [["user_id": 10, "username": "synthetic", "nickname": "Peter", "type": "human"] as [String: Any]] + (Self.record.isEmpty ? [] : [Self.record])]); return }
        if api == "SYNO.Chat.Channel.Member" { finish(["user_ids": [10, 6]]); return }
        if api == "SYNO.Chat.Channel" { finish(["channels": f["is_joined"] == "false" ? [] : [["channel_id": 93, "name": "Peter", "type": "anonymous", "encrypted": false, "unread": 0, "is_joined": true]]]); return }
        if method == "get" { Self.detailReads += 1; finish(Self.record); return }
        guard api == "SYNO.Chat.Bot" || api.hasPrefix("SYNO.Chat.Webhook.") else { finish([:]); return }
        Self.writes.append(f)
        switch method {
        case "create": Self.record = ["user_id": Self.nextID, "creator_id": 10, "nickname": "New integration", "type": "bot", "bot_type": api.hasSuffix("Outgoing") ? "outgoing" : "incoming", "channel_id": 0, "is_disabled": false, "token": "new-secret", "deleted": false]; Self.nextID += 1
        case "disable": Self.record["is_disabled"] = true; if Self.changeOnDisable { Self.record["nickname"] = "Concurrent change" }
        case "enable": Self.record["is_disabled"] = false
        case "delete": Self.record["deleted"] = true
        case "regen_token": if !Self.noRotate { Self.record["token"] = "replaced-secret" }
        case "set": for key in ["nickname", "channel_id", "url", "trigger_word"] { if let v = f[key], let parsed = try? JSONSerialization.jsonObject(with: Data(v.utf8), options: [.fragmentsAllowed]) { Self.record[key] = parsed } }
        default: break
        }
        if Self.loseMethod == method { Self.loseMethod = nil; client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let result:[String:Any] = method == "create" ? ["user_id": Self.record["user_id"]!] : method == "regen_token" ? ["token": Self.record["token"]!] : [:]
        if Self.holdMethod == method { Self.held = self;Self.heldResponse = result;Self.onWrite?();return }
        finish(result)
    }
    func finish(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: ["success": true, "data": value]); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
