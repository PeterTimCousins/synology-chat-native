import XCTest
@testable import SynologyChatNative

final class ChatEncryptionManagementTests: XCTestCase {
    private struct Fixture: Decodable {
        let password, privateKey, publicKey, channelKey, wrappedPrivateKey, wrappedChannelKey: String
        let message, encryptedMessage: String
        var pair: ChatEncryptionKeyPair { .init(public_key: publicKey, private_key_enc: wrappedPrivateKey) }
    }
    private let newPassword = "Synthetic new encryption password"
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ChatCrypto", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func keys(_ pair: ChatEncryptionKeyPair, password: String) throws -> (Data, Data) {
        (try ChatContentCrypto.decodeBase64(pair.public_key), try ChatContentCrypto.unlockPrivateKey(pair.private_key_enc, password: password))
    }

    func testPassphraseUsesVendorUTF16BoundsAndExactConfirmation() throws {
        for value in [String(repeating: "a", count: 8), String(repeating: "a", count: 64), String(repeating: "😀", count: 4), String(repeating: "😀", count: 32), "        "] {
            try ChatEncryptionManagement.validatePassphrase(value, confirmation: value)
        }
        for value in ["", "1234567", String(repeating: "a", count: 65), String(repeating: "😀", count: 33)] {
            XCTAssertThrowsError(try ChatEncryptionManagement.validatePassphrase(value, confirmation: value)) {
                XCTAssertEqual($0 as? ChatEncryptionManagement.Failure, .passphraseLength)
            }
        }
        let composed = "passwordé", decomposed = "passworde\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift canonical equality differs from exact password bytes")
        XCTAssertThrowsError(try ChatEncryptionManagement.validatePassphrase(composed, confirmation: decomposed)) {
            XCTAssertEqual($0 as? ChatEncryptionManagement.Failure, .confirmationMismatch)
        }
        XCTAssertThrowsError(try ChatEncryptionManagement.validatePassphrase("password123", confirmation: "password124"))
    }

    func testGeneratedPairHasFreshKeysAndExistingWireFormat() throws {
        let first = try ChatEncryptionManagement.generateKeyPair(password: newPassword, confirmation: newPassword)
        let second = try ChatEncryptionManagement.generateKeyPair(password: newPassword, confirmation: newPassword)
        XCTAssertNotEqual(first.public_key, second.public_key)
        XCTAssertNotEqual(first.private_key_enc, second.private_key_enc)
        let (publicKey, privateKey) = try keys(first, password: newPassword)
        XCTAssertEqual(publicKey.count, 32); XCTAssertEqual(privateKey.count, 32)
        XCTAssertEqual(first.public_key.count, 44)
        XCTAssertEqual(try ChatContentCrypto.decodeBase64(first.private_key_enc).count, 84,
            "24-byte nonce + 16-byte MAC + 44-byte Base64 private-key text")
        try ChatEncryptionManagement.validateKeyPair(first, password: newPassword)
        XCTAssertThrowsError(try ChatEncryptionManagement.validateKeyPair(first, password: "Incorrect synthetic password"))
    }

    func testInitialSetupRequiresBothOwnFieldsEmptyAndCannotReset() throws {
        let f = try fixture(), empty = ChatEncryptionKeyPair(public_key: "", private_key_enc: "")
        let plan = try ChatEncryptionManagement.initialPlan(existing: empty, password: newPassword, confirmation: newPassword)
        XCTAssertEqual(plan.operation, .initialSetup)
        XCTAssertEqual(plan.original.public_key, ""); XCTAssertEqual(plan.original.private_key_enc, "")
        XCTAssertTrue(plan.channels.isEmpty); XCTAssertTrue(plan.archives.isEmpty)
        for pair in [f.pair, .init(public_key: f.publicKey, private_key_enc: ""), .init(public_key: "", private_key_enc: f.wrappedPrivateKey), .init(public_key: " ", private_key_enc: "")] {
            XCTAssertThrowsError(try ChatEncryptionManagement.initialPlan(existing: pair, password: newPassword, confirmation: newPassword)) {
                XCTAssertEqual($0 as? ChatEncryptionManagement.Failure, .initializationWouldReplaceKeys)
            }
        }
    }

    func testRewrapKeepsOriginalPublicAndPrivateKeysAndChannelAccess() throws {
        let f = try fixture()
        let original = ChatEncryptionKeyPair(public_key: f.publicKey + "\r\n", private_key_enc: f.wrappedPrivateKey)
        let plan = try ChatEncryptionManagement.passwordRewrapPlan(existing: original, oldPassword: f.password, password: newPassword, confirmation: newPassword)
        XCTAssertEqual(plan.operation, .passwordRewrap)
        XCTAssertEqual(plan.replacement.public_key, original.public_key, "Do not normalize or rotate public keys during a password change")
        XCTAssertEqual(plan.original.private_key_enc, f.wrappedPrivateKey)
        XCTAssertNotEqual(plan.replacement.private_key_enc, f.wrappedPrivateKey)
        let (publicKey, privateKey) = try keys(plan.replacement, password: newPassword)
        XCTAssertEqual(privateKey, try ChatContentCrypto.decodeBase64(f.privateKey))
        XCTAssertThrowsError(try ChatContentCrypto.unlockPrivateKey(plan.replacement.private_key_enc, password: f.password))
        let channel = try ChatContentCrypto.unwrapChannelKey(f.wrappedChannelKey, publicKey: publicKey, privateKey: privateKey)
        XCTAssertEqual(try ChatContentCrypto.decryptMessage(f.encryptedMessage, key: channel), f.message)
        XCTAssertTrue(plan.channels.isEmpty); XCTAssertTrue(plan.archives.isEmpty)
    }

    func testRewrapRejectsWrongPasswordIncompleteAndMismatchedPairs() throws {
        let f = try fixture()
        XCTAssertThrowsError(try ChatEncryptionManagement.passwordRewrapPlan(existing: f.pair, oldPassword: "Wrong synthetic password", password: newPassword, confirmation: newPassword))
        let other = try ChatEncryptionManagement.generateKeyPair(password: newPassword, confirmation: newPassword)
        let mismatch = ChatEncryptionKeyPair(public_key: other.public_key, private_key_enc: f.wrappedPrivateKey)
        XCTAssertThrowsError(try ChatEncryptionManagement.passwordRewrapPlan(existing: mismatch, oldPassword: f.password, password: newPassword, confirmation: newPassword))
        XCTAssertThrowsError(try ChatEncryptionManagement.validateKeyPair(.init(public_key: f.publicKey, private_key_enc: ""), password: f.password))
    }

    func testRenewalResealsSameChannelAndArchiveKeysWithoutChangingCiphertext() throws {
        let f = try fixture()
        let firstKey = try ChatContentCrypto.decodeBase64(f.channelKey), otherKey = Data(repeating: 0x32, count: 32)
        let otherEnvelope = try ChatContentCrypto.wrapChannelKey(otherKey, publicKey: ChatContentCrypto.decodeBase64(f.publicKey))
        let originalCiphertext = try ChatContentCrypto.encryptMessage("Synthetic archive plaintext", key: otherKey)
        let inventory = ChatEncryptionManagement.Inventory(channels: [.init(id: 93, wrappedKey: f.wrappedChannelKey), .init(id: 94, wrappedKey: otherEnvelope)], archives: [.init(id: 26, wrappedKey: otherEnvelope)], isComplete: true)
        let plan = try ChatEncryptionManagement.renewalPlan(existing: f.pair, oldPassword: f.password, password: newPassword, confirmation: newPassword, inventory: inventory)
        XCTAssertEqual(plan.operation, .keyRenewal)
        XCTAssertNotEqual(plan.replacement.public_key, f.publicKey)
        XCTAssertEqual(plan.channels.map(\.id), [93, 94]); XCTAssertEqual(plan.archives.map(\.id), [26])
        let (publicKey, privateKey) = try keys(plan.replacement, password: newPassword)
        let channelKeys = try plan.channels.map { try ChatContentCrypto.unwrapChannelKey($0.wrappedKey, publicKey: publicKey, privateKey: privateKey) }
        let archiveKey = try ChatContentCrypto.unwrapChannelKey(plan.archives[0].wrappedKey, publicKey: publicKey, privateKey: privateKey)
        XCTAssertEqual(channelKeys, [firstKey, otherKey]); XCTAssertEqual(archiveKey, otherKey)
        XCTAssertEqual(try ChatContentCrypto.decryptMessage(f.encryptedMessage, key: channelKeys[0]), f.message)
        XCTAssertEqual(try ChatContentCrypto.decryptMessage(originalCiphertext, key: archiveKey), "Synthetic archive plaintext")
        XCTAssertEqual(inventory.channels[0].wrappedKey, f.wrappedChannelKey, "Preparing a plan never mutates old envelopes")
        XCTAssertThrowsError(try ChatContentCrypto.unwrapChannelKey(plan.channels[0].wrappedKey, publicKey: ChatContentCrypto.decodeBase64(f.publicKey), privateKey: ChatContentCrypto.decodeBase64(f.privateKey)))
    }

    func testRenewalRejectsIncompleteDuplicateInvalidAndUnreadableInventory() throws {
        let f = try fixture(), valid = ChatEncryptionManagement.Envelope(id: 93, wrappedKey: f.wrappedChannelKey)
        let inventories = [
            ChatEncryptionManagement.Inventory(channels: [], archives: [], isComplete: false),
            .init(channels: [valid, valid], archives: [], isComplete: true),
            .init(channels: [valid], archives: [.init(id: 0, wrappedKey: f.wrappedChannelKey)], isComplete: true),
            .init(channels: [valid], archives: [.init(id: 26, wrappedKey: "")], isComplete: true),
            .init(channels: [valid], archives: [.init(id: 26, wrappedKey: "damaged")], isComplete: true)
        ]
        for inventory in inventories {
            XCTAssertThrowsError(try ChatEncryptionManagement.renewalPlan(existing: f.pair, oldPassword: f.password, password: newPassword, confirmation: newPassword, inventory: inventory))
        }
    }

    func testExportsOnlySyntheticPlanWireValuesForIndependentJavaScriptCheck() throws {
        let f = try fixture()
        let initial = try ChatEncryptionManagement.initialPlan(existing: .init(public_key: "", private_key_enc: ""), password: newPassword, confirmation: newPassword)
        let rewrap = try ChatEncryptionManagement.passwordRewrapPlan(existing: f.pair, oldPassword: f.password, password: newPassword, confirmation: newPassword)
        let renewal = try ChatEncryptionManagement.renewalPlan(existing: f.pair, oldPassword: f.password, password: newPassword, confirmation: newPassword,
            inventory: .init(channels: [.init(id: 93, wrappedKey: f.wrappedChannelKey)], archives: [.init(id: 26, wrappedKey: f.wrappedChannelKey)], isComplete: true))
        let output: [String: Any] = ["kind": "synthetic fixture only", "password": newPassword,
            "initial": ["public_key": initial.replacement.public_key, "private_key_enc": initial.replacement.private_key_enc],
            "rewrap": ["public_key": rewrap.replacement.public_key, "private_key_enc": rewrap.replacement.private_key_enc],
            "renewal": ["public_key": renewal.replacement.public_key, "private_key_enc": renewal.replacement.private_key_enc,
                        "channel_key_enc": renewal.channels[0].wrappedKey, "archive_key_enc": renewal.archives[0].wrappedKey]]
        // Contains only freshly generated synthetic test keys, never an account.
        let file = URL(fileURLWithPath: "/private/tmp/synology-encryption-management-native.json")
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
