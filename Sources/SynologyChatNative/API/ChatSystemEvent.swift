import Foundation

/// Treat event fields as literal data; unknown extensions must not hide the post.
struct ChatSystemEvent:Decodable {
    let value:ChatJSON
    init(from decoder:Decoder) throws { value = try ChatJSON(from:decoder) }
    var event:String? { value["event"]?.string }
    var effectiveUserID:Int64? { value["effective_user_id"]?.integer.flatMap { $0 > 0 ? $0 : nil } }
    func text(names:[Int64:String],language:NativeInterfaceLanguage = .system,bundle:Bundle? = nil)->String {
        func label(_ key:String)->String { NativeLocalizedStrings.text(key,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle) }
        func one(_ key:String,_ value:String)->String { NativeLocalizedStrings.object(key,value,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle) }
        func two(_ key:String,_ first:String,_ second:String)->String { NativeLocalizedStrings.objects(key,first,second,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle) }
        func count(_ key:String,_ value:Int64)->String { NativeLocalizedStrings.count(key,value,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle) }
        func name(_ id:Int64?)->String { guard let id,id > 0 else { return label("A member") };return names[id] ?? NativeLocalizedStrings.integer("User %lld",id,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle) }
        let actor = name(value["trigger_user_id"]?.integer)
        let targets:[Int64]
        if case .array(let values) = value["target_user_ids"] { targets = values.compactMap(\.integer) } else { targets = [] }
        let people = targets.prefix(20).map { name($0) }.joined(separator:", ") + (targets.count > 20 ? count(" and %lld others",Int64(targets.count - 20)) : "")
        let hasActor = (value["trigger_user_id"]?.integer ?? 0) > 0
        switch event {
        case "channel.update":
            guard case .array(let updates) = value["extra"]?["update_info"] else { return label("Channel details changed.") }
            let descriptions = updates.compactMap { update -> String? in
                switch update["attr"]?.string {
                case "channel_name":return update["new"]?.string.map { one("Channel name changed to %@.",$0) }
                case "purpose":return update["new"]?.string.map { $0.isEmpty ? label("Channel purpose cleared.") : one("Channel purpose changed to %@.",$0) }
                case "type":return label("Conversation converted to a private channel.")
                default:return nil
                }
            }
            return descriptions.isEmpty ? label("Channel details changed.") : descriptions.joined(separator:" ")
        case "channel.join":
            guard !people.isEmpty else { return label("Channel membership changed.") }
            return hasActor ? two("%@ joined the channel, invited by %@.",people,actor) : one("%@ joined the channel.",people)
        case "channel.disjoin":
            guard !people.isEmpty else { return label("Channel membership changed.") }
            return hasActor ? two("%@ removed from the channel by %@.",people,actor) : one("%@ left the channel.",people)
        case "channel.kick":return label("You were removed from the channel.")
        case "encrypt.enabled":return label("Conversation encryption enabled.")
        case "encrypt.disabled":return label("Conversation encryption disabled.")
        case "encrypt.notify":return one("%@ updated conversation encryption.",actor)
        case "channel.rescue":return two("%@ repaired encrypted channel access for %@.",actor,people.isEmpty ? label("a member") : people)
        case "channel.revive":return one("%@ reopened a conversation.",actor)
        case "channel.close":return label("Channel closed.")
        case "post.pin":return one("%@ pinned a message.",actor)
        case "post.unpin":return one("%@ unpinned a message.",actor)
        case "post.vote.close":return one("%@ closed a poll.",actor)
        case "post.vote.update":return one("%@ updated a poll.",actor)
        case "bot.add":return two("%@ added %@.",actor,people.isEmpty ? label("an integration") : people)
        case "bot.delete":return two("%@ removed %@.",actor,people.isEmpty ? label("an integration") : people)
        default:return label("Conversation event.")
        }
    }
}
extension ChatPost {
    var displayAuthorID:Int64 { type == "system" ? system_props?.effectiveUserID ?? creator_id : creator_id }
    func systemEventText(names:[Int64:String],language:NativeInterfaceLanguage = .system,bundle:Bundle? = nil)->String {
        system_props?.text(names:names,language:language,bundle:bundle)
            ?? NativeLocalizedStrings.text("Conversation event.",language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
    }
}
