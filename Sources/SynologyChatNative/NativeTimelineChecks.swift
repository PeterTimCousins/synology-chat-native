#if DEBUG
import AppKit
import SwiftUI

/// The real timeline and composers backed solely by fixed, synthetic reads.
/// No saved account, real socket or remote asset is available. An explicit
/// action mode mutates only this process's known synthetic posts.
@MainActor enum NativeTimelineChecks {
    nonisolated static let bundleID = "com.costwisegroup.synology-chat-native.timeline-checks"
    nonisolated static let host = "timeline-checks.invalid"
    private static var retained: Delegate?

    static func makeModel(actions: Bool = false) async throws -> NativeChatPreviewModel {
        TimelineChecksProtocol.style = .dark;TimelineChecksProtocol.extendedHistory = false
        TimelineChecksProtocol.resetHeldRead()
        TimelineChecksProtocol.configureActions(actions)
        let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            guard session.baseURL.scheme == "https", session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [TimelineChecksProtocol.self]; config.httpShouldSetCookies = false; config.urlCache = nil
            return try ChatAPIClient(session: session, network: URLSession(configuration: config),
                                     makeAttachmentNetwork: { URLSession(configuration: config) })
        }, downloadPreferences: .init(defaults:nil), emojiPreferences: .init(defaults:nil), notificationDefaults:nil)
        await model.connect(using: .init(session: .init(baseURL: URL(string: "https://" + host)!, sid: "synthetic", synoToken: "synthetic"),
                                        username: "synthetic-alex", importedFromOfficialApp: false))
        guard model.connected, model.userID == 10 else { throw ChatAPIError.invalidResponse }
        // runtimeVersion is deliberately denied by the fake transport, before
        // connect can construct a live socket. Live here enables only UI policy.
        model.suspendLiveForProbe(); model.liveStatus = .live; model.selection = 23
        model.loadSelection(); await model.historyTask?.value
        guard model.posts.count == TimelineChecksProtocol.currentPosts.count else { throw ChatAPIError.invalidResponse }
        model.error = nil
        model.draft = "Unsent synthetic draft — keep this while checking the timeline."
        model.threadDrafts[1003] = "Unsent synthetic thread reply — retained."
        return model
    }

    static func safeActionSnapshot() -> [String: Any] { TimelineChecksProtocol.actionSnapshot() }
    static func holdNextActionSet() { TimelineChecksProtocol.holdNextSet = true }
    static func releaseHeldActionSet() { TimelineChecksProtocol.releaseHeldSet() }
    static func configureActions(model: NativeChatPreviewModel, enabled: Bool) async {
        guard !model.isEditingMessage else { return }
        let draft = model.draft, threadDrafts = model.threadDrafts, root = model.threadRoot?.id
        TimelineChecksProtocol.configureActions(enabled)
        model.loadSelection()
        await model.historyTask?.value
        if let root, let post = model.posts.first(where: { $0.id == root }) { await model.openThread(post) }
        model.draft = draft; model.threadDrafts = threadDrafts
    }

    /// Holds one real history API read in this synthetic process. This measures
    /// the empty loading phase separately from the unresolved rapid-scroll H4.
    static func renderHeldReload(to directory:URL) async -> Bool {
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let model = try await makeModel()
            defer { model.signOutLocally();TimelineChecksProtocol.resetHeldRead() }
            let original = model.posts.map(\.id),draft = model.draft
            let appearance = NativeAppearancePreferences(defaults:nil)
            let host = NSHostingView(rootView:NativeChatPreviewView(model:model,appearancePreferences:appearance)
                .environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark))
            host.appearance = NSAppearance(named:.darkAqua)
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1120,height:840),styleMask:[],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = host
            defer { window.contentView = nil;window.close() }
            host.frame = NSRect(x:0,y:0,width:1120,height:840)
            func settle() async throws { for _ in 0..<6 { try await Task.sleep(nanoseconds:50_000_000);host.layoutSubtreeIfNeeded();host.displayIfNeeded() } }
            func scrollViews(_ view:NSView)->[NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
            func timelineScroll()->NSScrollView? {
                scrollViews(host).filter { $0.contentView.bounds.width > 400 && $0.contentView.bounds.height > 100 }
                    .max { $0.contentView.bounds.height < $1.contentView.bounds.height }
            }
            func capture(_ name:String) throws -> [String:Any] {
                guard !window.isVisible,let scroll = timelineScroll(),let document = scroll.documentView,
                      let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw ChatAPIError.invalidResponse }
                host.cacheDisplay(in:host.bounds,to:bitmap)
                guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
                let phase:[String:Any] = ["phase":name,"posts":model.posts.count,"loading":model.loadingHistory,
                    "clip_y":Double(scroll.contentView.bounds.origin.y),"clip_height":Double(scroll.contentView.bounds.height),
                    "document_height":Double(document.bounds.height),"reader":String(describing:ObjectIdentifier(scroll)),
                    "draft_retained":model.draft == draft,"reader_token":model.historyViewportToken.uuidString]
                try JSONSerialization.data(withJSONObject:phase,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(name+".json"),options:.withoutOverwriting)
                return phase
            }
            try await settle()
            guard let reader = timelineScroll() else { throw ChatAPIError.invalidResponse }
            var phases = [try capture("before-reload")]
            TimelineChecksProtocol.holdNextPostRead = true
            model.loadSelection()
            for _ in 0..<80 {
                if TimelineChecksProtocol.hasHeldRead { break }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            guard TimelineChecksProtocol.hasHeldRead,model.loadingHistory,model.posts.isEmpty else { throw ChatAPIError.invalidResponse }
            try await settle();phases.append(try capture("held-loading"))
            guard timelineScroll() === reader else { throw ChatAPIError.invalidResponse }
            TimelineChecksProtocol.releaseHeldRead()
            await model.historyTask?.value
            try await settle();phases.append(try capture("after-release"))
            guard !model.loadingHistory,model.error == nil,model.posts.map(\.id) == original,model.draft == draft,
                  timelineScroll() === reader,TimelineChecksProtocol.mutationAttempts == 0 else { throw ChatAPIError.invalidResponse }
            let result:[String:Any] = ["synthetic_only":true,"same_scroll_reader":true,"post_ids_restored":true,
                "draft_retained":true,"mutation_attempts":0,"visible_window_opened":false,"phases":phases,
                "scope":"Held reload only; not a reproduction or resolution of live rapid-scroll H4."]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("result.json"),options:.withoutOverwriting)
            return true
        } catch {
            if let data = try? JSONSerialization.data(withJSONObject:["synthetic_only":true,"status":"failed","error":"Held reload proof did not satisfy its contract."],options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:directory.appendingPathComponent("failure.json"),options:.withoutOverwriting) }
            return false
        }
    }

    static func run() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = Delegate(); retained = delegate; app.delegate = delegate; app.run()
    }

    private final class Delegate: NSObject, NSApplicationDelegate {
        private var window: NSWindow?
        private var model: NativeChatPreviewModel?
        func applicationDidFinishLaunching(_ notification: Notification) {
            let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
            appMenu.addItem(withTitle: "Quit Chat Timeline Checks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu; menu.addItem(appItem)
            let editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
            edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            editItem.submenu = edit; menu.addItem(editItem); NSApplication.shared.mainMenu = menu
            Task { @MainActor in
                do {
                    let model = try await makeModel(); self.model = model
                    let appearance = NativeAppearancePreferences(); appearance.followsAccount = true
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 840),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.title = "Chat Timeline Checks — synthetic account only"
                    window.minSize = NSSize(width: 820, height: 650)
                    window.contentView = NSHostingView(rootView: Controls(model: model, appearance: appearance, resize: { [weak window] compact in
                        window?.setContentSize(compact ? NSSize(width: 820, height: 680) : NSSize(width: 1120, height: 840))
                    }))
                    window.center(); self.window = window; window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } catch { fputs("Synthetic timeline checks could not start.\n", stderr); NSApplication.shared.terminate(nil) }
            }
        }
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
        func applicationWillTerminate(_ notification: Notification) { model?.signOutLocally(); model = nil }
    }

    private struct Controls: View {
        @ObservedObject var model: NativeChatPreviewModel
        @ObservedObject var appearance: NativeAppearancePreferences
        let resize: (Bool) -> Void
        @State private var compact = false
        @State private var light = false
        @State private var changingTheme = false
        @State private var themeError = false
        @State private var viewportDiagnostic = ""
        @State private var nativeReader = false
        @State private var actions = false
        @State private var configuring = false
        @State private var actionDiagnostic = ""
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text(actions ? "Synthetic timeline · local fake actions" : "Synthetic timeline · writes disabled").font(.caption)
                    Spacer()
                    Button("Simulate reconnect") { model.resyncAfterConnection() }.disabled(model.loadingHistory)
                    Button("Inspect viewport") { viewportDiagnostic = NativeTimelineViewport.diagnostic }
                    Button("Paged history") { TimelineChecksProtocol.extendedHistory = true;model.navigateToMessage(channelID:23,postID:1006) }
                    Toggle("Compact window", isOn: $compact).toggleStyle(.checkbox)
                    Toggle("Light", isOn: $light).toggleStyle(.checkbox).disabled(changingTheme)
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }.font(.caption).padding(10)
                HStack {
                    Toggle("Native reader", isOn: $nativeReader).toggleStyle(.checkbox).disabled(model.isEditingMessage)
                    Toggle("Synthetic actions", isOn: $actions).toggleStyle(.checkbox).disabled(configuring || model.isEditingMessage)
                    Button("Hold next Save") { holdNextActionSet(); inspectActions() }.disabled(!actions)
                    Button("Release Save") { releaseHeldActionSet(); inspectActions() }.disabled(!actions)
                    Button("Inspect actions") { inspectActions() }
                    Spacer()
                }.font(.caption).padding(.horizontal, 10).padding(.bottom, 6)
                HStack {
                    Text((model.viewingMessageContext ? "Context anchor: \(model.scrollPostID.map(String.init) ?? "pending")" : "Latest history") + " · \(model.posts.count) posts")
                    Spacer()
                }.font(.caption).foregroundColor(NativeChatColors.muted).padding(.horizontal,12).padding(.bottom,6)
                if !viewportDiagnostic.isEmpty { Text(viewportDiagnostic).font(.caption2).lineLimit(4) }
                if !actionDiagnostic.isEmpty { Text(actionDiagnostic).font(.caption2).lineLimit(5).textSelection(.enabled) }
                if themeError { Text("Could not load the synthetic theme.").font(.caption).foregroundColor(.orange) }
                if nativeReader { NativeChatPreviewView(model: model, appearancePreferences: appearance).usingNativeMessageViewport() }
                else { NativeChatPreviewView(model: model, appearancePreferences: appearance) }
            }.environment(\.nativeChatStyle, light ? .light : .dark).preferredColorScheme(light ? .light : .dark)
                .background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text)
                .onChange(of: compact) { resize($0) }
                .onChange(of: actions) { enabled in
                    configuring = true
                    Task { @MainActor in
                        await configureActions(model: model, enabled: enabled)
                        configuring = false; inspectActions()
                    }
                }
                .onChange(of: light) { value in
                    changingTheme = true; themeError = false; TimelineChecksProtocol.style = value ? .light : .dark
                    Task { @MainActor in
                        defer { changingTheme = false }
                        do { _ = try await model.loadAppearanceSettings() } catch { themeError = true }
                    }
                }
        }
        private func inspectActions() {
            if let data = try? JSONSerialization.data(withJSONObject: safeActionSnapshot(), options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { actionDiagnostic = text }
        }
    }
}

