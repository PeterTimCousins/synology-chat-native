import AppKit
import PDFKit
import SwiftUI

enum NativeDocumentKind:Equatable {
    case text,pdf,audio,video,quickLook
    var limit:Int { switch self { case .text:return 2 * 1024 * 1024;case .pdf,.quickLook:return 32 * 1024 * 1024;case .audio,.video:return 128 * 1024 * 1024 } }
    var isMedia:Bool { self == .audio || self == .video }
    static func forFilename(_ name:String) -> Self? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if NativeOfficePreviewFormat.supportedExtensions.contains(ext) { return .quickLook }
        if ["mp4","m4v","mov","webm"].contains(ext) { return .video }
        if ["mp3","m4a","aac","wav","aif","aiff","flac","ogg","opus","caf"].contains(ext) { return .audio }
        if ["txt","md","csv","tsv","log","json","xml","yaml","yml","ini","conf","swift","js","css","html","py","sql"].contains(ext) { return .text }
        return nil
    }
}
enum NativeDocumentContent {
    case text(String),pdf(PDFDocument),media(NativeMediaPlayback),quickLook(NativeOfficePreview)
    @MainActor static func load(_ data:Data,kind:NativeDocumentKind,filename:String) async throws -> Self {
        if kind == .audio || kind == .video { return .media(try await NativeMediaPlayback.load(data,kind:kind,filename:filename)) }
        if kind == .quickLook { return .quickLook(try NativeOfficePreview.load(data,filename:filename)) }
        return try decode(data,kind:kind)
    }
    @MainActor func dispose() {
        if case .media(let media) = self { media.dispose() }
        if case .quickLook(let document) = self { document.dispose() }
    }
    static func decode(_ data:Data,kind:NativeDocumentKind) throws -> Self {
        guard data.count <= kind.limit else { throw ChatTransferError(message:"This document is too large to preview. Save the original to open it.") }
        guard kind == .text || kind == .pdf else { throw ChatAPIError.invalidResponse }
        if kind == .pdf {
            guard data.prefix(1024).range(of:Data("%PDF-".utf8)) != nil,let document = PDFDocument(data:data),document.isLocked || document.pageCount > 0 else {
                throw ChatTransferError(message:"This file could not be read as a PDF. Save the original to open it.")
            }
            return .pdf(document)
        }
        let encoding:String.Encoding
        if data.starts(with:[0xFF,0xFE]) { encoding = .utf16LittleEndian }
        else if data.starts(with:[0xFE,0xFF]) { encoding = .utf16BigEndian }
        else { encoding = .utf8 }
        guard var text = String(data:data,encoding:encoding),!text.contains("\0") else {
            throw ChatTransferError(message:"This file is binary or uses an unsupported text encoding. Save the original to open it.")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        return .text(text)
    }
}

struct NativeDocumentPreview:View {
    @ObservedObject var model:NativeChatPreviewModel
    var didJumpToSource:(()->Void)? = nil
    var sourceContextLabel:String = "Search result"
    @State private var wrap = true
    @State private var findRequest = 0
    @State private var pdfCommand = NativePDFCommand()
    @State private var page = 1
    @State private var password = ""
    @State private var unlockFailure:String?
    @State private var unlockRevision = UUID()
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:kind == .audio ? "waveform" : kind == .video ? "play.rectangle" : "doc.text").foregroundColor(NativeChatColors.green)
                VStack(alignment:.leading,spacing:3) {
                    Text(model.documentPreviewPost.map(model.attachmentName) ?? "Document").font(.system(size:14,weight:.semibold)).lineLimit(1).truncationMode(.middle)
                    if case .pdf(let pdf) = model.documentPreviewContent,!pdf.isLocked {
                        Text("Page \(page) of \(pdf.pageCount)").font(.caption).foregroundColor(NativeChatColors.muted)
                    } else { Text(kind?.isMedia == true ? "Media player" : "Document preview").font(.caption).foregroundColor(NativeChatColors.muted) }
                    if model.searchDocumentOwner != nil,let post = model.documentPreviewPost,let channel = model.channels.first(where:{ $0.id == post.channel_id }) {
                        Text(sourceContextLabel + " · " + model.title(channel)).font(.caption).foregroundColor(NativeChatColors.muted).lineLimit(1)
                    }
                }
                Spacer(minLength:8)
                if model.searchDocumentOwner != nil { Button("Show message") { if model.jumpFromSearchDocument() { didJumpToSource?() } } }
                if case .text = model.documentPreviewContent {
                    Toggle("Wrap lines",isOn:$wrap).toggleStyle(.checkbox).font(.callout)
                    Button { findRequest += 1 } label: { Image(systemName:"magnifyingglass") }.accessibilityLabel("Find in document").keyboardShortcut("f",modifiers:.command)
                }
                if case .pdf(let pdf) = model.documentPreviewContent,!pdf.isLocked {
                    Button { pdfCommand = .init(action:.previous) } label: { Image(systemName:"chevron.left") }.accessibilityLabel("Previous PDF page").disabled(page <= 1)
                    Button { pdfCommand = .init(action:.next) } label: { Image(systemName:"chevron.right") }.accessibilityLabel("Next PDF page").disabled(page >= pdf.pageCount)
                    Button { pdfCommand = .init(action:.zoomOut) } label: { Image(systemName:"minus.magnifyingglass") }.accessibilityLabel("Zoom out PDF")
                    Button { pdfCommand = .init(action:.zoomIn) } label: { Image(systemName:"plus.magnifyingglass") }.accessibilityLabel("Zoom in PDF")
                    Button("Fit") { pdfCommand = .init(action:.fit) }
                }
                Button { model.closeDocumentPreview() } label: { Image(systemName:"xmark") }.accessibilityLabel(kind?.isMedia == true ? "Close media player" : "Close document").keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(16)
            Divider().overlay(NativeChatColors.separator)
            ZStack {
                NativeChatColors.canvas
                if model.documentPreviewLoading { ProgressView(kind?.isMedia == true ? "Loading media…" : "Loading document…") }
                else if let failure = model.documentPreviewError {
                    VStack(spacing:14) {
                        Image(systemName:"doc.badge.exclamationmark").font(.system(size:30))
                        Text(failure).foregroundColor(NativeChatColors.muted).multilineTextAlignment(.center)
                        Button("Try again") { model.retryDocumentPreview() }.buttonStyle(NativeSendButtonStyle())
                    }.padding(30)
                } else if let content = model.documentPreviewContent {
                    switch content {
                    case .quickLook(let document): NativeOfficePreviewView(document:document).id(ObjectIdentifier(document))
                    case .media(let media):NativeMediaPlayerView(playback:media,retry:{ model.retryDocumentPreview() })
                    case .text(let text):
                        if model.documentPreviewPost?.file_props?.is_snippet == true { NativeCodeEditor(text:.constant(text),filename:model.documentPreviewPost.map(model.attachmentName) ?? "Untitled.txt",editable:false,wrap:wrap,findRequest:findRequest,label:"Document text") }
                        else { NativeTextDocumentView(text:text,wrap:wrap,findRequest:findRequest) }
                    case .pdf(let pdf):
                        if pdf.isLocked {
                            VStack(spacing:14) {
                                Image(systemName:"lock.doc").font(.system(size:30)).foregroundColor(NativeChatColors.green)
                                Text("This PDF needs a password.").font(.headline)
                                SecureField("PDF password",text:$password).textFieldStyle(.roundedBorder).frame(width:280).onSubmit { unlock(pdf) }
                                if let unlockFailure { Text(unlockFailure).foregroundColor(.orange).font(.callout) }
                                Button("Unlock PDF") { unlock(pdf) }.buttonStyle(NativeSendButtonStyle())
                            }.id(unlockRevision)
                        } else {
                            NativePDFDocumentView(document:pdf,command:pdfCommand,page:$page,openLink:{ url in
                                guard let post = model.documentPreviewPost,model.connected,model.canRead(post.channel_id),let destination = ChatMessageLinks.webURL(url.absoluteString) else { return }
                                NSWorkspace.shared.open(destination)
                            })
                        }
                    }
                }
            }
            Divider().overlay(NativeChatColors.separator)
            HStack(spacing:12) {
                if let post = model.documentPreviewPost {
                    Text(model.messageText(post)).font(.caption).foregroundColor(NativeChatColors.muted).lineLimit(2)
                    Spacer()
                    if model.downloading.contains(post.id) {
                        ProgressView().controlSize(.small)
                        Button("Cancel save") { model.cancelDownload(postID:post.id) }
                    } else {
                        Button("Save original…") { Task { await model.saveAttachment(post) } }
                        Button("Save & open…") { Task { await model.saveAttachment(post,openAfterSaving:{ NSWorkspace.shared.open($0) }) } }
                    }
                }
            }.buttonStyle(NativeToolbarButtonStyle()).padding(16)
        }.frame(minWidth:660,idealWidth:900,maxWidth:1100,minHeight:520,idealHeight:650,maxHeight:800)
            .foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .onDisappear { password = "" }
            .onChange(of:model.documentPreviewPost?.id) { _ in password = "";unlockFailure = nil;page = 1;findRequest = 0;pdfCommand = NativePDFCommand();unlockRevision = UUID() }
    }
    private var kind:NativeDocumentKind? { model.documentPreviewPost.flatMap { model.documentKind($0) } }
    private func unlock(_ pdf:PDFDocument) {
        if pdf.unlock(withPassword:password) { password = "";unlockFailure = nil;unlockRevision = UUID() }
        else { unlockFailure = "That password did not unlock this PDF." }
    }
}

