#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeSearchPreviewChecks {
    nonisolated static let bundleID = "com.costwisegroup.synology-chat-native.search-preview-checks"
    nonisolated static let sidebarBundleID = "com.costwisegroup.synology-chat-native.sidebar-checks"
    private static var retained:Delegate?
    static func run() {
        let app = NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate = Delegate(sidebar:Bundle.main.bundleIdentifier == sidebarBundleID);retained = delegate;app.delegate = delegate;app.run()
    }
    static func renderPanel(to file:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let session = try await NativeSearchResultsUIFixture.makeInteractiveSession();defer { session.cleanup() }
            let host = NSHostingView(rootView:Checks(session:session));host.appearance = NSAppearance(named:.darkAqua)
            host.frame = NSRect(x:0,y:0,width:820,height:720);host.layoutSubtreeIfNeeded()
            for _ in 0..<6 { try await Task.sleep(nanoseconds:50_000_000);host.layoutSubtreeIfNeeded() }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw ChatAPIError.invalidResponse }
            host.cacheDisplay(in:host.bounds,to:bitmap);guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
            try data.write(to:file,options:.withoutOverwriting);return true
        } catch { fputs("Synthetic preview panel rendering failed.\n",stderr);return false }
    }
    private final class Delegate:NSObject,NSApplicationDelegate {
        let sidebar:Bool
        init(sidebar:Bool) { self.sidebar = sidebar;super.init() }
        private var session:NativeSearchPreviewSession?
        private var window:NSWindow?
        func applicationDidFinishLaunching(_ notification:Notification) {
            let root = NSMenu(),item = NSMenuItem(),menu = NSMenu()
            menu.addItem(withTitle:sidebar ? "Quit Chat Sidebar Checks" : "Quit Chat Preview Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            item.submenu = menu;root.addItem(item);NSApplication.shared.mainMenu = root
            Task { @MainActor in
                do {
                    let session = try await NativeSearchResultsUIFixture.makeInteractiveSession();self.session = session
                    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
                    window.isReleasedWhenClosed = false;window.title = sidebar ? "Chat Sidebar Checks — synthetic account only" : "Chat Preview Checks — synthetic files only"
                    if sidebar {
                        _ = try await session.model.loadSidebarSettings()
                        window.setContentSize(NSSize(width:1120,height:800))
                        window.contentView = NSHostingView(rootView:SidebarChecks(session:session))
                    } else { window.contentView = NSHostingView(rootView:Checks(session:session)) }
                    window.center();self.window = window
                    window.makeKeyAndOrderFront(nil);NSApplication.shared.activate(ignoringOtherApps:true)
                } catch { fputs("Synthetic preview checks could not start.\n",stderr);NSApplication.shared.terminate(nil) }
            }
        }
        func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
        func applicationWillTerminate(_ notification:Notification) { session?.cleanup();session = nil }
    }
    private struct SidebarChecks:View {
        let session:NativeSearchPreviewSession
        var body:some View {
            VStack(spacing:0) {
                HStack {
                    Text("Synthetic sidebar checks · no sign-in or real chat data")
                    Spacer()
                    Button("Add synthetic unread") { try? session.setSidebarUnreadForChecks(1) }
                    Button("Clear synthetic unread") { try? session.setSidebarUnreadForChecks(0) }
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }.padding(10)
                NativeChatPreviewView(model:session.model)
            }.background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).preferredColorScheme(.dark)
        }
    }
    private struct Checks:View {
        let session:NativeSearchPreviewSession
        @ObservedObject private var model:NativeChatPreviewModel
        @State private var owner = UUID()
        @State private var showSavedCollection = false
        @State private var showPinnedCollection = false
        @State private var showCalendarPreferences = false
        init(session:NativeSearchPreviewSession) { self.session = session;model = session.model }
        var body:some View {
            VStack(alignment:.leading,spacing:18) {
                Label("Native preview checks",systemImage:"doc.text.magnifyingglass").font(.title2.bold())
                Text("These files are generated for testing. No sign-in or real chat data is used.").font(.callout).foregroundColor(NativeChatColors.muted)
                HStack { Button("Saved messages") { showSavedCollection = true };Button("Pinned messages") { showPinnedCollection = true };Button("Calendar preferences") { showCalendarPreferences = true } }
                ForEach(session.documents) { post in
                    NativeSearchResultContent(post:post,model:model,openImage:{},openDocument:{ model.openSearchDocument(post,owner:owner,playMedia:model.documentKind(post)?.isMedia == true) })
                }
                Divider()
                Text("Selected conversation: " + (model.selectedChannel.map(model.title) ?? "None")).font(.callout)
                Text("Planning draft: " + (model.drafts[23] ?? "")).font(.caption).foregroundColor(NativeChatColors.muted)
                HStack { Button("Reset selected conversation") { model.selection = 23 };Spacer();Button("Quit") { NSApplication.shared.terminate(nil) } }
            }.padding(24).frame(minWidth:760,maxWidth:.infinity,minHeight:520,maxHeight:.infinity,alignment:.topLeading).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark)
                .sheet(isPresented:Binding(get:{ model.searchDocumentOwner == owner && model.documentPreviewIsPresented },set:{ if !$0,model.searchDocumentOwner == owner { model.closeDocumentPreview() } })) { NativeDocumentPreview(model:model) }
                .sheet(isPresented:$showSavedCollection) { NativeMessageCollection(model:model) }
                .sheet(isPresented:$showPinnedCollection) { NativeMessageCollection(model:model,channelID:24) }
                .sheet(isPresented:$showCalendarPreferences) { NativeCalendarPreferencesView(model:model) }
                .onDisappear { if model.searchDocumentOwner == owner { model.closeDocumentPreview() } }
        }
    }
}
#endif
