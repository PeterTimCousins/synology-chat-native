import SwiftUI

struct NativeCreateChannelView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var epoch:Int
    @State private var name = ""
    @State private var purpose = ""
    @State private var kind = ChatNamedChannelKind.private
    @State private var encrypted = false
    @State private var working = false
    @State private var error:String?
    @State private var creationNeedsCheck = false
    @State private var showRecovery = false
    @State private var task:Task<Void,Never>?
    init(model:NativeChatPreviewModel) { self.model = model;_epoch = State(initialValue:model.accountGeneration) }
#if DEBUG
    static func renderFixture(model:NativeChatPreviewModel,encrypted:Bool) -> Self {
        var view = Self(model:model);view._name = State(initialValue:"Project-planning");view._purpose = State(initialValue:"Planning and decisions for the team");view._encrypted = State(initialValue:encrypted);return view
    }
#endif
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Image(systemName:"number.square.fill").font(.title).foregroundColor(NativeChatColors.green);Text("New channel").font(.title2.bold()) }
            TextField("Channel name",text:$name).textFieldStyle(.roundedBorder).accessibilityLabel("Channel name")
            Text("Up to 64 characters. Use hyphens instead of spaces.").font(.caption).foregroundColor(NativeChatColors.muted)
            TextField("Purpose (optional)",text:$purpose).textFieldStyle(.roundedBorder).accessibilityLabel("Channel purpose")
            Picker("Visibility",selection:$kind) {
                Text("Private").tag(ChatNamedChannelKind.private)
                if model.channelPermissions?.allows("channel_public") == true { Text("Public").tag(ChatNamedChannelKind.public) }
            }.pickerStyle(.segmented)
            Text(kind == .private ? "Only invited people can access this channel. Add people after creating it." : "People on this Synology can discover and join this channel.")
                .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
            if kind == .private {
                VStack(alignment:.leading,spacing:8) {
                    Toggle("Encrypt this channel",isOn:$encrypted).disabled(!model.canCreateEncryptedChannel)
                    Text(model.encryptionUnlocked ? "Uses your existing encryption keys. Invited people must also have Chat encryption set up." : "Unlock your existing Chat encryption keys to enable this option.")
                        .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                }.padding(14).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            }
            if !model.pendingEncryptedCreations.isEmpty || model.encryptedCreationRecoveryError != nil {
                HStack { Text("Encrypted channel creation needs review.").font(.callout).foregroundColor(.orange);Spacer();Button("Pending actions") { showRecovery = true } }
            }
            if let error { Text(error).foregroundColor(.orange).font(.callout).fixedSize(horizontal:false,vertical:true) }
            if !name.isEmpty,let validation = ChatNamedChannelInput.validationError(name:name,purpose:purpose) { Text(validation).foregroundColor(.orange).font(.callout).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Spacer();Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Creating…" : "Create channel") { submit() }.buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(working || creationNeedsCheck || ChatNamedChannelInput.validationError(name:name,purpose:purpose) != nil || !model.canCreateNamedChannel || (encrypted && !model.canCreateEncryptedChannel))
            }
        }.padding(24).frame(width:520).disabled(working).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .task { guard epoch == model.accountGeneration else { return };await model.refreshChannelPermissions() }
            .onDisappear { task?.cancel() }
            .onChange(of:kind) { if $0 == .public { encrypted = false } }
            .onChange(of:model.accountGeneration) { if $0 != epoch { task?.cancel();dismiss() } }
            .onChange(of:model.connected) { if !$0 { task?.cancel();dismiss() } }
            .onChange(of:model.encryptionUnlocked) { if !$0 && encrypted { task?.cancel();if working { dismiss() } else { encrypted = false } } }
            .sheet(isPresented:$showRecovery) { NativePendingChannelActionsView(model:model) }
            .interactiveDismissDisabled(working)
    }
    private func submit() {
        guard epoch == model.accountGeneration,!working else { return };working = true;error = nil
        let requestedName = name,requestedPurpose = purpose,requestedKind = kind,requestedEncryption = encrypted
        task = Task { @MainActor in
            defer { working = false }
            do {
                guard epoch == model.accountGeneration else { throw CancellationError() }
                try await model.createChannel(name:requestedName,purpose:requestedPurpose,kind:requestedKind,encrypted:requestedEncryption)
                try Task.checkCancellation();dismiss()
            } catch is CancellationError { dismiss() }
            catch {
                creationNeedsCheck = requestedEncryption ? !model.pendingEncryptedCreations.isEmpty : error is ChatChannelCreatedError || error is ChatChannelCreationUnconfirmedError
                self.error = error.localizedDescription
            }
        }
    }
}

