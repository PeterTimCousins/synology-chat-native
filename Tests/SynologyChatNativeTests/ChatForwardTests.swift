import XCTest
@testable import SynologyChatNative

@MainActor final class ChatForwardTests:XCTestCase {
    private func client() async throws -> ChatAPIClient {
        let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ForwardProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://forward-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:c))
        try await api.discover();return api
    }
    private func post(_ object:[String:Any] = ForwardProtocol.source) throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:object)) }
    private func model(journal:ChatForwardJournal? = nil) async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ForwardProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:c))
        },forwardJournal:journal)
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://forward-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 93;model.posts = [try post()]
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func setUp() { super.setUp();ForwardProtocol.reset() }
    override func tearDown() { ForwardProtocol.observer = nil;ForwardProtocol.held = nil;super.tearDown() }
    func testForwardWireAndDestinationBounds() async throws {
        let api = try await client()
        var calls = 0
        ForwardProtocol.observer = { fields in
            if fields["method"] == "forward" { calls += 1;XCTAssertEqual(fields["version"],"5");XCTAssertEqual(fields["post_id"],"1");XCTAssertEqual(fields["channel_ids"],"[93,94]");XCTAssertNil(fields["message"]);XCTAssertNil(fields["conn_id"]) }
        }
        try await api.forwardPost(postID:1,channelIDs:[93,94])
        for targets:[Int64] in [[],[0],[93,93],Array(1...21)] {
            do { try await api.forwardPost(postID:1,channelIDs:targets);XCTFail("Invalid destinations sent") } catch ChatAPIError.invalidResponse { }
        }
        do { try await api.forwardPost(postID:0,channelIDs:[93]);XCTFail("Invalid source sent") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(calls,1)
    }
    func testNativeForwardConfirmsEveryDestinationAndPreservesSource() async throws {
        let model = try await model(),source = try post()
        let result = try await model.forwardMessage(source,to:[93,94])
        XCTAssertEqual(result.map(\.channel_id),[93,94]);XCTAssertEqual(ForwardProtocol.forwardCalls,1)
        XCTAssertEqual(result.map { $0.props?.forward?.origin_post_id },[1,1])
        XCTAssertEqual(model.posts.map(\.id),[1,193]);XCTAssertTrue(model.pendingMessageActions.isEmpty)
        XCTAssertEqual(model.posts.first?.message,source.message)
    }
    func testChangedCanonicalSourceDoesNotSend() async throws {
        let model = try await model(),source = try post()
        ForwardProtocol.source["message"] = "Changed after preview"
        do { _ = try await model.forwardMessage(source,to:[94]);XCTFail("Stale source sent") }
        catch let failure as NativeForwardFailure { XCTAssertFalse(failure.uncertain) }
        XCTAssertEqual(ForwardProtocol.forwardCalls,0)
    }
    func testSuccessEnvelopeWithoutReceiptIsUncertainAndNeverRetried() async throws {
        let model = try await model();ForwardProtocol.ignoreForward = true
        do { _ = try await model.forwardMessage(try post(),to:[94]);XCTFail("Empty success accepted") }
        catch let failure as NativeForwardFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(ForwardProtocol.forwardCalls,1);XCTAssertEqual(model.posts.map(\.id),[1])
    }
    func testPartialMultiDestinationDeliveryDoesNotClaimSuccess() async throws {
        let model = try await model();ForwardProtocol.missingDestination = 94
        do { _ = try await model.forwardMessage(try post(),to:[93,94]);XCTFail("Partial result accepted") }
        catch let failure as NativeForwardFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(ForwardProtocol.forwardCalls,1);XCTAssertEqual(model.posts.map(\.id),[1])
    }
    func testSignOutWhileForwardHeldPreventsOldAccountReadbackOrPublication() async throws {
        let model = try await model(),started = expectation(description:"Forward dispatched")
        ForwardProtocol.hold = true
        ForwardProtocol.observer = { if $0["method"] == "forward" { started.fulfill() } }
        let task = Task { try await model.forwardMessage(try post(),to:[93]) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();ForwardProtocol.held?.finish(["success":true])
        do { _ = try await task.value;XCTFail("Old account returned result") } catch is CancellationError { }
        XCTAssertTrue(model.posts.isEmpty);XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testPolicyExcludesUnsupportedMessagesBotsAndEncryptedChannels() async throws {
        let model = try await model(),source = try post()
        XCTAssertTrue(model.canForward(source))
        for type in ["system","vote","unknown"] { var obj = ForwardProtocol.source;obj["type"] = type;XCTAssertFalse(model.canForward(try post(obj))) }
        var obj = ForwardProtocol.source;obj["delete_at"] = 2000;XCTAssertFalse(model.canForward(try post(obj)))
        obj = ForwardProtocol.source;obj["creator_id"] = 20;XCTAssertFalse(model.canForward(try post(obj)))
        obj = ForwardProtocol.source;obj["props"] = ["encrypted":true];XCTAssertFalse(model.canForward(try post(obj)))
        let channel = try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":95,"name":"Secret","type":"private","encrypted":true,"unread":0}"#.utf8))
        XCTAssertFalse(ChatForwardPolicy.destination(channel))
        do { _ = try await model.forwardMessage(source,to:[95]);XCTFail("Unknown/encrypted target sent") } catch let error as NativeForwardFailure { XCTAssertFalse(error.uncertain) }
        XCTAssertEqual(ForwardProtocol.forwardCalls,0)
    }
    func testForwardMetadataIsOptionalAndReceiptRejectsOldWrongOrDeletedCopies() throws {
        var malformed = ForwardProtocol.source;malformed["props"] = ["safe_url":true,"forward":["invalid":true]]
        XCTAssertEqual(try post(malformed).props?.safe_url,true);XCTAssertNil(try post(malformed).props?.forward)
        let source = try post();var copy = ForwardProtocol.copy(to:94);let valid = try post(copy)
        XCTAssertTrue(ChatForwardPolicy.receipt(valid,source:source,channelID:94,userID:10,previous:[]))
        XCTAssertFalse(ChatForwardPolicy.receipt(valid,source:source,channelID:94,userID:10,previous:[valid.id]))
        copy["creator_id"] = 6;XCTAssertFalse(ChatForwardPolicy.receipt(try post(copy),source:source,channelID:94,userID:10,previous:[]))
        copy = ForwardProtocol.copy(to:94);copy["delete_at"] = 2000;XCTAssertFalse(ChatForwardPolicy.receipt(try post(copy),source:source,channelID:94,userID:10,previous:[]))
    }
    func testForwardingAnExistingCopyReferencesImmediateSourceNotOldestOrigin() throws {
        let immediate = try post(ForwardProtocol.copy(to:93))
        var copy = ForwardProtocol.copy(to:94)
        XCTAssertFalse(ChatForwardPolicy.receipt(try post(copy),source:immediate,channelID:94,userID:10,previous:[]))
        copy["props"] = ["forward":["origin_channel_id":93,"origin_post_id":immediate.id,"origin_user_id":10,"origin_thread_id":0]]
        XCTAssertTrue(ChatForwardPolicy.receipt(try post(copy),source:immediate,channelID:94,userID:10,previous:[]))
        var changed = ForwardProtocol.source;changed["update_at"] = 2000
        XCTAssertFalse(ChatForwardPolicy.sameContent(try post(),try post(changed)))
    }
    func testForwardSourceIdentityAndUnavailableScopeCannotPassContentReview() throws {
        let original = try post()
        for key in ["post_id","channel_id","creator_id","thread_id"] {
            var changed = ForwardProtocol.source;changed[key] = 999
            XCTAssertFalse(ChatForwardPolicy.sameContent(original,try post(changed)))
        }
        for mutation:[String:Any] in [["is_closed":true],["is_joined":false],["hide_global_at":1000],["encrypted":true]] {
            var value:[String:Any] = ["channel_id":93,"name":"Synthetic","type":"public","encrypted":false,"unread":0]
            value.merge(mutation,uniquingKeysWith:{ _,new in new })
            let channel = try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:value))
            XCTAssertFalse(ChatForwardPolicy.destination(channel))
            let human = try JSONDecoder().decode(ChatUser.self,from:Data(#"{"user_id":10,"nickname":"Self","type":"human","human_type":"dsm"}"#.utf8))
            XCTAssertFalse(ChatForwardPolicy.supports(original,channel:channel,users:[human]))
        }
    }
    func testForwardDestinationCatalogueIncludesNewPeopleWithoutStartingOrSending() async throws {
        let model = try await model(),snapshot = try await model.loadQuickSwitcher()
        XCTAssertNotNil(snapshot.entries.first { $0.person?.user_id == 30 && $0.channel == nil })
        XCTAssertEqual(ForwardProtocol.starts.count,0);XCTAssertEqual(ForwardProtocol.forwardCalls,0)
        XCTAssertFalse(snapshot.entries.contains { $0.person?.user_id == 20 })
    }
    func testNewPersonAndExistingChannelForwardTogetherWithoutNavigationOrDraftLoss() async throws {
        let model = try await model(),source = try post(),snapshot = try await model.loadQuickSwitcher()
        let person = try XCTUnwrap(snapshot.entries.first { $0.person?.user_id == 30 }),existing = try XCTUnwrap(snapshot.entries.first { $0.channel?.id == 94 })
        model.draft = "Keep the original unsent text 👋"
        let result = try await model.forwardMessage(source,to:[person.id,existing.id],reviewed:snapshot)
        XCTAssertEqual(Set(result.map(\.channel_id)),[94,96]);XCTAssertEqual(ForwardProtocol.forwardCalls,1)
        XCTAssertEqual(ForwardProtocol.starts.count,1);XCTAssertEqual(ForwardProtocol.starts.first?["user_ids"],"[10,30]")
        XCTAssertEqual(model.selection,93);XCTAssertEqual(model.draft,"Keep the original unsent text 👋")
        XCTAssertTrue(model.channels.contains { $0.id == 96 });XCTAssertTrue(model.pendingConversationStarts.isEmpty)
    }
    func testAllReviewedDestinationsAreValidatedBeforeAnyNewConversationStarts() async throws {
        let model = try await model(),snapshot = try await model.loadQuickSwitcher()
        let person = try XCTUnwrap(snapshot.entries.first { $0.person?.user_id == 30 }),existing = try XCTUnwrap(snapshot.entries.first { $0.channel?.id == 94 })
        ForwardProtocol.destinationUnavailable = true
        do { _ = try await model.forwardMessage(try post(),to:[person.id,existing.id],reviewed:snapshot);XCTFail("Unavailable target forwarded") } catch { }
        XCTAssertTrue(ForwardProtocol.starts.isEmpty);XCTAssertEqual(ForwardProtocol.forwardCalls,0)
    }
    func testNewRecipientIdentityPermissionAndSourceChangesBlockBeforeStart() async throws {
        for change in 0..<3 {
            ForwardProtocol.reset()
            let model = try await model(),source = try post(),snapshot = try await model.loadQuickSwitcher()
            let person = try XCTUnwrap(snapshot.entries.first { $0.person?.user_id == 30 })
            if change == 0 { ForwardProtocol.peerRenamed = true }
            if change == 1 { ForwardProtocol.allowStart = false }
            if change == 2 { ForwardProtocol.source["message"] = "Edited after review" }
            do { _ = try await model.forwardMessage(source,to:[person.id],reviewed:snapshot);XCTFail("Changed review forwarded") } catch { }
            XCTAssertTrue(ForwardProtocol.starts.isEmpty);XCTAssertEqual(ForwardProtocol.forwardCalls,0)
            model.signOutLocally()
        }
    }
    func testLostStartResponseNeverForwardsOrRepeatsStartAndRefreshFindsCreatedDestination() async throws {
        let model = try await model(),snapshot = try await model.loadQuickSwitcher()
        let person = try XCTUnwrap(snapshot.entries.first { $0.person?.user_id == 30 })
        ForwardProtocol.loseStart = true
        do { _ = try await model.forwardMessage(try post(),to:[person.id],reviewed:snapshot);XCTFail("Lost start forwarded") }
        catch let error as NativeForwardFailure { XCTAssertFalse(error.uncertain);XCTAssertTrue(error.message.contains("No message was forwarded")) }
        XCTAssertEqual(ForwardProtocol.starts.count,1);XCTAssertEqual(ForwardProtocol.forwardCalls,0)
        XCTAssertEqual(model.pendingConversationStarts.count,1)
        let refreshed = try await model.loadQuickSwitcher(),entry = try XCTUnwrap(refreshed.entries.first { $0.channel?.id == 96 })
        XCTAssertTrue(model.pendingConversationStarts.isEmpty)
        _ = try await model.forwardMessage(try post(),to:[entry.id],reviewed:refreshed)
        XCTAssertEqual(ForwardProtocol.starts.count,1);XCTAssertEqual(ForwardProtocol.forwardCalls,1)
    }
    func testNewPersonAlreadyCreatedElsewhereUsesExistingConversationWithoutStartPermission() async throws {
        let model = try await model(),snapshot = try await model.loadQuickSwitcher()
        let person = try XCTUnwrap(snapshot.entries.first { $0.person?.user_id == 30 })
        ForwardProtocol.created = true;ForwardProtocol.allowStart = false
        let result = try await model.forwardMessage(try post(),to:[person.id],reviewed:snapshot)
        XCTAssertEqual(result.first?.channel_id,96);XCTAssertTrue(ForwardProtocol.starts.isEmpty)
        XCTAssertEqual(ForwardProtocol.forwardCalls,1);XCTAssertEqual(model.selection,93)
    }
    func testRecipientMembershipChangeAfterCreationStopsBeforeForwardDispatch() async throws {
        let model = try await model(),snapshot = try await model.loadQuickSwitcher()
        let person = try XCTUnwrap(snapshot.entries.first { $0.person?.user_id == 30 })
        ForwardProtocol.changeMembersAt = 3
        do { _ = try await model.forwardMessage(try post(),to:[person.id],reviewed:snapshot);XCTFail("Changed membership forwarded") }
        catch let error as NativeForwardFailure { XCTAssertFalse(error.uncertain) }
        XCTAssertEqual(ForwardProtocol.starts.count,1);XCTAssertEqual(ForwardProtocol.forwardCalls,0)
        XCTAssertEqual(model.selection,93)
    }
    func testSignOutWhileNewRecipientStartHeldCannotForwardOrPublish() async throws {
        let model = try await model(),snapshot = try await model.loadQuickSwitcher()
        let person = try XCTUnwrap(snapshot.entries.first { $0.person?.user_id == 30 }),started = expectation(description:"Held new-recipient start")
        ForwardProtocol.holdStart = true
        ForwardProtocol.observer = { if $0["method"] == "initiate" { started.fulfill() } }
        let operation = Task { try await model.forwardMessage(try post(),to:[person.id],reviewed:snapshot) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        ForwardProtocol.held?.finish(["success":true,"data":ForwardProtocol.newChannel])
        do { _ = try await operation.value;XCTFail("Old account completed") } catch is CancellationError { }
        XCTAssertEqual(ForwardProtocol.forwardCalls,0);XCTAssertTrue(model.channels.isEmpty);XCTAssertFalse(model.channelManagementBusy)
    }
    private func recoveryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-forward-tests-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url
    }
    func testUnconfirmedForwardRestoresFromDiskBlocksResendAndReadOnlyStatusRetiresIt() async throws {
        let folder = try recoveryFolder(),first = try await model(journal:.init(directory:folder)),source = try post()
        ForwardProtocol.ignoreForward = true
        do { _ = try await first.forwardMessage(source,to:[94]);XCTFail() } catch let failure as NativeForwardFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(first.pendingForwards.count,1);first.signOutLocally()
        let restored = try await model(journal:.init(directory:folder)),intent = try XCTUnwrap(restored.pendingForwards.values.first)
        do { _ = try await restored.forwardMessage(source,to:[94]);XCTFail("Restored forward repeated") } catch let failure as NativeForwardFailure { XCTAssertTrue(failure.uncertain) }
        do { _ = try await restored.checkForwardStatus(intent,expectedGeneration:restored.accountGeneration);XCTFail("Missing copy accepted") } catch { }
        XCTAssertEqual(ForwardProtocol.forwardCalls,1);XCTAssertEqual(restored.pendingForwards.count,1)
        // External synthetic backend delivery; the status check never dispatches.
        ForwardProtocol.delivered = [94]
        let copies = try await restored.checkForwardStatus(intent,expectedGeneration:restored.accountGeneration)
        XCTAssertEqual(copies.map(\.channel_id),[94]);XCTAssertTrue(restored.pendingForwards.isEmpty);XCTAssertEqual(ForwardProtocol.forwardCalls,1)
        restored.signOutLocally()
        let final = try await model(journal:.init(directory:folder));XCTAssertTrue(final.pendingForwards.isEmpty)
    }
    func testPartialForwardLocalAcknowledgementMakesNoRequestAndRequiresNewManualSend() async throws {
        let model = try await model();ForwardProtocol.missingDestination = 94
        do { _ = try await model.forwardMessage(try post(),to:[93,94]);XCTFail() } catch { }
        let intent = try XCTUnwrap(model.pendingForwards.values.first)
        do { _ = try await model.checkForwardStatus(intent,expectedGeneration:model.accountGeneration);XCTFail() } catch { }
        XCTAssertEqual(model.pendingForwards.count,1);XCTAssertEqual(ForwardProtocol.forwardCalls,1)
        var requests = 0;ForwardProtocol.observer = { _ in requests += 1 }
        try model.acknowledgeForwardOutcome(intent,expectedGeneration:model.accountGeneration)
        XCTAssertEqual(requests,0);XCTAssertTrue(model.pendingForwards.isEmpty);XCTAssertEqual(ForwardProtocol.forwardCalls,1)
        ForwardProtocol.missingDestination = nil
        _ = try await model.forwardMessage(try post(),to:[94]);XCTAssertEqual(ForwardProtocol.forwardCalls,2)
    }
    func testForwardRecoveryExcludesOldCopiesAndChangedSource() async throws {
        let model = try await model();ForwardProtocol.delivered = [94];ForwardProtocol.ignoreForward = true
        do { _ = try await model.forwardMessage(try post(),to:[94]);XCTFail() } catch { }
        let intent = try XCTUnwrap(model.pendingForwards.values.first)
        XCTAssertTrue(intent.previousIDs["94"]?.contains(194) == true)
        do { _ = try await model.checkForwardStatus(intent,expectedGeneration:model.accountGeneration);XCTFail("Old copy treated as new") } catch { }
        ForwardProtocol.source["message"] = "Edited source after forwarding"
        do { _ = try await model.checkForwardStatus(intent,expectedGeneration:model.accountGeneration);XCTFail("Edited source accepted") } catch { }
        XCTAssertEqual(model.pendingForwards.count,1);XCTAssertEqual(ForwardProtocol.forwardCalls,1)
    }
    func testOlderOrTiedCopyReappearingAfterBaselineHistoryRemovalCannotConfirmForward() async throws {
        for timestamp in [2000.0,5000.0] {
            ForwardProtocol.reset()
            let model = try await model()
            ForwardProtocol.baselinePosts = [94:[["post_id":500,"channel_id":94,"creator_id":30,"message":"Unrelated later history","type":"normal","create_at":timestamp]]]
            ForwardProtocol.ignoreForward = true
            do { _ = try await model.forwardMessage(try post(),to:[94]);XCTFail() } catch { }
            let intent = try XCTUnwrap(model.pendingForwards.values.first)
            XCTAssertFalse(intent.previousIDs["94"]?.contains(194) == true)
            ForwardProtocol.baselinePosts = [:];ForwardProtocol.delivered = [94]
            do { _ = try await model.checkForwardStatus(intent,expectedGeneration:model.accountGeneration);XCTFail("Old or tied copy cleared the warning") } catch { }
            XCTAssertEqual(model.pendingForwards.count,1);XCTAssertEqual(ForwardProtocol.forwardCalls,1)
            model.signOutLocally()
        }
    }
    func testCorruptRecoveryStorageBlocksForwardBeforeDispatch() async throws {
        let folder = try recoveryFolder(),first = try await model(journal:.init(directory:folder))
        _ = try await first.forwardMessage(try post(),to:[94]);first.signOutLocally()
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).first { $0.pathExtension == "json" })
        try Data("corrupt".utf8).write(to:file)
        let restored = try await model(journal:.init(directory:folder));XCTAssertNotNil(restored.forwardRecoveryError)
        do { _ = try await restored.forwardMessage(try post(),to:[94]);XCTFail("Unreadable journal allowed forwarding") } catch { }
        XCTAssertEqual(ForwardProtocol.forwardCalls,1)
    }
    func testConfirmedForwardSurvivesReceiptRetirementFailureWithoutReportingUnsent() async throws {
        let folder = try recoveryFolder(),model = try await model(journal:.init(directory:folder))
        ForwardProtocol.observer = { fields in
            if fields["method"] == "forward",let file = try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).first(where:{ $0.pathExtension == "json" }) {
                try? Data("corrupt after dispatch".utf8).write(to:file)
            }
        }
        let confirmed = try await model.forwardMessage(try post(),to:[94])
        XCTAssertEqual(confirmed.count,1);XCTAssertEqual(ForwardProtocol.forwardCalls,1)
        XCTAssertNotNil(model.forwardRecoveryError);XCTAssertEqual(model.pendingForwards.count,1)
    }
    func testRecoveryWriteFailureAfterPreflightStopsBeforeForwardRequest() async throws {
        let folder = try recoveryFolder(),journal = ChatForwardJournal(directory:folder),model = try await model(journal:journal)
        let scope = try XCTUnwrap(journal.accountScope),file = folder.appendingPathComponent(scope+".json")
        ForwardProtocol.observer = { fields in
            if fields["method"] == "list",fields["channel_id"] == "94",fields["post_id"] == nil { try? Data("corrupt before persist".utf8).write(to:file) }
        }
        do { _ = try await model.forwardMessage(try post(),to:[94]);XCTFail("Unsaved operation dispatched") }
        catch let failure as NativeForwardFailure { XCTAssertFalse(failure.uncertain) }
        XCTAssertEqual(ForwardProtocol.forwardCalls,0);XCTAssertTrue(model.pendingForwards.isEmpty);XCTAssertNotNil(model.forwardRecoveryError)
    }
    func testForwardRecoveryRecordContainsNoMessageAndStaleGenerationCannotClearOrRead() async throws {
        let folder = try recoveryFolder(),model = try await model(journal:.init(directory:folder));ForwardProtocol.ignoreForward = true
        do { _ = try await model.forwardMessage(try post(),to:[94]);XCTFail() } catch { }
        let intent = try XCTUnwrap(model.pendingForwards.values.first),epoch = model.accountGeneration
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).first { $0.pathExtension == "json" })
        let raw = try String(contentsOf:file,encoding:.utf8)
        XCTAssertFalse(raw.contains("Synthetic forward source"));XCTAssertFalse(raw.contains("synoToken"));XCTAssertFalse(raw.contains("sid"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? Int,0o600)
        model.signOutLocally();var requests = 0;ForwardProtocol.observer = { _ in requests += 1 }
        do { try model.acknowledgeForwardOutcome(intent,expectedGeneration:epoch);XCTFail() } catch is CancellationError { }
        do { _ = try await model.checkForwardStatus(intent,expectedGeneration:epoch);XCTFail() } catch is CancellationError { }
        XCTAssertEqual(requests,0)
        let restored = try await self.model(journal:.init(directory:folder));XCTAssertEqual(restored.pendingForwards[intent.id],intent)
    }
}