private final class TimelineChecksProtocol: URLProtocol {
    @MainActor static var style = ChatAppearanceStyle.dark
    @MainActor static var extendedHistory = false
    @MainActor static var holdNextPostRead = false
    @MainActor private static var heldRead:(handler:TimelineChecksProtocol,endpoint:String,fields:[String:String])?
    @MainActor static var hasHeldRead:Bool { heldRead != nil }
    @MainActor private(set) static var mutationAttempts = 0
    @MainActor private static var actionsEnabled = false
    @MainActor private static var canonical: [Int: [String: Any]] = [:]
    @MainActor private static var acceptedSets: [Int] = []
    @MainActor private static var acceptedReactions: [Int] = []
    @MainActor private static var deniedMutationAttempts = 0
    @MainActor static var holdNextSet = false
    @MainActor private static var heldSet: (handler: TimelineChecksProtocol, fields: [String: String])?
    @MainActor static var currentPosts: [[String: Any]] {
        guard actionsEnabled else { return posts }
        return (posts + [imagePost]).map { canonical[$0["post_id"] as! Int] ?? $0 }
    }
    @MainActor private static var currentReplies: [[String: Any]] {
        replies.map { actionsEnabled ? canonical[$0["post_id"] as! Int] ?? $0 : $0 }
    }
    @MainActor static func configureActions(_ enabled: Bool) {
        if let pending = heldSet, !pending.handler.isStopped { pending.handler.fail() }
        heldSet = nil; holdNextSet = false; actionsEnabled = enabled
        canonical = [:];acceptedSets = [];acceptedReactions = [];deniedMutationAttempts = 0;mutationAttempts = 0
    }
    @MainActor static func actionSnapshot() -> [String: Any] {
        ["synthetic_only": true, "actions_enabled": actionsEnabled, "mutation_attempts": mutationAttempts,
         "unknown_mutation_attempts": deniedMutationAttempts, "set_count": acceptedSets.count,
         "set_post_ids": acceptedSets, "reaction_count": acceptedReactions.count,
         "reaction_post_ids": acceptedReactions, "holding_set": heldSet != nil, "hold_next_set": holdNextSet]
    }
    @MainActor static func releaseHeldSet() {
        guard let value = heldSet else { return };heldSet = nil
        if !value.handler.isStopped { value.handler.route("SYNO.Chat.Post", fields: value.fields, resumingSet: true) }
    }
    private let stopLock = NSLock()
    private var stopped = false
    private var formIsValid = false
    private var isStopped:Bool { stopLock.lock();defer { stopLock.unlock() };return stopped }
    @MainActor static func resetHeldRead() { holdNextPostRead = false;heldRead = nil;mutationAttempts = 0 }
    @MainActor static func releaseHeldRead() {
        guard let read = heldRead else { return };heldRead = nil
        if !read.handler.isStopped { read.handler.route(read.endpoint,fields:read.fields) }
    }
    private static let base: Int64 = 1_794_481_200_000
    static let users: [[String: Any]] = [
        ["user_id": 10, "username": "synthetic-alex", "nickname": "Alex Morgan", "type": "human", "human_type": "dsm", "status": "online"],
        ["user_id": 20, "username": "synthetic-jordan", "nickname": "Jordan Lee", "type": "human", "human_type": "dsm", "status": "online"]
    ]
    static let channels: [[String: Any]] = [
        ["channel_id": 23, "name": "design-studio", "purpose": "A place to turn good ideas into thoughtful details.", "type": "private", "encrypted": false, "is_joined": true, "creator_id": 10, "unread": 0],
        ["channel_id": 24, "name": "General", "type": "public", "encrypted": false, "is_joined": true, "unread": 0],
        ["channel_id": 25, "name": "", "type": "anonymous", "encrypted": false, "is_joined": true, "unread": 0],
        ["channel_id": 26, "name": "", "type": "synobot", "creator_id": 10, "encrypted": false, "is_joined": true, "unread": 0]
    ]
    static let posts: [[String: Any]] = [
        post(1001, creator: 20, seconds: 0, text: "Morning! I’ve pulled together the notes from yesterday’s design review."),
        post(1002, creator: 20, seconds: 30, text: "The goal is simple: make the everyday conversations feel calm, clear and easy to follow."),
        post(1003, creator: 10, seconds: 90, text: "Agreed. Let’s keep the details close to the message and the conversation at the centre.", extra: ["comment_count": 2, "last_comment_at": base + 240_000,
             "reactions": [["sticker_name": "thumbsup", "user_ids": [10, 20]], ["sticker_name": "heart", "user_ids": [20]], ["sticker_name": "tada", "user_ids": [10]]]]),
        post(1004, creator: 10, seconds: 120, text: "The updated review checklist is ready for the next pass.", extra: ["is_star": true, "last_pin_at": base + 125_000, "update_at": base + 130_000]),
        post(1005, creator: 20, seconds: 180, text: "A longer message to check wrapping: the timeline should stay readable when the window is narrow, with enough room for names, timestamps and message actions. Reactions and thread links should sit naturally beneath the text, without squeezing the words into a thin column or covering the end of a sentence.\n\nThis second paragraph checks spacing while keeping the full message available for selection."),
        post(1006, creator: 20, seconds: 210, text: "Try the reaction picker, the message menu and the two-reply thread. The draft below should stay exactly as it is."),
        post(1007, creator: 20, seconds: 270, text: "Application-link review check: <line://msg/text/Synthetic|Review synthetic LINE link>. Cancel the confirmation to keep the external app closed.",extra:["props":["safe_url":true]])
    ]
    static let replies: [[String: Any]] = [
        post(1101, creator: 20, seconds: 220, text: "The thread can hold the smaller decisions without interrupting the main conversation.", extra: ["thread_id": 1003]),
        post(1102, creator: 10, seconds: 240, text: "Yes — and the main draft should still be waiting when we close it.", extra: ["thread_id": 1003])
    ]
    @MainActor private static let imagePNG: Data = {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:96,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:384,bitsPerPixel:32),let bytes = bitmap.bitmapData else { return Data() }
        for y in 0..<64 { for x in 0..<96 {
            let i = y * 384 + x * 4
            bytes[i] = UInt8(40 + x * 2);bytes[i+1] = UInt8(60 + y * 2);bytes[i+2] = 170;bytes[i+3] = 255
        } }
        return bitmap.representation(using:.png,properties:[:]) ?? Data()
    }()
    @MainActor private static var imagePost: [String: Any] {
        post(1008,creator:10,seconds:300,text:"Generated synthetic PNG — 96 × 64",extra:["type":"file","file_props":["id":1008,"name":"Synthetic timeline.png","is_image":true,"size":imagePNG.count]])
    }
    private static func post(_ id: Int, creator: Int, seconds: Int64, text: String, extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["post_id": id, "channel_id": 23, "creator_id": creator, "message": text, "type": "normal", "create_at": base + seconds * 1000, "thread_id": 0]
        value.merge(extra) { _, new in new }; return value
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https", request.url?.host == NativeTimelineChecks.host,
              request.url?.path.hasPrefix("/webapi/") == true else { fail(); return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048)
            while bytes.count < 16_384, stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: min(buffer.count, 16_384 - bytes.count))
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        guard bytes.count < 16_384 else { fail(); return }
        var parts = URLComponents(); parts.percentEncodedQuery = String(decoding: bytes, as: UTF8.self)
        let items = parts.queryItems ?? []
        let fields = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        formIsValid = request.httpMethod == "POST" && Set(items.map(\.name)).count == items.count && fields["api"] == request.url?.lastPathComponent
        let endpoint = request.url!.lastPathComponent
        DispatchQueue.main.async { self.route(endpoint, fields: fields) }
    }
    @MainActor private func route(_ endpoint: String, fields: [String: String], resumingSet: Bool = false) {
        guard !isStopped else { return }
        let method = fields["method"] ?? ""
        let mutation = !["query","list","get","acl","thumbnail"].contains(method)
        if mutation && !resumingSet { Self.mutationAttempts += 1 }
        if Self.actionsEnabled, !formIsValid {
            if mutation { Self.deniedMutationAttempts += 1 };fail();return
        }
        if endpoint == "SYNO.Chat.Post",fields["method"] == "list",Self.holdNextPostRead {
            Self.holdNextPostRead = false;Self.heldRead = (self,endpoint,fields);return
        }
        if Self.actionsEnabled, endpoint == "SYNO.Chat.Post.File", ["thumbnail","get"].contains(method) {
            guard fields["version"] == "2", fields["post_id"] == "1008",
                  Set(fields.keys).subtracting(["api","method","version"]) == (method == "thumbnail" ? ["post_id","type"] : ["post_id"]),
                  method == "get" || ["\"M\"","\"XL\""].contains(fields["type"] ?? ""), !Self.imagePNG.isEmpty else { fail();return }
            respond(Self.imagePNG, mime:"image/png");return
        }
        if Self.actionsEnabled, endpoint == "SYNO.Chat.Post", method == "set" {
            guard fields["version"] == "8", fields["channel_id"] == "23",let id = fields["post_id"].flatMap(Int.init),[1003,1004,1102].contains(id),
                  fields["thread_id"] == (id == 1102 ? "1003" : "0"),
                  Set(fields.keys) == ["api","method","version","channel_id","post_id","thread_id","message"],
                  let raw = fields["message"], let text = try? JSONDecoder().decode(String.self,from:Data(raw.utf8)),text.utf16.count <= 2000,
                  var post = (Self.currentPosts + Self.currentReplies).first(where: { $0["post_id"] as? Int == id }),post["creator_id"] as? Int == 10 else {
                Self.deniedMutationAttempts += 1;fail();return
            }
            if Self.holdNextSet && !resumingSet {
                guard Self.heldSet == nil else { Self.deniedMutationAttempts += 1;fail();return }
                Self.holdNextSet = false;Self.heldSet = (self,fields);return
            }
            post["message"] = text
            post["update_at"] = max((post["update_at"] as? Int64 ?? Self.base), Self.base + 400_000) + 1
            Self.canonical[id] = post;Self.acceptedSets.append(id)
            respondJSON([:]);return
        }
        if Self.actionsEnabled, endpoint == "SYNO.Chat.Post.Reaction", ["set","delete"].contains(method) {
            guard fields["version"] == "1",let id = fields["post_id"].flatMap(Int.init),[1003,1006].contains(id),
                  Set(fields.keys) == ["api","method","version","post_id","sticker_name"],
                  let raw = fields["sticker_name"],let name = try? JSONDecoder().decode(String.self,from:Data(raw.utf8)),ChatReactionKind(rawValue:name) != nil,
                  var post = Self.currentPosts.first(where: { $0["post_id"] as? Int == id }) else { Self.deniedMutationAttempts += 1;fail();return }
            var reactions = post["reactions"] as? [[String:Any]] ?? []
            let index = reactions.firstIndex(where: { $0["sticker_name"] as? String == name })
            if let index {
                var users = reactions[index]["user_ids"] as? [Int] ?? []
                users.removeAll(where: { $0 == 10 });if method == "set" { users.append(10) }
                if users.isEmpty { reactions.remove(at:index) } else { reactions[index]["user_ids"] = users.sorted() }
            } else if method == "set" { reactions.append(["sticker_name":name,"user_ids":[10]]) }
            post["reactions"] = reactions;Self.canonical[id] = post;Self.acceptedReactions.append(id)
            respondJSON([:]);return
        }
        let payload: [String: Any]
        switch (endpoint, fields["method"] ?? "") {
        case ("SYNO.API.Info", "query"):
            // Metadata stays stable when actions are toggled after discovery;
            // actual reaction/file routes remain unavailable in read-only mode.
            let endpoints = ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Channel.Member", "SYNO.Chat.Misc", "SYNO.Chat.Post", "SYNO.Chat.Admin.Setting", "SYNO.Chat.User.Preference", "SYNO.Chat.Post.Subscribe", "SYNO.Chat.Post.Reaction", "SYNO.Chat.Post.File"]
            payload = Dictionary(uniqueKeysWithValues: endpoints.map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 8, "requestFormat": "JSON"] as [String: Any]) })
        case ("SYNO.Chat.User", "list"): payload = ["users": Self.users]
        case ("SYNO.Chat.Channel", "list"): payload = ["channels": Self.channels]
        case ("SYNO.Chat.Channel.Member", "get"): payload = ["user_ids": [10, 20]]
        case ("SYNO.Chat.Misc", "acl"): payload = ["acls": []]
        case ("SYNO.Chat.Admin.Setting", "get"): payload = ["hide_post_url_preview": false, "allow_read_status": true, "file_size_limit": 0]
        case ("SYNO.Chat.User.Preference", "get"):
            payload = ["preferences": ["theme_style": Self.style.rawValue, "theme_background": 0, "prefer_user_name_format": "nickname", "sidebar_pinning_unread": false,
                                       "notification_showmessage": true, "notification_browser_active": true, "notification_mute": false, "calendar_enable": false, "recent_emoji": []]]
        case ("SYNO.Chat.Post.Subscribe", "get"): payload = ["subscribes": []]
        case ("SYNO.Chat.Post", "list"):
            if Self.extendedHistory,fields["channel_id"] == "23",fields["thread_id"] == nil {
                let older = (0..<60).map { index -> [String:Any] in
                    var value = Self.post(941+index,creator:index % 2 == 0 ? 10 : 20,seconds:Int64(index-61)*90,text:"Synthetic historical message \(941+index). " + String(repeating:"A readable paragraph for paging and wrapping. ",count:index % 4 + 1))
                    if (20...28).contains(index) {
                        value["type"] = "file"
                        value["file_props"] = ["id":941+index,"name":"Synthetic history \(index).txt","is_snippet":true,"is_image":false,"size":180,"snippet_preview":String(repeating:"Synthetic code line for historical rendering.\n",count:6),"snippet_lines":6,"snippet_preview_more":false] as [String:Any]
                    } else if (29...35).contains(index) {
                        value["type"] = "system";value["message"] = ""
                    } else if (36...38).contains(index) {
                        value["type"] = "file";value["file_props"] = ["id":941+index,"name":"Synthetic history.pdf","is_image":false,"size":300] as [String:Any]
                    }
                    return value
                }
                let all = older + Self.currentPosts
                let previous = Int(fields["prev_count"] ?? "30") ?? 30,next = Int(fields["next_count"] ?? "0") ?? 0
                if let anchor = fields["post_id"].flatMap(Int.init),let index = all.firstIndex(where:{ $0["post_id"] as? Int == anchor }) {
                    payload = ["posts":Array(all[..<index].suffix(previous)) + [all[index]] + Array(all.dropFirst(index+1).prefix(next))]
                } else { payload = ["posts":Array(all.suffix(previous))] }
                break
            }
            let values = fields["thread_id"] == "1003" ? Self.currentReplies : fields["channel_id"] == "23" ? Self.currentPosts : []
            if fields["prev_count"] == "0", let id = fields["post_id"].flatMap(Int.init) { payload = ["posts": (Self.currentPosts + Self.currentReplies).filter { $0["post_id"] as? Int == id }] }
            else { payload = ["posts": values] }
        default: if mutation { Self.deniedMutationAttempts += 1 };fail(); return // Every other write and unsupported endpoint is denied.
        }
        respondJSON(payload)
    }
    @MainActor private func respondJSON(_ payload: [String:Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["success": true, "data": payload]),
              !isStopped else { fail(); return }
        respond(data,mime:"application/json")
    }
    private func respond(_ data:Data,mime:String) {
        var headers = ["Content-Type":mime,"Content-Length":String(data.count)]
        if mime == "image/png" { headers["Content-Disposition"] = "attachment; filename=\"Synthetic timeline.png\"" }
        guard let url = request.url,let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:headers) else { fail();return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    override func stopLoading() {
        stopLock.lock();stopped = true;stopLock.unlock()
        DispatchQueue.main.async {
            if Self.heldRead?.handler === self { Self.heldRead = nil }
            if Self.heldSet?.handler === self { Self.heldSet = nil }
        }
    }
}
#endif
