import Foundation
import CryptoKit

struct ChatSlashProperties: Decodable, Equatable {
    let cmd: String?
    let description: String?
    let usage: String?
    let endpointFingerprint: String?
    enum CodingKeys: String, CodingKey { case cmd, description, usage, url }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        cmd = try? c?.decode(String.self, forKey: .cmd)
        description = try? c?.decode(String.self, forKey: .description)
        usage = try? c?.decode(String.self, forKey: .usage)
        let endpoint = try? c?.decode(String.self, forKey: .url)
        endpointFingerprint = endpoint.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
}
struct ChatSlashCommand: Equatable, Identifiable {
    enum Kind: Equatable { case help, nickname, server(Int64) }
    let name: String
    let description: String
    let usage: String
    let kind: Kind
    let endpointFingerprint: String?
    var id: String { name }
    static func catalogue(users: [ChatUser], encrypted: Bool) throws -> [Self] {
        guard Set(users.map(\.user_id)).count == users.count else { throw ChatAPIError.invalidResponse }
        var result = [Self(name: "help", description: "Show available commands", usage: "/help", kind: .help, endpointFingerprint: nil),
                      Self(name: "nickname", description: "Edit your display name", usage: "/nickname Your display name", kind: .nickname, endpointFingerprint: nil)]
        for user in users where user.type == "bot" && user.bot_type == "slash" && user.is_disabled != true && (user.delete_at ?? 0) == 0 && user.user_id > 0 {
            guard let props = user.slash_props, let name = props.cmd, ChatSlashSyntax.validName(name), !(encrypted && name == "jitsi") else { continue }
            guard !result.contains(where: { $0.name == name }) else { throw ChatTransferError(message: "The server command catalogue has conflicting command names.") }
            let description = props.description == "webhook_builtin:desc_conference_jitsi" ? "Start a Jitsi video meeting" : props.description ?? "Configured integration command"
            result.append(.init(name: name, description: description, usage: props.usage?.isEmpty == false ? props.usage! : "/" + name, kind: .server(user.user_id), endpointFingerprint: props.endpointFingerprint))
        }
        return result.sorted { $0.name < $1.name }
    }
}
enum ChatSlashSyntax {
    static func validName(_ text: String) -> Bool { !text.isEmpty && text.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }
    static func name(_ text: String) -> String? {
        guard let range = text.range(of: #"^/[A-Za-z0-9_-]+"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst())
    }
    static func arguments(_ text: String) -> String {
        guard let name = name(text) else { return "" }
        return String(text.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func completing(_ text: String, with command: String) -> String {
        guard validName(command), text.hasPrefix("/") else { return text }
        let count = (name(text)?.count ?? 0) + 1
        let suffix = String(text.dropFirst(count))
        return "/" + command + (suffix.isEmpty ? " " : suffix)
    }
    static func invocationKey(channelID: Int64, command: ChatSlashCommand, message: String) -> String {
        let kind:String
        switch command.kind {
        case .help:kind = "help"
        case .nickname:kind = "nickname"
        case .server(let userID):kind = "server:\(userID)"
        }
        let value = "v1|\(channelID)|\(kind)|" + message
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
struct NativeSlashCommandRequest: Identifiable {
    let id = UUID()
    let channel: ChatChannel
    let rootID: Int64?
    let memberIDs: Set<Int64>
    let commands: [ChatSlashCommand]
    let initialText: String
    let originText: String?
    let accountGeneration: Int
}
struct ChatSlashResult: Decodable {
    let message: String?
    var displayMessage: String {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Command sent. The integration may update the conversation separately." }
        return message
    }
}
struct ChatSlashFailure: LocalizedError {
    let uncertain: Bool
    let message: String
    var errorDescription: String? { message }
}
extension ChatAPIClient {
    func executeSlashCommand(channelID: Int64, userID: Int64, message: String) async throws -> ChatSlashResult {
        guard channelID > 0, userID > 0, ChatSlashSyntax.name(message) != nil, ChatMessageText.isAllowed(message) else { throw ChatAPIError.invalidResponse }
        return try await perform(requestForCall(api: "SYNO.Chat.Webhook.Slash", method: "execute", version: 2,
            parameters: ["channel_id": .integer(channelID), "user_id": .integer(userID), "message": .string(message)]))
    }
}
