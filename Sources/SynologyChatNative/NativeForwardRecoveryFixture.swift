#if DEBUG
import AppKit
import SwiftUI

/// App-owned synthetic rendering and real process probes, with no session import.
@MainActor enum NativeForwardRecoveryFixture {
    nonisolated static let host = "forward-recovery-fixture.invalid"
    static var state:ForwardRecoveryFixtureState?
    static func validateDirectory(_ directory:URL) throws {
        guard directory.path.hasPrefix("/private/tmp/native-forward-recovery-fixture."),!directory.path.contains(".."),!directory.path.contains("\0"),directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw ChatAPIError.invalidResponse }
    }
    static func makeModel(directory:URL) async throws -> NativeChatPreviewModel {
        try validateDirectory(directory)
        let backend = try ForwardRecoveryFixtureState(directory:directory);state = backend
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            guard session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
            let configuration = URLSessionConfiguration.ephemeral;configuration.protocolClasses = [ForwardRecoveryFixtureProtocol.self]
            configuration.httpShouldSetCookies = false;configuration.urlCache = nil
            return try ChatAPIClient(session:session,network:URLSession(configuration:configuration))
        },forwardJournal:.init(directory:directory.appendingPathComponent("receipts")))
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-self",importedFromOfficialApp:false))
        guard model.connected,model.forwardRecoveryError == nil else { throw ChatAPIError.invalidResponse }
        model.liveStatus = .live;model.error = nil;model.selection = 93;model.draft = "Preserve the synthetic original draft."
        return model
    }
    static func source() throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:ForwardRecoveryFixtureState.source)) }
    static func runContract(directory:URL,phase:String) async -> Bool {
        do {
            guard ["create-stop","restore-check","resolve-check","verify-finished"].contains(phase) else { throw ChatAPIError.invalidResponse }
            try validateDirectory(directory)
            let file = directory.appendingPathComponent(phase+".json")
            guard !FileManager.default.fileExists(atPath:file.path) else { throw ChatAPIError.invalidResponse }
            let model = try await makeModel(directory:directory);defer { model.signOutLocally() }
            guard let backend = state else { throw ChatAPIError.invalidResponse }
            let before = backend.attempts,pendingBefore = model.pendingForwards.count
            switch phase {
            case "create-stop":
                guard before == 0,pendingBefore == 0 else { throw ChatAPIError.invalidResponse }
                do { _ = try await model.forwardMessage(source(),to:[94]);throw ChatAPIError.invalidResponse }
                catch let error as NativeForwardFailure { guard error.uncertain else { throw error } }
                guard backend.attempts == 1,model.pendingForwards.count == 1 else { throw ChatAPIError.invalidResponse }
            case "restore-check":
                guard before == 1,pendingBefore == 1,let intent = model.pendingForwards.values.first else { throw ChatAPIError.invalidResponse }
                do { _ = try await model.forwardMessage(source(),to:[94]);throw ChatAPIError.invalidResponse }
                catch let error as NativeForwardFailure { guard error.uncertain else { throw error } }
                do { _ = try await model.checkForwardStatus(intent,expectedGeneration:model.accountGeneration);throw ChatAPIError.invalidResponse }
                catch { guard model.pendingForwards[intent.id] != nil else { throw error } }
                guard backend.attempts == before else { throw ChatAPIError.invalidResponse }
            case "resolve-check":
                guard before == 1,pendingBefore == 1,let intent = model.pendingForwards.values.first else { throw ChatAPIError.invalidResponse }
                // Direct fake backend change represents external delivery, not an API resend.
                backend.delivered = true;try backend.save()
                let copies = try await model.checkForwardStatus(intent,expectedGeneration:model.accountGeneration)
                guard copies.map(\.channel_id) == [94],backend.attempts == before,model.pendingForwards.isEmpty else { throw ChatAPIError.invalidResponse }
            case "verify-finished":guard before == 1,pendingBefore == 0 else { throw ChatAPIError.invalidResponse }
            default:throw ChatAPIError.invalidResponse
            }
            let receipt:[String:Any] = ["phase":phase,"pid":ProcessInfo.processInfo.processIdentifier,"attempts_before":before,"attempts_after":backend.attempts,"pending_before":pendingBefore,"pending_after":model.pendingForwards.count,"selection":model.selection ?? 0,"synthetic_only":true,"window_opened":false]
            try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            return true
        } catch { fputs("Synthetic forward recovery contract failed.\n",stderr);return false }
    }
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            for (name,style,mode) in [("dark-destinations",ChatAppearanceStyle.dark,0),("light-destinations",.light,0),("dark-pending-forward",.dark,1),("light-pending-forward",.light,1),("dark-recovery-review",.dark,2),("light-recovery-review",.light,2),("dark-missing-source-centre",.dark,3)] {
                let temporary = URL(fileURLWithPath:"/private/tmp/native-forward-recovery-fixture.render-"+UUID().uuidString,isDirectory:true)
                let model = try await makeModel(directory:temporary)
                defer { model.signOutLocally();try? FileManager.default.removeItem(at:temporary) }
                let post = try source(),snapshot = try await model.loadQuickSwitcher()
                if mode > 0 { do { _ = try await model.forwardMessage(post,to:[94]) } catch { } }
                let content = Group {
                    if mode < 2 { NativeForwardMessageView.renderFixture(model:model,post:post,snapshot:snapshot) }
                    else if mode == 2,let intent = model.pendingForwards.values.first { NativeForwardRecoveryView(model:model,intent:intent) }
                    else { NativePendingChannelActionsView(model:model) }
                }.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                if mode == 3 { model.channels.removeAll { $0.id == 93 } }
                let width = mode < 2 ? 620.0 : mode == 2 ? 560.0 : 600.0,height = mode < 2 ? 650.0 : mode == 2 ? 420.0 : 520.0
                let view = NSHostingView(rootView:content);view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x:0,y:0,width:width,height:height);view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:60_000_000);view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Offscreen forwarding rendering failed.\n",stderr);return false }
    }
}
@MainActor final class ForwardRecoveryFixtureState {
    let directory:URL
    var attempts = 0,delivered = false
    init(directory:URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = directory.appendingPathComponent("synthetic-backend.json")
        if FileManager.default.fileExists(atPath:file.path) {
            let object = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]
            guard let attempts = object?["attempts"] as? Int,attempts >= 0,attempts <= 100,let delivered = object?["delivered"] as? Bool else { throw ChatAPIError.invalidResponse }
            self.attempts = attempts;self.delivered = delivered
        }
    }
    func save() throws { try JSONSerialization.data(withJSONObject:["attempts":attempts,"delivered":delivered],options:.sortedKeys).write(to:directory.appendingPathComponent("synthetic-backend.json"),options:.atomic) }
    static let source:[String:Any] = ["post_id":1,"channel_id":93,"creator_id":10,"message":"Synthetic forwarding review: keep the original draft while choosing a new person or an existing conversation.","type":"normal","create_at":1000]
}
private final class ForwardRecoveryFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == NativeForwardRecoveryFixture.host else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var components = URLComponents();components.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),endpoint = request.url!.lastPathComponent
        DispatchQueue.main.async { self.route(endpoint:endpoint,fields:fields) }
    }
    @MainActor private func route(endpoint:String,fields:[String:String]) {
        guard let backend = NativeForwardRecoveryFixture.state else { finish(["success":false]);return }
        let users:[[String:Any]] = [(10,"synthetic-self","Synthetic self"),(20,"synthetic-existing","Existing peer"),(30,"synthetic-new","New recipient")].map { ["user_id":$0.0,"username":$0.1,"nickname":$0.2,"type":"human","human_type":"dsm"] }
        switch (endpoint,fields["method"] ?? "") {
        case ("SYNO.API.Info",_):
            let names = ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Misc","SYNO.Chat.Post","SYNO.Chat.Admin.Setting"]
            finish(["success":true,"data":Dictionary(uniqueKeysWithValues:names.map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })])
        case ("SYNO.Chat.User","list"):finish(["success":true,"data":["users":users]])
        case ("SYNO.Chat.Channel","list"):finish(["success":true,"data":["channels":[["channel_id":93,"name":"Synthetic source","type":"anonymous","encrypted":false,"unread":0],["channel_id":94,"name":"Synthetic private destination","type":"private","encrypted":false,"unread":0]]]])
        case ("SYNO.Chat.Channel.Member","get"):finish(["success":true,"data":["user_ids":[10,20]]])
        case ("SYNO.Chat.Misc","acl"):finish(["success":true,"data":["acls":[["acl_name":"channel_anonymous","allow":true]]]])
        case ("SYNO.Chat.Admin.Setting",_):finish(["success":true,"data":["hide_post_url_preview":true,"file_size_limit":0]])
        case ("SYNO.Chat.Post","forward"):
            backend.attempts += 1
            do { try backend.save();finish(["success":true]) } catch { finish(["success":false]) }
        case ("SYNO.Chat.Post","list"):
            var copy = ForwardRecoveryFixtureState.source;copy["post_id"] = 194;copy["channel_id"] = 94;copy["create_at"] = 2000;copy["props"] = ["forward":["origin_post_id":1,"origin_channel_id":93,"origin_user_id":10]]
            let posts = fields["channel_id"] == "93" ? [ForwardRecoveryFixtureState.source] : backend.delivered ? [copy] : []
            finish(["success":true,"data":["posts":posts]])
        default:finish(["success":false,"error":["code":400]])
        }
    }
    private func finish(_ value:[String:Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject:value) else { return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
