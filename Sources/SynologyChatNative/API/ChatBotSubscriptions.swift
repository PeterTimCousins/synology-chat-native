import Foundation

struct ChatBotSummary: Decodable, Equatable, Identifiable {
    struct Properties: Decodable, Equatable {
        let hide_from_user: Bool
        let purpose: String
        let welcome_note: String
    }
    let user_id: Int64
    let nickname: String
    let type: String?
    let bot_type: String?
    let is_disabled: Bool?
    let delete_at: Double?
    let deleted: Bool?
    let chatbot_props: Properties?
    var id: Int64 { user_id }
    var available: Bool { id > 1 && type == "bot" && bot_type == "chatbot" && !nickname.isEmpty && is_disabled != true && (delete_at ?? 0) == 0 && deleted != true && chatbot_props != nil }
    enum CodingKeys: String, CodingKey { case user_id, nickname, type, bot_type, is_disabled, delete_at, deleted, chatbot_props }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user_id = try c.decode(Int64.self, forKey: .user_id); nickname = try c.decode(String.self, forKey: .nickname)
        type = try c.decodeIfPresent(String.self, forKey: .type); bot_type = try c.decodeIfPresent(String.self, forKey: .bot_type)
        is_disabled = try c.decodeIfPresent(Bool.self, forKey: .is_disabled); delete_at = try c.decodeIfPresent(Double.self, forKey: .delete_at)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted); chatbot_props = try? c.decode(Properties.self, forKey: .chatbot_props)
    }
}
struct ChatBotEntry: Identifiable, Equatable {
    let bot: ChatBotSummary
    let channel: ChatChannel?
    let blocked: Bool
    var id: Int64 { bot.id }
    var subscribed: Bool { !blocked && channel?.is_joined == true && channel?.is_closed != true && (channel?.hide_global_at ?? 0) == 0 }
}
struct ChatBotCatalogue {
    let entries: [ChatBotEntry]
    let joinedChannels: [ChatChannel]
    let blockedIDs: Set<Int64>
    let ownerID: Int64
    let accountGeneration: Int
    static func entries(users: [ChatBotSummary], channels: [ChatChannel], blockedIDs: Set<Int64>) throws -> [ChatBotEntry] {
        guard Set(users.map(\.id)).count == users.count, Set(channels.map(\.id)).count == channels.count else { throw ChatAPIError.invalidResponse }
        let bots = channels.filter { $0.type == "chatbot" }
        guard bots.allSatisfy({ $0.id > 0 && ($0.creator_id ?? 0) > 1 && !$0.encrypted }), Set(bots.compactMap(\.creator_id)).count == bots.count else { throw ChatAPIError.invalidResponse }
        return users.filter(\.available).compactMap { bot -> ChatBotEntry? in
            let channel = bots.first { $0.creator_id == bot.id }
            guard bot.chatbot_props?.hide_from_user == false || channel != nil else { return nil }
            return .init(bot: bot, channel: channel, blocked: blockedIDs.contains(bot.id))
        }.sorted { $0.bot.nickname.localizedCaseInsensitiveCompare($1.bot.nickname) == .orderedAscending }
    }
}
struct ChatBotSubscriptionIntent: ChatAccountActionRecord {
    static var journalFolder: String { "BotSubscriptions" }
    let botID: Int64
    let blocked: Bool
    let priorChannelID: Int64?
    let operationID: UUID
    var id: Int64 { botID }
    init(botID: Int64, blocked: Bool, priorChannelID: Int64?) { self.botID = botID; self.blocked = blocked; self.priorChannelID = priorChannelID; operationID = UUID() }
    func validate() throws { guard botID > 1, priorChannelID == nil || priorChannelID! > 0 else { throw ChatAPIError.invalidResponse } }
    func isConfirmed(in catalogue: ChatBotCatalogue) -> Bool {
        if blocked { return catalogue.blockedIDs.contains(botID) }
        return catalogue.entries.contains { $0.id == botID && $0.subscribed }
    }
}
extension ChatAPIClient {
    func chatbotSummaries() async throws -> [ChatBotSummary] {
        struct Response: Decodable { let users: [ChatBotSummary] }
        let value: Response = try await perform(requestForCall(api: "SYNO.Chat.User", method: "list", version: 2))
        guard Set(value.users.map(\.id)).count == value.users.count else { throw ChatAPIError.invalidResponse }
        return value.users.filter { $0.type == "bot" && $0.bot_type == "chatbot" }
    }
    func blockedChatbotIDs() async throws -> Set<Int64> {
        struct Response: Decodable { let blocked_user_ids: [Int64] }
        let value: Response = try await perform(requestForCall(api: "SYNO.Chat.Channel.Chatbot", method: "list_blocked", version: 1))
        guard value.blocked_user_ids.allSatisfy({ $0 > 1 }), Set(value.blocked_user_ids).count == value.blocked_user_ids.count else { throw ChatAPIError.invalidResponse }
        return Set(value.blocked_user_ids)
    }
    func initiateChatbot(userID: Int64) async throws -> ChatChannel {
        guard userID > 1 else { throw ChatAPIError.invalidResponse }
        let channel: ChatChannel = try await perform(requestForCall(api: "SYNO.Chat.Channel.Chatbot", method: "initiate", version: 1, parameters: ["user_id": .integer(userID)]))
        guard channel.id > 0, channel.type == "chatbot", channel.creator_id == userID, !channel.encrypted, channel.is_closed != true else { throw ChatAPIError.invalidResponse }
        return channel
    }
}
