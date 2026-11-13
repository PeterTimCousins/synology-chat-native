import Foundation
import CryptoKit

struct ChatQuickSwitchEntry: Identifiable {
    enum Kind { case channel, person }
    let kind: Kind
    let person: ChatUser?
    let channel: ChatChannel?
    let memberIDs: Set<Int64>
    let title: String
    let subtitle: String
    let searchNames: [String]
    var id: String { channel.map { "channel-\($0.id)" } ?? person.map { "person-\($0.user_id)" } ?? "invalid" }
    var encrypted: Bool { channel?.encrypted == true }
    var named: Bool { channel.map { ["public", "private"].contains($0.type) } ?? false }
    var conversation: Bool { person != nil || channel.map { ["anonymous", "synobot"].contains($0.type) } == true }
    var orderTime: Double { let value = channel?.channel_order_time ?? 0; return value.isFinite ? max(0, value) : 0 }
    var unreadScore: Int {
        guard let channel else { return 0 }
        return (channel.unread > 0 || (channel.unread_mention ?? 0) > 0 || (channel.unread_thread ?? [:]).values.contains(where: { $0 > 0 }) ? 1 : 0) + (channel.badgeUnreadCount > 0 ? 1 : 0)
    }
    func score(_ query: String) -> Int {
        if let person { return max(ChatQuickSwitchMatch.score(person.username ?? "", query, bonus: 1), ChatQuickSwitchMatch.score(person.nickname, query)) }
        let compact = { (s: String) in s.filter { !$0.isWhitespace } }
        return searchNames.map { ChatQuickSwitchMatch.score(compact($0), query) }.max() ?? 0
    }
}
enum ChatQuickSwitchMatch {
    /// Port of Utils.fullPatternMatch: each literal space-separated term must match.
    static func score(_ source: String, _ query: String, bonus: Int = 0) -> Int {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        let source = source.lowercased()
        var result = 0
        for term in terms {
            guard !source.isEmpty, !term.isEmpty, let match = source.range(of: term.lowercased(), options: .literal) else { return 0 }
            result += 1 + (match.lowerBound == source.startIndex ? 1 : 0) + bonus
        }
        return result
    }
}
struct ChatQuickSwitchSnapshot {
    let users: [ChatUser]
    let entries: [ChatQuickSwitchEntry]
    let channels: [ChatChannel]
    let blockedBots: Set<Int64>
    let accountGeneration: Int
    let ownerID: Int64
    let canStartConversations: Bool
    func filtered(query: String, scope: Int) -> [ChatQuickSwitchEntry] {
        entries.filter { entry in
            (scope == 0 || scope == 1 && entry.named || scope == 2 && entry.conversation)
            && (query.isEmpty ? entry.orderTime > 0 : entry.score(query) > 0)
        }.sorted { a, b in
            if a.unreadScore != b.unreadScore { return a.unreadScore > b.unreadScore }
            if a.orderTime != b.orderTime { return a.orderTime > b.orderTime }
            let sa = a.score(query), sb = b.score(query)
            if sa != sb { return sa > sb }
            let order = a.title.localizedCaseInsensitiveCompare(b.title)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
    static func build(users: [ChatUser], channels: [ChatChannel], members: [Int64: Set<Int64>], ownerID: Int64, canStart: Bool, blockedBots: Set<Int64>, epoch: Int, nameFormat: ChatNameFormat = .nickname) throws -> Self {
        guard users.allSatisfy({ $0.user_id > 0 }), channels.allSatisfy({ $0.id > 0 }), users.contains(where: { $0.user_id == ownerID }), Set(users.map(\.user_id)).count == users.count, Set(channels.map(\.id)).count == channels.count else { throw ChatAPIError.invalidResponse }
        let people = Dictionary(uniqueKeysWithValues: users.map { ($0.user_id, $0) })
        var entries: [ChatQuickSwitchEntry] = [], represented = Set<Int64>()
        for channel in channels where channel.is_closed != true && channel.is_joined != false && (channel.hide_global_at ?? 0) == 0 {
            guard channel.id > 0, ["anonymous", "public", "private", "synobot", "chatbot"].contains(channel.type) else { continue }
            let ids = members[channel.id] ?? []
            if channel.type == "anonymous" {
                guard ids.contains(ownerID), ids.count >= 2 else { continue }
                let peer = ids.count == 2 ? ids.first(where: { $0 != ownerID }).flatMap { people[$0] } : nil
                if let peer, !channel.encrypted, peer.type == "human", peer.human_type == "dsm" {
                    represented.insert(peer.user_id)
                    entries.append(.init(kind: .person, person: peer, channel: channel, memberIDs: ids, title: nameFormat.display(peer), subtitle: peer.username.map { "@" + $0 } ?? "Conversation", searchNames: [])); continue
                }
                let names = ids.filter { $0 != ownerID }.sorted().map { people[$0].map { nameFormat.display($0) } ?? "User \($0)" }
                let title = channel.name.isEmpty ? names.joined(separator: ", ") : channel.name
                let aliases = ids.sorted().flatMap { id -> [String] in guard let user = people[id] else { return [] }; return [user.nickname, user.username ?? ""] }
                entries.append(.init(kind: .channel, person: channel.encrypted && ids.count == 2 ? peer : nil, channel: channel, memberIDs: ids, title: title, subtitle: channel.encrypted ? "Encrypted conversation" : "Group conversation", searchNames: [channel.name, aliases.joined(separator: ", ")])); continue
            }
            if channel.type == "chatbot" {
                guard let botID = channel.creator_id, !blockedBots.contains(botID), let bot = people[botID], bot.type == "bot", bot.bot_type == "chatbot", bot.is_disabled != true, (bot.delete_at ?? 0) == 0, ids == [ownerID], !channel.encrypted else { continue }
                entries.append(.init(kind: .channel, person: nil, channel: channel, memberIDs: ids, title: nameFormat.display(bot), subtitle: "Bot", searchNames: [bot.nickname, bot.username ?? ""])); continue
            }
            if channel.type == "synobot", ids != [ownerID] { continue }
            let title = channel.defaultTitle ?? "Channel \(channel.id)"
            entries.append(.init(kind: .channel, person: nil, channel: channel, memberIDs: ids, title: title, subtitle: channel.type == "synobot" ? "My Space" : channel.type == "private" ? "Private channel" : "Channel", searchNames: [title]))
        }
        if canStart {
            for user in users where user.user_id != ownerID && user.canStartConversation && !represented.contains(user.user_id) {
                entries.append(.init(kind: .person, person: user, channel: nil, memberIDs: [ownerID, user.user_id], title: nameFormat.display(user), subtitle: "Start a conversation", searchNames: []))
            }
        }
        guard Set(entries.map(\.id)).count == entries.count else { throw ChatAPIError.invalidResponse }
        return .init(users: users, entries: entries, channels: channels, blockedBots: blockedBots, accountGeneration: epoch, ownerID: ownerID, canStartConversations: canStart)
    }
}
enum ChatQuickSwitchSelection {
    static func move(_ selected: String?, in entries: [ChatQuickSwitchEntry], delta: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        guard let index = selected.flatMap({ selected in entries.firstIndex { $0.id == selected } }) else { return entries.first?.id }
        return entries[max(0, min(entries.count - 1, index + delta))].id
    }
}


struct ChatConversationStartIntent: ChatAccountActionRecord {
    static var journalFolder: String { "ConversationStarts" }
    let members: [Int64]
    let operationID: UUID
    init(members: Set<Int64>) { self.members = members.sorted(); operationID = UUID() }
    var id: String { SHA256.hash(data: Data(members.map(String.init).joined(separator: ",").utf8)).map { String(format: "%02x", $0) }.joined() }
    func validate() throws { guard members.count >= 2, members.allSatisfy({ $0 > 0 }), members == members.sorted(), Set(members).count == members.count else { throw ChatAPIError.invalidResponse } }
}
typealias ChatConversationStartJournal = ChatAccountActionJournal<ChatConversationStartIntent>
