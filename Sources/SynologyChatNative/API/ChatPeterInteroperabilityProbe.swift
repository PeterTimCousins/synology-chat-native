#if DEBUG
import Foundation

/// A deliberately pinned development target. Display names may change; account
/// identity and exact current membership cannot broaden this test's audience.
struct ChatPeterProbeTarget: Equatable {
    let ownerID: Int64
    let peerID: Int64
    static func resolve(username: String, users: [ChatUser], channels: [ChatChannel], members: [Int64]) throws -> Self {
        let owned: Set<Int64> = [6, 10]
        let matches = users.filter { $0.username?.caseInsensitiveCompare(username) == .orderedSame }
        guard !username.isEmpty, users.allSatisfy({ $0.user_id > 0 }), Set(users.map(\.user_id)).count == users.count,
              matches.count == 1, let owner = matches.first, owned.contains(owner.user_id),
              owner.is_disabled != true, (owner.delete_at ?? 0) == 0,
              users.contains(where: { $0.user_id == (owner.user_id == 6 ? 10 : 6) }),
              channels.filter({ $0.id == 93 }).count == 1,
              let channel = channels.first(where: { $0.id == 93 }), channel.type == "anonymous",
              !channel.encrypted, channel.is_closed != true, channel.is_joined != false,
              members.count == 2, Set(members) == owned else {
            throw ChatTransferError(message: "The two Peter-owned accounts and conversation93 could not be verified. No message sent.")
        }
        return .init(ownerID: owner.user_id, peerID: owner.user_id == 6 ? 10 : 6)
    }
}

enum ChatPeterInteroperabilityProbe {
    static func run(receipt: URL, send: Bool, expectedReply: String? = nil) async -> Bool {
        var report: [String: Any] = ["scope": "Only verified Peter accounts6+10, conversation93", "send_requested": send, "state": "not_dispatched"]
        var dispatched = false
        do {
            guard expectedReply == nil || (!send && expectedReply!.hasPrefix("Native daily-use reply — ") && expectedReply!.utf8.count <= 256) else { throw ChatAPIError.invalidResponse }
            guard !FileManager.default.fileExists(atPath: receipt.path) else {
                print("This probe receipt already exists. No request repeated."); return false
            }
            // Persist before any possible dispatch; a failed observation cannot
            // turn a rerun with this receipt into a second message.
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: receipt, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let users = try await api.users(), channels = try await api.channels()
            let target = try ChatPeterProbeTarget.resolve(username: account.username, users: users, channels: channels,
                                                        members: await api.members(channelID: 93))
            report["owner_id"] = target.ownerID; report["peer_id"] = target.peerID; report["channel_id"] = 93
            // Only the two already verified owned identities are exposed for
            // matching UI destinations; never dump the account directory.
            for (label, id) in [("owner",target.ownerID),("peer",target.peerID)] {
                if let user = users.first(where: { $0.user_id == id }) {
                    report[label + "_name"] = user.nickname
                    report[label + "_username"] = user.username
                }
            }
            print("Verified signed-in account\(target.ownerID), peer\(target.peerID), exact members[6,10], conversation93.")
            if send {
                let marker = "Native daily-use test — peer\(target.ownerID) to Peter account\(target.peerID) — " + String(UUID().uuidString.prefix(8))
                report["marker"] = marker; report["state"] = "dispatching"
                try save(report, receipt)
                dispatched = true
                let post = try await api.sendText(channelID: 93, text: marker, connectionID: "")
                report["post_id"] = post.id
                let canonical = try await api.post(channelID: 93, postID: post.id)
                guard canonical.channel_id == 93, canonical.creator_id == target.ownerID,
                      canonical.type == "normal", canonical.thread_id == 0, canonical.message == marker else { throw ChatAPIError.invalidResponse }
                report["state"] = "confirmed"; report["canonical_readback"] = true
                print("One synthetic message sent. Exact author, channel, normal type and text verified; post\(post.id).")
            } else if let expectedReply {
                let matches = try await api.posts(channelID: 93).filter {
                    $0.creator_id == target.peerID && $0.type == "normal" && $0.thread_id == 0 && $0.message == expectedReply
                }
                guard matches.count == 1, let post = matches.first else { throw ChatAPIError.invalidResponse }
                let canonical = try await api.post(channelID: 93, postID: post.id)
                guard canonical.message == expectedReply, canonical.creator_id == target.peerID, canonical.channel_id == 93 else { throw ChatAPIError.invalidResponse }
                report["state"] = "native_reply_readback_verified"; report["reply_post_id"] = post.id
                report["reply_marker"] = expectedReply; report["canonical_readback"] = true
                print("Native UI reply verified from account\(target.peerID), post\(post.id), exact text and channel93.")
            } else { report["state"] = "read_only_verified" }
            try save(report, receipt)
            return true
        } catch {
            report["state"] = dispatched ? "uncertain_no_retry" : "not_dispatched"
            try? save(report, receipt)
            print(dispatched ? "The single message request could not be confirmed. No automatic retry." : ((error as? LocalizedError)?.errorDescription ?? "Identity verification failed. No message sent."))
            return false
        }
    }
    private static func save(_ report: [String: Any], _ file: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
#endif
