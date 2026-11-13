import AppKit
import SwiftUI

/// A separate result context: browsing attachments must not replace the chat timeline.
@MainActor final class NativeConversationLibraryStore: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case files = "Files", links = "Links", bookmarks = "Saved messages", pins = "Pinned messages"
        var id: String { rawValue }
        var filters: ChatSearchFilters {
            var value = ChatSearchFilters()
            if self == .files { value.content = .file } else { value.attribute = self == .links ? .url : self == .pins ? .pin : .star }
            return value
        }
    }
    @Published private(set) var posts: [ChatPost] = []
    @Published private(set) var searched = false
    @Published private(set) var loading = false
    @Published private(set) var hasMore = false
    @Published private(set) var failure: String?
    private var offset = 0
    private var wantedPages = 1
    private var revision = UUID()
    private var galleryScope = UUID()
    private var context: Request?
    private var consumedIDs: Set<Int64> = []
    private var deletedIDs: Set<Int64> = []
    private var updates: [Int64: ChatPost] = [:]
    private var updateOrder: [Int64] = []
    private(set) var task: Task<Void, Never>?
    typealias Loader = (String, Int, ChatSearchFilters) async throws -> ChatSearchPage
    private struct Request {
        let kind: Kind; let query: String; let channelID: Int64?
        let pinSort: ChatPinSort; let files: ChatLibraryFileOptions?; let account: Int?
        let loader: Loader
        func sameScope(_ other: Request) -> Bool {
            kind == other.kind && query == other.query && channelID == other.channelID && pinSort == other.pinSort && files == other.files && account == other.account
        }
    }
    func clear() {
        task?.cancel(); task = nil; revision = UUID(); galleryScope = UUID(); context = nil
        posts = []; offset = 0; wantedPages = 1; searched = false; loading = false; hasMore = false; failure = nil
        consumedIDs = []; deletedIDs = []; updates = [:]; updateOrder = []
    }
    func load(kind: Kind, query: String, channelID: Int64?, more: Bool = false, pinSort: ChatPinSort = .pinned, fileOptions: ChatLibraryFileOptions? = nil, accountGeneration: Int? = nil, using loader: @escaping Loader) {
        let request = Request(kind:kind,query:query.trimmingCharacters(in:.whitespacesAndNewlines),channelID:channelID,pinSort:pinSort,files:fileOptions,account:accountGeneration,loader:loader)
        if more {
            guard !loading, hasMore, context?.sameScope(request) == true else { return }
            wantedPages += 1
        } else { clear() }
        context = request
        fetch(request, rebase:false, delayed:false)
    }
    func receive(_ change: ChatCollectionChange) {
        guard let context, context.account == change.accountGeneration,
              context.channelID == nil || context.channelID == change.channelID else { return }
        let known = consumedIDs.contains(change.postID) || posts.contains { $0.id == change.postID }
        switch change.state {
        case .deleted:
            guard deletedIDs.insert(change.postID).inserted else { return }
            updates[change.postID] = nil; updateOrder.removeAll { $0 == change.postID }
            posts.removeAll { $0.id == change.postID }
            guard known || loading else { return }
        case .invalidated:
            guard known || loading else { return }
        case .updated(let post):
            guard post.id == change.postID, post.channel_id == change.channelID, !deletedIDs.contains(post.id),
                  known || eligible(post, context) else { return }
            updates[post.id] = post; updateOrder.removeAll { $0 == post.id }; updateOrder.append(post.id)
            posts = reconciled(posts, context)
        }
        // Cancel the older page immediately; debounce the rebase, not invalidation.
        fetch(context, rebase:true, delayed:true)
    }
    func retry() {
        guard !loading, let context else { return }
        fetch(context,rebase:true,delayed:false)
    }
    func recover(accountGeneration: Int) {
        guard let context, context.account == accountGeneration else { return }
        // Earlier canonical overlays may themselves be obsolete after missed
        // events. Retain confirmed deletion tombstones, but replace membership
        // and metadata from authoritative pages. Events arriving during this
        // recovery build a new overlay and invalidate any older response.
        updates = [:]; updateOrder = []
        fetch(context,rebase:true,delayed:false)
    }
    /// The gallery pages this exact result set, including non-image file rows.
    /// A changed search/filter/refresh must invalidate an old viewer callback.
    func imageGalleryLoader() -> (() async throws -> ChatLibraryImagePage)? {
        guard let kind = context?.kind,[Kind.files,.bookmarks,.pins].contains(kind) else { return nil }
        let scope = galleryScope
        return { [weak self] in
            guard let self else { throw CancellationError() }
            @MainActor func settle() async throws {
                while let pending = self.task {
                    await pending.value
                    try Task.checkCancellation()
                    guard self.galleryScope == scope else { throw CancellationError() }
                }
                if let failure = self.failure { throw ChatTransferError(message:failure) }
            }
            guard self.galleryScope == scope,let context = self.context else { throw CancellationError() }
            if self.failure != nil {
                self.fetch(context,rebase:true,delayed:false)
                try await settle()
            } else {
                try await settle()
                if self.hasMore {
                    self.wantedPages += 1
                    self.fetch(context,rebase:false,delayed:false)
                    try await settle()
                }
            }
            guard self.galleryScope == scope else { throw CancellationError() }
            return ChatLibraryImagePage(posts:self.posts,hasMore:self.hasMore,cursor:self.offset)
        }
    }
    private func eligible(_ post: ChatPost, _ request: Request) -> Bool {
        guard (request.channelID == nil || post.channel_id == request.channelID), (post.delete_at ?? 0) == 0, !deletedIDs.contains(post.id) else { return false }
        switch request.kind {
        case .files: return post.type == "file" && (request.files?.includes(post) ?? true)
        case .links: return post.props?.encrypted != true && !(post.url_props ?? []).isEmpty
        case .bookmarks: return post.is_star == true
        case .pins: return post.isPinned && !post.isReply
        }
    }
    private func reconciled(_ source: [ChatPost], _ request: Request) -> [ChatPost] {
        let returnedIDs = Set(source.map(\.id))
        var seen = Set<Int64>()
        var result = source.filter { eligible($0,request) && seen.insert($0.id).inserted }
        for id in updateOrder {
            guard let post = updates[id] else { continue }
            if let index = result.firstIndex(where: { $0.id == id }) {
                guard eligible(post,request) else { result.remove(at:index); continue }
                if request.kind == .links { result.remove(at:index);result.insert(post,at:0) }
                else { result[index] = post }
            } else if eligible(post,request), request.query.isEmpty || returnedIDs.contains(id) {
                if request.kind == .links { result.insert(post,at:0) } else { result.append(post) }
            }
        }
        if request.kind == .bookmarks {
            result.sort { let a = $0.star_at ?? 0,b = $1.star_at ?? 0; return a == b ? $0.id > $1.id : a > b }
        }
        if request.kind == .pins { result = request.pinSort.ordered(result) }
        if request.kind == .files, let files = request.files { result = files.ordered(result) }
        return result
    }
    private func fetch(_ request: Request, rebase: Bool, delayed: Bool) {
        task?.cancel(); let key = UUID(); revision = key
        let next = rebase ? 0 : offset, pages = rebase ? wantedPages : 1
        let existing = rebase ? [] : posts
        let priorIDs = rebase ? Set<Int64>() : consumedIDs
        loading = true; searched = true; failure = nil
        task = Task {
            defer { if revision == key { loading = false; task = nil } }
            do {
                if delayed { try await Task.sleep(nanoseconds:150_000_000) }
                var rows = existing, rawIDs = priorIDs, position = next, more = false
                for _ in 0..<pages {
                    let page = try await request.loader(request.query,position,request.kind.filters)
                    guard !Task.isCancelled, revision == key else { return }
                    rows += page.search_results; rawIDs.formUnion(page.search_results.map(\.id))
                    position += page.search_results.count
                    more = page.search_results.count >= 25 && (page.total.map { position < $0 } ?? true)
                    if !more { break }
                }
                guard !Task.isCancelled, revision == key else { return }
                posts = reconciled(rows,request); offset = position; consumedIDs = rawIDs; hasMore = more
            } catch {
                guard !Task.isCancelled, revision == key else { return }
                failure = (error as? LocalizedError)?.errorDescription ?? "Could not update these results. Refresh to try again."
            }
        }
    }

}

