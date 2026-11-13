import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit owns the viewport's drag destination. Hosting the complete reader
/// keeps its scroll proxy and message preferences in one SwiftUI tree.
private struct NativeConversationDropHost<Content:View>:NSViewRepresentable {
    let content:Content
    let model:NativeChatPreviewModel
    func makeNSView(context:Context)->NativeConversationDropContainer {
        let view = NativeConversationDropContainer(content:AnyView(content.environment(\.self,context.environment)))
        configure(view);return view
    }
    func updateNSView(_ view:NativeConversationDropContainer,context:Context) {
        view.host.rootView = AnyView(content.environment(\.self,context.environment));configure(view)
    }
    private func configure(_ view:NativeConversationDropContainer) {
        view.host.registerForDraggedTypes(NativeConversationFileDropReader.attachmentTypes)
        view.canReceive = { model.canReceiveConversationFileDrop(inThread:true) }
        view.receive = { providers in
            let accepted = model.receiveConversationFileDrop(providers,inThread:true)
            #if DEBUG
            model.conversationFileDropDiagnostic = "Native thread accepted: " + String(accepted)
            #endif
            return accepted
        }
    }
}

/// The hosting child fills the viewport and can be the nearest registered drag
/// destination. Register and route both views; a parent-only destination can be
/// shadowed by SwiftUI's hosting view. Ordinary mouse and scroll hit testing is
/// deliberately unchanged.
@MainActor final class NativeConversationDropContainer:NSView {
    let host:NativeConversationDropHostingView
    var canReceive:(()->Bool)?
    var receive:(([NSItemProvider])->Bool)?
    init(content:AnyView) {
        host = NativeConversationDropHostingView(rootView:content)
        super.init(frame:.zero)
        host.dropContainer = self
        host.sizingOptions = [];host.autoresizingMask = [.width,.height];addSubview(host)
        wantsLayer = true;layer?.cornerRadius = 8
        registerForDraggedTypes(NativeConversationFileDropReader.attachmentTypes);host.registerForDraggedTypes(NativeConversationFileDropReader.attachmentTypes)
    }
    required init?(coder:NSCoder) {nil}
    override func layout() { super.layout();host.frame = bounds.insetBy(dx:2,dy:2) }
    private func eligible(_ sender:NSDraggingInfo)->Bool {
        canReceive?() == true && sender.draggingSourceOperationMask.contains(.copy) &&
            NativeConversationFileDropReader.hasAttachments(sender.draggingPasteboard)
    }
    private func highlight(_ active:Bool) { layer?.borderColor = NSColor.systemMint.cgColor;layer?.borderWidth = active ? 2 : 0 }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {
        let active = eligible(sender);highlight(active)
        #if DEBUG
        NativeConversationFileDropReader.trace("native thread entered eligible=\(active)")
        #endif
        return active ? .copy : []
    }
    override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation { let active = eligible(sender);highlight(active);return active ? .copy : [] }
    override func draggingExited(_ sender:NSDraggingInfo?) { highlight(false) }
    override func prepareForDragOperation(_ sender:NSDraggingInfo)->Bool { eligible(sender) }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        highlight(false);guard eligible(sender),
            let providers = NativeConversationFileDropReader.attachmentProviders(from:sender.draggingPasteboard) else { return false }
        return receive?(providers) == true
    }
    override func concludeDragOperation(_ sender:NSDraggingInfo?) { highlight(false) }
}

@MainActor final class NativeConversationDropHostingView:NSHostingView<AnyView> {
    weak var dropContainer:NativeConversationDropContainer?
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation { dropContainer?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation { dropContainer?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender:NSDraggingInfo?) { dropContainer?.draggingExited(sender) }
    override func prepareForDragOperation(_ sender:NSDraggingInfo)->Bool { dropContainer?.prepareForDragOperation(sender) == true }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool { dropContainer?.performDragOperation(sender) == true }
    override func concludeDragOperation(_ sender:NSDraggingInfo?) { dropContainer?.concludeDragOperation(sender) }
}

extension View {
    func nativeConversationScrollDrop(model:NativeChatPreviewModel)->some View {
        NativeConversationDropHost(content:self,model:model).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
