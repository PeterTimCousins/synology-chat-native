import Foundation

/// Durable action identity only. Webhook tokens, callbacks, names, triggers and
/// configuration drafts never belong in this receipt. Loading it never retries.
struct ChatWebhookActionIntent:ChatAccountActionRecord {
    enum Operation:String,Codable,CaseIterable { case create,edit,rotate,remove }
    static let journalFolder = "webhook-action-recovery"
    let operation:Operation
    let kind:ChatWebhookKind
    var webhookID:Int64?
    let previousTokenFingerprint:String?
    let operationID:UUID
    var id:String { operation == .create ? "create:" + kind.rawValue : "webhook:\(webhookID ?? 0)" }
    var recoveryLockKeys:[String] {
        if operation == .create,let webhookID { return [id,"webhook:\(webhookID)"] }
        return [id]
    }

    init(operation:Operation,kind:ChatWebhookKind,webhookID:Int64? = nil,previousTokenFingerprint:String? = nil,operationID:UUID = UUID()) throws {
        self.operation = operation;self.kind = kind;self.webhookID = webhookID
        self.previousTokenFingerprint = previousTokenFingerprint;self.operationID = operationID
        try validate()
    }
    func validate() throws {
        switch operation {
        case .create:
            guard webhookID.map({ $0 > 1 }) ?? true,previousTokenFingerprint == nil else { throw ChatAPIError.invalidResponse }
        case .edit,.remove:
            guard let webhookID,webhookID > 1,previousTokenFingerprint == nil else { throw ChatAPIError.invalidResponse }
        case .rotate:
            guard let webhookID,webhookID > 1,let fingerprint = previousTokenFingerprint,
                  fingerprint.utf8.count == 64,
                  fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ChatAPIError.invalidResponse }
        }
    }
    func withCreatedID(_ value:Int64) throws -> Self {
        try validate()
        guard operation == .create,webhookID == nil || webhookID == value else { throw ChatAPIError.invalidResponse }
        return try .init(operation:operation,kind:kind,webhookID:value,operationID:operationID)
    }
    func conflicts(with other:Self)->Bool {
        id == other.id || (webhookID != nil && webhookID == other.webhookID)
    }
}

typealias ChatWebhookActionJournal = ChatAccountActionJournal<ChatWebhookActionIntent>
