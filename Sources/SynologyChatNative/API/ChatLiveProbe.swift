import Foundation

/// Explicit development command. One test message, only to a uniquely resolved two-person Peter DM.
@MainActor
enum ChatLiveProbe {
    static func run(sendTest: Bool) async -> Bool {
        do {
            let imported = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: imported.session)
            try await api.discover()
            let version = try await api.runtimeVersion()
            let live = ChatLiveConnection(session: imported.session, version: version)
            defer { live.stop() }
            var events: [ChatLiveEvent] = []
            var ready = false
            var readyCount = 0
            if CommandLine.arguments.contains("--force-reconnect") {
                live.onStatus = { print("Native diagnostic: " + $0.title) }
            }
            live.onReady = { ready = true; readyCount += 1 }
            live.onEvent = { events.append($0) }
            live.start()
            for _ in 0..<100 where !ready { try await Task.sleep(nanoseconds: 100_000_000) }
            guard ready else { print("Native socket handshake did not finish."); return false }
            print("Native Engine.IO / Socket.IO handshake verified.")
            if sendTest {
                let users = try await api.users()
                guard let me = users.first(where: { $0.username?.caseInsensitiveCompare(imported.username) == .orderedSame }) else {
                    print("Current user could not be identified. No message sent."); return false
                }
                let channels = try await api.channels()
                var targets: [ChatChannel] = []
                for channel in channels where channel.type == "anonymous" && !channel.encrypted {
                    let ids = try await api.members(channelID: channel.id)
                    let others = ids.filter { $0 != me.user_id }
                    if ids.count == 2 && others.count == 1 && users.first(where: { $0.user_id == others[0] })?.nickname == "Peter" {
                        targets.append(channel)
                    }
                }
                guard targets.count == 1 else { print("Peter DM was not unique. No message sent."); return false }
                let target = targets[0]
                // Empty origin connection ID lets this independent observer receive the creation event.
                let sent = try await api.sendText(channelID: target.id, text: "Native interoperability test — normal message type.", connectionID: "")
                print("One native Swift test message sent to Peter.")
                for _ in 0..<100 where !events.contains(where: { $0.postID == sent.id }) {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard events.contains(where: { $0.name == "client.post.create" && $0.postID == sent.id && $0.channelID == target.id }) else {
                    print("Send succeeded, but its live event was not observed."); return false
                }
                let canonical = try await api.post(channelID: target.id, postID: sent.id)
                guard canonical.message == sent.message, canonical.type == "normal", canonical.thread_id == 0 else {
                    print("Canonical message type, text or thread readback mismatch."); return false
                }
                print("Native live event and canonical post readback verified.")
            }
            for _ in 0..<70 where live.receivedHeartbeatCount == 0 { try await Task.sleep(nanoseconds: 500_000_000) }
            guard live.receivedHeartbeatCount > 0 else { print("Heartbeat response was not observed."); return false }
            print("Native heartbeat verified.")
            #if DEBUG
            if CommandLine.arguments.contains("--force-reconnect") {
                let previous = live.connectionID
                live.interruptTransportForProbe()
                for _ in 0..<150 where readyCount < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
                guard readyCount >= 2, let replacement = live.connectionID, replacement != previous else {
                    print("Native forced reconnect did not establish a replacement connection."); return false
                }
                print("Native forced transport loss and automatic reconnection verified.")
            }
            #endif
            return true
        } catch {
            print((error as? LocalizedError)?.errorDescription ?? "Native live probe failed.")
            return false
        }
    }
}