struct NativeConversationLibrary: View {
    @ObservedObject var model: NativeChatPreviewModel
    let channelID: Int64
    @StateObject private var library = NativeConversationLibraryStore()
    @State private var kind = NativeConversationLibraryStore.Kind.files
    @State private var query = ""
    @State private var fileOptions = ChatLibraryFileOptions()
    @State private var watchID = UUID()
    @Environment(\.dismiss) private var dismiss
    private var linkEntries: [ChatLinkLibrary.Entry] { ChatLinkLibrary.entries(library.posts) }
    private var resultCountText: String {
        let count = kind == .links ? linkEntries.count : library.posts.count
        let noun = kind == .links ? (count == 1 ? "link" : "links") : fileOptions.category == .images ? (count == 1 ? "image" : "images") : (count == 1 ? "file" : "files")
        return "\(count) \(noun) shown"
    }
    private var title: String { model.channels.first(where: { $0.id == channelID }).map(model.title) ?? "Conversation" }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"square.stack.3d.up").font(.system(size:20)).foregroundColor(NativeChatColors.green)
                VStack(alignment:.leading,spacing:3) {
                    Text("Files & links").font(.system(size:19,weight:.bold))
                    Text(title).font(.callout).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh files and links")
                Button { dismiss() } label: { Image(systemName:"xmark") }
                    .accessibilityLabel("Close files and links").keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            HStack(spacing:16) {
                Picker("Content",selection:$kind) {
                    ForEach([NativeConversationLibraryStore.Kind.files, .links]) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width:180)
                TextField("Find in " + kind.rawValue.lowercased(),text:$query)
                    .textFieldStyle(.roundedBorder).onSubmit { load() }.accessibilityLabel("Find conversation content")
                Button("Search") { load() }
            }.padding(.horizontal,20).padding(.bottom,16)
            if kind == .files {
                HStack(spacing: 16) {
                    Picker("File type", selection: $fileOptions.category) {
                        ForEach(ChatLibraryFileOptions.Category.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 220)
                    Picker("Sort files", selection: $fileOptions.sort) {
                        ForEach(ChatLibraryFileOptions.Sort.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 230)
                    Spacer()
                }.padding(.horizontal, 20).padding(.bottom, 14)
            }
            if library.searched {
                Text(resultCountText)
                    .font(.caption).foregroundColor(NativeChatColors.muted).padding(.horizontal,20).padding(.bottom,10)
                    .accessibilityIdentifier("conversation-library-loaded-count")
            }
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    if (kind == .links ? linkEntries.isEmpty : library.posts.isEmpty) && !library.loading && library.failure == nil {
                        VStack(spacing:10) {
                            Image(systemName:kind == .files ? "doc.on.doc" : "link").font(.system(size:28))
                            Text(!library.searched ? "Enter a search and press Return." : query.isEmpty ? "No \(kind.rawValue.lowercased()) in this conversation yet." : "No matching \(kind.rawValue.lowercased()).")
                        }.foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity).padding(.vertical,60)
                    }
                    if kind == .links {
                        ForEach(linkEntries) { entry in
                            NativeLibraryLink(model: model, entry: entry) {
                                dismiss(); model.navigateToMessage(channelID: channelID, postID: entry.post.id, threadID: entry.post.isReply ? entry.post.thread_id : nil)
                            }
                        }
                    } else { ForEach(library.posts) { post in row(post) } }
                    if let failure = library.failure {
                        Text(failure).foregroundColor(.orange)
                        Button("Try again") { library.retry() }
                    }
                    if library.hasMore && !library.loading && library.failure == nil {
                        Button("Load more " + kind.rawValue.lowercased()) { load(more:true) }.frame(maxWidth:.infinity)
                    }
                    if library.loading { ProgressView("Loading " + kind.rawValue.lowercased() + "…").frame(maxWidth:.infinity).padding(20) }
                }.padding(20)
            }
        }.frame(width:740,height:650).background(NativeChatColors.canvas)
            .foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .onAppear { model.watchCollection(watchID,channelID:channelID); model.conversationLibraryVisible = true; load() }
            .onChange(of:kind) { _ in load() }
            .onChange(of:fileOptions) { _ in if kind == .files { load() } }
            .onChange(of:query) { _ in library.clear() }
            .onReceive(model.collectionChanges) { change in library.receive(change) }
            .onReceive(model.collectionResyncs) { library.recover(accountGeneration:$0) }
            .onChange(of:model.channels) { _ in if !model.canBrowseConversationContent(channelID) || !model.canRead(channelID) { library.clear(); dismiss() } }
            .onChange(of:model.accountGeneration) { _ in library.clear(); model.closeImageViewer(); model.closeDocumentPreview(); dismiss() }
            .onDisappear { model.stopWatchingCollection(watchID); library.clear(); model.closeImageViewer();model.closeDocumentPreview(); model.conversationLibraryVisible = false }
            .sheet(isPresented:Binding(get:{ model.pollAttachmentOwner == nil && model.searchDocumentOwner == nil && model.collectionDocumentOwner == nil && model.documentPreviewIsPresented },set:{ if !$0 && model.pollAttachmentOwner == nil && model.searchDocumentOwner == nil && model.collectionDocumentOwner == nil && model.documentPreviewIsPresented { model.closeDocumentPreview() } })) {
                NativeDocumentPreview(model:model)
            }
            .sheet(isPresented:Binding(get:{ model.pollAttachmentOwner == nil && model.searchImageOwner == nil && model.imageViewerPost != nil },set:{ if !$0,model.pollAttachmentOwner == nil,model.searchImageOwner == nil { model.closeImageViewer() } })) {
                NativeImageViewer(model:model,didJumpToSource:{ dismiss() })
            }
    }
    @ViewBuilder private func row(_ post: ChatPost) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.top,spacing:14) {
                if kind == .files {
                    if post.file_props?.is_image == true {
                        Button { model.openLibraryImage(post, context:library.posts,hasMore:library.hasMore,loadMore:library.imageGalleryLoader()) } label: {
                            NativeLibraryThumbnail(post:post,model:model)
                        }.buttonStyle(.plain).accessibilityLabel("View image: " + model.attachmentName(post))
                    } else {
                        Image(systemName:"doc.fill").font(.system(size:24)).foregroundColor(NativeChatColors.green)
                            .frame(width:72,height:64).background(NativeChatColors.elevated).clipShape(RoundedRectangle(cornerRadius:8))
                    }
                }
                VStack(alignment:.leading,spacing:6) {
                    if kind == .files { Text(model.attachmentName(post)).font(.system(size:14,weight:.semibold)).textSelection(.enabled) }
                    HStack {
                        Text(model.names[post.creator_id] ?? "User \(post.creator_id)")
                        Text("·")
                        Text(model.formattedDate(post.date))
                        if post.isReply { Text("· Thread reply") }
                    }.font(.system(size:11)).foregroundColor(NativeChatColors.muted)
                    if !post.message.isEmpty { NativeMessageText(post:post,model:model).font(.system(size:13)) }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack(spacing:12) {
                if model.canPreviewDocument(post) { Button(NativeDocumentKind.forFilename(model.attachmentName(post))?.isMedia == true ? "Play" : "Preview") { model.openDocumentPreview(post,playMedia:true) } }
                Button("Show in conversation") {
                    model.closeImageViewer(); dismiss()
                    model.navigateToMessage(channelID:channelID,postID:post.id,threadID:post.isReply ? post.thread_id : nil)
                }
                Spacer()
                if kind == .files {
                    if model.downloading.contains(post.id) {
                        ProgressView().controlSize(.small)
                        Button("Cancel save") { model.cancelDownload(postID:post.id) }
                    } else {
                        Button("Save…") { Task { await model.saveAttachment(post) } }
                        Button("Save & open…") { Task { await model.saveAttachment(post,openAfterSaving:{ NSWorkspace.shared.open($0) }) } }
                    }
                }
            }.font(.system(size:12)).buttonStyle(NativeToolbarButtonStyle())
        }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(NativeChatColors.separator))
            .accessibilityElement(children: .contain).accessibilityIdentifier("conversation-library-post-\(post.id)")
    }
    private func load(more:Bool = false) {
        guard model.canBrowseConversationContent(channelID), model.canRead(channelID) else { library.clear(); return }
        let options = fileOptions, kind = kind, model = model, channelID = channelID
        library.load(kind:kind,query:query,channelID:channelID,more:more,fileOptions:kind == .files ? options : nil,accountGeneration:model.accountGeneration) { text,offset,filters in
            if kind == .files { return try await model.conversationFiles(channelID:channelID,query:text,offset:offset,options:options) }
            return try await model.searchMessages(query:text,channelID:channelID,offset:offset,filters:filters)
        }
    }
}

private struct NativeLibraryThumbnail: View {
    let post: ChatPost
    @ObservedObject var model: NativeChatPreviewModel
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            NativeChatColors.elevated
            if let image { NativeInlineImageView(image:image,label:"Image attachment: " + model.attachmentName(post)) }
            else { Image(systemName:"photo").foregroundColor(NativeChatColors.muted) }
        }.frame(width:88,height:72).clipShape(RoundedRectangle(cornerRadius:8))
            .task(id:post.id) { image = await model.thumbnail(for:post) }
            .onDisappear { image = nil }
    }
}
