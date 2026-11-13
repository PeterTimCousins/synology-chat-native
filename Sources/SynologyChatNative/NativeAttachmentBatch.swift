import AppKit
import SwiftUI

struct NativeAttachmentItem: Identifiable {
    enum State: Equatable { case queued, sending, sent(Int64), unconfirmed(String), blocked(String) }
    let id = UUID()
    enum Source {case local(URL),nas(ChatNASFile)}
    let source:Source
    init(file:URL,caption:String) {source = .local(file);self.caption = caption}
    init(nasFile:ChatNASFile,caption:String) {source = .nas(nasFile);self.caption = caption}
    var localFile:URL? {if case .local(let file) = source {return file};return nil}
    var nasFile:ChatNASFile? {if case .nas(let file) = source {return file};return nil}
    var displayName:String {localFile?.lastPathComponent ?? nasFile?.name ?? "File"}
    var sourceID:String {localFile.map {"local:"+$0.standardizedFileURL.absoluteString} ?? "nas:"+(nasFile?.path ?? "")}
    var size:Int64? {
        if let file = nasFile { return file.additional.size }
        guard var file = localFile else { return nil }
        file.removeAllCachedResourceValues()
        return (try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize).map(Int64.init)
    }
    var caption: String
    var state = State.queued
}

/// One deliberate send per queued file. Failed/ambiguous deliveries are never silently retried.
@MainActor final class NativeAttachmentBatch: ObservableObject, Identifiable {
    let id = UUID()
    let channelID:Int64
    let channelTitle:String
    let rootID:Int64?
    let encrypted:Bool
    let keyEnvelope:String?
    let originalCaption:String
    private(set) var originalCaptionItemID:UUID?
    @Published private(set) var items:[NativeAttachmentItem] = []
    @Published private(set) var sending = false
    @Published private(set) var validationError:String?
    var queuedCount:Int { items.filter { $0.state == .queued }.count }
    var sentCount:Int { items.filter { if case .sent = $0.state { return true };return false }.count }
    var unconfirmedCount:Int { items.filter { if case .unconfirmed = $0.state { return true };return false }.count }
    var finished:Bool { !items.isEmpty && sentCount == items.count }
    var canSend:Bool { !sending && queuedCount > 0 && items.filter { $0.state == .queued }.allSatisfy { ChatMessageText.isAllowed($0.caption) } }
    init(files:[URL],caption:String,channelID:Int64,channelTitle:String,rootID:Int64?,encrypted:Bool,keyEnvelope:String?) {
        self.channelID = channelID;self.channelTitle = channelTitle;self.rootID = rootID
        self.encrypted = encrypted;self.keyEnvelope = keyEnvelope;self.originalCaption = caption
        append(files)
        if !items.isEmpty { items[0].caption = caption;originalCaptionItemID = items[0].id }
    }
    func refreshFileMetadata() { objectWillChange.send() }
    @discardableResult func append(_ files:[URL]) -> Bool {
        guard !sending else { return false }
        do {
            let additions = try ChatAttachmentSelection.localFiles(files,existing:items.compactMap(\.localFile),existingCount:items.count)
            items += additions.map { NativeAttachmentItem(file:$0,caption:"") }
            validationError = nil;return true
        } catch { validationError = (error as? LocalizedError)?.errorDescription ?? "Could not add these files. No files were added.";return false }
    }
    @discardableResult func appendNAS(_ files:[ChatNASFile]) -> Bool {
        guard !sending,!encrypted else {return false}
        do {
            try ChatAttachmentSelection.validateCount(inputCount:files.count,additionCount:0,existingCount:items.count)
            guard files.allSatisfy(\.selectable) else {throw ChatTransferError(message:"Every selected NAS item must be an available readable file. No files were added.")}
            var known = Set(items.compactMap { $0.nasFile?.path })
            let additions = files.filter {known.insert($0.path).inserted}
            try ChatAttachmentSelection.validateCount(inputCount:files.count,additionCount:additions.count,existingCount:items.count)
            items += additions.map {NativeAttachmentItem(nasFile:$0,caption:"")}
            if originalCaptionItemID == nil,let first = items.first {items[0].caption = originalCaption;originalCaptionItemID = first.id}
            validationError = nil;return true
        } catch {validationError = (error as? LocalizedError)?.errorDescription ?? "Could not add these NAS files. No files were added.";return false}
    }
    func caption(_ id:UUID,text:String) {
        guard !sending,let index = items.firstIndex(where:{ $0.id == id }),items[index].state == .queued else { return }
        items[index].caption = text
    }
    func remove(_ id:UUID) { guard !sending else { return };items.removeAll {item in guard item.id == id else {return false};if case .blocked = item.state {return true};return item.state == .queued} }
    func run(canContinue:() -> Bool,send:(NativeAttachmentItem) async throws -> ChatPost,received:(ChatPost,NativeAttachmentItem)->Void) async {
        guard canSend else { return }
        sending = true;defer { sending = false }
        for index in items.indices where items[index].state == .queued {
            guard !Task.isCancelled,canContinue() else { return }
            let item = items[index]
            items[index].state = .sending
            do {
                let post = try await send(item)
                // A confirmed response can arrive as cancellation is requested. Preserve
                // its receipt; the owner separately checks account before publication.
                items[index].state = .sent(post.id)
                received(post,item)
            } catch {
                if let preflight = error as? ChatAttachmentPreflightFailure {items[index].state = .blocked(preflight.message);return}
                if let preflight = error as? ChatNASPreflightFailure {items[index].state = .blocked(preflight.message);return}
                let detail = (error as? LocalizedError)?.errorDescription ?? "Delivery could not be confirmed."
                items[index].state = .unconfirmed(error is CancellationError
                    ? "Upload stopped. Check the conversation before attaching this file again."
                    : detail + " Check the conversation before attaching this file again.")
                return
            }
        }
    }
}

