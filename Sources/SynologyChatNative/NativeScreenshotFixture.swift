#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeScreenshotFixture {
    private static var controller:ScreenshotFixtureController?
    static func present() {
        guard NativeChatAppConfiguration.standalone,NativeChatAppConfiguration.allowsOfficialSessionImport else {return}
        controller?.close()
        let model = NativeChatPreviewModel(restoreNotificationPreference:false)
        guard let channel = try? JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8)) else {return}
        model.channels = [channel];model.selection = 93;model.connected = true;model.liveStatus = .live;model.draft = "Synthetic screenshot — no desktop captured."
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Screenshot review fixture — no capture or delivery connection";window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:ScreenshotFixtureView(model:model));window.center();controller = ScreenshotFixtureController(window:window,model:model);controller?.showWindow(nil);window.makeKeyAndOrderFront(nil)
    }
}
@MainActor private final class ScreenshotFixtureController:NSWindowController,NSWindowDelegate {
    let model:NativeChatPreviewModel
    init(window:NSWindow,model:NativeChatPreviewModel) {self.model = model;super.init(window:window);window.delegate = self}
    required init?(coder:NSCoder) {nil}
    func windowWillClose(_ notification:Notification) {model.signOutLocally()}
}
private struct ScreenshotFixtureView:View {
    @ObservedObject var model:NativeChatPreviewModel
    var body:some View {
        Group {
            if let batch = model.attachmentBatch {NativeAttachmentBatchView(model:model,batch:batch).onAppear {model.liveStatus = .offline}}
            else {
                VStack(alignment:.leading,spacing:20) {
                    Text("Screenshot capture review").font(.title2.bold())
                    Text("macOS Screen Recording access: "+(NativeScreenshotCapture.hasAccess ? "granted" : "not granted"))
                    Text("This fixture uses fixed synthetic pixels. It never captures your screen, reads the clipboard or sends a message.").foregroundColor(.secondary)
                    NativeUploadStatusView(model:model)
                    HStack {
                        Button("Review synthetic screenshot") {model.liveStatus = .live;model.captureScreenshot(capture:{NativeSyntheticClipboardImage.data})}.disabled(model.preparingComposerAttachment)
                        Button("Hold synthetic selection") {model.liveStatus = .live;model.captureScreenshot(capture:{try await Task.sleep(nanoseconds:30_000_000_000);return nil})}.disabled(model.preparingComposerAttachment)
                    }
                    if let error = model.error {Text(error).foregroundColor(.orange)}
                }.padding(30).frame(width:720,height:500).nativeChatAppearance()
            }
        }
    }
}
#endif
