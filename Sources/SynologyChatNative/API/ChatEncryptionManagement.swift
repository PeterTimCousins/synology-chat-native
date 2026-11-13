import Foundation
import Sodium

/// Offline plans only. No API requests, persistence, account initialization or
/// destructive reset occurs here. A caller must freshly verify the account and
/// inventory, serialize changes and confirm canonical readback before publishing.
enum ChatEncryptionManagement {
    enum Failure: LocalizedError, Equatable {
        case passphraseLength, confirmationMismatch, initializationWouldReplaceKeys
        case incompleteInventory, invalidInventory
        var errorDescription: String? {
            switch self {
            case .passphraseLength: return "Use an encryption password between 8 and 64 characters."
            case .confirmationMismatch: return "The encryption passwords do not match."
            case .initializationWouldReplaceKeys: return "Encryption keys already exist or are incomplete. Initialization cannot replace them."
            case .incompleteInventory: return "All encrypted conversations and archives must be checked before renewing keys."
            case .invalidInventory: return "The encrypted conversation or archive key list is invalid."
            }
        }
    }
    enum Operation { case initialSetup, passwordRewrap, keyRenewal }
    struct Envelope: Equatable {
        let id: Int64
        let wrappedKey: String
    }
    struct Inventory {
        let channels: [Envelope]
        let archives: [Envelope]
        /// Must be established by the future account-scoped inventory reader,
        /// not inferred from an empty/failed/partially paged response.
        let isComplete: Bool
    }
    struct Plan {
        let operation: Operation
        let original: ChatEncryptionKeyPair
        let replacement: ChatEncryptionKeyPair
        let channels: [Envelope]
        let archives: [Envelope]
        // No plaintext private/channel key or password is retained in a plan.
    }

    static func validatePassphrase(_ password: String, confirmation: String) throws {
        guard (8...64).contains(password.utf16.count), (8...64).contains(confirmation.utf16.count) else {
            throw Failure.passphraseLength
        }
        // JavaScript compares literal strings. Swift's canonical Unicode
        // equality must not accept two differently encoded password inputs.
        guard password.utf8.elementsEqual(confirmation.utf8) else { throw Failure.confirmationMismatch }
    }

    static func generateKeyPair(password: String, confirmation: String) throws -> ChatEncryptionKeyPair {
        try validatePassphrase(password, confirmation: confirmation)
        guard let keys = Sodium().box.keyPair() else { throw ChatCryptoError.operationFailed }
        let publicKey = Data(keys.publicKey), privateKey = Data(keys.secretKey)
        try validate(publicKey: publicKey, privateKey: privateKey)
        return ChatEncryptionKeyPair(public_key: publicKey.base64EncodedString(),
            private_key_enc: try ChatContentCrypto.wrapPrivateKey(privateKey, password: password))
    }

    static func validateKeyPair(_ pair: ChatEncryptionKeyPair, password: String) throws {
        _ = try privateKey(pair, password: password)
    }

    static func initialPlan(existing: ChatEncryptionKeyPair, password: String, confirmation: String) throws -> Plan {
        // Public-only records are valid for peers but are not empty own state.
        // Never make initial setup an implicit forgot-password reset.
        guard existing.public_key.isEmpty, existing.private_key_enc.isEmpty else {
            throw Failure.initializationWouldReplaceKeys
        }
        return Plan(operation: .initialSetup, original: existing,
            replacement: try generateKeyPair(password: password, confirmation: confirmation), channels: [], archives: [])
    }

    static func passwordRewrapPlan(existing: ChatEncryptionKeyPair, oldPassword: String,
                                   password: String, confirmation: String) throws -> Plan {
        try validatePassphrase(password, confirmation: confirmation)
        let key = try privateKey(existing, password: oldPassword)
        let replacement = ChatEncryptionKeyPair(public_key: existing.public_key,
            private_key_enc: try ChatContentCrypto.wrapPrivateKey(key, password: password))
        return Plan(operation: .passwordRewrap, original: existing, replacement: replacement, channels: [], archives: [])
    }

    /// Preserves the symmetric content keys, unlike a destructive reset. This
    /// deliberately rejects any missing/unreadable envelope rather than copying
    /// the official client's silent omission of records it could not decrypt.
    static func renewalPlan(existing: ChatEncryptionKeyPair, oldPassword: String,
                            password: String, confirmation: String, inventory: Inventory) throws -> Plan {
        try validatePassphrase(password, confirmation: confirmation)
        guard inventory.isComplete else { throw Failure.incompleteInventory }
        for entries in [inventory.channels, inventory.archives] {
            guard entries.count <= 10_000, Set(entries.map(\.id)).count == entries.count,
                  entries.allSatisfy({ $0.id > 0 && !$0.wrappedKey.isEmpty }) else { throw Failure.invalidInventory }
        }
        let oldPrivate = try privateKey(existing, password: oldPassword)
        let oldPublic = try ChatContentCrypto.decodeBase64(existing.public_key)
        func open(_ entries: [Envelope]) throws -> [(Int64, Data)] {
            try entries.map { ($0.id, try ChatContentCrypto.unwrapChannelKey($0.wrappedKey,
                publicKey: oldPublic, privateKey: oldPrivate)) }
        }
        // Validate the whole inventory before generating or returning a plan.
        let channels = try open(inventory.channels), archives = try open(inventory.archives)
        let replacement = try generateKeyPair(password: password, confirmation: confirmation)
        let newPublic = try ChatContentCrypto.decodeBase64(replacement.public_key)
        func reseal(_ entries: [(Int64, Data)]) throws -> [Envelope] {
            try entries.map { Envelope(id: $0.0, wrappedKey: try ChatContentCrypto.wrapChannelKey($0.1, publicKey: newPublic)) }
        }
        return Plan(operation: .keyRenewal, original: existing, replacement: replacement,
            channels: try reseal(channels), archives: try reseal(archives))
    }

    private static func privateKey(_ pair: ChatEncryptionKeyPair, password: String) throws -> Data {
        guard pair.isInitialized else { throw ChatCryptoError.invalidKey }
        let publicKey = try ChatContentCrypto.decodeBase64(pair.public_key)
        let privateKey = try ChatContentCrypto.unlockPrivateKey(pair.private_key_enc, password: password)
        try validate(publicKey: publicKey, privateKey: privateKey)
        return privateKey
    }
    private static func validate(publicKey: Data, privateKey: Data) throws {
        guard publicKey.count == 32, privateKey.count == 32 else { throw ChatCryptoError.invalidKey }
        let challenge = Data(repeating: 0xA5, count: 32)
        let envelope = try ChatContentCrypto.wrapChannelKey(challenge, publicKey: publicKey)
        guard try ChatContentCrypto.unwrapChannelKey(envelope, publicKey: publicKey, privateKey: privateKey) == challenge else {
            throw ChatCryptoError.authenticationFailed
        }
    }
}
