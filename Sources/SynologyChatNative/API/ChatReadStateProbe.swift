import Foundation

@MainActor
enum ChatReadStateProbe {
    static func run() async -> Bool {
        do {
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let target = try await ChatAuthorizedTestTarget.peter(api: api, username: account.username)
            let live = ChatLiveConnection(session: account.session, version: try await api.runtimeVersion())
            live.start()
            defer { live.stop() }
            for _ in 0..<100 where live.connectionID == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            guard let connection = live.connectionID else { return false }
            let posts = try await api.posts(channelID: target.id)
            guard let timestamp = posts.map(\.create_at).max(), timestamp.isFinite,
                  timestamp >= 0, timestamp < Double(Int64.max) else { return false }
            try await api.enterChannel(target.id, connectionID: connection)
            try await api.viewChannel(target.id, through: Int64(timestamp), connectionID: connection)
            try await api.leaveChannel(connectionID: connection)
            guard let after = try await api.channels().first(where: { $0.id == target.id }),
                  after.unread == 0, (after.last_view_at ?? 0) >= timestamp else {
                print("Peter read cursor did not match canonical state."); return false
            }
            print("Peter enter/view/leave verified: unread \(target.unread) → \(after.unread), cursor advanced to the loaded server timestamp.")
            if FileManager.default.fileExists(atPath: ChatThreadProbe.file.path) {
                let fixture = try JSONDecoder().decode(ChatThreadProbe.Fixture.self, from: Data(contentsOf: ChatThreadProbe.file))
                if fixture.channelID == target.id, let rootID = fixture.rootID {
                    let root = try await api.post(channelID: target.id, postID: rootID)
                    guard root.creator_id == fixture.creatorID, root.message == fixture.text else { return false }
                    try await api.viewThread(channelID: target.id, rootID: rootID)
                    let updated = try await api.channels().first(where: { $0.id == target.id })
                    guard (updated?.unread_thread?[String(rootID)] ?? 0) == 0 else { return false }
                    print("Synthetic Peter thread view verified: unread replies cleared.")
                }
            }
            return true
        } catch ChatAPIError.server(let code) {
            print("Read-state probe rejected, code \(code).")
            return false
        } catch {
            print("Read-state verification stopped; session details suppressed.")
            return false
        }
    }
}
