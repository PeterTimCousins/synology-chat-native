import XCTest
@testable import SynologyChatNative

@MainActor final class NativeEncryptionManagementTests: XCTestCase {
    private struct Fixture: Decodable {
        let password, publicKey, wrappedPrivateKey: String
        var pair: ChatEncryptionKeyPair { .init(public_key: publicKey, private_key_enc: wrappedPrivateKey) }
    }
    private let replacement = "Synthetic replacement password"
    private func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "ChatCrypto", withExtension: "json", subdirectory: "Fixtures"))))
    }
    private func model(pair: ChatEncryptionKeyPair = .init(public_key: "", private_key_enc: ""),
                       journal: ChatEncryptionWriteJournal? = nil,
                       connection: @escaping () -> String? = { "synthetic-client-init-id" }) async throws -> NativeChatPreviewModel {
        let model = try await NativeEncryptionManagementFixture.makeModel(pair: pair, journal: journal, connection: connection)
        addTeardownBlock { @MainActor in model.signOutLocally() }; return model
    }
    override func tearDown() {
        EncryptionManagementFixtureProtocol.held = nil; EncryptionManagementFixtureProtocol.heldResponse = nil
        EncryptionManagementFixtureProtocol.observer = nil; super.tearDown()
    }
    func testSetupExactWireCanonicalStateAndOrdinaryDraftAndProfilePreservation() async throws {
        let model = try await model(); model.draft = "Keep this ordinary unsent draft."
        let original = try await model.loadEncryptionManagement()
        XCTAssertFalse(original.owner.isInitialized)
        let result = try await model.changeEncryption(.setup(password: replacement, confirmation: replacement), original: original)
        XCTAssertTrue(result.owner.isInitialized); XCTAssertTrue(model.hasEncryptionKeyPair); XCTAssertFalse(model.encryptionUnlocked)
        XCTAssertEqual(model.draft, "Keep this ordinary unsent draft.")
        XCTAssertEqual(model.directory.first { $0.user_id == 10 }?.user_props?.email, "synthetic@example.invalid")
        XCTAssertEqual(model.directory.first { $0.user_id == 10 }?.user_props?.avatar_color, "#123456")
        XCTAssertEqual(model.directory.first { $0.user_id == 6 }?.nickname, "Synthetic peer")
        let fields = try XCTUnwrap(EncryptionManagementFixtureProtocol.writes.first)
        XCTAssertEqual(EncryptionManagementFixtureProtocol.writes.count, 1)
        XCTAssertEqual(fields["method"], "set"); XCTAssertEqual(fields["version"], "3")
        XCTAssertNotNil(fields["public_key"]); XCTAssertNotNil(fields["private_key_enc"])
        for name in ["conn_id", "password", "passwd", "channel_ids", "archive_ids"] { XCTAssertNil(fields[name]) }
        XCTAssertNil(model.encryptionChanges.pending)
        try model.unlockEncryption(password: replacement); XCTAssertTrue(model.encryptionUnlocked)
    }
    func testPasswordRewrapUsesClientInitIDAndPreservesAsymmetricKeys() async throws {
        let f = try fixture(), model = try await model(pair: f.pair)
        let original = try await model.loadEncryptionManagement()
        _ = try await model.changeEncryption(.rewrap(oldPassword: f.password, password: replacement, confirmation: replacement), original: original)
        let fields = try XCTUnwrap(EncryptionManagementFixtureProtocol.writes.first)
        XCTAssertEqual(fields["method"], "change_password"); XCTAssertEqual(fields["version"], "2")
        XCTAssertEqual(fields["conn_id"], #""synthetic-client-init-id""#)
        XCTAssertNil(fields["public_key"]); XCTAssertNil(fields["channel_ids"]); XCTAssertNil(fields["archive_ids"])
        XCTAssertEqual(EncryptionManagementFixtureProtocol.pair.public_key, f.publicKey)
        XCTAssertEqual(try ChatContentCrypto.unlockPrivateKey(EncryptionManagementFixtureProtocol.pair.private_key_enc, password: replacement),
                       try ChatContentCrypto.unlockPrivateKey(f.wrappedPrivateKey, password: f.password))
        XCTAssertFalse(model.encryptionUnlocked); XCTAssertNil(model.encryptionChanges.pending)
    }
    func testUnsupportedSetupVersionStopsBeforeUncertaintyReceiptOrRequest() async throws {
        let model = try await model(), original = try await model.loadEncryptionManagement()
        // API support is cached at discovery. A separate client discovers the older version.
        EncryptionManagementFixtureProtocol.maximumUserVersion = 2
        let older = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            try ChatAPIClient(session: session, network: NativeEncryptionManagementFixture.network())
        })
        await older.connect(using: NativeEncryptionManagementFixture.account)
        addTeardownBlock { @MainActor in older.signOutLocally() }
        let snapshot = try await older.loadEncryptionManagement()
        do { _ = try await older.changeEncryption(.setup(password: replacement, confirmation: replacement), original: snapshot); XCTFail("Unsupported setup dispatched") } catch ChatAPIError.unsupportedAPI { }
        XCTAssertTrue(EncryptionManagementFixtureProtocol.writes.isEmpty); XCTAssertNil(older.encryptionChanges.pending)
        XCTAssertFalse(original.owner.isInitialized)
    }
    func testEncryptedDraftBlocksMutationWithoutDiscardingTextOrSavingReceipt() async throws {
        let f = try fixture(), model = try await model(pair: f.pair), original = try await model.loadEncryptionManagement()
        let encrypted = try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":24,"name":"Encrypted synthetic","type":"private","encrypted":true,"is_joined":true,"unread":0}"#.utf8))
        model.channels.append(encrypted); model.selection = 24; model.draft = "Keep this encrypted draft exactly."
        XCTAssertNotNil(model.encryptionChangeBlockReason)
        do { _ = try await model.changeEncryption(.rewrap(oldPassword: f.password, password: replacement, confirmation: replacement), original: original); XCTFail("Encrypted draft discarded") } catch { }
        XCTAssertEqual(model.draft, "Keep this encrypted draft exactly.")
        XCTAssertTrue(EncryptionManagementFixtureProtocol.writes.isEmpty); XCTAssertNil(model.encryptionChanges.pending)
    }
    func testOldProfileReadCannotReinstallObsoleteKeysAfterStrictRead() async throws {
        let f = try fixture(), model = try await model(pair: f.pair), held = expectation(description: "Old profile held")
        EncryptionManagementFixtureProtocol.holdNextList = true; EncryptionManagementFixtureProtocol.observer = { if $0 == "list" { held.fulfill() } }
        let oldRead = Task { try await model.refreshUserProfiles() }
        await fulfillment(of: [held], timeout: 2)
        let response = try XCTUnwrap(EncryptionManagementFixtureProtocol.heldResponse), request = try XCTUnwrap(EncryptionManagementFixtureProtocol.held)
        let fresh = try ChatEncryptionManagement.generateKeyPair(password: replacement, confirmation: replacement)
        EncryptionManagementFixtureProtocol.pair = fresh
        _ = try await model.loadEncryptionManagement()
        request.finish(response)
        do { try await oldRead.value; XCTFail("Old profile installed obsolete pair") } catch is CancellationError { }
        XCTAssertEqual(model.encryptionKeyPair?.public_key, fresh.public_key)
        XCTAssertEqual(model.encryptionKeyPair?.private_key_enc, fresh.private_key_enc)
    }
    func testMissingOrChangedLiveConnectionCannotDispatchPasswordChange() async throws {
        let f = try fixture(); var connection: String? = nil
        let model = try await model(pair: f.pair, connection: { connection })
        let noConnection = try await model.loadEncryptionManagement()
        do { _ = try await model.changeEncryption(.rewrap(oldPassword: f.password, password: replacement, confirmation: replacement), original: noConnection); XCTFail() } catch { }
        connection = "first-client-init-id"; let original = try await model.loadEncryptionManagement(); connection = "replacement-client-init-id"
        do { _ = try await model.changeEncryption(.rewrap(oldPassword: f.password, password: replacement, confirmation: replacement), original: original); XCTFail() } catch { }
        XCTAssertTrue(EncryptionManagementFixtureProtocol.writes.isEmpty); XCTAssertNil(model.encryptionChanges.pending)
    }
    func testSetupPasswordWriterCannotDispatchRenewalOrReset() async throws {
        let f = try fixture()
        EncryptionManagementFixtureProtocol.reset(pair: f.pair)
        let api = try ChatAPIClient(session: NativeEncryptionManagementFixture.account.session, network: NativeEncryptionManagementFixture.network())
        try await api.discover()
        let renewal = try ChatEncryptionManagement.renewalPlan(existing: f.pair, oldPassword: f.password, password: replacement, confirmation: replacement,
                                                             inventory: .init(channels: [], archives: [], isComplete: true))
        do { try await api.applyEncryptionManagementPlan(renewal, connectionID: "synthetic-client-init-id"); XCTFail("Renewal used password-management route") } catch ChatAPIError.unsupportedAPI { }
        XCTAssertTrue(EncryptionManagementFixtureProtocol.writes.isEmpty)
    }
    func testOldStrictReadCannotOverwriteNewerProfileKeyPair() async throws {
        let f = try fixture(), model = try await model(pair: f.pair), held = expectation(description: "Old strict state held")
        EncryptionManagementFixtureProtocol.holdNextList = true
        EncryptionManagementFixtureProtocol.observer = { if $0 == "list" { held.fulfill() } }
        let oldStrict = Task { try await model.loadEncryptionManagement() }
        await fulfillment(of: [held], timeout: 2)
        let request = try XCTUnwrap(EncryptionManagementFixtureProtocol.held)
        let response = try XCTUnwrap(EncryptionManagementFixtureProtocol.heldResponse)
        let fresh = try ChatEncryptionManagement.generateKeyPair(password: replacement, confirmation: replacement)
        EncryptionManagementFixtureProtocol.pair = fresh
        try await model.refreshUserProfiles()
        request.finish(response)
        do { _ = try await oldStrict.value; XCTFail("Old strict read overwrote newer profile keys") } catch is CancellationError { }
        XCTAssertEqual(model.encryptionKeyPair?.public_key, fresh.public_key)
        XCTAssertEqual(model.encryptionKeyPair?.private_key_enc, fresh.private_key_enc)
        XCTAssertTrue(EncryptionManagementFixtureProtocol.writes.isEmpty)
    }
}
