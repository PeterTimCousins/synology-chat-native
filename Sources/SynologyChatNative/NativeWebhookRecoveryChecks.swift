#if DEBUG
import AppKit
import SwiftUI

/// A durable synthetic server and receipt folder. Every request is intercepted;
/// no real account, callback, token, socket or network destination is available.
@MainActor enum NativeWebhookRecoveryChecks {
    static let bundleID = "com.costwisegroup.synology-chat-native.webhook-recovery-checks"
    static func run() {
        let app = NSApplication.shared,delegate = Delegate()
        app.setActivationPolicy(.regular);app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    private final class Delegate:NSObject,NSApplicationDelegate {
        var window:NSWindow?
        var model:NativeChatPreviewModel?
        func applicationDidFinishLaunching(_ notification:Notification) {
            let menu = NSMenu(),item = NSMenuItem(),submenu = NSMenu()
            submenu.addItem(withTitle:"Quit Integration Recovery Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            item.submenu = submenu;menu.addItem(item);NSApplication.shared.mainMenu = menu
            Task { @MainActor in
                do {
                    guard let resource = Bundle.main.url(forResource:"FixtureRecoveryDirectory",withExtension:"txt") else { throw ChatAPIError.invalidResponse }
                    let directory = URL(fileURLWithPath:try String(contentsOf:resource,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines),isDirectory:true)
                    guard directory.path.hasPrefix("/private/tmp/native-webhook-recovery-ui."),directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw ChatAPIError.invalidResponse }
                    try WebhookRecoveryCheckProtocol.configure(directory)
                    let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
                        guard session.baseURL.host == "webhook-recovery.invalid" else { throw ChatAPIError.invalidResponse }
                        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [WebhookRecoveryCheckProtocol.self]
                        config.httpShouldSetCookies = false;config.urlCache = nil
                        return try ChatAPIClient(session:session,network:URLSession(configuration:config))
                    },webhookActionJournal:.init(directory:directory.appendingPathComponent("receipts",isDirectory:true)))
                    await model.connect(using:.init(session:.init(baseURL:URL(string:"https://webhook-recovery.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
                    guard model.connected,model.userID == 10 else { throw ChatAPIError.invalidResponse }
                    model.suspendLiveForProbe();model.liveStatus = .live;model.error = nil;self.model = model
                    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:780),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
                    window.isReleasedWhenClosed = false;window.title = "Integration Recovery Checks — synthetic server only"
                    window.contentViewController = NSHostingController(rootView:Checks(model:model))
                    self.window = window;window.center();window.makeKeyAndOrderFront(nil);NSApplication.shared.activate(ignoringOtherApps:true)
                } catch { fputs("Synthetic webhook recovery checks could not start.\n",stderr);NSApplication.shared.terminate(nil) }
            }
        }
        func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
        func applicationWillTerminate(_ notification:Notification) { model?.signOutLocally();model = nil }
    }
    private struct Checks:View {
        @ObservedObject var model:NativeChatPreviewModel
        var body:some View {
            VStack(spacing:0) {
                HStack {
                    Text("Synthetic dispatches: \(WebhookRecoveryCheckProtocol.dispatches) · Saved guards: \(model.pendingWebhookActions.count)").font(.caption)
                    Spacer();Button("Quit") { NSApplication.shared.terminate(nil) }
                }.padding(12)
                Divider()
                NativeWebhooksView(model:model)
            }.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark)
                .foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas)
        }
    }
}

private final class WebhookRecoveryCheckProtocol:URLProtocol {
    @MainActor static var directory:URL?
    @MainActor static var dispatches = 0
    @MainActor static var records:[[String:Any]] = []
    @MainActor static func configure(_ folder:URL) throws {
        directory = folder
        let file = folder.appendingPathComponent("synthetic-server.json")
        if FileManager.default.fileExists(atPath:file.path) {
            let object = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]
            guard let count = object?["dispatches"] as? Int,count >= 0,let rows = object?["records"] as? [[String:Any]],
                  rows.allSatisfy({ ($0["user_id"] as? Int ?? 0) >= 100 && $0["creator_id"] as? Int == 10 && $0["bot_type"] as? String == "incoming" && $0["url"] as? String == "" }) else { throw ChatAPIError.invalidResponse }
            dispatches = count;records = rows
        } else { dispatches = 0;records = [record(100,disabled:true)];try persist() }
    }
    @MainActor private static func record(_ id:Int,disabled:Bool)->[String:Any] {
        ["user_id":id,"creator_id":10,"nickname":"Synthetic integration \(id)","type":"bot","bot_type":"incoming","channel_id":0,"is_disabled":disabled,"deleted":false,"token":"synthetic-only-\(id)","url":"","trigger_word":""]
    }
    @MainActor private static func persist() throws {
        guard let directory else { throw ChatAPIError.invalidResponse }
        let file = directory.appendingPathComponent("synthetic-server.json")
        try JSONSerialization.data(withJSONObject:["dispatches":dispatches,"records":records]).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == "webhook-recovery.invalid" else { fail();return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while bytes.count < 16384,stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };bytes.append(contentsOf:buffer.prefix(count)) }
        }
        guard bytes.count < 16384 else { fail();return }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let endpoint = request.url!.lastPathComponent
        DispatchQueue.main.async { self.route(endpoint,fields) }
    }
    @MainActor private func route(_ endpoint:String,_ fields:[String:String]) {
        let value:[String:Any]
        switch (endpoint,fields["method"] ?? "") {
        case ("SYNO.API.Info","query"):
            value = Dictionary(uniqueKeysWithValues:["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Webhook.Incoming","SYNO.Chat.Webhook.Outgoing","SYNO.Chat.Bot"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })
        case ("SYNO.Chat.User","list"):
            value = ["users":[["user_id":10,"username":"synthetic","nickname":"Synthetic Peter","type":"human","human_type":"dsm"] as [String:Any]] + Self.records]
        case ("SYNO.Chat.Channel","list"):
            value = ["channels":fields["is_joined"] == "false" ? [] : [["channel_id":93,"name":"Synthetic own conversation","type":"private","encrypted":false,"is_joined":true,"unread":0]]]
        case ("SYNO.Chat.Misc","acl"):
            value = ["acls":["webhook_read","webhook_create"].map { ["acl_name":$0,"allow":true] as [String:Any] }]
        case ("SYNO.Chat.Webhook.Incoming","get"):
            guard let id = fields["user_id"].flatMap(Int.init),let record = Self.records.first(where:{ $0["user_id"] as? Int == id }) else { fail();return }
            value = record
        case ("SYNO.Chat.Webhook.Incoming","create"):
            Self.dispatches += 1;Self.records.append(Self.record(100+Self.dispatches,disabled:false))
            do { try Self.persist() } catch { fail();return }
            // The synthetic server commits, then deliberately loses the reply.
            client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return
        default: fail();return // No other mutation, socket or external destination.
        }
        guard let url = request.url,let data = try? JSONSerialization.data(withJSONObject:["success":true,"data":value]) else { fail();return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
    override func stopLoading() {}
}
#endif
