import SwiftUI

/// A local presentation of an existing post. The model retains all transfer,
/// preview, permission and failure handling; the card never opens a remote URL.
struct NativeFileAttachmentCard: View {
    let post: ChatPost
    @ObservedObject var model: NativeChatPreviewModel
    @State private var audioOwnerID = UUID()
    init(post: ChatPost, model: NativeChatPreviewModel, audioOwnerID: UUID = UUID()) {
        self.post = post; self.model = model
        _audioOwnerID = State(initialValue: audioOwnerID)
    }

    private var filename: String { model.attachmentName(post) }
    private var presentation: NativeFileAttachmentPresentation {
        .init(filename:filename,isImage:post.file_props?.is_image == true,size:post.file_props?.size)
    }
    private var saving: Bool { model.downloading.contains(post.id) }
    private var activeRecord: ChatDownloadRecord? {
        model.downloadHistory.first { $0.postID == post.id && $0.state.active }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:11) {
                Image(systemName:presentation.symbol)
                    .font(.system(size:20,weight:.medium)).foregroundColor(NativeChatColors.green)
                    .frame(width:40,height:44).background(NativeChatColors.elevated)
                    .clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:4) {
                    Text(filename).font(.system(size:13,weight:.semibold))
                        .lineLimit(1).truncationMode(.middle).help(filename)
                        .accessibilityLabel(filename)
                    Text(presentation.metadata).font(.caption).foregroundColor(NativeChatColors.muted)
                        .lineLimit(1).truncationMode(.tail)
                }.frame(minWidth:0,maxWidth:.infinity,alignment:.leading)
                if saving {
                    Button { model.cancelDownload(postID:post.id) } label: { Image(systemName:"xmark") }
                        .buttonStyle(NativeToolbarButtonStyle())
                        .accessibilityLabel("Cancel download of " + filename).help("Cancel download")
                } else {
                    Button { Task { await model.saveAttachment(post) } } label: { Image(systemName:"arrow.down.to.line") }
                        .buttonStyle(NativeToolbarButtonStyle())
                        .accessibilityLabel("Save " + filename).help("Save attachment…")
                        .disabled(!model.canRead(post.channel_id))
                        .background {
#if DEBUG
                            NativeMessageActionMarker(postID:post.id,kind:"file-save")
#endif
                        }
                }
            }
            if saving {
                if let record = activeRecord { NativeFileAttachmentTransferStatus(record:record) }
                else { Text("Preparing save…").font(.caption).foregroundColor(NativeChatColors.muted) }
            }
            if model.canPreviewDocument(post) {
                if model.ownsInlineAudio(postID: post.id, ownerID: audioOwnerID) {
                    inlineAudio
                } else {
                Button {
                    if model.documentKind(post) == .audio { model.openInlineAudio(post, ownerID: audioOwnerID) }
                    else { model.openDocumentPreview(post,playMedia:true) }
                } label: {
                    Label(model.documentKind(post)?.isMedia == true ? "Play" : "Preview",
                          systemImage:model.documentKind(post)?.isMedia == true ? "play.fill" : "eye")
                        .font(.system(size:12,weight:.medium))
                }.buttonStyle(.plain).foregroundColor(NativeChatColors.green)
                    .accessibilityLabel((model.documentKind(post)?.isMedia == true ? "Play " : "Preview ") + filename)
                    .background {
#if DEBUG
                        NativeMessageActionMarker(postID:post.id,kind:"file-preview")
#endif
                    }
                }
            }
        }
        .padding(12).frame(maxWidth:420,alignment:.leading)
        .background(NativeChatColors.surface)
        .clipShape(RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(NativeChatColors.separator,lineWidth:1))
        .accessibilityElement(children:.contain)
        .accessibilityLabel("File attachment, " + filename)
        .onDisappear { model.closeInlineAudio(postID: post.id, ownerID: audioOwnerID) }
    }

    @ViewBuilder private var inlineAudio: some View {
        if model.documentPreviewLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading audio…").font(.callout).foregroundColor(NativeChatColors.muted)
                Spacer()
                Button("Cancel") { model.closeDocumentPreview() }.buttonStyle(.plain)
            }.accessibilityElement(children: .contain)
        } else if let failure = model.documentPreviewError {
            VStack(alignment: .leading, spacing: 8) {
                Text(failure).font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try again") { model.retryDocumentPreview() }
                    Button("Close") { model.closeDocumentPreview() }
                }.buttonStyle(.plain).foregroundColor(NativeChatColors.green)
            }
        } else if case .media(let playback) = model.documentPreviewContent {
            NativeInlineAudioControls(playback: playback, retry: model.retryDocumentPreview,
                                      expand: model.expandInlineAudio, stop: model.closeDocumentPreview)
        }
    }
}

private struct NativeFileAttachmentTransferStatus: View {
    @ObservedObject var record: ChatDownloadRecord
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Text(record.progressLabel).font(.caption).foregroundColor(NativeChatColors.muted)
                .lineLimit(2).fixedSize(horizontal:false,vertical:true)
            if record.state == .transferring {
                ProgressView(value:record.fraction).progressViewStyle(.linear)
                    .accessibilityLabel("Attachment download progress")
            }
        }
    }
}
