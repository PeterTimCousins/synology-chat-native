#if DEBUG
import AppKit
import SwiftUI

/// Separate synthetic application: no imported account, Keychain, live socket or external integration.
@MainActor enum NativeSlashRecoveryFixture {
    nonisolated static let host = "slash-recovery-fixture.invalid"
    static let scope = String(repeating:"c",count:64)
    static let input = "/synthetic private fixture arguments"
    static func validateDirectory(_ directory:URL) throws {
        let path = directory.path
        guard path.hasPrefix("/private/tmp/native-slash-recovery-ui."),!path.contains(".."),!path.contains("\0"),
              directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw ChatAPIError.invalidResponse }
    }
    static func makeModel(directory:URL) async throws -> NativeChatPreviewModel {
        try validateDirectory(directory)
        let state = try SlashRecoveryFixtureState(directory:directory)
        SlashRecoveryFixtureStorage.current = state
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlashRecoveryFixtureProtocol.self];configuration.httpShouldSetCookies = false;configuration.urlCache = nil
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:configuration))
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,
            makeClient:{ _ in throw ChatAPIError.unsupportedAPI },slashActionJournal:.init(directory:directory.appendingPathComponent("receipts")))
        model.directory = try JSONDecoder().decode(UserList.self,from:JSONSerialization.data(withJSONObject:["users":state.users])).users
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:state.channel))]
        model.connected = true;model.liveStatus = .live;model.selection = 93;model.draft = input
        model.restoreSlashRecovery(scope:scope)
        return model
    }
    static var totalDispatches:Int { SlashRecoveryFixtureStorage.current?.total ?? -1 }
    static func setAcknowledgedResponse(_ enabled:Bool) { SlashRecoveryFixtureStorage.current?.acknowledge = enabled }
    static func run() {
        let application = NSApplication.shared,delegate = SlashRecoveryFixtureDelegate()
        application.delegate = delegate;application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
    /// Render app-owned views only: no window, desktop capture or input.
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            var measurements:[[String:Any]] = []
            for (name,style,storageError) in [("dark-pending",ChatAppearanceStyle.dark,false),("light-pending",.light,false),("dark-storage-error",.dark,true)] {
                let stateDirectory = URL(fileURLWithPath:"/private/tmp/native-slash-recovery-ui.render-"+UUID().uuidString,isDirectory:true)
                let model = try await makeModel(directory:stateDirectory)
                defer { model.signOutLocally();try? FileManager.default.removeItem(at:stateDirectory) }
                try await model.prepareSlashCommands(fromComposer:true)
                guard let request = model.slashCommandRequest,let command = request.commands.first(where:{ $0.name == "synthetic" }) else { throw ChatAPIError.invalidResponse }
                do { _ = try await model.executeSlashCommand(request,command:command,message:input);throw ChatAPIError.invalidResponse }
                catch let error as ChatSlashFailure { guard error.uncertain else { throw error } }
                if storageError {
                    try Data("synthetic unreadable recovery record".utf8).write(to:stateDirectory.appendingPathComponent("receipts").appendingPathComponent(scope+".json"))
                    do { try model.refreshSlashRecovery(request);throw ChatAPIError.invalidResponse }
                    catch { guard model.slashRecoveryError != nil else { throw error } }
                }
                let content = NativeSlashCommandView(model:model,request:request).environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let view = NSHostingView(rootView:content)
                view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x:0,y:0,width:570,height:720);view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:60_000_000);view.layoutSubtreeIfNeeded()
                let fitting = view.fittingSize
                measurements.append(["name":name,"fitting_width":fitting.width,"fitting_height":fitting.height,"render_width":570,"render_height":720])
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let png = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try png.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("measurements.json"),options:.withoutOverwriting)
            return true
        } catch { fputs("Offscreen command recovery rendering failed.\n",stderr);return false }
    }
    /// Headless process proof. Each phase has an immutable safe receipt and never opens a window.
    static func runContract(directory:URL,phase:String) async -> Bool {
        let phases = ["dispatch-unknown","verify-restored","acknowledge-only","dispatch-ack","verify-finished"]
        guard phases.contains(phase) else { return false }
        do {
            try validateDirectory(directory)
            let receipt = directory.appendingPathComponent(phase+".json")
            guard !FileManager.default.fileExists(atPath:receipt.path) else { throw ChatAPIError.invalidResponse }
            let model = try await makeModel(directory:directory)
            defer { model.signOutLocally() }
            guard model.slashRecoveryError == nil else { throw ChatAPIError.invalidResponse }
            let before = totalDispatches,pendingBefore = model.pendingSlashInvocations.count
            var blocked = false
            if phase != "verify-finished" {
                try await model.prepareSlashCommands(fromComposer:true)
                guard let request = model.slashCommandRequest,let command = request.commands.first(where:{ $0.name == "synthetic" }) else { throw ChatAPIError.invalidResponse }
                switch phase {
                case "dispatch-unknown":
                    guard before == 0,pendingBefore == 0 else { throw ChatAPIError.invalidResponse }
                    do { _ = try await model.executeSlashCommand(request,command:command,message:input);throw ChatAPIError.invalidResponse }
                    catch let error as ChatSlashFailure { guard error.uncertain else { throw error };blocked = true }
                    guard totalDispatches == 1,model.pendingSlashInvocations.count == 1 else { throw ChatAPIError.invalidResponse }
                case "verify-restored":
                    guard before == 1,pendingBefore == 1 else { throw ChatAPIError.invalidResponse }
                    do { _ = try await model.executeSlashCommand(request,command:command,message:input);throw ChatAPIError.invalidResponse }
                    catch let error as ChatSlashFailure { guard error.uncertain else { throw error };blocked = true }
                    guard totalDispatches == 1,model.pendingSlashInvocations.count == 1 else { throw ChatAPIError.invalidResponse }
                case "acknowledge-only":
                    guard before == 1,pendingBefore == 1,let pending = model.pendingSlashInvocations.values.first else { throw ChatAPIError.invalidResponse }
                    try model.acknowledgeSlashOutcome(pending,request:request)
                    guard totalDispatches == 1,model.pendingSlashInvocations.isEmpty else { throw ChatAPIError.invalidResponse }
                case "dispatch-ack":
                    guard before == 1,pendingBefore == 0 else { throw ChatAPIError.invalidResponse }
                    setAcknowledgedResponse(true)
                    _ = try await model.executeSlashCommand(request,command:command,message:input)
                    guard totalDispatches == 2,model.pendingSlashInvocations.isEmpty,model.draft.isEmpty else { throw ChatAPIError.invalidResponse }
                default:throw ChatAPIError.invalidResponse
                }
            } else {
                guard before == 2,pendingBefore == 0 else { throw ChatAPIError.invalidResponse }
            }
            let record:[String:Any] = ["phase":phase,"pid":ProcessInfo.processInfo.processIdentifier,"dispatches_before":before,"dispatches_after":totalDispatches,
                "pending_before":pendingBefore,"pending_after":model.pendingSlashInvocations.count,"blocked":blocked,"selected_channel":model.selection ?? 0,
                "draft_empty":model.draft.isEmpty,"synthetic_only":true,"window_opened":false]
            try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:receipt,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receipt.path)
            return true
        } catch { fputs("Synthetic slash recovery phase failed.\n",stderr);return false }
    }
}

