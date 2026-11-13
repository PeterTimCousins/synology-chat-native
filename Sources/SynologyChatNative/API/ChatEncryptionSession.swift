import Foundation

struct ChatEncryptionKeyPair: Decodable {
    let public_key: String
    let private_key_enc: String
    init(public_key: String, private_key_enc: String) {
        self.public_key = public_key; self.private_key_enc = private_key_enc
    }
    private enum CodingKeys: String, CodingKey { case public_key, private_key_enc }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        public_key = try fields.decodeIfPresent(String.self, forKey: .public_key) ?? ""
        private_key_enc = try fields.decodeIfPresent(String.self, forKey: .private_key_enc) ?? ""
    }
    var isInitialized: Bool { !public_key.isEmpty && !private_key_enc.isEmpty }
}

/// Unlocks existing server envelopes locally. No persistence or server key-management operations.
final class ChatEncryptionSession {
    private var privateKey: Data?
    private var publicKey: Data?
    private var channelKeys: [Int64: (envelope: String, key: Data)] = [:]
    var isUnlocked: Bool { privateKey != nil && publicKey != nil }

    func unlock(_ pair: ChatEncryptionKeyPair, password: String) throws {
        lock()
        guard pair.isInitialized else { throw ChatCryptoError.invalidKey }
        let publicKey = try ChatContentCrypto.decodeBase64(pair.public_key)
        let privateKey = try ChatContentCrypto.unlockPrivateKey(pair.private_key_enc, password: password)
        // Verify the stored public and private keys belong together before retaining either.
        let challenge = Data(repeating: 0xA5, count: 32)
        let envelope = try ChatContentCrypto.wrapChannelKey(challenge, publicKey: publicKey)
        guard try ChatContentCrypto.unwrapChannelKey(envelope, publicKey: publicKey, privateKey: privateKey) == challenge else {
            throw ChatCryptoError.authenticationFailed
        }
        self.publicKey = publicKey; self.privateKey = privateKey
    }

    func lock() { privateKey = nil; publicKey = nil; channelKeys = [:] }

    func matchesUnlockedPublicKey(_ value:String) -> Bool {
        guard isUnlocked,let publicKey,let candidate = try? ChatContentCrypto.decodeBase64(value) else { return false }
        return candidate == publicKey
    }

    func validateChannelEnvelope(_ envelope:String) throws {
        guard let publicKey,let privateKey else { throw ChatCryptoError.invalidKey }
        _ = try ChatContentCrypto.unwrapChannelKey(envelope,publicKey:publicKey,privateKey:privateKey)
    }

    func key(for channel: ChatChannel) throws -> Data {
        guard channel.encrypted, let envelope = channel.channel_key_enc, !envelope.isEmpty,
              let publicKey, let privateKey else { throw ChatCryptoError.invalidKey }
        if let cached = channelKeys[channel.id], cached.envelope == envelope { return cached.key }
        let key = try ChatContentCrypto.unwrapChannelKey(envelope, publicKey: publicKey, privateKey: privateKey)
        channelKeys[channel.id] = (envelope, key)
        return key
    }

    func wireMessage(_ text: String, channel: ChatChannel) throws -> String {
        channel.encrypted ? try ChatContentCrypto.encryptMessage(text, key: key(for: channel)) : text
    }
    func message(_ text: String, channel: ChatChannel) throws -> String {
        guard channel.encrypted, !text.isEmpty else { return text }
        return try ChatContentCrypto.decryptMessage(text, key: key(for: channel))
    }
    func filename(_ text: String, channel: ChatChannel) throws -> String {
        channel.encrypted ? try ChatContentCrypto.decryptFilename(text, key: key(for: channel)) : text
    }
}