struct NativeTextDocumentView:NSViewRepresentable {
    let text:String
    let wrap:Bool
    let findRequest:Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll = NSScrollView();scroll.drawsBackground = false;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.autohidesScrollers = true
        let view = NSTextView();view.isEditable = false;view.isSelectable = true;view.isRichText = false;view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize:13,weight:.regular);view.textColor = NSColor.labelColor;view.textContainerInset = NSSize(width:20,height:20)
        view.isVerticallyResizable = true;view.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.usesFindBar = true;view.string = text;view.setAccessibilityLabel("Document text")
        scroll.documentView = view;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        Self.updateLayout(of:scroll,wrap:wrap)
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            let action = NSMenuItem();action.tag = NSTextFinder.Action.showFindInterface.rawValue
            view.performTextFinderAction(action)
        }
    }
    static func updateLayout(of scroll:NSScrollView,wrap:Bool) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isHorizontallyResizable = !wrap;view.autoresizingMask = wrap ? [.width] : []
        scroll.hasHorizontalScroller = !wrap
        view.textContainer?.widthTracksTextView = wrap
        if wrap {
            // Re-enabling width tracking does not shrink an already expanded
            // document until the next resize. Restore the viewport immediately.
            let width = max(1,scroll.contentSize.width)
            view.setFrameSize(NSSize(width:width,height:view.frame.height))
            view.textContainer?.containerSize = NSSize(width:max(1,width-2*view.textContainerInset.width),height:CGFloat.greatestFiniteMagnitude)
            scroll.contentView.scroll(to:NSPoint(x:0,y:scroll.contentView.bounds.origin.y))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            view.textContainer?.containerSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        }
        if let layout = view.layoutManager,let container = view.textContainer {
            layout.ensureLayout(for:container)
            let used = layout.usedRect(for:container),inset = view.textContainerInset
            let width = wrap ? max(1,scroll.contentSize.width) : max(scroll.contentSize.width,used.maxX+2*inset.width)
            view.setFrameSize(NSSize(width:width,height:max(scroll.contentSize.height,used.maxY+2*inset.height)))
        }
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) { (scroll.documentView as? NSTextView)?.string = "" }
    final class Coordinator { var findRequest = 0 }
}

