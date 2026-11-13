import AppKit
import SwiftUI

struct NativeMessageText: View {
    let post: ChatPost
    var textOverride: String? = nil
    @ObservedObject var model: NativeChatPreviewModel
    @StateObject private var website = NativeMessageWebsiteOpening()
    @State private var hashtagDestination: NativeHashtagDestination?
    @State private var calendarDestination: ChatDateLinks.Selection?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(ChatMessageFormatting.blocks(textOverride ?? model.messageText(post)).enumerated()), id: \.offset) { item in
                    NativeFormattedMessageBlock(block: item.element, mentions: model.mentionNames, hashtagLinks: textOverride == nil && model.canBrowseHashtags(post.channel_id), calendarLinks: textOverride == nil && model.calendarDetection == true && model.canCreateCalendarEvent(post))
                }
            }.lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { destination in
                    if let date = ChatDateLinks.selection(destination) {
                        guard model.connected, model.calendarDetection == true, model.canRead(post.channel_id) else { return .discarded }
                        calendarDestination = date; return .handled
                    }
                    if let tag = ChatHashtags.tag(from:destination) {
                        guard model.canBrowseHashtags(post.channel_id) else { return .discarded }
                        hashtagDestination = .init(name:tag); return .handled
                    }
                    guard model.connected, model.canRead(post.channel_id), let url = ChatMessageLinks.messageURL(destination.absoluteString) else { return .discarded }
                    website.begin(model:model,post:post,destination:url,source:textOverride.map { .botText($0) } ?? .body)
                    return .handled
                })
            NativeMessageWebsiteFeedback(opening:website,model:model)
            if post.props?.safe_url == false {
                Label("Synology flagged a link in this message as unsafe.", systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundColor(.orange).padding(.top,8)
            }
        }
        .task(id: model.accountGeneration) { if textOverride == nil { await model.ensureCalendarDetection() } }
        .sheet(item: $calendarDestination) { date in NativeCalendarEventView(model: model, post: post, detected: date) }
        .sheet(item:$hashtagDestination) { tag in NativeMessageSearchView(model:model,hashtag:tag.name,fixedChannelID:post.channel_id) }
        .onChange(of:model.connected) { connected in if !connected { hashtagDestination = nil; calendarDestination = nil } }
        .onDisappear { website.clear(); hashtagDestination = nil; calendarDestination = nil }
    }
}

