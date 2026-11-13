import Foundation
import CryptoKit

extension ChatChannel {
    var supportsMemberInvitation:Bool {
        id > 1 && ["public","private"].contains(type) && is_joined != false && is_closed != true && (hide_global_at ?? 0) == 0
            && (!encrypted || ChatEncryptedChannelInvitation.supports(self))
    }
    func sameInvitationScope(as other:ChatChannel) -> Bool {
        guard id == other.id,type == other.type,encrypted == other.encrypted,supportsMemberInvitation,other.supportsMemberInvitation else { return false }
        if !encrypted { return true }
        guard let a = channel_key_enc.flatMap({ try? ChatContentCrypto.decodeBase64($0) }),let b = other.channel_key_enc.flatMap({ try? ChatContentCrypto.decodeBase64($0) }) else { return false }
        return a == b
    }
}

struct ChatChannelInvitationSnapshot {
    let channel:ChatChannel
    let users:[ChatUser]
    let members:Set<Int64>
    let ownerID:Int64
    let ownerKeys:ChatEncryptionOwnerState?
    let accountGeneration:Int
    let keyGeneration:Int
}

/// Only destination IDs and a scope fingerprint survive restart. No names,
/// public/private keys, channel-key envelopes, passwords or message data.
struct ChatChannelInvitationIntent:ChatAccountActionRecord {
    static let journalFolder = "ChannelInvitations"
    var id:Int64 { channelID }
    let channelID:Int64
    let channelType:String
    let encrypted:Bool
    let envelopeDigest:String?
    let members:[Int64]
    let operationID:UUID
    let createdAt:Double
    init(channel:ChatChannel,members:Set<Int64>) throws {
        guard channel.supportsMemberInvitation else { throw ChatAPIError.invalidResponse }
        channelID = channel.id;channelType = channel.type;encrypted = channel.encrypted
        envelopeDigest = try Self.envelopeDigest(channel)
        self.members = members.sorted();operationID = UUID();createdAt = Date().timeIntervalSince1970
        try validate()
    }
    func validate() throws {
        guard channelID > 1,["public","private"].contains(channelType),!encrypted || channelType == "private",
              !members.isEmpty,members == members.sorted(),Set(members).count == members.count,members.allSatisfy({ $0 > 0 }),
              createdAt.isFinite,createdAt > 0,createdAt < Date.distantFuture.timeIntervalSince1970,
              encrypted ? envelopeDigest?.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil : envelopeDigest == nil else { throw ChatAPIError.invalidResponse }
    }
    func matches(_ channel:ChatChannel) -> Bool {
        channel.id == channelID && channel.type == channelType && channel.encrypted == encrypted
            && channel.supportsMemberInvitation && (try? Self.envelopeDigest(channel)) == envelopeDigest
    }
    func matchesExactly(_ channels:[ChatChannel]) -> Bool {
        let found = channels.filter { $0.id == channelID }
        return found.count == 1 && matches(found[0])
    }
    private static func envelopeDigest(_ channel:ChatChannel) throws -> String? {
        guard channel.encrypted else { return nil }
        guard let raw = channel.channel_key_enc else { throw ChatCryptoError.invalidKey }
        let bytes = try ChatContentCrypto.decodeBase64(raw)
        guard bytes.count == 92 else { throw ChatCryptoError.invalidKey }
        return SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
    }
}
typealias ChatChannelInvitationJournal = ChatAccountActionJournal<ChatChannelInvitationIntent>

struct ChatChannelInvitationFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}
