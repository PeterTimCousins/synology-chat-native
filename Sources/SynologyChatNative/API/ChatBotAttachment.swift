import Foundation

/// Retains server indices and callback values. Unknown card/action fields never
/// become request fields, URLs, executable code or a reason to drop the message.
struct ChatBotAttachment: Identifiable {
    let index: Int
    let raw: ChatJSON
    var id: Int { index }
    var text: String { raw["text"]?.string ?? "" }
    var actionCount: Int { if case .array(let actions) = raw["actions"] { return actions.count }; return 0 }
    var actions: [ChatBotAttachmentAction] {
        guard case .array(let actions) = raw["actions"] else { return [] }
        return actions.prefix(100).enumerated().map { .init(index: $0.offset, raw: $0.element) }
    }
}
struct ChatBotAttachmentAction: Identifiable {
    let index: Int
    let raw: ChatJSON
    var id: Int { index }
    var type: String { raw["type"]?.string ?? "unknown" }
    var text: String { raw["text"]?.string ?? "Unsupported action" }
    var style: String { raw["style"]?.string ?? "default" }
}
struct ChatBotActionSelection: Equatable {
    let attachmentIndex: Int
    let actionIndex: Int
    let attachment: ChatJSON
    func payload() throws -> ChatParameter {
        guard (0..<100).contains(attachmentIndex), (0..<100).contains(actionIndex),
              case .array(let actions) = attachment["actions"], actions.indices.contains(actionIndex),
              let type = actions[actionIndex]["type"]?.string, type == "button",
              let text = actions[actionIndex]["text"]?.string, !text.isEmpty, text.utf16.count <= 1000 else { throw ChatAPIError.invalidResponse }
        let action = actions[actionIndex]
        var selected: [String: ChatParameter] = ["type": .string(type), "idx": .integer(Int64(actionIndex))]
        for name in ["name", "value"] { if let value = action[name] { selected[name] = try Self.parameter(value) } }
        var fields: [String: ChatParameter] = ["idx": .integer(Int64(attachmentIndex)), "actions": .array([.object(selected)])]
        if let callback = attachment["callback_id"] { fields["callback_id"] = try Self.parameter(callback) }
        let payload = ChatParameter.object(fields)
        guard try JSONEncoder().encode(payload).count <= 32_768 else { throw ChatAPIError.invalidResponse }
        return payload
    }
    private static func parameter(_ value: ChatJSON, depth: Int = 0) throws -> ChatParameter {
        guard depth <= 8 else { throw ChatAPIError.invalidResponse }
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .integer(let value): return .integer(value)
        case .number(let value): guard value.isFinite else { throw ChatAPIError.invalidResponse }; return .number(value)
        case .string(let value): guard value.utf16.count <= 8192 else { throw ChatAPIError.invalidResponse }; return .string(value)
        case .array(let values):
            guard values.count <= 100 else { throw ChatAPIError.invalidResponse }
            return .array(try values.map { try parameter($0, depth: depth + 1) })
        case .object(let values):
            guard values.count <= 100 else { throw ChatAPIError.invalidResponse }
            return .object(try values.mapValues { try parameter($0, depth: depth + 1) })
        }
    }
    func matches(_ post: ChatPost) -> Bool {
        guard let cards = post.props?.attachments, cards.indices.contains(attachmentIndex) else { return false }
        return cards[attachmentIndex] == attachment
    }
}
struct ChatBotActionFailure: LocalizedError {
    let uncertain: Bool
    let message: String
    var errorDescription: String? { message }
}
