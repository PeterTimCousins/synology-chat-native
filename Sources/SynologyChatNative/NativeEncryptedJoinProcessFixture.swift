#if DEBUG
import Foundation

/// Separate headless processes, private fake server state and real product journal.
/// No saved-session import, Keychain, live socket, application window or desktop input.
@MainActor enum NativeEncryptedJoinProcessFixture {
    static func run(directory:URL,phase:String) async -> Bool {
        do {
            let phases = ["create-interrupted","restore-review","join-unknown","status-locked","final-restore"]
            guard phases.contains(phase),directory.path.hasPrefix("/private/tmp/native-channel-invitation-fixture.join-process-") else { throw ChatAPIError.invalidResponse }
            try NativeChannelInvitationUIFixture.validateDirectory(directory)
            let stateFile = directory.appendingPathComponent("synthetic-server.json"),proof = directory.appendingPathComponent(phase+".json")
            guard !FileManager.default.fileExists(atPath:proof.path) else { throw ChatAPIError.invalidResponse }
            var saved:[String:Any]?
            if FileManager.default.fileExists(atPath:stateFile.path) {
                guard let value = try JSONSerialization.jsonObject(with:Data(contentsOf:stateFile)) as? [String:Any],value["synthetic_only"] as? Bool == true,
                      let creates = value["creates"] as? Int,creates == 1,let joins = value["joins"] as? Int,(1...2).contains(joins),
                      let channel = value["channel"] as? [String:Any],channel["channel_id"] as? Int == 96,channel["creator_id"] as? Int == 10 else { throw ChatAPIError.invalidResponse }
                saved = value
            }
            guard (phase == "create-interrupted") == (saved == nil) else { throw ChatAPIError.invalidResponse }
            let (model,backend) = try await NativeChannelInvitationUIFixture.makeModel(directory:directory,unlock:phase != "status-locked" && phase != "final-restore",configure:{ backend in
                if let saved {
                    backend.creates = Array(repeating:[:],count:saved["creates"] as! Int);backend.joins = Array(repeating:[:],count:saved["joins"] as! Int)
                    backend.createdChannel = saved["channel"] as? [String:Any]
                }
            })
            defer { model.signOutLocally() }
            let beforeCreates = backend.creates.count,beforeJoins = backend.joins.count,pendingBefore = model.pendingEncryptedCreations.count
            switch phase {
            case "create-interrupted":
                guard pendingBefore == 0 else { throw ChatAPIError.invalidResponse };backend.rejectJoin = true
                do { try await model.createChannel(name:"Synthetic-process-channel",purpose:"Synthetic process recovery",kind:.private,encrypted:true);throw ChatAPIError.invalidResponse }
                catch { guard model.pendingEncryptedCreations.count == 1,model.pendingEncryptedCreations.values.first?.channelID == 96,backend.creates.count == 1,backend.joins.count == 1,backend.createdChannel?["is_joined"] as? Bool == false else { throw error } }
            case "restore-review":
                guard pendingBefore == 1,let intent = model.pendingEncryptedCreations.values.first else { throw ChatAPIError.invalidResponse }
                _ = try await model.prepareEncryptedCreationJoin(intent,expectedGeneration:model.accountGeneration)
                guard backend.creates.count == beforeCreates,backend.joins.count == beforeJoins else { throw ChatAPIError.invalidResponse }
            case "join-unknown":
                guard pendingBefore == 1,beforeJoins == 1,let intent = model.pendingEncryptedCreations.values.first else { throw ChatAPIError.invalidResponse }
                let review = try await model.prepareEncryptedCreationJoin(intent,expectedGeneration:model.accountGeneration);backend.loseJoinReply = true
                do { try await model.finishEncryptedCreationJoin(review);throw ChatAPIError.invalidResponse }
                catch { guard model.pendingEncryptedCreations.count == 1,model.pendingEncryptedCreations[intent.id]?.joinAttemptID != intent.joinAttemptID,backend.joins.count == 2,backend.createdChannel?["is_joined"] as? Bool == true else { throw error } }
            case "status-locked":
                guard pendingBefore == 1,beforeJoins == 2,let intent = model.pendingEncryptedCreations.values.first else { throw ChatAPIError.invalidResponse }
                model.lockEncryption();try await model.checkEncryptedCreationStatus(intent,expectedGeneration:model.accountGeneration)
                guard !model.encryptionUnlocked,model.pendingEncryptedCreations.isEmpty,backend.joins.count == beforeJoins else { throw ChatAPIError.invalidResponse }
            default:
                model.lockEncryption()
                guard pendingBefore == 0,backend.creates.count == 1,backend.joins.count == 2,model.channels.contains(where:{ $0.id == 96 && $0.is_joined == true }) else { throw ChatAPIError.invalidResponse }
            }
            guard backend.creates.count == 1,backend.invites.isEmpty,model.selection == 23,let channel = backend.createdChannel else { throw ChatAPIError.invalidResponse }
            let server:[String:Any] = ["synthetic_only":true,"creates":backend.creates.count,"joins":backend.joins.count,"channel":channel]
            try JSONSerialization.data(withJSONObject:server,options:[.sortedKeys]).write(to:stateFile,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:stateFile.path)
            let receipt:[String:Any] = ["phase":phase,"pid":ProcessInfo.processInfo.processIdentifier,"creates_before":beforeCreates,"creates_after":backend.creates.count,"joins_before":beforeJoins,"joins_after":backend.joins.count,"pending_before":pendingBefore,"pending_after":model.pendingEncryptedCreations.count,"selection":model.selection ?? 0,"synthetic_only":true,"window_opened":false]
            try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:proof,options:.withoutOverwriting)
            return true
        } catch { fputs("Synthetic encrypted join process check failed.\n",stderr);return false }
    }
}
#endif
