#if DEBUG
import Foundation

/// Deliberately miss two synthetic posts, then verify the real UI model's handshake resync.
@MainActor
enum ChatMessageGapProbe {
    static func run() async -> Bool {
        let model = NativeChatPreviewModel(restoreNotificationPreference: false)
        defer { model.disconnectLive() }
        do {
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let target = try await ChatAuthorizedTestTarget.peter(api: api, username: account.username)
            let fixture = try JSONDecoder().decode(ChatThreadProbe.Fixture.self, from: Data(contentsOf: ChatThreadProbe.file))
            guard fixture.channelID == target.id, let rootID = fixture.rootID else { return false }
            let root = try await api.post(channelID: target.id, postID: rootID)
            guard root.creator_id == fixture.creatorID, root.message == fixture.text,
                  fixture.text.hasPrefix("Native pagination test ") else { return false }
            await model.connect(using: account)
            for _ in 0..<150 where model.liveStatus != .live { try await Task.sleep(nanoseconds: 100_000_000) }
            guard model.connected, model.liveStatus == .live else { return false }
            model.selection = target.id
            model.loadSelection()
            for _ in 0..<150 where model.loadingHistory { try await Task.sleep(nanoseconds: 100_000_000) }
            await model.openThread(root)
            model.draft = "Synthetic unsent main draft"
            model.replyDraft = "Synthetic unsent reply draft"
            model.suspendLiveForProbe()
            guard model.liveStatus == .offline else { return false }
            let label = "Native reconnect gap test " + UUID().uuidString.prefix(8) + "."
            let sent = try await api.sendText(channelID: target.id, text: label, connectionID: "")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let reply = try await api.sendText(channelID: target.id, text: label + " Reply.", connectionID: "", threadID: rootID)
            guard !model.posts.contains(where: { $0.id == sent.id }),
                  !model.replies.contains(where: { $0.id == reply.id }) else { return false }
            print("Two synthetic posts are absent from the disconnected UI model, as expected.")
            model.resumeLiveForProbe()
            for _ in 0..<200 {
                if model.liveStatus == .live, !model.loadingHistory, !model.loadingThread,
                   model.posts.contains(where: { $0.id == sent.id }),
                   model.replies.contains(where: { $0.id == reply.id }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard model.liveStatus == .live, model.threadRoot?.id == rootID,
                  model.posts.contains(where: { $0.id == sent.id && $0.message == label }),
                  model.replies.contains(where: { $0.id == reply.id && $0.message == label + " Reply." }),
                  model.draft == "Synthetic unsent main draft", model.replyDraft == "Synthetic unsent reply draft" else {
                print("Missed-post recovery or draft/thread preservation failed; no retry."); return false
            }
            print("Real UI model recovered both missed posts after a fresh handshake, retained the open thread and preserved both unsent drafts.")
            return true
        } catch {
            print((error as? ChatAPIError)?.errorDescription ?? "Message-gap probe failed; details suppressed.")
            return false
        }
    }
}
#endif
