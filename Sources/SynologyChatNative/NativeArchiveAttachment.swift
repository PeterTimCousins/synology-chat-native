import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeArchiveAttachmentTarget:Identifiable {
    let archive:ChatArchive
    let post:ChatPost
    var id:String { "\(archive.id):\(post.id)" }
}
struct NativeArchiveAttachmentView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let kind:ChatArchiveKind
    let name:String
    let archive:ChatArchive
    let context:[ChatPost]
    @State private var current:ChatPost
    @Environment(\.dismiss) private var dismiss
    @State private var content:NativeDocumentContent?
    @State private var image:NSImage?
    @State private var loading = false
    @State private var failure:String?
    @State private var saveFailure:String?
    @State private var saved:String?
    @State private var saving = false
    @State private var previewTask:Task<Void,Never>?
    @State private var saveTask:Task<Void,Never>?
    @State private var panel:NSSavePanel?
    @State private var request = UUID()
    @State private var session = -1
    @State private var zoom:CGFloat = 1
    @State private var wrap = true
    @State private var findRequest = 0
    @State private var pdfCommand = NativePDFCommand()
    @State private var page = 1
    @State private var password = ""
    @State private var unlockFailure = false
    @State private var pdfRevision = 0
    init(model:NativeChatPreviewModel,kind:ChatArchiveKind,name:String,archive:ChatArchive,post:ChatPost,context:[ChatPost]) {
        self.model = model;self.kind = kind;self.name = name;self.archive = archive;self.context = context;_current = State(initialValue:post)
    }
    private var filename: String { model.archiveFilename(current,archive:archive) }
    private func isImage(_ post: ChatPost) -> Bool {
        post.file_props?.is_image == true || (archive.props.channel.encrypted && UTType(filenameExtension:(model.archiveFilename(post,archive:archive) as NSString).pathExtension)?.conforms(to:.image) == true)
    }
    private var documentKind: NativeDocumentKind? {
        let kind: NativeDocumentKind? = current.file_props?.is_snippet == true ? .text : NativeDocumentKind.forFilename(filename)
        return archive.props.channel.encrypted && kind == .quickLook ? nil : kind
    }
    private var images:[ChatPost] { context.filter { model.canOpenArchiveAttachment($0,archive:archive) && isImage($0) && $0.channel_id == archive.props.channel.id && $0.id >= archive.post_id_start && $0.id <= archive.post_id_end } }
    private var position:Int? { images.firstIndex { $0.id == current.id } }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text(filename).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("Archived attachment").font(.caption).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                if image != nil {
                    Button { zoom = max(1,zoom / 1.5) } label:{ Image(systemName:"minus.magnifyingglass") }.accessibilityLabel("Zoom out archived image").disabled(zoom <= 1)
                    Button { zoom = min(4,zoom * 1.5) } label:{ Image(systemName:"plus.magnifyingglass") }.accessibilityLabel("Zoom in archived image").disabled(zoom >= 4)
                    Button("Fit") { zoom = 1 }
                }
                if case .text = content {
                    Toggle("Wrap lines",isOn:$wrap).toggleStyle(.checkbox)
                    Button { findRequest += 1 } label:{ Image(systemName:"magnifyingglass") }.accessibilityLabel("Find in archived document").keyboardShortcut("f",modifiers:.command)
                }
                if case .pdf(let pdf) = content,!pdf.isLocked {
                    Button { pdfCommand = .init(action:.previous) } label:{ Image(systemName:"chevron.left") }.accessibilityLabel("Previous archived PDF page").disabled(page <= 1)
                    Button { pdfCommand = .init(action:.next) } label:{ Image(systemName:"chevron.right") }.accessibilityLabel("Next archived PDF page").disabled(page >= pdf.pageCount)
                    Button { pdfCommand = .init(action:.zoomOut) } label:{ Image(systemName:"minus.magnifyingglass") }.accessibilityLabel("Zoom out archived PDF")
                    Button { pdfCommand = .init(action:.zoomIn) } label:{ Image(systemName:"plus.magnifyingglass") }.accessibilityLabel("Zoom in archived PDF")
                    Button("Fit") { pdfCommand = .init(action:.fit) }
                }
                Button { dismiss() } label:{ Image(systemName:"xmark") }.accessibilityLabel("Close archived attachment").keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(16)
            Divider()
            ZStack {
                NativeChatColors.canvas
                if loading { ProgressView("Loading archived attachment…") }
                else if let failure {
                    VStack(spacing:14) { Text(failure).multilineTextAlignment(.center);Button("Try again") { load() } }.padding(30)
                } else if let image {
                    GeometryReader { geometry in
                        let fit = min(1,min((geometry.size.width - 48) / max(1,image.size.width),(geometry.size.height - 48) / max(1,image.size.height)))
                        ScrollView([.horizontal,.vertical]) {
                            Image(nsImage:image).resizable().interpolation(.high).frame(width:image.size.width * fit * zoom,height:image.size.height * fit * zoom).frame(minWidth:geometry.size.width,minHeight:geometry.size.height).accessibilityLabel(filename)
                        }
                    }
                } else if let content { preview(content) }
                else { Text("Save this attachment to open it in its default app.").foregroundColor(NativeChatColors.muted) }
            }
            Divider()
            HStack(spacing:12) {
                if isImage(current),let position {
                    Button { move(-1) } label:{ Image(systemName:"chevron.left") }.accessibilityLabel("Previous archived image").disabled(position == 0 || saving).keyboardShortcut(.leftArrow,modifiers:[])
                    Button { move(1) } label:{ Image(systemName:"chevron.right") }.accessibilityLabel("Next archived image").disabled(position + 1 >= images.count || saving).keyboardShortcut(.rightArrow,modifiers:[])
                    Text("\(position + 1) of \(images.count) loaded images").font(.caption).foregroundColor(NativeChatColors.muted)
                }
                if let saved { Text(saved).font(.caption).foregroundColor(NativeChatColors.muted) }
                if let saveFailure { Text(saveFailure).font(.caption).foregroundColor(.orange) }
                Spacer()
                if saving { ProgressView().controlSize(.small);Button("Cancel save") { saveTask?.cancel();panel?.cancel(nil) } }
                else {
                    Button("Save original…") { save(open:false) }
                    Button("Save & open…") { save(open:true) }
                }
            }.buttonStyle(NativeToolbarButtonStyle()).padding(16)
        }.frame(width:940,height:650).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .onAppear { session = model.accountGeneration;load() }
            .onDisappear { retireContent() }
            .onChange(of:model.archiveContentEpoch) { _ in if archive.props.channel.encrypted { retireContent();dismiss() } }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
    }
    @ViewBuilder private func preview(_ value:NativeDocumentContent)->some View {
        switch value {
        case .quickLook(let document): NativeOfficePreviewView(document:document).id(ObjectIdentifier(document))
        case .text(let text):
            if current.file_props?.is_snippet == true { NativeCodeEditor(text:.constant(text),filename:filename,editable:false,wrap:wrap,findRequest:findRequest,label:"Archived document text") }
            else { NativeTextDocumentView(text:text,wrap:wrap,findRequest:findRequest) }
        case .media(let media):NativeMediaPlayerView(playback:media,retry:load)
        case .pdf(let pdf):
            if pdf.isLocked {
                VStack(spacing:14) {
                    Text("This PDF needs a password.").font(.headline)
                    SecureField("PDF password",text:$password).frame(width:280).textFieldStyle(.roundedBorder).onSubmit { unlock(pdf) }
                    if unlockFailure { Text("The password did not unlock this PDF.").foregroundColor(.orange) }
                    Button("Unlock PDF") { unlock(pdf) }
                }.id(pdfRevision)
            } else {
                NativePDFDocumentView(document:pdf,command:pdfCommand,page:$page,openLink:{ url in
                    guard model.connected,model.accountGeneration == session,model.canReadArchive(archive),let destination = ChatMessageLinks.webURL(url.absoluteString) else { return };NSWorkspace.shared.open(destination)
                })
            }
        }
    }
    private func retireContent() {
        request = UUID();previewTask?.cancel();saveTask?.cancel();panel?.cancel(nil)
        content?.dispose();content = nil;image = nil;password = "";saved = nil;failure = nil;saveFailure = nil;loading = false
    }
    private func unlock(_ pdf:PDFDocument) { unlockFailure = !pdf.unlock(withPassword:password);password = "";pdfRevision += 1 }
    private func move(_ offset:Int) { guard let position,images.indices.contains(position + offset),!saving else { return };current = images[position + offset];load() }
    private func load() {
        previewTask?.cancel();request = UUID();let id = request,post = current,epoch = model.archiveContentEpoch
        content?.dispose();content = nil;image = nil;failure = nil;zoom = 1;page = 1;password = "";unlockFailure = false;pdfCommand = .init()
        let imageFile = isImage(post),kindOfDocument = documentKind
        guard model.canOpenArchiveAttachment(post,archive:archive) else { loading = false;return }
        guard imageFile || kindOfDocument != nil else { loading = false;return }
        loading = true
        previewTask = Task { @MainActor in
            defer { if request == id { loading = false } }
            do {
                let bytes = try await model.archivedAttachmentPreview(kind:kind,name:name,archive:archive,post:post,maximumBytes:imageFile ? 32 * 1024 * 1024 : kindOfDocument!.limit,expectedAccount:session)
                try Task.checkCancellation();guard request == id,model.accountGeneration == session,model.archiveContentEpoch == epoch,model.canReadArchive(archive) else { return }
                if imageFile {
                    guard let decoded = NativeImagePreview.decode(bytes,maximumPixelSize:4096) else { throw ChatAPIError.invalidResponse };image = decoded
                } else if let kindOfDocument {
                    let decoded = try await NativeDocumentContent.load(bytes,kind:kindOfDocument,filename:model.archiveFilename(post,archive:archive))
                    guard !Task.isCancelled,request == id,model.accountGeneration == session,model.archiveContentEpoch == epoch,model.canReadArchive(archive) else { decoded.dispose();return };content = decoded
                }
            } catch is CancellationError { }
            catch { if request == id { failure = (error as? ChatTransferError)?.errorDescription ?? "Could not preview this archived attachment. Retry or save the original." } }
        }
    }
    private func save(open:Bool) {
        guard !saving,model.canOpenArchiveAttachment(current,archive:archive) else { return };saving = true;saved = nil;saveFailure = nil
        let post = current,expected = session,epoch = model.archiveContentEpoch
        saveTask = Task { @MainActor in
            defer { saving = false;panel = nil;saveTask = nil }
            let chooser = NSSavePanel();panel = chooser;chooser.title = open ? "Save and open archived attachment" : "Save archived attachment";chooser.nameFieldStringValue = model.archiveFilename(post,archive:archive);chooser.directoryURL = model.downloadPreferences.initialFolder
            let accepted = await withCheckedContinuation { continuation in chooser.begin { continuation.resume(returning:$0 == .OK) } }
            do {
                try Task.checkCancellation();guard accepted,let url = chooser.url,model.accountGeneration == expected,model.archiveContentEpoch == epoch,model.canReadArchive(archive) else { return }
                try await model.saveArchivedAttachment(kind:kind,name:name,archive:archive,post:post,to:url,expectedAccount:expected)
                try Task.checkCancellation();guard model.accountGeneration == expected,model.archiveContentEpoch == epoch,model.canReadArchive(archive) else { return }
                saved = "Saved " + url.lastPathComponent
                if open { await model.openSavedAttachment(at: url, postID: post.id, expectedAccount: expected) }
            } catch is CancellationError { }
            catch { saveFailure = "Could not save the archived attachment. Refresh the archive and try again." }
        }
    }
}
