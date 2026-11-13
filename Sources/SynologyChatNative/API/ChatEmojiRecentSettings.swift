import Foundation

/// DSM UserSettings namespaces are saved as a whole by the official client.
/// Retain unknown Chat fields and submit only this application's namespace.
struct ChatEmojiRecentSettings {
    static let namespace = "SYNO.SDS.Chat.Application"
    let application: [String:ChatJSON]
    let names: [String]
    var recent: [ChatReactionKind] {
        var seen = Set<String>()
        return Array(names.compactMap { name in
            guard seen.insert(name).inserted else { return nil };return ChatReactionKind(rawValue:name)
        }.prefix(24))
    }
    init(_ response: ChatJSON) throws {
        guard case .object(let root) = response,root.count <= 1024 else { throw ChatAPIError.invalidResponse }
        let app = root[Self.namespace] ?? .object([:])
        guard case .object(let values) = app,values.count <= 512,
              (try JSONEncoder().encode(app)).count <= 1024*1024 else { throw ChatAPIError.invalidResponse }
        guard case .array(let raw) = values["recent_emojies"] ?? .array([]),raw.count <= 1024 else { throw ChatAPIError.invalidResponse }
        let names = raw.compactMap(\.string)
        guard names.count == raw.count,names.allSatisfy(ChatSticker.validName) else { throw ChatAPIError.invalidResponse }
        application = values;self.names = names
    }
    func adding(_ choices: [ChatReactionKind]) throws -> Self {
        var names = self.names
        for choice in choices {
            names.removeAll { $0 == choice.rawValue };names.insert(choice.rawValue,at:0)
        }
        var values = application;values["recent_emojies"] = .array(Array(names.prefix(24)).map(ChatJSON.string))
        return try Self(.object([Self.namespace:.object(values)]))
    }
    var payload: ChatJSON { .object([Self.namespace:.object(application)]) }
}
