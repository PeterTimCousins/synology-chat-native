import SwiftUI

struct NativeChannelAlertsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    let channelID: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var source: ChatChannelAlertsSnapshot?
    @State private var draft: ChatChannelAlertsDraft?
    @State private var busy = false
    @State private var saving = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var discard: String?
    private var dirty: Bool { guard let source, let draft else { return false }; return draft != .init(source.settings) }
    private var valid: Bool { guard let source, let draft, let patch = try? draft.patch(from: source.settings, channel: source.channel) else { return false }; return !patch.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Conversation notifications").font(.title2.bold()); Spacer(); Button("Refresh") { requestAction("refresh") }.disabled(busy || model.channelAlertsBusy); Button("Done") { requestAction("close") }.keyboardShortcut(.cancelAction).disabled(busy) }
            if let source, let draft {
                Text(model.title(source.channel)).font(.headline)
                Text("These modes apply to your account in this conversation. Global snooze and macOS notification permissions still apply.").font(.callout).foregroundColor(NativeChatColors.muted)
                VStack(alignment: .leading, spacing: 16) {
                    modePicker("Desktop notifications", value: Binding(get: { self.draft?.desktop ?? draft.desktop }, set: { self.draft?.desktop = $0 }), original: source.settings.notification_desktop, channel: source.channel)
                    modePicker("Mobile notifications", value: Binding(get: { self.draft?.mobile ?? draft.mobile }, set: { self.draft?.mobile = $0 }), original: source.settings.notification_mobile, channel: source.channel)
                }.disabled(busy || model.channelAlertsBusy || model.channelAlertsNeedRefresh.contains(channelID))
                Text("Mobile notifications use the setting saved on Synology Chat.").font(.caption).foregroundColor(NativeChatColors.muted)
            }
            if busy { ProgressView(saving ? "Saving conversation notifications…" : "Loading conversation notifications…") }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            if model.channelAlertsNeedRefresh.contains(channelID) { Text("Refresh to verify the server before saving again.").font(.callout).foregroundColor(.orange) }
            HStack {
                if busy { Button("Stop waiting") { request = UUID(); task?.cancel(); busy = false; failure = "Stopped waiting. Refresh to check the server before continuing." } }
                Spacer()
                Button("Cancel") { requestAction("close") }.disabled(busy)
                Button("Save changes") { run(save: true) }.keyboardShortcut(.return, modifiers: .command).disabled(busy || model.channelAlertsBusy || !valid || model.channelAlertsNeedRefresh.contains(channelID))
            }
        }.padding(24).frame(width: 650).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .interactiveDismissDisabled(busy || dirty)
            .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; run() }
            .onDisappear { task?.cancel(); model.conversationLibraryVisible = false }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of: model.connected) { if !$0 { dismiss() } }
            .onChange(of: model.selection) { if $0 != channelID { dismiss() } }
            .alert("Discard notification edits?", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }),presenting:discard) { action in
                Button("Keep editing", role: .cancel) { discard = nil }
                Button("Discard edits", role: .destructive) { discard = nil; if action == "refresh" { run() } else { dismiss() } }
            } message: { _ in Text("Your unsaved local edits will be discarded.") }
    }
    private func modePicker(_ title: String, value: Binding<String>, original: String, channel: ChatChannel) -> some View {
        let choices = ChatChannelAlertMode.choices(channel)
        return Picker(title, selection: value) {
            ForEach(choices, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            if !choices.contains(where: { $0.rawValue == original }) { Text(ChatChannelAlertMode.title(original)).tag(original) }
        }.pickerStyle(.menu)
    }
    private func requestAction(_ action: String) { if dirty { discard = action } else if action == "refresh" { run() } else { dismiss() } }
    private func run(save: Bool = false) {
        guard !busy else { return }; busy = true; saving = save; failure = nil; let token = UUID(); request = token
        task = Task { @MainActor in
            defer { if request == token { busy = false; saving = false } }
            do {
                let updated: ChatChannelAlertsSnapshot
                if save, let source, let draft { updated = try await model.saveChannelAlerts(original: source, draft: draft) }
                else { updated = try await model.loadChannelAlerts(channelID: channelID) }
                try Task.checkCancellation(); guard request == token else { return }
                source = updated; draft = .init(updated.settings)
            } catch is CancellationError { }
            catch { if request == token { failure = (error as? ChatPreferenceUpdateFailure)?.message ?? (error as? ChatTransferError)?.message ?? "Could not verify these notification settings. Refresh before trying again." } }
        }
    }
}
