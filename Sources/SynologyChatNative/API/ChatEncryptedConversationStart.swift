import Foundation
import CryptoKit

/// A decoded initiation response is not proof of a newly created conversation.
/// Preserve its ID for read-only reconciliation without publishing or retrying.
struct ChatEncryptedConversationResponseUnconfirmed:LocalizedError {
    let candidateChannelID:Int64?
    var errorDescription:String? { "The returned encrypted conversation could not be verified. Check its status before trying again." }
}

/// A reviewed, in-memory anonymous-conversation wire plan. All participants,
/// including the creator, receive separately sealed copies of one fresh key.
/// Account/ACL/participant reuse checks and durable uncertainty recovery belong
/// to the initiating coordinator; this plan does not create or publish a chat.
struct ChatEncryptedConversationStart {
    struct Participant {
        let id:Int64
        let username:String?
        let nickname:String
        let publicKeyDigest:String
        let envelope:String
    }
    let ownerID:Int64
    let participants:[Participant]
    private let ownerFingerprint:String
    var userIDs:[Int64] { participants.map(\.id) }
    var envelopes:[String] { participants.map(\.envelope) }
    var ownerEnvelope:String { participants.first { $0.id == ownerID }!.envelope }

    init(ownerID:Int64,owner:ChatEncryptionKeyPair,users:[ChatUser],encryption:ChatEncryptionSession) throws {
        guard ownerID > 0,owner.isInitialized,encryption.matchesUnlockedPublicKey(owner.public_key),
              users.count >= 2,Set(users.map(\.user_id)).count == users.count,
              let creator = users.first(where:{ $0.user_id == ownerID }),
              try Self.publicKey(creator) == ChatContentCrypto.decodeBase64(owner.public_key) else { throw ChatCryptoError.invalidKey }
        let reviewed = try users.sorted { $0.user_id < $1.user_id }.map { ($0,try Self.publicKey($0)) }
        let key = try ChatContentCrypto.generateChannelKey()
        self.ownerID = ownerID;ownerFingerprint = try Self.fingerprint(owner)
        participants = try reviewed.map { user,publicKey in
            Participant(id:user.user_id,username:user.username,nickname:user.nickname,publicKeyDigest:Self.digest(publicKey),
                        envelope:try ChatContentCrypto.wrapChannelKey(key,publicKey:publicKey))
        }
        try validate(owner:owner,users:users,encryption:encryption)
    }

    func validate(owner:ChatEncryptionKeyPair,users:[ChatUser],encryption:ChatEncryptionSession) throws {
        guard owner.isInitialized,encryption.matchesUnlockedPublicKey(owner.public_key),
              try Self.fingerprint(owner) == ownerFingerprint,users.count == participants.count,
              Set(users.map(\.user_id)) == Set(userIDs),Set(users.map(\.user_id)).count == users.count else { throw ChatCryptoError.invalidKey }
        for participant in participants {
            guard let user = users.first(where:{ $0.user_id == participant.id }),user.username == participant.username,user.nickname == participant.nickname,
                  try Self.digest(Self.publicKey(user)) == participant.publicKeyDigest,
                  try ChatContentCrypto.decodeBase64(participant.envelope).count == 92 else { throw ChatCryptoError.invalidKey }
        }
    }

    func matchesCreatedResponse(_ channel:ChatChannel)->Bool {
        guard channel.id > 1,channel.type == "anonymous",channel.encrypted,channel.is_joined != false,
              channel.is_closed != true,(channel.hide_global_at ?? 0) == 0,
              let envelope = channel.channel_key_enc,
              let actual = try? ChatContentCrypto.decodeBase64(envelope),let expected = try? ChatContentCrypto.decodeBase64(ownerEnvelope) else { return false }
        return actual == expected
    }
    private static func publicKey(_ user:ChatUser) throws -> Data {
        guard user.canStartConversation,user.user_id > 0,let raw = user.user_props?.key_pair?.public_key else { throw ChatCryptoError.invalidKey }
        let key = try ChatContentCrypto.decodeBase64(raw);guard key.count == 32 else { throw ChatCryptoError.invalidKey };return key
    }
    private static func fingerprint(_ pair:ChatEncryptionKeyPair) throws -> String {
        digest(try JSONEncoder().encode([ChatContentCrypto.decodeBase64(pair.public_key).base64EncodedString(),ChatContentCrypto.decodeBase64(pair.private_key_enc).base64EncodedString()]))
    }
    private static func digest(_ value:Data)->String { SHA256.hash(data:value).map { String(format:"%02x",$0) }.joined() }
}
