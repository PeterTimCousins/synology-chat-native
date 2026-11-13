import SwiftUI

struct NativeChannelBrowserView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = 0
    @State private var query = ""
    @State private var available:[ChatChannel] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var session = -1
    @State private var pendingLeave:ChatChannel?
    @State private var showingDetails:ChatChannel?
    @State private var previewing:ChatChannel?
    @State private var joinedFromPreview = false
    private var entries:[ChatChannel] { (scope == 0 ? model.channels.filter { ["public","private"].contains($0.type) } : available).filter { query.isEmpty || model.title($0).localizedCaseInsensitiveContains(query) || ($0.purpose ?? "").localizedCaseInsensitiveContains(query) } }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label("Browse channels",systemImage:"number").font(.system(size:20,weight:.bold))
                Spacer()
                Button { load() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh channel browser").disabled(busy || model.channelManagementBusy)
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close channel browser").keyboardShortcut(.cancelAction).disabled(model.channelManagementBusy)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            HStack {
                Picker("Channels",selection:$scope) { Text("Joined").tag(0);Text("Available to join").tag(1) }.pickerStyle(.segmented).frame(width:280)
                TextField("Find a channel",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a channel")
            }.padding(.horizontal,20).padding(.bottom,16)
            Divider().overlay(NativeChatColors.separator)
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).frame(maxWidth:.infinity,alignment:.leading).padding(16) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    if busy { ProgressView("Loading channels…").frame(maxWidth:.infinity).padding(24) }
                    if entries.isEmpty && !busy && loaded {
                        VStack(spacing:10) {
                            Image(systemName:"number").font(.system(size:30))
                            Text(query.isEmpty ? (scope == 0 ? "No joined channels" : "No channels available to join") : "No matching channels").font(.headline)
                            Text("Your server controls which channels are visible to you.").font(.callout)
                        }.foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity).padding(.vertical,60)
                    }
                    ForEach(entries) { channel in row(channel) }
                }.padding(20)
            }
            Text(scope == 0 ? "Leaving a private channel may require a new invitation to return." : "Only channels made available by your server appear here.").font(.caption).foregroundColor(NativeChatColors.muted).padding(20)
        }.frame(width:740,height:590).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(model.channelManagementBusy)
            .onAppear { session = model.accountGeneration;model.conversationLibraryVisible = true;load() }
            .onDisappear { request = UUID();task?.cancel();task = nil;available = [];model.conversationLibraryVisible = false }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
            .sheet(item:$previewing,onDismiss:{
                if joinedFromPreview { dismiss() } else { load() }
            }) { NativePublicChannelPreviewView(model:model,channel:$0,onJoined:{ joinedFromPreview = true }) }
            .sheet(item:$showingDetails,onDismiss:{ model.conversationLibraryVisible = true }) { NativeChannelDetailsView(model:model,channelID:$0.id) }
            .alert("Leave this channel?",isPresented:Binding(get:{ pendingLeave != nil },set:{ if !$0 { pendingLeave = nil } })) {
                Button("Stay",role:.cancel) { pendingLeave = nil }
                Button("Leave channel",role:.destructive) { if let channel = pendingLeave { leave(channel) };pendingLeave = nil }
            } message: { Text(leaveExplanation) }
    }
    private var leaveExplanation:String {
        if pendingLeave?.encrypted == true {
            let access = pendingLeave?.type == "private" ? "You will lose access to this private encrypted channel and may need another invitation to return." : "You will stop receiving messages from this encrypted channel."
            return access + " Rejoining encrypted channels currently requires Synology’s official app. Unsent encrypted drafts remain only in this session and are cleared when encryption locks."
        }
        return pendingLeave?.type == "private" ? "You will lose access to this private channel and may need another invitation to return. Your unsent draft stays on this Mac." : "You will stop receiving messages from this channel. You can look for it in Available to join later."
    }
    private func row(_ channel:ChatChannel) -> some View {
        HStack(alignment:.top,spacing:14) {
            Image(systemName:channel.encrypted || channel.type == "private" ? "lock" : "number").font(.system(size:20)).foregroundColor(NativeChatColors.muted).frame(width:30).padding(.top,2)
            VStack(alignment:.leading,spacing:7) {
                Text(model.title(channel)).font(.headline)
                if let purpose = channel.purpose,!purpose.isEmpty { Text(purpose).font(.callout).foregroundColor(NativeChatColors.muted).lineLimit(3) }
                HStack(spacing:10) {
                    Text(channel.encrypted ? "Encrypted" : channel.type == "private" ? "Private" : "Public").font(.caption)
                    if let count = channel.total_member_count,count >= 0 { Label("\(count) \(count == 1 ? "member" : "members")",systemImage:"person.2").font(.caption) }
                }.foregroundColor(NativeChatColors.muted)
                if scope == 1,channel.encrypted { Text("Joining encrypted channels is not available in this client yet.").font(.caption).foregroundColor(NativeChatColors.muted) }
            }.frame(maxWidth:.infinity,alignment:.leading)
            if scope == 0 {
                Button("Details") { showingDetails = channel }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Details for channel " + model.title(channel)).disabled(busy || model.channelManagementBusy)
                Button("Open") { guard !model.isEditingMessage else { return };model.selection = channel.id;dismiss() }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Open channel " + model.title(channel)).disabled(busy || model.channelManagementBusy || model.isEditingMessage)
                if channel.id != 1 {
                    Button("Leave") { pendingLeave = channel }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Leave channel " + model.title(channel)).disabled(busy || !model.canLeaveDiscoveredChannel(channel))
                }
            } else {
                Button("Preview") { joinedFromPreview = false;previewing = channel }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Preview channel " + model.title(channel)).disabled(busy || !model.canPreviewDiscoveredChannel(channel))
                Button("Join") { join(channel) }.buttonStyle(NativeSendButtonStyle()).accessibilityLabel("Join channel " + model.title(channel)).disabled(busy || !model.canJoinDiscoveredChannel(channel))
            }
        }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
    }
    private func load() {
        task?.cancel();let key = UUID();request = key;busy = true;failure = nil
        task = Task { @MainActor in
            defer { if request == key { busy = false } }
            do { let result = try await model.channelDiscovery();try Task.checkCancellation();guard request == key else { return };available = result;loaded = true }
            catch is CancellationError { }
            catch { if request == key { failure = "Could not refresh channels. Check the connection and try again." } }
        }
    }
    private func join(_ channel:ChatChannel) {
        busy = true;failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { try await model.joinDiscoveredChannel(channel);try Task.checkCancellation();dismiss() }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
    private func leave(_ channel:ChatChannel) {
        busy = true;failure = nil
        task = Task { @MainActor in
            do { try await model.leaveDiscoveredChannel(channel);try Task.checkCancellation();busy = false;load() }
            catch is CancellationError { busy = false }
            catch { busy = false;failure = error.localizedDescription }
        }
    }
}
