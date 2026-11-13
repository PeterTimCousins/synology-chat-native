import SwiftUI
import AppKit

/// Explicit link browsing is separate from inline message-preview visibility.
/// Display metadata as plain text; images use only the authenticated NAS proxy.
struct NativeLibraryLink: View {
    @ObservedObject var model: NativeChatPreviewModel
    let entry: ChatLinkLibrary.Entry
    let showSource: () -> Void
    @State private var image: NSImage?
    @StateObject private var website = NativeMessageWebsiteOpening()
    @State private var playback:LibraryYouTubePresentation?
    @State private var playingRequested = false
    private struct LibraryYouTubePresentation:Identifiable {
        let id = UUID()
        let video:ChatYouTubeVideo
    }
    private var youtube:ChatYouTubeVideo? { ChatYouTubeVideo(url:entry.destination) }
    private func openWebsite() {
        guard model.canBrowseLibraryLink(entry),!website.busy else { return }
        playingRequested = false
        website.begin(model:model,post:entry.post,destination:entry.destination,source:.library(entry.rawURL))
    }
    private func playVideo() {
        guard youtube != nil,model.canBrowseLibraryLink(entry),!website.busy else { return }
        playingRequested = true
        let target = $playback,account = model.accountGeneration
        website.begin(model:model,post:entry.post,destination:entry.destination,source:.library(entry.rawURL),open:{ checked in
            guard model.accountGeneration == account,model.canBrowseLibraryLink(entry),
                  let video = ChatYouTubeVideo(url:checked) else { return false }
            target.wrappedValue = .init(video:video);return true
        })
    }
    private func clearPlayback() { playback = nil;website.clear();playingRequested = false }
    private var title: String {
        entry.preview.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? entry.rawURL
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                if let image, model.canShowLibraryLinkImage(entry) {
                    if youtube != nil {
                        Button(action:playVideo) {
                            Image(nsImage:image).resizable().scaledToFit().frame(width:112,height:88)
                                .background(NativeChatColors.elevated).clipShape(RoundedRectangle(cornerRadius:7))
                                .overlay { Image(systemName:"play.circle.fill").font(.system(size:30)).symbolRenderingMode(.palette).foregroundStyle(.white,Color.black.opacity(0.7)) }
                        }.buttonStyle(.plain).accessibilityLabel("Play YouTube video").disabled(website.busy)
                    } else {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 112, height: 88)
                            .background(NativeChatColors.elevated).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button(action:openWebsite) {
                        Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.leading).lineLimit(2)
                    }.buttonStyle(.plain).foregroundColor(NativeChatColors.green)
                        .accessibilityLabel("Open link: " + title).disabled(!model.canBrowseLibraryLink(entry) || website.busy)
                    if let description = entry.preview.description, !description.isEmpty {
                        Text(description).font(.callout).lineLimit(3).textSelection(.enabled)
                    }
                    Text(entry.destination.host ?? "Website").font(.caption).foregroundColor(NativeChatColors.muted)
                    if model.libraryLinkIsUnsafe(entry) {
                        Label("Synology flagged this link as unsafe", systemImage: "exclamationmark.shield").font(.caption).foregroundColor(.orange)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(model.names[entry.post.creator_id] ?? "User \(entry.post.creator_id)")
                Text("· " + model.formattedDate(entry.post.date))
                if entry.post.isReply { Text("· Thread reply") }
                Spacer()
            }.font(.caption).foregroundColor(NativeChatColors.muted)
            if youtube != nil {
                HStack(spacing:12) {
                    Button(action:playVideo) { Label("Play video",systemImage:"play.fill") }
                    Button("Open YouTube",action:openWebsite)
                }.buttonStyle(NativeToolbarButtonStyle()).disabled(!model.canBrowseLibraryLink(entry) || website.busy)
            }
            NativeMessageWebsiteFeedback(opening:website,model:model,confirmationAction:playingRequested ? "Play video" : "Open website")
            HStack {
                Button("Show in conversation", action: showSource).disabled(!model.canBrowseLibraryLink(entry))
                Spacer()
                Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.rawURL, forType: .string) }
                    .disabled(!model.canBrowseLibraryLink(entry))
            }.font(.system(size: 12)).buttonStyle(NativeToolbarButtonStyle())
        }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(NativeChatColors.separator))
            .accessibilityElement(children: .contain).accessibilityIdentifier("conversation-library-link-" + entry.id)
            .task(id: entry.id + ":\(model.accountGeneration):" + (entry.preview.image ?? "") + ":\(model.libraryLinkIsUnsafe(entry))") { image = await model.libraryLinkImage(entry) }
            .sheet(item:$playback) { presentation in NativeYouTubePlayerSheet(video:presentation.video) }
            .onChange(of:model.accountGeneration) { _ in clearPlayback() }
            .onChange(of:model.selection) { _ in clearPlayback() }
            .onChange(of:model.connected) { if !$0 { clearPlayback() } }
            .onChange(of:model.encryptionUnlocked) { _ in clearPlayback() }
            .onChange(of:model.canBrowseLibraryLink(entry)) { if !$0 { clearPlayback() } }
            .onChange(of:model.libraryLinkIsUnsafe(entry)) { _ in clearPlayback() }
            .onChange(of:entry.rawURL) { _ in clearPlayback() }
            .onChange(of:entry.post.id) { _ in clearPlayback() }
            .onChange(of:entry.post.update_at) { _ in clearPlayback() }
            .onReceive(model.collectionChanges) { change in
                if change.accountGeneration == model.accountGeneration,change.channelID == entry.post.channel_id,change.postID == entry.post.id { clearPlayback() }
            }
            .onReceive(model.collectionResyncs) { if $0 == model.accountGeneration { clearPlayback() } }
            .onDisappear { image = nil;clearPlayback() }
    }
}
