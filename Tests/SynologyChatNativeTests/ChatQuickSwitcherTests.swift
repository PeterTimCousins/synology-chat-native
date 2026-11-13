import XCTest
import AppKit
@testable import SynologyChatNative

@MainActor final class ChatQuickSwitcherTests: XCTestCase {
    override func setUp() { super.setUp(); QuickProtocol.reset() }
    private func account() -> ChatAccount { .init(session: .init(baseURL: URL(string: "https://quick-switch.invalid")!, sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false) }
    private func folder() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("quick-start-tests-" + UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url }
    private func model(journal: ChatConversationStartJournal? = nil) async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [QuickProtocol.self]
            return try ChatAPIClient(session: session, network: URLSession(configuration: c))
        }, conversationStartJournal: journal)
        await model.connect(using: account()); XCTAssertTrue(model.connected, model.error ?? "Connection failed"); model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() }; return model
    }
    private func newPerson(_ model: NativeChatPreviewModel) async throws -> (ChatQuickSwitchSnapshot, ChatQuickSwitchEntry) { let snapshot = try await model.loadQuickSwitcher(); return (snapshot, try XCTUnwrap(snapshot.entries.first { $0.channel == nil && $0.person?.user_id == 7 })) }
    func testPickerExistingDirectAndGroupNeverCreateOrSendAndPreserveDraft() async throws {
        let model = try await model(), snapshot = try await model.loadQuickSwitcher()
        model.selection = 1; model.draft = "Keep draft"
        try await model.startConversation(with:[6],reviewed:snapshot);XCTAssertEqual(model.selection,93)
        try await model.startConversation(with:[6,7],reviewed:snapshot);XCTAssertEqual(model.selection,94)
        model.selection = 1;XCTAssertEqual(model.draft,"Keep draft");XCTAssertTrue(QuickProtocol.starts.isEmpty);XCTAssertEqual(QuickProtocol.posts,0)
    }
    func testPickerNewDirectUsesCanonicalWireAndClearsReceipt() async throws {
        let model = try await model(), snapshot = try await model.loadQuickSwitcher()
        try await model.startConversation(with:[7],reviewed:snapshot)
        XCTAssertEqual(model.selection,99);XCTAssertTrue(model.pendingConversationStarts.isEmpty)
        XCTAssertEqual(QuickProtocol.starts.count,1);XCTAssertEqual(QuickProtocol.starts.first?["user_ids"],"[7,10]");XCTAssertEqual(QuickProtocol.posts,0)
    }
    func testPickerNewGroupJournalsAndChecksExactMembership() async throws {
        QuickProtocol.groupPeer = true;QuickProtocol.createdMembers = [6,8,10]
        let model = try await model(), snapshot = try await model.loadQuickSwitcher()
        try await model.startConversation(with:[6,8],reviewed:snapshot)
        XCTAssertEqual(model.selection,99);XCTAssertEqual(QuickProtocol.starts.first?["user_ids"],"[6,8,10]")
        XCTAssertTrue(model.pendingConversationStarts.isEmpty);XCTAssertEqual(QuickProtocol.posts,0)
    }
    func testReviewedPickerIdentityChangeCannotStartOrRoute() async throws {
        let model = try await model(), snapshot = try await model.loadQuickSwitcher();QuickProtocol.peerRenamed = true
        do {try await model.startConversation(with:[7],reviewed:snapshot);XCTFail()}catch{}
        XCTAssertNil(model.selection);XCTAssertTrue(QuickProtocol.starts.isEmpty);XCTAssertTrue(model.pendingConversationStarts.isEmpty)
    }
    func testDisappearedReviewedConversationCannotSilentlyCreateAnother() async throws {
        let model = try await model(), snapshot = try await model.loadQuickSwitcher();QuickProtocol.hideExisting = true
        do {try await model.startConversation(with:[6],reviewed:snapshot);XCTFail()}catch{}
        XCTAssertTrue(QuickProtocol.starts.isEmpty);XCTAssertTrue(model.pendingConversationStarts.isEmpty)
    }
    func testPickerLostUnappliedReplyBlocksQuickSwitcherAndPickerAcrossRelaunch() async throws {
        let dir = try folder(), model = try await model(journal:.init(directory:dir)), snapshot = try await model.loadQuickSwitcher()
        QuickProtocol.ignoreStart = true;QuickProtocol.loseReply = true
        do {try await model.startConversation(with:[7],reviewed:snapshot);XCTFail()}catch{}
        let person = try XCTUnwrap(snapshot.entries.first{$0.channel == nil && $0.person?.user_id == 7})
        do {_ = try await model.openQuickSwitch(person,snapshot:snapshot);XCTFail()}catch{}
        model.signOutLocally();let next = try await self.model(journal:.init(directory:dir))
        do {try await next.startConversation(with:[7]);XCTFail()}catch{}
        XCTAssertEqual(QuickProtocol.starts.count,1);XCTAssertEqual(next.pendingConversationStarts.count,1)
    }
    func testGroupLostAppliedReplyResolvesReadOnlyAfterRelaunch() async throws {
        QuickProtocol.groupPeer = true;QuickProtocol.createdMembers = [6,8,10]
        let dir = try folder(), model = try await model(journal:.init(directory:dir))
        QuickProtocol.loseReply = true
        do {try await model.startConversation(with:[6,8]);XCTFail()}catch{}
        XCTAssertEqual(model.pendingConversationStarts.count,1);model.signOutLocally()
        let next = try await self.model(journal:.init(directory:dir));_ = try await next.loadQuickSwitcher()
        XCTAssertTrue(next.pendingConversationStarts.isEmpty)
        try await next.startConversation(with:[6,8]);XCTAssertEqual(next.selection,99);XCTAssertEqual(QuickProtocol.starts.count,1)
    }
    func testPickerCancellationBeforeDispatchClearsSavedReceipt() async throws {
        let dir = try folder(), model = try await model(journal:.init(directory:dir)), held = expectation(description:"Pre-dispatch read")
        QuickProtocol.holdUsersAt = QuickProtocol.userReads+2;QuickProtocol.onHeld = {held.fulfill()}
        let operation = Task {try await model.startConversation(with:[7])}
        await fulfillment(of:[held],timeout:2);XCTAssertEqual(model.pendingConversationStarts.count,1)
        operation.cancel();QuickProtocol.release()
        do {try await operation.value;XCTFail()}catch{}
        XCTAssertTrue(model.pendingConversationStarts.isEmpty);XCTAssertTrue(QuickProtocol.starts.isEmpty);XCTAssertFalse(model.channelManagementBusy)
        model.signOutLocally();let next = try await self.model(journal:.init(directory:dir));XCTAssertTrue(next.pendingConversationStarts.isEmpty)
    }
    func testPickerAndQuickSwitcherSerializeSharedMutation() async throws {
        let model = try await model(), snapshot = try await model.loadQuickSwitcher(), person = try XCTUnwrap(snapshot.entries.first{$0.channel == nil && $0.person?.user_id == 7}), held = expectation(description:"Start held")
        QuickProtocol.holdStart = true;QuickProtocol.onHeld = {held.fulfill()}
        let operation = Task {try await model.startConversation(with:[7],reviewed:snapshot)}
        await fulfillment(of:[held],timeout:2)
        do {_ = try await model.openQuickSwitch(person,snapshot:snapshot);XCTFail()}catch{}
        do {_ = try await model.loadQuickSwitcher();XCTFail()}catch{}
        QuickProtocol.release();try await operation.value;XCTAssertEqual(QuickProtocol.starts.count,1)
    }
    func testPickerLateAcknowledgementDoesNotOverrideNavigation() async throws {
        let model = try await model(), held = expectation(description:"Start held")
        QuickProtocol.holdStart = true;QuickProtocol.onHeld = {held.fulfill()}
        let operation = Task {try await model.startConversation(with:[7])}
        await fulfillment(of:[held],timeout:2);model.selection = 1;QuickProtocol.release()
        do {try await operation.value;XCTFail()}catch is CancellationError{}
        XCTAssertEqual(model.selection,1);XCTAssertTrue(model.pendingConversationStarts.isEmpty);XCTAssertEqual(QuickProtocol.starts.count,1)
    }
    func testAmbiguousExistingMemberSetDoesNotRouteOrCreate() async throws {
        QuickProtocol.duplicateExisting = true
        let model = try await model()
        do {try await model.startConversation(with:[6]);XCTFail()}catch{}
        XCTAssertNil(model.selection);XCTAssertTrue(QuickProtocol.starts.isEmpty)
    }
    func testProfileMessageUsesSameDurableUncertaintyAndDoesNotReplay() async throws {
        let model = try await model();QuickProtocol.loseReply = true;QuickProtocol.ignoreStart = true
        do {try await model.openProfileConversation(userID:7);XCTFail()}catch{}
        do {try await model.openProfileConversation(userID:7);XCTFail()}catch{}
        XCTAssertEqual(QuickProtocol.starts.count,1);XCTAssertEqual(model.pendingConversationStarts.count,1)
    }
    func testProfileInitialReadCannotOverrideLaterNavigationOrStart() async throws {
        let model = try await model(), held = expectation(description:"Profile people held")
        QuickProtocol.holdUsersAt = QuickProtocol.userReads+1;QuickProtocol.onHeld = {held.fulfill()}
        let operation = Task {try await model.openProfileConversation(userID:7)}
        await fulfillment(of:[held],timeout:2);model.selection = 1;QuickProtocol.release()
        do {try await operation.value;XCTFail()}catch is CancellationError{}
        XCTAssertEqual(model.selection,1);XCTAssertTrue(QuickProtocol.starts.isEmpty);XCTAssertTrue(model.pendingConversationStarts.isEmpty)
    }
    func testGroupReceiptSupportsMoreThanNineMembersWithoutAssumingServerLimit() throws {
        let intent = ChatConversationStartIntent(members:Set(Int64(1)...Int64(32)))
        let journal = ChatConversationStartJournal(directory:try folder()), scope = String(repeating:"b",count:64)
        _ = try journal.activate(scope:scope);try journal.remember(intent)
        XCTAssertEqual(try journal.activate(scope:scope),[intent])
    }
    func testLiteralPatternPortHandlesTermsPrefixUsernameBonusAndUnicode() {
        XCTAssertEqual(ChatQuickSwitchMatch.score("Peter Cousins", "pe cou"), 3)
        XCTAssertEqual(ChatQuickSwitchMatch.score("Peter", "peter", bonus: 1), 3)
        XCTAssertEqual(ChatQuickSwitchMatch.score("alpha.beta", "."), 1)
        XCTAssertEqual(ChatQuickSwitchMatch.score("😀 Équipe", "équipe"), 1)
        XCTAssertEqual(ChatQuickSwitchMatch.score("Peter", "ptr"), 0)
        XCTAssertEqual(ChatQuickSwitchMatch.score("Peter Cousins", "pe  cou"), 0)
        XCTAssertEqual(ChatQuickSwitchMatch.score("Peter", "   "), 0)
    }
    func testCatalogueKeepsEncryptedSeparateCollapsesDirectUsersAndExcludesGuestOrSelfStarts() async throws {
        let model = try await model(), s = try await model.loadQuickSwitcher()
        XCTAssertEqual(s.entries.filter { $0.person?.user_id == 6 && !$0.encrypted }.count, 1)
        XCTAssertNotNil(s.entries.first { $0.channel?.id == 95 && $0.encrypted })
        XCTAssertFalse(s.entries.contains { $0.channel == nil && [10, 8].contains($0.person?.user_id ?? 0) })
        XCTAssertEqual(s.filtered(query: "General", scope: 1).map(\.title), ["General"])
        XCTAssertFalse(s.filtered(query: "Calendar", scope: 2).contains { $0.channel?.type == "chatbot" })
        XCTAssertEqual(s.filtered(query: "Calendar", scope: 0).count, 1)
        XCTAssertTrue(QuickProtocol.starts.isEmpty)
    }
    func testUnreadPriorityPrecedesRecencyAndNewPeopleDoNotAppearAsRecent() async throws {
        let model = try await model(), s = try await model.loadQuickSwitcher(), recent = s.filtered(query: "", scope: 0)
        XCTAssertEqual(recent.first?.channel?.id, 93)
        XCTAssertFalse(recent.contains { $0.channel == nil })
        XCTAssertTrue(s.filtered(query: "Zed", scope: 0).contains { $0.person?.user_id == 7 && $0.channel == nil })
    }
    func testShortcutModifiersAndClampedKeyboardMovement() async throws {
        XCTAssertTrue(NativeQuickSwitchKeys.matches("k", modifiers: .command)); XCTAssertTrue(NativeQuickSwitchKeys.matches("K", modifiers: [.control, .capsLock]))
        for flags: NSEvent.ModifierFlags in [[], .option, [.command, .shift], [.command, .option], [.command, .control]] { XCTAssertFalse(NativeQuickSwitchKeys.matches("k", modifiers: flags)) }
        let model = try await model(), entries = try await model.loadQuickSwitcher().filtered(query: "", scope: 0)
        XCTAssertEqual(ChatQuickSwitchSelection.move(nil, in: entries, delta: 1), entries.first?.id)
        XCTAssertEqual(ChatQuickSwitchSelection.move(entries.first?.id, in: entries, delta: -10), entries.first?.id)
        XCTAssertEqual(ChatQuickSwitchSelection.move(entries.first?.id, in: entries, delta: 100), entries.last?.id)
        XCTAssertNil(ChatQuickSwitchSelection.move(nil, in: [], delta: 1))
    }
    func testExistingRoutePreservesDraftAndNeverInitiatesOrPosts() async throws {
        let model = try await model(), s = try await model.loadQuickSwitcher(), peter = try XCTUnwrap(s.entries.first { $0.channel?.id == 93 })
        model.selection = 1; model.draft = "Keep original draft"
        let opened = try await model.openQuickSwitch(peter, snapshot: s)
        XCTAssertTrue(opened); XCTAssertEqual(model.selection, 93); XCTAssertTrue(QuickProtocol.starts.isEmpty); XCTAssertEqual(QuickProtocol.posts, 0)
        model.selection = 1; XCTAssertEqual(model.draft, "Keep original draft")
    }
    func testEncryptedRouteDoesNotReadProtectedHistoryOrCreateUnencryptedConversation() async throws {
        let model = try await model(), s = try await model.loadQuickSwitcher(), encrypted = try XCTUnwrap(s.entries.first { $0.channel?.id == 95 })
        let opened = try await model.openQuickSwitch(encrypted, snapshot: s)
        XCTAssertTrue(opened); XCTAssertEqual(model.selection, 95); XCTAssertFalse(model.canRead(95))
        XCTAssertTrue(QuickProtocol.starts.isEmpty); XCTAssertEqual(QuickProtocol.postReads, 0)
    }
    func testChangedMembershipFailsWithoutRouteOrWrites() async throws {
        let model = try await model(), s = try await model.loadQuickSwitcher(), peter = try XCTUnwrap(s.entries.first { $0.channel?.id == 93 })
        model.selection = 1; QuickProtocol.members[93] = [10, 6, 7]
        do { _ = try await model.openQuickSwitch(peter, snapshot: s); XCTFail() } catch { }
        XCTAssertEqual(model.selection, 1); XCTAssertTrue(QuickProtocol.starts.isEmpty)
    }
    func testNewConversationCanonicalReadbackAndWireContract() async throws {
        let model = try await model(), (s, person) = try await newPerson(model)
        let opened = try await model.openQuickSwitch(person, snapshot: s)
        XCTAssertTrue(opened); XCTAssertEqual(model.selection, 99); XCTAssertTrue(model.pendingConversationStarts.isEmpty)
        XCTAssertEqual(QuickProtocol.starts.count, 1); let f = try XCTUnwrap(QuickProtocol.starts.first)
        XCTAssertEqual(f["version"], "2"); XCTAssertEqual(f["user_ids"], "[7,10]"); XCTAssertEqual(f["channel_key_encs"], "[]"); XCTAssertNil(f["message"]); XCTAssertNil(f["encrypted"]); XCTAssertEqual(QuickProtocol.posts, 0)
    }
    func testPermissionOrAvailabilityChangePreventsNewStart() async throws {
        let model = try await model(), (s, person) = try await newPerson(model)
        QuickProtocol.allowStart = false
        do { _ = try await model.openQuickSwitch(person, snapshot: s); XCTFail() } catch { }
        QuickProtocol.allowStart = true; QuickProtocol.peerDisabled = true
        do { _ = try await model.openQuickSwitch(person, snapshot: s); XCTFail() } catch { }
        XCTAssertTrue(QuickProtocol.starts.isEmpty); XCTAssertTrue(model.pendingConversationStarts.isEmpty)
    }
    func testEditingMessagePreventsNavigationAndPreservesDraft() async throws {
        let model = try await model(), s = try await model.loadQuickSwitcher(), peter = try XCTUnwrap(s.entries.first { $0.channel?.id == 93 })
        model.selection = 1; model.draft = "Keep this draft"; let owner = UUID(); model.beginMessageEditing(owner: owner)
        defer { model.endMessageEditing(owner: owner) }
        do { _ = try await model.openQuickSwitch(peter, snapshot: s); XCTFail() } catch { }
        XCTAssertEqual(model.selection, 1); XCTAssertEqual(model.draft, "Keep this draft"); XCTAssertTrue(QuickProtocol.starts.isEmpty)
    }
    func testAnotherClientCreatingConversationBeforeDispatchAvoidsDuplicateStart() async throws {
        let model = try await model(), (s, person) = try await newPerson(model)
        QuickProtocol.createAfterACLAt = QuickProtocol.aclReads + 1
        let opened = try await model.openQuickSwitch(person, snapshot: s)
        XCTAssertTrue(opened); XCTAssertEqual(model.selection, 99); XCTAssertTrue(QuickProtocol.starts.isEmpty); XCTAssertTrue(model.pendingConversationStarts.isEmpty)
    }
    func testPermissionRevokedAfterJournalingClearsUndispatchedReceipt() async throws {
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (s, person) = try await newPerson(model)
        QuickProtocol.revokeOnUserRead = QuickProtocol.userReads + 2
        do { _ = try await model.openQuickSwitch(person, snapshot: s); XCTFail() } catch { }
        XCTAssertTrue(model.pendingConversationStarts.isEmpty); XCTAssertTrue(QuickProtocol.starts.isEmpty)
        model.signOutLocally(); let next = try await self.model(journal: .init(directory: dir)); XCTAssertTrue(next.pendingConversationStarts.isEmpty)
    }
    func testLostReplySurvivesRelaunchWithoutReplayAndReadOnlyRefreshResolvesIt() async throws {
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (s, person) = try await newPerson(model)
        QuickProtocol.loseReply = true
        do { _ = try await model.openQuickSwitch(person, snapshot: s); XCTFail() } catch { }
        XCTAssertEqual(model.pendingConversationStarts.count, 1); model.signOutLocally()
        let next = try await self.model(journal: .init(directory: dir)); XCTAssertEqual(next.pendingConversationStarts.count, 1); XCTAssertEqual(QuickProtocol.starts.count, 1)
        let checked = try await next.loadQuickSwitcher(); XCTAssertTrue(next.pendingConversationStarts.isEmpty); XCTAssertNotNil(checked.entries.first { $0.channel?.id == 99 }); XCTAssertEqual(QuickProtocol.starts.count, 1)
    }
    func testUnappliedLostReplyBlocksRepeatAcrossRefreshAndRelaunch() async throws {
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (s, person) = try await newPerson(model)
        QuickProtocol.loseReply = true; QuickProtocol.ignoreStart = true
        do { _ = try await model.openQuickSwitch(person, snapshot: s); XCTFail() } catch { }
        _ = try await model.loadQuickSwitcher(); do { _ = try await model.openQuickSwitch(person, snapshot: s); XCTFail() } catch { }
        model.signOutLocally(); let next = try await self.model(journal: .init(directory: dir)), (fresh, same) = try await newPerson(next)
        do { _ = try await next.openQuickSwitch(same, snapshot: fresh); XCTFail() } catch { }
        XCTAssertEqual(QuickProtocol.starts.count, 1); XCTAssertEqual(next.pendingConversationStarts.count, 1)
    }
    func testWrongCreatedMembershipIsNotRoutedAndRemainsUnconfirmed() async throws {
        let model = try await model(), (s, person) = try await newPerson(model); QuickProtocol.createdMembers = [10, 8]
        do { _ = try await model.openQuickSwitch(person, snapshot: s); XCTFail() } catch { }
        XCTAssertNil(model.selection); XCTAssertEqual(model.pendingConversationStarts.count, 1); XCTAssertEqual(QuickProtocol.starts.count, 1)
    }
    func testLateAcknowledgementDoesNotReplaceNewlySelectedConversation() async throws {
        let model = try await model(), (s, person) = try await newPerson(model), held = expectation(description: "Held initiate")
        model.selection = 1; QuickProtocol.holdStart = true; QuickProtocol.onHeld = { held.fulfill() }
        let action = Task { try await model.openQuickSwitch(person, snapshot: s) }
        await fulfillment(of: [held], timeout: 2); model.selection = 2; QuickProtocol.release()
        let routed = try await action.value; XCTAssertFalse(routed); XCTAssertEqual(model.selection, 2); XCTAssertTrue(model.pendingConversationStarts.isEmpty)
    }
    func testSignOutAfterDispatchKeepsReceiptForNextAccountSession() async throws {
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (s, person) = try await newPerson(model), held = expectation(description: "Held initiate")
        QuickProtocol.holdStart = true; QuickProtocol.onHeld = { held.fulfill() }
        let action = Task { try await model.openQuickSwitch(person, snapshot: s) }
        await fulfillment(of: [held], timeout: 2); model.signOutLocally(); QuickProtocol.release()
        do { _ = try await action.value; XCTFail() } catch is CancellationError { }
        let next = try await self.model(journal: .init(directory: dir)); XCTAssertEqual(next.pendingConversationStarts.count, 1)
        _ = try await next.loadQuickSwitcher(); XCTAssertTrue(next.pendingConversationStarts.isEmpty); XCTAssertEqual(QuickProtocol.starts.count, 1)
    }
    func testSignOutBeforeDispatchCleansOriginalReceiptWithoutRequest() async throws {
        let dir = try folder(), model = try await model(journal: .init(directory: dir)), (s, person) = try await newPerson(model), held = expectation(description: "Held post-journal read")
        QuickProtocol.holdUsersAt = QuickProtocol.userReads + 2; QuickProtocol.onHeld = { held.fulfill() }
        let action = Task { try await model.openQuickSwitch(person, snapshot: s) }
        await fulfillment(of: [held], timeout: 2); XCTAssertEqual(model.pendingConversationStarts.count, 1); model.signOutLocally(); QuickProtocol.release()
        do { _ = try await action.value; XCTFail() } catch is CancellationError { }
        let next = try await self.model(journal: .init(directory: dir)); XCTAssertTrue(next.pendingConversationStarts.isEmpty); XCTAssertTrue(QuickProtocol.starts.isEmpty)
    }
    func testCorruptStartStorageStillAllowsExistingReadOnlyRoutes() async throws {
        let dir = try folder(), scope = try XCTUnwrap(ChatNotificationAccountScope.make(account: account(), userID: 10))
        try Data("corrupt".utf8).write(to: dir.appendingPathComponent(scope + ".json"))
        let model = try await model(journal: .init(directory: dir)), s = try await model.loadQuickSwitcher(), person = try XCTUnwrap(s.entries.first { $0.channel == nil && $0.person?.user_id == 7 })
        XCTAssertNotNil(model.conversationStartRecoveryError)
        do { _ = try await model.openQuickSwitch(person, snapshot: s); XCTFail() } catch { }
        let peter = try XCTUnwrap(s.entries.first { $0.channel?.id == 93 }), opened = try await model.openQuickSwitch(peter, snapshot: s)
        XCTAssertTrue(opened); XCTAssertTrue(QuickProtocol.starts.isEmpty)
    }
    func testMemberFingerprintIsOrderIndependentAndJournalStoresNoNamesOrCredentials() throws {
        let a = ChatConversationStartIntent(members: [10, 7]), b = ChatConversationStartIntent(members: [7, 10])
        XCTAssertEqual(a.id, b.id); XCTAssertNotEqual(a.operationID, b.operationID)
        let dir = try folder(), journal = ChatConversationStartJournal(directory: dir), scope = String(repeating: "a", count: 64)
        _ = try journal.activate(scope: scope); try journal.remember(a)
        let raw = try String(contentsOf: dir.appendingPathComponent(scope + ".json"))
        XCTAssertFalse(raw.contains("Peter")); XCTAssertFalse(raw.contains("sid")); XCTAssertFalse(raw.contains("https"))
        XCTAssertEqual(try ChatConversationStartJournal(directory: dir).activate(scope: scope), [a])
    }
}

