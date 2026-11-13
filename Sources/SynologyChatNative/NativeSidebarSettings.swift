import SwiftUI

struct NativeSidebarSettingsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: ChatSidebarSettingsSnapshot?
    @State private var pinUnread = false
    @State private var busy = false
    @State private var failure: String?
    @State private var task: Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var discard: String?
    private var dirty: Bool { source.map { $0.settings.sidebar_pinning_unread != pinUnread } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Sidebar preferences").font(.title2.bold()); Spacer(); Button("Refresh") { requestAction("refresh") }.disabled(busy || model.sidebarSettingsBusy); Button("Done") { requestAction("close") }.disabled(busy).keyboardShortcut(.cancelAction) }
            if source != nil {
                Toggle("Pin unread conversations", isOn: $pinUnread).disabled(busy || model.sidebarSettingsBusy || model.sidebarSettingsNeedRefresh)
                Text("Show conversations with unread messages or followed replies in an Unread section above Starred. The selected conversation stays in its section while you read it.").font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
                Text("This preference is saved for your Synology Chat account. Starred conversations and your current selection are preserved.").font(.caption).foregroundColor(NativeChatColors.muted)
            }
            if busy { ProgressView("Checking sidebar preferences…") }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange) }
            if model.sidebarSettingsNeedRefresh { Text("Refresh to check the server before saving again.").font(.callout).foregroundColor(.orange) }
            HStack {
                if busy { Button("Stop waiting") { request = UUID(); task?.cancel(); busy = false; failure = "Stopped waiting. Refresh to verify the result before continuing." } }
                Spacer(); Button("Cancel") { requestAction("close") }.disabled(busy)
                Button("Save changes") { run(save:true) }.keyboardShortcut(.return, modifiers:.command).disabled(!dirty || busy || model.sidebarSettingsBusy || model.sidebarSettingsNeedRefresh)
            }
        }.padding(24).frame(width:600).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy || dirty)
            .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; run() }
            .onDisappear { task?.cancel(); model.conversationLibraryVisible = false }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .alert("Discard sidebar edits?",isPresented:Binding(get:{discard != nil},set:{if !$0{discard = nil}}),presenting:discard) { action in
                Button("Keep editing",role:.cancel){discard = nil}
                Button("Discard edits",role:.destructive){discard = nil;if action == "refresh"{run()}else{dismiss()}}
            } message:{ _ in Text("Your unsaved local edits will be discarded.")}
    }
    private func requestAction(_ action:String){if dirty{discard = action}else if action == "refresh"{run()}else{dismiss()}}
    private func run(save:Bool = false){
        guard !busy else{return};busy = true;failure = nil;let token = UUID();request = token
        task = Task { @MainActor in
            defer{if request == token{busy = false}}
            do{
                let updated:ChatSidebarSettingsSnapshot
                if save,let source{updated = try await model.saveSidebarSettings(original:source,pinUnread:pinUnread)}else{updated = try await model.loadSidebarSettings()}
                try Task.checkCancellation();guard request == token else{return};source = updated;pinUnread = updated.settings.sidebar_pinning_unread
            }catch is CancellationError{}catch{if request == token{failure = (error as? ChatPreferenceUpdateFailure)?.message ?? "Could not verify the sidebar preference. Refresh before trying again."}}
        }
    }
}
