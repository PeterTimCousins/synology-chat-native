import Foundation

enum ChatChannelAlertMode: String, CaseIterable {
    case all, mentionSubscribe = "mention_subscribe", mention, none
    var title: String {
        switch self { case .all: return "All messages"; case .mentionSubscribe: return "Mentions and followed threads"; case .mention: return "Mentions only"; case .none: return "None" }
    }
    static func choices(_ channel: ChatChannel) -> [Self] { ["public", "private"].contains(channel.type) && !channel.encrypted ? allCases : [.all, .none] }
    static func title(_ raw: String) -> String { raw == "by_admin_console" ? "Server default" : Self(rawValue: raw)?.title ?? "Keep current setting" }
}
struct ChatChannelAlerts: Decodable, Equatable {
    let notification_desktop: String
    let notification_mobile: String
    var fields: [String: String] { ["notification_desktop": notification_desktop, "notification_mobile": notification_mobile] }
    func validate() throws { guard fields.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw ChatAPIError.invalidResponse } }
}
struct ChatChannelAlertsDraft: Equatable {
    var desktop: String
    var mobile: String
    init(_ source: ChatChannelAlerts) { desktop = source.notification_desktop; mobile = source.notification_mobile }
    func patch(from original: ChatChannelAlerts, channel: ChatChannel) throws -> [String: String] {
        let values = ["notification_desktop": desktop, "notification_mobile": mobile]
        let patch = values.filter { original.fields[$0.key] != $0.value }
        guard patch.values.allSatisfy({ raw in ChatChannelAlertMode.choices(channel).contains { $0.rawValue == raw } }) else { throw ChatTransferError(message: "Choose a notification mode available for this conversation.") }
        return patch
    }
}
struct ChatChannelAlertsSnapshot {
    let channel: ChatChannel
    let memberIDs: Set<Int64>?
    let settings: ChatChannelAlerts
    let accountGeneration: Int
}
