import Foundation

enum ChatConversationOrganizationChange:Equatable {
    case star(Bool),hide
    var method:String {
        switch self { case .star(true):return "star";case .star(false):return "unstar";case .hide:return "hide" }
    }
    var changesVisibility:Bool { if case .hide = self { return true };return false }
    func matches(_ channel:ChatChannel) -> Bool {
        switch self {
        case .star(let value):return channel.is_star == value
        case .hide:return (channel.last_hide_at ?? 0) > 0 && (channel.last_hide_at ?? 0) >= (channel.last_view_at ?? 0)
        }
    }
}

struct ChatConversationOrganizationFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}

extension ChatChannel {
    /// Recovered vendor visibility rules: selection and new relevant activity reveal
    /// a hidden chat. Keep admin/unknown notification rules conservative until known.
    func hiddenFromSidebar(selectedID:Int64?) -> Bool {
        if selectedID == id || type == "synobot" { return false }
        if let global = hide_global_at,global.isFinite,global > 0 { return true }
        guard let hidden = last_hide_at,hidden.isFinite,hidden > 0,hidden >= (last_view_at ?? 0) else { return false }
        let threadUnread = (unread_thread ?? [:]).values.contains { $0 > 0 }
        if type == "anonymous" { return unread <= 0 && !threadUnread }
        if type == "chatbot" { return badgeUnreadCount == 0 }
        if ["public","private"].contains(type) {
            if (unread_mention ?? 0) > 0 || threadUnread { return false }
            let rule = preferences?.notification_desktop ?? "mention_subscribe"
            if !["mention","mention_subscribe"].contains(rule),unread > 0 { return false }
            return true
        }
        return false
    }
    func supportsOrganization(_ change:ChatConversationOrganizationChange) -> Bool {
        guard id > 0,is_joined != false,(hide_global_at ?? 0) == 0 else { return false }
        switch change {
        case .star:return is_star != nil && ["public","private","anonymous","chatbot","synobot"].contains(type)
        case .hide:return last_hide_at != nil && ["public","private","anonymous","chatbot"].contains(type)
        }
    }
}
