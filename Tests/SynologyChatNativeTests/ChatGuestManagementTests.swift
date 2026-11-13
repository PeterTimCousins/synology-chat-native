import XCTest
@testable import SynologyChatNative

@MainActor final class ChatGuestManagementTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private func guest(_ id: Int64 = 9, email: String = "pending@example.invalid", expires: Int64 = 0, user: Int64 = 0, status: String = "uninvited") throws -> ChatChannelGuest {
        try JSONDecoder().decode(ChatChannelGuest.self, from: JSONSerialization.data(withJSONObject: ["guest_id": id, "email": email, "expire_at": expires, "user_id": user, "status": status]))
    }
    private func snapshot(_ guests: [ChatChannelGuest], enabled: Bool = true, epoch: Int = 4) throws -> ChatChannelGuestsSnapshot {
        let channel = try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":96,"name":"Synthetic","type":"private","encrypted":false,"is_joined":true,"unread":0}"#.utf8))
        return .init(channel: channel, policy: .init(allow_guest: enabled), guests: guests, accountGeneration: epoch)
    }
    private func manager(journal: ChatGuestActionJournal? = nil) -> ChatGuestManagement {
        let value = ChatGuestManagement(journal: journal); value.activate(scope: scope); return value
    }
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guest-action-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }; return folder
    }
    func testInputNormalizesEmailAndUsesEndOfLocalDayInUnixSecondsAcrossDST() throws {
        XCTAssertEqual(try ChatGuestInput.email(" New.User+tag@Example.INVALID \n"), "new.user+tag@example.invalid")
        for value in ["", "a@", "@example.invalid", "a@@example.invalid", "a@example..invalid", "a@example.invalid\nBcc:x@example.invalid", "a b@example.invalid"] { XCTAssertThrowsError(try ChatGuestInput.email(value)) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let parser = ISO8601DateFormatter(), now = try XCTUnwrap(parser.date(from: "2026-01-01T00:00:00Z"))
        for (day, expected) in [("2026-07-01T12:00:00Z", "2026-07-01T22:59:59Z"), ("2026-11-11T12:00:00Z", "2026-11-11T23:59:59Z")] {
            XCTAssertEqual(try ChatGuestInput.expiration(day: parser.date(from: day), now: now, calendar: calendar), Int64(try XCTUnwrap(parser.date(from: expected)).timeIntervalSince1970))
        }
        XCTAssertEqual(try ChatGuestInput.expiration(day: nil), 0)
        XCTAssertThrowsError(try ChatGuestInput.expiration(day: now, now: now.addingTimeInterval(100_000), calendar: calendar))
        XCTAssertFalse(ChatGuestInput.languages.contains { $0.0 == "def" })
    }
    func testDisabledPolicyDuplicateEmailChangedGuestAndInvalidResendRejectBeforeReceipt() throws {
        let pending = try guest(), registered = try guest(4, user: 42, status: "registered")
        XCTAssertThrowsError(try ChatGuestActionRecord(change: .invite(email: "new@example.invalid", expireAt: 0, language: "enu"), snapshot: snapshot([pending], enabled: false)))
        XCTAssertThrowsError(try ChatGuestActionRecord(change: .invite(email: "PENDING@example.invalid", expireAt: 0, language: "enu"), snapshot: snapshot([pending])))
        XCTAssertThrowsError(try ChatGuestActionRecord(change: .invite(email: "new@example.invalid", expireAt: 0, language: "def"), snapshot: snapshot([pending])))
        XCTAssertThrowsError(try ChatGuestActionRecord(change: .resend(registered), snapshot: snapshot([registered])))
        XCTAssertThrowsError(try ChatGuestActionRecord(change: .remove(pending), snapshot: snapshot([])))
        XCTAssertThrowsError(try ChatGuestActionRecord(change: .expiry(pending, expireAt: 0), snapshot: snapshot([pending])))
        // Disabling new guest invitations does not remove management of existing records.
        XCTAssertNoThrow(try ChatGuestActionRecord(change: .remove(pending), snapshot: snapshot([pending], enabled: false)))
    }
    func testSuccessfulInvitationConfirmsNewCanonicalRecordAndClearsJournal() async throws {
        let actions = manager(), before = try snapshot([]), invited = try guest(11, email: "new@example.invalid")
        var reads = 0, writes = 0
        let after = try snapshot([invited])
        let result = try await actions.perform(.invite(email: "NEW@example.invalid", expireAt: 0, language: "enu"), original: before, read: { reads += 1; return reads == 1 ? before : after }, dispatch: { intent in
            writes += 1; XCTAssertEqual(intent.email, "new@example.invalid"); XCTAssertEqual(actions.pending[96], intent)
        }, check: {})
        XCTAssertEqual(result.guests, [invited]); XCTAssertEqual(reads, 2); XCTAssertEqual(writes, 1); XCTAssertTrue(actions.pending.isEmpty); XCTAssertFalse(actions.busy)
    }
    func testFreshPolicyAndExactSelectedRegistrationAreCheckedBeforeDispatch() async throws {
        let actions = manager(), pending = try guest(), before = try snapshot([pending])
        var writes = 0
        do { _ = try await actions.perform(.remove(pending), original: before, read: { try self.snapshot([self.guest(expires: 1_900_000_000)]) }, dispatch: { _ in writes += 1 }, check: {}); XCTFail("Stale guest changed") } catch { }
        do { _ = try await actions.perform(.invite(email: "new@example.invalid", expireAt: 0, language: "enu"), original: before, read: { try self.snapshot([pending], enabled: false) }, dispatch: { _ in writes += 1 }, check: {}); XCTFail("Disabled policy invited") } catch { }
        XCTAssertEqual(writes, 0); XCTAssertTrue(actions.pending.isEmpty)
    }
    func testLostInvitationResultSurvivesRelaunchAndFreshReadReconcilesWithoutReplay() async throws {
        let directory = try folder(), before = try snapshot([])
        let actions = manager(journal: .init(directory: directory))
        var writes = 0
        do { _ = try await actions.perform(.invite(email: "new@example.invalid", expireAt: 0, language: "enu"), original: before, read: { before }, dispatch: { _ in writes += 1; throw URLError(.timedOut) }, check: {}); XCTFail("Unknown invitation confirmed") } catch { }
        let restarted = manager(journal: .init(directory: directory)); XCTAssertEqual(restarted.pending.count, 1)
        do { _ = try await restarted.perform(.invite(email: "again@example.invalid", expireAt: 0, language: "enu"), original: before, read: { before }, dispatch: { _ in writes += 1 }, check: {}); XCTFail("Pending invitation repeated") } catch { }
        try restarted.reconcile(snapshot([guest(11, email: "new@example.invalid")]))
        XCTAssertTrue(restarted.pending.isEmpty); XCTAssertEqual(writes, 1)
        let file = directory.appendingPathComponent(scope + ".json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
    }
    func testUnknownResendCannotBeConfirmedByListAndAcknowledgementDoesNotSendAgain() async throws {
        let actions = manager(), pending = try guest(), before = try snapshot([pending]); var writes = 0
        do { _ = try await actions.perform(.resend(pending), original: before, read: { before }, dispatch: { _ in writes += 1; throw URLError(.networkConnectionLost) }, check: {}); XCTFail() } catch { }
        try actions.reconcile(before); let receipt = try XCTUnwrap(actions.pending[96])
        XCTAssertEqual(receipt.kind, .resend); try actions.dismissPending(receipt)
        XCTAssertTrue(actions.pending.isEmpty); XCTAssertEqual(writes, 1)
    }
    func testSuccessfulResendAcknowledgesRequestWithoutClaimingEmailDelivery() async throws {
        let actions = manager(), pending = try guest(), before = try snapshot([pending]); var writes = 0
        _ = try await actions.perform(.resend(pending), original: before, read: { before }, dispatch: { _ in writes += 1 }, check: {})
        XCTAssertEqual(writes, 1); XCTAssertTrue(actions.pending.isEmpty)
    }
    func testExpiryAndRemovalConfirmOnlyTheirTargetAndPreserveOtherRegistrations() async throws {
        let selected = try guest(), other = try guest(4, email: "other@example.invalid"), before = try snapshot([selected, other])
        for change in [ChatGuestChange.expiry(selected, expireAt: 1_900_000_000), .remove(selected)] {
            let actions = manager(); var reads = 0, writes = 0
            let after = try snapshot(change == .remove(selected) ? [other] : [guest(expires: 1_900_000_000), other])
            let result = try await actions.perform(change, original: before, read: { reads += 1; return reads == 1 ? before : after }, dispatch: { _ in writes += 1 }, check: {})
            XCTAssertTrue(result.guests.contains(other)); XCTAssertEqual(writes, 1); XCTAssertTrue(actions.pending.isEmpty)
        }
    }
    func testAccountRetirementAfterDispatchPreservesOldReceiptAndCannotReadOrPublish() async throws {
        let directory = try folder(), actions = manager(journal: .init(directory: directory)), before = try snapshot([])
        var reads = 0
        do { _ = try await actions.perform(.invite(email: "new@example.invalid", expireAt: 0, language: "enu"), original: before, read: { reads += 1; return before }, dispatch: { _ in actions.deactivate() }, check: {}); XCTFail("Retired result published") } catch is CancellationError { }
        XCTAssertEqual(reads, 1); XCTAssertTrue(actions.pending.isEmpty)
        let restored = manager(journal: .init(directory: directory)); XCTAssertEqual(restored.pending.count, 1)
        restored.activate(scope: String(repeating: "b", count: 64)); XCTAssertTrue(restored.pending.isEmpty)
    }
    func testCancellationBetweenReceiptAndDispatchRemovesKnownUndispatchedIntent() async throws {
        let directory = try folder(), actions = manager(journal: .init(directory: directory)), before = try snapshot([])
        var checks = 0, writes = 0
        do { _ = try await actions.perform(.invite(email: "new@example.invalid", expireAt: 0, language: "enu"), original: before, read: { before }, dispatch: { _ in writes += 1 }, check: { checks += 1; if checks == 3 { throw CancellationError() } }); XCTFail() } catch is CancellationError { }
        XCTAssertEqual(writes, 0); XCTAssertTrue(actions.pending.isEmpty)
        XCTAssertTrue(manager(journal: .init(directory: directory)).pending.isEmpty)
    }
    func testUnchangedCanonicalStateStaysPendingAndCorruptRecoveryBlocksWrites() async throws {
        let directory = try folder(), actions = manager(journal: .init(directory: directory)), pending = try guest(), before = try snapshot([pending])
        do { _ = try await actions.perform(.remove(pending), original: before, read: { before }, dispatch: { _ in }, check: {}); XCTFail("Ignored removal confirmed") } catch { }
        XCTAssertNotNil(actions.pending[96])
        try Data("corrupt synthetic receipt".utf8).write(to: directory.appendingPathComponent(scope + ".json"))
        let broken = manager(journal: .init(directory: directory)); XCTAssertNotNil(broken.recoveryError)
        var writes = 0
        do { _ = try await broken.perform(.remove(pending), original: before, read: { before }, dispatch: { _ in writes += 1 }, check: {}); XCTFail() } catch { }
        XCTAssertEqual(writes, 0)
    }
    func testAcknowledgedEmailRequestIsNotMadeUncertainByReadbackFailure() async throws {
        let actions = manager(), pending = try guest(), before = try snapshot([pending]); var reads = 0, writes = 0
        do {
            _ = try await actions.perform(.resend(pending), original: before, read: { reads += 1; if reads > 1 { throw URLError(.timedOut) }; return before }, dispatch: { _ in writes += 1 }, check: {})
            XCTFail()
        } catch { XCTAssertTrue(error.localizedDescription.contains("email was requested")) }
        XCTAssertEqual(writes, 1); XCTAssertTrue(actions.pending.isEmpty)
    }
    func testGuestEmailSettingsFailureRetainsReceiptAndExplainsServerIssue() async throws {
        let actions = manager(), before = try snapshot([])
        do {
            _ = try await actions.perform(.invite(email: "new@example.invalid", expireAt: 0, language: "enu"), original: before, read: { before }, dispatch: { _ in throw ChatAPIError.server(521) }, check: {})
            XCTFail()
        } catch { XCTAssertTrue(error.localizedDescription.contains("invitation email settings")) }
        XCTAssertNotNil(actions.pending[96])
    }
    func testSecondProcessCannotOverwriteOrReplayFirstProcessesChannelReceipt() async throws {
        let directory = try folder(), first = manager(journal: .init(directory: directory)), second = manager(journal: .init(directory: directory)), before = try snapshot([])
        var writes = 0
        do { _ = try await first.perform(.invite(email: "first@example.invalid", expireAt: 0, language: "enu"), original: before, read: { before }, dispatch: { _ in writes += 1; throw URLError(.timedOut) }, check: {}); XCTFail() } catch { }
        do { _ = try await second.perform(.invite(email: "second@example.invalid", expireAt: 0, language: "enu"), original: before, read: { before }, dispatch: { _ in writes += 1 }, check: {}); XCTFail() } catch { }
        second.retryRecovery()
        XCTAssertEqual(second.pending[96], first.pending[96]); XCTAssertEqual(second.pending[96]?.email, "first@example.invalid"); XCTAssertEqual(writes, 1)
    }
}
