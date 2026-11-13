import Foundation

/// Destination IDs, attempt time and an invocation hash survive restart; no arguments,
/// integration URL, credentials or response text enter this recovery record.
struct ChatSlashActionIntent:ChatAccountActionRecord {
    static let journalFolder = "SlashActions"
    var id:String { invocationFingerprint }
    let channelID:Int64
    let commandUserID:Int64
    let invocationFingerprint:String
    let operationID:UUID
    let createdAt:Double
    init(channelID:Int64,command:ChatSlashCommand,message:String,operationID:UUID = UUID(),createdAt:Date = Date()) throws {
        guard case .server(let userID) = command.kind,ChatSlashSyntax.name(message) == command.name,ChatMessageText.isAllowed(message) else { throw ChatAPIError.invalidResponse }
        self.channelID = channelID;commandUserID = userID
        invocationFingerprint = ChatSlashSyntax.invocationKey(channelID:channelID,command:command,message:message)
        self.operationID = operationID;self.createdAt = createdAt.timeIntervalSince1970
        try validate()
    }
    func validate() throws {
        guard channelID > 0,commandUserID > 0,createdAt.isFinite,createdAt > 0,createdAt < Date.distantFuture.timeIntervalSince1970,invocationFingerprint.utf8.count == 64,invocationFingerprint.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else { throw ChatAPIError.invalidResponse }
    }
}
typealias ChatSlashActionJournal = ChatAccountActionJournal<ChatSlashActionIntent>
