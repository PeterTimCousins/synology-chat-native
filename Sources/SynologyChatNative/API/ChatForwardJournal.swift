import Foundation
import CryptoKit

/// IDs and a content fingerprint only; never persist forwarded text or filenames.
struct ChatForwardIntent:ChatAccountActionRecord {
    static let journalFolder = "Forwards"
    let sourceID:Int64
    let sourceChannelID:Int64
    let sourceThreadID:Int64
    let targets:[Int64]
    let previousIDs:[String:[Int64]]
    let previousNewestAt:[String:Double]
    let fingerprint:String
    let operationID:UUID
    let createdAt:Double
    var id:String { Self.hash([String(sourceChannelID),String(sourceID)] + targets.map(String.init)) }
    init(source:ChatPost,targets:[Int64],previous:[Int64:Set<Int64>],newestAt:[Int64:Double]) throws {
        sourceID = source.id;sourceChannelID = source.channel_id;sourceThreadID = source.isReply ? source.thread_id ?? 0 : 0
        self.targets = targets.sorted();previousIDs = Dictionary(uniqueKeysWithValues:targets.map { (String($0),(previous[$0] ?? []).sorted()) })
        previousNewestAt = Dictionary(uniqueKeysWithValues:targets.map { (String($0),newestAt[$0] ?? 0) })
        fingerprint = Self.contentFingerprint(source);operationID = UUID();createdAt = Date().timeIntervalSince1970
        try validate()
    }
    static func contentFingerprint(_ post:ChatPost) -> String {
        let origin = post.props?.forward
        let parts:[String] = ["v1",String(post.id),String(post.channel_id),String(post.creator_id),String(post.thread_id ?? 0),post.type,post.message,
            post.update_at.map { String($0) } ?? "nil",post.file_props?.name ?? "",post.file_props?.size.map { String($0) } ?? "nil",
            origin.map { String($0.origin_post_id) } ?? "nil",origin.map { String($0.origin_channel_id) } ?? "nil",origin.map { String($0.origin_user_id) } ?? "nil",
            origin?.origin_thread_id.map { String($0) } ?? "nil",origin?.origin_create_at.map { String($0) } ?? "nil",origin?.type ?? "nil"]
        return hash(parts)
    }
    private static func hash(_ parts:[String]) -> String {
        // Length-prefix components so content containing separators cannot alias.
        let value = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    func newerThanBaseline(_ post:ChatPost) -> Bool {
        guard let cutoff = previousNewestAt[String(post.channel_id)] else { return false }
        // An older copy can reappear after intervening history is deleted. IDs
        // absent from the recent baseline alone cannot establish a new delivery.
        return post.create_at.isFinite && post.create_at > cutoff && post.create_at < 253402300800000
    }
    func validate() throws {
        guard sourceID > 0,sourceChannelID > 0,sourceThreadID >= 0,targets.count > 0,targets.count <= 20,
              targets == targets.sorted(),Set(targets).count == targets.count,targets.allSatisfy({ $0 > 0 }),
              Set(previousIDs.keys) == Set(targets.map(String.init)),previousIDs.values.allSatisfy({ ids in ids.count <= 1000 && ids == ids.sorted() && Set(ids).count == ids.count && ids.allSatisfy({ $0 > 0 }) }),
              Set(previousNewestAt.keys) == Set(targets.map(String.init)),previousNewestAt.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 253402300800000 }),
              fingerprint.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              createdAt.isFinite,createdAt > 0,createdAt < Date.distantFuture.timeIntervalSince1970 else { throw ChatAPIError.invalidResponse }
    }
}
typealias ChatForwardJournal = ChatAccountActionJournal<ChatForwardIntent>
