import Foundation
import CryptoKit

/// An in-memory creation plan. Only the creator-sealed envelope survives key
/// generation. A coordinator must durably retain it before dispatch, then bind
/// the returned channel ID before permitting the join.
struct ChatEncryptedChannelCreation {
    let creatorEnvelope:String
    private let ownerFingerprint:String

    init(owner:ChatEncryptionKeyPair,encryption:ChatEncryptionSession) throws {
        guard owner.isInitialized,encryption.matchesUnlockedPublicKey(owner.public_key) else { throw ChatCryptoError.invalidKey }
        creatorEnvelope = try ChatContentCrypto.wrapChannelKey(ChatContentCrypto.generateChannelKey(),publicKey:ChatContentCrypto.decodeBase64(owner.public_key))
        ownerFingerprint = try Self.fingerprint(owner)
        try validate(owner:owner,encryption:encryption)
    }
    func validate(owner:ChatEncryptionKeyPair,encryption:ChatEncryptionSession) throws {
        guard owner.isInitialized,encryption.matchesUnlockedPublicKey(owner.public_key),
              try Self.fingerprint(owner) == ownerFingerprint,
              try ChatContentCrypto.decodeBase64(creatorEnvelope).count == 92 else { throw ChatCryptoError.invalidKey }
    }
    func matches(_ channel:ChatChannel,name:String,purpose:String) -> Bool {
        guard channel.id > 1,channel.type == "private",channel.encrypted,channel.is_joined == true,
              channel.is_closed != true,(channel.hide_global_at ?? 0) == 0,
              channel.name == name,(channel.purpose ?? "") == purpose,
              let raw = channel.channel_key_enc,let decoded = try? ChatContentCrypto.decodeBase64(raw),
              let expected = try? ChatContentCrypto.decodeBase64(creatorEnvelope) else { return false }
        return decoded == expected
    }
    private static func fingerprint(_ owner:ChatEncryptionKeyPair) throws -> String {
        let parts = try [owner.public_key,owner.private_key_enc].map { try ChatContentCrypto.decodeBase64($0).base64EncodedString() }
        return SHA256.hash(data:try JSONEncoder().encode(parts)).map { String(format:"%02x",$0) }.joined()
    }
}
