import SwiftUI

struct ChatForwardOrigin:Decodable,Equatable {
    let origin_channel_id:Int64
    let origin_post_id:Int64
    let origin_thread_id:Int64?
    let origin_user_id:Int64
    let origin_create_at:Double?
    let type:String?
    var isReminder:Bool { type == "reminder" && origin_channel_id > 0 && origin_post_id > 0 && origin_user_id > 0 }
    var navigationThreadID:Int64? { origin_thread_id.flatMap{$0 > 0 && $0 != origin_post_id ? $0 : nil} }
    var originDate:Date? { origin_create_at.flatMap{$0.isFinite && $0 >= 0 && $0 < 253402300800000 ? Date(timeIntervalSince1970:$0/1000) : nil} }
}

enum ChatForwardPolicy {
    static func supports(_ post:ChatPost,channel:ChatChannel?,users:[ChatUser]) -> Bool {
        channel.map { destination($0) } == true && post.props?.encrypted != true && (post.delete_at ?? 0) == 0
            && ["normal","file","sticker"].contains(post.type)
            && users.first(where:{ $0.user_id == post.creator_id }).map { $0.type == "human" } == true
    }
    static func destination(_ channel:ChatChannel) -> Bool {
        channel.id > 0 && !channel.encrypted && channel.is_closed != true && channel.is_joined != false
            && (channel.hide_global_at ?? 0) == 0 && ["public","private","anonymous","synobot"].contains(channel.type)
    }
    static func destination(_ entry:ChatQuickSwitchEntry) -> Bool {
        if let channel = entry.channel { return destination(channel) }
        return entry.person?.canStartConversation == true
    }
    static func sameDestination(_ original:ChatQuickSwitchEntry,_ current:ChatQuickSwitchEntry) -> Bool {
        guard destination(original),destination(current),let a = original.channel,let b = current.channel else { return false }
        return a.id == b.id && a.type == b.type && a.name == b.name && a.encrypted == b.encrypted
            && (a.type != "anonymous" && a.type != "synobot" || original.memberIDs == current.memberIDs)
    }
    static func sameContent(_ a:ChatPost,_ b:ChatPost) -> Bool {
        a.id == b.id && a.channel_id == b.channel_id && a.creator_id == b.creator_id && (a.thread_id ?? 0) == (b.thread_id ?? 0)
            && a.type == b.type && a.message == b.message && a.update_at == b.update_at && a.file_props?.name == b.file_props?.name
            && a.file_props?.size == b.file_props?.size && a.props?.forward == b.props?.forward
    }
    static func receipt(_ value:ChatPost,source:ChatPost,channelID:Int64,userID:Int64,previous:Set<Int64>) -> Bool {
        value.id != source.id && !previous.contains(value.id) && value.channel_id == channelID
            && value.creator_id == userID && !value.isReply && (value.delete_at ?? 0) == 0
            && value.type == source.type && value.message == source.message
            && value.file_props?.name == source.file_props?.name && value.file_props?.size == source.file_props?.size
            && value.props?.forward?.origin_post_id == source.id
            && value.props?.forward?.origin_channel_id == source.channel_id
            && value.props?.forward?.origin_user_id == source.creator_id
    }
}

struct NativeForwardFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}

struct NativeForwardMessageView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let post:ChatPost
    @Environment(\.dismiss) private var dismiss
    @State private var selection:Set<String> = []
    @State private var snapshot:ChatQuickSwitchSnapshot?
    @State private var loading = false
    @State private var showRecovery = false
    @State private var query = ""
    @State private var busy = false
    @State private var uncertain = false
    @State private var failure:String?
    @State private var confirmed:[ChatPost] = []
    @State private var task:Task<Void,Never>?
    @State private var session = -1
#if DEBUG
    private var renderingSnapshot = false
    static func renderFixture(model:NativeChatPreviewModel,post:ChatPost,snapshot:ChatQuickSwitchSnapshot) -> Self {
        var view = Self(model:model,post:post)
        view._snapshot = State(initialValue:snapshot);view.renderingSnapshot = true
        return view
    }
