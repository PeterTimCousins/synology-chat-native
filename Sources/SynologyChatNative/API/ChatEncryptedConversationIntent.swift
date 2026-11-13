import Foundation
import CryptoKit

/// Durable uncertainty metadata, never an instruction to replay initiation.
/// Only IDs, key fingerprints and the creator-sealed ciphertext are retained.
struct ChatEncryptedConversationIntent:ChatAccountActionRecord {
    static let journalFolder = "EncryptedConversationStarts"
    struct Participant:Codable,Equatable {
        let id:Int64
        let publicKeyDigest:String
    }
    let id:UUID
    let ownerID:Int64
    let participants:[Participant]
    let creatorEnvelope:String
    let createdAt:Double
    private(set) var candidateChannelID:Int64?
    var memberIDs:[Int64] { participants.map(\.id) }

    init(plan:ChatEncryptedConversationStart,owner:ChatEncryptionKeyPair) throws {
        id = UUID();ownerID = plan.ownerID
        participants = plan.participants.map { .init(id:$0.id,publicKeyDigest:$0.publicKeyDigest) }
        creatorEnvelope = plan.ownerEnvelope;createdAt = Date().timeIntervalSince1970;candidateChannelID = nil
        try validate();guard matchesOwner(owner) else { throw ChatCryptoError.invalidKey }
    }
    func validate() throws {
        guard ownerID > 0,participants.count >= 2,memberIDs == memberIDs.sorted(),Set(memberIDs).count == memberIDs.count,
              memberIDs.allSatisfy({ $0 > 0 }),memberIDs.contains(ownerID),
              participants.allSatisfy({ $0.publicKeyDigest.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil }),
              creatorEnvelope.utf8.count <= 256,try ChatContentCrypto.decodeBase64(creatorEnvelope).count == 92,
              candidateChannelID == nil || candidateChannelID! > 0,
              createdAt.isFinite,createdAt > 0,createdAt < Date.distantFuture.timeIntervalSince1970 else { throw ChatAPIError.invalidResponse }
    }
    func recordingCandidate(_ value:Int64) throws -> Self {
        guard candidateChannelID == nil || candidateChannelID == value else { throw ChatAPIError.invalidResponse }
        var result = self;result.candidateChannelID = value;try result.validate();return result
    }
    func matchesOwner(_ pair:ChatEncryptionKeyPair)->Bool {
        guard pair.isInitialized,let bytes = try? ChatContentCrypto.decodeBase64(pair.public_key),bytes.count == 32 else { return false }
        return participants.first { $0.id == ownerID }?.publicKeyDigest == Self.digest(bytes)
    }
    func matchesReviewedKeys(_ users:[ChatUser])->Bool {
        guard Set(users.map(\.user_id)).count == users.count else { return false }
        return participants.allSatisfy { participant in
            guard let user = users.first(where:{ $0.user_id == participant.id }),user.canStartConversation,
                  let raw = user.user_props?.key_pair?.public_key,let bytes = try? ChatContentCrypto.decodeBase64(raw),bytes.count == 32 else { return false }
            return Self.digest(bytes) == participant.publicKeyDigest
        }
    }
    func matchesPlannedEnvelope(_ channel:ChatChannel)->Bool {
        guard let raw = channel.channel_key_enc,let actual = try? ChatContentCrypto.decodeBase64(raw),let expected = try? ChatContentCrypto.decodeBase64(creatorEnvelope) else { return false }
        return actual == expected
    }
    private static func digest(_ bytes:Data)->String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
}
typealias ChatEncryptedConversationJournal = ChatAccountActionJournal<ChatEncryptedConversationIntent>

struct ChatEncryptedConversationOpenReview {
    let intent:ChatEncryptedConversationIntent
    let channel:ChatChannel
    let accountGeneration:Int
    let keyGeneration:Int
    let requiresExistingReview:Bool
    let participants:[ChatUser]
}

/// Pure read-only classification of fresh canonical observations. It cannot
/// issue requests, clear receipts, choose account scope or publish a channel.
enum ChatEncryptedConversationRecovery {
    struct Snapshot { let channel:ChatChannel;let memberIDs:[Int64]? }
    enum Status:Equatable { case pending,ambiguous,changedKeys,unverified,needsUnlock,verified,existingNeedsReview }
    struct Result:Equatable { let status:Status;let candidateChannelID:Int64? }
    static func evaluate(_ intent:ChatEncryptedConversationIntent,owner:ChatEncryptionKeyPair,users:[ChatUser],snapshots:[Snapshot],encryption:ChatEncryptionSession)->Result {
        guard (try? intent.validate()) != nil,intent.matchesOwner(owner),intent.matchesReviewedKeys(users) else { return .init(status:.changedKeys,candidateChannelID:intent.candidateChannelID) }
        let candidates = snapshots.filter { snapshot in
            if let id = intent.candidateChannelID { return snapshot.channel.id == id }
            return intent.matchesPlannedEnvelope(snapshot.channel)
        }
        guard candidates.count == 1 else { return .init(status:candidates.isEmpty ? .pending : .ambiguous,candidateChannelID:intent.candidateChannelID) }
        let candidate = candidates[0],channel = candidate.channel
        guard channel.id > 1,channel.type == "anonymous",channel.encrypted,channel.is_joined == true,
              channel.is_closed != true,(channel.hide_global_at ?? 0) == 0,
              let members = candidate.memberIDs,members.count == intent.memberIDs.count,
              Set(members).count == members.count,members.sorted() == intent.memberIDs else { return .init(status:.unverified,candidateChannelID:channel.id) }
        guard encryption.matchesUnlockedPublicKey(owner.public_key) else { return .init(status:.needsUnlock,candidateChannelID:channel.id) }
        guard let envelope = channel.channel_key_enc,(try? encryption.validateChannelEnvelope(envelope)) != nil else { return .init(status:.unverified,candidateChannelID:channel.id) }
        // A known response may identify a concurrently reused conversation.
        // Do not confuse its different key with proof that this request created it.
        return .init(status:intent.matchesPlannedEnvelope(channel) ? .verified : .existingNeedsReview,candidateChannelID:channel.id)
    }
}
