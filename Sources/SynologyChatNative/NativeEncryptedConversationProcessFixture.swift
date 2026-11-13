#if DEBUG
import Foundation

/// Headless process-restart proof with a persisted synthetic server and the
/// product's private receipt journal. Never loads a real session or real keys.
@MainActor enum NativeEncryptedConversationProcessFixture {
    static func run(directory:URL,phase:String) async -> Bool {
        do {
            let phases = ["create-lost","locked-status","review-open","final-restore"]
            guard let index = phases.firstIndex(of:phase),directory.path.hasPrefix("/private/tmp/native-channel-invitation-fixture.anonymous-process-") else { throw ChatAPIError.invalidResponse }
            try NativeChannelInvitationUIFixture.validateDirectory(directory)
            let server = directory.appendingPathComponent("synthetic-server.json"),proof = directory.appendingPathComponent(phase+".json")
            guard !FileManager.default.fileExists(atPath:proof.path),index == 0 || FileManager.default.fileExists(atPath:directory.appendingPathComponent(phases[index-1]+".json").path) else { throw ChatAPIError.invalidResponse }
            var saved:[String:Any]?
            if FileManager.default.fileExists(atPath:server.path) {
                guard let value = try JSONSerialization.jsonObject(with:Data(contentsOf:server)) as? [String:Any],value["synthetic_only"] as? Bool == true,value["initiations"] as? Int == 1,
                      let channel = value["channel"] as? [String:Any],channel["channel_id"] as? Int == 96,channel["type"] as? String == "anonymous",channel["encrypted"] as? Bool == true,
                      value["members"] as? [Int] == [10,20],let keys = value["peer_public_keys"] as? [String:String],let peer = keys["20"],try ChatContentCrypto.decodeBase64(peer).count == 32 else { throw ChatAPIError.invalidResponse }
                saved = value
            }
            guard (index == 0) == (saved == nil) else { throw ChatAPIError.invalidResponse }
            let (model,state) = try await NativeChannelInvitationUIFixture.makeModel(directory:directory,unlock:phase == "create-lost" || phase == "review-open",configure:{ backend in
                backend.allowAnonymous = true
                if let saved {
                    backend.anonymousStarts = [[:]];backend.createdChannel = saved["channel"] as? [String:Any];backend.anonymousMembers = [10,20]
                    for (raw,key) in saved["peer_public_keys"] as! [String:String] { guard let id = Int64(raw) else { throw ChatAPIError.invalidResponse };backend.peerPairs[id] = .init(public_key:key,private_key_enc:"") }
                }
            })
            defer { model.signOutLocally() }
            func saveServer() throws {
                guard let channel = state.createdChannel,state.anonymousStarts.count == 1 else { throw ChatAPIError.invalidResponse }
                let value:[String:Any] = ["synthetic_only":true,"initiations":state.anonymousStarts.count,"channel":channel,"members":state.anonymousMembers,
                                         "peer_public_keys":Dictionary(uniqueKeysWithValues:state.peerPairs.map { (String($0.key),$0.value.public_key) })]
                try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:server,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:server.path)
            }
            let before = model.pendingEncryptedConversationStarts.count
            var status = "not-checked",persistenceFailed = false
            switch phase {
            case "create-lost":
                guard before == 0 else { throw ChatAPIError.invalidResponse }
                let snapshot = try await model.loadQuickSwitcher();state.loseAnonymousReply = true
                state.hook = { endpoint in if endpoint == "SYNO.Chat.Channel.Anonymous" { do { try saveServer() } catch { persistenceFailed = true } } }
                do { try await model.startEncryptedConversation(with:[20],reviewed:snapshot);throw ChatAPIError.invalidResponse }
                catch { guard !persistenceFailed,state.anonymousStarts.count == 1,model.pendingEncryptedConversationStarts.count == 1,model.selection == 23 else { throw error } }
                guard model.pendingEncryptedConversationStarts.values.first?.candidateChannelID == nil else { throw ChatAPIError.invalidResponse }
                status = "reply-lost-pending"
            case "locked-status":
                guard before == 1,!model.encryptionUnlocked,let intent = model.pendingEncryptedConversationStarts.values.first else { throw ChatAPIError.invalidResponse }
                let result = try await model.checkEncryptedConversationStart(intent,expectedGeneration:model.accountGeneration)
                guard result.status == .needsUnlock,result.candidateChannelID == 96,model.selection == 23,model.pendingEncryptedConversationStarts.count == 1 else { throw ChatAPIError.invalidResponse }
                status = "needs-unlock-no-replay"
            case "review-open":
                guard before == 1,let intent = model.pendingEncryptedConversationStarts.values.first else { throw ChatAPIError.invalidResponse }
                let review = try await model.prepareEncryptedConversationOpen(intent,expectedGeneration:model.accountGeneration)
                guard !review.requiresExistingReview,review.channel.id == 96,model.selection == 23 else { throw ChatAPIError.invalidResponse }
                try await model.openRecoveredEncryptedConversation(review)
                guard model.selection == 96,model.pendingEncryptedConversationStarts.isEmpty else { throw ChatAPIError.invalidResponse }
                status = "verified-opened"
            default:
                guard before == 0,model.pendingEncryptedConversationStarts.isEmpty,!model.encryptionUnlocked else { throw ChatAPIError.invalidResponse }
                status = "receipt-retirement-restored"
            }
            guard state.anonymousStarts.count == 1,state.creates.isEmpty,state.joins.isEmpty else { throw ChatAPIError.invalidResponse }
            try saveServer()
            let result:[String:Any] = ["synthetic_only":true,"phase":phase,"process_id":ProcessInfo.processInfo.processIdentifier,"initiations":state.anonymousStarts.count,
                                      "named_creates":state.creates.count,"joins":state.joins.count,"pending_before":before,"pending_after":model.pendingEncryptedConversationStarts.count,"selected":model.selection ?? 0,"status":status]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:proof,options:.withoutOverwriting)
            return true
        } catch { fputs("Synthetic encrypted conversation process phase failed.\n",stderr);return false }
    }
}
#endif
