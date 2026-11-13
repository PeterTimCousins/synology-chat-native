#if DEBUG
import AppKit
import SwiftUI

/// Synthetic backend only. No official session, Keychain import or live socket.
@MainActor enum NativeChannelInvitationUIFixture {
    nonisolated static let host = "invitation-integration.invalid"
    static func validateDirectory(_ directory:URL) throws {
        guard directory.path.hasPrefix("/private/tmp/native-channel-invitation-fixture."),!directory.path.contains(".."),!directory.path.contains("\0"),directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw ChatAPIError.invalidResponse }
    }
    static func makeModel(directory:URL,unlock:Bool = true,configure:((InvitationIntegrationBackend) throws -> Void)? = nil) async throws -> (NativeChatPreviewModel,InvitationIntegrationBackend) {
        try validateDirectory(directory)
        let path = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/SynologyChatNativeTests/Fixtures/ChatCrypto.json")
        let fixture = try JSONDecoder().decode(InvitationIntegrationFixture.self,from:Data(contentsOf:path))
        let backend = try InvitationIntegrationBackend(fixture:fixture,encrypted:true)
        backend.journalDirectory = directory.appendingPathComponent("receipts");backend.missingKeys = [30]
        try configure?(backend)
        InvitationIntegrationProtocol.backend = backend
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            guard session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [InvitationIntegrationProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
            return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        },invitationJournal:.init(directory:directory.appendingPathComponent("receipts")),encryptedCreationJournal:.init(directory:directory.appendingPathComponent("creation-receipts")),encryptedConversationJournal:.init(directory:directory.appendingPathComponent("conversation-receipts")))
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-inviter",importedFromOfficialApp:false))
        guard model.connected,model.invitationRecoveryError == nil else { throw ChatAPIError.invalidResponse }
        model.suspendLiveForProbe();model.selection = 23;if unlock { try model.unlockEncryption(password:fixture.password) };await model.historyTask?.value
        model.liveStatus = .live;model.error = nil
        return (model,backend)
    }
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            for (name,style,mode) in [("dark-add-people",ChatAppearanceStyle.dark,0),("light-add-people",.light,0),("dark-pending-invite",.dark,1),("light-pending-invite",.light,1),("dark-recovery",.dark,2),("light-recovery",.light,2),("dark-locked-recovery",.dark,3),("dark-missing-channel-centre",.dark,4)] {
                let temporary = URL(fileURLWithPath:"/private/tmp/native-channel-invitation-fixture.render-"+UUID().uuidString,isDirectory:true)
                let (model,backend) = try await makeModel(directory:temporary)
                defer { model.signOutLocally();try? FileManager.default.removeItem(at:temporary) }
                let snapshot = try await model.invitationSnapshot(channelID:23)
                var failure:String?
                if mode > 0 {
                    backend.applyOnly = []
                    do { try await model.inviteMembers([20],channelID:23,reviewed:snapshot);throw ChatAPIError.invalidResponse }
                    catch let error as ChatChannelInvitationFailure { guard error.uncertain else { throw error };failure = error.localizedDescription }
                    guard model.pendingInvitations[23] != nil,backend.invites.count == 1 else { throw ChatAPIError.invalidResponse }
                }
                if mode == 3 { model.lockEncryption() }
                if mode == 4 { model.channels = [] }
                let content = Group {
                    if mode < 2 { NativeAddMembersView.renderFixture(model:model,snapshot:snapshot,selected:[20],error:failure) }
                    else if mode < 4,let intent = model.pendingInvitations[23] { NativeChannelInvitationRecoveryView(model:model,intent:intent) }
                    else { NativePendingChannelActionsView(model:model) }
                }.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let width = mode < 2 ? 540.0 : mode < 4 ? 560.0 : 600.0,height = mode < 2 ? 560.0 : mode < 4 ? 420.0 : 520.0
                let view = NSHostingView(rootView:content);view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x:0,y:0,width:width,height:height);view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:60_000_000);view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Offscreen synthetic invitation rendering failed.\n",stderr);return false }
    }
}

