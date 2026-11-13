#if DEBUG
import Foundation
import CryptoKit

/// Only the successful exclusive creator may update a no-retry receipt.
struct ChatOwnEditProbeReceipt {
    let file:URL
    private(set) var owned = false
    mutating func claim(_ report:[String:Any]) throws {
        guard file.isFileURL,!owned else { throw ChatAPIError.invalidResponse }
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:file,options:.withoutOverwriting)
        owned = true
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func save(_ report:[String:Any]) throws {
        guard owned else { throw ChatAPIError.invalidResponse }
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}

/// Current-model/backend acceptance only. No window, Keychain, session copy on
/// disk, logout/revocation, or production authentication-policy exception.
@MainActor enum ChatOwnEditLiveProbe {
    static func run(receipt:URL) async -> Bool {
        guard CommandLine.arguments.contains("--disable-native-read-state"),receipt.isFileURL,
              !FileManager.default.fileExists(atPath:receipt.path) else {
            print("Edit probe requires disabled read receipts and a fresh receipt path. Nothing repeated.");return false
        }
        let controlPolicy = ChatOwnEditProbePolicy(role:.control),modelPolicy = ChatOwnEditProbePolicy(role:.model)
        var ledger = ChatOwnEditProbeReceipt(file:receipt)
        var report:[String:Any] = ["state":"initialized","channel_id":93,"member_ids":[6,10],
                                  "scope":"fresh synthetic own-Peter message only","model_build":"DEBUG",
                                  "physical_ui_verified":false,"optimized_auth_verified":false]
        var model:NativeChatPreviewModel?
        func save() throws {
            try ledger.save(report)
        }
        func snapshot() throws {
            report["control_policy"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(controlPolicy.snapshot()))
            report["model_policy"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(modelPolicy.snapshot()))
        }
        defer { controlPolicy.forbidWrites();modelPolicy.forbidWrites();model?.disconnectLive();model?.signOutLocally() }
        do {
            // Exclusive creation prevents a reused/ambiguous receipt from
            // silently becoming another create, even if an earlier run died.
            try ledger.claim(report)
            let account = try OfficialChatSessionLoader.load()
            guard account.importedFromOfficialApp,NativeChatAppConfiguration.allowsOfficialSessionImport else { throw ChatAPIError.invalidResponse }
            let control = try ChatAPIClient(session:account.session)
            control.debugRequestGuard = { try controlPolicy.check($0) }
            try await control.discover()
            func target() async throws -> ChatPeterProbeTarget {
                let users = try await control.users(),channels = try await control.channels(),members = try await control.members(channelID:93)
                return try ChatPeterProbeTarget.resolve(username:account.username,users:users,channels:channels,members:members)
            }
            let verified = try await target()
            report["owner_id"] = verified.ownerID;report["peer_id"] = verified.peerID;report["state"] = "scope_verified";try save()
            let current = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
                let api = try ChatAPIClient(session:session);api.debugRequestGuard = { try modelPolicy.check($0) };return api
            },downloadPreferences:.init(defaults:nil),emojiPreferences:.init(defaults:nil),draftStore:nil,notificationDefaults:nil)
            model = current
            await current.connect(using:account)
            for _ in 0..<250 {
                if current.liveStatus == .live { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            guard current.connected,current.liveStatus == .live,current.userID == verified.ownerID,!current.notificationsEnabled,
                  modelPolicy.snapshot().rejectedCount == 0,controlPolicy.snapshot().rejectedCount == 0 else { throw ChatAPIError.invalidResponse }
            current.selection = 93;current.loadSelection();await current.historyTask?.value
            guard current.error == nil,!current.loadingHistory,current.canRead(93),current.liveStatus == .live else { throw ChatAPIError.invalidResponse }
            let nonce = UUID().uuidString
            let initial = "Native edit verification \(nonce). Initial synthetic message."
            let accepted = "Native edit verification \(nonce). Edited café e\u{301} 😀\nSecond synthetic line."
            let remote = "Native edit verification \(nonce). Changed by the other test client."
            let refused = "Native edit verification \(nonce). This stale draft must not be sent."
            func hash(_ text:String)->String { SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
            report["initial_sha256"] = hash(initial);report["accepted_sha256"] = hash(accepted)
            report["other_client_sha256"] = hash(remote);report["refused_sha256"] = hash(refused)
            guard try await target() == verified else { throw ChatAPIError.invalidResponse }
            try controlPolicy.allowCreate(text:initial)
            report["state"] = "create_dispatching";try save()
            let created = try await control.sendText(channelID:93,text:initial,connectionID:"")
            report["post_id"] = created.id;report["state"] = "create_responded";try save()
            let original = try await control.post(channelID:93,postID:created.id)
            guard original.id > 0,original.channel_id == 93,original.creator_id == verified.ownerID,original.type == "normal",
                  !original.isReply,(original.delete_at ?? 0) == 0,original.message.utf8.elementsEqual(initial.utf8) else { throw ChatAPIError.invalidResponse }
            current.loadSelection(preservingThread:true,preservingViewport:true);await current.historyTask?.value
            guard current.error == nil,current.posts.contains(where:{ $0.id == original.id }) else { throw ChatAPIError.invalidResponse }
            let owner = UUID();current.beginMessageEditing(owner:owner,post:original)
            guard let session = current.messageEditorSession(owner:owner),try await target() == verified else { throw ChatAPIError.invalidResponse }
            try modelPolicy.allowSet(postID:original.id,text:accepted)
            report["state"] = "model_edit_dispatching";try save()
            guard await current.edit(original,text:accepted,owner:owner,session:session) else { throw ChatAPIError.invalidResponse }
            let confirmed = try await control.post(channelID:93,postID:original.id)
            guard confirmed.creator_id == verified.ownerID,confirmed.channel_id == 93,!confirmed.isReply,
                  confirmed.message.utf8.elementsEqual(accepted.utf8),modelPolicy.snapshot().setAttempts == 1,
                  modelPolicy.snapshot().createAttempts == 0,modelPolicy.snapshot().rejectedCount == 0 else { throw ChatAPIError.invalidResponse }
            report["model_edit_confirmed"] = true;report["state"] = "model_edit_confirmed";try save()
            current.endMessageEditing(owner:owner)
            let staleOwner = UUID();current.beginMessageEditing(owner:staleOwner,post:confirmed)
            guard let staleSession = current.messageEditorSession(owner:staleOwner),try await target() == verified else { throw ChatAPIError.invalidResponse }
            current.draft = "Synthetic separate composer draft — \(nonce)"
            let composer = current.draft
            // The same authenticated own account, separate client: no attempt
            // to edit the peer's messages or any pre-existing user content.
            modelPolicy.forbidWrites()
            try controlPolicy.allowSet(postID:original.id,text:remote)
            report["state"] = "other_client_edit_dispatching";try save()
            try await control.setPost(confirmed,text:remote)
            let changed = try await control.post(channelID:93,postID:original.id)
            guard changed.creator_id == verified.ownerID,changed.channel_id == 93,!changed.isReply,
                  changed.message.utf8.elementsEqual(remote.utf8) else { throw ChatAPIError.invalidResponse }
            // Explicit real recovery read ensures the currently rendered model
            // has the new canonical post. This is not an incoming-socket claim.
            current.loadSelection(preservingThread:true,preservingViewport:true);await current.historyTask?.value
            guard current.error == nil,let rendered = current.posts.first(where:{ $0.id == original.id }),
                  rendered.message.utf8.elementsEqual(remote.utf8),current.messageEditorSession(owner:staleOwner) == staleSession,
                  try await target() == verified else { throw ChatAPIError.invalidResponse }
            let before = modelPolicy.snapshot()
            report["state"] = "model_conflict_checking";try save()
            let result = await current.edit(rendered,text:refused,owner:staleOwner,session:staleSession)
            let after = modelPolicy.snapshot()
            let expectedError = NativeLocalizedStrings.text("This message changed since you started editing. Your draft is kept. Cancel this edit to review the latest version.")
            guard !result,current.error == expectedError,after.setAttempts == before.setAttempts,after.createAttempts == 0,
                  after.rejectedCount == 0,current.activeMessageEditor == staleOwner,current.messageEditorSession(owner:staleOwner) == staleSession,
                  current.draft == composer,current.pendingMessageActions.isEmpty,
                  current.posts.first(where:{ $0.id == original.id })?.message.utf8.elementsEqual(remote.utf8) == true else { throw ChatAPIError.invalidResponse }
            let final = try await control.post(channelID:93,postID:original.id)
            guard final.creator_id == verified.ownerID,final.channel_id == 93,final.message.utf8.elementsEqual(remote.utf8),
                  controlPolicy.snapshot().createAttempts == 1,controlPolicy.snapshot().setAttempts == 1,
                  controlPolicy.snapshot().rejectedCount == 0 else { throw ChatAPIError.invalidResponse }
            report["conflict_refused"] = true;report["conflict_model_set_attempts"] = after.setAttempts-before.setAttempts
            report["owner_and_session_retained"] = true;report["separate_composer_draft_retained"] = true
            report["fresh_server_other_client_content_retained"] = true
            controlPolicy.forbidWrites();modelPolicy.forbidWrites();current.disconnectLive();current.signOutLocally();model = nil
            report["state"] = "verified";try snapshot();try save()
            print("Verified current-model edit and zero-attempt conflict refusal in own Peter conversation93. Shared sign-in retained.")
            return true
        } catch {
            controlPolicy.forbidWrites();modelPolicy.forbidWrites();model?.disconnectLive();model?.signOutLocally();model = nil
            report["failed_at"] = report["state"];report["state"] = "stopped_no_retry"
            if case ChatAPIError.server(let code) = error { report["server_error_code"] = code }
            if ledger.owned { try? snapshot();try? save() }
            print("Own-Peter edit verification stopped. Inspect the safe receipt; no request is automatically repeated.")
            return false
        }
    }
}
#endif
