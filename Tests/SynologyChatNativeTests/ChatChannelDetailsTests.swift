import XCTest
@testable import SynologyChatNative

@MainActor final class ChatChannelDetailsTests:XCTestCase {
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [DetailsProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://details-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover();return api
    }
    private func channel(_ fields:[String:Any] = DetailsProtocol.initial) throws -> ChatChannel { try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:fields)) }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:try await api(),restoreNotificationPreference:false);model.connected = true;model.liveStatus = .live
        _ = try await model.loadChannelDetails(channelID:96);model.selection = 96
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func setUp() { super.setUp();DetailsProtocol.reset() }
    override func tearDown() { DetailsProtocol.held = nil;DetailsProtocol.observer = nil;super.tearDown() }
    func testEncryptedPrivateMetadataEditsDoNotRequireUnlockOrChangeKeys() async throws {
        DetailsProtocol.value["encrypted"] = true
        DetailsProtocol.value["channel_key_enc"] = "Synthetic historical envelope — not a real key"
        let m = try await model(), original = try XCTUnwrap(m.channels.first)
        XCTAssertFalse(m.encryptionUnlocked); XCTAssertFalse(m.canRead(original.id))
        XCTAssertTrue(m.canEditChannelDetails(original), "Named encrypted metadata is editable without decrypting history")
        guard m.canEditChannelDetails(original) else { return }
        m.draft = "Keep the unsent draft"
        var draft = ChatChannelDetailsDraft(channel: original); draft.name = "Encrypted-details-test"; draft.purpose = "Updated purpose 👋"
        let result = try await m.saveChannelDetails(original: original, draft: draft)
        XCTAssertEqual(result.name, draft.name); XCTAssertEqual(result.purpose, draft.purpose)
        XCTAssertTrue(result.encrypted); XCTAssertEqual(result.channel_key_enc, original.channel_key_enc)
        XCTAssertFalse(m.encryptionUnlocked); XCTAssertFalse(m.canRead(original.id)); XCTAssertEqual(m.draft, "Keep the unsent draft")
        XCTAssertEqual(DetailsProtocol.writes, 1)
        XCTAssertEqual(Set(DetailsProtocol.lastPatch.keys), Set(["api", "version", "method", "channel_id", "name", "purpose"]))
    }
    func testFreshEncryptedScopeOrEnvelopeChangeRejectsMetadataWrite() async throws {
        DetailsProtocol.value["encrypted"] = true; DetailsProtocol.value["channel_key_enc"] = "Synthetic original envelope"
        let m = try await model(), original = try XCTUnwrap(m.channels.first)
        var draft = ChatChannelDetailsDraft(channel: original); draft.purpose = "New purpose"
        for change: [String:Any] in [["encrypted":false], ["channel_key_enc":"Synthetic rotated envelope"]] {
            DetailsProtocol.value = DetailsProtocol.initial.merging(["encrypted":true,"channel_key_enc":"Synthetic original envelope"], uniquingKeysWith: { _,new in new }).merging(change, uniquingKeysWith: { _,new in new })
            do { _ = try await m.saveChannelDetails(original: original, draft: draft); XCTFail("Changed encryption scope accepted") } catch { }
        }
        XCTAssertEqual(DetailsProtocol.writes, 0); XCTAssertTrue(m.unresolvedChannelDetails.isEmpty)
        XCTAssertEqual(m.channels.first?.channel_key_enc, original.channel_key_enc)
    }
    func testPostWriteEnvelopeChangeIsUncertainAndDoesNotPublishReplacementScope() async throws {
        DetailsProtocol.value["encrypted"] = true; DetailsProtocol.value["channel_key_enc"] = "Synthetic original envelope"
        let m = try await model(), original = try XCTUnwrap(m.channels.first)
        var draft = ChatChannelDetailsDraft(channel: original); draft.purpose = "New purpose"
        DetailsProtocol.observer = { fields in if fields["method"] == "set" { DetailsProtocol.value["channel_key_enc"] = "Synthetic rotated envelope" } }
        do { _ = try await m.saveChannelDetails(original: original, draft: draft); XCTFail("Replacement encrypted scope published") }
        catch let failure as ChatChannelDetailsFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(DetailsProtocol.writes, 1); XCTAssertTrue(m.unresolvedChannelDetails.contains(96))
        XCTAssertEqual(m.channels.first?.channel_key_enc, original.channel_key_enc)
        XCTAssertFalse(m.encryptionUnlocked)
    }
    func testMetadataEligibilityRetainsSystemMembershipAndUnsupportedKindRestrictions() throws {
        let encrypted = DetailsProtocol.initial.merging(["encrypted":true], uniquingKeysWith: { _,new in new })
        XCTAssertTrue(try channel(encrypted).supportsDetailsEditing)
        for change: [String:Any] in [["channel_id":1],["channel_id":2],["type":"public"],["type":"anonymous"],["type":"chatbot"],["is_joined":false],["is_closed":true],["hide_global_at":2000]] {
            XCTAssertFalse(try channel(encrypted.merging(change, uniquingKeysWith: { _,new in new })).supportsDetailsEditing)
        }
    }
    private func administrativeModel() async throws -> NativeChatPreviewModel {
        DetailsProtocol.value = DetailsProtocol.initial.merging(["channel_id":1,"name":"General","type":"public"], uniquingKeysWith: { _,new in new })
        let api = try await api()
        let m = NativeChatPreviewModel(restoreNotificationPreference:false, makeClient:{ _ in api })
        await m.connect(using:.init(session:.init(baseURL:URL(string:"https://details-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"SyntheticAdmin",importedFromOfficialApp:false))
        XCTAssertTrue(m.connected,m.error ?? "Synthetic bootstrap did not connect"); m.liveStatus = .live; m.selection = 1
        _ = try await m.loadChannelDetails(channelID:1)
        addTeardownBlock { @MainActor in m.signOutLocally() }; return m
    }
    func testVerifiedSystemAdministratorCanSaveOnlyNamedMetadataFields() async throws {
        let m = try await administrativeModel(), original = try XCTUnwrap(m.channels.first)
        XCTAssertTrue(m.isVerifiedAdministrator); XCTAssertTrue(m.canEditChannelDetails(original))
        var draft = ChatChannelDetailsDraft(channel:original); draft.name = "Synthetic-General"; draft.purpose = "Synthetic administrator-only purpose"
        let result = try await m.saveChannelDetails(original:original,draft:draft)
        XCTAssertEqual(result.name,draft.name); XCTAssertEqual(result.purpose,draft.purpose)
        XCTAssertEqual(DetailsProtocol.writes,1); XCTAssertEqual(DetailsProtocol.lastPatch["channel_id"],"1")
        XCTAssertEqual(Set(DetailsProtocol.lastPatch.keys),Set(["api","version","method","channel_id","name","purpose"]))
        XCTAssertEqual(DetailsProtocol.administratorReads,2, "Authority is refreshed again immediately before the write")
    }
    func testSystemChannelRemainsReadOnlyForKnownNonAdministrator() async throws {
        DetailsProtocol.administrator = false
        let m = try await administrativeModel(), channel = try XCTUnwrap(m.channels.first)
        XCTAssertNotNil(m.administratorStatus); XCTAssertFalse(m.isVerifiedAdministrator)
        XCTAssertFalse(m.hasChannelDetailsEditingAuthority(channel)); XCTAssertFalse(m.canEditChannelDetails(channel))
        var draft = ChatChannelDetailsDraft(channel:channel); draft.purpose = "Must not dispatch"
        do { _ = try await m.saveChannelDetails(original:channel,draft:draft); XCTFail("Nonadministrator wrote system metadata") } catch { }
        XCTAssertEqual(DetailsProtocol.writes,0)
    }
    func testFreshAdministratorRevocationOrIdentityMismatchPreventsSystemWrite() async throws {
        for mismatch in [false,true] {
            DetailsProtocol.reset()
            let m = try await administrativeModel(), channel = try XCTUnwrap(m.channels.first)
            var draft = ChatChannelDetailsDraft(channel:channel); draft.purpose = "Must not dispatch"
            if mismatch { DetailsProtocol.administratorUser = "Another synthetic identity" }
            else { DetailsProtocol.administrator = false }
            do { _ = try await m.saveChannelDetails(original:channel,draft:draft); XCTFail("Stale administrator grant wrote metadata") } catch { }
            XCTAssertEqual(DetailsProtocol.writes,0); XCTAssertFalse(m.isVerifiedAdministrator)
            XCTAssertTrue(m.unresolvedChannelDetails.isEmpty)
        }
    }
    func testOldAdministratorReadCannotAuthorizeReplacementAccountAfterSignout() async throws {
        let m = try await administrativeModel(), channel = try XCTUnwrap(m.channels.first)
        var draft = ChatChannelDetailsDraft(channel:channel); draft.purpose = "Must not dispatch"
        let started = expectation(description:"Administrator configuration held")
        DetailsProtocol.holdAdministratorRead = true
        DetailsProtocol.observer = { fields in if fields["method"] == "get_user_service" { started.fulfill() } }
        let task = Task { try await m.saveChannelDetails(original:channel,draft:draft) }
        await fulfillment(of:[started],timeout:2); m.signOutLocally()
        DetailsProtocol.held?.finish(["success":true,"data":["Session":["user":"SyntheticAdmin","isLogined":true,"is_admin":true]]]); DetailsProtocol.held = nil
        do { _ = try await task.value; XCTFail("Old administrator status published") } catch is CancellationError { }
        XCTAssertNil(m.administratorStatus); XCTAssertFalse(m.isVerifiedAdministrator); XCTAssertTrue(m.channels.isEmpty)
        XCTAssertEqual(DetailsProtocol.writes,0)
    }
    private func publicArchive() throws -> ChatArchive {
        try JSONDecoder().decode(ChatArchive.self,from:JSONSerialization.data(withJSONObject:DetailsProtocol.publicArchive))
    }
    func testVerifiedAdministratorPublicArchiveDeleteUsesFreshAuthorityAndExactWire() async throws {
        let m = try await administrativeModel(), archive = try publicArchive()
        XCTAssertTrue(m.canReviewArchiveDeletion(kind:.public))
        let prepared = try await m.prepareArchiveDeletion(archive,kind:.public,name:"Synthetic public archive")
        let before = DetailsProtocol.administratorReads
        try await m.deleteArchive(prepared)
        XCTAssertEqual(DetailsProtocol.administratorReads,before + 1)
        XCTAssertEqual(DetailsProtocol.archiveWrites,1); XCTAssertEqual(DetailsProtocol.writes,0)
        XCTAssertEqual(Set(DetailsProtocol.lastArchivePatch.keys),Set(["api","method","version","archive_id"]))
        XCTAssertEqual(DetailsProtocol.lastArchivePatch["archive_id"],"26")
        XCTAssertTrue(m.archiveDeletions.pending.isEmpty)
    }
    func testNonAdministratorAndUnavailableAuthorityCanBrowseButCannotReviewPublicDeletion() async throws {
        DetailsProtocol.administrator = false
        let m = try await administrativeModel(), archive = try publicArchive()
        XCTAssertFalse(m.canReviewArchiveDeletion(kind:.public)); XCTAssertTrue(m.canReviewArchiveDeletion(kind:.private))
        var names = try await m.loadArchiveNames(kind:.public)
        XCTAssertEqual(names,["Synthetic public archive"])
        do { _ = try await m.prepareArchiveDeletion(archive,kind:.public,name:names[0]); XCTFail("Nonadministrator obtained delete review") } catch { }
        DetailsProtocol.administratorUser = "Wrong synthetic account"
        names = try await m.loadArchiveNames(kind:.public)
        XCTAssertEqual(names,["Synthetic public archive"]); XCTAssertNil(m.administratorStatus)
        XCTAssertFalse(m.canReviewArchiveDeletion(kind:.public)); XCTAssertEqual(DetailsProtocol.archiveWrites,0)
        XCTAssertTrue(m.archiveDeletions.pending.isEmpty)
    }
    func testPublicArchiveRevocationAfterReviewDoesNotDispatchOrLeaveUnknownReceipt() async throws {
        let m = try await administrativeModel(), archive = try publicArchive()
        let prepared = try await m.prepareArchiveDeletion(archive,kind:.public,name:"Synthetic public archive")
        DetailsProtocol.administrator = false
        do { try await m.deleteArchive(prepared); XCTFail("Revoked administrator deleted archive") } catch { }
        XCTAssertEqual(DetailsProtocol.archiveWrites,0); XCTAssertTrue(m.archiveDeletions.pending.isEmpty)
        XCTAssertFalse(m.isVerifiedAdministrator)
    }
    func testPublicArchiveAccountChangeDuringFinalAuthorityReadCannotDispatch() async throws {
        let m = try await administrativeModel(), archive = try publicArchive()
        let prepared = try await m.prepareArchiveDeletion(archive,kind:.public,name:"Synthetic public archive")
        let started = expectation(description:"Final archive authority held")
        DetailsProtocol.holdAdministratorRead = true
        DetailsProtocol.observer = { fields in if fields["method"] == "get_user_service" { started.fulfill() } }
        let task = Task { try await m.deleteArchive(prepared) }
        await fulfillment(of:[started],timeout:2); m.signOutLocally()
        DetailsProtocol.held?.finish(["success":true,"data":["Session":["user":"SyntheticAdmin","isLogined":true,"is_admin":true]]]); DetailsProtocol.held = nil
        do { try await task.value; XCTFail("Retired account deleted archive") } catch is CancellationError { }
        XCTAssertEqual(DetailsProtocol.archiveWrites,0); XCTAssertTrue(m.archiveDeletions.pending.isEmpty)
        XCTAssertFalse(m.isVerifiedAdministrator)
    }
    func testOlderPositiveAdministratorReadCannotOverwriteNewerRevocation() async throws {
        let m = try await administrativeModel(), started = expectation(description:"Old authority read held")
        DetailsProtocol.holdAdministratorRead = true
        DetailsProtocol.observer = { fields in if fields["method"] == "get_user_service" { started.fulfill() } }
        let old = Task { try await m.refreshAdministratorStatus() }
        await fulfillment(of:[started],timeout:2)
        let held = try XCTUnwrap(DetailsProtocol.held); DetailsProtocol.held = nil
        DetailsProtocol.holdAdministratorRead = false; DetailsProtocol.observer = nil; DetailsProtocol.administrator = false
        let newer = try await m.refreshAdministratorStatus(); XCTAssertFalse(newer)
        held.finish(["success":true,"data":["Session":["user":"SyntheticAdmin","isLogined":true,"is_admin":true]]])
        do { _ = try await old.value; XCTFail("Obsolete positive authority accepted") } catch is CancellationError { }
        XCTAssertFalse(m.isVerifiedAdministrator); XCTAssertEqual(m.administratorStatus?.isAdministrator,false)
    }
    func testOldFailedSystemDetailsReadCannotClearNewerAdministratorGrant() async throws {
        let m = try await administrativeModel(), started = expectation(description:"Old system details authority held")
        DetailsProtocol.holdAdministratorRead = true
        DetailsProtocol.observer = { fields in if fields["method"] == "get_user_service" { started.fulfill() } }
        let old = Task { try await m.loadChannelDetails(channelID:1) }
        await fulfillment(of:[started],timeout:2)
        let held = try XCTUnwrap(DetailsProtocol.held); DetailsProtocol.held = nil
        DetailsProtocol.holdAdministratorRead = false; DetailsProtocol.observer = nil
        let newer = try await m.refreshAdministratorStatus(); XCTAssertTrue(newer)
        held.finish(["success":false,"error":["code":117]])
        do { _ = try await old.value; XCTFail("Retired failed read must not reach parent failure cleanup") } catch is CancellationError { }
        XCTAssertTrue(m.isVerifiedAdministrator); XCTAssertEqual(m.administratorStatus?.isAdministrator,true)
    }
    func testDirtyPatchTrimsChangedFieldsAndDoesNotRewriteUntouchedLegacyValues() throws {
        var fields = DetailsProtocol.initial;fields["name"] = "Legacy name with spaces";fields["purpose"] = "Existing purpose  "
        let original = try channel(fields);var draft = ChatChannelDetailsDraft(channel:original)
        XCTAssertTrue(try draft.patch(relativeTo:original).isEmpty)
        draft.purpose = "  Literal <new purpose> 👋  "
        XCTAssertEqual(try draft.patch(relativeTo:original),.init(name:nil,purpose:"Literal <new purpose> 👋"))
        draft.name = "  New-name  "
        XCTAssertEqual(try draft.patch(relativeTo:original),.init(name:"New-name",purpose:"Literal <new purpose> 👋"))
        draft.purpose = " \n ";XCTAssertEqual(try draft.patch(relativeTo:original).purpose,"")
    }
    func testChangedFieldsUseOfficialUTF16BoundsAndNameConstraints() throws {
        XCTAssertNoThrow(try ChatChannelDetailsPatch(name:String(repeating:"a",count:64),purpose:String(repeating:"😀",count:128)).validate())
        for patch in [ChatChannelDetailsPatch(name:"",purpose:nil),.init(name:"name with spaces",purpose:nil),.init(name:"name#bad",purpose:nil),.init(name:String(repeating:"a",count:65),purpose:nil),.init(name:nil,purpose:String(repeating:"😀",count:129)),.init(name:" untrimmed",purpose:nil)] { XCTAssertThrowsError(try patch.validate()) }
    }
    func testWireSendsOnlyDirtyNamedSetV1FieldsAndSupportsExplicitPurposeClear() async throws {
        let api = try await api();var patches:[[String:String]] = []
        DetailsProtocol.observer = { fields in
            guard fields["method"] == "set" else { return };patches.append(fields)
            XCTAssertEqual(fields["api"],"SYNO.Chat.Channel.Named");XCTAssertEqual(fields["version"],"1");XCTAssertEqual(fields["channel_id"],"96")
            XCTAssertNil(fields["type"]);XCTAssertNil(fields["encrypted"]);XCTAssertNil(fields["user_ids"])
        }
        try await api.setNamedChannelDetails(channelID:96,patch:.init(name:"Renamed",purpose:nil))
        try await api.setNamedChannelDetails(channelID:96,patch:.init(name:nil,purpose:""))
        XCTAssertNil(patches[0]["purpose"]);XCTAssertEqual(patches[0]["name"],#""Renamed""#)
        XCTAssertNil(patches[1]["name"]);XCTAssertEqual(patches[1]["purpose"],#""""#)
        do { try await api.setNamedChannelDetails(channelID:1,patch:.init(name:"General",purpose:nil));XCTFail("System mutation sent") } catch ChatAPIError.invalidResponse { }
        do { try await api.setNamedChannelDetails(channelID:96,patch:.init(name:nil,purpose:nil));XCTFail("Empty patch sent") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(DetailsProtocol.writes,2)
    }
    func testCanonicalMetadataUpdateDoesNotNavigateOrDiscardMessageDraftOrEdit() async throws {
        let model = try await model(),original = model.channels[0],owner = UUID();model.draft = "Unsent conversation draft";model.beginMessageEditing(owner:owner)
        var draft = ChatChannelDetailsDraft(channel:original);draft.name = "Native-renamed";draft.purpose = "Literal <purpose> 👋"
        let result = try await model.saveChannelDetails(original:original,draft:draft)
        XCTAssertEqual(result.name,"Native-renamed");XCTAssertEqual(result.purpose,"Literal <purpose> 👋");XCTAssertEqual(model.channels[0].name,result.name)
        XCTAssertEqual(model.selection,96);XCTAssertEqual(model.draft,"Unsent conversation draft");XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertFalse(model.channelManagementBusy)
    }
    func testStaleChangedFieldIsNotOverwrittenButUntouchedRemoteFieldIsPreserved() async throws {
        let model = try await model(),original = model.channels[0];var draft = ChatChannelDetailsDraft(channel:original);draft.name = "Our-name"
        DetailsProtocol.value["name"] = "Remote-name"
        do { _ = try await model.saveChannelDetails(original:original,draft:draft);XCTFail("Stale rename overwrote remote change") } catch let failure as ChatChannelDetailsFailure { XCTAssertFalse(failure.uncertain) }
        XCTAssertEqual(DetailsProtocol.writes,0)
        DetailsProtocol.value["name"] = original.name;DetailsProtocol.value["purpose"] = "Remote purpose"
        let updated = try await model.saveChannelDetails(original:original,draft:draft)
        XCTAssertEqual(updated.name,"Our-name");XCTAssertEqual(updated.purpose,"Remote purpose");XCTAssertNil(DetailsProtocol.lastPatch["purpose"])
    }
    func testPurposeOnlyCanUpdateLegacyNameWithoutUnrequestedNameNormalization() async throws {
        DetailsProtocol.value["name"] = "Legacy name";let model = try await model(),original = model.channels[0]
        var draft = ChatChannelDetailsDraft(channel:original);draft.purpose = "Changed purpose"
        let updated = try await model.saveChannelDetails(original:original,draft:draft)
        XCTAssertEqual(updated.name,"Legacy name");XCTAssertEqual(updated.purpose,"Changed purpose");XCTAssertNil(DetailsProtocol.lastPatch["name"])
    }
    func testFreshPermissionRevocationAndUnavailableSourceRejectBeforeWrite() async throws {
        let model = try await model(),original = model.channels[0];var draft = ChatChannelDetailsDraft(channel:original);draft.name = "New-name"
        DetailsProtocol.allow = false
        do { _ = try await model.saveChannelDetails(original:original,draft:draft);XCTFail("Revoked ACL wrote") } catch { }
        DetailsProtocol.allow = true
        for fields:[String:Any] in [["type":"public"],["encrypted":true],["is_joined":false],["is_closed":true]] {
            DetailsProtocol.value = DetailsProtocol.initial.merging(fields,uniquingKeysWith:{ _,new in new })
            do { _ = try await model.saveChannelDetails(original:original,draft:draft);XCTFail("Unavailable source wrote") } catch { }
        }
        XCTAssertEqual(DetailsProtocol.writes,0)
    }
    func testIgnoredUpdateBecomesUncertainAndOnlyDetailsRefreshUnlocksRetry() async throws {
        let model = try await model(),original = model.channels[0];var draft = ChatChannelDetailsDraft(channel:original);draft.name = "New-name";DetailsProtocol.ignoreWrite = true
        do { _ = try await model.saveChannelDetails(original:original,draft:draft);XCTFail("No-op update confirmed") } catch let failure as ChatChannelDetailsFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(model.channels[0].name,original.name);XCTAssertTrue(model.unresolvedChannelDetails.contains(96));XCTAssertFalse(model.canEditChannelDetails(original))
        do { _ = try await model.saveChannelDetails(original:original,draft:draft);XCTFail("Uncertain update repeated") } catch { }
        XCTAssertEqual(DetailsProtocol.writes,1)
        _ = try await model.loadChannelDetails(channelID:96);XCTAssertTrue(model.unresolvedChannelDetails.isEmpty)
        DetailsProtocol.ignoreWrite = false;_ = try await model.saveChannelDetails(original:original,draft:draft);XCTAssertEqual(model.channels[0].name,"New-name")
    }
    func testSignOutAfterDispatchCannotPublishOldDetailsOrIssueReadback() async throws {
        let model = try await model(),original = model.channels[0],started = expectation(description:"Details set held");var draft = ChatChannelDetailsDraft(channel:original);draft.name = "New-name";DetailsProtocol.holdWrite = true
        DetailsProtocol.observer = { if $0["method"] == "set" { started.fulfill() } }
        let task = Task { try await model.saveChannelDetails(original:original,draft:draft) }
        await fulfillment(of:[started],timeout:2);let reads = DetailsProtocol.reads;model.signOutLocally();DetailsProtocol.held?.finish(["success":true])
        do { _ = try await task.value;XCTFail("Old details published") } catch is CancellationError { }
        XCTAssertTrue(model.channels.isEmpty);XCTAssertTrue(model.unresolvedChannelDetails.isEmpty);XCTAssertEqual(DetailsProtocol.reads,reads)
    }
    func testCancelledDispatchedUpdateRetainsUncertainGuard() async throws {
        let model = try await model(),original = model.channels[0],started = expectation(description:"Details set held");var draft = ChatChannelDetailsDraft(channel:original);draft.purpose = "New purpose";DetailsProtocol.holdWrite = true
        DetailsProtocol.observer = { if $0["method"] == "set" { started.fulfill() } }
        let task = Task { try await model.saveChannelDetails(original:original,draft:draft) }
        await fulfillment(of:[started],timeout:2);task.cancel();DetailsProtocol.held?.finish(["success":true])
        do { _ = try await task.value;XCTFail("Cancelled update accepted") } catch let failure as ChatChannelDetailsFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertTrue(model.unresolvedChannelDetails.contains(96));XCTAssertFalse(model.channelManagementBusy)
    }
    func testSystemUnjoinedAndMismatchedEncryptionDetailsRemainReadOnly() async throws {
        let model = try await model()
        for changes:[String:Any] in [["channel_id":1],["channel_id":2],["encrypted":true],["is_joined":false]] {
            let candidate = try channel(DetailsProtocol.initial.merging(changes,uniquingKeysWith:{ _,new in new }))
            XCTAssertFalse(model.canEditChannelDetails(candidate))
        }
        XCTAssertEqual(DetailsProtocol.writes,0)
    }
    func testDuplicateReadSnapshotDoesNotPublishMetadata() async throws {
        let model = try await model();DetailsProtocol.duplicate = true
        do { _ = try await model.loadChannelDetails(channelID:96);XCTFail("Duplicate snapshot accepted") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(model.channels.count,1);XCTAssertEqual(DetailsProtocol.writes,0)
    }
}

private final class DetailsProtocol:URLProtocol {
    static let initial:[String:Any] = ["channel_id":96,"name":"Peter-Native-API-test","purpose":"","type":"private","encrypted":false,"is_joined":true,"unread":0,"is_star":false,"last_hide_at":0]
    static var value = initial
    static var allow = true,ignoreWrite = false,holdWrite = false,duplicate = false
    static var administrator = true, administratorUser = "SyntheticAdmin", holdAdministratorRead = false
    static var administratorReads = 0
    static var archiveWrites = 0, archiveDeleted = false
    static var lastArchivePatch: [String:String] = [:]
    static var publicArchive: [String:Any] { ["archive_id":26,"post_start":1000,"post_end":2000,"post_id_start":100,"post_id_end":200,"props":["reason":"channel_archived","trigger_user_id":6,"channel":["channel_id":97,"name":"Synthetic public archive","type":"public","encrypted":false,"unread":0]]] }
    static var writes = 0,reads = 0
    static var lastPatch:[String:String] = [:]
    static var held:DetailsProtocol?
    static var observer:(([String:String])->Void)?
    static func reset() { value = initial;allow = true;ignoreWrite = false;holdWrite = false;duplicate = false;writes = 0;reads = 0;lastPatch = [:];held = nil;observer = nil;administrator = true;administratorUser = "SyntheticAdmin";holdAdministratorRead = false;administratorReads = 0;archiveWrites = 0;archiveDeleted = false;lastArchivePatch = [:] }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Channel","SYNO.Chat.Channel.Named","SYNO.Chat.Misc","SYNO.Chat.User","SYNO.Core.Desktop.Initdata","SYNO.Chat.Archive"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        let route = request.url!.lastPathComponent
        guard ["SYNO.Chat.Channel","SYNO.Chat.Channel.Named","SYNO.Chat.Misc","SYNO.Chat.User","SYNO.Core.Desktop.Initdata","SYNO.Chat.Archive"].contains(route) else {
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:404,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed);client?.urlProtocolDidFinishLoading(self);return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        if request.httpMethod == "GET" { data = Data((request.url?.query ?? "").utf8) }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        var fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });let api = request.url!.lastPathComponent;fields["api"] = api;let method = fields["method"] ?? ""
        if api == "SYNO.Chat.User" { finish(["success":true,"data":["users":[["user_id":6,"username":"SyntheticAdmin","nickname":"Synthetic administrator","type":"human","human_type":"dsm"]]]]);return }
        if api == "SYNO.Core.Desktop.Initdata" {
            Self.administratorReads += 1
            if Self.holdAdministratorRead { Self.held = self;Self.observer?(fields);return }
            Self.observer?(fields);finish(["success":true,"data":["Session":["user":Self.administratorUser,"isLogined":true,"is_admin":Self.administrator]]]);return
        }
        if api == "SYNO.Chat.Archive" {
            Self.observer?(fields)
            if method == "delete" { Self.archiveWrites += 1;Self.archiveDeleted = true;Self.lastArchivePatch = fields;finish(["success":true]);return }
            if method == "list_name" { finish(["success":true,"data":["channel_names":["Synthetic public archive"]]]);return }
            finish(["success":true,"data":["archives":Self.archiveDeleted ? [] : [Self.publicArchive]]]);return
        }
        if api == "SYNO.Chat.Channel.Named" {
            Self.writes += 1;Self.lastPatch = fields
            if !Self.ignoreWrite {
                for name in ["name","purpose"] { if let encoded = fields[name],let value = try? JSONDecoder().decode(String.self,from:Data(encoded.utf8)) { Self.value[name] = value } }
            }
            if Self.holdWrite { Self.held = self;Self.observer?(fields);return }
            Self.observer?(fields);finish(["success":true]);return
        }
        Self.observer?(fields)
        if api == "SYNO.Chat.Misc" { finish(["success":true,"data":["acls":[["acl_name":"channel_set","allow":Self.allow]]]]);return }
        Self.reads += 1;finish(["success":true,"data":["channels":Self.duplicate ? [Self.value,Self.value] : [Self.value]]])
    }
    func finish(_ object:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:object);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
