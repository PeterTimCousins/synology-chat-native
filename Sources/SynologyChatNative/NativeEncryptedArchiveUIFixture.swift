#if DEBUG
import AppKit
import SwiftUI

/// Isolated synthetic archive application. All requests are intercepted locally;
/// no account import, Keychain restore, live socket or real server is used.
@MainActor enum NativeEncryptedArchiveUIFixture {
    nonisolated static let password = "Synthetic encryption password — not an account credential"
    nonisolated static let publicKey = "RwHQhIhFH1RaQJ+1iuPlhYHKQKw/fxFGmM1x3qxzygE="
    nonisolated static let wrappedPrivateKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYWGLhMDGAig/UqBZ9IK1VMeCF6Cyx6PVlAD6j+u0gRv6j\r\nnz686ORlAF/7Ha/0is2TiSzqS0OVt6NW4uH2"
    nonisolated static let wrappedChannelKey = "aLzjiuhwaA7XGprChThNjLdURV2xRQhPJjhgzr3cFG1C5eQK6chYeKaE3fneSfQqe9/aBBUZdBHQ\r\nzS4xRtirf0YPwfs+UdB8piW8EboSCuFH9WGZj7+5YsFDTs4="
    nonisolated static let channelKey = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8="
    nonisolated static let host = "encrypted-archive-fixture.invalid"
    static func run() {
        let app = NSApplication.shared
        let delegate = EncryptedArchiveFixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    static func makeModel() async throws -> NativeChatPreviewModel {
        try EncryptedArchiveFixtureProtocol.prepare()
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            func network() -> URLSession {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [EncryptedArchiveFixtureProtocol.self]
                config.httpShouldSetCookies = false;config.urlCache = nil
                return URLSession(configuration:config)
            }
            return try ChatAPIClient(session:session,network:network(),makeAttachmentNetwork:network)
        })
        await connect(model)
        guard model.connected,model.hasEncryptionKeyPair,!model.encryptionUnlocked else { throw ChatAPIError.invalidResponse }
        return model
    }
    nonisolated static var syntheticPassword:String { password }
    static func connect(_ model:NativeChatPreviewModel) async {
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic-fixture-session",synoToken:"synthetic-fixture-token"),username:"archive-fixture",importedFromOfficialApp:false))
    }
}

@MainActor private final class EncryptedArchiveFixtureDelegate:NSObject,NSApplicationDelegate {
    private var window:NSWindow?
    private var model:NativeChatPreviewModel?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let menu = NSMenu(),application = NSMenuItem(),items = NSMenu()
        let lock = items.addItem(withTitle:"Lock synthetic encryption",action:#selector(lockFixtureEncryption(_:)),keyEquivalent:"l")
        lock.keyEquivalentModifierMask = [.command,.shift];lock.target = self
        items.addItem(.separator())
        items.addItem(withTitle:"Quit Encrypted Archive Test",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        application.submenu = items;menu.addItem(application)
        let editItem = NSMenuItem(),edit = NSMenu(title:"Edit")
        edit.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        editItem.submenu = edit;menu.addItem(editItem);NSApp.mainMenu = menu
        Task {
        do {
            let model = try await NativeEncryptedArchiveUIFixture.makeModel();self.model = model
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1020,height:780),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title = "Encrypted Archive Test — synthetic local data only"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView:EncryptedArchiveFixtureRoot(model:model))
            self.window = window;window.center();window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true)
        } catch {
            fputs("Could not prepare synthetic encrypted archive fixture.\n",stderr)
            NSApp.terminate(nil)
        }
        }
    }
    @objc private func lockFixtureEncryption(_ sender:Any?) { model?.lockEncryption(reload:false) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationWillTerminate(_ notification:Notification) { model?.signOutLocally() }
}

private struct EncryptedArchiveFixtureRoot:View {
    @ObservedObject var model:NativeChatPreviewModel
    @State private var showDownloads = false
    var body:some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:4) {
                Text("Synthetic data · Password: " + NativeEncryptedArchiveUIFixture.password).font(.caption).textSelection(.enabled)
                HStack {
                    Text(model.connected ? (model.encryptionUnlocked ? "Keys unlocked" : "Keys locked — open the private archive period to unlock") : "Connecting synthetic account…")
                    Spacer()
                    Button("Downloads") { showDownloads = true }
                    Button("Lock encryption") { model.lockEncryption(reload:false) }.disabled(!model.encryptionUnlocked)
                }
            }.padding(8)
            Divider()
            if model.connected { NativeArchivesView(model:model) }
            else { ProgressView("Connecting local fixture…").frame(width:940,height:650) }
        }.foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .sheet(isPresented: $showDownloads) { NativeDownloadsView(model:model) }
    }
}

