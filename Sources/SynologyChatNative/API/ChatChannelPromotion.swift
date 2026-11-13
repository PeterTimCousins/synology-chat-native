import Foundation
import CryptoKit

enum ChatChannelPromotionMode: String, Codable, CaseIterable, Identifiable {
    case convert, newChannel
    var id: String { rawValue }
    var title: String { self == .convert ? "Convert this conversation" : "Create a new private channel" }
    var detail: String {
        self == .convert ? "The existing conversation becomes a named private channel. Its messages and members stay together. This cannot be changed back here." : "A new private channel starts with the same members and no message history. This conversation and its messages stay in place."
    }
}
struct ChatChannelPromotionDraft: Equatable {
    var name = ""
    var purpose = ""
    var mode = ChatChannelPromotionMode.convert
    var normalized: Self { .init(name: name.trimmingCharacters(in: .whitespacesAndNewlines), purpose: purpose.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode) }
    func validate() throws {
        if let error = ChatNamedChannelInput.validationError(name: normalized.name, purpose: normalized.purpose) { throw ChatTransferError(message: error) }
    }
    func matches(_ channel: ChatChannel) -> Bool {
        channel.type == "private" && !channel.encrypted && channel.is_joined == true && channel.is_closed != true && (channel.hide_global_at ?? 0) == 0 && channel.name == normalized.name && (channel.purpose ?? "") == normalized.purpose
    }
}
extension ChatChannel {
    var supportsPromotion: Bool { id > 2 && type == "anonymous" && !encrypted && is_joined == true && is_closed != true && (hide_global_at ?? 0) == 0 }
}
struct ChatChannelPromotionSnapshot {
    let channel: ChatChannel
    let memberIDs: Set<Int64>
    let memberNames: [Int64: String]
    let accountGeneration: Int
}
struct ChatChannelPromotionIntent:ChatAccountActionRecord {
    static let journalFolder = "ChannelConversions"
    var id:Int64 { sourceID }
    let sourceID:Int64
    let mode:ChatChannelPromotionMode
    let memberIDs:[Int64]
    let detailsFingerprint:String
    let operationID:UUID
    let createdAt:Double
    var targetID:Int64?
    init(snapshot:ChatChannelPromotionSnapshot,draft:ChatChannelPromotionDraft) throws {
        try draft.validate()
        guard snapshot.channel.supportsPromotion else { throw ChatAPIError.invalidResponse }
        sourceID = snapshot.channel.id;mode = draft.mode;memberIDs = snapshot.memberIDs.sorted()
        detailsFingerprint = try Self.fingerprint(name:draft.normalized.name,purpose:draft.normalized.purpose)
        operationID = UUID();createdAt = Date().timeIntervalSince1970;targetID = mode == .convert ? sourceID : nil
        try validate()
    }
    func validate() throws {
        guard sourceID > 2,!memberIDs.isEmpty,memberIDs.count <= 1000,memberIDs == memberIDs.sorted(),Set(memberIDs).count == memberIDs.count,memberIDs.allSatisfy({ $0 > 0 }),
              detailsFingerprint.utf8.count == 64,detailsFingerprint.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              createdAt.isFinite,createdAt > 0,createdAt < Date.distantFuture.timeIntervalSince1970,
              mode != .convert || targetID == sourceID,
              targetID == nil || (targetID! > 2 && (mode == .convert || targetID != sourceID)) else { throw ChatAPIError.invalidResponse }
    }
    func withTarget(_ id:Int64) throws -> Self {
        guard mode == .newChannel,targetID == nil || targetID == id else { throw ChatAPIError.invalidResponse }
        var result = self;result.targetID = id;try result.validate();return result
    }
    func matches(_ channel:ChatChannel) -> Bool {
        channel.type == "private" && !channel.encrypted && channel.is_joined == true && channel.is_closed != true && (channel.hide_global_at ?? 0) == 0
            && (try? Self.fingerprint(name:channel.name,purpose:channel.purpose ?? "")) == detailsFingerprint
    }
    private static func fingerprint(name:String,purpose:String) throws -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(["v1",name.precomposedStringWithCanonicalMapping,purpose.precomposedStringWithCanonicalMapping])
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
}
typealias ChatChannelPromotionJournal = ChatAccountActionJournal<ChatChannelPromotionIntent>
struct ChatChannelPromotionAttempt {
    let intent:ChatChannelPromotionIntent
    let accountGeneration:Int
    let reviewedName:String?
    var targetID:Int64? { intent.targetID }
}
struct ChatChannelPromotionFailure: LocalizedError {
    let uncertain: Bool
    let message: String
    var errorDescription: String? { message }
}