#endif
    private var destinations:[ChatQuickSwitchEntry] {
        (snapshot?.entries ?? []).filter {
            ChatForwardPolicy.destination($0) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.score(query) > 0)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    private var needsReview:Bool { model.forwardRecoveryError != nil || model.pendingForwards.values.contains { $0.sourceID == post.id && $0.sourceChannelID == post.channel_id } }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label("Forward message",systemImage:"arrowshape.turn.up.right").font(.system(size:20,weight:.bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close forwarding").disabled(busy)
            }.padding(20).buttonStyle(NativeToolbarButtonStyle())
            Divider().overlay(NativeChatColors.separator)
            VStack(alignment:.leading,spacing:10) {
                Text("From \(model.names[post.creator_id] ?? "a member")").font(.caption).foregroundColor(NativeChatColors.muted)
                if post.type == "file" { Label(model.attachmentName(post),systemImage:"doc").font(.headline) }
                Text(post.type == "sticker" ? "Sticker message" : post.message).lineLimit(4).textSelection(.enabled)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12)).padding(20)
            if needsReview {
                HStack { Text("A saved forwarding operation needs review.").font(.callout).foregroundColor(.orange);Spacer();Button("Review pending actions") { showRecovery = true } }.padding(.horizontal,20).padding(.bottom,12)
            }
            if confirmed.isEmpty {
                TextField("Find a destination",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Find forwarding destination").padding(.horizontal,20).disabled(busy || uncertain)
                ScrollView {
                    LazyVStack(spacing:4) {
                        if loading { ProgressView("Loading destinations…").padding() }
                        ForEach(destinations) { entry in
                            Toggle(isOn:Binding(get:{ selection.contains(entry.id) },set:{ if $0 { selection.insert(entry.id) } else { selection.remove(entry.id) } })) {
                                HStack {
                                    NativeChatAvatar(name:entry.title,size:30)
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(entry.title)
                                        Text(entry.channel == nil ? "New direct conversation" : entry.channel?.id == post.channel_id ? "This conversation" : entry.subtitle)
                                            .font(.caption).foregroundColor(NativeChatColors.muted)
                                    }
                                    Spacer()
                                }
                            }.toggleStyle(.checkbox).padding(10).background(selection.contains(entry.id) ? NativeChatColors.selected : Color.clear).clipShape(RoundedRectangle(cornerRadius:8)).disabled(busy || uncertain || loading)
                        }
                        if !loading, destinations.isEmpty { Text("No matching destinations").foregroundColor(NativeChatColors.muted).padding() }
                    }.padding(20)
                }.frame(minHeight:180,maxHeight:.infinity)
                Text("Choose up to 20 destinations. New direct conversations start when you forward. Encrypted conversations and bots are unavailable.").font(.caption).foregroundColor(NativeChatColors.muted).padding(.horizontal,20)
            } else {
                Label("Forwarded to \(confirmed.count) \(confirmed.count == 1 ? "conversation" : "conversations")",systemImage:"checkmark.circle.fill").foregroundColor(NativeChatColors.green).padding(20)
                Spacer()
            }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).padding(.horizontal,20) }
            HStack {
                if busy { ProgressView().controlSize(.small);Button("Stop waiting") { task?.cancel();busy = false;uncertain = true;failure = "Delivery may have occurred. Check each selected conversation before forwarding again." }.buttonStyle(NativeToolbarButtonStyle()) }
                if !busy,!uncertain,confirmed.isEmpty { Button("Refresh destinations") { load() }.disabled(loading).buttonStyle(NativeToolbarButtonStyle()) }
                Spacer()
                if !confirmed.isEmpty {
                    Button("Done") { dismiss() }.buttonStyle(NativeToolbarButtonStyle())
                    if confirmed.count == 1,let first = confirmed.first {
                        Button("Open conversation") { dismiss();model.navigateToMessage(channelID:first.channel_id,postID:first.id) }.buttonStyle(NativeSendButtonStyle())
                    }
                } else if uncertain {
                    Button("Close and check conversations") { dismiss() }.buttonStyle(NativeSendButtonStyle())
                } else {
                    Button(busy ? "Forwarding…" : "Forward\(selection.isEmpty ? "" : " to \(selection.count)")") { submit() }.buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.return,modifiers:.command).disabled(busy || loading || needsReview || snapshot == nil || selection.isEmpty || selection.count > 20 || !model.canForward(post))
                }
            }.padding(20)
        }.frame(width:620,height:650).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy)
            .sheet(isPresented:$showRecovery) { NativePendingChannelActionsView(model:model) }
            .onAppear { session = model.pollSessionGeneration;model.conversationLibraryVisible = true;load() }
            .onDisappear { task?.cancel();task = nil;model.conversationLibraryVisible = false }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.pollSessionGeneration) { if $0 != session { dismiss() } }
            .onChange(of:model.selection) { if $0 != post.channel_id { dismiss() } }
            .onChange(of:model.channels) { _ in if model.channels.first(where:{ $0.id == post.channel_id })?.encrypted != false { dismiss() } }
    }
    private func load() {
#if DEBUG
        if renderingSnapshot { return }
#endif
        guard !busy,!loading,!uncertain else { return }
        loading = true;failure = nil;selection = [];snapshot = nil
        task = Task { @MainActor in
            defer { loading = false }
            do {
                let value = try await model.loadQuickSwitcher();try Task.checkCancellation()
                guard session == model.pollSessionGeneration else { return };snapshot = value
            } catch { if !Task.isCancelled { failure = "Could not load forwarding destinations. Refresh to try again." } }
        }
    }
    private func submit() {
        guard let snapshot,!busy,!loading else { return }
        busy = true;failure = nil
        let targets = selection
        task = Task { @MainActor in
            defer { busy = false }
            do { let result = try await model.forwardMessage(post,to:targets,reviewed:snapshot);try Task.checkCancellation();confirmed = result }
            catch is CancellationError { }
            catch { failure = error.localizedDescription;uncertain = (error as? NativeForwardFailure)?.uncertain ?? false }
        }
    }
}