private final class EncryptedArchiveFixtureProtocol:URLProtocol {
    static var archive:[String:Any] = [:]
    static var posts:[[String:Any]] = []
    static var files:[Int64:Data] = [:]
    @MainActor static func prepare() throws {
        let key = try ChatContentCrypto.decodeBase64(NativeEncryptedArchiveUIFixture.channelKey)
        let channel:[String:Any] = ["channel_id":400,"name":"Synthetic encrypted archive","type":"private","encrypted":true,"unread":0,"channel_key_enc":NativeEncryptedArchiveUIFixture.wrappedChannelKey]
        archive = ["archive_id":600,"post_start":1000,"post_end":3000,"post_id_start":1,"post_id_end":100,"props":["reason":"channel_closed","trigger_user_id":10,"channel":channel]]
        func message(_ id:Int64,_ text:String,thread:Int64 = 0,comments:Int = 0) throws -> [String:Any] {
            ["post_id":id,"channel_id":400,"creator_id":10,"thread_id":thread,"type":"normal","create_at":1500,"message":try ChatContentCrypto.encryptMessage(text,key:key),"comment_count":comments]
        }
        posts = [try message(1,"Synthetic archived root — café 👋",comments:1),try message(2,"Synthetic archived reply — historical channel key",thread:1)]
        let wave = NativeSyntheticMedia.wave()
        let silent = Data(wave.prefix(44)) + Data(repeating:0,count:max(0,wave.count-44))
        let originals:[(Int64,String,Data,Bool)] = [
            (10,"Synthetic encrypted note.txt",Data("Synthetic encrypted archive text.\nNo private data.\n".utf8),false),
            (11,"Synthetic encrypted image.png",NativeSyntheticClipboardImage.data,true),
            (12,"Synthetic encrypted second image.png",NativeSyntheticClipboardImage.data,true),
            (13,"Synthetic encrypted document.pdf",try NativeSyntheticDocument.data(),false),
            (14,"Synthetic encrypted silent audio.wav",silent,false)]
        files = [:]
        for (id,name,data,image) in originals {
            let ciphertext = try ChatContentCrypto.encryptAttachment(data,key:key)
            files[id] = ciphertext
            posts.append(["post_id":id,"channel_id":400,"creator_id":10,"thread_id":0,"type":"file","create_at":1600,"message":try ChatContentCrypto.encryptMessage("Synthetic encrypted attachment — " + name,key:key),"file_props":["name":try ChatContentCrypto.encryptFilename(name,key:key),"size":ciphertext.count,"is_image":image,"type":""],"props":["encrypted":true]])
        }
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == NativeEncryptedArchiveUIFixture.host else {
            client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return
        }
        if request.url?.path.hasSuffix("/Chat/config") == true { respond(Data(),status:404);return }
        if request.url?.lastPathComponent == "SYNO.API.Info" {
            let apis = ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Post","SYNO.Chat.Post.File","SYNO.Chat.Archive"]
            json(Dictionary(uniqueKeysWithValues:apis.map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) }));return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable,body.count < 64*1024 { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };body.append(contentsOf:buffer.prefix(count)) }
        }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:body,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let api = fields["api"] ?? "",method = fields["method"] ?? ""
        func text(_ name:String) -> String? {
            guard let value = fields[name] else { return nil }
            return (try? JSONDecoder().decode(String.self,from:Data(value.utf8))) ?? value
        }
        switch (api,method) {
        case ("SYNO.Chat.User","list"):
            json(["users":[["user_id":10,"username":"archive-fixture","nickname":"Synthetic archive user","type":"human","human_type":"dsm","user_props":["key_pair":["public_key":NativeEncryptedArchiveUIFixture.publicKey,"private_key_enc":NativeEncryptedArchiveUIFixture.wrappedPrivateKey]]]]])
        case ("SYNO.Chat.Channel","list"): json(["channels":[]])
        case ("SYNO.Chat.Misc","acl"): json(["acls":[]])
        case ("SYNO.Chat.Archive","list_name"): json(["channel_names":text("type") == "private" ? ["Synthetic encrypted archive"] : []])
        case ("SYNO.Chat.Archive","list"): json(["archives":text("type") == "private" && text("channel_name") == "Synthetic encrypted archive" ? [Self.archive] : []])
        case ("SYNO.Chat.Post.File","get"):
            guard fields["version"] == "2",let id = fields["post_id"].flatMap(Int64.init),let bytes = Self.files[id] else { reject();return }
            respond(bytes,headers:["Content-Type":"application/octet-stream","Content-Disposition":"attachment; filename=encrypted","Content-Length":String(bytes.count)])
        case ("SYNO.Chat.Post","list"):
            guard fields["archive_id"] == "600",fields["channel_id"] == "400" else { reject();return }
            var posts = Self.posts
            if let thread = fields["thread_id"].flatMap(Int64.init) { posts = posts.filter { ($0["post_id"] as? Int64) == thread || ($0["thread_id"] as? Int64) == thread } }
            else { posts = posts.filter { ($0["thread_id"] as? Int64 ?? 0) == 0 } }
            if let id = fields["post_id"].flatMap(Int64.init) {
                if fields["prev_count"] == "0",fields["next_count"] == "0" { posts = Self.posts.filter { ($0["post_id"] as? Int64) == id } }
                else { posts = posts.filter { ($0["post_id"] as? Int64 ?? 0) < id } }
            }
            json(["posts":posts])
        case ("SYNO.Chat.Post","search"):
            guard fields["archives"] == "[600]" else { reject();return }
            var posts = Self.posts.filter { ($0["thread_id"] as? Int64 ?? 0) == 0 }
            if fields["post_type"]?.contains("file") == true { posts = posts.filter { ($0["type"] as? String) == "file" } }
            if text("keyword")?.isEmpty == false || fields["has"] != nil || (fields["offset"].flatMap(Int.init) ?? 0) > 0 { posts = [] }
            json(["search_results":posts,"total":posts.count])
        default: reject()
        }
    }
    private func reject() { json([:],success:false) }
    private func json(_ data:[String:Any],success:Bool = true) {
        let result:[String:Any] = success ? ["success":true,"data":data] : ["success":false,"error":["code":119]]
        respond((try? JSONSerialization.data(withJSONObject:result)) ?? Data(),headers:["Content-Type":"application/json"])
    }
    private func respond(_ bytes:Data,status:Int = 200,headers:[String:String] = [:]) {
        guard let url = request.url,let response = HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers) else { return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if !bytes.isEmpty { client?.urlProtocol(self,didLoad:bytes) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
