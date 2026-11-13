import Foundation
import CryptoKit

enum ChatAuthorizedTestTarget {
    static func peter(api: ChatAPIClient, username: String) async throws -> ChatChannel {
        let users = try await api.users()
        guard let me = users.first(where: { $0.username?.caseInsensitiveCompare(username) == .orderedSame }) else {
            throw ChatTransferError(message: "Cannot identify the current user. No test message sent.")
        }
        var candidates: [ChatChannel] = []
        for channel in try await api.channels() where channel.type == "anonymous" && !channel.encrypted {
            let ids = try await api.members(channelID: channel.id)
            let others = ids.filter { $0 != me.user_id }
            if ids.count == 2 && others.count == 1 && users.first(where: { $0.user_id == others[0] })?.nickname == "Peter" {
                candidates.append(channel)
            }
        }
        guard candidates.count == 1 else { throw ChatTransferError(message: "Peter DM is not unique. No test message sent.") }
        return candidates[0]
    }
}

@MainActor
enum ChatAttachmentProbe {
    static func run(inThread: Bool = false) async -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-chat-transfer-probe-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let relay = CommandLine.arguments.contains("--relay-only")
            let source = root.appendingPathComponent(relay ? "native-swift-relay-attachment-test.txt" : "native-swift-attachment-test.txt")
            let destination = root.appendingPathComponent("downloaded-test.txt")
            let data = Data("Synthetic native Swift attachment transfer test. No private data.\n".utf8)
            try data.write(to: source)
            let imported = try OfficialChatSessionLoader.load()
            let session: ChatSession
            if relay {
                guard let index = CommandLine.arguments.firstIndex(of: "--quickconnect-id"), index + 1 < CommandLine.arguments.count else {
                    print("Supply the authorized QuickConnect ID. No upload attempted."); return false
                }
                let resolved = try await ChatServerResolver().resolveServer(CommandLine.arguments[index + 1], relayOnly: true)
                let network = URLSession(configuration: .ephemeral, delegate: NoChatRedirects(), delegateQueue: nil)
                defer { network.invalidateAndCancel() }
                guard let identity = resolved.quickConnectIdentity,
                      await ChatServerResolver.matchesIdentity(imported.session.baseURL, expected: identity, network: network) else {
                    print("Relay identity does not match the authorized NAS. No upload attempted."); return false
                }
                session = ChatSession(baseURL: resolved.baseURL, sid: imported.session.sid, synoToken: imported.session.synoToken, tlsServerName: resolved.tlsServerName)
            } else { session = imported.session }
            let api = try ChatAPIClient(session: session)
            try await api.discover()
            let target = try await ChatAuthorizedTestTarget.peter(api: api, username: imported.username)
            var rootID: Int64 = 0
            if inThread {
                let fixture = try JSONDecoder().decode(ChatThreadProbe.Fixture.self, from: Data(contentsOf: ChatThreadProbe.file))
                guard fixture.channelID == target.id, let id = fixture.rootID else { return false }
                let root = try await api.post(channelID: target.id, postID: id)
                guard root.creator_id == fixture.creatorID, root.message == fixture.text,
                      fixture.text.hasPrefix("Native pagination test ") else { return false }
                rootID = id
            }
            let live = ChatLiveConnection(session: session, version: try await api.runtimeVersion())
            live.start()
            defer { live.stop() }
            for _ in 0..<100 where live.connectionID == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            guard let connectionID = live.connectionID else { throw ChatAPIError.connection }
            let post = try await api.uploadAttachment(channelID: target.id, file: source,
                caption: relay ? "Native relay attachment verification — Peter." : inThread ? "Native Swift thread attachment test." : "Native Swift attachment test.",
                connectionID: connectionID, threadID: rootID)
            let canonical = try await api.post(channelID: target.id, postID: post.id, threadID: rootID == 0 ? nil : rootID)
            guard canonical.type == "file", (canonical.thread_id ?? 0) == rootID,
                  canonical.file_props?.name == source.lastPathComponent else {
                print("Attachment canonical type or thread metadata mismatch. No retry."); return false
            }
            print(inThread ? "Native synthetic attachment verified inside the authorized Peter test thread." : "Native synthetic attachment verified as an ordinary file in Peter.")
            try await api.saveAttachment(postID: post.id, to: destination)
            guard try Data(contentsOf: destination) == data else { print("Attachment readback mismatch."); return false }
            print("Native attachment download verified byte for byte.")
            if relay {
                let receipt: [String: Any] = ["channel_id": target.id, "post_id": post.id, "type": canonical.type,
                    "thread_id": canonical.thread_id ?? 0, "filename": source.lastPathComponent, "bytes": data.count,
                    "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    "byte_equal": true, "relay": true, "keychain_access": false, "session_revoked": false]
                try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                    .write(to: URL(fileURLWithPath: "/private/tmp/synology-native-relay-attachment-result.json"), options: .atomic)
                print("Native relay upload and download verified in the authorized Peter DM.")
            }
            return true
        } catch {
            print((error as? ChatTransferError)?.errorDescription ?? (error as? ChatAPIError)?.errorDescription ?? "Attachment probe failed; details suppressed.")
            return false
        }
    }
}
