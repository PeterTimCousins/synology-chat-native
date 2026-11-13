#if DEBUG
import AppKit
import SwiftUI

/// Real settings view, synthetic account and intercepted API responses only.
@MainActor enum NativeNotificationSettingsFixture {
    nonisolated static let regionalBundleID = "com.costwisegroup.synology-chat-native.regional-checks"
    nonisolated static let regionalAXBundleID = "com.costwisegroup.synology-chat-native.regional-ax-checks"
    private static var regionalDelegate:RegionalChecksDelegate?
    static func runRegionalChecks() {
        let app = NSApplication.shared;app.setActivationPolicy(.regular)
        let handler = RegionalChecksDelegate();regionalDelegate = handler;app.delegate = handler;app.run()
    }
    private final class RegionalChecksDelegate:NSObject,NSApplicationDelegate {
        private var model:NativeChatPreviewModel?
        private var window:NSWindow?
        func applicationDidFinishLaunching(_ notification:Notification) {
            let menu = NSMenu(),item = NSMenuItem(),submenu = NSMenu()
            submenu.addItem(withTitle:"Quit Regional Settings Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            item.submenu = submenu;menu.addItem(item);NSApplication.shared.mainMenu = menu
            Task { @MainActor in
                do {
                    reset();let model = try await makeModel();self.model = model
                    model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic settings","type":"private","encrypted":false,"is_joined":true,"unread":0}"#.utf8))]
                    model.selection = 23
                    model.draft = "Unsent synthetic regional settings draft — retained."
                    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:740),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                    window.title = "Regional Settings Checks — synthetic server only";window.isReleasedWhenClosed = false
                    window.contentView = NSHostingView(rootView:RegionalChecks(model:model));self.window = window
                    window.center();window.makeKeyAndOrderFront(nil);NSApplication.shared.activate(ignoringOtherApps:true)
                } catch { NSApplication.shared.terminate(nil) }
            }
        }
        func applicationWillTerminate(_ notification:Notification) { model?.signOutLocally();model = nil }
    }
    private struct RegionalChecks:View {
        @ObservedObject var model:NativeChatPreviewModel
        @State private var showing = false
        @State private var profile = false
        @State private var names = false
        @State private var availability = false
        @State private var light = false
        var body:some View {
            VStack(alignment:.leading,spacing:20) {
                Text("Synthetic account settings · no real account").font(.headline)
                Toggle("Light appearance",isOn:$light).toggleStyle(.checkbox)
                Button("Open language & time") { showing = true }
                Button("Open edit profile") { profile = true }
                Button("Open name display") { names = true }
                Button("Open availability") { availability = true }
                Text(model.draft).font(.callout)
                Button("Quit checks") { NSApplication.shared.terminate(nil) }
                Spacer()
            }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                .background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text)
                .environment(\.nativeChatStyle,light ? .light : .dark).preferredColorScheme(light ? .light : .dark)
                .sheet(isPresented:$showing) { NativeRegionalSettingsView(model:model).environment(\.nativeChatStyle,light ? .light : .dark).preferredColorScheme(light ? .light : .dark) }
                .sheet(isPresented:$profile) { NativeProfileEditorView(model:model).environment(\.nativeChatStyle,light ? .light : .dark).preferredColorScheme(light ? .light : .dark) }
                .sheet(isPresented:$names) { NativeNameSettingsView(model:model).environment(\.nativeChatStyle,light ? .light : .dark).preferredColorScheme(light ? .light : .dark) }
                .sheet(isPresented:$availability) { NativeManualPresenceView(model:model).environment(\.nativeChatStyle,light ? .light : .dark).preferredColorScheme(light ? .light : .dark) }
        }
    }
    private static var controller:NotificationSettingsFixtureWindow?
    private static func reset() {
        NotificationSettingsFixtureProtocol.launcherApps = NotificationSettingsFixtureProtocol.initialLauncherApps
        NotificationSettingsFixtureProtocol.personal = NotificationSettingsFixtureProtocol.initialPersonal
        NotificationSettingsFixtureProtocol.timezone = "def"; NotificationSettingsFixtureProtocol.devices = NotificationSettingsFixtureProtocol.initialDevices
        NotificationSettingsFixtureProtocol.preferences = NotificationSettingsFixtureProtocol.initial
        NotificationSettingsFixtureProtocol.avatarVersion = 0; NotificationSettingsFixtureProtocol.photoData = Data()
        NotificationSettingsFixtureProtocol.away = false; NotificationSettingsFixtureProtocol.nickname = "Synthetic Peter"
        NotificationSettingsFixtureProtocol.description = "Local profile fixture"
    }
    private static func makeModel() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            guard session.baseURL.scheme == "https",session.baseURL.host == "notification-settings-ui.invalid" else { throw ChatAPIError.invalidResponse }
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [NotificationSettingsFixtureProtocol.self]
            config.httpShouldSetCookies = false;config.urlCache = nil
            return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://notification-settings-ui.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        guard model.connected else { throw ChatAPIError.invalidResponse }
        return model
    }
    static func renderAccountSettings(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            var metadata:[[String:Any]] = []
            for style in ChatAppearanceStyle.allCases {
                for kind in ["profile","names","availability"] {
                    reset();let model = try await makeModel();defer { model.signOutLocally() }
                    model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic settings","type":"private","encrypted":false,"is_joined":true,"unread":0}"#.utf8))]
                    model.selection = 23;model.draft = "Unsent synthetic account-settings render draft."
                    let beforeWrites = NotificationSettingsFixtureProtocol.renderReads.snapshot.writes
                    let content:AnyView
                    switch kind {
                    case "profile": content = AnyView(NativeProfileEditorView(model:model))
                    case "names": content = AnyView(NativeNameSettingsView(model:model))
                    default: content = AnyView(NativeManualPresenceView(model:model))
                    }
                    let height:CGFloat = kind == "profile" ? 660 : kind == "names" ? 610 : 420
                    let host = NSHostingView(rootView:content.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme))
                    host.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:height),styleMask:.borderless,backing:.buffered,defer:false)
                    window.isReleasedWhenClosed = false;window.contentView = host
                    defer { window.contentView = nil;window.close() }
                    host.frame = NSRect(x:0,y:0,width:600,height:height)
                    for _ in 0..<10 { try await Task.sleep(nanoseconds:50_000_000);host.layoutSubtreeIfNeeded();host.displayIfNeeded() }
                    guard model.draft == "Unsent synthetic account-settings render draft.",
                          NotificationSettingsFixtureProtocol.renderReads.snapshot.writes == beforeWrites,
                          NotificationSettingsFixtureProtocol.nickname == "Synthetic Peter",
                          NotificationSettingsFixtureProtocol.description == "Local profile fixture",
                          NotificationSettingsFixtureProtocol.away == false,
                          let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw ChatAPIError.invalidResponse }
                    host.cacheDisplay(in:host.bounds,to:bitmap)
                    guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                    let name = style.rawValue+"-"+kind+"-settings.png"
                    try bytes.write(to:directory.appendingPathComponent(name),options:.withoutOverwriting)
                    metadata.append(["file":name,"width":600,"height":height,"synthetic_only":true,"preference_writes":0,"draft_retained":true])
                }
            }
            try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("render-checks.json"),options:.withoutOverwriting)
            return true
        } catch { fputs("Synthetic account settings rendering failed.\n",stderr);return false }
    }
    static func render(to directory:URL) async -> Bool {
        do {
            guard controller?.window?.isVisible != true else { throw ChatAPIError.invalidResponse }
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            for style in ChatAppearanceStyle.allCases {
                reset()
                let model = try await makeModel();defer { model.signOutLocally() }
                let baseline = NotificationSettingsFixtureProtocol.renderReads.snapshot
                let content = NativeNotificationSettingsView(model:model).environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let view = NSHostingView(rootView:content);view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                let hostWindow = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:650,height:680),styleMask:[],backing:.buffered,defer:false)
                hostWindow.isReleasedWhenClosed = false;hostWindow.contentView = view
                defer { hostWindow.contentView = nil;hostWindow.close() }
                view.frame = NSRect(x:0,y:0,width:650,height:680);view.layoutSubtreeIfNeeded()
                var loaded = false
                for _ in 0..<80 {
                    try await Task.sleep(nanoseconds:25_000_000)
                    view.layoutSubtreeIfNeeded();view.displayIfNeeded()
                    let reads = NotificationSettingsFixtureProtocol.renderReads.snapshot
                    if model.conversationLibraryVisible,!model.notificationPreferencesBusy,
                       reads.preferences > baseline.preferences,reads.clock > baseline.clock {
                        loaded = true;break
                    }
                }
                guard loaded,!model.notificationsEnabled,!model.notificationPreferencesNeedRefresh else { throw ChatAPIError.invalidResponse }
                // The actual onAppear task has completed both server reads.
                // Allow its final draft/state publication to finish layout.
                try await Task.sleep(nanoseconds:50_000_000);view.layoutSubtreeIfNeeded()
                let candidates = scrollViews(in:view)
                guard let selected = candidates.indices.max(by:{ scrollExtent(candidates[$0]) < scrollExtent(candidates[$1]) }),
                      let document = candidates[selected].documentView else { throw ChatAPIError.invalidResponse }
                let scroll = candidates[selected]
                let sidecar = directory.appendingPathComponent(style.rawValue+"-notification-scroll.json")
                var steps:[[String:Any]] = []
                var metadata:[String:Any] = ["synthetic_only":true,"theme":style.rawValue,"host_frame":rect(view.frame),
                    "selected_index":selected,"candidates":candidates.enumerated().map { index, candidate in
                        var value = scrollMetrics(candidate);value["index"] = index;return value
                    }]
                func record() throws {
                    metadata["steps"] = steps
                    try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:sidecar,options:.atomic)
                }
                try record()
                guard scrollExtent(scroll) > 1 else { throw ChatAPIError.invalidResponse }
                var topImage:Data?
                for bottom in [false,true] {
                    let before = scrollMetrics(scroll), extent = scrollExtent(scroll)
                    let y = document.isFlipped ? (bottom ? extent : 0) : (bottom ? 0 : extent)
                    document.scroll(NSPoint(x:0,y:y))
                    scroll.contentView.scroll(to:NSPoint(x:0,y:y));scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(nanoseconds:50_000_000);view.layoutSubtreeIfNeeded()
                    var attempts:[[String:Any]] = [["strategy":"document-and-clip-point","after":scrollMetrics(scroll)]]
                    if abs(scroll.contentView.bounds.origin.y-y) > 1 {
                        let edge = document.isFlipped ? (bottom ? document.bounds.maxY-1 : document.bounds.minY) : (bottom ? document.bounds.minY : document.bounds.maxY-1)
                        document.scrollToVisible(NSRect(x:document.bounds.minX,y:edge,width:1,height:1))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try await Task.sleep(nanoseconds:50_000_000);view.layoutSubtreeIfNeeded()
                        attempts.append(["strategy":"document-edge-visible","after":scrollMetrics(scroll)])
                    }
                    let offsetReached = abs(scroll.contentView.bounds.origin.y-y) <= 1
                    scroll.contentView.needsDisplay = true;document.needsDisplay = true;view.needsDisplay = true;view.displayIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                    try data.write(to:directory.appendingPathComponent(style.rawValue+"-notifications-"+(bottom ? "bottom" : "top")+".png"),options:.withoutOverwriting)
                    let changed = !bottom || data != topImage
                    steps.append(["viewport":bottom ? "bottom" : "top","target_y":y,"before":before,"attempts":attempts,
                                  "after":scrollMetrics(scroll),"offset_reached":offsetReached,"different_from_top":changed])
                    try record()
                    guard offsetReached,changed else { throw ChatAPIError.invalidResponse }
                    if !bottom { topImage = data }
                }
                let final = NotificationSettingsFixtureProtocol.renderReads.snapshot
                guard final.writes == baseline.writes,!model.notificationsEnabled,
                      NSDictionary(dictionary:NotificationSettingsFixtureProtocol.preferences).isEqual(to:NotificationSettingsFixtureProtocol.initial) else { throw ChatAPIError.invalidResponse }
                let loginItem = NotificationRenderLoginItem()
                let preferences = NativeDesktopPreferences(loginItem:loginItem)
                model.downloadPreferences.chooseFolder(URL(fileURLWithPath:"/Synthetic review downloads",isDirectory:true))
                let desktop = NSHostingView(rootView:NativeDesktopSettingsView(model:model,preferences:preferences)
                    .environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme))
                desktop.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                let desktopWindow = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:600,height:600),styleMask:[],backing:.buffered,defer:false)
                desktopWindow.isReleasedWhenClosed = false;desktopWindow.contentView = desktop
                defer { desktopWindow.contentView = nil;desktopWindow.close() }
                desktop.frame = NSRect(x:0,y:0,width:600,height:600);desktop.layoutSubtreeIfNeeded()
                let height = desktop.fittingSize.height
                guard height.isFinite,height > 0,height < 1600 else { throw ChatAPIError.invalidResponse }
                desktop.frame.size.height = height
                try await Task.sleep(nanoseconds:50_000_000);desktop.layoutSubtreeIfNeeded();desktop.displayIfNeeded()
                let beforeResetViewport = try await revealBottom(in:desktop)
                guard loginItem.writes == 0,!model.notificationsEnabled,
                      let bitmap = desktop.bitmapImageRepForCachingDisplay(in:desktop.bounds) else { throw ChatAPIError.invalidResponse }
                desktop.cacheDisplay(in:desktop.bounds,to:bitmap)
                guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try data.write(to:directory.appendingPathComponent(style.rawValue+"-desktop-downloads-before-reset.png"),options:.withoutOverwriting)
                // Do not publish a parent-model change: the summary must track
                // the nested download preference itself, just like the editor.
                model.downloadPreferences.reset()
                try await Task.sleep(nanoseconds:80_000_000);desktop.layoutSubtreeIfNeeded();desktop.displayIfNeeded()
                let afterResetViewport = try await revealBottom(in:desktop)
                guard model.downloadPreferences.lastFolder == nil,loginItem.writes == 0,
                      let updated = desktop.bitmapImageRepForCachingDisplay(in:desktop.bounds) else { throw ChatAPIError.invalidResponse }
                desktop.cacheDisplay(in:desktop.bounds,to:updated)
                guard let updatedData = updated.representation(using:.png,properties:[:]),updatedData != data else { throw ChatAPIError.invalidResponse }
                try updatedData.write(to:directory.appendingPathComponent(style.rawValue+"-desktop-notifications-entry.png"),options:.withoutOverwriting)
                try JSONSerialization.data(withJSONObject:["synthetic_only":true,"before_reset":beforeResetViewport,"after_reset":afterResetViewport,"images_differ":true],options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(style.rawValue+"-download-summary-scroll.json"),options:.withoutOverwriting)
                let downloads = NSHostingView(rootView:NativeDownloadSettingsView(preferences:model.downloadPreferences)
                    .environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme))
                downloads.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                let downloadsWindow = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:600,height:360),styleMask:[],backing:.buffered,defer:false)
                downloadsWindow.isReleasedWhenClosed = false;downloadsWindow.contentView = downloads
                defer { downloadsWindow.contentView = nil;downloadsWindow.close() }
                downloads.frame = NSRect(x:0,y:0,width:600,height:360)
                for custom in [false,true] {
                    if custom { model.downloadPreferences.chooseFolder(URL(fileURLWithPath:"/Synthetic review downloads/An intentionally long project folder/Reference documents and original image exports/Shared review attachments",isDirectory:true)) }
                    try await Task.sleep(nanoseconds:80_000_000);downloads.layoutSubtreeIfNeeded();downloads.displayIfNeeded()
                    guard let bitmap = downloads.bitmapImageRepForCachingDisplay(in:downloads.bounds) else { throw ChatAPIError.invalidResponse }
                    downloads.cacheDisplay(in:downloads.bounds,to:bitmap)
                    guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                    try data.write(to:directory.appendingPathComponent(style.rawValue+"-download-settings-"+(custom ? "custom" : "default")+".png"),options:.withoutOverwriting)
                }
                model.downloadPreferences.reset()
            }
            return true
        } catch { fputs("Offscreen synthetic notification settings rendering failed.\n",stderr);return false }
    }
    private static func scrollViews(in view:NSView)->[NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in:$0) }
    }
    private static func revealBottom(in view:NSView) async throws -> [String:Any] {
        let candidates = scrollViews(in:view)
        guard let scroll = candidates.max(by:{ scrollExtent($0) < scrollExtent($1) }),let document = scroll.documentView else { throw ChatAPIError.invalidResponse }
        let y:CGFloat = document.isFlipped ? scrollExtent(scroll) : 0
        document.scroll(NSPoint(x:0,y:y));scroll.contentView.scroll(to:NSPoint(x:0,y:y));scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(nanoseconds:50_000_000);view.layoutSubtreeIfNeeded()
        scroll.contentView.needsDisplay = true;document.needsDisplay = true;view.needsDisplay = true;view.displayIfNeeded()
        guard abs(scroll.contentView.bounds.origin.y-y) <= 1 else { throw ChatAPIError.invalidResponse }
        var metrics = scrollMetrics(scroll);metrics["host_has_window"] = view.window != nil;metrics["host_window_visible"] = view.window?.isVisible == true
        return metrics
    }
    private static func scrollExtent(_ scroll:NSScrollView)->CGFloat {
        guard let document = scroll.documentView else { return 0 }
        return max(0,max(document.bounds.height,document.frame.height)-scroll.contentView.bounds.height)
    }
    private static func rect(_ value:NSRect)->[String:Double] {
        ["x":Double(value.origin.x),"y":Double(value.origin.y),"width":Double(value.width),"height":Double(value.height)]
    }
    private static func scrollMetrics(_ scroll:NSScrollView)->[String:Any] {
        var value:[String:Any] = ["class":String(reflecting:type(of:scroll)),"frame":rect(scroll.frame),
            "clip_frame":rect(scroll.contentView.frame),"clip_bounds":rect(scroll.contentView.bounds),"extent":Double(scrollExtent(scroll))]
        if let document = scroll.documentView {
            value["document_class"] = String(reflecting:type(of:document));value["document_frame"] = rect(document.frame)
            value["document_bounds"] = rect(document.bounds);value["document_flipped"] = document.isFlipped
        }
        return value
    }
    static func present(presence:Bool = false,profile:Bool = false,photo:Bool = false,devices:Bool = false,regional:Bool = false,launcher:Bool = false) {
        guard NativeChatAppConfiguration.standalone,NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        Task {
            controller?.close();reset()
            guard let model = try? await makeModel() else { NSSound.beep();return }
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:680),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = launcher ? "Application launcher fixture — local responses only" : regional ? "Regional settings fixture — local responses only" : devices ? "Paired devices fixture — local responses only" : photo ? "Profile photo fixture — local responses only" : profile ? "Profile fixture — local responses only" : presence ? "Availability fixture — local responses only" : "Notification preferences fixture — local responses only";window.isReleasedWhenClosed = false
            if launcher {
                window.contentViewController = NSHostingController(rootView:NativeApplicationLauncherView(model:model));window.setContentSize(NSSize(width:700,height:430))
            } else if regional {
                window.contentViewController = NSHostingController(rootView:NativeRegionalSettingsView(model:model));window.setContentSize(NSSize(width:640,height:650))
            } else if devices {
                window.contentViewController = NSHostingController(rootView:NativePairedDevicesView(model:model));window.setContentSize(NSSize(width:600,height:390))
            } else if photo {
                window.contentViewController = NSHostingController(rootView:NativeProfilePhotoEditor(model:model));window.setContentSize(NSSize(width:550,height:560))
            } else if profile {
                window.contentViewController = NSHostingController(rootView:NativeProfileEditorView(model:model));window.setContentSize(NSSize(width:550,height:430))
            } else if presence {
                window.contentViewController = NSHostingController(rootView:NativeManualPresenceView(model:model));window.setContentSize(NSSize(width:550,height:280))
            } else { window.contentViewController = NSHostingController(rootView:NativeNotificationSettingsView(model:model)) }
            window.center()
            controller = NotificationSettingsFixtureWindow(window:window,model:model);controller?.showWindow(nil);window.makeKeyAndOrderFront(nil)
        }
    }
}
@MainActor private final class NotificationRenderLoginItem:NativeLoginItemService {
    let state = NativeLoginItemState.disabled
    private(set) var writes = 0
    func setEnabled(_ enabled:Bool) async throws { writes += 1;throw ChatAPIError.unsupportedAPI }
}
@MainActor private final class NotificationSettingsFixtureWindow:NSWindowController,NSWindowDelegate {
    let model:NativeChatPreviewModel
    init(window:NSWindow,model:NativeChatPreviewModel) { self.model = model;super.init(window:window);window.delegate = self }
    required init?(coder:NSCoder) { fatalError("Not supported") }
    func windowWillClose(_ notification:Notification) { model.signOutLocally() }
}
private final class NotificationSettingsFixtureProtocol:URLProtocol {
    final class RenderReads:@unchecked Sendable {
        private let lock = NSLock()
        private var preferences = 0,clock = 0,writes = 0
        var snapshot:(preferences:Int,clock:Int,writes:Int) { lock.lock();defer { lock.unlock() };return(preferences,clock,writes) }
        func readPreferences() { lock.lock();preferences += 1;lock.unlock() }
        func readClock() { lock.lock();clock += 1;lock.unlock() }
        func writePreferences() { lock.lock();writes += 1;lock.unlock() }
    }
    static let renderReads = RenderReads()
    static let initialLauncherApps:[[String:Any]] = [
        ["appname":"SYNO.Cal.Application","name":"Synthetic Calendar","description":"Local response only","type":"local","badge":2,"launch_url":"https://notification-settings-ui.invalid/?launchApp=SYNO.Cal.Application"],
        ["appname":"SYNO.SDS.Drive.Application","name":"Synthetic Drive","description":"Local response only","type":"local","badge":0,"launch_url":"https://notification-settings-ui.invalid/?launchApp=SYNO.SDS.Drive.Application"]]
    static var launcherApps = initialLauncherApps
    static let initialPersonal:[String:Any] = ["lang":"def","dateFormat":"d-m-Y","timeFormat":"h:i a","otherSetting":["keep":true]]
    static var personal = initialPersonal
    static var timezone = "def"
    static let initialDevices:[[String:Any]] = [
        ["id":101,"device_name":"Synthetic phone","identity":"synthetic-phone","package":"Chat","firmware_version":17.4,"app_version":100],
        ["id":102,"device_name":"Synthetic tablet","identity":"synthetic-tablet","package":"Chat","firmware_version":"18.1","app_version":"2.0"]]
    static var devices = initialDevices
    static let initial:[String:Any] = ["notification_showmessage":true,"notification_browser_active":true,"notification_mute":false,"snooze":0,"snooze_schedule_enable":false,"prefer_user_name_format":"nickname"]
    static var preferences = initial
    static var avatarVersion:Int64 = 0
    static var photoData = Data()
    static var away = false
    static var nickname = "Synthetic Peter",description = "Local profile fixture"
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "notification-settings-ui.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        if request.url!.lastPathComponent == "SYNO.API.Info" { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Personal.Application.Info","SYNO.Core.UserSettings","SYNO.Core.Desktop.Initdata","SYNO.Core.Region.NTP","SYNO.Personal.Notification.Device","SYNO.Chat.User.Avatar","SYNO.Chat.Admin.Setting","SYNO.Chat.User.Preference","SYNO.Chat.Misc","SYNO.Chat.User","SYNO.Chat.Channel"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        if request.url!.lastPathComponent == "SYNO.Chat.User.Avatar" {
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"image/png"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:Self.photoData);client?.urlProtocolDidFinishLoading(self);return
        }
        if request.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("multipart/form-data;") == true {
            let signature = Data([137,80,78,71,13,10,26,10])
            if let start = data.range(of:signature),let end = data.range(of:Data("\r\n--".utf8),options:[],in:start.lowerBound..<data.endIndex) { Self.photoData = data.subdata(in:start.lowerBound..<end.lowerBound);Self.avatarVersion += 1;finish(["success":true]);return }
            finish(["success":false,"error":["code":406]]);return
        }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),api = request.url!.lastPathComponent,method = fields["method"] ?? ""
        if api == "SYNO.Personal.Application.Info",method == "get" {finish(["success":true,"data":["total":Self.launcherApps.count,"applications":Self.launcherApps]]);return}
        if api == "SYNO.Personal.Application.Info",method == "setorder",let raw = fields["app_order"],let names = try? JSONDecoder().decode([String].self,from:Data(raw.utf8)) {Self.launcherApps = names.compactMap {name in Self.launcherApps.first(where:{$0["appname"] as? String == name})};finish(["success":true]);return}
        if api == "SYNO.Core.UserSettings",method == "get" {finish(["success":true,"data":["Personal":Self.personal]]);return}
        if api == "SYNO.Core.UserSettings",method == "apply",let raw = fields["data"],let inner = try? JSONDecoder().decode(String.self,from:Data(raw.utf8)),let value = try? JSONSerialization.jsonObject(with:Data(inner.utf8)) as? [String:Any],let personal = value["Personal"] as? [String:Any] {Self.personal = personal;finish(["success":true]);return}
        if api == "SYNO.Core.Desktop.Initdata" {finish(["success":true,"data":["Session":["date_format":"Y-m-d","time_format":"H:i"]]]);return}
        if api == "SYNO.Core.Region.NTP" {finish(["success":true,"data":["zonedata":[["value":"London","display":"(GMT+00:00) London","offset":0],["value":"Berlin","display":"(GMT+01:00) Berlin","offset":3600]]]]);return}
        if api == "SYNO.Chat.User",method == "set",let raw = fields["timezone"],let value = try? JSONDecoder().decode(String.self,from:Data(raw.utf8)) {Self.timezone = value;finish(["success":true]);return}
        if api == "SYNO.Personal.Notification.Device",method == "list" { finish(["success":true,"data":["count":Self.devices.count,"list":Self.devices]]);return }
        if api == "SYNO.Personal.Notification.Device",method == "unpair",fields["package"] == "\"Chat\"",let raw = fields["list"],let selected = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [[String:Any]],selected.count == 1,let id = selected[0]["id"] as? Int {
            Self.devices.removeAll { $0["id"] as? Int == id };finish(["success":true]);return
        }
        if api == "SYNO.Chat.User",method == "set",fields["remove_avatar"] == "true" { Self.avatarVersion = 0;Self.photoData = Data();finish(["success":true]);return }
        if api == "SYNO.Chat.Admin.Setting",method == "get" { finish(["success":true,"data":["readonly_profile":[]]]);return }
        if api == "SYNO.Chat.User",method == "set",fields["nickname"] != nil || fields["description"] != nil {
            if let encoded = fields["nickname"],let value = try? JSONDecoder().decode(String.self,from:Data(encoded.utf8)) { Self.nickname = value }
            if let encoded = fields["description"],let value = try? JSONDecoder().decode(String.self,from:Data(encoded.utf8)) { Self.description = value }
            finish(["success":true]);return
        }
        if api == "SYNO.Chat.User",method == "set",let encoded = fields["is_always_offline"],let value = try? JSONDecoder().decode(Bool.self,from:Data(encoded.utf8)) { Self.away = value;finish(["success":true]);return }
        if api == "SYNO.Chat.User",method == "list" { finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":Self.nickname,"avatar_version":Self.avatarVersion,"user_props":["description":Self.description,"timezone":Self.timezone,"timezoneUTC":"GMT","is_always_offline":Self.away]]]]]);return }
        if api == "SYNO.Chat.Channel",method == "list" { finish(["success":true,"data":["channels":[]]]);return }
        if api == "SYNO.Chat.Misc",method == "acl" { finish(["success":true,"data":["acls":[]]]);return }
        if api == "SYNO.Chat.Misc",method == "ntp" { Self.renderReads.readClock();finish(["success":true,"data":["time":(Date().timeIntervalSince1970+7200)*1000]]);return }
        if api == "SYNO.Chat.User.Preference",method == "get" { Self.renderReads.readPreferences();finish(["success":true,"data":["preferences":Self.preferences]]);return }
        if api == "SYNO.Chat.User.Preference",method == "set" {
            Self.renderReads.writePreferences()
            let allowed = Set(Self.initial.keys).union(["snooze_schedule_start","snooze_schedule_end"])
            for (key,value) in fields where allowed.contains(key) { if let object = try? JSONSerialization.jsonObject(with:Data(value.utf8),options:.fragmentsAllowed) { Self.preferences[key] = object } }
            finish(["success":true]);return
        }
        // In particular, do not return a socket runtime version or permit any
        // channel/message mutation, imported account or non-fixture destination.
        finish(["success":false,"error":["code":102]])
    }
    private func finish(_ value:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
#endif