private final class QuickProtocol: URLProtocol, @unchecked Sendable {
    static var groupPeer = false, peerRenamed = false, hideExisting = false, duplicateExisting = false
    static var allowStart = true, peerDisabled = false, loseReply = false, ignoreStart = false, holdStart = false
    static var aclReads = 0, createAfterACLAt: Int?, revokeOnUserRead: Int?
    static var starts: [[String: String]] = [], posts = 0, postReads = 0, userReads = 0, holdUsersAt: Int?
    static var members: [Int64: [Int64]] = [:], createdMembers: [Int64] = [7, 10]
    static var created = false
    static var held: (QuickProtocol, [String: Any])?, onHeld: (() -> Void)?
    static func reset() { groupPeer = false; peerRenamed = false; hideExisting = false; duplicateExisting = false; aclReads = 0; createAfterACLAt = nil; revokeOnUserRead = nil; allowStart = true; peerDisabled = false; loseReply = false; ignoreStart = false; holdStart = false; starts = []; posts = 0; postReads = 0; userReads = 0; holdUsersAt = nil; members = [93: [10,6], 94: [10,6,7], 95: [10,6], 46: [10], 88: [10]]; createdMembers = [7,10]; created = false; held = nil; onHeld = nil }
    static var users: [[String: Any]] { [["user_id":10,"username":"synthetic","nickname":"Owner","type":"human","human_type":"dsm"],["user_id":6,"username":"peter","nickname":"Peter","type":"human","human_type":"dsm"],["user_id":7,"username":"zed","nickname":peerRenamed ? "Changed" : "Zed","type":"human","human_type":"dsm","is_disabled":peerDisabled],["user_id":8,"username":"guest","nickname":"Guest","type":"human","human_type":groupPeer ? "dsm" : "guest"],["user_id":16,"nickname":"Calendar","type":"bot","bot_type":"chatbot"]] }
    static func channel(_ id: Int, _ name: String, _ type: String, _ time: Int = 10, _ unread: Int = 0) -> [String: Any] { ["channel_id":id,"name":name,"type":type,"encrypted":false,"unread":unread,"channel_order_time":time,"is_joined":true] }
    static var newChannel: [String: Any] { channel(99,"","anonymous",500) }
    static var channels: [[String: Any]] {
        var encrypted = channel(95,"","anonymous",5); encrypted["encrypted"] = true; encrypted["channel_key_enc"] = "wrapped"
        var bot = channel(46,"","chatbot"); bot["creator_id"] = 16
        return ([channel(1,"General","public",100,3),channel(2,"Team","private",90),channel(93,"","anonymous",20,2),channel(94,"","anonymous",9),encrypted,bot,channel(88,"","synobot")] + (created ? [newChannel] : []) + (duplicateExisting ? [channel(98,"","anonymous")] : [])).filter { !hideExisting || ($0["channel_id"] as? Int) != 93 }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "quick-switch.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" { finish(Dictionary(uniqueKeysWithValues: ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Misc","SYNO.Chat.Channel.Chatbot","SYNO.Chat.Channel.Anonymous","SYNO.Chat.Post"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String: Any]) })); return }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var b = [UInt8](repeating:0,count:2048); while stream.hasBytesAvailable { let n = stream.read(&b,maxLength:b.count); if n <= 0 { break }; data.append(contentsOf:b.prefix(n)) } }
        var q = URLComponents(); q.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let f = Dictionary((q.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,v in v }), method = f["method"] ?? ""
        if api == "SYNO.Chat.User" { Self.userReads += 1; if Self.revokeOnUserRead == Self.userReads { Self.allowStart = false }; if Self.holdUsersAt == Self.userReads { Self.holdUsersAt = nil; Self.held = (self,["users":Self.users]); Self.onHeld?(); return }; finish(["users":Self.users]); return }
        if api == "SYNO.Chat.Misc" { Self.aclReads += 1; if Self.createAfterACLAt == Self.aclReads { Self.created = true }; finish(["acls":[["acl_name":"channel_anonymous","allow":Self.allowStart]]]); return }
        if api == "SYNO.Chat.Channel.Chatbot" { finish(["blocked_user_ids":[]]); return }
        if api == "SYNO.Chat.Channel.Member" { let id = Int64(f["channel_id"] ?? "") ?? 0; finish(["user_ids": id == 99 ? Self.createdMembers : (id == 98 ? [10,6] : Self.members[id] ?? [])]); return }
        if api == "SYNO.Chat.Channel" { finish(method == "list" ? ["channels":f["is_joined"] == "false" ? [] : Self.channels] : [:]); return }
        if api == "SYNO.Chat.Post" { if method == "create" { Self.posts += 1 }; if method == "list" { Self.postReads += 1 }; finish(["posts":[]]); return }
        guard api == "SYNO.Chat.Channel.Anonymous", method == "initiate" else { finish([:]); return }
        Self.starts.append(f); if !Self.ignoreStart { Self.created = true }
        if Self.holdStart { Self.holdStart = false; Self.held = (self,Self.newChannel); Self.onHeld?(); return }
        if Self.loseReply { Self.loseReply = false; client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost)); return }
        finish(Self.newChannel)
    }
    static func release() { if let held { Self.held = nil; held.0.finish(held.1) } }
    private func finish(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject:["success":true,"data":value]); client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
