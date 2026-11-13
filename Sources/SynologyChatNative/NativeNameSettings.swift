import SwiftUI

struct NativeNameSettingsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: ChatNameSettingsSnapshot?
    @State private var format = ChatNameFormat.nickname
    @State private var busy = false
    @State private var saving = false
    @State private var failure: String?
    @State private var task: Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var discard: PendingAction?
    private enum PendingAction: Equatable { case refresh, close }
    private var dirty: Bool { source.map { $0.settings.prefer_user_name_format != format } ?? false }
    private var choicesDisabled: Bool { busy || model.nameSettingsBusy || model.nameSettingsNeedRefresh }

    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"person.text.rectangle").font(.system(size:22)).foregroundColor(NativeChatColors.green)
                Text("Name display").font(.system(size:20,weight:.bold))
                Spacer()
                Button("Refresh") { requestAction(.refresh) }.disabled(busy || model.nameSettingsBusy)
                Button("Done") { requestAction(.close) }.disabled(busy).keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    settingsCard("Display people by",icon:"person.2") {
                        Text("Choose which name you see in conversations and people lists.")
                            .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                        if source != nil {
                            Picker("Display people by",selection:$format) {
                                nameChoice(.nickname).tag(ChatNameFormat.nickname)
                                nameChoice(.username).tag(ChatNameFormat.username)
                            }.pickerStyle(.radioGroup).labelsHidden().disabled(choicesDisabled)
                        }
                        Text("Shared with your Synology Chat account. Saving also changes this preference in other Chat clients.")
                            .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                    }
                    if source != nil {
                        settingsCard("Preview",icon:"eye") {
                            // Keep one accessibility subtree: duplicating this
                            // preview in ViewThatFits stalled AX traversal.
                            VStack(alignment:.leading,spacing:12) {
                                previewCaption
                                previewIdentity
                            }
                            Divider().overlay(NativeChatColors.separator)
                            Text("Bots and guests keep their display names. Mentions use username handles.")
                                .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                        }
                    }
                    if busy {
                        HStack(spacing:10) {
                            ProgressView().controlSize(.small)
                            Text(saving ? "Saving name preference…" : "Checking name preference…").font(.callout)
                            Spacer(minLength:8)
                            Button("Stop waiting") {
                                request = UUID();task?.cancel();busy = false;saving = false
                                failure = "Stopped waiting. Refresh to verify the result before continuing."
                            }.buttonStyle(NativeToolbarButtonStyle())
                        }
                    }
                    if let failure {
                        Label(failure,systemImage:"exclamationmark.circle").font(.callout).foregroundColor(.orange)
                            .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    }
                    if model.nameSettingsNeedRefresh {
                        Label("Refresh to verify the server before saving again.",systemImage:"arrow.clockwise.circle")
                            .font(.callout).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
                    }
                }.padding(20)
            }
            Divider().overlay(NativeChatColors.separator)
            HStack(spacing:12) {
                Button("Discard changes") { if let source { format = source.settings.prefer_user_name_format } }
                    .buttonStyle(NativeToolbarButtonStyle()).disabled(!dirty || busy)
                Spacer(minLength:8)
                Button("Cancel") { requestAction(.close) }.buttonStyle(NativeToolbarButtonStyle()).disabled(busy)
                Button("Save changes") { run(save:true) }.buttonStyle(NativeSendButtonStyle())
                    .keyboardShortcut(.return,modifiers:.command).disabled(!dirty || choicesDisabled)
            }.padding(20)
        }.frame(width:600,height:610).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas)
            .nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy || dirty)
            .onAppear { epoch = model.accountGeneration;model.conversationLibraryVisible = true;run() }
            .onDisappear { request = UUID();task?.cancel();model.conversationLibraryVisible = false }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .alert("Discard name-display edits?",isPresented:Binding(get:{discard != nil},set:{if !$0 {discard = nil}}),presenting:discard) { action in
                Button("Keep editing",role:.cancel) { discard = nil }
                Button(action == .refresh ? "Discard and refresh" : "Discard and close",role:.destructive) {
                    discard = nil;perform(action)
                }
            } message: { _ in Text("Your unsaved local edits will be discarded.") }
    }

    private func nameChoice(_ choice:ChatNameFormat) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(choice.title).font(.callout.weight(.semibold)).foregroundColor(NativeChatColors.text)
            Text(choice == .nickname ? "Show nicknames first, with usernames as a fallback." : "Show usernames first, with nicknames as a fallback.")
                .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(format == choice ? NativeChatColors.green.opacity(0.08) : NativeChatColors.canvas)
            .clipShape(RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(format == choice ? NativeChatColors.green : NativeChatColors.separator))
            .accessibilityElement(children:.combine).accessibilityLabel(choice.title)
    }
    private var previewCaption: some View {
        VStack(alignment:.leading,spacing:4) {
            Text(format.title).font(.callout.weight(.semibold))
            Text("Example using your account").font(.caption).foregroundColor(NativeChatColors.muted)
        }
    }
    @ViewBuilder private var previewIdentity: some View {
        if let user = model.directory.first(where:{ $0.user_id == model.userID }) {
            HStack(spacing:10) {
                Image(systemName:"person.crop.circle.fill").font(.system(size:30)).foregroundColor(NativeChatColors.green)
                VStack(alignment:.leading,spacing:3) {
                    Text(format.display(user)).font(.callout.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
                    if let additional = format.additional(user) {
                        Text(additional).font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }.accessibilityElement(children:.combine).accessibilityLabel("Name preview: " + format.display(user))
        } else {
            Text("Your name preview will appear when account details are available.")
                .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func settingsCard<Content:View>(_ title:String,icon:String,@ViewBuilder content:()->Content) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Label(title,systemImage:icon).font(.callout.weight(.semibold))
            content()
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
    }
    private func requestAction(_ action:PendingAction) {
        if dirty { discard = action } else { perform(action) }
    }
    private func perform(_ action:PendingAction) {
        if action == .refresh { run() } else { dismiss() }
    }
    private func run(save:Bool = false) {
        guard !busy else { return };busy = true;saving = save;failure = nil
        let token = UUID();request = token
        let original = source,desired = format
        task = Task { @MainActor in
            defer { if request == token { busy = false;saving = false } }
            do {
                let updated:ChatNameSettingsSnapshot
                if save,let original { updated = try await model.saveNameSettings(original:original,format:desired) }
                else { updated = try await model.loadNameSettings() }
                try Task.checkCancellation();guard request == token else { return }
                source = updated;format = updated.settings.prefer_user_name_format
            } catch is CancellationError {} catch {
                if request == token { failure = (error as? ChatPreferenceUpdateFailure)?.message ?? "Could not verify the name preference. Refresh before trying again." }
            }
        }
    }
}
