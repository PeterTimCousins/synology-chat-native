import XCTest
import AppKit
import Combine
import SwiftUI
@testable import SynologyChatNative

@MainActor final class ChatScheduleTests:XCTestCase {
    private func client() async throws -> ChatAPIClient {
        let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ScheduleProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://schedule-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:c))
        try await api.discover();return api
    }
    private func draft(_ text:String = "Synthetic scheduled message 👋") -> ChatScheduleDraft { .init(message:text,date:Date(timeIntervalSinceNow:3600)) }
    private func job(_ id:Int64 = 28,message:String = "Synthetic scheduled message 👋") throws -> ChatScheduledMessage {
        try JSONDecoder().decode(ChatScheduledMessage.self,from:JSONSerialization.data(withJSONObject:["cronjob_id":id,"message":message,"send_at":Double(Int64(Date().timeIntervalSince1970*1000))+3600000]))
    }
    private func model(journal:ChatScheduledCreationJournal? = nil,host:String = "schedule-fixture.invalid") async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ScheduleProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:c))
        },scheduleCreationJournal:journal)
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://\(host)")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 93
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func setUp() { super.setUp();ScheduleProtocol.reset() }
    override func tearDown() { ScheduleProtocol.observer = nil;ScheduleProtocol.held = nil;super.tearDown() }
    func testScheduleWireIsChannelScopedAndUsesMillisecondTimes() async throws {
        let api = try await client(),draft = try draft("  Synthetic scheduled message 👋  ").validated()
        var methods:[String] = []
        ScheduleProtocol.observer = { fields in
            guard fields["api"] == "SYNO.Chat.Post.Schedule" else { return };let method = fields["method"]!;methods.append(method);XCTAssertEqual(fields["version"],"1")
            if ["list","create"].contains(method) { XCTAssertEqual(fields["channel_id"],"93") }
            else { XCTAssertEqual(fields["cronjob_id"],"28");XCTAssertNil(fields["channel_id"]) }
            if ["create","set"].contains(method) { XCTAssertEqual(fields["send_at"],String(Int64(draft.milliseconds)));XCTAssertEqual(fields["message"],#""Synthetic scheduled message 👋""#) }
            XCTAssertNil(fields["thread_id"]);XCTAssertNil(fields["conn_id"])
        }
        let id = try await api.createScheduledMessage(channelID:93,draft:draft);XCTAssertEqual(id,28)
        _ = try await api.scheduledMessages(channelID:93);try await api.setScheduledMessage(id:id,draft:draft);try await api.cancelScheduledMessage(id:id)
        XCTAssertEqual(methods,["create","list","set","delete"])
        do { try await api.cancelScheduledMessage(id:0);XCTFail("Invalid ID sent") } catch ChatAPIError.invalidResponse { }
    }
    func testDraftValidationPreservesInternalWhitespaceAndRejectsPastAndUTF16Overflow() throws {
        let now = Date(timeIntervalSince1970:1000)
        let value = try ChatScheduleDraft(message:"  a\n  b  ",date:Date(timeIntervalSince1970:2000.125)).validated(now:now)
        XCTAssertEqual(value.message,"a\n  b");XCTAssertEqual(value.milliseconds,2000125)
        for text in [" \n ",String(repeating:"😀",count:1001)] { XCTAssertThrowsError(try ChatScheduleDraft(message:text,date:Date(timeIntervalSince1970:2000)).validated(now:now)) }
        XCTAssertNoThrow(try ChatScheduleDraft(message:String(repeating:"😀",count:1000),date:Date(timeIntervalSince1970:2000)).validated(now:now))
        for seconds in [999.0,1000.0,Double.infinity,Double.nan] { XCTAssertThrowsError(try ChatScheduleDraft(message:"x",date:Date(timeIntervalSince1970:seconds)).validated(now:now)) }
    }
    func testPendingListSortsAndRejectsDuplicateOrMalformedJobIdentities() async throws {
        let api = try await client();let first = try job(3),second = ChatScheduledMessage(cronjob_id:2,message:first.message,send_at:first.send_at)
        ScheduleProtocol.jobs = [first,second]
        let values = try await api.scheduledMessages(channelID:93)
        XCTAssertEqual(values.map(\.id),[2,3])
        ScheduleProtocol.jobs = [first,first]
        do { _ = try await api.scheduledMessages(channelID:93);XCTFail("Duplicate jobs accepted") } catch ChatAPIError.invalidResponse { }
        for object:[String:Any] in [["cronjob_id":0,"message":"x","send_at":1],["cronjob_id":2,"message":"","send_at":1],["cronjob_id":2,"message":"x","send_at":-1]] {
            let value = try JSONDecoder().decode(ChatScheduledMessage.self,from:JSONSerialization.data(withJSONObject:object));XCTAssertThrowsError(try value.validate())
        }
    }
    func testCanonicalCreateEditAndCancelRoundTripClearsOnlyScheduledDraft() async throws {
        let model = try await model(),original = draft();model.scheduleDrafts[93] = original;model.drafts[93] = "Ordinary draft"
        let created = try await model.saveScheduledMessage(channelID:93,draft:original)
        XCTAssertNil(model.scheduleDrafts[93]);XCTAssertEqual(model.drafts[93],"Ordinary draft")
        let edited = try await model.saveScheduledMessage(channelID:93,draft:draft("Edited synthetic schedule"),editing:created)
        XCTAssertEqual(edited.id,created.id);XCTAssertEqual(edited.message,"Edited synthetic schedule")
        try await model.cancelScheduledMessage(edited,channelID:93)
        let pending = try await model.scheduledMessages(channelID:93);XCTAssertTrue(pending.isEmpty);XCTAssertFalse(model.scheduleBusy)
        XCTAssertEqual(ScheduleProtocol.writes,["create","set","delete"])
    }
    func testSuccessWithoutCanonicalCreationOrEditIsUncertainAndDraftIsRetained() async throws {
        let model = try await model(),value = draft();model.scheduleDrafts[93] = value;ScheduleProtocol.ignoreWrite = true
        do { _ = try await model.saveScheduledMessage(channelID:93,draft:value);XCTFail("No-op create accepted") } catch let failure as ChatScheduleFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(model.scheduleDrafts[93],value);XCTAssertEqual(ScheduleProtocol.writes,["create"])
        let existing = try job();ScheduleProtocol.jobs = [existing]
        do { _ = try await model.saveScheduledMessage(channelID:93,draft:draft("Changed"),editing:existing);XCTFail("No-op edit accepted") } catch let failure as ChatScheduleFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(ScheduleProtocol.writes,["create","set"])
    }
    func testStaleOrNoLongerPendingJobsAreNotEditedOrCancelled() async throws {
        let model = try await model(),existing = try job();ScheduleProtocol.jobs = [try job(message:"Changed elsewhere")]
        do { _ = try await model.saveScheduledMessage(channelID:93,draft:draft("Stale change"),editing:existing);XCTFail("Stale edit sent") } catch let failure as ChatScheduleFailure { XCTAssertFalse(failure.uncertain) }
        do { try await model.cancelScheduledMessage(existing,channelID:93);XCTFail("Stale cancellation sent") } catch let failure as ChatScheduleFailure { XCTAssertFalse(failure.uncertain) }
        ScheduleProtocol.jobs = []
        do { try await model.cancelScheduledMessage(existing,channelID:93);XCTFail("Delivered job cancelled") } catch let failure as ChatScheduleFailure { XCTAssertFalse(failure.uncertain) }
        XCTAssertTrue(ScheduleProtocol.writes.isEmpty)
    }
    func testIgnoredCancellationDoesNotClaimMessageWillNotSend() async throws {
        let model = try await model(),existing = try job();ScheduleProtocol.jobs = [existing];ScheduleProtocol.ignoreWrite = true
        do { try await model.cancelScheduledMessage(existing,channelID:93);XCTFail("No-op cancellation accepted") } catch let failure as ChatScheduleFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(ScheduleProtocol.writes,["delete"]);XCTAssertFalse(model.scheduleBusy)
    }
    func testSignOutAfterCreateDispatchRejectsOldAccountReadback() async throws {
        let model = try await model(),started = expectation(description:"Create held");ScheduleProtocol.holdCreate = true
        ScheduleProtocol.observer = { if $0["method"] == "create" { started.fulfill() } }
        let task = Task { try await model.saveScheduledMessage(channelID:93,draft:draft()) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();ScheduleProtocol.held?.finish(["success":true,"data":["cronjob_id":28]])
        do { _ = try await task.value;XCTFail("Old account result accepted") } catch is CancellationError { }
        XCTAssertFalse(model.scheduleBusy);XCTAssertTrue(model.scheduleDrafts.isEmpty)
    }
    func testSelectionChangeDuringPreflightPreventsDispatch() async throws {
        let model = try await model(),started = expectation(description:"List held");ScheduleProtocol.holdList = true
        ScheduleProtocol.observer = { if $0["api"] == "SYNO.Chat.Post.Schedule",$0["method"] == "list" { started.fulfill() } }
        let task = Task { try await model.saveScheduledMessage(channelID:93,draft:draft()) }
        await fulfillment(of:[started],timeout:2);model.selection = 94;ScheduleProtocol.held?.finish(["success":true,"data":["schedule_posts":[]]])
        do { _ = try await task.value;XCTFail("Wrong context dispatch") } catch is CancellationError { }
        XCTAssertTrue(ScheduleProtocol.writes.isEmpty);XCTAssertFalse(model.scheduleBusy)
    }
    func testEncryptedAndUnknownChannelsAreBlockedAndSignOutClearsDrafts() async throws {
        let model = try await model();model.scheduleDrafts[93] = draft();model.selection = 95
        XCTAssertFalse(model.canManageSchedules(channelID:95));XCTAssertFalse(model.canCreateSchedule)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":95,"name":"Encrypted","type":"private","encrypted":true,"unread":0}"#.utf8))]
        XCTAssertFalse(model.canManageSchedules(channelID:95))
        do { _ = try await model.saveScheduledMessage(channelID:95,draft:draft());XCTFail("Encrypted scheduling sent") } catch { }
        XCTAssertTrue(ScheduleProtocol.writes.isEmpty);model.signOutLocally();XCTAssertTrue(model.scheduleDrafts.isEmpty)
    }
    func testConfirmedScheduleClearsItsSourceComposerButPreservesSubsequentTyping() async throws {
        let model = try await model()
        var value = draft();value.sourceComposerText = "Original ordinary draft";model.drafts[93] = value.sourceComposerText
        _ = try await model.saveScheduledMessage(channelID:93,draft:value)
        XCTAssertNil(model.drafts[93])
        model.drafts[93] = "New typing while scheduling"
        _ = try await model.saveScheduledMessage(channelID:93,draft:value)
        XCTAssertEqual(model.drafts[93],"New typing while scheduling")
    }
    private func recoveryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-recovery-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) };return directory
    }
    func testLostCreateReplyBlocksReopenReconnectAndRecreatedModelUntilExplicitReviewedClear() async throws {
        let directory = try recoveryDirectory(),journal = ChatScheduledCreationJournal(directory:directory)
        let model = try await model(journal:journal),value = draft()
        ScheduleProtocol.loseCreateReply = true;model.scheduleDrafts[93] = value
        do { _ = try await model.saveScheduledMessage(channelID:93,draft:value);XCTFail("Lost reply accepted") } catch let e as ChatScheduleFailure { XCTAssertTrue(e.uncertain) }
        XCTAssertEqual(ScheduleProtocol.jobs.count,1);XCTAssertEqual(ScheduleProtocol.writes,["create"])
        let receipt = try XCTUnwrap(model.pendingScheduledCreations[93]);XCTAssertNil(receipt.acknowledgedID)
        model.scheduleDrafts[93] = value // Represents sheet reopen; UI-local uncertainty is gone.
        do { _ = try await model.saveScheduledMessage(channelID:93,draft:draft("Different reopened draft"));XCTFail("Duplicate create allowed") } catch { }
        let review = try await model.reviewScheduledCreation(channelID:93)
        XCTAssertEqual(review.matchingJobs.map(\.id),[28]);XCTAssertEqual(model.pendingScheduledCreations[93],receipt,"Reading or cancelling review must retain protection")
        model.signOutLocally()
        let restored = try await self.model(journal:ChatScheduledCreationJournal(directory:directory))
        XCTAssertEqual(restored.pendingScheduledCreations[93],receipt);XCTAssertFalse(restored.canCreateSchedule)
        do { _ = try await restored.saveScheduledMessage(channelID:93,draft:value);XCTFail("New model resent") } catch { }
        await restored.connect();restored.suspendLiveForProbe();restored.liveStatus = .live;restored.selection = 93
        XCTAssertEqual(restored.pendingScheduledCreations[93],receipt,"Reconnect must restore unresolved protection")
        let newReview = try await restored.reviewScheduledCreation(channelID:93)
        try await restored.clearReviewedScheduledCreation(newReview)
        XCTAssertNil(restored.pendingScheduledCreations[93]);XCTAssertTrue(restored.canCreateSchedule)
        XCTAssertEqual(ScheduleProtocol.writes,["create"],"Review/clear must perform no server write")
        await restored.connect();restored.suspendLiveForProbe();restored.liveStatus = .live;restored.selection = 93
        XCTAssertNil(restored.pendingScheduledCreations[93])
    }
    func testRecoveryExcludesExistingMatchingJobsAndAbsenceNeverUnlocks() async throws {
        let journal = ChatScheduledCreationJournal(directory:try recoveryDirectory()),model = try await model(journal:journal)
        let value = try draft().validated()
        ScheduleProtocol.jobs = [.init(cronjob_id:7,message:value.message,send_at:value.milliseconds),.init(cronjob_id:9,message:"Unrelated private job",send_at:value.milliseconds)]
        ScheduleProtocol.loseCreateReply = true
        do { _ = try await model.saveScheduledMessage(channelID:93,draft:value) } catch { }
        let receipt = try XCTUnwrap(model.pendingScheduledCreations[93]);XCTAssertEqual(receipt.beforeMatchingJobIDs,[7])
        let review = try await model.reviewScheduledCreation(channelID:93);XCTAssertEqual(review.matchingJobs.map(\.id),[28])
        model.scheduleDrafts[93] = .init(message:value.message,date:Date(timeIntervalSince1970:1))
        ScheduleProtocol.jobs = [] // Delivery/removal is indistinguishable from an unsuccessful request.
        let absent = try await model.reviewScheduledCreation(channelID:93);XCTAssertTrue(absent.matchingJobs.isEmpty)
        XCTAssertEqual(model.pendingScheduledCreations[93],receipt);XCTAssertFalse(model.canCreateSchedule)
        do { try await model.clearReviewedScheduledCreation(review);XCTFail("Stale review cleared") } catch { }
        XCTAssertEqual(model.pendingScheduledCreations[93],receipt)
        try await model.clearReviewedScheduledCreation(absent)
        XCTAssertNil(model.pendingScheduledCreations[93]);XCTAssertEqual(ScheduleProtocol.writes,["create"])
    }
    func testLateAcknowledgementAfterAccountSwitchCheckpointsOriginalScopeOnly() async throws {
        let directory = try recoveryDirectory(),journal = ChatScheduledCreationJournal(directory:directory),model = try await model(journal:journal)
        let scope = try XCTUnwrap(journal.accountScope),started = expectation(description:"Create dispatched")
        ScheduleProtocol.holdCreate = true;ScheduleProtocol.observer = { if $0["method"] == "create" { started.fulfill() } }
        let task = Task { try await model.saveScheduledMessage(channelID:93,draft:draft()) }
        await fulfillment(of:[started],timeout:2);ScheduleProtocol.observer = nil
        let held = ScheduleProtocol.held;model.signOutLocally()
        let other = try await self.model(journal:ChatScheduledCreationJournal(directory:directory),host:"other-schedule-fixture.invalid")
        XCTAssertTrue(other.pendingScheduledCreations.isEmpty)
        held?.finish(["success":true,"data":["cronjob_id":28]])
        do { _ = try await task.value;XCTFail("Late result accepted in replacement account") } catch is CancellationError { }
        let old = try ChatScheduledCreationJournal(directory:directory).activate(scope:scope)
        XCTAssertEqual(old.count,1);XCTAssertEqual(old.first?.acknowledgedID,28)
        XCTAssertTrue(other.pendingScheduledCreations.isEmpty);XCTAssertEqual(ScheduleProtocol.writes,["create"])
    }
    func testDispatchedCancellationRetainsDurableReceipt() async throws {
        let directory = try recoveryDirectory(),journal = ChatScheduledCreationJournal(directory:directory),model = try await model(journal:journal)
        let started = expectation(description:"Create held"),scope = try XCTUnwrap(journal.accountScope)
        ScheduleProtocol.holdCreate = true;ScheduleProtocol.observer = { if $0["method"] == "create" { started.fulfill() } }
        let task = Task { try await model.saveScheduledMessage(channelID:93,draft:draft()) }
        await fulfillment(of:[started],timeout:2);ScheduleProtocol.observer = nil;task.cancel()
        ScheduleProtocol.held?.finish(["success":true,"data":["cronjob_id":28]])
        do { _ = try await task.value;XCTFail("Cancellation reported success") } catch { }
        XCTAssertFalse(model.canCreateSchedule)
        XCTAssertEqual(try ChatScheduledCreationJournal(directory:directory).activate(scope:scope).count,1)
        XCTAssertEqual(ScheduleProtocol.writes,["create"])
    }
    func testCorruptAndUnavailableJournalFailClosedBeforeCreate() async throws {
        for corrupt in [true,false] {
            let directory = try recoveryDirectory(),journal = ChatScheduledCreationJournal(directory:directory),model = try await model(journal:journal)
            let scope = try XCTUnwrap(journal.accountScope),file = directory.appendingPathComponent(scope+".json")
            if corrupt { try Data("invalid synthetic recovery".utf8).write(to:file) }
            else { try FileManager.default.removeItem(at:directory);try Data("not a directory".utf8).write(to:directory) }
            do { _ = try await model.saveScheduledMessage(channelID:93,draft:draft());XCTFail("Unsafe create dispatched") } catch { }
            XCTAssertNotNil(model.scheduleCreationRecoveryError);XCTAssertFalse(model.canCreateSchedule)
            XCTAssertTrue(ScheduleProtocol.writes.isEmpty)
        }
    }
    func testKnownCanonicalSuccessSurvivesCleanupFailureAndKeepsNewerDraft() async throws {
        let directory = try recoveryDirectory(),journal = ChatScheduledCreationJournal(directory:directory),model = try await model(journal:journal)
        let scope = try XCTUnwrap(journal.accountScope),file = directory.appendingPathComponent(scope+".json"),value = draft()
        model.scheduleDrafts[93] = value
        var listCount = 0
        ScheduleProtocol.observer = { fields in
            if fields["api"] == "SYNO.Chat.Post.Schedule",fields["method"] == "list" {
                listCount += 1
                if listCount == 2 {
                    model.scheduleDrafts[93] = self.draft("Newer schedule draft")
                    try? FileManager.default.removeItem(at:file);try? FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
                }
            }
        }
        let confirmed = try await model.saveScheduledMessage(channelID:93,draft:value)
        XCTAssertEqual(confirmed.id,28);XCTAssertNotNil(model.scheduleCreationRecoveryError)
        XCTAssertNotNil(model.pendingScheduledCreations[93]);XCTAssertEqual(model.scheduleDrafts[93]?.message,"Newer schedule draft")
        XCTAssertFalse(model.canCreateSchedule);XCTAssertEqual(ScheduleProtocol.writes,["create"])
    }
    func testCrossInstanceLeasePreventsConcurrentCreateAndClearWhileRequestRuns() async throws {
        let directory = try recoveryDirectory(),first = try await model(journal:ChatScheduledCreationJournal(directory:directory)),second = try await model(journal:ChatScheduledCreationJournal(directory:directory))
        let started = expectation(description:"First create held");ScheduleProtocol.holdCreate = true
        ScheduleProtocol.observer = { if $0["method"] == "create" { started.fulfill() } }
        let task = Task { try await first.saveScheduledMessage(channelID:93,draft:draft()) }
        await fulfillment(of:[started],timeout:2);ScheduleProtocol.observer = nil
        do { _ = try await second.saveScheduledMessage(channelID:93,draft:draft("Another schedule"));XCTFail("Concurrent create") } catch { }
        do { _ = try await second.reviewScheduledCreation(channelID:93);XCTFail("Read review crossed live operation") } catch { }
        ScheduleProtocol.held?.finish(["success":true,"data":["cronjob_id":28]])
        _ = try await task.value
        XCTAssertEqual(ScheduleProtocol.writes,["create"])
        let pending = try await second.scheduledMessages(channelID:93);XCTAssertEqual(pending.count,1)
        XCTAssertNil(second.pendingScheduledCreations[93]);XCTAssertTrue(second.canCreateSchedule)
    }
    func testPreflightContextChangeLeavesNoPersistentCreationReceipt() async throws {
        let journal = ChatScheduledCreationJournal(directory:try recoveryDirectory()),model = try await model(journal:journal),scope = try XCTUnwrap(journal.accountScope)
        let started = expectation(description:"Preflight held");ScheduleProtocol.holdList = true
        ScheduleProtocol.observer = { if $0["api"] == "SYNO.Chat.Post.Schedule",$0["method"] == "list" { started.fulfill() } }
        let task = Task { try await model.saveScheduledMessage(channelID:93,draft:draft()) }
        await fulfillment(of:[started],timeout:2);ScheduleProtocol.observer = nil;model.selection = 94
        ScheduleProtocol.held?.finish(["success":true,"data":["schedule_posts":[]]])
        do { _ = try await task.value;XCTFail("Selection-change create") } catch is CancellationError { }
        XCTAssertTrue(try journal.activate(scope:scope).isEmpty);XCTAssertTrue(ScheduleProtocol.writes.isEmpty)
    }
    func testCancellationAfterReceiptPublicationBeforeDispatchRemovesOnlyUnsentProtection() async throws {
        let journal = ChatScheduledCreationJournal(directory:try recoveryDirectory()),model = try await model(journal:journal),scope = try XCTUnwrap(journal.accountScope)
        var operation:Task<ChatScheduledMessage,Error>?
        let observation = model.$pendingScheduledCreations.sink { records in
            if records[93] != nil { operation?.cancel() }
        }
        defer { observation.cancel() }
        let task = Task { try await model.saveScheduledMessage(channelID:93,draft:draft()) };operation = task
        do { _ = try await task.value;XCTFail("Cancelled undispatched creation succeeded") } catch is CancellationError { }
        XCTAssertTrue(ScheduleProtocol.writes.isEmpty)
        XCTAssertNil(model.pendingScheduledCreations[93]);XCTAssertTrue(try journal.activate(scope:scope).isEmpty)
        XCTAssertFalse(model.scheduleBusy);XCTAssertTrue(model.canCreateSchedule)
    }
    func testOldReviewedOperationCannotClearAReplacementAttempt() async throws {
        let model = try await model(journal:ChatScheduledCreationJournal(directory:try recoveryDirectory()))
        ScheduleProtocol.loseCreateReply = true
        do { _ = try await model.saveScheduledMessage(channelID:93,draft:draft()) } catch { }
        let oldReview = try await model.reviewScheduledCreation(channelID:93)
        try await model.clearReviewedScheduledCreation(oldReview)
        do { _ = try await model.saveScheduledMessage(channelID:93,draft:draft("Replacement synthetic attempt")) } catch { }
        let replacement = try XCTUnwrap(model.pendingScheduledCreations[93]);XCTAssertNotEqual(replacement.operationID,oldReview.record.operationID)
        do { try await model.clearReviewedScheduledCreation(oldReview);XCTFail("Old operation review cleared replacement") } catch { }
        XCTAssertEqual(model.pendingScheduledCreations[93],replacement);XCTAssertEqual(ScheduleProtocol.writes,["create","create"])
    }
    func testHiddenRecoverySurfacesRetainProtectionAndDraftWithoutServerWrites() async throws {
        let model = try await model(journal:ChatScheduledCreationJournal(directory:try recoveryDirectory())),value = draft()
        model.scheduleDrafts[93] = value;model.drafts[93] = "Synthetic ordinary draft retained"
        ScheduleProtocol.loseCreateReply = true
        do { _ = try await model.saveScheduledMessage(channelID:93,draft:value) } catch { }
        let receipt = try XCTUnwrap(model.pendingScheduledCreations[93]),review = try await model.reviewScheduledCreation(channelID:93)
        XCTAssertEqual(review.matchingJobs.count,1)
        let surfaces:[(String,AnyView,NSSize)] = [
            ("composer",AnyView(NativeScheduleComposer(model:model,channelID:93)),NSSize(width:700,height:570)),
            ("pending-list",AnyView(NativeScheduledMessagesView(model:model,channelID:93)),NSSize(width:720,height:600)),
            ("review",AnyView(NativeScheduledCreationRecoveryView.fixture(model:model,channelID:93,review:review)),NSSize(width:680,height:540))]
        for (name,view,size) in surfaces {
            let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView:view.preferredColorScheme(.dark));window.contentView = host
            defer { window.contentView = nil;window.close() }
            host.frame = NSRect(origin:.zero,size:size);host.layoutSubtreeIfNeeded();host.displayIfNeeded()
            try await Task.sleep(nanoseconds:40_000_000)
            host.layoutSubtreeIfNeeded();host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
            let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            XCTAssertFalse(window.isVisible);XCTAssertGreaterThan(png.count,1000)
            XCTAssertEqual(host.bounds.size,size)
            if let folder = ProcessInfo.processInfo.environment["NATIVE_SCHEDULE_RECOVERY_RENDER_DIR"] {
                let output = URL(fileURLWithPath:folder,isDirectory:true)
                try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                let file = output.appendingPathComponent(name+".png")
                XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));try png.write(to:file,options:.withoutOverwriting)
            }
        }
        XCTAssertEqual(model.pendingScheduledCreations[93],receipt);XCTAssertEqual(model.scheduleDrafts[93],value)
        XCTAssertEqual(model.drafts[93],"Synthetic ordinary draft retained");XCTAssertEqual(ScheduleProtocol.writes,["create"])
    }
    func testMinutePickerDropsInvisibleSecondsWhileAPIDraftPreservesExactTimestamp() throws {
        let exact = Date(timeIntervalSince1970:2000.125)
        XCTAssertEqual(ChatScheduleDraft.minutePrecision(exact).timeIntervalSince1970,1980)
        XCTAssertEqual(ChatScheduleDraft(message:"API",date:exact).milliseconds,2000125)
        let initial = ChatScheduleDraft();XCTAssertEqual(initial.date.timeIntervalSince1970.truncatingRemainder(dividingBy:60),0);XCTAssertGreaterThan(initial.date,Date())
    }
}

