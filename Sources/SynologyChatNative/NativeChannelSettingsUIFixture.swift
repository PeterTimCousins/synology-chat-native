#if DEBUG
import AppKit
import SwiftUI

/// Independent settings application with intercepted synthetic account responses.
/// It never imports a session, restores Keychain data or constructs a live socket.
@MainActor enum NativeChannelSettingsUIFixture {
    nonisolated static let host = "channel-settings-fixture.invalid"
    static func run() {
        let app = NSApplication.shared, delegate = ChannelSettingsFixtureDelegate()
        app.delegate = delegate;app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    static func makeModel() async throws -> NativeChatPreviewModel {
        ChannelSettingsFixtureStorage.current = ChannelSettingsFixtureState()
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ChannelSettingsFixtureProtocol.self]
            config.httpShouldSetCookies = false;config.urlCache = nil
            return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic-settings-session",synoToken:"synthetic-settings-token"),username:"synthetic-settings",importedFromOfficialApp:false))
        guard model.connected,!model.encryptionUnlocked else { throw ChatAPIError.invalidResponse }
        // Local fixture readiness only; runtime config deliberately prevents a socket.
        model.liveStatus = .live;model.error = nil
        model.selection = 96;model.draft = "Synthetic settings draft — keep unchanged."
        _ = try await model.refreshAdministratorStatus()
        return model
    }
    static var metadataWriteCount:Int { ChannelSettingsFixtureStorage.current?.metadataWrites ?? 0 }
    static var deleteAttemptCount:Int { ChannelSettingsFixtureStorage.current?.deleteAttempts ?? 0 }
    static var joinAttemptCount:Int { ChannelSettingsFixtureStorage.current?.joinAttempts ?? 0 }
    static var disjoinAttemptCount:Int { ChannelSettingsFixtureStorage.current?.disjoinAttempts ?? 0 }
    static func setSyntheticAdministrator(_ administrator:Bool,model:NativeChatPreviewModel) async throws {
        guard let state = ChannelSettingsFixtureStorage.current else { throw ChatAPIError.invalidResponse }
        state.administrator = administrator
        _ = try await model.refreshAdministratorStatus()
    }
}

@MainActor private final class ChannelSettingsFixtureState:ObservableObject {
    @Published var administrator = true
    @Published var metadataWrites = 0
    @Published var deleteAttempts = 0
    @Published var disjoinAttempts = 0
    @Published var joinAttempts = 0
    var joinedPreview = false
    var channels:[[String:Any]] = [
        ["channel_id":96,"name":"Synthetic encrypted channel","purpose":"Plaintext synthetic purpose; message keys stay locked.","type":"private","encrypted":true,"channel_key_enc":"synthetic-settings-envelope-not-a-real-key","unread":0,"is_joined":true,"is_closed":false,"hide_global_at":0,"creator_id":10],
        ["channel_id":1,"name":"General","purpose":"Synthetic system channel purpose","type":"public","encrypted":false,"unread":0,"is_joined":true,"is_closed":false,"hide_global_at":0,"creator_id":10]]
    var available:[[String:Any]] { joinedPreview ? [] : [["channel_id":97,"name":"Synthetic public preview","purpose":"Synthetic local preview; joining changes only intercepted fixture state.","type":"public","encrypted":false,"unread":0,"is_joined":false,"total_member_count":2]] }
    lazy var previewImage = (try? NativeSyntheticAnimatedImage.gif()) ?? Data()
    lazy var stickerImage = NSBitmapImageRep(data:(try? NativeSyntheticAnimatedImage.gif(frames:1,width:32,height:32)) ?? Data())?.representation(using:.png,properties:[:]) ?? Data()
    let previewPosts:[[String:Any]] = [
        ["post_id":101,"channel_id":97,"creator_id":10,"message":"**Welcome** to the synthetic preview.\n> A read-only quoted message.\n- Keep the active draft unchanged.","type":"normal","create_at":1000],
        ["post_id":102,"channel_id":97,"creator_id":10,"message":"Synthetic image attachment","type":"file","create_at":2000,"file_props":["name":"Synthetic-preview.gif","size":62,"is_image":true]],
        ["post_id":103,"channel_id":97,"creator_id":10,"message":"https://example.invalid/synthetic","type":"normal","create_at":3000,"url_props":[["url":"https://example.invalid/synthetic","image":"https://images.example.invalid/synthetic.png","favicon":"https://images.example.invalid/icon.png","title":"Synthetic link preview","description":"Local metadata; the website opens only when selected.","hidden":false]]],
        ["post_id":104,"channel_id":97,"creator_id":10,"message":":synthetic_smile:","type":"sticker","create_at":4000],
        ["post_id":105,"channel_id":97,"creator_id":10,"message":"Synthetic preview poll?","type":"vote","create_at":5000,"props":["vote":["state":"open","choices":[["id":"a","text":"First synthetic choice","count":2],["id":"b","text":"Second synthetic choice","count":1]],"options":["multiple":false,"anonymous":true,"add_option":false,"expire_at":0]]]],
        ["post_id":106,"channel_id":97,"creator_id":10,"message":"https://unsafe.example.invalid/synthetic","type":"normal","create_at":6000,"props":["safe_url":false]]]