struct NativeLinkPreviewCard: View {
    let post: ChatPost
    let item: ChatIndexedLinkPreview
    @ObservedObject var model: NativeChatPreviewModel
    @State private var image: NSImage?
    @State private var favicon: NSImage?
    @StateObject private var website = NativeMessageWebsiteOpening()
    @State private var video:ChatYouTubeVideo?
    @State private var playingRequested = false
    private func openWebsite(_ destination:URL) {
        guard !website.busy else { return }
        playingRequested = false
        website.begin(model:model,post:post,destination:destination,source:.card(item.index))
    }
    private func playVideo(_ destination:URL) {
        guard !website.busy else { return }
        playingRequested = true
        let target = $video
        website.begin(model:model,post:post,destination:destination,source:.card(item.index),open:{ checked in
            guard let parsed = ChatYouTubeVideo(url:checked) else { return false }
            target.wrappedValue = parsed;return true
        })
    }
    private var imageMetadataSize:CGSize? {
        item.preview.image_prop.map { CGSize(width:$0.width,height:$0.height) }
    }
    private var reservedImageSize:CGSize? {
        NativeLinkPreviewImageLayout.reservedSize(image:item.preview.image,metadata:imageMetadataSize)
    }
    var body: some View {
        if let destination = item.preview.url.flatMap(ChatMessageLinks.webURL) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if let favicon {
                        Image(nsImage: favicon).resizable().scaledToFit().frame(width: 16, height: 16).accessibilityHidden(true)
                    } else {
                        Image(systemName: "globe").frame(width: 16, height: 16).foregroundColor(NativeChatColors.muted).accessibilityHidden(true)
                    }
                    Text(destination.host ?? "Website").font(.system(size: 11, weight: .semibold)).foregroundColor(NativeChatColors.muted)
                    Spacer()
                    if post.creator_id == model.userID {
                        Button { Task { await model.hideLinkPreview(post, index: item.index) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(NativeChatColors.muted)
                            .accessibilityLabel("Hide link preview").help("Hide this preview")
                            .disabled(!model.canChangeOwnMessage(post))
                    }
                }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                Button {
                    openWebsite(destination)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.preview.title?.isEmpty == false ? item.preview.title! : destination.absoluteString)
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(NativeChatColors.text).lineLimit(2)
                        if let description = item.preview.description, !description.isEmpty {
                            Text(description).font(.system(size: 12)).foregroundColor(NativeChatColors.muted).lineLimit(3)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
                }.buttonStyle(.plain).help(destination.absoluteString)
                    .accessibilityLabel("Open website: " + (item.preview.title ?? destination.host ?? "Website"))
                    .background {
#if DEBUG
                        NativeMessageActionMarker(postID:post.id,kind:"link-open:"+String(item.index))
#endif
                    }
                if let image,let size = NativeLinkPreviewImageLayout.displaySize(image:item.preview.image,metadata:imageMetadataSize,loaded:image.size),
                   let renderedSize = NativeLinkPreviewImageLayout.renderedSize(loaded:image.size,slot:size) {
                    Button {
                        if ChatYouTubeVideo(url:destination) != nil { playVideo(destination) }
                        else { openWebsite(destination) }
                    } label: {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width:renderedSize.width,height:renderedSize.height)
                            .frame(width:size.width,height:size.height)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay {
                                if ChatYouTubeVideo(url:destination) != nil {
                                    Image(systemName:"play.circle.fill").font(.system(size:44)).symbolRenderingMode(.palette)
                                        .foregroundStyle(.white,Color.black.opacity(0.7)).accessibilityHidden(true)
                                }
                            }
                    }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 12)
                        .accessibilityLabel(ChatYouTubeVideo(url:destination) != nil ? "Play YouTube video" : "Open preview image website: " + (destination.host ?? "Website"))
                        .background {
#if DEBUG
                            NativeMessageActionMarker(postID:post.id,kind:"link-image:"+String(item.index))
#endif
                        }
                } else if let size = reservedImageSize {
                    // Keep geometry stable during the request and after a failed
                    // decode. This placeholder has no action or indefinite spinner.
                    Image(systemName:"photo").font(.system(size:min(24,min(size.width,size.height))))
                        .foregroundColor(NativeChatColors.muted)
                        .frame(width:size.width,height:size.height)
                        .background(NativeChatColors.canvas.opacity(0.5))
                        .clipped().frame(maxWidth:.infinity,alignment:.leading)
                        .padding(.horizontal,14).padding(.bottom,12).accessibilityHidden(true)
                }
                if ChatYouTubeVideo(url:destination) != nil {
                    HStack {
                        Button { playVideo(destination) } label: { Label("Play video",systemImage:"play.fill") }.buttonStyle(NativeToolbarButtonStyle())
                        Button("Open YouTube") { openWebsite(destination) }.buttonStyle(NativeToolbarButtonStyle())
                    }.padding(.horizontal,14).padding(.bottom,12).disabled(website.busy)
                }
                NativeMessageWebsiteFeedback(opening:website,model:model,confirmationAction:playingRequested ? "Play video" : "Open website").padding(.horizontal,14)
            }.frame(maxWidth: 400, alignment: .leading)
                .background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(NativeChatColors.separator))
                .task(id: "\(post.id):\(item.index):\(model.accountGeneration):" + (item.preview.image ?? "")) {
                    image = nil
                    let loaded = await model.linkPreviewImage(for: post, preview: item.preview)
                    if !Task.isCancelled { image = loaded }
                }
                .task(id: "\(post.id):\(item.index):\(model.accountGeneration):" + (item.preview.favicon ?? "")) {
                    favicon = nil
                    let loaded = await model.linkPreviewFavicon(for: post, preview: item.preview)
                    if !Task.isCancelled { favicon = loaded }
                }
                .sheet(isPresented:Binding(get:{ video != nil },set:{ if !$0 { video = nil } })) {
                    if let video { NativeYouTubePlayerSheet(video:video) }
                }
                .onChange(of:model.accountGeneration) { _ in video = nil;website.clear() }
                .onChange(of:model.selection) { _ in video = nil;website.clear() }
                .onChange(of:model.connected) { if !$0 { video = nil;website.clear() } }
                .onChange(of:model.encryptionUnlocked) { _ in video = nil;website.clear() }
                .onChange(of:model.canRead(post.channel_id)) { if !$0 { video = nil;website.clear() } }
                .onChange(of:model.hidesLinkPreviews) { if $0 { video = nil;website.clear() } }
                .onChange(of:item.preview.url) { _ in video = nil;website.clear() }
                .onDisappear { image = nil; favicon = nil;website.clear();video = nil }
        }
    }
}
