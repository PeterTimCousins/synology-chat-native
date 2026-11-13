#if DEBUG
import AppKit
import SwiftUI

/// Exercises the real archive views and transfer code with intercepted synthetic responses.
/// No imported account, socket or writable NAS endpoint is involved.
@MainActor enum NativeArchiveUIFixture {
    private static var controller:ArchiveFixtureWindow?
    static func present(recovery:Bool = false) {
        guard NativeChatAppConfiguration.standalone,NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        Task {
            do {
                controller?.close()
                try await ArchiveFixtureProtocol.prepare()
                func network()->URLSession { let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ArchiveFixtureProtocol.self];c.urlCache = nil;return URLSession(configuration:c) }
                let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://archive-ui-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network)
                try await api.discover()
                let journal = recovery ? ChatChannelActionJournal(directory:FileManager.default.temporaryDirectory.appendingPathComponent("SynologyChatNative-ChannelActionUIFixture")) : ChatChannelActionJournal()
                let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,channelActionJournal:journal);model.connected = true;model.liveStatus = .live;model.names = [10:"Synthetic Peter"]
                model.archiveDeletions.activate(scope: String(repeating: "d", count: 64), ownerID: 10)
                let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1040,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                window.title = recovery ? "Channel recovery fixture — local responses only" : "Archive fixture — local responses only";window.isReleasedWhenClosed = false
                if recovery {
                    let scope = String(repeating:"c",count:64),records = try journal.activate(scope:scope)
                    if records.isEmpty {
                        try journal.remember(.init(kind:.archive,channelID:400,channelType:"private",encrypted:false,latestPostID:106,priorArchiveIDs:[600]))
                        try journal.remember(.init(kind:.close,channelID:401,channelType:"private",encrypted:false,latestPostID:nil,priorArchiveIDs:[]))
                    }
                    model.restoreChannelActions(scope:scope,loaded:[])
                    window.contentViewController = NSHostingController(rootView:NativePendingChannelActionsView(model:model))
                } else { window.contentViewController = NSHostingController(rootView:ArchiveFixtureRoot(model:model)) }
                window.center()
                controller = ArchiveFixtureWindow(window:window,model:model);controller?.showWindow(nil);window.makeKeyAndOrderFront(nil)
            } catch { NSSound.beep() }
        }
    }
}
private struct ArchiveFixtureRoot:View {
    @ObservedObject var model:NativeChatPreviewModel
    @State private var management = false
    @State private var closing = false
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Button("Review synthetic archive action") { management = true }
                Button("Review synthetic close action") { closing = true }
            }.padding(8)
            NativeArchivesView(model:model)
        }.sheet(isPresented:$closing) { if let channel = try? JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":400,"name":"Synthetic-archive","type":"private","encrypted":false,"unread":0,"is_joined":true}"#.utf8)) { NativeChannelCloseView(model:model,channel:channel) } }
        .sheet(isPresented:$management) { NativeHistoryArchiveActionView(model:model,channelID:400) }
    }
}
@MainActor private final class ArchiveFixtureWindow:NSWindowController,NSWindowDelegate {
    let model:NativeChatPreviewModel
    init(window:NSWindow,model:NativeChatPreviewModel) { self.model = model;super.init(window:window);window.delegate = self }
    required init?(coder:NSCoder) { fatalError("Not supported") }
    func windowWillClose(_ notification:Notification) { model.signOutLocally() }
}
private final class ArchiveFixtureProtocol:URLProtocol {
    static var deleted = false
    static var files:[Int64:(name:String,data:Data,image:Bool)] = [:]
    @MainActor static func prepare() async throws {
        deleted = false
        let picture = NSImage(size:NSSize(width:640,height:320),flipped:false) { rect in
            NSColor(calibratedRed:0.18,green:0.14,blue:0.28,alpha:1).setFill();rect.fill()
            NSColor(calibratedRed:0.4,green:0.85,blue:0.7,alpha:1).setFill();NSRect(x:80,y:70,width:480,height:180).fill()
            return true
        }
        guard let tiff = picture.tiffRepresentation,let bitmap = NSBitmapImageRep(data:tiff),let png = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
        let temporary = try NativeMediaTemporaryFiles.shared.create(extension:"mp4")
        defer { NativeMediaTemporaryFiles.shared.remove(temporary) }
        try await NativeSyntheticMedia.video(to:temporary)
        files = [101:("synthetic-archive.txt",Data("Synthetic archived document. No private data.\nSecond line: <literal> **text**.\n".utf8),false),
                 102:("synthetic-archive-a.png",png,true),103:("synthetic-archive-b.png",png,true),
                 104:("synthetic-archive.pdf",try NativeSyntheticDocument.data(),false),
                 105:("synthetic-archive.wav",NativeSyntheticMedia.wave(),false),
                 106:("synthetic-archive.mp4",try Data(contentsOf:temporary),false)]
    }
    static var archive:[String:Any] { ["archive_id":600,"post_start":1000,"post_end":2000,"post_id_start":0,"post_id_end":999,"props":["reason":"channel_archived","trigger_user_id":10,"channel":["channel_id":400,"name":"Synthetic-archive","purpose":"Local responses only","type":"private","encrypted":false,"unread":0]] ] }
    static func post(_ id:Int64)->[String:Any]? {
        guard let file = files[id] else { return nil }
        return ["post_id":id,"channel_id":400,"creator_id":10,"message":"Synthetic archived attachment","type":"file","create_at":1500,"comment_count":0,"file_props":["name":file.name,"size":file.data.count,"is_image":file.image,"type":(file.name as NSString).pathExtension]]
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "archive-ui-fixture.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Archive","SYNO.Chat.Post","SYNO.Chat.Post.File","SYNO.Chat.Channel","SYNO.Chat.Misc"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),method = fields["method"] ?? "",id = Int64(fields["post_id"] ?? "")
        if api == "SYNO.Chat.Channel",method == "get" { finish(["success":true,"data":["channel":["channel_id":400,"name":"Synthetic-archive","type":"private","encrypted":false,"unread":0,"is_joined":true]]]);return }
        if api == "SYNO.Chat.Channel",method == "list" { finish(["success":true,"data":["channels":[["channel_id":400,"name":"Synthetic-archive","type":"private","encrypted":false,"unread":0,"is_joined":true]]]]);return }
        if api == "SYNO.Chat.Misc",method == "acl" { finish(["success":true,"data":["acls":[["acl_name":"channel_archive","allow":true],["acl_name":"channel_close","allow":true]]]]);return }
        if api == "SYNO.Chat.Post.File",method == "get",let id,let file = Self.files[id] { respond(file.data,headers:["Content-Type":"application/octet-stream","Content-Disposition":"attachment; filename="+file.name]);return }
        if api == "SYNO.Chat.Archive",method == "list_name" { finish(["success":true,"data":["channel_names":Self.deleted ? [] : ["Synthetic-archive"]]]);return }
        if api == "SYNO.Chat.Archive",method == "list" { finish(["success":true,"data":["archives":Self.deleted ? [] : [Self.archive]]]);return }
        if api == "SYNO.Chat.Post",method == "list" {
            let posts = id.flatMap(Self.post).map { [$0] } ?? Self.files.keys.sorted().compactMap(Self.post)
            finish(["success":true,"data":["posts":posts]]);return
        }
        if api == "SYNO.Chat.Archive", method == "delete", fields["archive_id"] == "600" {
            Self.deleted = true
            finish(["success":true,"data":[:]]);return
        }
        // Only the exact synthetic archive deletion above can mutate local fixture state.
        // Fail closed for every unimplemented operation, including all writes.
        finish(["success":false,"error":["code":404]])
    }
    private func finish(_ value:[String:Any]) { respond(try! JSONSerialization.data(withJSONObject:value),headers:["Content-Type":"application/json"]) }
    private func respond(_ data:Data,headers:[String:String]) { client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
#endif
