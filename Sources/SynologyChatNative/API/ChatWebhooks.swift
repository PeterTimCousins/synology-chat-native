import Foundation
import CryptoKit

enum ChatWebhookKind: String, Codable, CaseIterable, Identifiable {
    case incoming, outgoing
    var id: String { rawValue }
    var title: String { self == .incoming ? "Incoming" : "Outgoing" }
    var api: String { "SYNO.Chat.Webhook." + title }
}
struct ChatWebhookSecret: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String
    init(_ value: String) { self.value = value }
    func reveal() -> String { value }
    var fingerprint: String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    var description: String { "[Webhook credential]" }
    var debugDescription: String { description }
}
struct ChatWebhookSummary: Decodable, Identifiable {
    let user_id: Int64
    let creator_id: Int64?
    let nickname: String
    let type: String?
    let bot_type: String?
    let channel_id: Int64?
    let is_disabled: Bool?
    let deleted: Bool?
    let delete_at: Double?
    let app_id: ChatJSON?
    var id: Int64 { user_id }
    var kind: ChatWebhookKind? { type == "bot" ? bot_type.flatMap(ChatWebhookKind.init(rawValue:)) : nil }
    var isDeleted: Bool { deleted == true || (delete_at ?? 0) > 0 }
    var appManaged: Bool {
        switch app_id { case nil, .null, .string(""), .integer(0), .bool(false): return false; default: return true }
    }
    func editable(by owner: Int64) -> Bool { id > 1 && creator_id == owner && kind != nil && !isDeleted && !appManaged }
}
struct ChatWebhookDetail: Decodable, CustomDebugStringConvertible {
    let user_id: Int64
    let creator_id: Int64?
    let bot_type: String?
    let nickname: String
    let is_disabled: Bool
    let channel_id: Int64
    let trigger_word: String?
    private let credential: String?
    private let callback: String?
    enum CodingKeys: String, CodingKey { case user_id, creator_id, bot_type, nickname, is_disabled, channel_id, trigger_word, token, url }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user_id = try c.decode(Int64.self, forKey: .user_id); creator_id = try c.decodeIfPresent(Int64.self, forKey: .creator_id)
        bot_type = try c.decodeIfPresent(String.self, forKey: .bot_type); nickname = try c.decode(String.self, forKey: .nickname)
        is_disabled = try c.decode(Bool.self, forKey: .is_disabled); channel_id = try c.decode(Int64.self, forKey: .channel_id)
        trigger_word = try c.decodeIfPresent(String.self, forKey: .trigger_word)
        credential = try c.decodeIfPresent(String.self, forKey: .token); callback = try c.decodeIfPresent(String.self, forKey: .url)
    }
    var token: ChatWebhookSecret? { credential.flatMap { $0.isEmpty ? nil : ChatWebhookSecret($0) } }
    var callbackURL: String { callback ?? "" }
    var debugDescription: String { "Webhook \(user_id) [credentials and callback redacted]" }
    func sameConfiguration(as other: Self, includeToken: Bool = true) -> Bool {
        user_id == other.user_id && creator_id == other.creator_id && bot_type == other.bot_type && nickname == other.nickname
        && is_disabled == other.is_disabled && channel_id == other.channel_id && (trigger_word ?? "") == (other.trigger_word ?? "")
        && callbackURL == other.callbackURL && (!includeToken || token == other.token)
    }
}
struct ChatWebhookDraft: Equatable, CustomDebugStringConvertible {
    var nickname = ""
    var enabled = false
    var channelID: Int64 = 0
    var triggerWord = ""
    var callbackURL = ""
    init() { }
    init(_ value: ChatWebhookDetail) { nickname = value.nickname; enabled = !value.is_disabled; channelID = value.channel_id; triggerWord = value.trigger_word ?? ""; callbackURL = value.callbackURL }
    var normalized: Self { var v = self; v.nickname = v.nickname.trimmingCharacters(in: .whitespacesAndNewlines); v.triggerWord = v.triggerWord.trimmingCharacters(in: .whitespacesAndNewlines); return v }
    var debugDescription: String { "Webhook draft [callback redacted]" }
    func matches(_ value: ChatWebhookDetail, kind: ChatWebhookKind) -> Bool {
        let v = normalized
        return value.nickname == v.nickname && value.is_disabled == !v.enabled && value.channel_id == v.channelID
        && (kind == .incoming || ((value.trigger_word ?? "") == v.triggerWord && value.callbackURL == v.callbackURL))
    }
    func detailsMatch(_ value: ChatWebhookDetail, kind: ChatWebhookKind) -> Bool {
        let v = normalized
        return value.channel_id == v.channelID && (kind == .incoming || ((value.trigger_word ?? "") == v.triggerWord && value.callbackURL == v.callbackURL))
    }
    func validate(kind: ChatWebhookKind, channels: [ChatChannel], original: ChatWebhookDetail? = nil) throws {
        let v = normalized
        if let original, !v.enabled {
            var disabled = ChatWebhookDraft(original); disabled.enabled = false
            if v == disabled { return } // An invalid/unavailable old binding can always be disabled.
        }
        guard !v.nickname.isEmpty, v.nickname.utf16.count <= 32, !v.nickname.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ChatTransferError(message: "Use an integration name of 1–32 characters.") }
        guard v.channelID == 0 && kind == .outgoing || channels.contains(where: { $0.id == v.channelID && $0.webhookEligible }) else { throw ChatTransferError(message: "Choose an available, unencrypted conversation or channel.") }
        if kind == .outgoing {
            guard v.channelID != 0 || !v.triggerWord.isEmpty else { throw ChatTransferError(message: "A trigger word is required for Any channel.") }
            guard let url = URLComponents(string: v.callbackURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
                  url.fragment == nil, !(url.queryItems ?? []).contains(where: { ["_sid", "synotoken"].contains($0.name.lowercased()) }) else { throw ChatTransferError(message: "Use a complete HTTP or HTTPS callback URL without Synology session credentials or a fragment.") }
        }
    }
}
extension ChatChannel { var webhookEligible: Bool { id > 0 && !encrypted && is_closed != true && (hide_global_at ?? 0) == 0 && (["public", "private", "anonymous", "synobot"].contains(type)) } }
struct ChatWebhookCatalogue {
    let entries: [ChatWebhookSummary]
    let channels: [ChatChannel]
    let ownerID: Int64
    let canCreate: Bool
    let accountGeneration: Int
}
struct ChatWebhookSnapshot {
    let detail: ChatWebhookDetail
    let kind: ChatWebhookKind
    let catalogue: ChatWebhookCatalogue
}
struct ChatWebhookFailure: LocalizedError {
    let uncertain: Bool
    let message: String
    var errorDescription: String? { message }
}
extension ChatAPIClient {
    func webhookSummaries() async throws -> [ChatWebhookSummary] {
        struct Response: Decodable { let users: [ChatWebhookSummary] }
        let value: Response = try await perform(requestForCall(api: "SYNO.Chat.User", method: "list", version: 2))
        guard Set(value.users.map(\.id)).count == value.users.count else { throw ChatAPIError.invalidResponse }
        return value.users.filter { $0.kind != nil }
    }
    func webhookDetail(kind: ChatWebhookKind, id: Int64) async throws -> ChatWebhookDetail {
        guard id > 1 else { throw ChatAPIError.invalidResponse }
        return try await perform(requestForCall(api: kind.api, method: "get", version: 1, parameters: ["user_id": .integer(id)]))
    }
    func createWebhook(kind: ChatWebhookKind) async throws -> Int64 {
        struct Created: Decodable { let user_id: Int64 }
        let value: Created = try await perform(requestForCall(api: kind.api, method: "create", version: 1))
        guard value.user_id > 1 else { throw ChatAPIError.invalidResponse }; return value.user_id
    }
}
