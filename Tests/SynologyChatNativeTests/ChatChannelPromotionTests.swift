import XCTest
@testable import SynologyChatNative

@MainActor final class ChatChannelPromotionTests: XCTestCase {
    override func setUp() { super.setUp(); PromotionProtocol.reset() }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PromotionProtocol.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://promotion.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: config))
        try await api.discover(); return api
    }
    private func model(journal:ChatChannelPromotionJournal? = nil) async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PromotionProtocol.self]
            return try ChatAPIClient(session: session, network: URLSession(configuration: config))
        },promotionJournal:journal)
        await model.connect(using: .init(session: .init(baseURL: URL(string: "https://promotion.invalid")!, sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false))
        model.liveStatus = .live; model.selection = 93; XCTAssertTrue(model.connected)
        addTeardownBlock { @MainActor in model.signOutLocally() }; return model
    }
    private var draft: ChatChannelPromotionDraft { .init(name: "  Native-private  ", purpose: "  Synthetic purpose  ") }
    func testPromotionV2WireMatchesOfficialFormAndRejectsInvalidInputs() async throws {
        let api = try await api()
        try await api.promoteConversation(channelID: 93, name: draft.name, purpose: draft.purpose)
        let request = try XCTUnwrap(PromotionProtocol.promoteFields)
        XCTAssertEqual(request["version"], "2"); XCTAssertEqual(request["channel_id"], "93")
        XCTAssertEqual(request["name"], #""Native-private""#); XCTAssertEqual(request["purpose"], #""Synthetic purpose""#)
        XCTAssertEqual(request["message_stay"], #""false""#)
        for key in ["members", "user_ids", "encrypted", "type", "channel_key_enc"] { XCTAssertNil(request[key]) }
        for id: Int64 in [0, 1, 2] { do { try await api.promoteConversation(channelID: id, name: "Valid", purpose: ""); XCTFail("Invalid source sent") } catch { } }
        for name in ["", "bad name", "<bad>", String(repeating: "x", count: 65)] { do { try await api.promoteConversation(channelID: 93, name: name, purpose: ""); XCTFail("Invalid name sent") } catch { } }
        XCTAssertEqual(PromotionProtocol.promotes, 1)
    }
    func testInPlaceConversionPreservesDestinationMembersTimelineAndUnsentDraftAndClearsCachedDMTitle() async throws {
        let model = try await model(), snapshot = try await model.loadPromotionSnapshot(channelID: 93)
        XCTAssertEqual(snapshot.memberIDs, [10, 6]); XCTAssertEqual(snapshot.memberNames[6], "Other Peter")
        model.draft = "Keep unsent"; model.posts = [try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":999,"channel_id":93,"creator_id":10,"type":"normal","message":"Synthetic history","create_at":1000}"#.utf8))]
        let result = try await model.promoteConversation(snapshot, draft: draft)
        XCTAssertEqual(result.id, 93); XCTAssertEqual(result.type, "private"); XCTAssertEqual(model.title(result), "Native-private")
        XCTAssertEqual(model.selection, 93); XCTAssertEqual(model.draft, "Keep unsent"); XCTAssertEqual(model.posts.map(\.id), [999])
        XCTAssertEqual(PromotionProtocol.sourceMembers, [10, 6]); XCTAssertEqual(PromotionProtocol.promotes, 1); XCTAssertEqual(PromotionProtocol.creates, 0); XCTAssertEqual(PromotionProtocol.invites, 0)
        XCTAssertTrue(model.pendingPromotions.isEmpty); XCTAssertFalse(model.channelManagementBusy)
    }
    func testNewChannelLeavesOriginalAndInvitesExactlyReviewedPeersOnce() async throws {
        let model = try await model(), snapshot = try await model.loadPromotionSnapshot(channelID: 93)
        model.draft = "Original draft"; var d = draft; d.mode = .newChannel
        let result = try await model.promoteConversation(snapshot, draft: d)
        XCTAssertEqual(result.id, 96); XCTAssertEqual(result.type, "private"); XCTAssertEqual(model.selection, 96)
        XCTAssertEqual(PromotionProtocol.source["type"] as? String, "anonymous"); XCTAssertEqual(PromotionProtocol.sourceMembers, [10, 6]); XCTAssertEqual(PromotionProtocol.targetMembers, [10, 6])
        XCTAssertEqual(PromotionProtocol.inviteFields?["user_ids"], "[6]"); XCTAssertEqual(PromotionProtocol.creates, 1); XCTAssertEqual(PromotionProtocol.joins, 1); XCTAssertEqual(PromotionProtocol.invites, 1); XCTAssertEqual(PromotionProtocol.promotes, 0)
        XCTAssertEqual(PromotionProtocol.createFields?["encrypted"], "false"); XCTAssertEqual(PromotionProtocol.createFields?["type"], #""private""#)
        XCTAssertTrue(model.pendingPromotions.isEmpty)
        model.selection = 93; XCTAssertEqual(model.draft, "Original draft")
    }
    func testFreshMembershipAndPermissionChangesPreventDispatchAndKeepReview() async throws {
        let model = try await model(), snapshot = try await model.loadPromotionSnapshot(channelID: 93)
        PromotionProtocol.sourceMembers = [10]
        do { _ = try await model.promoteConversation(snapshot, draft: draft); XCTFail("Changed members accepted") } catch { }
        PromotionProtocol.sourceMembers = [10, 6]; PromotionProtocol.allowCreate = false
        do { _ = try await model.promoteConversation(snapshot, draft: draft); XCTFail("Revoked create accepted") } catch { }
        XCTAssertEqual(PromotionProtocol.promotes, 0); XCTAssertEqual(PromotionProtocol.creates, 0); XCTAssertTrue(model.pendingPromotions.isEmpty)
    }
    func testUnavailableOrMalformedSourcesAndDisabledMembersCannotPrepare() async throws {
        let model = try await model()
        for patch: [String: Any] in [["type": "private"], ["encrypted": true], ["is_joined": false], ["is_closed": true], ["hide_global_at": 10]] {
            PromotionProtocol.source.merge(patch) { _, new in new }
            do { _ = try await model.loadPromotionSnapshot(channelID: 93); XCTFail("Unsupported source accepted") } catch { }
            PromotionProtocol.resetSource()
        }
        PromotionProtocol.disabledPeer = true
        do { _ = try await model.loadPromotionSnapshot(channelID: 93); XCTFail("Disabled member accepted") } catch { }
        XCTAssertEqual(PromotionProtocol.promotes, 0); XCTAssertEqual(PromotionProtocol.creates, 0)
    }
    func testUnconfirmedInPlaceNeverRepeatsAndReadOnlyRecoveryConfirmsLater() async throws {
        let model = try await model(), snapshot = try await model.loadPromotionSnapshot(channelID: 93)
        PromotionProtocol.ignorePromotion = true
        do { _ = try await model.promoteConversation(snapshot, draft: draft); XCTFail("Ignored promotion confirmed") } catch let e as ChatChannelPromotionFailure { XCTAssertTrue(e.uncertain) }
        XCTAssertNotNil(model.pendingPromotions[93])
        do { _ = try await model.promoteConversation(snapshot, draft: draft); XCTFail("Repeat dispatched") } catch { }
        do { _ = try await model.checkPromotionStatus(channelID: 93); XCTFail("Unconfirmed state forgotten") } catch { }
        PromotionProtocol.applyPromotion()
        let confirmed = try await model.checkPromotionStatus(channelID: 93)
        XCTAssertEqual(confirmed.name, "Native-private"); XCTAssertTrue(model.pendingPromotions.isEmpty); XCTAssertEqual(PromotionProtocol.promotes, 1)
    }
    func testPartialNewChannelRetainsKnownIDAndStatusNeverReinvites() async throws {
        let model = try await model(), snapshot = try await model.loadPromotionSnapshot(channelID: 93)
        var d = draft; d.mode = .newChannel; PromotionProtocol.rejectInvite = true
        do { _ = try await model.promoteConversation(snapshot, draft: d); XCTFail("Rejected invite confirmed") } catch { }
        XCTAssertEqual(model.pendingPromotions[93]?.targetID, 96)
        do { _ = try await model.checkPromotionStatus(channelID: 93); XCTFail("Missing peer confirmed") } catch { }
        do { _ = try await model.promoteConversation(snapshot, draft: d); XCTFail("Repeated creation") } catch { }
        XCTAssertEqual(PromotionProtocol.creates, 1); XCTAssertEqual(PromotionProtocol.invites, 1)
        PromotionProtocol.targetMembers = [10, 6]
        _ = try await model.checkPromotionStatus(channelID: 93)
        XCTAssertTrue(model.pendingPromotions.isEmpty); XCTAssertEqual(PromotionProtocol.invites, 1); XCTAssertEqual(model.selection, 96)
    }
    func testSourceChangeAfterNewChannelCreationStopsBeforeInvitations() async throws {
        let model = try await model(), snapshot = try await model.loadPromotionSnapshot(channelID: 93)
        var d = draft; d.mode = .newChannel; PromotionProtocol.changeSourceAfterCreate = true
        do { _ = try await model.promoteConversation(snapshot, draft: d); XCTFail("Stale source accepted") } catch { }
        XCTAssertEqual(PromotionProtocol.creates, 1); XCTAssertEqual(PromotionProtocol.invites, 0); XCTAssertEqual(model.pendingPromotions[93]?.targetID, 96)
    }
    func testCancellationAfterDispatchBlocksRepeatAndDoesNotPublishReadback() async throws {
        let model = try await model(), snapshot = try await model.loadPromotionSnapshot(channelID: 93), sent = expectation(description: "Promotion held")
        PromotionProtocol.hold = true; PromotionProtocol.onWrite = { sent.fulfill() }
        let action = Task { try await model.promoteConversation(snapshot, draft: draft) }
        await fulfillment(of: [sent], timeout: 2); let reads = PromotionProtocol.listReads; action.cancel(); PromotionProtocol.held?.finish(["success": true]); PromotionProtocol.held = nil
        do { _ = try await action.value; XCTFail("Cancelled write published") } catch { }
        XCTAssertEqual(PromotionProtocol.listReads, reads); XCTAssertEqual(PromotionProtocol.promotes, 1); XCTAssertNotNil(model.pendingPromotions[93]); XCTAssertFalse(model.channelManagementBusy)
    }
    private func journalFolder() throws -> URL {
        let directory = URL(fileURLWithPath:"/private/tmp/native-promotion-journal-"+UUID().uuidString,isDirectory:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return directory
    }
    func testUnconfirmedConversionRestoresThroughSignInAndReadOnlyStatusNeverRepeats() async throws {
        let directory = try journalFolder(),journal = ChatChannelPromotionJournal(directory:directory)
        let first = try await model(journal:journal),snapshot = try await first.loadPromotionSnapshot(channelID:93)
        PromotionProtocol.ignorePromotion = true
        do { _ = try await first.promoteConversation(snapshot,draft:draft);XCTFail("Ignored conversion confirmed") } catch { }
        XCTAssertEqual(PromotionProtocol.promotes,1);first.signOutLocally()
        let restored = try await model(journal:.init(directory:directory))
        XCTAssertEqual(restored.pendingPromotions[93]?.targetID,93)
        let readsBeforeStaleCheck = PromotionProtocol.listReads
        do { _ = try await restored.checkPromotionStatus(channelID:93,expectedGeneration:restored.accountGeneration-1);XCTFail("Stale dialog checked current account") } catch is CancellationError { }
        XCTAssertEqual(PromotionProtocol.listReads,readsBeforeStaleCheck)
        XCTAssertNotNil(restored.pendingPromotions[93])

        XCTAssertFalse(restored.canPromoteConversation(restored.channels[0]))
        do { _ = try await restored.checkPromotionStatus(channelID:93);XCTFail("Unchanged source confirmed") } catch { }
        XCTAssertEqual(PromotionProtocol.promotes,1)
        PromotionProtocol.applyPromotion()
        _ = try await restored.checkPromotionStatus(channelID:93)
        XCTAssertTrue(restored.pendingPromotions.isEmpty);XCTAssertEqual(PromotionProtocol.promotes,1)
        let scope = try XCTUnwrap(journal.accountScope ?? ChatNotificationAccountScope.make(account:.init(session:.init(baseURL:URL(string:"https://promotion.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false),userID:10))
        XCTAssertTrue(try ChatChannelPromotionJournal(directory:directory).activate(scope:scope).isEmpty)
    }
    func testCreatedIDCheckpointExistsBeforeJoinAndSurvivesRestartWithoutInviting() async throws {
        let directory = try journalFolder(),journal = ChatChannelPromotionJournal(directory:directory)
        let first = try await model(journal:journal),snapshot = try await first.loadPromotionSnapshot(channelID:93)
        let scope = try XCTUnwrap(journal.accountScope)
        var checked = false
        PromotionProtocol.onJoin = {
            let file = directory.appendingPathComponent(scope+".json")
            let envelope = try! JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
            let records = envelope["records"] as! [[String:Any]]
            XCTAssertEqual(records.first?["targetID"] as? Int,96);checked = true
        }
        PromotionProtocol.rejectJoin = true;var new = draft;new.mode = .newChannel
        do { _ = try await first.promoteConversation(snapshot,draft:new);XCTFail("Rejected join confirmed") } catch { }
        XCTAssertTrue(checked);XCTAssertEqual(PromotionProtocol.creates,1);XCTAssertEqual(PromotionProtocol.invites,0)
        first.signOutLocally()
        let restored = try await model(journal:.init(directory:directory))
        XCTAssertEqual(restored.pendingPromotions[93]?.targetID,96)
        do { _ = try await restored.checkPromotionStatus(channelID:93);XCTFail("Incomplete members confirmed") } catch { }
        XCTAssertEqual(PromotionProtocol.joins,1);XCTAssertEqual(PromotionProtocol.invites,0)
        PromotionProtocol.targetMembers = [10,6]
        _ = try await restored.checkPromotionStatus(channelID:93)
        XCTAssertEqual(PromotionProtocol.creates,1);XCTAssertEqual(PromotionProtocol.invites,0)
    }
    func testUnknownCreateReplySurvivesRestartAndLocalAcknowledgementSendsNothing() async throws {
        let directory = try journalFolder(),first = try await model(journal:.init(directory:directory)),snapshot = try await first.loadPromotionSnapshot(channelID:93)
        PromotionProtocol.loseCreateReply = true;var new = draft;new.mode = .newChannel
        do { _ = try await first.promoteConversation(snapshot,draft:new);XCTFail("Lost creation acknowledged") } catch { }
        first.signOutLocally()
        let restored = try await model(journal:.init(directory:directory)),attempt = try XCTUnwrap(restored.pendingPromotions[93])
        XCTAssertNil(attempt.targetID)
        do { _ = try await restored.checkPromotionStatus(channelID:93);XCTFail("Unidentified target inferred from name") } catch { }
        try restored.acknowledgePromotionOutcome(attempt.intent,epoch:restored.accountGeneration)
        XCTAssertTrue(restored.pendingPromotions.isEmpty)
        XCTAssertEqual(PromotionProtocol.creates,1);XCTAssertEqual(PromotionProtocol.joins,0);XCTAssertEqual(PromotionProtocol.invites,0)
    }
    func testStorageFailureStopsBeforeMutationAndKnownIDCheckpointFailureStopsBeforeJoin() async throws {
        let directory = try journalFolder(),journal = ChatChannelPromotionJournal(directory:directory)
        let model = try await model(journal:journal),snapshot = try await model.loadPromotionSnapshot(channelID:93),scope = try XCTUnwrap(journal.accountScope)
        let file = directory.appendingPathComponent(scope+".json")
        try Data("invalid synthetic state".utf8).write(to:file)
        do { _ = try await model.promoteConversation(snapshot,draft:draft);XCTFail("Unsaved conversion sent") } catch { }
        XCTAssertNotNil(model.promotionRecoveryError);XCTAssertEqual(PromotionProtocol.promotes,0)
        try FileManager.default.removeItem(at:file);try model.refreshPromotionRecovery()
        PromotionProtocol.onCreate = { try! Data("invalid synthetic checkpoint".utf8).write(to:file) }
        var new = draft;new.mode = .newChannel
        do { _ = try await model.promoteConversation(snapshot,draft:new);XCTFail("Unsaved created ID joined") } catch { }
        XCTAssertTrue(model.promotionRecoveryError?.contains("96") == true)
        XCTAssertEqual(PromotionProtocol.creates,1);XCTAssertEqual(PromotionProtocol.joins,0);XCTAssertEqual(PromotionProtocol.invites,0)
    }
    func testLateCreatedIDAfterSignoutIsSavedOnlyInOriginalAccountWithoutJoining() async throws {
        let directory = try journalFolder(),journal = ChatChannelPromotionJournal(directory:directory)
        let model = try await model(journal:journal),snapshot = try await model.loadPromotionSnapshot(channelID:93),scope = try XCTUnwrap(journal.accountScope)
        let started = expectation(description:"Create response held");PromotionProtocol.holdCreate = true;PromotionProtocol.onWrite = { started.fulfill() }
        var new = draft;new.mode = .newChannel
        let task = Task { try await model.promoteConversation(snapshot,draft:new) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        PromotionProtocol.held?.finish(["success":true,"data":["channel_id":96]])
        do { _ = try await task.value;XCTFail("Old operation continued") } catch is CancellationError { }
        XCTAssertTrue(model.pendingPromotions.isEmpty);XCTAssertEqual(PromotionProtocol.joins,0);XCTAssertEqual(PromotionProtocol.invites,0)
        XCTAssertEqual(try ChatChannelPromotionJournal(directory:directory).activate(scope:scope).first?.targetID,96)
    }
    func testSignOutAfterDispatchDoesNotPublishOldAccountChannels() async throws {
        let model = try await model(), snapshot = try await model.loadPromotionSnapshot(channelID: 93), sent = expectation(description: "Promotion held")
        PromotionProtocol.hold = true; PromotionProtocol.onWrite = { sent.fulfill() }
        let action = Task { try await model.promoteConversation(snapshot, draft: draft) }
        await fulfillment(of: [sent], timeout: 2); let reads = PromotionProtocol.listReads; model.signOutLocally(); PromotionProtocol.held?.finish(["success": true]); PromotionProtocol.held = nil
        do { _ = try await action.value; XCTFail("Old result published") } catch is CancellationError { }
        XCTAssertEqual(PromotionProtocol.listReads, reads); XCTAssertTrue(model.pendingPromotions.isEmpty); XCTAssertTrue(model.channels.isEmpty); XCTAssertFalse(model.channelManagementBusy)
    }
}

private final class PromotionProtocol: URLProtocol {
    static var source: [String: Any] = [:], target: [String: Any]?
    static var sourceMembers: [Int64] = [10, 6], targetMembers: [Int64] = []
    static var allowCreate = true, ignorePromotion = false, rejectInvite = false, hold = false, disabledPeer = false, changeSourceAfterCreate = false
    static var rejectJoin = false,loseCreateReply = false,holdCreate = false
    static var onJoin:(()->Void)?,onCreate:(()->Void)?
    static var promotes = 0, creates = 0, invites = 0, joins = 0, listReads = 0
    static var promoteFields: [String: String]?, inviteFields: [String: String]?, createFields: [String: String]?
    static var held: PromotionProtocol?, onWrite: (() -> Void)?
    static func resetSource() { source = ["channel_id": 93, "name": "", "purpose": "", "type": "anonymous", "encrypted": false, "unread": 0, "is_joined": true] }
    static func reset() { resetSource(); target = nil; sourceMembers = [10, 6]; targetMembers = []; allowCreate = true; ignorePromotion = false; rejectInvite = false; hold = false; disabledPeer = false; changeSourceAfterCreate = false; promotes = 0; creates = 0; invites = 0; joins = 0; listReads = 0; promoteFields = nil; inviteFields = nil; createFields = nil; held = nil; onWrite = nil;rejectJoin = false;loseCreateReply = false;holdCreate = false;onJoin = nil;onCreate = nil }
    static func applyPromotion() { source["type"] = "private"; source["name"] = "Native-private"; source["purpose"] = "Synthetic purpose" }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" {
            let names = ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Misc", "SYNO.Chat.Channel.Member", "SYNO.Chat.Channel.Anonymous", "SYNO.Chat.Channel.Named"]
            finish(["success": true, "data": Dictionary(uniqueKeysWithValues: names.map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 5, "requestFormat": "JSON"] as [String: Any]) })]); return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) } }
        var q = URLComponents(); q.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let f = Dictionary((q.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        if api == "SYNO.Chat.User" { finish(["success": true, "data": ["users": [["user_id": 10, "username": "synthetic", "nickname": "Synthetic", "type": "human", "human_type": "dsm"], ["user_id": 6, "username": "other", "nickname": "Other Peter", "type": "human", "human_type": "dsm", "is_disabled": Self.disabledPeer]]]]); return }
        if api == "SYNO.Chat.Misc" { finish(["success": true, "data": ["acls": [["acl_name": "channel_create", "allow": Self.allowCreate], ["acl_name": "channel_invite", "allow": true]]]]); return }
        if api == "SYNO.Chat.Channel" { Self.listReads += 1; finish(["success": true, "data": ["channels": [Self.source] + (Self.target.map { [$0] } ?? [])]]); return }
        if api == "SYNO.Chat.Channel.Member" { finish(["success": true, "data": ["user_ids": f["channel_id"] == "96" ? Self.targetMembers : Self.sourceMembers]]); return }
        if api == "SYNO.Chat.Channel.Anonymous", f["method"] == "promote" {
            Self.promotes += 1; Self.promoteFields = f; if !Self.ignorePromotion { Self.applyPromotion() }
            if Self.hold { Self.held = self; Self.onWrite?(); return }; finish(["success": true]); return
        }
        if api == "SYNO.Chat.Channel.Named", f["method"] == "create" {
            Self.creates += 1; Self.createFields = f
            Self.target = ["channel_id": 96, "name": "Native-private", "purpose": "Synthetic purpose", "type": "private", "encrypted": false, "unread": 0, "is_joined": true]; Self.targetMembers = [10]
            if Self.changeSourceAfterCreate { Self.source["type"] = "private" }
            Self.onCreate?()
            if Self.holdCreate { Self.held = self;Self.onWrite?();return }
            if Self.loseCreateReply { client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return }
            finish(["success": true, "data": ["channel_id": 96]]); return
        }
        if api == "SYNO.Chat.Channel.Named", f["method"] == "join" { Self.joins += 1;Self.onJoin?();finish(Self.rejectJoin ? ["success":false,"error":["code":119]] : ["success":true]);return }
        if api == "SYNO.Chat.Channel.Named", f["method"] == "invite" {
            Self.invites += 1; Self.inviteFields = f
            if Self.rejectInvite { finish(["success": false, "error": ["code": 105]]); return }
            Self.targetMembers = [10, 6]; finish(["success": true]); return
        }
        finish(["success": false, "error": ["code": 102]])
    }
    func finish(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: value); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