    var archive:[String:Any] {
        ["archive_id":600,"post_start":1000,"post_end":3000,"post_id_start":1,"post_id_end":100,
         "props":["reason":"channel_archived","trigger_user_id":10,
                  "channel":["channel_id":400,"name":"Synthetic public archive","type":"public","encrypted":false,"unread":0]]]
    }
}
@MainActor private enum ChannelSettingsFixtureStorage {
    static var current:ChannelSettingsFixtureState?
}

@MainActor private final class ChannelSettingsFixtureDelegate:NSObject,NSApplicationDelegate {
    private var model:NativeChatPreviewModel?
    private var window:NSWindow?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let menu = NSMenu(),item = NSMenuItem(),appMenu = NSMenu()
        for (title,action) in [("Revoke synthetic administrator",#selector(revokeAdministrator(_:))),("Restore synthetic administrator",#selector(restoreAdministrator(_:)))] {
            let command = appMenu.addItem(withTitle:title,action:action,keyEquivalent:"");command.target = self
        }
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"Quit Channel Settings Test",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu = appMenu;menu.addItem(item)
        let editItem = NSMenuItem(),edit = NSMenu(title:"Edit")
        edit.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        editItem.submenu = edit;menu.addItem(editItem);NSApp.mainMenu = menu
        Task { @MainActor in
            do {
                let model = try await NativeChannelSettingsUIFixture.makeModel()
                guard let state = ChannelSettingsFixtureStorage.current else { throw ChatAPIError.invalidResponse }
                self.model = model
                let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1020,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                window.title = "Channel Settings Test — synthetic local account only";window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView:ChannelSettingsFixtureRoot(model:model,state:state))
                self.window = window;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            } catch { fputs("Could not initialize synthetic channel settings fixture.\n",stderr);NSApp.terminate(nil) }
        }
    }
    @objc private func revokeAdministrator(_ sender:Any?) { changeAdministrator(false) }
    @objc private func restoreAdministrator(_ sender:Any?) { changeAdministrator(true) }
    private func changeAdministrator(_ value:Bool) {
        guard let model else { return }
        Task { @MainActor in try? await NativeChannelSettingsUIFixture.setSyntheticAdministrator(value,model:model) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationWillTerminate(_ notification:Notification) { model?.signOutLocally() }
}

private struct ChannelSettingsFixtureRoot:View {
    @ObservedObject var model:NativeChatPreviewModel
    @ObservedObject var state:ChannelSettingsFixtureState
    @State private var encryptedDetails = false
    @State private var systemDetails = false
    @State private var archives = false
    @State private var channels = false
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Synthetic channel settings").font(.title2.bold())
            Text("No NAS or real account. Chat API requests are intercepted locally. Website links open only when selected. Archive deletion is always rejected.").foregroundColor(NativeChatColors.muted)
            Text("Message keys: \(model.encryptionUnlocked ? "unlocked" : "locked") · Verified administrator: \(model.isVerifiedAdministrator ? "yes" : "no")")
            Text("Synthetic metadata writes: \(state.metadataWrites) · Rejected archive delete attempts: \(state.deleteAttempts)")
            Text("Rejected membership leave attempts: \(state.disjoinAttempts) · Local synthetic joins: \(state.joinAttempts)")
            Text("Selected synthetic channel: \(model.selection.map(String.init) ?? "none")")
            HStack {
                Button("Encrypted private channel details") { encryptedDetails = true }
                Button("General system channel details") { systemDetails = true }
                Button("Browse synthetic archives") { archives = true }
            }
            Button("Browse joined synthetic channels") { channels = true }
            Text("Use the application menu to revoke or restore synthetic administrator status while a sheet is open.").font(.callout)
            Spacer()
        }.padding(24).frame(minWidth:960,minHeight:650,alignment:.topLeading)
            .foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .sheet(isPresented:$encryptedDetails) { NativeChannelDetailsView(model:model,channelID:96) }
            .sheet(isPresented:$systemDetails) { NativeChannelDetailsView(model:model,channelID:1) }
            .sheet(isPresented:$archives) { NativeArchivesView(model:model) }
            .sheet(isPresented:$channels) { NativeChannelBrowserView(model:model) }
    }
}

