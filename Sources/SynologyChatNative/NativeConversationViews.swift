import SwiftUI

struct NativeNewConversationView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ChatQuickSwitchSnapshot?
    @State private var query = ""
    @State private var selected: Set<Int64> = []
    @State private var working = false
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var confirm = false
    @State private var encrypted = false
    @State private var epoch = -1
    #if DEBUG
    static func renderFixture(model:NativeChatPreviewModel,snapshot:ChatQuickSwitchSnapshot,selected:Set<Int64>,encrypted:Bool)->Self {
        var view = Self(model:model);view._snapshot = State(initialValue:snapshot);view._selected = State(initialValue:selected);view._encrypted = State(initialValue:encrypted);return view
    }
    #endif
    private var people: [ChatUser] {
        (snapshot?.users ?? []).filter {
            $0.user_id != model.userID && $0.canStartConversation &&
            ChatNameFormat.matches($0,query:query)
        }.sorted { model.displayName($0).localizedCaseInsensitiveCompare(model.displayName($1)) == .orderedAscending }
    }
    private var selectedNames: String {
        (snapshot?.users ?? []).filter { selected.contains($0.user_id) }.map { model.displayName($0) }.sorted().joined(separator: ", ")
    }
    private var selectedPeople:[ChatUser] { (snapshot?.users ?? []).filter { selected.contains($0.user_id) }.sorted { model.displayName($0).localizedCaseInsensitiveCompare(model.displayName($1)) == .orderedAscending } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing:10) {
                Image(systemName:"bubble.left.and.bubble.right").font(.system(size:22,weight:.medium)).foregroundColor(NativeChatColors.green)
                Text("New conversation").font(.title2.weight(.semibold));Spacer()
                Button { load() } label:{ Image(systemName:"arrow.clockwise") }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Refresh people and conversations").help("Refresh people and conversations").disabled(loading || working)
            }
            Text("Choose people to talk with. Existing conversations open where you left off.").foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
            Toggle("Encrypted conversation",isOn:$encrypted).toggleStyle(.checkbox).disabled(working || loading || !model.encryptionUnlocked || !model.hasEncryptionKeyPair)
            if !model.encryptionUnlocked || !model.hasEncryptionKeyPair {
                Text("Set up and unlock encryption in account settings to start an encrypted conversation.").font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
            } else if encrypted { Text("Everyone selected must have encryption keys. Existing encrypted conversations are reused.").font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true) }
            HStack(spacing:8) {
                Image(systemName:"magnifyingglass").foregroundColor(NativeChatColors.muted)
                TextField("Find a person",text:$query).textFieldStyle(.plain).accessibilityLabel("Find a person")
            }.padding(10).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(NativeChatColors.separator,lineWidth:1)).disabled(loading || working)
            Group {
                if selectedPeople.isEmpty { HStack { Text("Select one or more people").font(.caption).foregroundColor(NativeChatColors.muted);Spacer() } }
                else {
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:8) {
                            ForEach(selectedPeople,id:\.user_id) { user in
                                HStack(spacing:6) {
                                    NativeUserAvatar(avatars:model.avatars,user:user,name:model.displayName(user),size:22)
                                    Text(model.displayName(user)).font(.system(size:12,weight:.medium)).lineLimit(1).frame(maxWidth:150)
                                    Button { selected.remove(user.user_id);confirm = false } label:{ Image(systemName:"xmark").font(.system(size:10,weight:.bold)) }.buttonStyle(.plain).accessibilityLabel("Remove \(model.displayName(user)) from selected people")
                                }.padding(.horizontal,9).padding(.vertical,6).background(NativeChatColors.selected).clipShape(Capsule()).help(model.displayName(user))
                            }
                        }
                    }
                }
            }.frame(height:40).disabled(loading || working)
            if loading { ProgressView("Loading people and conversations…") }
            List(people, id: \.user_id) { user in
                Toggle(isOn: Binding(get: { selected.contains(user.user_id) }, set: { value in
                    if value { selected.insert(user.user_id) } else { selected.remove(user.user_id) }
                })) {
                    HStack(spacing:10) {
                        NativeUserAvatar(avatars:model.avatars,user:user,name:model.displayName(user),size:34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.displayName(user)).font(.system(size:14,weight:.medium))
                            if let username = model.additionalName(user) { Text(username).font(.caption).foregroundColor(NativeChatColors.muted) }
                            if encrypted && !ChatEncryptedChannelInvitation.hasUsablePublicKey(user) { Label("Encryption is not set up",systemImage:"lock.slash").font(.caption).foregroundColor(NativeChatColors.muted) }
                        }
                    }.padding(.vertical, 5)
                }.toggleStyle(.checkbox).disabled(encrypted && !ChatEncryptedChannelInvitation.hasUsablePublicKey(user))
                    .listRowSeparator(.hidden).listRowInsets(EdgeInsets(top:4,leading:12,bottom:4,trailing:12)).listRowBackground(selected.contains(user.user_id) ? NativeChatColors.selected.opacity(0.55) : Color.clear)
            }.scrollContentBackground(.hidden).disabled(loading || working)
                .background(NativeChatColors.sidebar).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { if people.isEmpty && !loading { Text(query.isEmpty ? "No people available" : "No matching people").foregroundColor(NativeChatColors.muted).allowsHitTesting(false) } }
            if let recovery = model.conversationStartRecoveryError { Text(recovery).font(.caption).foregroundColor(.orange) }
            if !model.pendingConversationStarts.isEmpty { Text("An earlier start needs verification. Refresh checks for its result without sending another request.").font(.caption).foregroundColor(.orange) }
            if encrypted,let failure = model.encryptedConversationRecoveryError { Text(failure).font(.caption).foregroundColor(.orange) }
            if encrypted,!model.pendingEncryptedConversationStarts.isEmpty { Text("An encrypted start needs review. Close this window and use Pending actions before trying again.").font(.caption).foregroundColor(.orange) }
            if let error { Text(error).font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            Divider().overlay(NativeChatColors.separator)
            HStack {
                Text("\(selected.count) selected").font(.caption).foregroundColor(NativeChatColors.muted); Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }.buttonStyle(NativeToolbarButtonStyle()).keyboardShortcut(.cancelAction)
                Button(working ? "Opening…" : "Open conversation") { review() }.buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || snapshot == nil || loading || working || !model.canInteract || model.channelManagementBusy || model.quickSwitcherBusy || encrypted && (!model.pendingEncryptedConversationStarts.isEmpty || model.encryptedConversationRecoveryError != nil))
            }
        }.padding(24).frame(width: 540, height: 680).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .interactiveDismissDisabled(working)
            .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; load() }
            .onDisappear { task?.cancel(); model.conversationLibraryVisible = false }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of: model.connected) { if !$0 { dismiss() } }
            .onChange(of:encrypted) { _ in confirm = false;if encrypted { selected.formIntersection(Set((snapshot?.users ?? []).filter(ChatEncryptedChannelInvitation.hasUsablePublicKey).map(\.user_id))) } }
            .onChange(of:model.encryptionUnlocked) { if !$0 && encrypted { confirm = false;task?.cancel();dismiss() } }
            .confirmationDialog(encrypted ? "Start an encrypted conversation?" : "Start a conversation?", isPresented: $confirm, titleVisibility: .visible) {
                Button(encrypted ? "Start encrypted conversation" : "Start conversation") { open() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Start a conversation with " + selectedNames + "? No message will be sent.") }
    }
    private func review() {
        guard let snapshot, !selected.isEmpty, !working, !loading else { return }; error = nil
        do {
            if encrypted {
                guard model.encryptionUnlocked else { throw ChatTransferError(message:"Unlock encryption before starting an encrypted conversation.") }
                guard model.encryptedConversationRecoveryError == nil,model.pendingEncryptedConversationStarts.isEmpty else { throw ChatTransferError(message:"Check Pending actions before starting another encrypted conversation.") }
                if try model.existingEncryptedConversation(members:selected.union([snapshot.ownerID]),snapshot:snapshot) != nil { open() }
                else { guard snapshot.canStartConversations else { throw ChatAPIError.connection };confirm = true }
                return
            }
            if try model.existingConversation(members: selected.union([snapshot.ownerID]), snapshot: snapshot) != nil { open() }
            else {
                guard snapshot.canStartConversations, model.conversationStartRecoveryError == nil else { throw ChatTransferError(message: "New conversations are currently unavailable. Existing conversations can still open.") }
                let intent = ChatConversationStartIntent(members: selected.union([snapshot.ownerID]))
                guard model.pendingConversationStarts[intent.id] == nil else { throw ChatTransferError(message: "This start needs verification. Refresh before trying again.") }
                confirm = true
            }
        } catch { self.error = message(error) }
    }
    private func open() {
        guard let snapshot else { return }; let peers = selected,isEncrypted = encrypted; working = true; error = nil
        task = Task { @MainActor in
            defer { working = false }
            do {
                if isEncrypted { try await model.startEncryptedConversation(with:peers,reviewed:snapshot) }
                else { try await model.startConversation(with:peers,reviewed:snapshot) }
                try Task.checkCancellation();dismiss()
            }
            catch is CancellationError { dismiss() }
            catch { self.error = message(error) }
        }
    }
    private func load() {
        guard !working, !loading else { return }; loading = true; error = nil;confirm = false
        task = Task { @MainActor in
            defer { loading = false }
            do {
                let result = try await model.loadQuickSwitcher(); try Task.checkCancellation()
                snapshot = result; selected.formIntersection(Set(result.users.filter { $0.canStartConversation && $0.user_id != result.ownerID && (!encrypted || ChatEncryptedChannelInvitation.hasUsablePublicKey($0)) }.map(\.user_id)))
            } catch is CancellationError { }
            catch { self.error = message(error) }
        }
    }
    private func message(_ error: Error) -> String {
        (error as? ChatTransferError)?.errorDescription ?? (error as? ChatAPIError)?.errorDescription ?? "Could not verify the conversation. Refresh before trying again."
    }
}

