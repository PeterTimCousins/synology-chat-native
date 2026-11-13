#if DEBUG
import AppKit
import SwiftUI

/// Synthetic server state and production recovery UI; never imports a real session.
@MainActor enum NativeConversionRecoveryFixture {
    nonisolated static let host = "conversion-recovery-fixture.invalid"
    static let originalDraft = "Preserve the synthetic conversation draft."
    static let draft = ChatChannelPromotionDraft(name:"Synthetic-private",purpose:"Synthetic conversion recovery",mode:.newChannel)
    static func validateDirectory(_ directory:URL) throws {
        guard directory.path.hasPrefix("/private/tmp/native-conversion-recovery-ui."),!directory.path.contains(".."),!directory.path.contains("\0"),
              directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw ChatAPIError.invalidResponse }
    }
    static func makeModel(directory:URL) async throws -> NativeChatPreviewModel {
        try validateDirectory(directory)
        let state = try ConversionFixtureState(directory:directory);ConversionFixtureStorage.current = state
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            guard session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
            let configuration = URLSessionConfiguration.ephemeral;configuration.protocolClasses = [ConversionFixtureProtocol.self]
            configuration.httpShouldSetCookies = false;configuration.urlCache = nil
            return try ChatAPIClient(session:session,network:URLSession(configuration:configuration))
        },promotionJournal:state.journal)
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-self",importedFromOfficialApp:false))
        guard model.connected,model.promotionRecoveryError == nil else { throw ChatAPIError.invalidResponse }
        // Local fixture readiness only: runtime configuration cannot construct a socket.
        model.liveStatus = .live;model.error = nil;model.selection = 93;model.draft = originalDraft
        return model
    }
    static var counts:[Int] {
        guard let state = ConversionFixtureStorage.current else { return [] }
        return [state.backend.creates,state.backend.joins,state.backend.invites,state.backend.promotes]
    }
    static func resolveSyntheticTarget() throws {
        guard let state = ConversionFixtureStorage.current,state.backend.hasTarget else { throw ChatAPIError.invalidResponse }
        state.backend.targetJoined = true;state.backend.targetMembers = [10,20];try state.save()
    }
    static func run() {
        let application = NSApplication.shared,delegate = ConversionFixtureDelegate()
        application.delegate = delegate;application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
    static func runContract(directory:URL,phase:String) async -> Bool {
        guard ["create-stop","restore-check","manual-resolve","verify-finished"].contains(phase) else { return false }
        do {
            try validateDirectory(directory)
            let receipt = directory.appendingPathComponent(phase+".json")
            guard !FileManager.default.fileExists(atPath:receipt.path) else { throw ChatAPIError.invalidResponse }
            let model = try await makeModel(directory:directory);defer { model.signOutLocally() }
            let before = counts,pendingBefore = model.pendingPromotions.count
            var blocked = false
            switch phase {
            case "create-stop":
                guard before == [0,0,0,0],pendingBefore == 0 else { throw ChatAPIError.invalidResponse }
                let snapshot = try await model.loadPromotionSnapshot(channelID:93)
                do { _ = try await model.promoteConversation(snapshot,draft:draft);throw ChatAPIError.invalidResponse }
                catch let error as ChatChannelPromotionFailure { guard error.uncertain else { throw error };blocked = true }
                guard counts == [1,1,0,0],model.pendingPromotions[93]?.targetID == 96 else { throw ChatAPIError.invalidResponse }
            case "restore-check":
                guard before == [1,1,0,0],pendingBefore == 1,model.pendingPromotions[93]?.targetID == 96 else { throw ChatAPIError.invalidResponse }
                guard let source = model.channels.first(where:{ $0.id == 93 }),!model.canPromoteConversation(source) else { throw ChatAPIError.invalidResponse }
                do { _ = try await model.checkPromotionStatus(channelID:93);throw ChatAPIError.invalidResponse }
                catch { guard model.pendingPromotions[93] != nil else { throw error };blocked = true }
                guard counts == before else { throw ChatAPIError.invalidResponse }
            case "manual-resolve":
                guard before == [1,1,0,0],pendingBefore == 1 else { throw ChatAPIError.invalidResponse }
                // Explicit fixture-only server-side repair; not a Chat API mutation.
                try resolveSyntheticTarget()
                let target = try await model.checkPromotionStatus(channelID:93)
                guard target.id == 96,counts == before,model.pendingPromotions.isEmpty,model.drafts[93] == originalDraft else { throw ChatAPIError.invalidResponse }
            case "verify-finished":
                guard before == [1,1,0,0],pendingBefore == 0,model.channels.contains(where:{ $0.id == 93 && $0.type == "anonymous" }),
                      model.channels.contains(where:{ $0.id == 96 && draft.matches($0) }) else { throw ChatAPIError.invalidResponse }
            default:throw ChatAPIError.invalidResponse
            }
            let value:[String:Any] = ["phase":phase,"pid":ProcessInfo.processInfo.processIdentifier,"counts_before":before,"counts_after":counts,
                "pending_before":pendingBefore,"pending_after":model.pendingPromotions.count,"known_target":model.pendingPromotions[93]?.targetID ?? 0,
                "blocked":blocked,"source_draft_retained":model.drafts[93] == originalDraft,"synthetic_only":true,"window_opened":false]
            try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:receipt,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receipt.path)
            return true
        } catch { fputs("Synthetic conversion recovery phase failed.\n",stderr);return false }
    }
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            for (name,style,missingSource) in [("dark-known-target",ChatAppearanceStyle.dark,false),("light-known-target",.light,false),("dark-missing-source-centre",.dark,true)] {
                let stateDirectory = URL(fileURLWithPath:"/private/tmp/native-conversion-recovery-ui.render-"+UUID().uuidString,isDirectory:true)
                let first = try await makeModel(directory:stateDirectory)
                let snapshot = try await first.loadPromotionSnapshot(channelID:93)
                do { _ = try await first.promoteConversation(snapshot,draft:draft) } catch { }
                first.signOutLocally()
                let restored = try await makeModel(directory:stateDirectory)
                defer { restored.signOutLocally();try? FileManager.default.removeItem(at:stateDirectory) }
                guard restored.pendingPromotions[93]?.targetID == 96 else { throw ChatAPIError.invalidResponse }
                if missingSource { restored.channels.removeAll { $0.id == 93 } }
                let content = Group {
                    if missingSource { NativePendingChannelActionsView(model:restored) }
                    else { NativeChannelPromotionView(model:restored,channelID:93) }
                }.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let width = missingSource ? 600.0 : 550.0
                let view = NSHostingView(rootView:content);view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x:0,y:0,width:width,height:520);view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:60_000_000);view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Offscreen conversion recovery rendering failed.\n",stderr);return false }
    }
}