private final class ChannelSettingsFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == NativeChannelSettingsUIFixture.host else {
            client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return
        }
        if request.url?.path.hasSuffix("/Chat/config") == true { respond(Data(),status:404);return }
        var body = request.httpBody ?? Data()
        if body.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable,body.count < 64*1024 { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };body.append(contentsOf:buffer.prefix(n)) }
        }
        var form = URLComponents();form.percentEncodedQuery = String(decoding:body,as:UTF8.self)
        let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
        let fields = Dictionary((query + (form.queryItems ?? [])).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let endpoint = request.url!.lastPathComponent
        DispatchQueue.main.async { self.route(endpoint: endpoint,fields:fields) }
    }
    @MainActor private func route(endpoint:String,fields:[String:String]) {
        guard let state = ChannelSettingsFixtureStorage.current else { reject();return }
        if endpoint == "style.css" {
            respond(Data(".sticker-synthetic_smile { background-image:url(images/sticker/1x/synthetic.png); width:32px; height:32px; background-position:0px 0px; }".utf8),contentType:"text/css");return
        }
        if endpoint == "synthetic.png" { respond(state.stickerImage,contentType:"image/png");return }
        if endpoint == "SYNO.API.Info" {
            let apis = ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Channel.Named","SYNO.Chat.Post","SYNO.Chat.Archive","SYNO.Core.Desktop.Initdata","SYNO.Chat.Post.File","SYNO.Chat.Channel.Member","SYNO.Chat.Sticker","SYNO.Chat.Admin.Setting"]
            json(Dictionary(uniqueKeysWithValues:apis.map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) }));return
        }
        func string(_ name:String) -> String? { fields[name].flatMap { try? JSONDecoder().decode(String.self,from:Data($0.utf8)) } }
        switch (fields["api"] ?? "",fields["method"] ?? "") {
        case ("SYNO.Chat.User","list"):
            json(["users":[["user_id":10,"username":"synthetic-settings","nickname":"Synthetic settings user","type":"human","human_type":"dsm"]]])
        case ("SYNO.Chat.Channel","list"):json(["channels":fields["is_joined"] == "false" ? state.available : state.channels])
        case ("SYNO.Chat.Misc","acl"):json(["acls":[["acl_name":"channel_set","allow":true],["acl_name":"channel_disjoin","allow":true],["acl_name":"channel_join","allow":true]]])
        case ("SYNO.Chat.Channel.Named","join"):
            guard fields["channel_id"] == "97",string("channel_key_enc") == "",!state.joinedPreview,var channel = state.available.first else { reject();return }
            state.joinAttempts += 1;state.joinedPreview = true;channel["is_joined"] = true;state.channels.append(channel);json([:])
        case ("SYNO.Chat.Channel.Named","disjoin"):
            state.disjoinAttempts += 1;reject()
        case ("SYNO.Core.Desktop.Initdata","get_user_service"):
            json(["Session":["user":"synthetic-settings","isLogined":true,"is_admin":state.administrator]])
        case ("SYNO.Chat.Channel.Named","set"):
            guard let id = fields["channel_id"].flatMap(Int64.init),let index = state.channels.firstIndex(where:{ Int64($0["channel_id"] as? Int ?? 0) == id }),
                  id == 96 || (id == 1 && state.administrator),
                  Set(fields.keys).isSubset(of:["api","method","version","_sid","SynoToken","channel_id","name","purpose"]),
                  fields["version"] == "1",string("name") != nil || string("purpose") != nil else { reject();return }
            if let name = string("name") { state.channels[index]["name"] = name }
            if let purpose = string("purpose") { state.channels[index]["purpose"] = purpose }
            state.metadataWrites += 1;json([:])
        case ("SYNO.Chat.Archive","list_name"):json(["channel_names":string("type") == "public" ? ["Synthetic public archive"] : []])
        case ("SYNO.Chat.Archive","list"):
            json(["archives":string("type") == "public" && string("channel_name") == "Synthetic public archive" ? [state.archive] : []])
        case ("SYNO.Chat.Archive","delete"):state.deleteAttempts += 1;reject()
        case ("SYNO.Chat.Admin.Setting","get"):json(["hide_post_url_preview":false,"allow_read_status":false])
        case ("SYNO.Chat.Post.File","og"):
            guard fields["post_id"] == "103" else { reject();return }
            respond(state.stickerImage,contentType:"image/png")
        case ("SYNO.Chat.Channel.Member","get"):json(["user_ids":fields["channel_id"] == "97" ? [10,20] : [10]])
        case ("SYNO.Chat.Post.File","thumbnail"):
            guard fields["post_id"] == "102" else { reject();return }
            respond(state.previewImage,contentType:"image/gif")
        case ("SYNO.Chat.Sticker","list"):json(["categories":[["category_id":1,"name":"synthetic","stickers":[["name":"synthetic_smile","sticker_id":1]]]]])
        case ("SYNO.Chat.Post","list"):json(["posts":fields["channel_id"] == "97" ? state.previewPosts : []])
        case ("SYNO.Chat.Post","search"):json(["search_results":[],"total":0])
        default:reject()
        }
    }
    private func reject() { respond(Data(#"{"success":false,"error":{"code":119}}"#.utf8)) }
    private func json(_ value:[String:Any]) {
        respond((try? JSONSerialization.data(withJSONObject:["success":true,"data":value])) ?? Data())
    }
    private func respond(_ data:Data,status:Int = 200,contentType:String = "application/json") {
        guard let url = request.url,let response = HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":contentType]) else { return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if !data.isEmpty { client?.urlProtocol(self,didLoad:data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
