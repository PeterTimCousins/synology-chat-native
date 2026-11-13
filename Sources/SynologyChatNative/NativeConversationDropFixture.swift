#if DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum NativeConversationDropFixture {
    nonisolated static let bundleID = "com.costwisegroup.synology-chat-native.drop-checks"
    private static var controller:ConversationDropFixtureController?
    private static var calibrationWindow:NSWindow?
    private static var delegate:DropChecksDelegate?
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let handler = DropChecksDelegate();delegate = handler;app.delegate = handler;app.run()
    }
    private final class DropChecksDelegate:NSObject,NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification:Notification) {
            let menu = NSMenu(),item = NSMenuItem(),submenu = NSMenu()
            submenu.addItem(withTitle:"Quit Attachment Drop Checks",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            item.submenu = submenu;menu.addItem(item);NSApplication.shared.mainMenu = menu
            NativeConversationDropFixture.present()
            NSApplication.shared.activate(ignoringOtherApps:true)
        }
        func applicationWillTerminate(_ notification:Notification) { calibrationWindow?.close();calibrationWindow = nil;controller?.close();controller = nil }
    }
    static func presentCalibration() {
        guard let file = controller?.folder.appendingPathComponent("Synthetic drop.png") else { return }
        calibrationWindow?.close()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Native drag calibration — no upload";window.isReleasedWhenClosed = false
        let content = NSView(frame:NSRect(x:0,y:0,width:650,height:300))
        let source = ConversationDropNativeSource.Source(file:file);source.frame = NSRect(x:20,y:100,width:180,height:70)
        let target = ConversationDropCalibrationTarget(frame:NSRect(x:280,y:60,width:330,height:160))
        let close = NSButton(title:"Close calibration",target:window,action:#selector(NSWindow.performClose(_:)))
        close.frame = NSRect(x:20,y:20,width:180,height:32)
        content.addSubview(source);content.addSubview(target);content.addSubview(close);window.contentView = content
        window.center();calibrationWindow = window;window.makeKeyAndOrderFront(nil)
    }
    static func tracePoint(_ label:String,window:NSWindow?,screenPoint:NSPoint) {
        guard let window,let content = window.contentView else { return }
        let point = window.convertPoint(fromScreen:screenPoint),local = content.convert(point,from:nil)
        NativeConversationFileDropReader.trace("\(label) windowPoint=\(point) contentPoint=\(local) key=\(window.isKeyWindow)")
        func walk(_ view:NSView,_ depth:Int) {
            guard depth < 20,view.bounds.contains(view.convert(point,from:nil)) else { return }
            let kind = String(String(reflecting:type(of:view)).prefix(100))
            if view.registeredDraggedTypes.contains(.fileURL) || kind.contains("Source") {
                NativeConversationFileDropReader.trace("point inside \(kind) frame=\(view.convert(view.bounds,to:nil)) fileType=\(view.registeredDraggedTypes.contains(.fileURL))")
            }
            for child in view.subviews { walk(child,depth+1) }
        }
        walk(content,0)
    }
    static func inspectHitTesting() {
        guard let window = controller?.window,let content = window.contentView else { return }
        let titleHeight = window.frame.height-content.frame.height
        NativeConversationFileDropReader.trace("window=\(window.title) content=\(content.bounds) flipped=\(content.isFlipped) titleHeight=\(titleHeight)")
        func walk(_ view:NSView,_ depth:Int) {
            guard depth < 16 else { return }
            let kind = String(String(reflecting:type(of:view)).prefix(100))
            if kind.contains("Container") || kind.contains("Observer") || kind.contains("ComposerTextView") || kind.contains("NSScrollView") {
                NativeConversationFileDropReader.trace("tree \(kind) frame=\(view.convert(view.bounds,to:nil)) hidden=\(view.isHidden) attached=\(view.window != nil) fileType=\(view.registeredDraggedTypes.contains(.fileURL))")
            }
            for child in view.subviews { walk(child,depth+1) }
        }
        walk(content,0)
        for (label,x,topY) in [("source",92.0,174.0),("destination",511.0,369.0),("editor",510.0,650.0)] {
            let y = topY-titleHeight
            let local = NSPoint(x:x,y:content.isFlipped ? y : content.bounds.height-y)
            let point = content.convert(local,to:content.superview)
            var node = content.hitTest(point)
            NativeConversationFileDropReader.trace("hit "+label)
            for _ in 0..<8 {
                guard let current = node else { break }
                let kind = String(String(reflecting:type(of:current)).prefix(100)),frame = current.convert(current.bounds,to:nil)
                NativeConversationFileDropReader.trace("view=\(kind) frame=\(frame) fileType=\(current.registeredDraggedTypes.contains(.fileURL))")
                node = current.superview
            }
        }
    }
    static func present(inThread:Bool = false) {
        guard Bundle.main.bundleIdentifier == bundleID || (NativeChatAppConfiguration.standalone && NativeChatAppConfiguration.allowsOfficialSessionImport) else { return }
        calibrationWindow?.close();calibrationWindow = nil;controller?.close()
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-conversation-drop-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let image = folder.appendingPathComponent("Synthetic drop.png"),text = folder.appendingPathComponent("Synthetic drop.txt")
            try NativeSyntheticClipboardImage.data.write(to:image);try Data("Synthetic file drop fixture.\n".utf8).write(to:text)
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ _ in throw ChatAPIError.unsupportedAPI })
            model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Local drop fixture","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
            model.selection = 93;model.connected = true;model.liveStatus = .live;model.draft = "Synthetic drop caption — retained."
            let messages: [[String: Any]] = [
                ["post_id": 1, "channel_id": 93, "creator_id": 10, "message": "Synthetic conversation. Drop files over this message list to review them. No delivery connection is configured.", "type": "normal", "create_at": 1792522800000],
                ["post_id": 2, "channel_id": 93, "creator_id": 10, "message": "Messages from the same person stay together, with each message retaining its own actions.", "type": "normal", "create_at": 1792522830000],
                ["post_id": 3, "channel_id": 93, "creator_id": 10, "message": ">>>* A list inside a multiline quote\n* Formatting remains structured\n```\nlet example = 1\n```", "type": "normal", "create_at": 1792522860000]
            ]
            model.posts = try JSONDecoder().decode([ChatPost].self, from: JSONSerialization.data(withJSONObject: messages))
            if inThread { model.threadRoot = model.posts.first;model.replyDraft = "Synthetic thread drop caption." }
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1240,height:800),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title = (inThread ? "Thread" : "Conversation") + " drop fixture — no delivery connection";window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView:ConversationDropFixtureView(model:model,files:[image,text].map(ConversationDropFixtureSource.init),missing:folder.appendingPathComponent("Missing synthetic.txt"),inThread:inThread))
            window.center();controller = ConversationDropFixtureController(window:window,model:model,folder:folder);controller?.showWindow(nil);window.makeKeyAndOrderFront(nil)
        } catch { }
    }
}
@MainActor private final class ConversationDropFixtureController:NSWindowController,NSWindowDelegate {
    let model:NativeChatPreviewModel
    let folder:URL
    init(window:NSWindow,model:NativeChatPreviewModel,folder:URL) { self.model = model;self.folder = folder;super.init(window:window);window.delegate = self }
    required init?(coder:NSCoder) {nil}
    func windowWillClose(_ notification:Notification) { model.signOutLocally();try? FileManager.default.removeItem(at:folder) }
}
private struct ConversationDropFixtureSource:Identifiable {
    let file:URL
    let provider:NSItemProvider
    var id:URL {file}
    init(_ file:URL) {
        self.file = file
        let data = Data(file.absoluteString.utf8),provider = NSItemProvider()
        provider.suggestedName = file.lastPathComponent
        provider.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all) { callback in callback(data,nil);return nil }
        self.provider = provider
    }
}
/// A conventional AppKit file drag source, independent of SwiftUI gesture recognition.
/// Its only payload is a file created by this local, disconnected fixture.
private struct ConversationDropNativeSource: NSViewRepresentable {
    let file: URL
    func makeNSView(context: Context) -> Source { Source(file: file) }
    func updateNSView(_ view: Source, context: Context) { view.file = file; view.needsDisplay = true }
    final class Source: NSView, NSDraggingSource {
        var file: URL
        init(file: URL) {
            self.file = file; super.init(frame: .zero)
            setAccessibilityElement(true); setAccessibilityRole(.button)
            setAccessibilityLabel("Drag " + file.lastPathComponent)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private var dragMoves = 0
        override func mouseDown(with event:NSEvent) { }
        // Source invocation and an actual OS drag are separate lifecycle events.
        override func mouseDragged(with event:NSEvent) {
            dragMoves = 0
            NativeConversationFileDropReader.trace("fixture source mouse dragged windowPoint=\(event.locationInWindow)")
            let item = NSDraggingItem(pasteboardWriter: file as NSURL)
            item.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
            _ = beginDraggingSession(with: [item], event: event, source: self)
            NativeConversationFileDropReader.trace("fixture beginDraggingSession returned")
            DispatchQueue.main.async { NativeConversationFileDropReader.trace("fixture queued main callback") }
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func draggingSession(_ session:NSDraggingSession,willBeginAt screenPoint:NSPoint) {
            NativeConversationFileDropReader.trace("fixture session will begin")
            NativeConversationDropFixture.tracePoint("session began",window:window,screenPoint:screenPoint)
        }
        func draggingSession(_ session:NSDraggingSession,movedTo screenPoint:NSPoint) {
            dragMoves += 1
            if dragMoves <= 3 { NativeConversationDropFixture.tracePoint("session movement \(dragMoves)",window:window,screenPoint:screenPoint) }
        }
        func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) {
            NativeConversationFileDropReader.trace("fixture native drag ended operation=\(operation.rawValue) moves=\(dragMoves)")
            NativeConversationDropFixture.tracePoint("session ended",window:window,screenPoint:screenPoint)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            (file.lastPathComponent as NSString).draw(in: bounds.insetBy(dx: 12, dy: 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor
            ])
        }
    }
}
/// Positive control outside any SwiftUI hosting tree. It consumes no file data
/// and only counts whether AppKit actually delivered the native drop lifecycle.
@MainActor private final class ConversationDropCalibrationTarget:NSView {
    private var accepted = 0
    override init(frame:NSRect) {
        super.init(frame:frame);registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true);setAccessibilityRole(.group);updateLabel()
    }
    required init?(coder:NSCoder) { nil }
    private func updateLabel() { setAccessibilityLabel("Native calibration accepted drops: \(accepted)");needsDisplay = true }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {
        NativeConversationFileDropReader.trace("calibration entered")
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }
    override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation { sender.draggingSourceOperationMask.contains(.copy) ? .copy : [] }
    override func prepareForDragOperation(_ sender:NSDraggingInfo)->Bool { sender.draggingSourceOperationMask.contains(.copy) }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return false }
        accepted += 1;updateLabel();NativeConversationFileDropReader.trace("calibration performed count=\(accepted)");return true
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.controlBackgroundColor.setFill();NSBezierPath(roundedRect:bounds,xRadius:12,yRadius:12).fill()
        ("Drop synthetic file here\nAccepted drops: \(accepted)" as NSString).draw(in:bounds.insetBy(dx:20,dy:30),withAttributes:[.font:NSFont.systemFont(ofSize:16,weight:.medium),.foregroundColor:NSColor.labelColor])
    }
}
private struct ConversationDropFixtureView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let files:[ConversationDropFixtureSource]
    let missing:URL
    let inThread:Bool
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:24) {
                Text("Local drag sources").font(.headline)
                Text("Drag these fixed synthetic files onto the message list. Nothing is uploaded.").font(.caption).foregroundColor(.secondary)
                ForEach(files) { source in
                    ConversationDropNativeSource(file: source.file).frame(height: 56)
                        .accessibilityLabel("Drag " + source.file.lastPathComponent)
                }
                Text("Missing synthetic file").padding(12).background(Color.secondary.opacity(0.15)).cornerRadius(8).contentShape(Rectangle())
                    .onDrag {
                        let provider = NSItemProvider()
                        provider.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all) { callback in callback(Data(missing.absoluteString.utf8),nil);return nil }
                        return provider
                    }
                Text("Slow synthetic file").padding(12).background(Color.secondary.opacity(0.15)).cornerRadius(8).contentShape(Rectangle())
                    .onDrag {
                        let provider = NSItemProvider(),data = Data(files[0].file.absoluteString.utf8)
                        provider.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all) { callback in
                            DispatchQueue.global().asyncAfter(deadline:.now()+10) { callback(data,nil) }
                            return Progress(totalUnitCount:1)
                        }
                        return provider
                    }
                Button("Open separate thread fixture") { NativeConversationDropFixture.present(inThread:true) }
                Button("Inspect native hit testing") { NativeConversationDropFixture.inspectHitTesting() }
                Button("Open native calibration") { NativeConversationDropFixture.presentCalibration() }
                if Bundle.main.bundleIdentifier == NativeConversationDropFixture.bundleID {
                    Button("Quit drop checks") { NSApplication.shared.terminate(nil) }
                }
                Text((model.canReceiveConversationFileDrop(inThread:inThread) ? "Target ready · " : "Target unavailable · ") + model.conversationFileDropDiagnostic).font(.caption2).foregroundColor(.secondary)
                Spacer()
            }.padding(16).frame(width:180)
            Divider()
            if inThread { NativeThreadView(model:model) }
            else { NativeChatPreviewView(model:model) }
        }.frame(width:1240,height:800,alignment:.topLeading).nativeChatAppearance()
    }
}
#endif