private final class ScheduleProtocol:URLProtocol {
    static var jobs:[ChatScheduledMessage] = []
    static var writes:[String] = []
    static var ignoreWrite = false
    static var loseCreateReply = false
    static var holdCreate = false
    static var holdList = false
    static var held:ScheduleProtocol?
    static var observer:(([String:String])->Void)?
    static var nextID:Int64 = 28
    static var createdID:Int64 = 28
    static func reset() { jobs = [];writes = [];ignoreWrite = false;loseCreateReply = false;holdCreate = false;holdList = false;held = nil;observer = nil;nextID = 28;createdID = 28 }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var b = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&b,maxLength:b.count);if n <= 0 { break };bytes.append(contentsOf:b.prefix(n)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });let api = request.url!.lastPathComponent,method = fields["method"] ?? ""
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Post.Schedule","SYNO.Chat.Post","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Admin.Setting"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        if api == "SYNO.Chat.Post.Schedule" {
            if method != "list" { Self.writes.append(method) }
            if method == "create" { Self.createdID = Self.nextID;Self.nextID += 1 }
            if ["create","set"].contains(method),!Self.ignoreWrite {
                let message = (try? JSONDecoder().decode(String.self,from:Data((fields["message"] ?? "").utf8))) ?? ""
                let time = Double(fields["send_at"] ?? "0") ?? 0,id = method == "create" ? Self.createdID : Int64(fields["cronjob_id"] ?? "28") ?? 28
                Self.jobs.removeAll { $0.id == id };Self.jobs.append(.init(cronjob_id:id,message:message,send_at:time))
            }
            if method == "delete",!Self.ignoreWrite { Self.jobs.removeAll { $0.id == Int64(fields["cronjob_id"] ?? "") } }
            if method == "create",Self.loseCreateReply { client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return }
            if method == "create",Self.holdCreate { Self.held = self;Self.observer?(fields);return }
            if method == "list",Self.holdList { Self.held = self;Self.observer?(fields);return }
        }
        Self.observer?(fields)
        switch (api,method) {
        case ("SYNO.Chat.Post.Schedule","list"):finish(["success":true,"data":["schedule_posts":Self.jobs.map { ["cronjob_id":$0.id,"message":$0.message,"send_at":$0.send_at] as [String:Any] }]])
        case ("SYNO.Chat.Post.Schedule","create"):finish(["success":true,"data":["cronjob_id":Self.createdID]])
        case ("SYNO.Chat.Post.Schedule",_):finish(["success":true])
        case ("SYNO.Chat.User","list"):finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Peter","type":"human","human_type":"dsm"]]]])
        case ("SYNO.Chat.Channel","list"):finish(["success":true,"data":["channels":[93,94].map { ["channel_id":$0,"name":"Synthetic \($0)","type":"public","encrypted":false,"unread":0] as [String:Any] }]])
        case ("SYNO.Chat.Misc",_):finish(["success":true,"data":["acls":[]]])
        case ("SYNO.Chat.Admin.Setting",_):finish(["success":true,"data":["hide_post_url_preview":true,"file_size_limit":0]])
        case ("SYNO.Chat.Post","list"):finish(["success":true,"data":["posts":[]]])
        default:finish(["success":false,"error":["code":400]])
        }
    }
    func finish(_ object:[String:Any]) { let bytes = try! JSONSerialization.data(withJSONObject:object);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
