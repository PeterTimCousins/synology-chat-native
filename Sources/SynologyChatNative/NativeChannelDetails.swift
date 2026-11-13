import SwiftUI

struct NativeChannelDetailsView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channelID:Int64
    @Environment(\.dismiss) private var dismiss
    @State private var original:ChatChannel?
    @State private var draft:ChatChannelDetailsDraft?
    @State private var busy = false
    @State private var saving = false
    @State private var needsRefresh = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var requestID = UUID()
    @State private var session = -1
    @State private var discard:String?
    @State private var showMembers = false
    @State private var showHistoryArchive = false
    @State private var showGuests = false
    private var dirty:Bool { guard let original,let draft else { return false };return draft.name != original.name || draft.purpose != (original.purpose ?? "") }
    private var editable:Bool { original.map(model.hasChannelDetailsEditingAuthority) == true }
    private var validChange:Bool { guard let original,let draft,let patch = try? draft.patch(relativeTo:original) else { return false };return !patch.isEmpty }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("Channel details").font(.system(size:20,weight:.bold))
                Spacer()
                Button { requestRefresh() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh channel details").disabled(busy || model.channelManagementBusy)
                Button { requestClose() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close channel details").keyboardShortcut(.cancelAction).disabled(busy || model.channelManagementBusy)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if let original { details(original) }
                    else if !busy { Text("Refresh to load this channel’s details.").foregroundColor(NativeChatColors.muted) }
                    if busy { ProgressView(saving ? "Saving channel details…" : "Loading channel details…") }
                    if let failure { Text(failure).font(.callout).foregroundColor(.orange).textSelection(.enabled) }
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            }
            Divider().overlay(NativeChatColors.separator)
            HStack {
                if busy { Button("Stop waiting") { stopWaiting() }.buttonStyle(NativeToolbarButtonStyle()) }
                Spacer()
                Button(editable ? "Cancel" : "Done") { requestClose() }.buttonStyle(NativeToolbarButtonStyle()).disabled(busy || model.channelManagementBusy)
                if editable || needsRefresh {
                    Button("Save changes") { save() }.buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.return,modifiers:.command)
                        .disabled(busy || needsRefresh || !editable || !validChange || original.map(model.canEditChannelDetails) != true)
                }
            }.padding(20)
        }.frame(width:620,height:570).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy || dirty)
            .onAppear { session = model.accountGeneration;model.conversationLibraryVisible = true;load() }
            .onDisappear { requestID = UUID();task?.cancel();task = nil;model.conversationLibraryVisible = false }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
            .sheet(isPresented:$showHistoryArchive) { NativeHistoryArchiveActionView(model:model,channelID:channelID) }
            .sheet(isPresented:$showGuests,onDismiss:{ model.conversationLibraryVisible = true }) { NativeChannelGuestsView(model:model,channelID:channelID) }
            .sheet(isPresented:$showMembers,onDismiss:{ model.conversationLibraryVisible = true }) { if let original { NativeConversationMembersView(model:model,channel:original) } }
            .alert("Discard your channel edits?",isPresented:Binding(get:{ discard != nil },set:{ if !$0 { discard = nil } }),presenting:discard) { action in
                Button("Keep editing",role:.cancel) { discard = nil }
                Button("Discard edits",role:.destructive) { discard = nil;if action == "refresh" { load() } else { dismiss() } }
            } message: { _ in Text(needsRefresh ? "Closing discards your local edits. Check refreshed server details before retrying an interrupted save." : "Your unsaved local edits will be discarded.") }
    }
    @ViewBuilder private func details(_ channel:ChatChannel) -> some View {
        HStack(alignment:.top,spacing:14) {
            Image(systemName:channel.encrypted || channel.type == "private" ? "lock" : "number").font(.system(size:26)).foregroundColor(NativeChatColors.green).frame(width:42,height:42).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            VStack(alignment:.leading,spacing:6) {
                Text(model.title(channel)).font(.system(size:22,weight:.bold))
                Text(channel.encrypted ? "Encrypted channel" : channel.type == "private" ? "Private channel" : "Public channel").font(.callout).foregroundColor(NativeChatColors.muted)
                if let creator = channel.creator_id,let name = model.names[creator] { Text("Created by " + name).font(.caption).foregroundColor(NativeChatColors.muted) }
            }
            Spacer()
            Button { showMembers = true } label: { Label(channel.total_member_count.map { "\($0) \($0 == 1 ? "member" : "members")" } ?? "Members",systemImage:"person.2") }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("View channel members").disabled(busy)
        }
        if channel.supportsGuestBrowser && model.channelPermissions?.allows("guest_manage") == true {
            Button("View channel guests…") { showGuests = true }.buttonStyle(NativeToolbarButtonStyle()).disabled(busy || dirty)
        }
        if channel.supportsHistoryArchiving && (model.channelPermissions?.allows("channel_archive") == true || model.pendingHistoryArchives[channel.id] != nil) {
            Button(model.pendingHistoryArchives[channel.id] == nil ? "Archive channel history…" : "Check archive status…") { showHistoryArchive = true }
                .buttonStyle(NativeToolbarButtonStyle()).disabled(busy || dirty || model.channelManagementBusy)
                .help(dirty ? "Save or discard your channel edits first." : "Move current history to a read-only archive; keep the channel open.")
        }
        if editable,let draft {
            VStack(alignment:.leading,spacing:7) {
                Text("Name").font(.callout.weight(.semibold))
                TextField("Channel name",text:Binding(get:{ self.draft?.name ?? "" },set:{ self.draft?.name = $0 })).textFieldStyle(.roundedBorder).accessibilityLabel("Edit channel name")
                Text("Up to 64 characters. Use hyphens instead of spaces.").font(.caption).foregroundColor(NativeChatColors.muted)
            }.disabled(busy)
            VStack(alignment:.leading,spacing:7) {
                HStack { Text("Purpose").font(.callout.weight(.semibold));Spacer();Text("\(draft.purpose.utf16.count) / 256").font(.caption).foregroundColor(draft.purpose.utf16.count > 256 ? .orange : NativeChatColors.muted) }
                TextEditor(text:Binding(get:{ self.draft?.purpose ?? "" },set:{ self.draft?.purpose = $0 })).font(.body).scrollContentBackground(.hidden).padding(8).frame(height:110).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityLabel("Edit channel purpose")
            }.disabled(busy)
            if dirty { if let failure = validation(channel,draft:draft) { Text(failure).font(.caption).foregroundColor(.orange) } }
        } else {
            VStack(alignment:.leading,spacing:8) { Text("Purpose").font(.callout.weight(.semibold));Text((channel.purpose ?? "").isEmpty ? "No purpose set." : channel.purpose!).foregroundColor(NativeChatColors.muted).textSelection(.enabled) }
            Text(channel.id <= 2 ? "Administrator access is required to edit this channel." : "Editing is unavailable with the current permissions or connection.").font(.caption).foregroundColor(NativeChatColors.muted)
        }
    }
    private func validation(_ channel:ChatChannel,draft:ChatChannelDetailsDraft) -> String? { do { _ = try draft.patch(relativeTo:channel);return nil } catch { return error.localizedDescription } }
    private func requestClose() { if dirty { discard = "close" } else { dismiss() } }
    private func requestRefresh() { if dirty { discard = "refresh" } else { load() } }
    private func stopWaiting() {
        requestID = UUID();task?.cancel();busy = false
        if saving { needsRefresh = true;failure = "The server may have saved this change. Refresh details before trying again." }
        else { failure = "Loading stopped. Refresh to try again." }
    }
    private func load() {
        task?.cancel();let key = UUID();requestID = key;busy = true;saving = false;failure = nil
        task = Task { @MainActor in
            defer { if requestID == key { busy = false } }
            do { let channel = try await model.loadChannelDetails(channelID:channelID);try Task.checkCancellation();guard requestID == key else { return };original = channel;draft = .init(channel:channel);needsRefresh = false }
            catch is CancellationError { }
            catch { if requestID == key { failure = error.localizedDescription } }
        }
    }
    private func save() {
        guard let original,let draft else { return };let key = UUID();requestID = key;busy = true;saving = true;failure = nil
        task = Task { @MainActor in
            defer { if requestID == key { busy = false;saving = false } }
            do { _ = try await model.saveChannelDetails(original:original,draft:draft);try Task.checkCancellation();guard requestID == key else { return };dismiss() }
            catch is CancellationError { }
            catch { if requestID == key { failure = error.localizedDescription;needsRefresh = true } }
        }
    }
}