struct InvitationIntegrationFixture:Decodable { let password,publicKey,wrappedPrivateKey,wrappedChannelKey,channelKey,encryptedMessage:String }
@MainActor final class InvitationIntegrationBackend {
    let fixture:InvitationIntegrationFixture
    let peerPassword = "Synthetic peer password"
    var peerPairs:[Int64:ChatEncryptionKeyPair] = [:]
    var encrypted:Bool,allowInvite = true,renamed = false,loseReply = false
    var allowCreate = true,allowJoin = true,loseCreateReply = false,loseJoinReply = false,rejectJoin = false
    var createdChannel:[String:Any]?
    var creates:[[String:String]] = [],joins:[[String:String]] = []
    var allowAnonymous = false,loseAnonymousReply = false
    var anonymousStarts:[[String:String]] = [],anonymousMembers:[Int64] = []
    var creationJournalDirectory:URL?,recordAtCreate:Data?,recordAtJoin:Data?
    var methodHook:((String)->Void)?
    func creationRecord() -> Data? {
        guard let directory = creationJournalDirectory,let file = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first(where:{ $0.pathExtension == "json" }) else { return nil }
        return try? Data(contentsOf:file)
    }
    var missingKeys:Set<Int64> = [],members:[Int64] = [10],applyOnly:Set<Int64>?
    var ownerPublicOverride:String?,ownerEnvelopeOverride:String?
    var requests = 0,userReads = 0,memberReads = 0,memberReadsAtWrite = 0
    var invites:[[String:String]] = []
    var holdEndpoint:String?,onHeld:(()->Void)?,hook:((String)->Void)?
    var held:(InvitationIntegrationProtocol,[String:Any])?
    var journalDirectory:URL?,recordAtWrite:Data?
    init(fixture:InvitationIntegrationFixture,encrypted:Bool) throws {
        self.fixture = fixture;self.encrypted = encrypted
        for id in [Int64(20),30] { peerPairs[id] = try ChatEncryptionManagement.generateKeyPair(password:peerPassword,confirmation:peerPassword) }
    }
    var users:[[String:Any]] {
        [["user_id":10,"username":"synthetic-inviter","nickname":"Synthetic self","type":"human","human_type":"dsm","user_props":["key_pair":["public_key":ownerPublicOverride ?? fixture.publicKey,"private_key_enc":fixture.wrappedPrivateKey]]]] + [Int64(20),30].map { id in
            var user:[String:Any] = ["user_id":id,"username":"synthetic-\(id)","nickname":renamed && id == 20 ? "Changed peer" : "Synthetic peer \(id)","type":"human","human_type":"dsm"]
            if !missingKeys.contains(id),let pair = peerPairs[id] { user["user_props"] = ["key_pair":["public_key":pair.public_key]] };return user
        }
    }
    var channel:[String:Any] {
        var value:[String:Any] = ["channel_id":23,"name":"Synthetic private channel","type":"private","encrypted":encrypted,"unread":0,"is_joined":true,"creator_id":10]
        if encrypted { value["channel_key_enc"] = ownerEnvelopeOverride ?? fixture.wrappedChannelKey };return value
    }
    func release() { if let held { self.held = nil;held.0.finish(held.1) } }
}
final class InvitationIntegrationProtocol:URLProtocol {
    @MainActor static var backend:InvitationIntegrationBackend?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == "invitation-integration.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&b,maxLength:b.count);if n <= 0 { break };data.append(contentsOf:b.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),endpoint = request.url!.lastPathComponent
        DispatchQueue.main.async { self.route(endpoint:endpoint,fields:fields) }
    }
    @MainActor private func route(endpoint:String,fields:[String:String]) {
        guard let state = Self.backend else { finish(["success":false]);return }
        if endpoint == "SYNO.API.Info" {
            let names = ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Misc","SYNO.Chat.Channel.Named","SYNO.Chat.Channel.Anonymous","SYNO.Chat.Post","SYNO.Chat.Admin.Setting"]
            finish(["success":true,"data":Dictionary(uniqueKeysWithValues:names.map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return
        }
        state.requests += 1
        if endpoint == "SYNO.Chat.User" { state.userReads += 1 }
        if endpoint == "SYNO.Chat.Channel.Member" { state.memberReads += 1 }
        var response:[String:Any]
        switch (endpoint,fields["method"] ?? "") {
        case ("SYNO.Chat.User","list"):response = ["success":true,"data":["users":state.users]]
        case ("SYNO.Chat.Channel","list"):response = ["success":true,"data":["channels":[state.channel] + (state.createdChannel.map { [$0] } ?? [])]]
        case ("SYNO.Chat.Channel.Member","get"):response = ["success":true,"data":["user_ids":fields["channel_id"] == "96" ? (state.createdChannel?["type"] as? String == "anonymous" ? state.anonymousMembers : (state.createdChannel?["is_joined"] as? Bool == true ? [Int64(10)] : [])) : state.members]]
        case ("SYNO.Chat.Misc","acl"):response = ["success":true,"data":["acls":[["acl_name":"channel_invite","allow":state.allowInvite],["acl_name":"channel_create","allow":state.allowCreate],["acl_name":"channel_join","allow":state.allowJoin],["acl_name":"channel_anonymous","allow":state.allowAnonymous]]]]
        case ("SYNO.Chat.Channel.Anonymous","initiate"):
            state.recordAtCreate = state.creationRecord();state.anonymousStarts.append(fields)
            let ids = (try? JSONDecoder().decode([Int64].self,from:Data((fields["user_ids"] ?? "[]").utf8))) ?? []
            let envelopes = (try? JSONDecoder().decode([String].self,from:Data((fields["channel_key_encs"] ?? "[]").utf8))) ?? []
            guard state.allowAnonymous,ids.count == envelopes.count,let own = ids.firstIndex(of:10),fields["encrypted"] == "true" else { finish(["success":false,"error":["code":400]]);return }
            state.anonymousMembers = ids;state.createdChannel = ["channel_id":96,"name":"","type":"anonymous","encrypted":true,"is_joined":true,"creator_id":10,"unread":0,"channel_key_enc":envelopes[own]]
            response = ["success":true,"data":state.createdChannel!]
        case ("SYNO.Chat.Admin.Setting",_):response = ["success":true,"data":["hide_post_url_preview":true,"file_size_limit":0]]
        case ("SYNO.Chat.Post","list"):response = ["success":true,"data":["posts":[["post_id":1,"channel_id":23,"creator_id":10,"message":state.encrypted ? state.fixture.encryptedMessage : "Synthetic message","type":"normal","create_at":1000]]]]
        case ("SYNO.Chat.Channel.Named","create"):
            state.recordAtCreate = state.creationRecord();state.creates.append(fields)
            let name = (try? JSONDecoder().decode(String.self,from:Data((fields["name"] ?? "").utf8))) ?? ""
            let purpose = (try? JSONDecoder().decode(String.self,from:Data((fields["purpose"] ?? "").utf8))) ?? ""
            state.createdChannel = ["channel_id":96,"name":name,"purpose":purpose,"type":"private","encrypted":true,"is_joined":false,"creator_id":10,"unread":0]
            response = ["success":true,"data":["channel_id":96]]
        case ("SYNO.Chat.Channel.Named","join"):
            state.recordAtJoin = state.creationRecord();state.joins.append(fields)
            if state.rejectJoin { response = ["success":false,"error":["code":117]] }
            else {
                state.createdChannel?["is_joined"] = true
                state.createdChannel?["channel_key_enc"] = (try? JSONDecoder().decode(String.self,from:Data((fields["channel_key_enc"] ?? "").utf8))) ?? ""
                response = ["success":true]
            }
        case ("SYNO.Chat.Channel.Named","invite"):
            state.invites.append(fields);state.memberReadsAtWrite = state.memberReads
            if let directory = state.journalDirectory,let file = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first(where:{ $0.pathExtension == "json" }) { state.recordAtWrite = try? Data(contentsOf:file) }
            let ids = (try? JSONDecoder().decode([Int64].self,from:Data((fields["user_ids"] ?? "[]").utf8))) ?? []
            state.members = Set(state.members).union(ids.filter { state.applyOnly?.contains($0) ?? true }).sorted()
            response = ["success":true]
        default:response = ["success":false,"error":["code":400]]
        }
        state.hook?(endpoint);state.methodHook?(fields["method"] ?? "")
        if state.holdEndpoint == endpoint { state.holdEndpoint = nil;state.held = (self,response);state.onHeld?();return }
        if endpoint == "SYNO.Chat.Channel.Anonymous",state.loseAnonymousReply { state.loseAnonymousReply = false;client?.urlProtocol(self,didFailWithError:URLError(.badServerResponse));return }
        if endpoint == "SYNO.Chat.Channel.Named",(fields["method"] == "create" && state.loseCreateReply || fields["method"] == "join" && state.loseJoinReply) {
            state.loseCreateReply = false;state.loseJoinReply = false;client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return
        }
        if endpoint == "SYNO.Chat.Channel.Named",state.loseReply { state.loseReply = false;client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return }
        finish(response)
    }
    fileprivate func finish(_ object:[String:Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject:object)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

#endif
