import SwiftUI

/// Archive IDs never enter the live timeline or any live-message action.
struct NativeArchivesView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @ObservedObject private var deletions: ChatArchiveDeletionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var kind:ChatArchiveKind = .private
    @State private var names:[String] = []
    @State private var name:String?
    @State private var archives:[ChatArchive] = []
    @State private var archive:ChatArchive?
    @State private var archiveEpoch = -1
    @State private var posts:[ChatPost] = []
    @State private var threadRoot:ChatPost?
    @State private var replies:[ChatPost] = []
    @State private var repliesExhausted = false
    @State private var attachment:NativeArchiveAttachmentTarget?
    @State private var showSearch = false
    @State private var jumpID:Int64?
    @State private var query = ""
    @State private var busy = false
    @State private var exhausted = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var session = -1
    @State private var deleting: ChatArchive?
    @State private var unlockArchive: ChatArchive?
    @State private var showUnlock = false
    init(model: NativeChatPreviewModel) {
        self.model = model
        self.deletions = model.archiveDeletions
    }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label("Archive history",systemImage:"archivebox").font(.system(size:20,weight:.bold))
                Spacer()
                Button("Search & collections") { showSearch = true }.disabled(name == nil || !archives.contains(where:{ model.canReadArchive($0) }) || busy)
                Button { reload() } label:{ Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh archive history")
                Button { dismiss() } label:{ Image(systemName:"xmark") }.accessibilityLabel("Close archive history").keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Picker("Archive category",selection:$kind) { ForEach(ChatArchiveKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).padding(.horizontal,20).padding(.bottom,16)
            Divider()
            if !deletions.pending.isEmpty || deletions.recoveryError != nil {
                NativePendingArchiveDeletionsView(model: model, onResolved: reload).padding(16)
                Divider()
            }
            if let failure { Text(failure).foregroundColor(.orange).font(.callout).padding(12) }
            if busy { ProgressView("Loading archive history…").padding(10) }
            HStack(spacing:0) {
                VStack {
                    TextField("Find archived conversation",text:$query).textFieldStyle(.roundedBorder).padding(12)
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:4) {
                            ForEach(names.filter { query.isEmpty || displayName($0).localizedCaseInsensitiveContains(query) },id:\.self) { item in
                                Button { chooseName(item) } label: {
                                    Text(displayName(item)).font(.system(size:13,weight:.medium)).frame(maxWidth:.infinity,alignment:.leading).padding(10)
                                        .background(name == item ? NativeChatColors.surface : Color.clear).clipShape(RoundedRectangle(cornerRadius:8))
                                }.buttonStyle(.plain).disabled(busy)
                            }
                            if names.isEmpty && !busy { Text("No archived conversations").foregroundColor(NativeChatColors.muted).padding(16) }
                        }.padding(.horizontal,8)
                    }
                }.frame(width:230)
                Divider()
                VStack(alignment:.leading,spacing:0) {
                    if let archive {
                        HStack {
                            Button(threadRoot == nil ? "Back to archive periods" : "Back to archived conversation") {
                                cancel();failure = nil
                                if threadRoot != nil { threadRoot = nil;replies = [] } else { self.archive = nil;posts = [] }
                            }
                            Spacer()
                            deleteButton(archive)
                            VStack(alignment:.trailing,spacing:3) {
                                Text(model.archivePeriodPresentation(archive).identifier).font(.caption.weight(.medium))
                                Text(period(archive)).font(.caption).fixedSize(horizontal:false,vertical:true)
                            }.foregroundColor(NativeChatColors.muted).help(model.archivePeriodPresentation(archive).exactRange)
                        }.padding(14)
                        archiveMessages(archive)
                    } else {
                        ScrollView {
                            LazyVStack(alignment:.leading,spacing:12) {
                                if name == nil { Text("Choose an archived conversation").foregroundColor(NativeChatColors.muted).padding(24) }
                                else if archives.isEmpty && !busy { Text("No archive periods available").foregroundColor(NativeChatColors.muted).padding(24) }
                                ForEach(archives) { item in
                                    let presentation = model.archivePeriodPresentation(item)
                                    HStack(alignment: .top, spacing: 12) {
                                    Button { chooseArchive(item) } label: {
                                        VStack(alignment:.leading,spacing:8) {
                                            Text(presentation.summary).font(.headline)
                                            Text(presentation.identifier).font(.caption.weight(.medium)).foregroundColor(NativeChatColors.muted)
                                            Text(item.reasonTitle).font(.callout)
                                            Text("Archived by " + (model.names[item.props.trigger_user_id] ?? "User \(item.props.trigger_user_id)")).font(.caption).foregroundColor(NativeChatColors.muted)
                                            if !item.props.channel.encrypted && !(item.props.channel.purpose ?? "").isEmpty { Text(item.props.channel.purpose ?? "").font(.callout) }
                                            if item.props.channel.encrypted { Label("Encrypted archive",systemImage:"lock").font(.caption) }
                                        }.frame(maxWidth:.infinity,alignment:.leading).padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                                    }.buttonStyle(.plain).disabled(busy || !item.isReadable || !presentation.isAvailable).accessibilityLabel("Open " + presentation.label).help(presentation.exactRange)
                                    deleteButton(item)
                                    }
                                }
                            }.padding(18)
                        }
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            Divider()
            Text("Archived messages open read-only. Delete an archive period using its trash control. Unlock encrypted periods with your Chat encryption password.").font(.caption).foregroundColor(NativeChatColors.muted).padding(12)
        }.frame(width:940,height:650).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .onAppear { session = model.accountGeneration;model.conversationLibraryVisible = true;reload() }
            .onDisappear { cancel();model.conversationLibraryVisible = false }
            .onChange(of:kind) { _ in reload() }
            .onChange(of:model.archiveContentEpoch) { epoch in
                if archive?.props.channel.encrypted == true && archiveEpoch != epoch {
                    cancel();attachment = nil;showSearch = false;posts = [];replies = [];threadRoot = nil;archive = nil
                }
            }
            .sheet(isPresented:$showUnlock,onDismiss:{
                if let requested = unlockArchive {
                    unlockArchive = nil
                    if model.canReadArchive(requested) { chooseArchive(requested) }
                    else if model.encryptionUnlocked { failure = "Could not unlock this archive period. Its encryption key may be unavailable." }
                }
            }) { NativeEncryptionUnlockView(model:model) }
            .sheet(item:$attachment,onDismiss:{ model.conversationLibraryVisible = true }) { target in
                if let name { NativeArchiveAttachmentView(model:model,kind:kind,name:name,archive:target.archive,post:target.post,context:threadRoot.map { [$0] + replies } ?? posts) }
            }
            .sheet(isPresented:$showSearch,onDismiss:{ model.conversationLibraryVisible = true }) {
                if let name { NativeArchiveSearchView(model:model,kind:kind,name:name,scopes:archives,onOpen:openResult) }
            }
            .sheet(item: $deleting) { target in
                if let name { NativeArchiveDeletionView(model: model, archive: target, kind: kind, name: name, onDeleted: reload) }
            }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
    }
    @ViewBuilder private func deleteButton(_ value: ChatArchive) -> some View {
        if model.canReviewArchiveDeletion(kind:kind) {
        Button(role: .destructive) { deleting = value } label: { Image(systemName: "trash") }
            .buttonStyle(NativeToolbarButtonStyle())
            .accessibilityLabel("Delete " + model.archivePeriodPresentation(value).label)
            .help("Permanently delete this archive period")
            .disabled(!model.archivePeriodPresentation(value).isAvailable || busy || deletions.busy || deletions.recoveryError != nil || deletions.pending.contains(where: { $0.id == value.id }))
        }
    }
    private func archiveMessages(_ source:ChatArchive)->some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment:.leading,spacing:16) {
                if let root = threadRoot {
                    Text("Archived thread").font(.headline)
                    archivedMessage(root,source:source,isRoot:true)
                    Divider()
                    if !repliesExhausted && !replies.isEmpty { Button("Load earlier archived replies") { loadReplies(source,root:root,earlier:true) }.disabled(busy) }
                    ForEach(replies) { archivedMessage($0,source:source,isRoot:false).id($0.id) }
                    if replies.isEmpty && !busy { Text("No archived replies in this period").foregroundColor(NativeChatColors.muted) }
                } else {
                    if !exhausted && !posts.isEmpty { Button("Load earlier archived messages") { loadPosts(source,earlier:true) }.disabled(busy) }
                    if posts.isEmpty && !busy { Text("No archived messages in this period").foregroundColor(NativeChatColors.muted) }
                    ForEach(posts) { archivedMessage($0,source:source,isRoot:false).id($0.id) }
                }
            }.padding(18)
        }.onChange(of:jumpID) { value in if let value { proxy.scrollTo(value,anchor:.center) } }
        }
    }
    private func archivedMessage(_ post:ChatPost,source:ChatArchive,isRoot:Bool)->some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text(model.names[post.displayAuthorID] ?? "User \(post.displayAuthorID)").font(.headline)
                Text(model.formattedDate(post.date)).font(.caption).foregroundColor(NativeChatColors.muted)
            }
            if (post.delete_at ?? 0) > 0 { Text("Message deleted").italic() }
            else if post.type == "system" { Text(post.systemEventText(names:model.names)).foregroundColor(NativeChatColors.muted) }
            else {
                ForEach(Array(ChatMessageFormatting.blocks(model.archiveMessageText(post,archive:source)).enumerated()),id:\.offset) { item in
                    NativeFormattedMessageBlock(block:item.element,mentions:model.mentionNames,hashtagLinks:false)
                }.environment(\.openURL,OpenURLAction { _ in .discarded })
                if model.canOpenArchiveAttachment(post,archive:source) {
                    Button { attachment = .init(archive:source,post:post) } label:{ Label(model.archiveFilename(post,archive:source),systemImage:post.file_props?.is_image == true ? "photo" : "doc") }.accessibilityLabel("Open archived attachment " + model.archiveFilename(post,archive:source))
                }
                if threadRoot == nil && !isRoot && (post.comment_count ?? 0) > 0 {
                    Button(NativeLocalizedStrings.count("%lld archived replies",Int64(post.comment_count ?? 0))) {
                        threadRoot = post;replies = [];repliesExhausted = false;loadReplies(source,root:post,earlier:false)
                    }.disabled(busy).accessibilityLabel("Open archived replies to message \(post.id)")
                }
            }
        }.textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(14).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
    }
    private func openResult(_ match:ChatArchiveMatch) {
        guard model.canReadArchive(match.archive),model.archivePeriodPresentation(match.archive).isAvailable,let name else { return };let category = kind,epoch = model.archiveContentEpoch
        jumpID = nil;archive = match.archive;archiveEpoch = model.archiveContentEpoch;threadRoot = nil;posts = [];replies = []
        run { id in
            let result = try await model.archivedMessageContext(kind:category,name:name,match:match)
            try Task.checkCancellation();guard request == id else { return }
            guard model.archiveContentEpoch == epoch else { return }
            threadRoot = result.root
            if result.root != nil { replies = result.posts;repliesExhausted = false } else { posts = result.posts;exhausted = false }
            jumpID = match.post.id
        }
    }
    private func loadReplies(_ value:ChatArchive,root:ChatPost,earlier:Bool) {
        guard let name else { return };let category = kind,before = earlier ? replies.first?.id : nil,epoch = model.archiveContentEpoch
        run { id in
            let result = try await model.loadArchivePosts(kind:category,name:name,archive:value,before:before,threadID:root.id)
            try Task.checkCancellation();guard request == id else { return }
            guard model.archiveContentEpoch == epoch else { return }
            replies = ChatTimeline.merge(earlier ? replies : [],result);repliesExhausted = result.isEmpty
        }
    }
    private func displayName(_ raw:String)->String {
        guard kind == .anonymous || kind == .chatbot else { return raw }
        let ids = raw.split(separator:",").compactMap { Int64($0) }
        guard !ids.isEmpty,ids.count == raw.split(separator:",").count else { return raw }
        return ids.map { model.names[$0] ?? "User \($0)" }.sorted().joined(separator:", ")
    }
    private func period(_ item:ChatArchive)->String {
        model.archivePeriodPresentation(item).summary
    }
    private func cancel() { request = UUID();task?.cancel();task = nil;busy = false }
    private func run(_ operation:@escaping @MainActor (UUID) async throws -> Void) {
        cancel();let id = request,epoch = model.archiveContentEpoch;busy = true;failure = nil
        task = Task { @MainActor in
            defer { if request == id { busy = false } }
            do { guard model.archiveContentEpoch == epoch else { return };try await operation(id) }
            catch is CancellationError { }
            catch { if request == id { failure = "Could not load archive history. Refresh and try again." } }
        }
    }
    private func reload() {
        deletions.retryRecovery()
        name = nil;archive = nil;threadRoot = nil;replies = [];names = [];archives = [];posts = [];query = ""
        let category = kind
        run { id in let result = try await model.loadArchiveNames(kind:category);try Task.checkCancellation();guard request == id else { return };names = result.sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending } }
    }
    private func chooseName(_ value:String) {
        name = value;archive = nil;threadRoot = nil;replies = [];archives = [];posts = [];let category = kind
        run { id in let result = try await model.loadArchives(kind:category,name:value);try Task.checkCancellation();guard request == id else { return };archives = result }
    }
    private func chooseArchive(_ value:ChatArchive) {
        guard model.archivePeriodPresentation(value).isAvailable else { failure = "This archive's dates are unavailable. Refresh the archive list.";return }
        guard model.canReadArchive(value) else { unlockArchive = value;showUnlock = true;return }
        archive = value;archiveEpoch = model.archiveContentEpoch;threadRoot = nil;replies = [];posts = [];exhausted = false;loadPosts(value,earlier:false) }
    private func loadPosts(_ value:ChatArchive,earlier:Bool) {
        guard let name else { return };let category = kind,before = earlier ? posts.first?.id : nil,epoch = model.archiveContentEpoch
        run { id in
            let result = try await model.loadArchivePosts(kind:category,name:name,archive:value,before:before)
            try Task.checkCancellation();guard request == id else { return }
            guard model.archiveContentEpoch == epoch else { return }
            posts = ChatTimeline.merge(earlier ? posts : [],result);exhausted = result.isEmpty
        }
    }
}
