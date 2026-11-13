#if DEBUG
import Foundation

/// Exercise initiation only for the uniquely authorized, already existing Peter DM.
enum ChatConversationProbe {
    static func run() async -> Bool {
        do {
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let target = try await ChatAuthorizedTestTarget.peter(api: api, username: account.username)
            let members = try await api.members(channelID: target.id)
            guard members.count == 2 else { return false }
            let result = try await api.initiateConversation(userIDs: members)
            guard result.id == target.id, Set(try await api.members(channelID: result.id)) == Set(members) else {
                print("Initiation did not reuse the authorized existing DM; no retry."); return false
            }
            print("Native conversation initiation reused the existing Peter DM with exactly the same two members. No message sent.")
            return true
        } catch {
            print((error as? ChatAPIError)?.errorDescription ?? "Conversation probe failed; details suppressed.")
            return false
        }
    }
}
#endif