private final class ForwardProtocol:URLProtocol {
    static var source:[String:Any] = [:]
    static var delivered:[Int64] = []
    static var forwardCalls = 0
    static var ignoreForward = false
    static var missingDestination:Int64?
    static var hold = false
    static var held:ForwardProtocol?
    static var starts:[[String:String]] = []
    static var baselinePosts:[Int64:[[String:Any]]] = [:]
    static var created = false,allowStart = true,peerRenamed = false,destinationUnavailable = false,loseStart = false,holdStart = false
    static var memberReads = 0,changeMembersAt:Int?
    static var newChannel:[String:Any] { ["channel_id":96,"name":"","type":"anonymous","encrypted":false,"unread":0] }
    static var observer:(([String:String])->Void)?
    static func reset() { source = ["post_id":1,"channel_id":93,"creator_id":10,"type":"normal","message":"Synthetic forward source 👋","create_at":1000];delivered = [];forwardCalls = 0;ignoreForward = false;missingDestination = nil;hold = false;held = nil;observer = nil;starts = [];baselinePosts = [:];created = false;allowStart = true;peerRenamed = false;destinationUnavailable = false;loseStart = false;holdStart = false;memberReads = 0;changeMembersAt = nil }
    static func copy(to id:Int64)->[String:Any] {
        var value = source;value["post_id"] = 100+id;value["channel_id"] = id;value["create_at"] = 2000
        value["props"] = ["forward":["origin_channel_id":93,"origin_post_id":1,"origin_user_id":10,"origin_thread_id":0,"origin_create_at":1000,"type":"normal"]];return value
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "forward-fixture.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var b = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&b,maxLength:b.count);if n <= 0 { break };bytes.append(contentsOf:b.prefix(n)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let api = request.url!.lastPathComponent,method = fields["method"] ?? ""
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Post","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Channel.Anonymous","SYNO.Chat.Misc","SYNO.Chat.Admin.Setting"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        if api == "SYNO.Chat.Channel.Anonymous",method == "initiate" {
            Self.starts.append(fields);Self.created = true
            if Self.holdStart { Self.held = self;Self.observer?(fields);return }
            if Self.loseStart { Self.loseStart = false;client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return }
            finish(["success":true,"data":Self.newChannel]);return
        }
        if api == "SYNO.Chat.Post",method == "forward" {
            Self.forwardCalls += 1
            if !Self.ignoreForward { Self.delivered = ((try? JSONDecoder().decode([Int64].self,from:Data((fields["channel_ids"] ?? "[]").utf8))) ?? []).filter { $0 != Self.missingDestination } }
            if Self.hold { Self.held = self;Self.observer?(fields);return }
        }
        Self.observer?(fields)
        switch (api,method) {
        case ("SYNO.Chat.Post","forward"):finish(["success":true])
        case ("SYNO.Chat.User","list"):finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Peter","type":"human","human_type":"dsm"],["user_id":20,"nickname":"Bot","type":"bot"],["user_id":30,"username":"synthetic-peer","nickname":Self.peerRenamed ? "Changed peer" : "Synthetic peer","type":"human","human_type":"dsm"]]]])
        case ("SYNO.Chat.Channel","list"):
            let channels = [93,94].map { ["channel_id":$0,"name":"Synthetic \($0)","type":"public","encrypted":false,"unread":0,"is_joined":$0 != 94 || !Self.destinationUnavailable] as [String:Any] } + (Self.created ? [Self.newChannel] : [])
            finish(["success":true,"data":["channels":channels]])
        case ("SYNO.Chat.Channel.Member","get"):
            Self.memberReads += 1
            finish(["success":true,"data":["user_ids":Self.memberReads == Self.changeMembersAt ? [10,30,40] : [10,30]]])
        case ("SYNO.Chat.Misc",_):finish(["success":true,"data":["acls":[["acl_name":"channel_anonymous","allow":Self.allowStart]]]])
        case ("SYNO.Chat.Admin.Setting",_):finish(["success":true,"data":["hide_post_url_preview":true,"file_size_limit":0]])
        case ("SYNO.Chat.Post","list"):
            let id = Int64(fields["channel_id"] ?? "93") ?? 93
            let posts = fields["post_id"] == "1" ? [Self.source] : (id == 93 ? [Self.source] : []) + (Self.baselinePosts[id] ?? []) + (Self.delivered.contains(id) ? [Self.copy(to:id)] : [])
            finish(["success":true,"data":["posts":posts]])
        default:finish(["success":false,"error":["code":400]])
        }
    }
    func finish(_ object:[String:Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject:object)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
