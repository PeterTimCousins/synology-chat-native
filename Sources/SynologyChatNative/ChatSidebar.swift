import Foundation

struct ChatSidebarSettings: Decodable, Equatable { let sidebar_pinning_unread: Bool }
struct ChatSidebarSettingsSnapshot { let settings: ChatSidebarSettings; let accountGeneration: Int }
enum ChatSidebarGroup: String, CaseIterable, Hashable { case unread = "Unread", starred = "Starred", channels = "Channels", conversations = "Conversations", bots = "Bots" }
struct ChatSidebarSection: Identifiable { let group: ChatSidebarGroup; let channels: [ChatChannel]; var id: String { group.rawValue } }
struct ChatSidebarAnchor {
    let channelID: Int64
    let inUnread: Bool
    let badgeCount: Int
}
extension ChatChannel {
    var sidebarUnreadCount: Int {
        (unread_thread ?? [:]).values.reduce(min(9999,max(0,unread))) { min(9999, $0 + min(9999,max(0,$1))) }
    }
    var sidebarUnreadDescription: String {
        sidebarUnreadDescription(language:.system)
    }
    func sidebarUnreadDescription(language:NativeInterfaceLanguage,bundle:Bundle? = nil)->String {
        let total = sidebarUnreadCount
        let resources = bundle ?? NativeLocalizedStrings.resourceBundle
        guard total > 0 else { return NativeLocalizedStrings.text("No unread messages",language:language,bundle:resources) }
        let normalNamed = ["public","private"].contains(type) && !encrypted
        let unread = NativeLocalizedStrings.count("%lld unread messages",Int64(total),language:language,bundle:resources)
        guard normalNamed && badgeUnreadCount != total else { return unread }
        let mentions = NativeLocalizedStrings.count("%lld mentions or followed replies",Int64(badgeUnreadCount),language:language,bundle:resources)
        return NativeLocalizedStrings.objects("%@, %@",unread,mentions,language:language,bundle:resources)
    }
}
enum ChatSidebarProjection {
    static func anchor(_ channel: ChatChannel, pinUnread: Bool) -> ChatSidebarAnchor {
        .init(channelID: channel.id, inUnread: pinUnread && channel.sidebarUnreadCount > 0, badgeCount: channel.badgeUnreadCount)
    }
    static func group(_ channel: ChatChannel, pinUnread: Bool, anchor: ChatSidebarAnchor?) -> ChatSidebarGroup {
        if pinUnread {
            if let anchor, anchor.channelID == channel.id { if anchor.inUnread { return .unread } }
            else if channel.sidebarUnreadCount > 0 { return .unread }
        }
        if channel.is_star == true { return .starred }
        if ["public","private"].contains(channel.type) { return .channels }
        return channel.type == "chatbot" ? .bots : .conversations
    }
    static func sections(channels: [ChatChannel], pinUnread: Bool, selectedID: Int64?, anchor: ChatSidebarAnchor?, closed: Set<Int64>, blockedBots: Set<Int64>, query: String, title: (ChatChannel) -> String, searchNames: (ChatChannel) -> [String] = { _ in [] }) -> [ChatSidebarSection] {
        let activeAnchor = anchor?.channelID == selectedID ? anchor : nil
        let filtered = channels.filter { channel in
            guard channel.id > 0, channel.is_closed != true, channel.is_joined != false, !closed.contains(channel.id),
                  (channel.hide_global_at ?? 0) == 0, ["public","private","anonymous","synobot","chatbot"].contains(channel.type),
                  channel.type != "chatbot" || !blockedBots.contains(channel.creator_id ?? 0) else { return false }
            if !query.isEmpty { return ([title(channel)] + searchNames(channel)).contains { $0.localizedCaseInsensitiveContains(query) } }
            return channel.is_star == true || !channel.hiddenFromSidebar(selectedID: selectedID)
        }
        return ChatSidebarGroup.allCases.compactMap { section in
            let rows = filtered.filter { group($0, pinUnread: pinUnread, anchor: activeAnchor) == section }.sorted { a,b in
                if section == .unread {
                    let ac = activeAnchor?.channelID == a.id ? activeAnchor!.badgeCount : a.badgeUnreadCount
                    let bc = activeAnchor?.channelID == b.id ? activeAnchor!.badgeCount : b.badgeUnreadCount
                    if (ac > 0) != (bc > 0) { return ac > 0 }
                } else {
                    if (a.type == "synobot") != (b.type == "synobot") { return a.type == "synobot" }
                    if a.encrypted != b.encrypted { return a.encrypted }
                }
                let order = title(a).compare(title(b), options: [.caseInsensitive,.numeric], locale: .current)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
            return rows.isEmpty ? nil : .init(group: section, channels: rows)
        }
    }
}
