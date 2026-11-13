import XCTest
@testable import SynologyChatNative

final class ChatContentCryptoTests: XCTestCase {
    private struct Fixture: Decodable {
        let password, privateKey, publicKey, channelKey, wrappedPrivateKey, wrappedChannelKey: String
        let message, encryptedMessage, filename, encryptedFilename, attachment, encryptedAttachment: String
    }
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ChatCrypto", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testOpensIndependentJavaScriptMessageFilenameAttachmentAndKeyEnvelopes() throws {
        let f = try fixture()
        let key = try ChatContentCrypto.decodeBase64(f.channelKey)
        let privateKey = try ChatContentCrypto.decodeBase64(f.privateKey)
        XCTAssertTrue(f.encryptedMessage.contains("\r\n"), "Exercise the legacy server's wrapped Base64")
        XCTAssertEqual(try ChatContentCrypto.unlockPrivateKey(f.wrappedPrivateKey, password: f.password), privateKey)
        XCTAssertEqual(try ChatContentCrypto.unwrapChannelKey(f.wrappedChannelKey,
            publicKey: ChatContentCrypto.decodeBase64(f.publicKey), privateKey: privateKey), key)
        XCTAssertEqual(try ChatContentCrypto.decryptMessage(f.encryptedMessage, key: key), f.message)
        XCTAssertEqual(try ChatContentCrypto.decryptFilename(f.encryptedFilename, key: key), f.filename)
        XCTAssertEqual(try ChatContentCrypto.decryptAttachment(ChatContentCrypto.decodeBase64(f.encryptedAttachment), key: key),
                       try ChatContentCrypto.decodeBase64(f.attachment))
    }

    func testTamperingWrongPasswordsAndWrongRecipientsFailAuthentication() throws {
        let f = try fixture()
        let key = try ChatContentCrypto.decodeBase64(f.channelKey)
        var damaged = try ChatContentCrypto.decodeBase64(f.encryptedMessage)
        damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try ChatContentCrypto.decryptMessage(damaged.base64EncodedString(), key: key))
        XCTAssertThrowsError(try ChatContentCrypto.unlockPrivateKey(f.wrappedPrivateKey, password: "Wrong synthetic password"))
        XCTAssertThrowsError(try ChatContentCrypto.unwrapChannelKey(f.wrappedChannelKey,
            publicKey: ChatContentCrypto.decodeBase64(f.publicKey), privateKey: Data(repeating: 7, count: 32)))
        XCTAssertThrowsError(try ChatContentCrypto.decryptMessage("not-base64!", key: key))
        XCTAssertThrowsError(try ChatContentCrypto.decryptFilename("not-hex", key: key))
        XCTAssertThrowsError(try ChatContentCrypto.decryptAttachment(Data(repeating: 0, count: 39), key: key))
        XCTAssertThrowsError(try ChatContentCrypto.encryptMessage("Synthetic", key: Data(repeating: 0, count: 31)))
    }

    func testNativeEncryptionUsesFreshNoncesAndExportsSyntheticCrossLanguageEvidence() throws {
        let f = try fixture()
        let key = try ChatContentCrypto.decodeBase64(f.channelKey)
        let message = try ChatContentCrypto.encryptMessage(f.message, key: key)
        XCTAssertNotEqual(message, try ChatContentCrypto.encryptMessage(f.message, key: key))
        XCTAssertEqual(try ChatContentCrypto.decryptMessage(message, key: key), f.message)
        let output = [
            "message": message,
            "filename": try ChatContentCrypto.encryptFilename(f.filename, key: key),
            "attachment": try ChatContentCrypto.encryptAttachment(ChatContentCrypto.decodeBase64(f.attachment), key: key).base64EncodedString(),
            "privateKey": try ChatContentCrypto.wrapPrivateKey(ChatContentCrypto.decodeBase64(f.privateKey), password: f.password),
            "channelKey": try ChatContentCrypto.wrapChannelKey(key, publicKey: ChatContentCrypto.decodeBase64(f.publicKey))
        ]
        // Only synthetic ciphertext. The separate JavaScript verifier opens these
        // five outputs using its independently implemented protocol framing.
        let destination = URL(fileURLWithPath: "/private/tmp/synology-chat-crypto-native-fixture.json")
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