@MainActor private final class SlashRecoveryFixtureState:ObservableObject {
    let directory:URL
    @Published var total:Int
    @Published var processDispatches = 0
    @Published var acknowledge = false
    let channel:[String:Any] = ["channel_id":93,"name":"Synthetic command destination","type":"anonymous","encrypted":false,"unread":0,"is_joined":true]
    let users:[[String:Any]] = [
        ["user_id":10,"username":"synthetic-self","nickname":"Synthetic You","type":"human","human_type":"dsm"],
        ["user_id":20,"username":"synthetic-peer","nickname":"Synthetic Peer","type":"human","human_type":"dsm"],
        ["user_id":42,"nickname":"Synthetic integration","type":"bot","bot_type":"slash","is_disabled":false,
         "slash_props":["cmd":"synthetic","description":"Local synthetic command — no integration is contacted","usage":"/synthetic arguments","url":"https://never-called.invalid/synthetic"]]]
    init(directory:URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = directory.appendingPathComponent("synthetic-dispatch-count.txt")
        if FileManager.default.fileExists(atPath:file.path) {
            guard let value = Int(try String(contentsOf:file,encoding:.utf8)),value >= 0 else { throw ChatAPIError.invalidResponse };total = value
        } else { total = 0 }
    }
    func recordDispatch() throws {
        let file = directory.appendingPathComponent("synthetic-dispatch-count.txt")
        try Data(String(total+1).utf8).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        total += 1;processDispatches += 1
    }
}
@MainActor private enum SlashRecoveryFixtureStorage { static var current:SlashRecoveryFixtureState? }

