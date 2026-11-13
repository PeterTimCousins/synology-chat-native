import SwiftUI

struct NativeProfileEditorView:View {
    @ObservedObject var model:NativeChatPreviewModel
    var initialNickname: String? = nil
    var onSaved: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot:ChatProfileEditSnapshot?
    @State private var nickname = ""
    @State private var description = ""
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var confirmDiscard = false
    @State private var closeAfterDiscard = false
    @State private var saving = false
    private var dirty:Bool { guard let snapshot else { return false };return nickname != snapshot.nickname || description != snapshot.description }
    private var validation:String? {
        guard let snapshot,dirty else {return nil}
        var draft = ChatProfileTextDraft(snapshot);draft.nickname = nickname;draft.description = description
        do {_ = try draft.patch(from:snapshot);return nil} catch {return error.localizedDescription}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"person.crop.circle").font(.system(size:22)).foregroundColor(NativeChatColors.green)
                Text("Edit profile").font(.system(size:20,weight:.bold));Spacer()
                Button("Refresh") { requestCloseOrRefresh(close:false) }.disabled(busy)
                Button("Done") { requestCloseOrRefresh(close:true) }.disabled(busy).keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if let snapshot {
                        let user = model.directory.first { $0.user_id == snapshot.userID }
                        let previewName = nickname.trimmingCharacters(in:.whitespacesAndNewlines)
                        HStack(spacing:14) {
                            NativeUserAvatar(avatars:model.avatars,user:user,name:previewName.isEmpty ? user?.username ?? "Your account" : previewName,size:48)
                            VStack(alignment:.leading,spacing:4) {
                                Text(previewName.isEmpty ? user?.username ?? "Your account" : previewName).font(.system(size:17,weight:.semibold)).lineLimit(2)
                                if let username = user?.username,!username.isEmpty { Text("@"+username).font(.callout).foregroundColor(NativeChatColors.muted) }
                            }
                            Spacer()
                        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(NativeChatColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
                        VStack(alignment:.leading,spacing:10) {
                            HStack {
                                Text("Display name").font(.callout.weight(.semibold));Spacer()
                                Text("\(nickname.utf16.count) / 255").font(.caption.monospacedDigit()).foregroundColor(nickname.utf16.count > 255 ? .orange : NativeChatColors.muted)
                                    .accessibilityLabel("Display name: \(nickname.utf16.count) of 255 characters")
                            }
                            TextField("Account name",text:$nickname).textFieldStyle(.plain).font(.callout).padding(12)
                                .background(NativeChatColors.canvas).clipShape(RoundedRectangle(cornerRadius:8))
                                .overlay(RoundedRectangle(cornerRadius:8).stroke(NativeChatColors.separator))
                                .accessibilityLabel("Display name").disabled(busy || !snapshot.policy.allows("nickname"))
                            Text(snapshot.policy.allows("nickname") ? "Leave this empty to use your account name." : "Your administrator manages your display name.")
                                .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                            HStack {
                                Text("Description").font(.callout.weight(.semibold));Spacer()
                                Text("\(description.utf16.count) / 256").font(.caption.monospacedDigit()).foregroundColor(description.utf16.count > 256 ? .orange : NativeChatColors.muted)
                                    .accessibilityLabel("Description: \(description.utf16.count) of 256 characters")
                            }.padding(.top,10)
                            TextEditor(text:$description).font(.callout).scrollContentBackground(.hidden).padding(8).frame(height:116)
                                .background(NativeChatColors.canvas).clipShape(RoundedRectangle(cornerRadius:8))
                                .overlay(RoundedRectangle(cornerRadius:8).stroke(NativeChatColors.separator))
                                .accessibilityLabel("Profile description").disabled(busy || !snapshot.policy.allows("description"))
                            if !snapshot.policy.allows("description") { Text("Your administrator manages your description.").font(.caption).foregroundColor(NativeChatColors.muted) }
                            Text("Saved to your Synology Chat profile and visible to other people in Chat.")
                                .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                        }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
                            .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
                        if let validation { Text(validation).font(.callout).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
                    }
                    if busy {
                        HStack(spacing:10) {
                            ProgressView().controlSize(.small)
                            Text(saving ? "Saving profile…" : "Checking profile…").font(.callout)
                            Spacer()
                            Button("Stop waiting") { request = UUID();task?.cancel();busy = false;failure = "Stopped waiting. Refresh to check your profile before saving again." }.buttonStyle(NativeToolbarButtonStyle())
                        }
                    }
                    if let failure { Text(failure).font(.callout).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                    if model.profileEditingNeedsRefresh { Label("Refresh before saving another profile change.",systemImage:"exclamationmark.circle").font(.callout).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
                }.padding(20)
            }
            Divider().overlay(NativeChatColors.separator)
            HStack {
                Button("Discard changes") { if let snapshot { nickname = snapshot.nickname;description = snapshot.description;failure = nil } }
                    .buttonStyle(NativeToolbarButtonStyle()).disabled(!dirty || busy)
                Spacer()
                Button("Save profile") { run(save:true) }.buttonStyle(NativeSendButtonStyle())
                    .disabled(!dirty || busy || snapshot == nil || model.profileEditingNeedsRefresh || validation != nil)
            }.padding(20)
        }.frame(width:600,height:660).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .interactiveDismissDisabled(busy || dirty)
            .confirmationDialog("Discard unsaved profile changes?",isPresented:$confirmDiscard,titleVisibility:.visible) {
                Button(closeAfterDiscard ? "Discard and close" : "Discard and refresh",role:.destructive) { if closeAfterDiscard { dismiss() } else { run() } }
                Button("Keep editing",role:.cancel) { }
            }
            .onAppear { epoch = model.accountGeneration;model.conversationLibraryVisible = true;run() }
            .onDisappear { task?.cancel();model.conversationLibraryVisible = false }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
    }
    private func requestCloseOrRefresh(close:Bool) {
        if dirty { closeAfterDiscard = close;confirmDiscard = true }
        else if close { dismiss() } else { run() }
    }
    private func run(save:Bool = false) {
        guard !busy else { return };busy = true;saving = save;failure = nil;let key = UUID();request = key
        let name = nickname,desc = description
        let prefillNickname = !save && snapshot == nil
        task = Task { @MainActor in
            defer { if request == key { busy = false;saving = false } }
            do {
                let value:ChatProfileEditSnapshot
                if save,let snapshot { var draft = ChatProfileTextDraft(snapshot);draft.nickname = name;draft.description = desc;value = try await model.saveProfileText(draft,original:snapshot) }
                else { value = try await model.loadEditableProfile() }
                try Task.checkCancellation();guard request == key else { return };snapshot = value;nickname = prefillNickname ? initialNickname ?? value.nickname : value.nickname;description = value.description
                if save { onSaved?() }
            } catch is CancellationError { }
            catch { if request == key { failure = error.localizedDescription } }
        }
    }
}
