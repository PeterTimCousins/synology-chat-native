import AppKit
import SwiftUI

/// Uses browser-owned snapshots rather than the active message row, whose controls can mutate posts.
struct NativePublicChannelPreviewView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channel:ChatChannel
    var onJoined:() -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot:ChatChannelPreviewSnapshot?
    @State private var failure:String?
    @State private var loading = false
    @State private var joining = false
    @State private var request = UUID()
    @State private var task:Task<Void,Never>?
    @State private var session = -1
    @State private var showingMembers = false
    @State private var unsafeLink:ChatPreviewLinkReview?
    @State private var openingLink = false
    @State private var linkTask:Task<Void,Never>?
    @State private var linkRequest = UUID()
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"number").foregroundColor(NativeChatColors.green)
                VStack(alignment:.leading,spacing:5) {
                    Text(snapshot?.channel.name ?? channel.name).font(.system(size:20,weight:.bold))
                    Text("Channel preview · You haven’t joined").font(.caption).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button { showingMembers = true } label: {
                    Label("Members",systemImage:"person.2")
                }.accessibilityLabel("Preview channel members").disabled(snapshot == nil || loading || joining)
                    .popover(isPresented:$showingMembers) {
                        if let snapshot { NativePublicChannelPreviewMembers(model:model,snapshot:snapshot) }
                    }
                Button { load() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh channel preview").disabled(loading || joining)
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close channel preview").keyboardShortcut(.cancelAction).disabled(joining)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            if let purpose = (snapshot?.channel ?? channel).purpose,!purpose.isEmpty {
                Text(purpose).font(.callout).foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.bottom,16)
            }
            Divider().overlay(NativeChatColors.separator)
            if let failure { Text(failure).foregroundColor(.orange).padding(16) }
            if loading { ProgressView("Loading recent messages…").padding(20) }
            if openingLink { ProgressView("Opening website…").font(.caption).padding(12) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:20) {
                    if let snapshot {
                        if snapshot.posts.isEmpty { Text("No messages to preview").foregroundColor(NativeChatColors.muted).padding(.vertical,40) }
                        ForEach(snapshot.posts) { post in previewRow(post) }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(24)
            }
            Divider().overlay(NativeChatColors.separator)
            HStack {
                Text("Up to 20 recent messages. Join to reply, open attachments, and explore the full conversation.").font(.caption).foregroundColor(NativeChatColors.muted)
                Spacer()
                Button(joining ? "Joining…" : "Join channel") { join() }.buttonStyle(NativeSendButtonStyle())
                    .disabled(loading || joining || openingLink || snapshot == nil || !model.canJoinDiscoveredChannel(snapshot?.channel ?? channel))
            }.padding(20)
        }.frame(width:740,height:620).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .interactiveDismissDisabled(joining)
            .onAppear { session = model.accountGeneration;load() }
            .onDisappear { resetLinkNavigation();request = UUID();task?.cancel();task = nil;snapshot = nil }
            .onChange(of:model.accountGeneration) { if $0 != session { resetLinkNavigation();snapshot = nil;dismiss() } }
            .onChange(of:model.connected) { if !$0 { resetLinkNavigation();snapshot = nil;dismiss() } }
            .alert(ChatMessageLinkPresentation.title(unsafeLink?.destination),isPresented:Binding(get:{ unsafeLink != nil },set:{ if !$0 { unsafeLink = nil } }),presenting:unsafeLink) { review in
                Button("Cancel",role:.cancel) { unsafeLink = nil }
                Button(ChatMessageLinkPresentation.action(review.destination)) { unsafeLink = nil;performOpen(review,confirmed:true) }
            } message: { review in Text(ChatMessageLinkPresentation.message(review.destination,flagged:review.flaggedByServer)) }
    }
    private func previewRow(_ post:ChatPost) -> some View {
        HStack(alignment:.top,spacing:12) {
            NativeUserAvatar(avatars:model.avatars,user:model.directory.first { $0.user_id == post.displayAuthorID },name:model.names[post.displayAuthorID] ?? "User \(post.displayAuthorID)",size:34)
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text(model.names[post.displayAuthorID] ?? "User \(post.displayAuthorID)").fontWeight(.semibold)
                    Text(model.formattedDate(post.date)).font(.caption).foregroundColor(NativeChatColors.muted)
                }
                if (post.delete_at ?? 0) > 0 {
                    Text("Message deleted").italic().foregroundColor(NativeChatColors.muted)
                } else if post.type == "system" {
                    Text(post.systemEventText(names:model.names)).foregroundColor(NativeChatColors.muted)
                } else {
                    if let sticker = ChatChannelPreviewContent.stickerName(post) {
                        NativeStickerImage(assets:model.stickers,name:sticker,size:140)
                    } else {
                    ForEach(Array(ChatMessageFormatting.blocks(post.message).enumerated()),id:\.offset) { item in
                        NativeFormattedMessageBlock(block:item.element,mentions:model.mentionNames,hashtagLinks:false,calendarLinks:false)
                    }.environment(\.openURL,OpenURLAction { destination in
                        guard let valid = ChatMessageLinks.messageURL(destination.absoluteString) else { return .discarded }
                        beginOpen(postID:post.id,destination:valid,source:.message);return .handled
                    })
                    }
                    if let poll = ChatChannelPreviewContent.poll(post) {
                        VStack(alignment:.leading,spacing:9) {
                            Label(poll.isOpen() ? "Poll" : "Closed poll",systemImage:"chart.bar").font(.caption).foregroundColor(NativeChatColors.muted)
                            ForEach(poll.sortedResults) { choice in
                                HStack { Image(systemName:"circle").foregroundColor(NativeChatColors.muted);Text(choice.text);Spacer();Text("\(choice.count)").foregroundColor(NativeChatColors.muted) }
                            }
                            Text("Join the channel to participate.").font(.caption).foregroundColor(NativeChatColors.muted)
                        }.padding(14).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                    }
                    if post.file_props?.is_image == true,let snapshot {
                        NativePublicChannelPreviewImage(model:model,snapshot:snapshot,post:post)
                    }
                    if let file = post.file_props {
                        Label(file.name ?? "Attachment",systemImage:file.is_image == true ? "photo" : "doc")
                            .font(.callout).padding(12).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:8))
                    }
                    if post.props?.safe_url == false {
                        Label("Synology flagged a link in this message as unsafe.",systemImage:"exclamationmark.shield").font(.caption).foregroundColor(.orange)
                    }
                    if let snapshot {
                        ForEach(model.previewLinkCards(snapshot,postID:post.id)) { item in
                            NativePublicChannelPreviewLinkCard(model:model,snapshot:snapshot,postID:post.id,item:item,onOpen:{ beginOpen(postID:post.id,destination:$0,source:.card(item.index)) })
                        }
                    }
                    if let count = post.comment_count,count > 0 { Label("\(count) replies",systemImage:"bubble.right").font(.caption).foregroundColor(NativeChatColors.muted) }
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private func load() {
        resetLinkNavigation();task?.cancel();showingMembers = false;let key = UUID();request = key;snapshot = nil;failure = nil;loading = true
        task = Task { @MainActor in
            defer { if request == key { loading = false } }
            do {
                let value = try await model.previewDiscoveredChannel(channel)
                try Task.checkCancellation();guard request == key,session == model.accountGeneration else { return }
                snapshot = value
            } catch is CancellationError { }
            catch { if request == key { failure = "Could not load this preview. Refresh channels and try again." } }
        }
    }
    private func resetLinkNavigation() {
        linkRequest = UUID();linkTask?.cancel();linkTask = nil;unsafeLink = nil;openingLink = false
    }
    private func beginOpen(postID:Int64,destination:URL,source:ChatPreviewLinkSource) {
        guard !openingLink,!joining,!loading,let snapshot else { return }
        do { performOpen(try model.previewLinkIntent(snapshot,postID:postID,destination:destination,source:source),confirmed:false) }
        catch { failure = "This link is no longer available. Refresh the preview and try again." }
    }
    private func performOpen(_ review:ChatPreviewLinkReview,confirmed:Bool) {
        guard !openingLink,!joining else { return }
        let key = UUID();linkRequest = key;openingLink = true;failure = nil
        linkTask = Task { @MainActor in
            defer { if linkRequest == key { openingLink = false } }
            do {
                let result = try await model.openPreviewLink(review,allowUnsafe:confirmed)
                try Task.checkCancellation();guard linkRequest == key else { return }
                if case .confirmation(let pending) = result { unsafeLink = pending }
            } catch is CancellationError { }
            catch { if linkRequest == key { failure = error.localizedDescription } }
        }
    }
    private func join() {
        guard let current = snapshot?.channel else { return }
        joining = true;failure = nil
        task = Task { @MainActor in
            defer { joining = false }
            do { _ = try await model.joinDiscoveredChannel(current);try Task.checkCancellation();onJoined();dismiss() }
            catch is CancellationError { }
            catch { snapshot = nil;failure = error.localizedDescription }
        }
    }
}