@MainActor private final class SlashRecoveryFixtureDelegate:NSObject,NSApplicationDelegate {
    private var window:NSWindow?
    private var model:NativeChatPreviewModel?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let menu = NSMenu(),item = NSMenuItem(),applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle:"Quit Command Recovery Test",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu = applicationMenu;menu.addItem(item)
        let editItem = NSMenuItem(),editMenu = NSMenu(title:"Edit")
        for (title,action,key) in [("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { editMenu.addItem(withTitle:title,action:action,keyEquivalent:key) }
        editItem.submenu = editMenu;menu.addItem(editItem);NSApp.mainMenu = menu
        Task { @MainActor in
            do {
                guard let config = Bundle.main.url(forResource:"FixtureRecoveryDirectory",withExtension:"txt") else { throw ChatAPIError.invalidResponse }
                let path = try String(contentsOf:config,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
                let model = try await NativeSlashRecoveryFixture.makeModel(directory:URL(fileURLWithPath:path,isDirectory:true))
                guard let state = SlashRecoveryFixtureStorage.current else { throw ChatAPIError.invalidResponse }
                self.model = model
                let window = NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                window.title = "Command Recovery Test — synthetic requests only";window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView:SlashRecoveryFixtureRoot(model:model,state:state))
                self.window = window;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            } catch { NSApp.terminate(nil) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationWillTerminate(_ notification:Notification) { model?.signOutLocally() }
}
private struct SlashRecoveryFixtureRoot:View {
    @ObservedObject var model:NativeChatPreviewModel
    @ObservedObject var state:SlashRecoveryFixtureState
    @State private var failure:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Synthetic command recovery").font(.title2.bold())
            Text("No NAS account, Keychain restore, live socket or external integration. Requests are intercepted locally.").foregroundColor(NativeChatColors.muted)
            Text("Requests this process: \(state.processDispatches) · Total synthetic requests: \(state.total)")
            Text("Saved recovery records: \(model.pendingSlashInvocations.count)")
            Toggle("Return a synthetic acknowledgement instead of losing the reply",isOn:$state.acknowledge).disabled(model.slashBusy)
            Button("Open reviewed synthetic command") {
                Task { @MainActor in
                    do { try await model.prepareSlashCommands(fromComposer:true);failure = nil }
                    catch { failure = error.localizedDescription }
                }
            }.disabled(!model.canOpenSlashCommands())
            if let failure { Text(failure).foregroundColor(.orange) }
            Text("Quit and reopen this test app to verify saved recovery. Clearing a record in Commands never sends a request. Run is a separate explicit action.").font(.callout).foregroundColor(NativeChatColors.muted)
            Spacer()
        }.padding(24).frame(minWidth:640,minHeight:650,alignment:.topLeading).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).nativeChatAppearance()
            .sheet(item:Binding(get:{ model.slashCommandRequest },set:{ if $0 == nil { model.dismissSlashCommands() } })) { NativeSlashCommandView(model:model,request:$0) }
    }
}
private final class SlashRecoveryFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == NativeSlashRecoveryFixture.host else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };data.append(contentsOf:buffer.prefix(count)) }
        }
        var components = URLComponents();components.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),endpoint = request.url!.lastPathComponent
        DispatchQueue.main.async { self.route(endpoint:endpoint,fields:fields) }
    }
    @MainActor private func route(endpoint:String,fields:[String:String]) {
        guard let state = SlashRecoveryFixtureStorage.current else { fail();return }
        if endpoint == "SYNO.API.Info" {
            let names = ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Webhook.Slash","SYNO.Chat.Post"]
            finish(["success":true,"data":Dictionary(uniqueKeysWithValues:names.map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return
        }
        switch (endpoint,fields["method"] ?? "") {
        case ("SYNO.Chat.User","list"):finish(["success":true,"data":["users":state.users]])
        case ("SYNO.Chat.Channel","list"):finish(["success":true,"data":["channels":[state.channel]]])
        case ("SYNO.Chat.Channel.Member","get"):finish(["success":true,"data":["user_ids":[10,20]]])
        case ("SYNO.Chat.Post","list"):finish(["success":true,"data":["posts":[]]])
        case ("SYNO.Chat.Webhook.Slash","execute"):
            guard fields["channel_id"] == "93",fields["user_id"] == "42" else { fail();return }
            do { try state.recordDispatch() } catch { fail();return }
            if state.acknowledge { finish(["success":true,"data":["message":"Synthetic acknowledgement. No external integration was contacted."]]) }
            else { client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost)) }
        default:fail()
        }
    }
    private func fail() { finish(["success":false,"error":["code":119]]) }
    private func finish(_ value:[String:Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject:value),let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"]) else { return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
