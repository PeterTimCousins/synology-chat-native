import Foundation
import CryptoKit

/// Durable uncertainty identity only. Callback values and card/button text never
/// enter this receipt, and restoring it must never dispatch an integration action.
struct ChatBotActionIntent: ChatAccountActionRecord {
    static let journalFolder = "BotActions"
    var id: Int64 { postID }
    let postID: Int64
    let channelID: Int64
    let creatorID: Int64
    let threadID: Int64
    let attachmentIndex: Int
    let actionIndex: Int
    let attachmentFingerprint: String
    let operationID: UUID

    init(post: ChatPost, selection: ChatBotActionSelection, operationID: UUID = UUID()) throws {
        guard selection.matches(post) else { throw ChatAPIError.invalidResponse }
        _ = try selection.payload()
        postID = post.id; channelID = post.channel_id; creatorID = post.creator_id
        threadID = post.isReply ? (post.thread_id ?? 0) : 0
        attachmentIndex = selection.attachmentIndex; actionIndex = selection.actionIndex
        attachmentFingerprint = try Self.fingerprint(selection.attachment)
        self.operationID = operationID
        try validate()
    }
    func validate() throws {
        guard postID > 0, channelID > 0, creatorID > 0, threadID >= 0,
              threadID == 0 || threadID != postID,
              (0..<100).contains(attachmentIndex), (0..<100).contains(actionIndex),
              attachmentFingerprint.utf8.count == 64,
              attachmentFingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ChatAPIError.invalidResponse
        }
    }
    func matches(_ post: ChatPost) -> Bool {
        guard (try? validate()) != nil,
              post.id == postID, post.channel_id == channelID, post.creator_id == creatorID,
              (post.isReply ? (post.thread_id ?? 0) : 0) == threadID,
              let cards = post.props?.attachments, cards.indices.contains(attachmentIndex) else { return false }
        let selection = ChatBotActionSelection(attachmentIndex: attachmentIndex, actionIndex: actionIndex, attachment: cards[attachmentIndex])
        return (try? selection.payload()) != nil && (try? Self.fingerprint(selection.attachment)) == attachmentFingerprint
    }
    private static func fingerprint(_ attachment: ChatJSON) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(attachment)).map { String(format: "%02x", $0) }.joined()
    }
}

typealias ChatBotActionJournal = ChatAccountActionJournal<ChatBotActionIntent>
