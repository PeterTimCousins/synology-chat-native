import SwiftUI

struct NativeMessageCollection: View {
    @ObservedObject var model: NativeChatPreviewModel
    var channelID:Int64? = nil
    private var pinned:Bool { channelID != nil }
    private var title:String { pinned ? "Pinned messages" : "Saved messages" }
    @StateObject private var library = NativeConversationLibraryStore()
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pinSort: ChatPinSort = .pinned
    @State private var actionError: String?
    @State private var updating = false
    @State private var visible = false
    @State private var watchID = UUID()
    @State private var previewOwner = UUID()
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:pinned ? "pin.fill" : "bookmark.fill").font(.system(size:20)).foregroundColor(NativeChatColors.green)
                VStack(alignment:.leading,spacing:3) {
                    Text(title).font(.system(size:19,weight:.bold))
                    Text(channelID.flatMap { id in model.channels.first(where:{ $0.id == id }).map(model.title) } ?? "Your collection across conversations").font(.callout).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button { load() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh " + title.lowercased()).disabled(updating)
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close " + title.lowercased()).keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            HStack {
                if pinned {
                    Picker("Sort pinned messages", selection: $pinSort) {
                        ForEach(ChatPinSort.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 210).disabled(updating)
                }
                TextField(pinned ? "Find a pinned message" : "Find a saved message",text:$query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(pinned ? "Find a pinned message" : "Find a saved message").onSubmit { load() }.disabled(updating)
                Button("Search") { load() }.disabled(updating)
            }.padding(.horizontal,20).padding(.bottom,16)
            Divider().overlay(NativeChatColors.separator)
            if let actionError { Text(actionError).font(.callout).foregroundColor(.orange).padding(20) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    if !library.loading && library.posts.isEmpty && library.failure == nil {
                        VStack(spacing:10) {
                            Image(systemName:pinned ? "pin" : "bookmark").font(.system(size:28))
                            Text(!library.searched ? "Enter a search and press Return." : query.isEmpty ? (pinned ? "Keep useful messages visible to this conversation." : "Keep useful messages here.") : (pinned ? "No matching pinned messages." : "No matching saved messages."))
                            if query.isEmpty { Text(pinned ? "Choose Pin message from a message’s menu." : "Choose Save message from a message’s menu.").font(.callout) }
                        }.foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity).padding(.vertical,60)
                    }
                    ForEach(library.posts) { post in messageRow(post) }
                    if let failure = library.failure {
                        Text(failure).foregroundColor(.orange)
                        Button("Try again") { library.retry() }
                    }
                    if library.hasMore && !library.loading && library.failure == nil {
                        Button("Load more " + title.lowercased()) { load(more:true) }.disabled(updating).frame(maxWidth:.infinity)
                    }
                    if library.loading { ProgressView("Loading " + title.lowercased() + "…").frame(maxWidth:.infinity).padding(20) }
                }.padding(20)
            }
        }.frame(width:700,height:650).background(NativeChatColors.canvas)
            .foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .onAppear { visible = true;model.watchCollection(watchID,channelID:channelID);model.conversationLibraryVisible = true; load() }
            .onChange(of:model.channels) { _ in if let channelID,!model.canBrowseConversationContent(channelID) { dismiss() } }
            .onChange(of:pinSort) { _ in load() }
            .onChange(of:query) { _ in closeOwnedPreviews();library.clear(); actionError = nil }
            .onReceive(model.collectionChanges) { change in
                model.closeCollectionPreviews(owner:previewOwner,changed:change)
                library.receive(change)
            }
            .onReceive(model.collectionResyncs) { epoch in
                guard epoch == model.accountGeneration else { return }
                closeOwnedPreviews();library.recover(accountGeneration:epoch)
            }
            .onChange(of:model.accountGeneration) { _ in closeOwnedPreviews();library.clear();dismiss() }
            .sheet(isPresented:Binding(get:{ model.searchImageOwner == previewOwner && model.imageViewerPost != nil },set:{ if !$0 { closeOwnedImage() } })) {
                NativeImageViewer(model:model,didJumpToSource:{ dismiss() },sourceContextLabel:pinned ? "Pinned message" : "Saved message")
            }
            .sheet(isPresented:Binding(get:{ (model.searchDocumentOwner == previewOwner || model.collectionDocumentOwner == previewOwner) && model.documentPreviewIsPresented },set:{ if !$0 { closeOwnedDocument() } })) {
                NativeDocumentPreview(model:model,didJumpToSource:{ dismiss() },sourceContextLabel:pinned ? "Pinned message" : "Saved message")
            }
            .onDisappear { visible = false;model.stopWatchingCollection(watchID);closeOwnedPreviews();library.clear();model.conversationLibraryVisible = false }
    }
    private func messageRow(_ post:ChatPost) -> some View {
        let channel = model.channels.first { $0.id == post.channel_id }
        return VStack(alignment:.leading,spacing:12) {
            HStack(spacing:8) {
                Image(systemName:channel?.encrypted == true ? "lock" : "bubble.left.and.bubble.right")
                Text(channel.map(model.title) ?? "Unavailable conversation").fontWeight(.medium)
                if post.isReply { Text("· Thread reply") }
                if pinned, post.is_sticky == true { Label("Kept on top", systemImage: "arrow.up.to.line") }
                Spacer()
                if let saved = pinned ? post.last_pin_at : post.star_at, saved.isFinite, saved > 0 {
                    Text((pinned ? "Pinned " : "Saved ") + model.formattedDate(Date(timeIntervalSince1970:saved/1000),dateOnly:true))
                }
            }.font(.system(size:11)).foregroundColor(NativeChatColors.muted)
            if channel != nil {
                HStack {
                    NativeUserIdentity(model:model,userID:post.creator_id,size:24)
                    Text(model.names[post.creator_id] ?? "User \(post.creator_id)").font(.system(size:13,weight:.semibold))
                    Text(model.formattedDate(post.date)).font(.system(size:11)).foregroundColor(NativeChatColors.muted)
                }
                if model.canRead(post.channel_id) {
                    if model.canReadSearchResult(post) {
                        NativeSearchResultContent(post:post,model:model,openImage:{ openImage(post) },openDocument:{ model.openCollectionDocument(post,owner:previewOwner,playMedia:model.documentKind(post)?.isMedia == true) })
                    } else if post.type == "sticker", let name = model.stickerName(post) {
                        NativeStickerImage(assets:model.stickers,name:name,size:100)
                    } else if !post.message.isEmpty { NativeMessageText(post:post,model:model).font(.system(size:13)) }
                    if !model.canReadSearchResult(post),post.type == "file" {
                        Label(model.attachmentName(post),systemImage:"doc").font(.callout)
                        if model.canPreviewDocument(post) {
                            Button(model.documentKind(post)?.isMedia == true ? "Play" : "Preview") { model.openCollectionDocument(post,owner:previewOwner,playMedia:model.documentKind(post)?.isMedia == true) }.buttonStyle(NativeToolbarButtonStyle())
                        }
                    }
                } else { Label("Unlock this conversation to read the saved message.",systemImage:"lock").font(.callout).foregroundColor(NativeChatColors.muted) }
            }
            HStack {
                Button("Show in conversation") {
                    dismiss()
                    model.navigateToMessage(channelID:post.channel_id,postID:post.id,threadID:post.isReply ? post.thread_id : nil)
                }.disabled(channel == nil || updating)
                Spacer()
                if model.pendingMessageActions.contains(post.id) { ProgressView().controlSize(.small) }
                if pinned {
                    if model.pinStateNeedsRefresh.contains(post.id) {
                        Button("Verify pin state") {
                            updating = true; actionError = nil
                            Task { let verified = await model.refreshPinState(post); updating = false; guard visible else { return }; if verified { actionError = nil } else { actionError = model.error } }
                        }.disabled(updating || model.pendingMessageActions.contains(post.id))
                    } else {
                        Button(post.is_sticky == true ? "Stop keeping on top" : "Keep on top") {
                            updating = true; actionError = nil
                            Task { let changed = await model.setPinSticky(post, enabled: post.is_sticky != true); updating = false; guard visible else { return }; if changed { actionError = nil } else { actionError = model.error } }
                        }.disabled(updating || !model.canKeepPinOnTop(post))
                    }
                }
                Button(pinned ? "Unpin" : "Remove from saved") {
                    updating = true; actionError = nil
                    Task {
                        let changed = pinned ? await model.setPinned(post,enabled:false) : await model.setBookmark(post,enabled:false)
                        updating = false
                        guard visible else { return }
                        if changed { actionError = nil }
                        else { actionError = model.error ?? "Could not confirm this change. Refresh and try again." }
                    }
                }.disabled(updating || (pinned ? !model.canPin(post) : !model.canAct(on:post)))
            }.font(.system(size:12)).buttonStyle(NativeToolbarButtonStyle())
        }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(NativeChatColors.separator))
            .accessibilityElement(children: .contain).accessibilityIdentifier("message-collection-post-\(post.id)")
    }
    private func load(more:Bool = false) {
        if !more { closeOwnedPreviews() }
        actionError = nil
        let pinned = pinned, channelID = channelID, pinSort = pinSort, model = model
        library.load(kind:pinned ? .pins : .bookmarks,query:query,channelID:channelID,more:more,pinSort:pinSort,accountGeneration:model.accountGeneration) { text,offset,filters in
            if let channelID { return try await model.pinnedMessages(channelID:channelID,query:text,offset:offset,sort:pinSort) }
            return try await model.searchMessages(query:text,channelID:nil,offset:offset,filters:filters)
        }
    }
    private func closeOwnedImage() { if model.searchImageOwner == previewOwner { model.closeImageViewer() } }
    private func closeOwnedDocument() { if model.searchDocumentOwner == previewOwner || model.collectionDocumentOwner == previewOwner { model.closeDocumentPreview() } }
    private func closeOwnedPreviews() { model.closeCollectionPreviews(owner:previewOwner) }
    private func openImage(_ post:ChatPost) {
        guard !updating,model.canReadSearchImage(post) else { return }
        model.openSearchImage(post,context:library.posts,owner:previewOwner,hasMore:library.hasMore,loadMore:library.imageGalleryLoader())
    }
}
