import Foundation
import CryptoKit

/// Durable uncertainty receipt: no scheduled message text is retained.
struct ChatScheduledCreationIntent:ChatAccountActionRecord {
    static let journalFolder = "ScheduledCreations"
    let operationID:UUID
    let channelID:Int64
    let createdAt:Double
    let messageFingerprint:String
    let sendAt:Int64
    let beforeMatchingJobIDs:[Int64]
    private(set) var acknowledgedID:Int64?
    var id:String { "create:\(channelID)" }

    init(channelID:Int64,message:String,sendAt:Int64,before:[ChatScheduledMessage],now:Date = Date()) throws {
        guard ChatMessageText.isAllowed(message),!message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              Set(before.map(\.id)).count == before.count else { throw ChatAPIError.invalidResponse }
        try before.forEach { try $0.validate() }
        operationID = UUID();self.channelID = channelID;createdAt = now.timeIntervalSince1970
        let fingerprint = Self.fingerprint(message)
        messageFingerprint = fingerprint;self.sendAt = sendAt;acknowledgedID = nil
        beforeMatchingJobIDs = before.filter { $0.send_at == Double(sendAt) && Self.fingerprint($0.message) == fingerprint }.map(\.id).sorted()
        try validate()
    }
    func validate() throws {
        guard channelID > 0,createdAt.isFinite,createdAt > 0,createdAt < Date.distantFuture.timeIntervalSince1970,
              sendAt > 0,sendAt < 253402300800000,
              messageFingerprint.utf8.count == 64,messageFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              beforeMatchingJobIDs.count <= 128,beforeMatchingJobIDs == beforeMatchingJobIDs.sorted(),
              Set(beforeMatchingJobIDs).count == beforeMatchingJobIDs.count,beforeMatchingJobIDs.allSatisfy({ $0 > 0 }),
              acknowledgedID == nil || (acknowledgedID! > 0 && !beforeMatchingJobIDs.contains(acknowledgedID!)) else { throw ChatAPIError.invalidResponse }
    }
    func acknowledging(_ id:Int64) throws -> Self {
        guard acknowledgedID == nil || acknowledgedID == id else { throw ChatAPIError.invalidResponse }
        var result = self;result.acknowledgedID = id;try result.validate();return result
    }
    func matches(_ job:ChatScheduledMessage) -> Bool {
        (try? job.validate()) != nil && job.send_at == Double(sendAt) && Self.fingerprint(job.message) == messageFingerprint
    }
    func candidates(in jobs:[ChatScheduledMessage]) -> [ChatScheduledMessage] {
        jobs.filter { !beforeMatchingJobIDs.contains($0.id) && matches($0) }.sorted { $0.id < $1.id }
    }
    private static func fingerprint(_ text:String) -> String {
        SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined()
    }
}
typealias ChatScheduledCreationJournal = ChatAccountActionJournal<ChatScheduledCreationIntent>