private struct ConversionFixtureBackend:Codable {
    var creates = 0,joins = 0,invites = 0,promotes = 0
    var hasTarget = false,targetJoined = false,sourceConverted = false
    var targetName = "",targetPurpose = "",sourceName = "Synthetic conversation",sourcePurpose = ""
    var targetMembers:[Int64] = []
}
@MainActor private final class ConversionFixtureState:ObservableObject {
    let directory:URL
    let journal:ChatChannelPromotionJournal
    @Published var backend:ConversionFixtureBackend
    @Published var failJoin = true
    @Published var loseReply = false
    init(directory:URL) throws {
        self.directory = directory;journal = .init(directory:directory.appendingPathComponent("receipts"))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = directory.appendingPathComponent("synthetic-backend.json")
        if FileManager.default.fileExists(atPath:file.path) { backend = try JSONDecoder().decode(ConversionFixtureBackend.self,from:Data(contentsOf:file)) }
        else { backend = .init() }
        guard [backend.creates,backend.joins,backend.invites,backend.promotes].allSatisfy({ $0 >= 0 && $0 <= 1000 }) else { throw ChatAPIError.invalidResponse }
    }
    func save() throws {
        let file = directory.appendingPathComponent("synthetic-backend.json")
        try JSONEncoder().encode(backend).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    var source:[String:Any] { ["channel_id":93,"name":backend.sourceName,"purpose":backend.sourcePurpose,"type":backend.sourceConverted ? "private" : "anonymous","encrypted":false,"unread":0,"is_joined":true] }
    var target:[String:Any] { ["channel_id":96,"name":backend.targetName,"purpose":backend.targetPurpose,"type":"private","encrypted":false,"unread":0,"is_joined":backend.targetJoined] }
    let users:[[String:Any]] = [["user_id":10,"username":"synthetic-self","nickname":"Synthetic You","type":"human","human_type":"dsm"],
        ["user_id":20,"username":"synthetic-peer","nickname":"Synthetic Peer","type":"human","human_type":"dsm"]]
}
@MainActor private enum ConversionFixtureStorage { static var current:ConversionFixtureState? }

@MainActor private final class ConversionFixtureDelegate:NSObject,NSApplicationDelegate {
    private var window:NSWindow?
    private var model:NativeChatPreviewModel?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let menu = NSMenu(),item = NSMenuItem(),applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle:"Quit Conversion Recovery Test",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu = applicationMenu;menu.addItem(item)
        let editItem = NSMenuItem(),edit = NSMenu(title:"Edit")
        for (title,action,key) in [("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:action,keyEquivalent:key) }
        editItem.submenu = edit;menu.addItem(editItem);NSApp.mainMenu = menu
        Task { @MainActor in
            do {
                guard let file = Bundle.main.url(forResource:"FixtureRecoveryDirectory",withExtension:"txt") else { throw ChatAPIError.invalidResponse }
                let path = try String(contentsOf:file,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
                let model = try await NativeConversionRecoveryFixture.makeModel(directory:URL(fileURLWithPath:path,isDirectory:true))
                guard let state = ConversionFixtureStorage.current else { throw ChatAPIError.invalidResponse };self.model = model
                let window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                window.title = "Conversion Recovery Test — synthetic channels only";window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView:ConversionFixtureRoot(model:model,state:state))
                self.window = window;window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            } catch { NSApp.terminate(nil) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationWillTerminate(_ notification:Notification) { model?.signOutLocally() }
}
private struct ConversionFixtureRoot:View {
    @ObservedObject var model:NativeChatPreviewModel
    @ObservedObject var state:ConversionFixtureState
    @State private var showing = false
    @State private var pending = false
    @State private var failure:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Synthetic conversion recovery").font(.title2.bold())
            Text("No real NAS, account restore or live socket. All channel requests are intercepted locally.").foregroundColor(NativeChatColors.muted)
            Text("Synthetic creates: \(state.backend.creates) · Joins: \(state.backend.joins) · Invitations: \(state.backend.invites)")
            Text("Saved conversion records: \(model.pendingPromotions.count)")
            Toggle("Reject synthetic join after saving the created channel ID",isOn:$state.failJoin)
            Toggle("Lose the synthetic creation reply",isOn:$state.loseReply)
            Button("Open conversion review") { showing = true }
            Button("Open pending channel actions") { pending = true }
            Button("Simulate completing target membership outside this app") {
                do { try NativeConversionRecoveryFixture.resolveSyntheticTarget();failure = nil }
                catch { failure = error.localizedDescription }
            }.disabled(!state.backend.hasTarget)
            if let failure { Text(failure).foregroundColor(.orange) }
            Text("Create and join controls affect only the fake backend. Check status never sends invitations. Quit and reopen to test the saved checkpoint.").font(.callout).foregroundColor(NativeChatColors.muted)
            Spacer()
        }.padding(24).frame(minWidth:680,minHeight:650,alignment:.topLeading).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).nativeChatAppearance()
            .sheet(isPresented:$showing) { NativeChannelPromotionView(model:model,channelID:93) }
            .sheet(isPresented:$pending) { NativePendingChannelActionsView(model:model) }
    }
}
private final class ConversionFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == NativeConversionRecoveryFixture.host else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
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
        guard let state = ConversionFixtureStorage.current else { fail();return }
        if endpoint == "SYNO.API.Info" {
            let names = ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Channel.Member","SYNO.Chat.Channel.Named","SYNO.Chat.Channel.Anonymous"]
            finish(["success":true,"data":Dictionary(uniqueKeysWithValues:names.map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return
        }
        func string(_ key:String)->String? { fields[key].flatMap { try? JSONDecoder().decode(String.self,from:Data($0.utf8)) } }
        do {
            switch (endpoint,fields["method"] ?? "") {
            case ("SYNO.Chat.User","list"):finish(["success":true,"data":["users":state.users]])
            case ("SYNO.Chat.Misc","acl"):finish(["success":true,"data":["acls":[["acl_name":"channel_create","allow":true],["acl_name":"channel_invite","allow":true]]]])
            case ("SYNO.Chat.Channel","list"):
                let unjoined = fields["is_joined"] == "false"
                let channels = unjoined ? (state.backend.hasTarget && !state.backend.targetJoined ? [state.target] : []) : [state.source]+(state.backend.hasTarget && state.backend.targetJoined ? [state.target] : [])
                finish(["success":true,"data":["channels":channels]])
            case ("SYNO.Chat.Channel.Member","get"):finish(["success":true,"data":["user_ids":fields["channel_id"] == "96" ? state.backend.targetMembers : [10,20]]])
            case ("SYNO.Chat.Channel.Named","create"):
                state.backend.creates += 1;try state.save()
                guard !state.backend.hasTarget,let name = string("name"),let purpose = string("purpose") else { fail();return }
                state.backend.hasTarget = true;state.backend.targetName = name;state.backend.targetPurpose = purpose;state.backend.targetMembers = [10];try state.save()
                if state.loseReply { client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost)) }
                else { finish(["success":true,"data":["channel_id":96]]) }
            case ("SYNO.Chat.Channel.Named","join"):
                state.backend.joins += 1;try state.save()
                guard fields["channel_id"] == "96",state.backend.hasTarget else { fail();return }
                if !state.failJoin { state.backend.targetJoined = true };try state.save()
                if state.failJoin { fail() } else { finish(["success":true]) }
            case ("SYNO.Chat.Channel.Named","invite"):
                state.backend.invites += 1;try state.save()
                guard fields["channel_id"] == "96",state.backend.targetJoined else { fail();return }
                state.backend.targetMembers = [10,20];try state.save();finish(["success":true])
            case ("SYNO.Chat.Channel.Anonymous","promote"):
                state.backend.promotes += 1;try state.save()
                guard fields["channel_id"] == "93",let name = string("name"),let purpose = string("purpose") else { fail();return }
                state.backend.sourceConverted = true;state.backend.sourceName = name;state.backend.sourcePurpose = purpose;try state.save()
                if state.loseReply { client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost)) } else { finish(["success":true]) }
            default:fail()
            }
        } catch { fail() }
    }
    private func fail() { finish(["success":false,"error":["code":119]]) }
    private func finish(_ value:[String:Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject:value),let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"]) else { return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
