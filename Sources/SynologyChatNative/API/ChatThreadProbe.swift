import Foundation

/// Controlled integration fixture: one synthetic root and 31 replies, only in the authorized Peter DM.
@MainActor
enum ChatThreadProbe {
    struct Fixture: Codable {
        let channelID: Int64
        let creatorID: Int64
        let text: String
        var rootID: Int64?
        var replyIDs: [Int64] = []
    }
    static let file = URL(fileURLWithPath: "/private/tmp/synology-chat-thread-test.json")
    static func save(_ fixture: Fixture) throws {
        try JSONEncoder().encode(fixture).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func run(create: Bool) async -> Bool {
        do {
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let live = ChatLiveConnection(session: account.session, version: try await api.runtimeVersion())
            live.start()
            defer { live.stop() }
            for _ in 0..<100 where live.connectionID == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            guard let connectionID = live.connectionID else { throw ChatAPIError.connection }
            let channel = try await ChatAuthorizedTestTarget.peter(api: api, username: account.username)
            let users = try await api.users()
            guard let me = users.first(where: { $0.username?.caseInsensitiveCompare(account.username) == .orderedSame }) else { return false }
            var fixture: Fixture
            if FileManager.default.fileExists(atPath: file.path) {
                fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
                guard fixture.channelID == channel.id, fixture.creatorID == me.user_id else { return false }
                print("Reusing existing fixture; no messages automatically retried.")
            } else {
                guard create else { print("No thread fixture exists."); return false }
                fixture = Fixture(channelID: channel.id, creatorID: me.user_id,
                    text: "Native pagination test " + UUID().uuidString.prefix(8) + ".")
                try save(fixture)
                let root = try await api.sendText(channelID: channel.id, text: fixture.text, connectionID: "")
                fixture.rootID = root.id
                try save(fixture)
            }
            if create, let rootID = fixture.rootID, fixture.replyIDs.count < 31 {
                let canonicalRoot = try await api.post(channelID: channel.id, postID: rootID)
                guard canonicalRoot.creator_id == me.user_id, canonicalRoot.message == fixture.text else { return false }
                let existing = try await api.threadPosts(channelID: channel.id, rootID: rootID)
                for number in 1...31 {
                    let text = fixture.text + " Reply " + String(format: "%02d", number) + "."
                    let matches = existing.filter { $0.creator_id == me.user_id && $0.message == text && $0.type == "normal" }
                    guard matches.count <= 1 else { return false }
                    if let known = matches.first {
                        if !fixture.replyIDs.contains(known.id) { fixture.replyIDs.append(known.id); try save(fixture) }
                        continue
                    }
                    // Respect the server's post-create rate limit; never burst the fixture.
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    // Canonical reads above reconcile the partial fixture before any new write.
                    let reply = try await api.sendText(channelID: channel.id, text: text,
                        connectionID: connectionID, threadID: rootID)
                    let canonical = try await api.post(channelID: channel.id, postID: reply.id, threadID: rootID)
                    guard canonical.thread_id == rootID, canonical.message == text else { throw ChatAPIError.invalidResponse }
                    fixture.replyIDs.append(reply.id)
                    try save(fixture)
                }
                print("Controlled fixture now contains one labelled root and 31 replies in Peter.")
            }
            guard let rootID = fixture.rootID, fixture.replyIDs.count == 31 else {
                print("Fixture is partial; inspect before any retry."); return false
            }
            let root = try await api.post(channelID: channel.id, postID: rootID)
            guard root.creator_id == me.user_id, root.message == fixture.text, root.type == "normal" else { return false }
            let latest = try await api.threadPosts(channelID: channel.id, rootID: rootID)
            let replies = latest.filter { $0.id != rootID }
            guard let oldest = replies.map(\.id).min(), replies.count >= 29 else { return false }
            let earlier = try await api.threadPosts(channelID: channel.id, rootID: rootID, before: oldest)
            let merged = ChatTimeline.merge(replies, earlier.filter { $0.id != rootID })
            guard Set(fixture.replyIDs).isSubset(of: Set(merged.map(\.id))) else {
                print("Thread pagination lost one or more synthetic replies."); return false
            }
            print("Live thread pagination verified: \(merged.count) replies across two pages. Root ID: \(rootID).")
            return true
        } catch ChatAPIError.server(let code) {
            print("Server rejected the controlled thread operation, code: \(code). No automatic resend.")
            return false
        } catch {
            print("Thread probe stopped; delivery may be uncertain. No automatic resend. Session details suppressed.")
            return false
        }
    }
}
