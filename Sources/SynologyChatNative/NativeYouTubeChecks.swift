#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeYouTubeChecks {
    nonisolated static let bundleID = "com.costwisegroup.synology-chat-native.youtube-checks"
    private static var retained:Delegate?
    static let destination = URL(string:"https://www.youtube.com/watch?v=M7lc1UVf-VE")!
    static func makeModel() async throws -> NativeChatPreviewModel {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [YouTubeChecksProtocol.self];config.urlCache = nil;config.httpShouldSetCookies = false
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://youtube-checks.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:YouTubeChecksProtocol.channel))]
        model.posts = [try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:YouTubeChecksProtocol.post))]
        model.connected = true;model.selection = 23;model.liveStatus = .rejected;model.draft = "Unsent synthetic video-check draft."
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("setting.update"),"data":.object(["hide_post_url_preview":.bool(false)])])))
        return model
    }
    static func run() {
        let app = NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate = Delegate();retained = delegate;app.delegate = delegate;app.run()
    }
    private final class Delegate:NSObject,NSApplicationDelegate {
        var window:NSWindow?
        var model:NativeChatPreviewModel?
        func applicationDidFinishLaunching(_ notification:Notification) {
            let root = NSMenu(),item = NSMenuItem(),menu = NSMenu()
            menu.addItem(withTitle:"Quit Chat Video Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            item.submenu = menu;root.addItem(item);NSApplication.shared.mainMenu = root
            Task { @MainActor in
                do {
                    let model = try await makeModel();self.model = model
                    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:460),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
                    window.title = "Chat Video Checks — synthetic message, public demo video"
                    window.contentView = NSHostingView(rootView:Checks(model:model));window.isReleasedWhenClosed = false
                    window.center();self.window = window;window.makeKeyAndOrderFront(nil);NSApplication.shared.activate(ignoringOtherApps:true)
                } catch { NSApplication.shared.terminate(nil) }
            }
        }
        func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
        func applicationWillTerminate(_ notification:Notification) { model?.signOutLocally();model = nil }
    }
    private struct Checks:View {
        @ObservedObject var model:NativeChatPreviewModel
        var body:some View {
            VStack(alignment:.leading,spacing:18) {
                HStack { Text("Video preview checks").font(.title2.bold());Spacer();Button("Quit") { NSApplication.shared.terminate(nil) } }
                Text("A synthetic message links to YouTube’s public player demo. The player loads only when Play video is selected.").font(.callout).foregroundColor(NativeChatColors.muted)
                if let post = model.posts.first,let item = model.linkPreviews(for:post).first { NativeLinkPreviewCard(post:post,item:item,model:model) }
                Text("Planning draft: "+model.draft).font(.caption).foregroundColor(NativeChatColors.muted)
                Spacer()
            }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).preferredColorScheme(.dark)
        }
    }
}

private final class YouTubeChecksProtocol:URLProtocol {
    static let channel:[String:Any] = ["channel_id":23,"name":"Synthetic Planning","type":"public","encrypted":false,"is_joined":true,"unread":0]
    static let post:[String:Any] = ["post_id":5001,"channel_id":23,"creator_id":10,"type":"normal","message":"https://www.youtube.com/watch?v=M7lc1UVf-VE","create_at":1794481200000,"props":["safe_url":true],"url_props":[["url":"https://www.youtube.com/watch?v=M7lc1UVf-VE","title":"YouTube IFrame Player API demo","description":"Public demo from the YouTube player documentation."]]]
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "youtube-checks.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        let leaf = request.url!.lastPathComponent
        let payload:[String:Any]
        if leaf == "SYNO.API.Info" { payload = Dictionary(uniqueKeysWithValues:["SYNO.Chat.Post","SYNO.Chat.Channel"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) }) }
        else {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while bytes.count < 16384,stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:min(buffer.count,16384-bytes.count));if n <= 0 { break };bytes.append(contentsOf:buffer.prefix(n)) } }
            var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
            guard parts.queryItems?.first(where:{ $0.name == "method" })?.value == "list" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
            if leaf == "SYNO.Chat.Channel" { payload = ["channels":[Self.channel]] }
            else if leaf == "SYNO.Chat.Post" { payload = ["posts":[Self.post]] }
            else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        }
        let data = try! JSONSerialization.data(withJSONObject:["success":true,"data":payload])
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
