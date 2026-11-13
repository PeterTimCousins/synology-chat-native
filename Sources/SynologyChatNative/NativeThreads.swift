import SwiftUI

struct NativeThreadEntry: Identifiable {
    let root: ChatPost
    let latest: ChatPost?
    var id: Int64 { root.id }
    var activity: Double { max(root.update_at ?? root.create_at, latest?.create_at ?? 0) }
}

/// Thread_list is scoped to one channel. Aggregate independent pages without changing the active chat.
@MainActor final class NativeThreadsStore: ObservableObject {
    @Published private(set) var entries: [NativeThreadEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var failures: [Int64:String] = [:]
    @Published private(set) var hasMore = false
    private var offsets: [Int64:Int] = [:]
    private var remaining: Set<Int64> = []
    private var revision = UUID()
    private(set) var task: Task<Void,Never>?
    typealias Loader = (Int64,Int) async throws -> ChatThreadCollectionPage
    func clear() {
        task?.cancel();task = nil;revision = UUID()
        entries = [];offsets = [:];remaining = [];failures = [:];hasMore = false;loading = false
    }
    func load(channelIDs:[Int64],more:Bool = false,using loader:@escaping Loader) {
        if !more { clear();remaining = Set(channelIDs.filter { $0 > 0 }) }
        guard !loading else { return }
        let ids = Array(Set(channelIDs)).filter { remaining.contains($0) }.sorted()
        guard !ids.isEmpty else { return }
        let key = UUID();revision = key;loading = true
        task = Task {
            defer { if revision == key { loading = false;hasMore = !remaining.isEmpty;task = nil } }
            for id in ids {
                guard !Task.isCancelled, revision == key else { return }
                let next = offsets[id] ?? 0
                do {
                    let page = try await loader(id,next)
                    guard !Task.isCancelled, revision == key else { return }
                    failures[id] = nil
                    var map = Dictionary(entries.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
                    for root in page.search_results where root.channel_id == id && !root.isReply && (root.delete_at ?? 0) == 0 {
                        let latest = page.related_posts.filter {
                            $0.channel_id == id && $0.isReply && $0.thread_id == root.id && ($0.delete_at ?? 0) == 0
                        }.max { $0.id < $1.id }
                        map[root.id] = NativeThreadEntry(root:root,latest:latest)
                    }
                    entries = map.values.sorted { $0.activity == $1.activity ? $0.id > $1.id : $0.activity > $1.activity }
                    offsets[id] = next + page.search_results.count
                    if page.search_results.count < 25 || page.total.map({ offsets[id]! >= $0 }) == true { remaining.remove(id) }
                } catch {
                    guard !Task.isCancelled, revision == key else { return }
                    failures[id] = (error as? LocalizedError)?.errorDescription ?? "Could not load this conversation’s threads."
                }
            }
        }
    }
}

struct NativeThreadsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @StateObject private var store = NativeThreadsStore()
    @Environment(\.dismiss) private var dismiss
    @State private var channelID: Int64 = 0
    @State private var unreadOnly = false
    @State private var actionFailure: String?
    @State private var updating = false
    private var eligibleIDs:[Int64] {
        if channelID > 0 { return [channelID] }
        return model.channels.filter { $0.subscribes?.isEmpty != true }.map(\.id)
    }
    private var visible:[NativeThreadEntry] {
        store.entries.filter { !unreadOnly || unread($0.root) > 0 }
    }
    private func unread(_ root:ChatPost) -> Int {
        model.channels.first(where:{ $0.id == root.channel_id })?.unread_thread?[String(root.id)] ?? 0
    }
    private var scopeTitle:String { channelID == 0 ? "All conversations" : model.channels.first(where:{ $0.id == channelID }).map(model.title) ?? "Conversation" }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"text.bubble.fill").font(.system(size:20)).foregroundColor(NativeChatColors.green)
                VStack(alignment:.leading,spacing:3) {
                    Text("Threads").font(.system(size:19,weight:.bold))
                    Text("Conversations you’re following").font(.callout).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button { load() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh threads").disabled(updating)
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close threads").keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            HStack {
                Menu {
                    Button("All conversations") { channelID = 0 }
                    Divider()
                    ForEach(model.channels) { channel in Button(model.title(channel)) { channelID = channel.id } }
                } label: { Text(scopeTitle) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Threads conversation filter")
                    .padding(8).background(NativeChatColors.elevated).clipShape(RoundedRectangle(cornerRadius:7)).disabled(updating)
                Spacer()
                Toggle("Unread only",isOn:$unreadOnly).toggleStyle(.checkbox).font(.callout)
            }.padding(.horizontal,20).padding(.bottom,16)
            Divider().overlay(NativeChatColors.separator)
            if let actionFailure { Text(actionFailure).font(.callout).foregroundColor(.orange).padding(20) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    if !store.failures.isEmpty {
                        Text("Could not load threads from \(store.failures.count) " + (store.failures.count == 1 ? "conversation." : "conversations."))
                            .font(.callout).foregroundColor(.orange)
                        Button("Retry failed conversations") { load(more:true) }.disabled(store.loading || updating)
                    }
                    if visible.isEmpty && !store.loading && store.failures.isEmpty {
                        VStack(spacing:10) {
                            Image(systemName:"text.bubble").font(.system(size:28))
                            Text(unreadOnly ? "No unread threads in the loaded results." : "No threads to catch up on.")
                            if !unreadOnly { Text("Reply to a message or follow a thread to keep it here.").font(.callout) }
                        }.foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity).padding(.vertical,60)
                    }
                    ForEach(visible) { entry in threadRow(entry) }
                    if store.hasMore && !store.loading { Button("Load more threads") { load(more:true) }.disabled(updating).frame(maxWidth:.infinity) }
                    if store.loading { ProgressView("Loading threads…").frame(maxWidth:.infinity).padding(20) }
                }.padding(20)
            }
        }.frame(width:740,height:680).background(NativeChatColors.canvas)
            .foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .onAppear { model.conversationLibraryVisible = true;load() }
            .onChange(of:channelID) { _ in load() }
            .onDisappear { store.clear();model.conversationLibraryVisible = false }
    }
    private func threadRow(_ entry:NativeThreadEntry) -> some View {
        let root = entry.root
        let channel = model.channels.first { $0.id == root.channel_id }
        return VStack(alignment:.leading,spacing:12) {
            HStack {
                Label(channel.map(model.title) ?? "Unavailable conversation",systemImage:channel?.encrypted == true ? "lock" : "bubble.left.and.bubble.right")
                Spacer()
                if unread(root) > 0 { Text("\(unread(root)) unread").foregroundColor(NativeChatColors.green).fontWeight(.semibold) }
            }.font(.system(size:11)).foregroundColor(NativeChatColors.muted)
            message(root)
            if let latest = entry.latest {
                HStack(alignment:.top,spacing:12) {
                    RoundedRectangle(cornerRadius:2).fill(NativeChatColors.selected).frame(width:3)
                    VStack(alignment:.leading,spacing:6) {
                        Text("LATEST REPLY").font(.system(size:9,weight:.bold)).tracking(0.7).foregroundColor(NativeChatColors.muted)
                        message(latest)
                    }
                }.fixedSize(horizontal:false,vertical:true)
            }
            HStack {
                Button(NativeLocalizedStrings.count("Open thread · %lld replies",Int64(root.comment_count ?? 0))) {
                    dismiss()
                    model.navigateToMessage(channelID:root.channel_id,postID:entry.latest?.id ?? root.id,threadID:root.id)
                }.disabled(channel == nil || updating)
                Spacer()
                Button("Unfollow") {
                    updating = true;actionFailure = nil
                    Task {
                        if await model.setThreadSubscription(root,enabled:false) { load() }
                        else { actionFailure = model.error ?? "Could not unfollow this thread. Refresh and try again." }
                        updating = false
                    }
                }.disabled(updating || !model.canAct(on:root) || model.followsThread(root) == nil)
                    .help("Stop following this thread in your collection")
            }.buttonStyle(NativeToolbarButtonStyle()).font(.system(size:12))
        }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(NativeChatColors.separator))
    }
    @ViewBuilder private func message(_ post:ChatPost) -> some View {
        if model.channels.contains(where:{ $0.id == post.channel_id }) {
            HStack(spacing:7) {
                NativeUserIdentity(model:model,userID:post.creator_id,size:22)
                Text(model.names[post.creator_id] ?? "User \(post.creator_id)").font(.system(size:12,weight:.semibold))
                Text(model.formattedDate(post.date)).font(.system(size:10)).foregroundColor(NativeChatColors.muted)
            }
            if model.canRead(post.channel_id) {
                if post.type == "sticker", let name = model.stickerName(post) { NativeStickerImage(assets:model.stickers,name:name,size:90) }
                else if !post.message.isEmpty { NativeMessageText(post:post,model:model).font(.system(size:13)).lineLimit(4) }
                if post.type == "file" { Label(model.attachmentName(post),systemImage:"doc").font(.callout) }
            } else { Label("Unlock this conversation to read the thread.",systemImage:"lock").font(.callout).foregroundColor(NativeChatColors.muted) }
        }
    }
    private func load(more:Bool = false) {
        actionFailure = nil
        store.load(channelIDs:eligibleIDs,more:more) { id,offset in try await model.threadCollection(channelID:id,offset:offset) }
    }
}
