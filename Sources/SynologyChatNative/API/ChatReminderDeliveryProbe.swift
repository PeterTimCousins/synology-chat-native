#if DEBUG
import Foundation
import CryptoKit
import UserNotifications

/// One personal reminder on an existing own synthetic Peter post. No authored
/// messages. Any automatic copy is confined to the verified self-only My Space.
@MainActor enum ChatReminderDeliveryProbe {
    private struct Receipt:Codable {
        var phase = "preflight"
        var scope: String
        var sourceID: Int64 = 399431958766
        var channelID: Int64 = 93
        var personalChannelID: Int64 = 10
        var due: Double?
        var copyID: Int64?
        var copyCreator: Int64?
        var copyType: String?
        var forwardType: String?
        var notificationEvent = false
        var notificationPostKeys: [String] = []
        var notificationPropertyKeys: [String] = []
        var factoryAccepted = false
        var deliveredToMacOS = false
        var deliveryBodySHA256: String?
        var dispatched: [String] = []
        var baselinePersonalIDs: [Int64] = []
        var checks: [String:Bool] = [:]
    }
    static func run(receiptURL:URL,cleanup:Bool = false) async -> Bool {
        let sourceText = "Native scheduled delivery test — Peter."
        var receipt:Receipt?
        var connection:ChatLiveConnection?
        func require(_ value:Bool) throws { if !value { throw ChatAPIError.invalidResponse } }
        func save(_ phase:String) throws {
            receipt?.phase = phase;let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(receipt).write(to:receiptURL,options:.atomic)
        }
        func dispatch(_ name:String) throws {
            try require(receipt?.dispatched.contains(name) == false);receipt?.dispatched.append(name);try save(name+"_dispatched")
        }
        defer { connection?.stop() }
        do {
            let account = try OfficialChatSessionLoader.load(),api = try ChatAPIClient(session:account.session)
            try await api.discover();let users = try await api.users()
            let me = users.first{$0.username?.caseInsensitiveCompare(account.username) == .orderedSame}
            let peter = try await ChatAuthorizedTestTarget.peter(api:api,username:account.username)
            let members = try await api.members(channelID:93),channels = try await api.channels()
            let spaces = channels.filter{$0.type == "synobot" && $0.creator_id == 10}
            try require(me?.user_id == 10 && peter.id == 93 && Set(members) == Set([6,10]) && spaces.count == 1 && spaces[0].id == 10)
            let privateMembers = try await api.members(channelID:10);try require(privateMembers == [10])
            let source = try await api.post(channelID:93,postID:399431958766)
            try require(source.creator_id == 10 && source.type == "normal" && source.message == sourceText)
            guard let scope = ChatNotificationAccountScope.make(account:account,userID:10) else { throw ChatAPIError.invalidResponse }
            if cleanup {
                receipt = try JSONDecoder().decode(Receipt.self,from:Data(contentsOf:receiptURL))
                try require(receipt?.scope == scope && receipt?.sourceID == source.id && receipt?.channelID == 93 && receipt?.personalChannelID == 10)
                if let due = receipt?.due {
                    let current = try await api.reminderTime(postID:source.id)
                    if current != 0 {
                        try require(current == due);try dispatch("remove_schedule");try await api.removeReminder(postID:source.id)
                    }
                    let remaining = try await api.reminderTime(postID:source.id);try require(remaining == 0)
                }
                if let id = receipt?.copyID {
                    let copy:ChatPost?
                    do { copy = try await api.post(channelID:10,postID:id) }
                    catch ChatAPIError.server(402) { copy = nil }
                    if let copy,(copy.delete_at ?? 0) == 0 {
                        try require(copy.channel_id == 10 && copy.creator_id == receipt?.copyCreator && (copy.creator_id == 10 || (copy.creator_id == 1 && users.contains(where: { $0.user_id == 1 && $0.type == "bot" }))) && copy.message == sourceText && copy.props?.forward?.isReminder == true && copy.props?.forward?.origin_post_id == source.id && copy.props?.forward?.origin_channel_id == 93 && copy.props?.forward?.origin_user_id == 10 && receipt?.checks["timed_private_copy_observed"] == true)
                        try dispatch("delete_copy");try await api.deletePost(postID:id)
                        do { let remaining = try await api.post(channelID:10,postID:id);try require((remaining.delete_at ?? 0) > 0) }
                        catch ChatAPIError.server(402) { }
                    }
                    if Bundle.main.bundleIdentifier == "com.costwisegroup.synology-chat-native.api-preview" {
                        let center = UNUserNotificationCenter.current(),delivered = await center.deliveredNotifications()
                        let ids = delivered.filter{$0.request.content.userInfo["nativePostID"] as? String == String(id) && $0.request.content.userInfo["nativeAccountScope"] as? String == scope}.map{$0.request.identifier}
                        center.removeDeliveredNotifications(withIdentifiers:ids)
                    }
                }
                receipt?.checks["schedule_removed"] = true;receipt?.checks["own_copy_absent"] = true
                try save("restored_confirmed");print("Exact personal reminder schedule/copy cleanup confirmed; no retry.");return true
            }
            try require(!FileManager.default.fileExists(atPath:receiptURL.path))
            let initial = try await api.reminderTime(postID:source.id);try require(initial == 0)
            let preferences = try await api.notificationPreferences(),clock = try await api.serverClock()
            try require(!preferences.pausesAlerts(at:clock.date(),timeZone:me?.profileTimeZone))
            let baseline = try await api.posts(channelID:10)
            receipt = Receipt(scope:scope,baselinePersonalIDs:baseline.map(\.id))
            try save("preflight")
            let version = try await api.runtimeVersion(),live = ChatLiveConnection(session:account.session,version:version)
            connection = live;var ready = false;var receivedCandidates:[ChatLiveEvent] = []
            live.onReady = { ready = true }
            live.onEvent = { event in
                let event = event.normalized
                guard event.name == "client.notification.create",event.payload["post"]?["channel_id"]?.integer == 10,
                      let id = event.payload["post"]?["post_id"]?.integer,!baseline.contains(where:{$0.id == id}) else { return }
                receivedCandidates.append(event)
                if receivedCandidates.count > 16 { receivedCandidates.removeFirst() }
            }
            live.start()
            for _ in 0..<200 where !ready { try await Task.sleep(nanoseconds:100_000_000) }
            try require(ready)
            let due = Date(timeIntervalSince1970:ceil((clock.date().timeIntervalSince1970+45)/60)*60)
            receipt?.due = due.timeIntervalSince1970*1000
            try dispatch("set");try await api.setReminder(postID:source.id,date:due)
            let saved = try await api.reminderTime(postID:source.id);try require(saved == receipt?.due)
            try save("waiting_for_delivery");print("One personal reminder scheduled; awaiting its real server event.")
            let deadline = due.addingTimeInterval(90);var copy:ChatPost?
            while clock.date() < deadline && copy == nil {
                try await Task.sleep(nanoseconds:2_000_000_000)
                let posts = try await api.posts(channelID:10)
                // Compare against the captured IDs, not a message-text search.
                copy = posts.first { post in !baseline.contains(where:{$0.id == post.id}) && post.channel_id == 10 && post.message == sourceText && post.props?.forward?.isReminder == true && post.props?.forward?.origin_post_id == source.id && post.props?.forward?.origin_channel_id == 93 }
            }
            guard let copy else { throw ChatAPIError.invalidResponse }
            receipt?.copyID = copy.id;receipt?.copyCreator = copy.creator_id;receipt?.copyType = copy.type;receipt?.forwardType = copy.props?.forward?.type
            receipt?.checks["timed_private_copy_observed"] = true
            var received:ChatLiveEvent?
            for _ in 0..<30 {
                received = receivedCandidates.first{$0.payload["post"]?["post_id"]?.integer == copy.id}
                if received != nil { break };try await Task.sleep(nanoseconds:500_000_000)
            }
            if let received {
                receipt?.notificationEvent = true
                if case .object(let fields)? = received.payload["post"] {
                    receipt?.notificationPostKeys = fields.keys.sorted()
                    if case .object(let props)? = fields["props"] { receipt?.notificationPropertyKeys = props.keys.sorted() }
                }
                let message = ChatNotificationMessage.make(event:received,preferences:preferences,currentUserID:10,visibleChannelID:nil,channelTitle:"My Space",personalReminderChannelID:10)
                receipt?.factoryAccepted = message?.postID == copy.id && message?.channelID == 10
            }
            if Bundle.main.bundleIdentifier == "com.costwisegroup.synology-chat-native.api-preview" {
                for _ in 0..<30 {
                    let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                    if let item = delivered.first(where:{$0.request.content.userInfo["nativePostID"] as? String == String(copy.id) && $0.request.content.userInfo["nativeAccountScope"] as? String == scope}) {
                        receipt?.deliveredToMacOS = true;receipt?.deliveryBodySHA256 = SHA256.hash(data:Data(item.request.content.body.utf8)).map{String(format:"%02x",$0)}.joined();break
                    }
                    try await Task.sleep(nanoseconds:500_000_000)
                }
            }
            let remaining = try await api.reminderTime(postID:source.id)
            if remaining != 0 { try require(remaining == receipt?.due);try dispatch("remove_schedule");try await api.removeReminder(postID:source.id) }
            let finalTime = try await api.reminderTime(postID:source.id);try require(finalTime == 0)
            receipt?.checks["schedule_removed"] = true
            try save("fired_ready_for_review")
            print("Timed personal reminder observed. Redacted receipt records server event, native filtering and macOS delivery; no authored message.")
            return true
        } catch {
            if receipt != nil { try? save("stopped_inspect_before_any_retry") }
            print("Personal reminder probe stopped; inspect its scoped receipt. No automatic replay.");return false
        }
    }
}
#endif
