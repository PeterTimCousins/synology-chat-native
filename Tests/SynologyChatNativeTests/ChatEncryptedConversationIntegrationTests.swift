#if DEBUG
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatEncryptedConversationIntegrationTests:XCTestCase {
    private func backend() throws -> InvitationIntegrationBackend {
        let file = try XCTUnwrap(Bundle.module.url(forResource:"ChatCrypto",withExtension:"json",subdirectory:"Fixtures"))
        let state = try InvitationIntegrationBackend(fixture:JSONDecoder().decode(InvitationIntegrationFixture.self,from:Data(contentsOf:file)),encrypted:true);state.allowAnonymous = true;return state
    }
    private func folder() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-start-model-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true);addTeardownBlock { try? FileManager.default.removeItem(at:path) };return path
    }
    private func model(_ state:InvitationIntegrationBackend,directory:URL,unlock:Bool = true) async throws -> NativeChatPreviewModel {
        InvitationIntegrationProtocol.backend = state;state.creationJournalDirectory = directory
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [InvitationIntegrationProtocol.self];return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        },encryptedConversationJournal:.init(directory:directory))
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://invitation-integration.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-inviter",importedFromOfficialApp:false))
        XCTAssertTrue(model.connected,model.error ?? "Not connected");model.suspendLiveForProbe();model.selection = 23
        if unlock { try model.unlockEncryption(password:state.fixture.password);await model.historyTask?.value }
        model.liveStatus = .live;addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    func testEncryptedStartPersistsBeforeOneRequestAndPublishesOnlyAfterCanonicalConfirmation() async throws {
        let state = try backend(),model = try await model(state,directory:folder()),review = try await model.loadQuickSwitcher()
        model.draft = "Synthetic retained draft"
        try await model.startEncryptedConversation(with:[20,30],reviewed:review)
        XCTAssertEqual(state.anonymousStarts.count,1);XCTAssertTrue(state.creates.isEmpty);XCTAssertTrue(state.joins.isEmpty)
        let saved = try XCTUnwrap(state.recordAtCreate),object = try XCTUnwrap(JSONSerialization.jsonObject(with:saved) as? [String:Any])
        XCTAssertEqual((object["records"] as? [Any])?.count,1)
        XCTAssertFalse(String(decoding:saved,as:UTF8.self).contains("Synthetic peer"))
        XCTAssertEqual(model.selection,96);XCTAssertEqual(model.drafts[23],"Synthetic retained draft");XCTAssertTrue(model.pendingEncryptedConversationStarts.isEmpty)
        XCTAssertFalse(model.channelManagementBusy)
    }
    func testLostReplyRestoresPendingAndStatusChecksWithoutReplayOrNavigation() async throws {
        let state = try backend(),directory = try folder(),model = try await model(state,directory:directory),review = try await model.loadQuickSwitcher()
        state.loseAnonymousReply = true
        do { try await model.startEncryptedConversation(with:[20],reviewed:review);XCTFail() } catch { }
        XCTAssertEqual(state.anonymousStarts.count,1);XCTAssertEqual(model.selection,23)
        let intent = try XCTUnwrap(model.pendingEncryptedConversationStarts.values.first);XCTAssertNil(intent.candidateChannelID)
        model.signOutLocally()
        let restored = try await self.model(state,directory:directory,unlock:false)
        XCTAssertEqual(restored.pendingEncryptedConversationStarts.values.first,intent)
        let locked = try await restored.checkEncryptedConversationStart(intent,expectedGeneration:restored.accountGeneration);XCTAssertEqual(locked.status,.needsUnlock)
        try restored.unlockEncryption(password:state.fixture.password);await restored.historyTask?.value;restored.liveStatus = .live
        let result = try await restored.checkEncryptedConversationStart(intent,expectedGeneration:restored.accountGeneration)
        XCTAssertEqual(result.status,.verified);XCTAssertEqual(result.candidateChannelID,96);XCTAssertEqual(restored.selection,23)
        XCTAssertEqual(state.anonymousStarts.count,1);XCTAssertEqual(restored.pendingEncryptedConversationStarts.count,1)
        let old = restored.accountGeneration;restored.signOutLocally()
        XCTAssertThrowsError(try restored.acknowledgeEncryptedConversationStart(intent,expectedGeneration:old))
    }
    func testExistingEncryptedParticipantSetIsReusedWithoutNewInitiation() async throws {
        let state = try backend(),model = try await model(state,directory:folder())
        let pair = ChatEncryptionKeyPair(public_key:state.fixture.publicKey,private_key_enc:state.fixture.wrappedPrivateKey),keys = ChatEncryptionSession();try keys.unlock(pair,password:state.fixture.password)
        let users = try JSONDecoder().decode([ChatUser].self,from:JSONSerialization.data(withJSONObject:state.users)),plan = try ChatEncryptedConversationStart(ownerID:10,owner:pair,users:users.filter { [10,20].contains($0.user_id) },encryption:keys)
        state.createdChannel = ["channel_id":96,"name":"","type":"anonymous","encrypted":true,"is_joined":true,"unread":0,"channel_key_enc":plan.ownerEnvelope];state.anonymousMembers = [10,20]
        let review = try await model.loadQuickSwitcher();try await model.startEncryptedConversation(with:[20],reviewed:review)
        XCTAssertEqual(model.selection,96);XCTAssertTrue(state.anonymousStarts.isEmpty);XCTAssertTrue(model.pendingEncryptedConversationStarts.isEmpty)
    }
    func testLateReplyCheckpointsOriginalAccountButNeverPublishesAfterLockOrSignout() async throws {
        for signout in [false,true] {
            let state = try backend(),directory = try folder(),model = try await model(state,directory:directory),review = try await model.loadQuickSwitcher()
            let held = expectation(description:"Synthetic initiation reply held");state.holdEndpoint = "SYNO.Chat.Channel.Anonymous";state.onHeld = { held.fulfill() }
            let operation = Task { try await model.startEncryptedConversation(with:[20],reviewed:review) }
            await fulfillment(of:[held],timeout:2)
            if signout { model.signOutLocally() } else { model.lockEncryption() }
            let requestCount = state.requests
            state.release();do { try await operation.value;XCTFail() } catch { }
            XCTAssertEqual(state.anonymousStarts.count,1)
            XCTAssertEqual(state.requests,requestCount)
            if signout {
                let restored = try await self.model(state,directory:directory,unlock:false)
                XCTAssertEqual(restored.pendingEncryptedConversationStarts.values.first?.candidateChannelID,96)
            } else { XCTAssertEqual(model.selection,23);XCTAssertEqual(model.pendingEncryptedConversationStarts.values.first?.candidateChannelID,96) }
        }
    }
    func testChangedRecipientOrRevokedPermissionBeforeDispatchSendsNothing() async throws {
        for permission in [false,true] {
            let state = try backend(),model = try await model(state,directory:folder()),review = try await model.loadQuickSwitcher()
            if permission { state.allowAnonymous = false } else { state.missingKeys = [20] }
            do { try await model.startEncryptedConversation(with:[20],reviewed:review);XCTFail() } catch { }
            XCTAssertTrue(state.anonymousStarts.isEmpty);XCTAssertTrue(model.pendingEncryptedConversationStarts.isEmpty)
        }
    }
    func testCanonicalMembershipChangeRetainsKnownCandidateWithoutPublication() async throws {
        let state = try backend(),model = try await model(state,directory:folder()),review = try await model.loadQuickSwitcher()
        state.hook = { endpoint in if endpoint == "SYNO.Chat.Channel.Anonymous" { state.anonymousMembers = [10,20,30] } }
        do { try await model.startEncryptedConversation(with:[20],reviewed:review);XCTFail() } catch { }
        XCTAssertEqual(state.anonymousStarts.count,1);XCTAssertEqual(model.selection,23)
        XCTAssertEqual(model.pendingEncryptedConversationStarts.values.first?.candidateChannelID,96)
    }
    func testCorruptJournalBeforeCreationPreventsDispatch() async throws {
        let state = try backend(),directory = try folder(),model = try await model(state,directory:directory),review = try await model.loadQuickSwitcher()
        let lock = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first { $0.pathExtension == "lock" })
        try Data("corrupt synthetic receipt".utf8).write(to:lock.deletingPathExtension().appendingPathExtension("json"))
        do { try await model.startEncryptedConversation(with:[20],reviewed:review);XCTFail() } catch { }
        XCTAssertTrue(state.anonymousStarts.isEmpty);XCTAssertNotNil(model.encryptedConversationRecoveryError)
    }
    func testRecipientKeyChangeInFinalPreflightResponsePreventsInitiation() async throws {
        let state = try backend(),model = try await model(state,directory:folder()),review = try await model.loadQuickSwitcher()
        let replacement = try ChatEncryptionManagement.generateKeyPair(password:"Replacement synthetic",confirmation:"Replacement synthetic")
        var readsAfterIntent = 0
        state.hook = { endpoint in
            guard endpoint == "SYNO.Chat.User",let data = state.creationRecord(),
                  let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  (value["records"] as? [Any])?.isEmpty == false else { return }
            readsAfterIntent += 1
            // The snapshot response was already assembled; the next/final
            // directory response contains this newer participant key.
            if readsAfterIntent == 1 { state.peerPairs[20] = replacement }
        }
        do { try await model.startEncryptedConversation(with:[20],reviewed:review);XCTFail() } catch { }
        XCTAssertGreaterThanOrEqual(readsAfterIntent,2)
        XCTAssertTrue(state.anonymousStarts.isEmpty);XCTAssertEqual(model.selection,23);XCTAssertTrue(model.pendingEncryptedConversationStarts.isEmpty)
    }
    private func interrupted(_ state:InvitationIntegrationBackend,model:NativeChatPreviewModel) async throws -> ChatEncryptedConversationIntent {
        let snapshot = try await model.loadQuickSwitcher();state.loseAnonymousReply = true
        do { try await model.startEncryptedConversation(with:[20],reviewed:snapshot);XCTFail() } catch { }
        return try XCTUnwrap(model.pendingEncryptedConversationStarts.values.first)
    }
    func testReviewedRecoveryOpensWithoutRepeatingInitiationAndPreservesOriginDraft() async throws {
        let state = try backend(),model = try await model(state,directory:folder())
        model.draft = "Synthetic recovery origin draft"
        let intent = try await interrupted(state,model:model),review = try await model.prepareEncryptedConversationOpen(intent,expectedGeneration:model.accountGeneration)
        XCTAssertFalse(review.requiresExistingReview);XCTAssertEqual(model.selection,23)
        try await model.openRecoveredEncryptedConversation(review)
        XCTAssertEqual(model.selection,96);XCTAssertEqual(state.anonymousStarts.count,1);XCTAssertTrue(model.pendingEncryptedConversationStarts.isEmpty)
        XCTAssertEqual(model.drafts[23],"Synthetic recovery origin draft")
    }
    func testRecoveredOpenRejectsChangedMembershipIdentityAndLockedReview() async throws {
        for variant in 0..<3 {
            let state = try backend(),model = try await model(state,directory:folder()),intent = try await interrupted(state,model:model)
            let review = try await model.prepareEncryptedConversationOpen(intent,expectedGeneration:model.accountGeneration)
            if variant == 0 { state.anonymousMembers = [10,20,30] }
            if variant == 1 { state.renamed = true }
            if variant == 2 { model.lockEncryption() }
            do { try await model.openRecoveredEncryptedConversation(review);XCTFail() } catch { }
            XCTAssertEqual(model.selection,23);XCTAssertEqual(state.anonymousStarts.count,1);XCTAssertEqual(model.pendingEncryptedConversationStarts.count,1)
        }
    }
    func testRecoveredOpenPreservesNewerNavigationAndPendingReceipt() async throws {
        let state = try backend(),model = try await model(state,directory:folder()),intent = try await interrupted(state,model:model)
        let review = try await model.prepareEncryptedConversationOpen(intent,expectedGeneration:model.accountGeneration)
        let held = expectation(description:"Recovery channel read held")
        state.holdEndpoint = "SYNO.Chat.Channel";state.onHeld = { held.fulfill() }
        let operation = Task { try await model.openRecoveredEncryptedConversation(review) }
        await fulfillment(of:[held],timeout:2)
        model.selection = nil
        state.release();do { try await operation.value;XCTFail() } catch { }
        XCTAssertNil(model.selection);XCTAssertEqual(model.pendingEncryptedConversationStarts.count,1)
        XCTAssertEqual(state.anonymousStarts.count,1)
    }
}
#endif
