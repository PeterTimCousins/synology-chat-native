#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeEncryptedConversationChecks {
    nonisolated static let bundleID = "com.costwisegroup.synology-chat-native.encrypted-conversation-checks"
    private static var retained:Delegate?
    static func run() {
        let app = NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate = Delegate();retained = delegate;app.delegate = delegate;app.run()
    }
    private final class Delegate:NSObject,NSApplicationDelegate {
        private var window:NSWindow?
        private var model:NativeChatPreviewModel?
        private var directory:URL?
        func applicationDidFinishLaunching(_ notification:Notification) {
            let menu = NSMenu(),item = NSMenuItem(),appMenu = NSMenu()
            appMenu.addItem(withTitle:"Quit Chat Encryption Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            item.submenu = appMenu;menu.addItem(item);NSApplication.shared.mainMenu = menu
            Task { @MainActor in
                do {
                    let directory = URL(fileURLWithPath:"/private/tmp/native-channel-invitation-fixture.window-"+UUID().uuidString,isDirectory:true)
                    self.directory = directory
                    let (model,backend) = try await NativeChannelInvitationUIFixture.makeModel(directory:directory,configure:{ $0.allowAnonymous = true })
                    self.model = model;model.draft = "Unsent synthetic encryption check — keep this draft."
                    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:850),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
                    window.title = "Chat Encryption Checks — synthetic accounts only";window.isReleasedWhenClosed = false
                    window.contentView = NSHostingView(rootView:Controls(model:model,backend:backend));window.center();self.window = window
                    window.makeKeyAndOrderFront(nil);NSApplication.shared.activate(ignoringOtherApps:true)
                } catch { fputs("Synthetic encryption checker could not start.\n",stderr);NSApplication.shared.terminate(nil) }
            }
        }
        func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
        func applicationWillTerminate(_ notification:Notification) {
            model?.signOutLocally();model = nil
            if let directory { try? NativeChannelInvitationUIFixture.validateDirectory(directory);try? FileManager.default.removeItem(at:directory) }
        }
    }
    private struct Controls:View {
        @ObservedObject var model:NativeChatPreviewModel
        let backend:InvitationIntegrationBackend
        @State private var newConversation = false
        @State private var pending = false
        @State private var notice = ""
        var body:some View {
            VStack(spacing:0) {
                HStack {
                    Text("Synthetic accounts only · no sign-in or real chat data").font(.caption)
                    Spacer()
                    Button("New conversation") { newConversation = true }
                    Button("Pending actions") { pending = true }
                    Button("Lose next reply") { backend.loseAnonymousReply = true;notice = "Next synthetic creation reply will be lost." }
                    Button(model.encryptionUnlocked ? "Lock test keys" : "Unlock test keys") {
                        if model.encryptionUnlocked { model.lockEncryption() }
                        else { do { try model.unlockEncryption(password:backend.fixture.password);model.liveStatus = .live;notice = "Synthetic keys unlocked." } catch { notice = "Synthetic unlock failed." } }
                    }
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }.padding(10)
                Text("Initiation requests: \(backend.anonymousStarts.count) · Pending starts: \(model.pendingEncryptedConversationStarts.count) · Selected: \(model.selection.map(String.init) ?? "none") · \(notice)").font(.caption).padding(.bottom,8)
                NativeChatPreviewView(model:model)
            }.background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).preferredColorScheme(.dark)
                .sheet(isPresented:$newConversation) { NativeNewConversationView(model:model) }
                .sheet(isPresented:$pending) { NativePendingChannelActionsView(model:model) }
        }
    }
}
#endif
