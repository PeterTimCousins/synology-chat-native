#if DEBUG
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatChannelInvitationIntegrationTests:XCTestCase {
    private func backend(encrypted:Bool = true) throws -> InvitationIntegrationBackend {
        let file = try XCTUnwrap(Bundle.module.url(forResource:"ChatCrypto",withExtension:"json",subdirectory:"Fixtures"))
        return try InvitationIntegrationBackend(fixture:JSONDecoder().decode(InvitationIntegrationFixture.self,from:Data(contentsOf:file)),encrypted:encrypted)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-invitation-integration-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url
    }
    private func model(_ backend:InvitationIntegrationBackend,journal:ChatChannelInvitationJournal? = nil,unlock:Bool = true) async throws -> NativeChatPreviewModel {
        InvitationIntegrationProtocol.backend = backend
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [InvitationIntegrationProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:c))
        },invitationJournal:journal)
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://invitation-integration.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-inviter",importedFromOfficialApp:false))
        XCTAssertTrue(model.connected,model.error ?? "Connection failed")
        model.suspendLiveForProbe();model.selection = 23
        if backend.encrypted && unlock { try model.unlockEncryption(password:backend.fixture.password);await model.historyTask?.value }
        model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    func testEncryptedModelInvitationPersistsBeforeWireAndConfirmsAlignedRecipientKeys() async throws {
        let state = try backend(),directory = try folder();state.journalDirectory = directory
        let model = try await model(state,journal:.init(directory:directory))
        let snapshot = try await model.invitationSnapshot(channelID:23)
        XCTAssertTrue(model.canInviteMembers(snapshot.channel))
        try await model.inviteMembers([30,20],channelID:23,reviewed:snapshot)
        XCTAssertEqual(state.invites.count,1);XCTAssertEqual(Set(state.members),[10,20,30]);XCTAssertTrue(model.pendingInvitations.isEmpty)
        let fields = try XCTUnwrap(state.invites.first),envelopes = try JSONDecoder().decode([String].self,from:Data(try XCTUnwrap(fields["channel_key_encs"]).utf8))
        XCTAssertEqual(fields["user_ids"],"[20,30]");XCTAssertEqual(envelopes.count,2)
        for (index,id) in [Int64(20),30].enumerated() {
            let pair = try XCTUnwrap(state.peerPairs[id])
            XCTAssertEqual(try ChatContentCrypto.unwrapChannelKey(envelopes[index],publicKey:ChatContentCrypto.decodeBase64(pair.public_key),privateKey:ChatContentCrypto.unlockPrivateKey(pair.private_key_enc,password:state.peerPassword)),try ChatContentCrypto.decodeBase64(state.fixture.channelKey))
        }
        let raw = try XCTUnwrap(state.recordAtWrite),record = try XCTUnwrap((try JSONSerialization.jsonObject(with:raw) as? [String:Any])?["records"] as? [[String:Any]]).first
        XCTAssertEqual(record?["members"] as? [Int],[20,30]);XCTAssertEqual(record?["encrypted"] as? Bool,true)
        for field in ["public_key","private_key_enc","channel_key_enc","channel_key_encs","password","username"] { XCTAssertNil(record?[field]) }
        let pairs = try [Int64(20),30].map { try XCTUnwrap(state.peerPairs[$0]) }
        let exported:[String:Any] = ["synthetic_only":true,"channel_key":state.fixture.channelKey,"user_ids":[20,30],"envelopes":envelopes,"public_keys":pairs.map(\.public_key),"private_keys":try pairs.map { try ChatContentCrypto.unlockPrivateKey($0.private_key_enc,password:state.peerPassword).base64EncodedString() }]
        let file = URL(fileURLWithPath:"/private/tmp/native-model-invitation-interop.json")
        try JSONSerialization.data(withJSONObject:exported,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func testReviewedIdentityKeysScopeAndPermissionChangesPreventEncryptedInvites() async throws {
        for change in ["locked","recipient-key","owner-key","permission","scope","renamed"] {
            let state = try backend(),model = try await model(state),snapshot = try await model.invitationSnapshot(channelID:23)
            switch change {
            case "locked":model.lockEncryption()
            case "recipient-key":state.peerPairs[20] = try ChatEncryptionManagement.generateKeyPair(password:state.peerPassword,confirmation:state.peerPassword)
            case "owner-key":state.ownerPublicOverride = try ChatEncryptionManagement.generateKeyPair(password:state.peerPassword,confirmation:state.peerPassword).public_key
            case "permission":state.allowInvite = false
            case "scope":state.ownerEnvelopeOverride = try ChatContentCrypto.wrapChannelKey(Data(repeating:7,count:32),publicKey:ChatContentCrypto.decodeBase64(state.fixture.publicKey))
            case "renamed":state.renamed = true
            default:break
            }
            do { try await model.inviteMembers([20],channelID:23,reviewed:snapshot);XCTFail(change) } catch { }
            XCTAssertTrue(state.invites.isEmpty,change);XCTAssertTrue(model.pendingInvitations.isEmpty);XCTAssertFalse(model.channelManagementBusy)
            model.signOutLocally()
        }
    }
    func testMissingPeerPublicKeyIsUnavailableAndCannotFallBackToEmptyEnvelope() async throws {
        let state = try backend();state.missingKeys = [20]
        let model = try await model(state),snapshot = try await model.invitationSnapshot(channelID:23),peer = try XCTUnwrap(snapshot.users.first { $0.user_id == 20 })
        XCTAssertFalse(ChatEncryptedChannelInvitation.hasUsablePublicKey(peer))
        do { try await model.inviteMembers([20],channelID:23,reviewed:snapshot);XCTFail() } catch { }
        XCTAssertTrue(state.invites.isEmpty);XCTAssertTrue(model.pendingInvitations.isEmpty)
    }
    func testUpdatedProfileCannotPretendAnOldUnlockedSessionOwnsTheNewPublicKey() async throws {
        let state = try backend(),model = try await model(state)
        state.ownerPublicOverride = try ChatEncryptionManagement.generateKeyPair(password:state.peerPassword,confirmation:state.peerPassword).public_key
        model.directory = try JSONDecoder().decode([ChatUser].self,from:JSONSerialization.data(withJSONObject:state.users))
        XCTAssertTrue(model.encryptionUnlocked)
        do { _ = try await model.invitationSnapshot(channelID:23);XCTFail("Stale private session accepted changed public key") } catch { }
        XCTAssertTrue(state.invites.isEmpty);XCTAssertTrue(model.pendingInvitations.isEmpty)
    }
    func testLostReplyRestoresAcrossNewModelAndChecksMembershipWhileLockedWithoutResend() async throws {
        let state = try backend(),directory = try folder(),first = try await model(state,journal:.init(directory:directory))
        let snapshot = try await first.invitationSnapshot(channelID:23);state.loseReply = true
        do { try await first.inviteMembers([20],channelID:23,reviewed:snapshot);XCTFail() } catch let error as ChatChannelInvitationFailure { XCTAssertTrue(error.uncertain) }
        XCTAssertEqual(first.pendingInvitations.count,1);first.signOutLocally()
        let restored = try await model(state,journal:.init(directory:directory),unlock:false),intent = try XCTUnwrap(restored.pendingInvitations[23])
        XCTAssertFalse(restored.encryptionUnlocked)
        do { try await restored.inviteMembers([20],channelID:23);XCTFail() } catch let error as ChatChannelInvitationFailure { XCTAssertTrue(error.uncertain) }
        try await restored.checkInvitationStatus(intent,expectedGeneration:restored.accountGeneration)
        XCTAssertEqual(state.invites.count,1);XCTAssertTrue(restored.pendingInvitations.isEmpty);XCTAssertFalse(restored.hasPendingActions)
    }
    func testPartialInvitationRemainsPendingUntilLocalAcknowledgementAndSeparateManualAction() async throws {
        let state = try backend(),model = try await model(state),snapshot = try await model.invitationSnapshot(channelID:23)
        state.applyOnly = [20]
        do { try await model.inviteMembers([20,30],channelID:23,reviewed:snapshot);XCTFail() } catch { }
        let intent = try XCTUnwrap(model.pendingInvitations[23])
        do { try await model.checkInvitationStatus(intent,expectedGeneration:model.accountGeneration);XCTFail() } catch { }
        let before = state.requests
        try model.acknowledgeInvitationOutcome(intent,expectedGeneration:model.accountGeneration)
        XCTAssertEqual(state.requests,before);XCTAssertTrue(model.pendingInvitations.isEmpty);XCTAssertEqual(state.invites.count,1)
        state.applyOnly = nil
        let fresh = try await model.invitationSnapshot(channelID:23)
        try await model.inviteMembers([30],channelID:23,reviewed:fresh)
        XCTAssertEqual(state.invites.count,2);XCTAssertEqual(Set(state.members),[10,20,30])
    }
    func testKeyLockDuringUserReadAndSignoutDuringWriteRetireOldAccountWork() async throws {
        for duringWrite in [false,true] {
            let state = try backend(),directory = try folder(),model = try await model(state,journal:.init(directory:directory)),snapshot = try await model.invitationSnapshot(channelID:23)
            let started = expectation(description:"Held invitation phase")
            state.holdEndpoint = duringWrite ? "SYNO.Chat.Channel.Named" : "SYNO.Chat.User";state.onHeld = { started.fulfill() }
            let operation = Task { try await model.inviteMembers([20],channelID:23,reviewed:snapshot) }
            await fulfillment(of:[started],timeout:2)
            if duringWrite { model.signOutLocally() } else { model.lockEncryption() }
            let before = state.requests;state.release()
            do { try await operation.value;XCTFail() } catch { }
            XCTAssertEqual(state.requests,before);XCTAssertEqual(state.invites.count,duringWrite ? 1 : 0);XCTAssertFalse(model.channelManagementBusy)
            if duringWrite {
                XCTAssertTrue(model.directory.isEmpty)
                let restored = try await self.model(state,journal:.init(directory:directory),unlock:false)
                XCTAssertEqual(restored.pendingInvitations.count,1);restored.signOutLocally()
            }
            model.signOutLocally()
        }
    }
    func testRecoveryWriteFailureAndAcknowledgedCleanupFailureAreDistinguished() async throws {
        for afterDispatch in [false,true] {
            let state = try backend(),directory = try folder(),journal = ChatChannelInvitationJournal(directory:directory),model = try await model(state,journal:journal),snapshot = try await model.invitationSnapshot(channelID:23)
            let file = directory.appendingPathComponent(try XCTUnwrap(journal.accountScope)+".json"),targetRead = state.userReads+4
            state.hook = { [weak state] endpoint in
                guard let state else { return }
                if afterDispatch ? endpoint == "SYNO.Chat.Channel.Named" : endpoint == "SYNO.Chat.User" && state.userReads == targetRead { try? Data("corrupt synthetic storage".utf8).write(to:file) }
            }
            do { try await model.inviteMembers([20],channelID:23,reviewed:snapshot);XCTAssertTrue(afterDispatch) }
            catch { XCTAssertFalse(afterDispatch,"Confirmed membership must remain successful: \(error)") }
            XCTAssertEqual(state.invites.count,afterDispatch ? 1 : 0);XCTAssertNotNil(model.invitationRecoveryError)
            XCTAssertEqual(model.pendingInvitations.count,afterDispatch ? 1 : 0);model.signOutLocally()
        }
    }
    func testPlainInviteRetainsEmptyEnvelopeWireAndStaleReviewCannotAddPeople() async throws {
        let state = try backend(encrypted:false),model = try await model(state),snapshot = try await model.invitationSnapshot(channelID:23),reads = state.memberReads
        try await model.inviteMembers([20],channelID:23,reviewed:snapshot)
        XCTAssertEqual(state.invites.first?["channel_key_encs"],"[]");XCTAssertEqual(state.memberReadsAtWrite-reads,1)
        model.signOutLocally()
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://invitation-integration.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-inviter",importedFromOfficialApp:false))
        model.suspendLiveForProbe();model.liveStatus = .live
        let before = state.requests
        do { try await model.inviteMembers([30],channelID:23,reviewed:snapshot);XCTFail() } catch { }
        XCTAssertEqual(state.requests,before);XCTAssertEqual(state.invites.count,1)
    }
    func testOfflineUIFactoryLoadsFreshKeyAvailabilityWithoutInvitingAnyone() async throws {
        let directory = URL(fileURLWithPath:"/private/tmp/native-channel-invitation-fixture.test-"+UUID().uuidString,isDirectory:true)
        let (model,state) = try await NativeChannelInvitationUIFixture.makeModel(directory:directory)
        defer { model.signOutLocally();try? FileManager.default.removeItem(at:directory) }
        let snapshot = try await model.invitationSnapshot(channelID:23)
        XCTAssertTrue(model.canInviteMembers(snapshot.channel));XCTAssertTrue(state.invites.isEmpty)
        XCTAssertTrue(ChatEncryptedChannelInvitation.hasUsablePublicKey(try XCTUnwrap(snapshot.users.first { $0.user_id == 20 })))
        XCTAssertFalse(ChatEncryptedChannelInvitation.hasUsablePublicKey(try XCTUnwrap(snapshot.users.first { $0.user_id == 30 })))
        XCTAssertThrowsError(try NativeChannelInvitationUIFixture.validateDirectory(URL(fileURLWithPath:"/private/tmp/unrelated-invitation-state")))
    }
}

#endif
