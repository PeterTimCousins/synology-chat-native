#if DEBUG
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatEncryptedCreationIntegrationTests:XCTestCase {
    private func backend() throws -> InvitationIntegrationBackend {
        let file = try XCTUnwrap(Bundle.module.url(forResource:"ChatCrypto",withExtension:"json",subdirectory:"Fixtures"))
        return try InvitationIntegrationBackend(fixture:JSONDecoder().decode(InvitationIntegrationFixture.self,from:Data(contentsOf:file)),encrypted:true)
    }
    private func folder() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("native-encrypted-creation-integration-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:path) };return path
    }
    private func model(_ backend:InvitationIntegrationBackend,directory:URL,unlock:Bool = true) async throws -> NativeChatPreviewModel {
        InvitationIntegrationProtocol.backend = backend;backend.creationJournalDirectory = directory
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [InvitationIntegrationProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        },encryptedCreationJournal:.init(directory:directory))
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://invitation-integration.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-inviter",importedFromOfficialApp:false))
        XCTAssertTrue(model.connected,model.error ?? "Not connected");model.suspendLiveForProbe();model.selection = 23
        if unlock { try model.unlockEncryption(password:backend.fixture.password);await model.historyTask?.value }
        model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    private func create(_ model:NativeChatPreviewModel) async throws {
        try await model.createChannel(name:"Synthetic-encrypted",purpose:"Synthetic purpose",kind:.private,encrypted:true)
    }
    private func records(_ data:Data?) throws -> [[String:Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(data)) as? [String:Any])
        return try XCTUnwrap(object["records"] as? [[String:Any]])
    }
    private func corrupt(_ directory:URL) throws {
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first { $0.pathExtension == "json" })
        try Data("synthetic corrupt state".utf8).write(to:file)
    }
    func testCreationPersistsSealedEnvelopeBeforeCreateAndKnownIDBeforeJoinThenPublishes() async throws {
        let state = try backend(),model = try await model(state,directory:folder())
        XCTAssertTrue(model.canCreateEncryptedChannel)
        try await create(model)
        XCTAssertEqual(state.creates.count,1);XCTAssertEqual(state.joins.count,1);XCTAssertTrue(state.invites.isEmpty)
        XCTAssertEqual(model.selection,96);XCTAssertTrue(model.pendingEncryptedCreations.isEmpty)
        let before = try XCTUnwrap(records(state.recordAtCreate).first),joined = try XCTUnwrap(records(state.recordAtJoin).first)
        XCTAssertNil(before["channelID"]);XCTAssertEqual(joined["channelID"] as? Int,96)
        XCTAssertEqual(before["creatorEnvelope"] as? String,joined["creatorEnvelope"] as? String)
        for field in ["name","purpose","password","private_key","public_key","channel_key"] { XCTAssertNil(before[field]) }
        let envelope = try XCTUnwrap(before["creatorEnvelope"] as? String)
        let key = try ChatContentCrypto.unwrapChannelKey(envelope,publicKey:ChatContentCrypto.decodeBase64(state.fixture.publicKey),privateKey:ChatContentCrypto.unlockPrivateKey(state.fixture.wrappedPrivateKey,password:state.fixture.password))
        XCTAssertEqual(key.count,32);XCTAssertNotEqual(key,try ChatContentCrypto.decodeBase64(state.fixture.channelKey))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:XCTUnwrap(state.creationJournalDirectory).path)[.posixPermissions] as? Int,0o700)
    }
    func testLostJoinRestoresKnownIDAndReadOnlyStatusWorksLockedWithoutNavigation() async throws {
        let state = try backend(),directory = try folder(),first = try await model(state,directory:directory)
        state.loseJoinReply = true
        do { try await create(first);XCTFail() } catch { }
        XCTAssertEqual(first.pendingEncryptedCreations.values.first?.channelID,96);first.signOutLocally()
        let restored = try await model(state,directory:directory,unlock:false),intent = try XCTUnwrap(restored.pendingEncryptedCreations.values.first)
        XCTAssertFalse(restored.encryptionUnlocked)
        try await restored.checkEncryptedCreationStatus(intent,expectedGeneration:restored.accountGeneration)
        XCTAssertTrue(restored.pendingEncryptedCreations.isEmpty);XCTAssertEqual(restored.selection,23)
        XCTAssertEqual(state.creates.count,1);XCTAssertEqual(state.joins.count,1)
    }
    func testLostCreateUnknownIDBlocksAnotherCreationAndLocalClearSendsNothing() async throws {
        let state = try backend(),directory = try folder(),first = try await model(state,directory:directory)
        state.loseCreateReply = true
        do { try await create(first);XCTFail() } catch { };first.signOutLocally()
        let restored = try await model(state,directory:directory),intent = try XCTUnwrap(restored.pendingEncryptedCreations.values.first)
        XCTAssertNil(intent.channelID)
        let before = state.requests
        do { try await create(restored);XCTFail() } catch { }
        do { try await restored.checkEncryptedCreationStatus(intent,expectedGeneration:restored.accountGeneration);XCTFail() } catch { }
        try restored.acknowledgeEncryptedCreation(intent,expectedGeneration:restored.accountGeneration)
        XCTAssertEqual(state.requests,before);XCTAssertTrue(restored.pendingEncryptedCreations.isEmpty)
        XCTAssertEqual(state.creates.count,1);XCTAssertTrue(state.joins.isEmpty)
    }
    func testLockedPublicRevokedPermissionOrChangedOwnerCannotCreate() async throws {
        for change in ["locked","public","permission","owner"] {
            let state = try backend(),model = try await model(state,directory:folder())
            switch change {
            case "locked":model.lockEncryption()
            case "permission":state.allowCreate = false
            case "owner":state.ownerPublicOverride = try ChatEncryptionManagement.generateKeyPair(password:"Synthetic other",confirmation:"Synthetic other").public_key
            default:break
            }
            do { try await model.createChannel(name:"Synthetic-encrypted",purpose:"",kind:change == "public" ? .public : .private,encrypted:true);XCTFail(change) } catch { }
            XCTAssertTrue(state.creates.isEmpty,change);XCTAssertTrue(model.pendingEncryptedCreations.isEmpty);XCTAssertFalse(model.channelManagementBusy)
            model.signOutLocally()
        }
    }
    func testPredispatchStorageFailureSendsNothing() async throws {
        let state = try backend(),directory = try folder(),model = try await model(state,directory:directory)
        let lock = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first { $0.pathExtension == "lock" })
        let file = lock.deletingPathExtension().appendingPathExtension("json")
        state.methodHook = { method in if method == "list" { try? Data("synthetic corrupt state".utf8).write(to:file) } }
        do { try await create(model);XCTFail() } catch { }
        XCTAssertTrue(state.creates.isEmpty);XCTAssertNotNil(model.encryptedCreationRecoveryError)
    }
    func testCheckpointFailureAfterCreatePreventsJoin() async throws {
        let state = try backend(),directory = try folder(),model = try await model(state,directory:directory)
        state.methodHook = { method in if method == "create" { try? self.corrupt(directory) } }
        do { try await create(model);XCTFail() } catch { }
        XCTAssertEqual(state.creates.count,1);XCTAssertTrue(state.joins.isEmpty);XCTAssertEqual(model.pendingEncryptedCreations.count,1)
        do { try model.refreshEncryptedCreationRecovery(expectedGeneration:model.accountGeneration);XCTFail() } catch { }
        XCTAssertNotNil(model.encryptedCreationRecoveryError)
    }
    func testConfirmedCreationRemainsSuccessWhenReceiptCleanupFails() async throws {
        let state = try backend(),directory = try folder(),model = try await model(state,directory:directory)
        state.hook = { endpoint in if endpoint == "SYNO.Chat.Channel.Member",!state.joins.isEmpty { try? self.corrupt(directory) } }
        try await create(model)
        XCTAssertEqual(model.selection,96);XCTAssertNotNil(model.encryptedCreationRecoveryError);XCTAssertEqual(model.pendingEncryptedCreations.count,1)
        XCTAssertEqual(state.creates.count,1);XCTAssertEqual(state.joins.count,1)
    }
    func testLateCreateResultCheckpointsOriginalAccountAndNeverJoinsAfterSignoutOrLock() async throws {
        for signout in [false,true] {
            let state = try backend(),directory = try folder(),model = try await model(state,directory:directory)
            let held = expectation(description:"Creation reply held")
            state.holdEndpoint = "SYNO.Chat.Channel.Named";state.onHeld = { held.fulfill() }
            let operation = Task { try await self.create(model) }
            await fulfillment(of:[held],timeout:2)
            if signout { model.signOutLocally() } else { model.lockEncryption() }
            let requests = state.requests;state.release()
            do { try await operation.value;XCTFail() } catch { }
            XCTAssertEqual(state.requests,requests);XCTAssertTrue(state.joins.isEmpty)
            if signout {
                let restored = try await self.model(state,directory:directory,unlock:false)
                XCTAssertEqual(restored.pendingEncryptedCreations.values.first?.channelID,96)
                restored.signOutLocally()
            } else { XCTAssertEqual(model.pendingEncryptedCreations.values.first?.channelID,96);model.signOutLocally() }
        }
    }
    func testChangedScopeDuringMembershipReadPreventsPublicationAndReadOnlyRecovery() async throws {
        let state = try backend(),model = try await model(state,directory:folder())
        state.hook = { endpoint in if endpoint == "SYNO.Chat.Channel.Member",!state.joins.isEmpty { state.createdChannel?["name"] = "Changed-after-join" } }
        do { try await create(model);XCTFail() } catch { }
        let intent = try XCTUnwrap(model.pendingEncryptedCreations.values.first)
        do { try await model.checkEncryptedCreationStatus(intent,expectedGeneration:model.accountGeneration);XCTFail() } catch { }
        XCTAssertEqual(model.selection,23);XCTAssertEqual(model.pendingEncryptedCreations.count,1)
        XCTAssertEqual(state.creates.count,1);XCTAssertEqual(state.joins.count,1)
        let old = model.accountGeneration;model.signOutLocally()
        do { try model.acknowledgeEncryptedCreation(intent,expectedGeneration:old);XCTFail() } catch { }
    }
    func testFreshPermissionOrKeyChangeAfterCreatePreventsJoinAndKeepsKnownID() async throws {
        for key in [false,true] {
            let state = try backend(),model = try await model(state,directory:folder())
            state.methodHook = { method in
                if method == "create" {
                    if key { state.ownerPublicOverride = Data(repeating:7,count:32).base64EncodedString() } else { state.allowCreate = false }
                }
            }
            do { try await create(model);XCTFail() } catch { }
            XCTAssertEqual(state.creates.count,1);XCTAssertTrue(state.joins.isEmpty)
            XCTAssertEqual(model.pendingEncryptedCreations.values.first?.channelID,96);model.signOutLocally()
        }
    }
    private func interrupted(_ state:InvitationIntegrationBackend,model:NativeChatPreviewModel) async throws -> ChatEncryptedCreationIntent {
        state.rejectJoin = true
        do { try await create(model);XCTFail("Synthetic initial join must fail") } catch { }
        state.rejectJoin = false
        return try XCTUnwrap(model.pendingEncryptedCreations.values.first)
    }
    func testExplicitRecoveredJoinReusesSavedKeyAndPersistsNewAttemptBeforeSingleJoin() async throws {
        let state = try backend(),directory = try folder(),first = try await model(state,directory:directory)
        let old = try await interrupted(state,model:first);XCTAssertNotNil(old.joinAttemptID);first.signOutLocally()
        let restored = try await model(state,directory:directory),intent = try XCTUnwrap(restored.pendingEncryptedCreations.values.first)
        restored.draft = "Synthetic unsent draft"
        let requests = state.joins.count,review = try await restored.prepareEncryptedCreationJoin(intent,expectedGeneration:restored.accountGeneration)
        XCTAssertEqual(state.joins.count,requests);XCTAssertEqual(restored.pendingEncryptedCreations[intent.id],intent)
        try await restored.finishEncryptedCreationJoin(review)
        XCTAssertEqual(state.creates.count,1);XCTAssertEqual(state.joins.count,2);XCTAssertTrue(state.invites.isEmpty)
        XCTAssertEqual(state.joins[0]["channel_key_enc"],state.joins[1]["channel_key_enc"])
        let saved = try XCTUnwrap(records(state.recordAtJoin).first)
        XCTAssertNotEqual(saved["joinAttemptID"] as? String,intent.joinAttemptID?.uuidString)
        XCTAssertEqual(saved["creatorEnvelope"] as? String,intent.creatorEnvelope)
        XCTAssertTrue(restored.pendingEncryptedCreations.isEmpty);XCTAssertEqual(restored.selection,23);XCTAssertEqual(restored.draft,"Synthetic unsent draft")
    }
    func testReviewAloneDoesNotJoinAndLockedOrStaleReviewCannotDispatch() async throws {
        let state = try backend(),model = try await model(state,directory:folder()),intent = try await interrupted(state,model:model)
        let review = try await model.prepareEncryptedCreationJoin(intent,expectedGeneration:model.accountGeneration)
        XCTAssertEqual(state.joins.count,1);XCTAssertEqual(model.pendingEncryptedCreations[intent.id],intent)
        model.lockEncryption()
        do { try await model.finishEncryptedCreationJoin(review);XCTFail() } catch { }
        XCTAssertEqual(state.joins.count,1)
        let before = state.requests;model.signOutLocally()
        do { try await model.finishEncryptedCreationJoin(review);XCTFail() } catch { }
        XCTAssertEqual(state.requests,before)
    }
    func testFreshScopeOwnerPermissionAndExistingEnvelopeChangesPreventRecoveredJoin() async throws {
        for change in ["name","owner","permission","envelope","joined","unknown-membership"] {
            let state = try backend(),model = try await model(state,directory:folder()),intent = try await interrupted(state,model:model)
            let review = try await model.prepareEncryptedCreationJoin(intent,expectedGeneration:model.accountGeneration)
            switch change {
            case "name":state.createdChannel?["name"] = "Changed"
            case "owner":state.ownerPublicOverride = Data(repeating:7,count:32).base64EncodedString()
            case "permission":state.allowJoin = false
            case "envelope":state.createdChannel?["channel_key_enc"] = intent.creatorEnvelope
            case "joined":state.createdChannel?["is_joined"] = true
            default:state.createdChannel?.removeValue(forKey:"is_joined")
            }
            do { try await model.finishEncryptedCreationJoin(review);XCTFail(change) } catch { }
            XCTAssertEqual(state.creates.count,1);XCTAssertEqual(state.joins.count,1,change);XCTAssertEqual(model.pendingEncryptedCreations[intent.id],intent)
            model.signOutLocally()
        }
    }
    func testLostRecoveredJoinReplyRestoresAttemptAndStatusClearsWithoutAnotherJoin() async throws {
        let state = try backend(),directory = try folder(),first = try await model(state,directory:directory),intent = try await interrupted(state,model:first)
        let review = try await first.prepareEncryptedCreationJoin(intent,expectedGeneration:first.accountGeneration);state.loseJoinReply = true
        do { try await first.finishEncryptedCreationJoin(review);XCTFail() } catch { }
        let saved = try XCTUnwrap(first.pendingEncryptedCreations[intent.id]);XCTAssertNotEqual(saved.joinAttemptID,intent.joinAttemptID)
        do { try await first.finishEncryptedCreationJoin(review);XCTFail("Old review cannot repeat attempt") } catch { }
        do { _ = try await first.prepareEncryptedCreationJoin(saved,expectedGeneration:first.accountGeneration);XCTFail("Joined channel cannot be joined again") } catch { }
        first.signOutLocally()
        let restored = try await model(state,directory:directory,unlock:false),record = try XCTUnwrap(restored.pendingEncryptedCreations[intent.id])
        try await restored.checkEncryptedCreationStatus(record,expectedGeneration:restored.accountGeneration)
        XCTAssertTrue(restored.pendingEncryptedCreations.isEmpty);XCTAssertEqual(state.joins.count,2);XCTAssertEqual(state.creates.count,1)
    }
    func testRecoveredJoinStorageFailureStopsBeforeRequestAndKeepsAttempt() async throws {
        let state = try backend(),directory = try folder(),model = try await model(state,directory:directory),intent = try await interrupted(state,model:model)
        let review = try await model.prepareEncryptedCreationJoin(intent,expectedGeneration:model.accountGeneration)
        state.methodHook = { method in if method == "list" { try? self.corrupt(directory) } }
        do { try await model.finishEncryptedCreationJoin(review);XCTFail() } catch { }
        XCTAssertEqual(state.joins.count,1);XCTAssertEqual(model.pendingEncryptedCreations[intent.id],intent);XCTAssertNotNil(model.encryptedCreationRecoveryError)
    }
    func testLateRecoveredJoinCannotPublishOrReadThroughSignedOutOrLockedSession() async throws {
        for signout in [false,true] {
            let state = try backend(),directory = try folder(),model = try await model(state,directory:directory),intent = try await interrupted(state,model:model)
            let review = try await model.prepareEncryptedCreationJoin(intent,expectedGeneration:model.accountGeneration),held = expectation(description:"Recovered join held")
            state.holdEndpoint = "SYNO.Chat.Channel.Named";state.onHeld = { held.fulfill() }
            let operation = Task { try await model.finishEncryptedCreationJoin(review) }
            await fulfillment(of:[held],timeout:2)
            if signout { model.signOutLocally() } else { model.lockEncryption() }
            let before = state.requests;state.release()
            do { try await operation.value;XCTFail() } catch { }
            XCTAssertEqual(state.requests,before);XCTAssertEqual(state.joins.count,2);XCTAssertEqual(state.creates.count,1)
            if signout {
                let restored = try await self.model(state,directory:directory,unlock:false)
                XCTAssertNotEqual(restored.pendingEncryptedCreations[intent.id]?.joinAttemptID,intent.joinAttemptID);restored.signOutLocally()
            } else { XCTAssertEqual(model.selection,23);XCTAssertNotNil(model.pendingEncryptedCreations[intent.id]);model.signOutLocally() }
        }
    }
    func testRecoveredJoinCanonicalFailureAndConfirmedCleanupFailureKeepCorrectOutcome() async throws {
        for corrupt in [false,true] {
            let state = try backend(),directory = try folder(),model = try await model(state,directory:directory),intent = try await interrupted(state,model:model)
            let review = try await model.prepareEncryptedCreationJoin(intent,expectedGeneration:model.accountGeneration)
            state.hook = { endpoint in if endpoint == "SYNO.Chat.Channel.Member",state.joins.count == 2 {
                if corrupt { try? self.corrupt(directory) } else { state.createdChannel?["creator_id"] = 20 }
            } }
            if corrupt { try await model.finishEncryptedCreationJoin(review);XCTAssertNotNil(model.encryptedCreationRecoveryError) }
            else { do { try await model.finishEncryptedCreationJoin(review);XCTFail() } catch { } }
            XCTAssertEqual(state.joins.count,2);XCTAssertNotNil(model.pendingEncryptedCreations[intent.id]);XCTAssertEqual(model.selection,23);model.signOutLocally()
        }
    }
    func testAnotherJournalCreationBetweenPreflightAndDispatchPreventsSecondCreate() async throws {
        let state = try backend(),directory = try folder(),model = try await model(state,directory:directory)
        let owner = ChatEncryptionKeyPair(public_key:state.fixture.publicKey,private_key_enc:state.fixture.wrappedPrivateKey),keys = ChatEncryptionSession()
        try keys.unlock(owner,password:state.fixture.password)
        let other = try ChatEncryptedCreationIntent(plan:ChatEncryptedChannelCreation(owner:owner,encryption:keys),ownerID:10,owner:owner,name:"Synthetic-other-request",purpose:"")
        let lock = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first { $0.pathExtension == "lock" })
        let journal = ChatEncryptedCreationJournal(directory:directory),scope = lock.deletingPathExtension().lastPathComponent
        _ = try journal.activate(scope:scope);var injected = false
        state.methodHook = { method in if method == "list",!injected { injected = true;try? journal.rememberAsOnlyPending(other) } }
        do { try await create(model);XCTFail("Competing request must block this create") } catch { }
        XCTAssertTrue(injected);XCTAssertTrue(state.creates.isEmpty);XCTAssertTrue(state.joins.isEmpty)
        XCTAssertEqual(try journal.activate(scope:scope),[other])
        try model.refreshEncryptedCreationRecovery(expectedGeneration:model.accountGeneration)
        XCTAssertEqual(model.pendingEncryptedCreations[other.id],other)
    }
    func testOlderReceiptWithoutJoinFieldsRestoresAndMalformedPhaseOrForeignEnvelopeIsRejected() async throws {
        let state = try backend(),directory = try folder(),model = try await model(state,directory:directory),intent = try await interrupted(state,model:model)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(intent)) as? [String:Any]);object.removeValue(forKey:"joinAttemptID");object.removeValue(forKey:"lastJoinAt")
        let old = try JSONDecoder().decode(ChatEncryptedCreationIntent.self,from:JSONSerialization.data(withJSONObject:object));try old.validate();XCTAssertNil(old.joinAttemptID)
        object["lastJoinAt"] = Date().timeIntervalSince1970
        let malformed = try JSONDecoder().decode(ChatEncryptedCreationIntent.self,from:JSONSerialization.data(withJSONObject:object));XCTAssertThrowsError(try malformed.validate())
        object.removeValue(forKey:"lastJoinAt")
        let peer = try XCTUnwrap(state.peerPairs[20]);object["creatorEnvelope"] = try ChatContentCrypto.wrapChannelKey(Data(repeating:7,count:32),publicKey:ChatContentCrypto.decodeBase64(peer.public_key))
        let foreign = try JSONDecoder().decode(ChatEncryptedCreationIntent.self,from:JSONSerialization.data(withJSONObject:object))
        let lock = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first { $0.pathExtension == "lock" })
        let journal = ChatEncryptedCreationJournal(directory:directory);_ = try journal.activate(scope:lock.deletingPathExtension().lastPathComponent);try journal.replace(intent,with:foreign)
        try model.refreshEncryptedCreationRecovery(expectedGeneration:model.accountGeneration)
        do { _ = try await model.prepareEncryptedCreationJoin(foreign,expectedGeneration:model.accountGeneration);XCTFail("Foreign sealed key must not be joined") } catch { }
        XCTAssertEqual(state.joins.count,1);XCTAssertEqual(state.creates.count,1)
    }

}
#endif
