import Foundation

enum ChatReadOnlyFeatureProbe {
    static func run() async -> Bool {
        do {
            let imported = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: imported.session)
            try await api.discover()
            let permissions = try await api.channelPermissions()
            print("Native channel permissions verified: create=\(permissions.allows("channel_create")), invite=\(permissions.allows("channel_invite")), remove=\(permissions.allows("channel_kick")).")
            let preferences = try await api.notificationPreferences()
            print("Notification preference contract: preview field present = \(preferences.notification_showmessage != nil), mute field present = \(preferences.notification_mute != nil).")
            let target = try await ChatAuthorizedTestTarget.peter(api: api, username: imported.username)
            let result = try await api.searchMessages(query: "Native", channelID: target.id)
            guard !result.search_results.isEmpty else { print("Synthetic test messages were not found by search."); return false }
            print("Native message search verified: \(result.search_results.count) matching test results.")
            if let image = result.search_results.first(where: { $0.file_props?.is_image == true && $0.file_props?.name == "native-client-test.png" }) {
                let data = try await api.thumbnail(postID: image.id)
                guard !data.isEmpty else { return false }
                print("Native image thumbnail retrieval verified.")
            }
            if let thread = result.search_results.first(where: { $0.message == "Native feature test — edited successfully." }) {
                _ = try await api.threadPosts(channelID: target.id, rootID: thread.id)
                print("Native thread history decoding verified.")
            }
            return true
        } catch {
            print((error as? ChatAPIError)?.errorDescription ?? "Native read-only feature probe failed.")
            return false
        }
    }
}
