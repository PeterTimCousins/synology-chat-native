import Foundation

enum ChatNameFormat: String, Codable, CaseIterable, Hashable {
    case username, nickname
    var title: String { title(language:.system) }
    func title(language:NativeInterfaceLanguage = .system,bundle:Bundle? = nil)->String {
        NativeLocalizedStrings.text(self == .username ? "Usernames" : "Nicknames",language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
    }
    func display(_ user: ChatUser, shortGuest: Bool = false,language:NativeInterfaceLanguage = .system,bundle:Bundle? = nil) -> String {
        let username = user.username ?? ""
        func fallback()->String { NativeLocalizedStrings.integer("User %lld",user.user_id,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle) }
        if user.type == "bot" { return user.nickname.isEmpty ? (username.isEmpty ? fallback() : username) : user.nickname }
        if user.human_type == "guest" {
            let short = username.hasPrefix("guest_") ? String(username.dropFirst(6)) : username
            let value = user.nickname.isEmpty ? (short.isEmpty ? fallback() : short) : user.nickname
            return shortGuest ? value : NativeLocalizedStrings.object("%@ (Guest)",value,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
        }
        let primary = self == .username ? username : user.nickname
        let secondary = self == .username ? user.nickname : username
        return !primary.isEmpty ? primary : !secondary.isEmpty ? secondary : fallback()
    }
    func additional(_ user: ChatUser) -> String? {
        guard user.type != "bot", user.human_type != "guest" else { return nil }
        let value = self == .username ? user.nickname : user.username ?? ""
        return value.isEmpty || value == display(user) ? nil : value
    }
    static func matches(_ user: ChatUser, query: String) -> Bool {
        query.isEmpty || user.nickname.localizedCaseInsensitiveContains(query) || (user.username?.localizedCaseInsensitiveContains(query) ?? false)
    }
}
struct ChatNameSettings: Decodable, Equatable { let prefer_user_name_format: ChatNameFormat }
struct ChatNameSettingsSnapshot { let settings: ChatNameSettings; let accountGeneration: Int }