struct NativePDFCommand {
    enum Action { case none,previous,next,zoomIn,zoomOut,fit }
    let id = UUID()
    var action = Action.none
}
struct NativePDFDocumentView:NSViewRepresentable {
    let document:PDFDocument
    let command:NativePDFCommand
    @Binding var page:Int
    let openLink:(URL)->Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> PDFView {
        let view = PDFView();view.backgroundColor = NSColor(calibratedWhite:0.12,alpha:1);view.displayMode = .singlePage
        view.autoScales = true;view.delegate = context.coordinator;view.document = document
        context.coordinator.observer = NotificationCenter.default.addObserver(forName:.PDFViewPageChanged,object:view,queue:.main) { [weak coordinator = context.coordinator] _ in
            guard let coordinator,let current = view.currentPage else { return }
            coordinator.parent.page = view.document.map { $0.index(for:current)+1 } ?? 1
        }
        return view
    }
    func updateNSView(_ view:PDFView,context:Context) {
        context.coordinator.parent = self
        if view.document !== document { view.document = document;view.autoScales = true }
        guard context.coordinator.command != command.id else { return }
        context.coordinator.command = command.id
        switch command.action {
        case .none:break
        case .previous:view.goToPreviousPage(nil)
        case .next:view.goToNextPage(nil)
        case .zoomIn:view.zoomIn(nil)
        case .zoomOut:view.zoomOut(nil)
        case .fit:view.autoScales = true
        }
        if let current = view.currentPage {
            let number = document.index(for:current)+1
            if number != page { DispatchQueue.main.async { self.page = number } }
        }
    }
    static func dismantleNSView(_ view:PDFView,coordinator:Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) };coordinator.observer = nil
        view.document = nil;view.delegate = nil
    }
    final class Coordinator:NSObject,PDFViewDelegate {
        var parent:NativePDFDocumentView
        var observer:NSObjectProtocol?
        var command:UUID?
        init(_ parent:NativePDFDocumentView) { self.parent = parent }
        func pdfViewWillClick(onLink sender:PDFView,with url:URL) { parent.openLink(url) }
        func pdfViewOpenPDF(_ sender:PDFView,forRemoteGoToAction action:PDFActionRemoteGoTo) { }
    }
}