struct NativeAttachmentBatchView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @ObservedObject var batch:NativeAttachmentBatch
    @State private var savingScreenshots:Set<UUID> = []
    @State private var screenshotSaveStatus:[UUID:String] = [:]
    private var singleImage:Bool {
        batch.items.count == 1 && batch.items.first?.localFile.map(NativeAttachmentImageLoader.supports) == true
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"paperclip").font(.system(size:21)).foregroundColor(NativeChatColors.green)
                VStack(alignment:.leading,spacing:3) {
                    Text("Send files").font(.system(size:19,weight:.bold))
                    Text(batch.channelTitle + (batch.rootID == nil ? "" : " · Thread reply")).font(.callout).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button { model.dismissAttachmentBatch() } label: { Image(systemName:"xmark") }
                    .accessibilityLabel("Close attachment review").disabled(batch.sending).keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            if let message = batch.validationError {
                Label(message,systemImage:"exclamationmark.triangle")
                    .font(.callout).foregroundColor(.orange).padding(.horizontal,20).padding(.bottom,16)
            }
            if batch.unconfirmedCount > 0 {
                Label("Some deliveries need checking. Continue sends only files that have not been attempted.",systemImage:"exclamationmark.triangle")
                    .font(.callout).foregroundColor(.orange).padding(.horizontal,20).padding(.bottom,16)
            }
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    if batch.items.isEmpty {
                        VStack(spacing:12) {
                            Image(systemName:"tray").font(.system(size:32,weight:.light)).foregroundColor(NativeChatColors.muted)
                            Text("No files attached").font(.system(size:16,weight:.semibold))
                            Text("Choose Add files to attach something to this conversation.")
                                .font(.callout).foregroundColor(NativeChatColors.muted).multilineTextAlignment(.center)
                        }.frame(maxWidth:.infinity).padding(.vertical,70)
                    }
                    ForEach(batch.items) { item in
                        VStack(alignment:.leading,spacing:10) {
                            HStack(spacing:12) {
                                Image(systemName:item.localFile.map(NativeAttachmentImageLoader.supports) == true ? "photo" : "doc.fill").font(.system(size:22)).foregroundColor(NativeChatColors.green)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(item.displayName).font(.system(size:14,weight:.semibold)).lineLimit(1).truncationMode(.middle)
                                    if let size = item.size {
                                        Text(ByteCountFormatter.string(fromByteCount:Int64(size),countStyle:.file)).font(.caption).foregroundColor(NativeChatColors.muted)
                                    }
                                }
                                Spacer()
                                switch item.state {
                                case .queued,.blocked:
                                    Button { batch.remove(item.id) } label: { Image(systemName:"xmark") }
                                        .accessibilityLabel("Remove " + item.displayName).disabled(batch.sending)
                                case .sending: ProgressView().controlSize(.small)
                                case .sent: Label("Sent",systemImage:"checkmark.circle.fill").font(.caption).foregroundColor(NativeChatColors.green)
                                case .unconfirmed: Image(systemName:"exclamationmark.triangle").foregroundColor(.orange)
                                }
                            }
                            if let file = item.localFile,NativeAttachmentImageLoader.supports(file),
                               !(file.lastPathComponent == "Screenshot.png" && file.deletingLastPathComponent().lastPathComponent.hasPrefix("native-chat-paste-")) {
                                NativeAttachmentImagePreview(file:file,maximumHeight:singleImage ? 280 : 180,onRefresh:batch.refreshFileMetadata)
                            }
                            if let file = item.localFile,file.lastPathComponent == "Screenshot.png",file.deletingLastPathComponent().lastPathComponent.hasPrefix("native-chat-paste-") {
                                NativeScreenshotReviewImage(file:file)
                                HStack {
                                    Button("Save screenshot copy…") {
                                        savingScreenshots.insert(item.id);screenshotSaveStatus[item.id] = nil
                                        Task { @MainActor in
                                            defer {savingScreenshots.remove(item.id)}
                                            do {if try await model.saveScreenshotCopy(itemID:item.id) {screenshotSaveStatus[item.id] = "Copy saved"}}
                                            catch is CancellationError {} catch {screenshotSaveStatus[item.id] = "Could not save the screenshot copy. Choose another location."}
                                        }
                                    }.disabled(batch.sending || savingScreenshots.contains(item.id))
                                    if let status = screenshotSaveStatus[item.id] {Text(status).font(.caption).foregroundColor(NativeChatColors.muted)}
                                }
                            }
                            if let _ = item.nasFile {Text("From NAS").font(.caption).foregroundColor(NativeChatColors.muted)}
                            if case .blocked(let reason) = item.state {Text(reason).font(.caption).foregroundColor(.orange)}
                            if item.state == .queued {
                                TextField("Add a caption…",text:Binding(get:{ batch.items.first(where:{ $0.id == item.id })?.caption ?? "" },set:{ batch.caption(item.id,text:$0) }),axis:.vertical)
                                    .lineLimit(1...3).textFieldStyle(.plain).padding(10)
                                    .background(NativeChatColors.canvas).clipShape(RoundedRectangle(cornerRadius:8))
                                    .overlay(RoundedRectangle(cornerRadius:8).stroke(NativeChatColors.separator))
                                    .disabled(batch.sending)
                                    .accessibilityLabel("Caption for " + item.displayName)
                                NativeMessageLengthNotice(text:item.caption)
                            } else if !item.caption.isEmpty { Text(item.caption).font(.callout).foregroundColor(NativeChatColors.muted).lineLimit(3) }
                            if case .unconfirmed(let reason) = item.state { Text(reason).font(.caption).foregroundColor(.orange) }
                            if item.state == .sending,let progress = model.uploadProgress {
                                ProgressView(value:progress.fraction ?? 0)
                                Text(progress.label).font(.caption).foregroundColor(NativeChatColors.muted)
                            }
                        }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                            .overlay(RoundedRectangle(cornerRadius:10).stroke(NativeChatColors.separator))
                    }
                }.padding(20)
            }
            Divider().overlay(NativeChatColors.separator)
            HStack(spacing:12) {
                Text(batch.sentCount == 0 && batch.unconfirmedCount == 0 ? "\(batch.items.count) " + (batch.items.count == 1 ? "file attached" : "files attached") : "\(batch.sentCount) of \(batch.items.count) sent").font(.callout).foregroundColor(NativeChatColors.muted)
                Spacer()
                if batch.sending {
                    Button("Stop upload") { model.cancelUpload() }.buttonStyle(NativeToolbarButtonStyle())
                } else {
                    Button("Add files…") { Task { await model.chooseAttachment(inThread:batch.rootID != nil) } }
                        .buttonStyle(NativeToolbarButtonStyle()).disabled(!model.canInteract)
                    Button(batch.items.isEmpty ? "Send files" : batch.sentCount == 0 && batch.unconfirmedCount == 0 ? "Send \(batch.queuedCount) " + (batch.queuedCount == 1 ? "file" : "files") : "Continue · \(batch.queuedCount) " + (batch.queuedCount == 1 ? "file" : "files")) {
                        model.sendAttachmentBatch()
                    }.buttonStyle(NativeSendButtonStyle()).disabled(!batch.canSend || !model.canInteract).keyboardShortcut(.return,modifiers:.command)
                }
            }.padding(20)
        }.frame(width:660,height:singleImage ? 600 : 560).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text)
            .tint(NativeChatColors.green).nativeChatAppearance()
    }
}