struct NativeConversationMembersView: View {
    @ObservedObject var model: NativeChatPreviewModel
    let channel: ChatChannel
    @State private var epoch:Int
    @Environment(\.dismiss) private var dismiss
    @State private var members: [ChatUser] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showAddMembers = false
    @State private var showPendingInvitations = false
    @State private var pendingRemoval: ChatUser?
    @State private var showRemoval = false
    @State private var changing = false

    init(model:NativeChatPreviewModel,channel:ChatChannel) { self.model = model;self.channel = channel;_epoch = State(initialValue:model.accountGeneration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Conversation members").font(.title2.weight(.semibold))
                    Text(model.title(channel)).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(changing)
            }
            if loading { ProgressView("Loading members…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error {
                VStack(spacing: 12) {
                    Text(error).foregroundColor(.orange)
                    Button("Try again") { Task { await load() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("\(members.count) \(members.count == 1 ? "member" : "members")").font(.caption).foregroundColor(NativeChatColors.muted)
                ScrollView {
                  LazyVStack(spacing: 0) {
                   ForEach(members, id: \.user_id) { user in
                    HStack {
                        NativeUserIdentity(model:model,userID:user.user_id,size:36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.displayName(user)).fontWeight(.medium)
                            if let username = model.additionalName(user) {
                                Text(username).font(.caption).foregroundColor(NativeChatColors.muted)
                            }
                        }
                        Spacer()
                        if user.user_id == model.userID { Text("You").font(.caption).foregroundColor(NativeChatColors.green) }
                        if model.canRemoveMember(user, channel: channel) {
                            Button("Remove", role: .destructive) { pendingRemoval = user; showRemoval = true }
                                .buttonStyle(.borderless).accessibilityLabel("Remove " + model.displayName(user)).disabled(changing)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 10).accessibilityElement(children: .contain)
                   }
                  }
                }.background(NativeChatColors.sidebar)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !loading, model.pendingInvitations[channel.id] != nil || model.invitationRecoveryError != nil {
                Button("Review pending invitation") { showPendingInvitations = true }.disabled(changing)
            } else if !loading, model.canInviteMembers(channel) {
                Button("Add people") { showAddMembers = true }.disabled(changing)
            } else if !loading,channel.encrypted,!model.canRead(channel.id) {
                Text("Unlock this encrypted conversation to add people.").font(.caption).foregroundColor(NativeChatColors.muted)
            }
        }.padding(24).frame(width: 460, height: 460).background(NativeChatColors.canvas)
            .foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .task { guard epoch == model.accountGeneration else { dismiss();return };await model.refreshChannelPermissions();await load() }
            .onChange(of:model.accountGeneration) { if $0 != epoch { pendingRemoval = nil;dismiss() } }
            .onChange(of:model.connected) { if !$0 { pendingRemoval = nil;dismiss() } }
            .interactiveDismissDisabled(changing)
            .sheet(isPresented: $showAddMembers, onDismiss: { Task { await load() } }) {
                NativeAddMembersView(model: model, channel: channel, existing: Set(members.map(\.user_id)))
            }
            .sheet(isPresented:$showPendingInvitations,onDismiss:{ Task { await load() } }) { NativePendingChannelActionsView(model:model) }
            .alert("Remove member?", isPresented: $showRemoval, presenting: pendingRemoval) { user in
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
                Button("Remove", role: .destructive) {
                    guard epoch == model.accountGeneration else { dismiss();return }
                    changing = true
                    Task {
                        defer { changing = false; pendingRemoval = nil }
                        do { try await model.removeMember(user.user_id, channelID: channel.id); await load() }
                        catch is CancellationError { dismiss() }
                        catch { self.error = "Removal could not be confirmed. Refresh the member list before trying again." }
                    }
                }
            } message: { user in Text("Remove \(model.displayName(user)) from \(model.title(channel))?") }
    }

    private func load() async {
        guard epoch == model.accountGeneration,model.connected else { return }
        loading = true; error = nil
        defer { loading = false }
        do { let value = try await model.conversationMembers(channelID:channel.id);try Task.checkCancellation();guard epoch == model.accountGeneration else { throw CancellationError() };members = value }
        catch is CancellationError { }
        catch { self.error = "Could not load the members of this conversation." }
    }
}
