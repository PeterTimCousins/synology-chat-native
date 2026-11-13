import Foundation
import CryptoKit

/// The sealed creator envelope is needed after a crash. This is ciphertext,
/// not a plaintext channel key. Names and purpose are retained only as a hash.
struct ChatEncryptedCreationIntent:ChatAccountActionRecord {
    static let journalFolder = "EncryptedChannelCreations"
    let id:UUID
    let ownerID:Int64
    let creatorEnvelope:String
    let ownerKeyFingerprint:String
    let detailsFingerprint:String
    let createdAt:Double
    var channelID:Int64?
    var joinAttemptID:UUID?
    var lastJoinAt:Double?
    init(plan:ChatEncryptedChannelCreation,ownerID:Int64,owner:ChatEncryptionKeyPair,name:String,purpose:String) throws {
        self.id = UUID();self.ownerID = ownerID;creatorEnvelope = plan.creatorEnvelope
        ownerKeyFingerprint = Self.digest(try ChatContentCrypto.decodeBase64(owner.public_key))
        detailsFingerprint = try Self.details(name:name,purpose:purpose)
        createdAt = Date().timeIntervalSince1970;channelID = nil;joinAttemptID = nil;lastJoinAt = nil;try validate()
    }
    func validate() throws {
        guard ownerID > 0,channelID == nil || channelID! > 1,
              creatorEnvelope.utf8.count <= 256,try ChatContentCrypto.decodeBase64(creatorEnvelope).count == 92,
              [ownerKeyFingerprint,detailsFingerprint].allSatisfy({ $0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil }),
              createdAt.isFinite,createdAt > 0,createdAt < Date.distantFuture.timeIntervalSince1970,
              (joinAttemptID == nil) == (lastJoinAt == nil),
              lastJoinAt == nil || (channelID != nil && lastJoinAt!.isFinite && lastJoinAt! >= createdAt && lastJoinAt! < Date.distantFuture.timeIntervalSince1970) else { throw ChatAPIError.invalidResponse }
    }
    func withChannelID(_ value:Int64) throws -> Self {
        guard channelID == nil || channelID == value else { throw ChatAPIError.invalidResponse }
        var result = self;result.channelID = value;try result.validate();return result
    }
    func matches(_ channel:ChatChannel) -> Bool {
        guard matchesScope(channel),channel.is_joined == true,
              let raw = channel.channel_key_enc,let decoded = try? ChatContentCrypto.decodeBase64(raw),
              let expected = try? ChatContentCrypto.decodeBase64(creatorEnvelope) else { return false }
        return decoded == expected
    }
    func matchesUnjoined(_ channel:ChatChannel) -> Bool {
        matchesScope(channel) && channel.is_joined == false && (channel.channel_key_enc == nil || channel.channel_key_enc == "")
    }
    func matchesOwnerKey(_ pair:ChatEncryptionKeyPair) -> Bool {
        guard let bytes = try? ChatContentCrypto.decodeBase64(pair.public_key) else { return false }
        return Self.digest(bytes) == ownerKeyFingerprint
    }
    func recordingJoinAttempt() throws -> Self {
        guard channelID != nil else { throw ChatAPIError.invalidResponse }
        var result = self;result.joinAttemptID = UUID();result.lastJoinAt = Date().timeIntervalSince1970;try result.validate();return result
    }
    private func matchesScope(_ channel:ChatChannel) -> Bool {
        channel.id == channelID && channel.creator_id == ownerID && channel.type == "private" && channel.encrypted
            && channel.is_closed != true && (channel.hide_global_at ?? 0) == 0
            && (try? Self.details(name:channel.name,purpose:channel.purpose ?? "")) == detailsFingerprint
    }
    private static func details(name:String,purpose:String) throws -> String {
        if let error = ChatNamedChannelInput.validationError(name:name,purpose:purpose) { throw ChatTransferError(message:error) }
        return digest(try JSONEncoder().encode(["v1",name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping,purpose.precomposedStringWithCanonicalMapping]))
    }
    private static func digest(_ bytes:Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
}
typealias ChatEncryptedCreationJournal = ChatAccountActionJournal<ChatEncryptedCreationIntent>

/// Ephemeral review for one explicit join. Never persisted or restored as an action.
struct ChatEncryptedCreationJoinReview {
    let intent:ChatEncryptedCreationIntent
    let channel:ChatChannel
    let owner:ChatEncryptionKeyPair
    let accountGeneration:Int
    let keyGeneration:Int
}
