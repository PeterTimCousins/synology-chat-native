#if DEBUG
import Foundation
import Combine
import CryptoKit

/// Bounded real-socket recovery check. Only the authorized two-Peter DM is
/// writable. Persist intent before every mutation and never replay a receipt.
@MainActor enum ChatCollectionRecoveryProbe {
    private struct Receipt: Codable {
        var phase = "preflight"
        var scopeSHA256: String
        var channelID: Int64
        var postID: Int64?
        var dispatched: [String] = []
        var checks: [String:Bool] = [:]
        var fileCount = 0
        var savedCount = 0
        var pinCount = 0
        var linkCount = 0
    }
    static func run(receiptURL: URL) async -> Bool {
        guard !FileManager.default.fileExists(atPath:receiptURL.path) else {
            print("Recovery receipt already exists; no automatic replay.");return false
        }
        let model = NativeChatPreviewModel(restoreNotificationPreference:false)
        let links = NativeConversationLibraryStore(), saved = NativeConversationLibraryStore(), files = NativeConversationLibraryStore(), pins = NativeConversationLibraryStore()
        let stores = [links,saved,files,pins]
        var subscriptions = Set<AnyCancellable>()
        var receipt: Receipt?
        var client: ChatAPIClient?
        var ownID: Int64?
        let text = "Native collection reconnect test 20261020 — https://www.synology.com/en-global/dsm/feature/chat?native_recovery_test=20261020"
        let edited = "Native collection reconnect test 20261020 — URL removed while disconnected."
        func save(_ phase: String) throws {
            receipt?.phase = phase
            try JSONEncoder().encode(receipt).write(to:receiptURL,options:.atomic)
        }
        func dispatch(_ operation: String) throws {
            guard receipt?.dispatched.contains(operation) == false else { throw ChatAPIError.invalidResponse }
            receipt?.dispatched.append(operation);try save(operation + "_dispatched")
        }
        func require(_ condition: Bool) throws { if !condition { throw ChatAPIError.invalidResponse } }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            throw ChatTransferError(message:"Recovery observation timed out; no writes retried.")
        }
        func settled() -> Bool { stores.allSatisfy { !$0.loading && $0.failure == nil } }
        func cleanup() async throws {
            guard let client,let id = receipt?.postID,let ownID else { return }
            if receipt?.dispatched.contains("delete") == true { return }
            let current = try await client.post(channelID:93,postID:id)
            try require(current.creator_id == ownID && current.channel_id == 93 && current.type == "normal" && [text,edited].contains(current.message))
            // Deleting this own disposable post also removes its personal bookmark.
            try dispatch("delete");try await client.deletePost(postID:id)
            do { let post = try await client.post(channelID:93,postID:id);try require((post.delete_at ?? 0) > 0) }
            catch ChatAPIError.server(let code) { try require(code == 402) }
            receipt?.checks["soft_delete_confirmed"] = true;try save("deleted_confirmed")
        }
        defer { subscriptions.removeAll();stores.forEach { $0.clear() };model.disconnectLive() }
        do {
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session:account.session);client = api;try await api.discover()
            let target = try await ChatAuthorizedTestTarget.peter(api:api,username:account.username)
            let users = try await api.users(),me = users.first { $0.username?.caseInsensitiveCompare(account.username) == .orderedSame }
            ownID = me?.user_id
            let members = try await api.members(channelID:93)
            try require(target.id == 93 && me?.user_id == 10 && Set(members) == Set([6,10]))
            let recent = try await api.posts(channelID:93)
            try require(!recent.contains { [text,edited].contains($0.message) })
            let identity = account.session.baseURL.absoluteString + "|10"
            receipt = .init(scopeSHA256:SHA256.hash(data:Data(identity.utf8)).map { String(format:"%02x",$0) }.joined(),channelID:93)
            try save("preflight")
            await model.connect(using:account);try await waitFor { model.connected && model.liveStatus == .live }
            model.selection = 93;model.loadSelection();try await waitFor { !model.loadingHistory }
            let watch = UUID();model.watchCollection(watch,channelID:nil)
            model.collectionChanges.sink { change in stores.forEach { $0.receive(change) } }.store(in:&subscriptions)
            model.collectionResyncs.sink { account in stores.forEach { $0.recover(accountGeneration:account) } }.store(in:&subscriptions)
            let epoch = model.accountGeneration
            let linkLoader:NativeConversationLibraryStore.Loader = { query,offset,filters in try await model.searchMessages(query:query,channelID:93,offset:offset,filters:filters) }
            let savedLoader:NativeConversationLibraryStore.Loader = { query,offset,filters in try await model.searchMessages(query:query,channelID:nil,offset:offset,filters:filters) }
            let fileLoader:NativeConversationLibraryStore.Loader = { query,offset,_ in try await model.conversationFiles(channelID:93,query:query,offset:offset,options:.init()) }
            links.load(kind:.links,query:"",channelID:93,accountGeneration:epoch,using:linkLoader)
            saved.load(kind:.bookmarks,query:"",channelID:nil,accountGeneration:epoch,using:savedLoader)
            files.load(kind:.files,query:"",channelID:93,accountGeneration:epoch,using:fileLoader)
            pins.load(kind:.pins,query:"",channelID:93,accountGeneration:epoch) { query,offset,_ in try await model.pinnedMessages(channelID:93,query:query,offset:offset) }
            try await waitFor { settled() }
            try require(files.hasMore)
            files.load(kind:.files,query:"",channelID:93,more:true,accountGeneration:epoch,using:fileLoader);try await waitFor { settled() }
            let fileIDs = files.posts.map(\.id),pinIDs = pins.posts.map(\.id),savedIDs = saved.posts.map(\.id),linkIDs = ChatLinkLibrary.entries(links.posts).map(\.id)
            receipt?.fileCount = fileIDs.count;receipt?.pinCount = pinIDs.count;receipt?.savedCount = savedIDs.count;receipt?.linkCount = linkIDs.count
            model.draft = "Synthetic unsent recovery draft"
            model.suspendLiveForProbe();try require(model.liveStatus == .offline)
            try dispatch("create");let sent = try await api.sendText(channelID:93,text:text,connectionID:"")
            receipt?.postID = sent.id;try save("created")
            try dispatch("bookmark");try await api.setBookmark(postID:sent.id,enabled:true);try save("bookmarked")
            // URL indexing is asynchronous and does not depend on socket replay.
            for _ in 0..<100 {
                let post = try await api.post(channelID:93,postID:sent.id)
                if !(post.url_props ?? []).isEmpty && post.is_star == true { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            try require(!links.posts.contains{$0.id == sent.id} && !saved.posts.contains{$0.id == sent.id})
            receipt?.checks["offline_creation_not_received"] = true
            model.resumeLiveForProbe();try await waitFor { model.liveStatus == .live && settled() && links.posts.contains{$0.id == sent.id} && saved.posts.contains{$0.id == sent.id} }
            receipt?.checks["missed_create_and_save_recovered"] = true
            try require(files.posts.map(\.id) == fileIDs && pins.posts.map(\.id) == pinIDs && model.draft == "Synthetic unsent recovery draft")
            receipt?.checks["two_file_pages_pins_and_draft_preserved"] = true
            model.suspendLiveForProbe();try require(model.liveStatus == .offline)
            let before = try await api.post(channelID:93,postID:sent.id)
            try dispatch("edit");try await api.setPost(before,text:edited);try save("edited")
            try dispatch("unbookmark");try await api.setBookmark(postID:sent.id,enabled:false);try save("unbookmarked")
            try require(links.posts.contains{$0.id == sent.id} && saved.posts.contains{$0.id == sent.id})
            receipt?.checks["offline_removal_not_received"] = true
            model.resumeLiveForProbe();try await waitFor { model.liveStatus == .live && settled() && !links.posts.contains{$0.id == sent.id} && !saved.posts.contains{$0.id == sent.id} && model.posts.contains{$0.id == sent.id && $0.message == edited} }
            receipt?.checks["missed_edit_and_unstar_recovered"] = true
            model.suspendLiveForProbe();try require(model.liveStatus == .offline)
            try await cleanup()
            try require(model.posts.contains{$0.id == sent.id})
            model.resumeLiveForProbe();try await waitFor { model.liveStatus == .live && !model.loadingHistory && settled() && !model.posts.contains{$0.id == sent.id} }
            receipt?.checks["missed_delete_recovered"] = true
            try require(files.posts.map(\.id) == fileIDs && pins.posts.map(\.id) == pinIDs && saved.posts.map(\.id) == savedIDs && ChatLinkLibrary.entries(links.posts).map(\.id) == linkIDs)
            receipt?.checks["original_collection_membership_restored"] = true
            try save("verified_and_restored")
            print("Real socket recovery verified: missed creation/save, edit/unstar and deletion; loaded file pages and other collections preserved; synthetic post soft-deleted.")
            return true
        } catch {
            // Cleanup is bounded to the exact new post, never an existing item.
            do { try await cleanup() } catch { print("Cleanup unresolved; inspect receipt before any further write.") }
            try? save("verification_failed")
            print("Collection recovery probe stopped; inspect redacted receipt. No automatic replay.")
            return false
        }
    }
}
#endif
