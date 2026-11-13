import XCTest
@testable import SynologyChatNative

@MainActor final class ChatEncryptionChangeCoordinatorTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private let password = "Synthetic replacement encryption password"
    private struct Fixture: Decodable {
        let password, publicKey, wrappedPrivateKey: String
        var pair: ChatEncryptionKeyPair { .init(public_key: publicKey, private_key_enc: wrappedPrivateKey) }
    }
    private func fixture() throws -> Fixture {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "ChatCrypto", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }
    private func snapshot(_ pair: ChatEncryptionKeyPair = .init(public_key: "", private_key_enc: ""), generation: Int = 4, owner: Int64 = 10, connection: String? = "synthetic-live-id") -> ChatEncryptionManagementSnapshot {
        .init(owner: .init(userID: owner, pair: pair), accountGeneration: generation, connectionID: connection)
    }
    private func manager(directory: URL? = nil) -> ChatEncryptionChangeCoordinator {
        let coordinator = ChatEncryptionChangeCoordinator(journal: .init(directory: directory))
        coordinator.activate(scope: scope, ownerID: 10); return coordinator
    }
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("encryption-coordinator-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return directory
    }
    private var setup: ChatEncryptionChange { .setup(password: password, confirmation: password) }

    func testSetupDispatchHasNoConnectionAndRequiresCanonicalDesiredPair() async throws {
        let coordinator = manager(), before = snapshot(connection: nil)
        var desired: ChatEncryptionKeyPair?, writes = 0, reads = 0
        let after = try await coordinator.perform(setup, original: before, read: {
            reads += 1; return desired.map { self.snapshot($0, connection: nil) } ?? before
        }, dispatch: { plan, connection in
            writes += 1; XCTAssertNil(connection); XCTAssertEqual(plan.operation, .initialSetup)
            XCTAssertNotNil(coordinator.pending); desired = plan.replacement
        }, check: {})
        XCTAssertEqual(writes, 1); XCTAssertEqual(reads, 2); XCTAssertTrue(after.owner.isInitialized)
        XCTAssertNil(coordinator.pending); XCTAssertFalse(coordinator.busy)
    }
    func testInitializedSetupAndWrongOldPasswordRejectWithoutReceiptOrDispatch() async throws {
        let f = try fixture(), before = snapshot(f.pair), coordinator = manager()
        var writes = 0
        for change in [setup, .rewrap(oldPassword: "Wrong synthetic password", password: password, confirmation: password)] {
            do { _ = try await coordinator.perform(change, original: before, read: { before }, dispatch: { _, _ in writes += 1 }, check: {}); XCTFail() } catch { }
        }
        XCTAssertEqual(writes, 0); XCTAssertNil(coordinator.pending)
    }
    func testFreshPairIdentityGenerationAndConnectionChangesRejectBeforeDispatch() async throws {
        let f = try fixture(), before = snapshot(f.pair), change = ChatEncryptionChange.rewrap(oldPassword: f.password, password: password, confirmation: password)
        let changedPair = try ChatEncryptionManagement.generateKeyPair(password: password, confirmation: password)
        for fresh in [snapshot(changedPair), snapshot(f.pair, generation: 5), snapshot(f.pair, owner: 11), snapshot(f.pair, connection: "replacement-id"), snapshot(f.pair, connection: nil), snapshot(f.pair, connection: "")] {
            let coordinator = manager(); var writes = 0
            do { _ = try await coordinator.perform(change, original: before, read: { fresh }, dispatch: { _, _ in writes += 1 }, check: {}); XCTFail() } catch { }
            XCTAssertEqual(writes, 0); XCTAssertNil(coordinator.pending)
        }
    }
    func testPasswordRewrapUsesOriginalConnectionAndPreservesPublicKey() async throws {
        let f = try fixture(), before = snapshot(f.pair), coordinator = manager()
        var desired: ChatEncryptionKeyPair?
        let after = try await coordinator.perform(.rewrap(oldPassword: f.password, password: password, confirmation: password), original: before,
            read: { desired.map { self.snapshot($0) } ?? before }, dispatch: { plan, connection in
                XCTAssertEqual(connection, before.connectionID); XCTAssertEqual(plan.operation, .passwordRewrap)
                XCTAssertEqual(plan.replacement.public_key, f.publicKey); desired = plan.replacement
            }, check: {})
        try ChatEncryptionManagement.validateKeyPair(after.owner.pair, password: password)
        XCTAssertNil(coordinator.pending)
    }
    func testIgnoredWriteStaysPendingAndOriginalReadCannotClearOrReplayIt() async throws {
        let coordinator = manager(), before = snapshot(); var writes = 0
        do { _ = try await coordinator.perform(setup, original: before, read: { before }, dispatch: { _, _ in writes += 1 }, check: {}); XCTFail() } catch { }
        let receipt = try XCTUnwrap(coordinator.pending)
        try coordinator.reconcile(before); XCTAssertEqual(coordinator.pending, receipt)
        do { _ = try await coordinator.perform(setup, original: before, read: { before }, dispatch: { _, _ in writes += 1 }, check: {}); XCTFail() } catch { }
        XCTAssertEqual(writes, 1)
    }
    func testLostWriteSurvivesRelaunchAndOnlyDesiredOwnerPairReconciles() async throws {
        let directory = try folder(), coordinator = manager(directory: directory), before = snapshot()
        var desired: ChatEncryptionKeyPair?, writes = 0
        do { _ = try await coordinator.perform(setup, original: before, read: { before }, dispatch: { plan, _ in desired = plan.replacement; writes += 1; throw URLError(.timedOut) }, check: {}); XCTFail() } catch { }
        let restarted = manager(directory: directory); XCTAssertEqual(restarted.pending, coordinator.pending)
        try restarted.reconcile(before); XCTAssertNotNil(restarted.pending)
        let pair = try XCTUnwrap(desired)
        try restarted.reconcile(snapshot(pair, owner: 11)); XCTAssertNotNil(restarted.pending)
        try restarted.reconcile(snapshot(pair, generation: 99)); XCTAssertNil(restarted.pending)
        XCTAssertEqual(writes, 1, "Recovery reads never replay a write")
        XCTAssertNil(manager(directory: directory).pending)
    }
    func testAcknowledgementAloneAndFailedReadbackRetainReceipt() async throws {
        let coordinator = manager(), before = snapshot(); var reads = 0, writes = 0
        do {
            _ = try await coordinator.perform(setup, original: before, read: {
                reads += 1; if reads == 2 { throw URLError(.networkConnectionLost) }; return before
            }, dispatch: { _, _ in writes += 1 }, check: {})
            XCTFail()
        } catch { }
        XCTAssertEqual(writes, 1); XCTAssertNotNil(coordinator.pending)
    }
    func testCancellationBetweenReceiptAndDispatchRemovesKnownUndispatchedIntent() async throws {
        let directory = try folder(), coordinator = manager(directory: directory), before = snapshot(); var checks = 0, writes = 0
        do {
            _ = try await coordinator.perform(setup, original: before, read: { before }, dispatch: { _, _ in writes += 1 }, check: {
                checks += 1; if checks == 3 { throw CancellationError() }
            }); XCTFail()
        } catch is CancellationError { }
        XCTAssertEqual(writes, 0); XCTAssertNil(coordinator.pending)
        XCTAssertNil(manager(directory: directory).pending)
    }
    func testAccountRetirementBeforeDispatchCleansOriginalScopeAndAfterDispatchPreservesIt() async throws {
        for retireAfterDispatch in [false, true] {
            let directory = try folder(), coordinator = manager(directory: directory), before = snapshot(); var checks = 0, writes = 0
            do {
                _ = try await coordinator.perform(setup, original: before, read: { before }, dispatch: { _, _ in
                    writes += 1; coordinator.deactivate()
                }, check: {
                    checks += 1; if !retireAfterDispatch && checks == 3 { coordinator.deactivate() }
                }); XCTFail()
            } catch is CancellationError { }
            XCTAssertNil(coordinator.pending); XCTAssertFalse(coordinator.busy)
            let restarted = manager(directory: directory)
            XCTAssertEqual(restarted.pending != nil, retireAfterDispatch); XCTAssertEqual(writes, retireAfterDispatch ? 1 : 0)
            restarted.activate(scope: String(repeating: "b", count: 64), ownerID: 10); XCTAssertNil(restarted.pending)
        }
    }
    func testSecondProcessCannotOverwriteOrDispatchPastFirstReceipt() async throws {
        let directory = try folder(), first = manager(directory: directory), second = manager(directory: directory), before = snapshot(); var writes = 0
        do { _ = try await first.perform(setup, original: before, read: { before }, dispatch: { _, _ in writes += 1; throw URLError(.timedOut) }, check: {}); XCTFail() } catch { }
        do { _ = try await second.perform(setup, original: before, read: { before }, dispatch: { _, _ in writes += 1 }, check: {}); XCTFail() } catch { }
        second.retryRecovery(); XCTAssertEqual(second.pending, first.pending); XCTAssertEqual(writes, 1)
    }
    func testPersistentReceiptIsPrivateAndContainsFingerprintsOnly() async throws {
        let directory = try folder(), coordinator = manager(directory: directory), before = snapshot(); var desired: ChatEncryptionKeyPair?
        do { _ = try await coordinator.perform(setup, original: before, read: { before }, dispatch: { plan, _ in desired = plan.replacement; throw URLError(.timedOut) }, check: {}); XCTFail() } catch { }
        let file = directory.appendingPathComponent(scope + ".json"), data = try Data(contentsOf: file), text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(password)); XCTAssertFalse(text.contains("private_key_enc")); XCTAssertFalse(text.contains("public_key"))
        XCTAssertFalse(text.contains(try XCTUnwrap(desired).private_key_enc)); XCTAssertFalse(text.contains(try XCTUnwrap(desired).public_key))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(records.first).keys), Set(["ownerID", "kind", "originalFingerprint", "desiredFingerprint", "operationID"]))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
    }
    func testCorruptAndWrongOwnerRecoveryFailClosedWithoutErasingRecords() async throws {
        let directory = try folder(), file = directory.appendingPathComponent(scope + ".json")
        let corrupt = Data("corrupt synthetic receipt".utf8); try corrupt.write(to: file)
        let coordinator = manager(directory: directory); XCTAssertNotNil(coordinator.recoveryError)
        var writes = 0
        do { _ = try await coordinator.perform(setup, original: snapshot(), read: { self.snapshot() }, dispatch: { _, _ in writes += 1 }, check: {}); XCTFail() } catch { }
        XCTAssertEqual(try Data(contentsOf: file), corrupt); XCTAssertEqual(writes, 0)
        let otherPlan = try ChatEncryptionManagement.initialPlan(existing: snapshot().owner.pair, password: password, confirmation: password)
        try FileManager.default.removeItem(at: file)
        let journal = ChatEncryptionWriteJournal(directory: directory); _ = try journal.activate(scope: scope)
        try journal.remember(ChatEncryptionWriteRecord(ownerID: 11, plan: otherPlan))
        coordinator.retryRecovery(); XCTAssertNotNil(coordinator.recoveryError)
    }
}