private struct NativePublicChannelPreviewImage:View {
    @ObservedObject var model:NativeChatPreviewModel
    let snapshot:ChatChannelPreviewSnapshot
    let post:ChatPost
    @State private var image:NSImage?
    @State private var unavailable = false
    var body:some View {
        Group {
            if let image {
                NativeInlineImageView(image:image,label:post.file_props?.name ?? "Preview image").frame(maxWidth:320,maxHeight:220)
            } else if unavailable {
                Label("Image preview unavailable",systemImage:"photo").font(.caption).foregroundColor(NativeChatColors.muted)
            } else { ProgressView("Loading image…").font(.caption) }
        }.task(id:"\(snapshot.accountGeneration):\(post.id)") {
            image = nil;unavailable = false
            do {
                let value = try await model.previewChannelThumbnail(snapshot,postID:post.id)
                try Task.checkCancellation();guard snapshot.accountGeneration == model.accountGeneration else { return }
                image = value
            } catch is CancellationError { }
            catch { if !Task.isCancelled { unavailable = true } }
        }.onDisappear { image = nil }
    }
}

private struct NativePublicChannelPreviewMembers:View {
    @ObservedObject var model:NativeChatPreviewModel
    let snapshot:ChatChannelPreviewSnapshot
    @State private var ids:[Int64]?
    @State private var failed = false
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Channel members").font(.headline)
            if failed { Text("Could not load members. Close this list and refresh the preview to try again.").foregroundColor(.orange) }
            else if let ids {
                Text(NativeLocalizedStrings.count("%lld members",Int64(ids.count))).font(.caption).foregroundColor(NativeChatColors.muted)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:12) {
                        ForEach(ids,id:\.self) { id in
                            HStack(spacing:10) {
                                NativeUserAvatar(avatars:model.avatars,user:model.directory.first { $0.user_id == id },name:model.names[id] ?? "User \(id)",size:30)
                                Text(model.names[id] ?? "User \(id)")
                            }
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            } else { ProgressView("Loading members…") }
        }.padding(20).frame(width:340,height:360).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).nativeChatAppearance()
            .task(id:snapshot.accountGeneration) {
                do { let value = try await model.previewChannelMemberIDs(snapshot);try Task.checkCancellation();ids = value }
                catch is CancellationError { }
                catch { if !Task.isCancelled { failed = true } }
            }.onDisappear { ids = nil }
    }
}

