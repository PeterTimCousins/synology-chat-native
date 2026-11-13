#if DEBUG
import Foundation

struct ChatAppearanceRoundTripResult: Codable {
    let changedConfirmed: Bool
    let restored: Bool
    let ending: ChatAppearanceSettings?
    let state: String
}

/// Bounded own-preference check: one alternate background, at most one restore.
/// A concurrently changed background is never overwritten during restoration.
enum ChatAppearanceRoundTrip {
    static func perform(original: ChatAppearanceSettings,
                        read: () async throws -> ChatAppearanceSettings,
                        write: (ChatAppearanceSettingsPatch) async throws -> Void,
                        recordBeforeChange: (ChatAppearanceSettings) throws -> Void) async -> ChatAppearanceRoundTripResult {
        let next = ChatAppearanceBackground(rawValue: (original.background.rawValue + 1) % 4)!
        let alternate = ChatAppearanceSettings(style: original.style, background: next)
        do {
            let fresh = try await read()
            guard fresh.background == original.background else {
                return .init(changedConfirmed: false, restored: false, ending: fresh, state: "changed_elsewhere_no_dispatch")
            }
            try Task.checkCancellation()
            try recordBeforeChange(alternate)
        } catch {
            return .init(changedConfirmed: false, restored: false, ending: nil, state: "not_dispatched")
        }
        // Even a lost change acknowledgement must proceed to a fresh read before
        // deciding whether a single guarded restore is necessary.
        var changeAcknowledged = false
        var changedConfirmed = false
        do {
            try await write(ChatAppearanceSettingsPatch(original: original, desired: alternate))
            changeAcknowledged = true
        } catch { }
        do {
            let changed = try await read()
            if changed.background == original.background {
                return .init(changedConfirmed: false, restored: changeAcknowledged, ending: changed,
                             state: changeAcknowledged ? "original_confirmed_change_not_observed" : "change_outcome_unknown_original_observed")
            }
            guard changed.background == next else {
                return .init(changedConfirmed: false, restored: false, ending: changed, state: "changed_elsewhere_no_restore")
            }
            changedConfirmed = true
            let beforeRestore = try await read()
            guard beforeRestore.background == next else {
                return .init(changedConfirmed: true, restored: beforeRestore.background == original.background,
                             ending: beforeRestore, state: "changed_before_restore_no_dispatch")
            }
            // Preserve an unrelated theme change made by another client.
            let restored = ChatAppearanceSettings(style: beforeRestore.style, background: original.background)
            do { try await write(ChatAppearanceSettingsPatch(original: beforeRestore, desired: restored)) } catch { }
            let ending = try await read()
            return .init(changedConfirmed: true, restored: ending.background == original.background,
                         ending: ending, state: ending.background == original.background ? "changed_and_restored" : "restore_unconfirmed_no_repeat")
        } catch {
            return .init(changedConfirmed: changedConfirmed, restored: false, ending: nil, state: "read_unavailable_no_repeat")
        }
    }
}

enum ChatAppearanceRoundTripProbe {
    static func run(receipt: URL) async -> Bool {
        var report: [String: Any] = ["state": "not_dispatched", "scope": "Own Peter account appearance; no messages or other-user operations"]
        do {
            guard !FileManager.default.fileExists(atPath: receipt.path) else {
                print("Receipt exists. No appearance operation repeated."); return false
            }
            try save(report, receipt, initially: true)
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let owners = try await api.users().filter { $0.username?.caseInsensitiveCompare(account.username) == .orderedSame }
            guard owners.count == 1, let owner = owners.first, [6, 10].contains(owner.user_id),
                  owner.is_disabled != true, (owner.delete_at ?? 0) == 0,
                  let scope = ChatNotificationAccountScope.make(account: account, userID: owner.user_id) else { throw ChatAPIError.invalidResponse }
            let original = try await api.appearanceSettings()
            report["owner_id"] = owner.user_id; report["account_scope"] = scope
            report["original"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
            let result = await ChatAppearanceRoundTrip.perform(original: original, read: { try await api.appearanceSettings() }, write: { try await api.setAppearanceSettings($0) }, recordBeforeChange: { alternate in
                report["alternate"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(alternate))
                report["state"] = "change_dispatching"
                try save(report, receipt)
            })
            report["result"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)); report["state"] = result.state
            try save(report, receipt)
            print("Own appearance check: \(result.state); original background restored: \(result.restored). No messages sent.")
            return result.changedConfirmed && result.restored
        } catch {
            try? save(report, receipt)
            print("Appearance check could not finish. Inspect its private receipt before any further action; no automatic replay.")
            return false
        }
    }
    private static func save(_ report: [String: Any], _ receipt: URL, initially: Bool = false) throws {
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try bytes.write(to: receipt, options: initially ? .withoutOverwriting : .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
    }
}
#endif
