import Foundation
import CryptoKit

/// An in-memory wire plan. It retains recipient-sealed envelopes, never the
/// plaintext channel key, recipient private keys or an encryption password.
struct ChatEncryptedChannelInvitation {
    struct Recipient {
        let id:Int64
        let username:String?
        let nickname:String
        let publicKeyDigest:String
        let wrappedKey:String
    }
    let channelID:Int64
    let ownerEnvelopeDigest:String
    let recipients:[Recipient]
    var userIDs:[Int64] { recipients.map(\.id) }
    var envelopes:[String] { recipients.map(\.wrappedKey) }

    init(channel:ChatChannel,recipients users:[ChatUser],encryption:ChatEncryptionSession) throws {
        guard Self.supports(channel),!users.isEmpty,Set(users.map(\.user_id)).count == users.count,
              let envelope = channel.channel_key_enc,!envelope.isEmpty else { throw ChatAPIError.invalidResponse }
        let key = try encryption.key(for:channel)
        channelID = channel.id;ownerEnvelopeDigest = Self.digest(try ChatContentCrypto.decodeBase64(envelope))
        recipients = try users.sorted { $0.user_id < $1.user_id }.map { user in
            let publicKey = try Self.publicKey(user)
            return Recipient(id:user.user_id,username:user.username,nickname:user.nickname,publicKeyDigest:Self.digest(publicKey),
                             wrappedKey:try ChatContentCrypto.wrapChannelKey(key,publicKey:publicKey))
        }
        try validate(channel:channel,users:users)
    }
    /// Call with freshly read channel and people immediately before dispatch.
    /// ACL, membership, account generation, key epoch and uncertainty guards are
    /// the account coordinator's responsibility, not inferred by this wire plan.
    func validate(channel:ChatChannel,users:[ChatUser]) throws {
        guard Self.supports(channel),channel.id == channelID,let envelope = channel.channel_key_enc,
              Self.digest(try ChatContentCrypto.decodeBase64(envelope)) == ownerEnvelopeDigest,
              !recipients.isEmpty,Set(userIDs).count == userIDs.count,userIDs == userIDs.sorted(),
              Set(users.map(\.user_id)).count == users.count else { throw ChatAPIError.invalidResponse }
        for recipient in recipients {
            guard let user = users.first(where:{ $0.user_id == recipient.id }),user.username == recipient.username,user.nickname == recipient.nickname,
                  Self.digest(try Self.publicKey(user)) == recipient.publicKeyDigest,
                  try ChatContentCrypto.decodeBase64(recipient.wrappedKey).count == 92 else {
                throw ChatTransferError(message:"An invitation recipient or encryption key changed. Refresh and review the people before inviting them.")
            }
        }
    }
    static func supports(_ channel:ChatChannel) -> Bool {
        channel.id > 1 && channel.type == "private" && channel.encrypted && channel.is_joined == true
            && channel.is_closed != true && (channel.hide_global_at ?? 0) == 0
    }
    static func hasUsablePublicKey(_ user:ChatUser) -> Bool { (try? publicKey(user)) != nil }
    private static func publicKey(_ user:ChatUser) throws -> Data {
        guard user.user_id > 0,user.canStartConversation,let raw = user.user_props?.key_pair?.public_key else { throw ChatCryptoError.invalidKey }
        let key = try ChatContentCrypto.decodeBase64(raw)
        guard key.count == 32 else { throw ChatCryptoError.invalidKey };return key
    }
    private static func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}