struct NativeAddMembersView: View {
    @ObservedObject var model:NativeChatPreviewModel
    let channel:ChatChannel
    let existing:Set<Int64>
    @State private var epoch:Int
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected:Set<Int64> = []
    @State private var snapshot:ChatChannelInvitationSnapshot?
    @State private var working = false
    @State private var loading = false
    @State private var error:String?
    @State private var task:Task<Void,Never>?
    @State private var showRecovery = false
    init(model:NativeChatPreviewModel,channel:ChatChannel,existing:Set<Int64>) {
        self.model = model;self.channel = channel;self.existing = existing;_epoch = State(initialValue:model.accountGeneration)
    }
#if DEBUG
    private var renderingSnapshot = false
    static func renderFixture(model:NativeChatPreviewModel,snapshot:ChatChannelInvitationSnapshot,selected:Set<Int64>,error:String?) -> Self {
        var view = Self(model:model,channel:snapshot.channel,existing:snapshot.members)
        view._snapshot = State(initialValue:snapshot);view._selected = State(initialValue:selected);view._error = State(initialValue:error);view.renderingSnapshot = true
        return view
    }
#endif
    private var people:[ChatUser] {
        (snapshot?.users ?? []).filter { $0.canStartConversation && !(snapshot?.members ?? existing).contains($0.user_id) && ChatNameFormat.matches($0,query:query) }
            .sorted { model.displayName($0).localizedCaseInsensitiveCompare(model.displayName($1)) == .orderedAscending }
    }
    private var needsReview:Bool { model.pendingInvitations[channel.id] != nil || model.invitationRecoveryError != nil }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:5) { Text("Add people").font(.title2.bold());Text(model.title(channel)).foregroundColor(NativeChatColors.muted) }
                Spacer();Image(systemName:channel.encrypted ? "lock.shield" : "person.badge.plus").font(.title2).foregroundColor(NativeChatColors.green)
            }
            if channel.encrypted { Text("Only people who have set up Chat encryption can be added.").font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true) }
            TextField("Find a person",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a person")
            ScrollView {
                LazyVStack(spacing:4) {
                    if loading { ProgressView("Loading people…").padding(20) }
                    ForEach(people,id:\.user_id) { user in
                        let eligible = !channel.encrypted || ChatEncryptedChannelInvitation.hasUsablePublicKey(user)
                        Toggle(isOn:Binding(get:{ selected.contains(user.user_id) },set:{ if $0 { selected.insert(user.user_id) } else { selected.remove(user.user_id) } })) {
                            HStack(spacing:10) {
                                NativeChatAvatar(name:model.displayName(user),size:32)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(model.displayName(user)).fontWeight(.medium)
                                    if let extra = model.additionalName(user) { Text(extra).font(.caption).foregroundColor(NativeChatColors.muted) }
                                    if !eligible { Text("Needs Chat encryption keys").font(.caption).foregroundColor(NativeChatColors.muted) }
                                }
                                Spacer()
                            }.padding(.vertical,5)
                        }.toggleStyle(.checkbox).disabled(!eligible || working || loading)
                            .padding(.horizontal,10).background(selected.contains(user.user_id) ? NativeChatColors.selected : Color.clear).clipShape(RoundedRectangle(cornerRadius:8))
                    }
                    if !loading,people.isEmpty { Text("No matching people").foregroundColor(NativeChatColors.muted).padding(20) }
                }.padding(8)
            }.frame(maxHeight:.infinity).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            if needsReview { HStack { Text("An invitation needs review.").font(.callout).foregroundColor(.orange);Spacer();Button("Pending actions") { showRecovery = true } } }
            if let error { Text(error).foregroundColor(.orange).font(.callout).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Button("Refresh people") { load() }.buttonStyle(NativeToolbarButtonStyle()).disabled(loading || working || model.channelManagementBusy)
                Text("\(selected.count) selected").font(.caption).foregroundColor(NativeChatColors.muted)
                Spacer();Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Adding…" : "Add people") { submit() }.buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || snapshot == nil || loading || needsReview || !model.canInviteMembers(channel))
            }
        }.padding(24).frame(width:540,height:560).disabled(working)
            .background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .onAppear { load() }.onDisappear { task?.cancel() }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.encryptionUnlocked) { if channel.encrypted && !$0 { task?.cancel();dismiss() } }
            .sheet(isPresented:$showRecovery) { NativePendingChannelActionsView(model:model) }
            .interactiveDismissDisabled(working)
    }
    private func load() {
#if DEBUG
        if renderingSnapshot { return }
#endif
        guard !loading,!working else { return };loading = true;selected = [];snapshot = nil;error = nil
        task = Task { @MainActor in
            defer { loading = false }
            do {
                let value = try await model.invitationSnapshot(channelID:channel.id);try Task.checkCancellation()
                guard value.accountGeneration == epoch else { throw CancellationError() }
                guard channel.sameInvitationScope(as:value.channel),channel.name == value.channel.name else { throw ChatTransferError(message:"This channel changed. Close this window and reopen Add people to review it.") }
                snapshot = value
            }
            catch is CancellationError { dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func submit() {
        guard let snapshot,!working,!loading else { return };working = true;error = nil
        let ids = selected
        task = Task { @MainActor in
            defer { working = false }
            do { try await model.inviteMembers(ids,channelID:channel.id,reviewed:snapshot);try Task.checkCancellation();dismiss() }
            catch is CancellationError { dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