private struct NativePublicChannelPreviewLinkCard:View {
    @ObservedObject var model:NativeChatPreviewModel
    let snapshot:ChatChannelPreviewSnapshot
    let postID:Int64
    let item:ChatIndexedLinkPreview
    let onOpen:(URL)->Void
    @State private var image:NSImage?
    @State private var favicon:NSImage?
    var body:some View {
        Button { if let destination = item.preview.url.flatMap(ChatMessageLinks.webURL) { onOpen(destination) } } label: {
        VStack(alignment:.leading,spacing:9) {
            if let image { Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:360,maxHeight:200).accessibilityLabel(item.preview.title ?? "Link preview image") }
            HStack(spacing:7) {
                if let favicon { Image(nsImage:favicon).resizable().frame(width:16,height:16).accessibilityHidden(true) }
                else { Image(systemName:"globe").foregroundColor(NativeChatColors.muted) }
                Text(item.preview.url.flatMap(ChatMessageLinks.webURL)?.host ?? "Website").foregroundColor(NativeChatColors.muted)
            }.font(.caption)
            if let title = item.preview.title { Text(title).fontWeight(.medium) }
            if let description = item.preview.description { Text(description).foregroundColor(NativeChatColors.muted).lineLimit(4) }
        }.font(.callout).padding(12).frame(maxWidth:390,alignment:.leading).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:8))
        }.buttonStyle(.plain).accessibilityLabel("Open website " + (item.preview.url.flatMap(ChatMessageLinks.webURL)?.host ?? ""))
            .task(id:"\(snapshot.accountGeneration):\(postID):\(item.index)") {
                image = nil;favicon = nil
                if item.preview.image != nil {
                    image = try? await model.previewChannelLinkAsset(snapshot,postID:postID,index:item.index,asset:.image)
                }
                guard !Task.isCancelled else { image = nil;return }
                if item.preview.favicon != nil {
                    favicon = try? await model.previewChannelLinkAsset(snapshot,postID:postID,index:item.index,asset:.favicon)
                }
                if Task.isCancelled { image = nil;favicon = nil }
            }.onDisappear { image = nil;favicon = nil }
    }
}
