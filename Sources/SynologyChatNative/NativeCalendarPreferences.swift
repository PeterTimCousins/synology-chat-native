import SwiftUI

struct NativeCalendarPreferenceSnapshot {
    let enabled:Bool
    let accountGeneration:Int
}

struct NativeCalendarPreferencesView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot:NativeCalendarPreferenceSnapshot?
    @State private var enabled = false
    @State private var busy = false
    @State private var saving = false
    @State private var failure:String?
    @State private var request = UUID()
    @State private var task:Task<Void,Never>?
    @State private var confirmDiscard = false
    @State private var closeAfterDiscard = false
    @State private var epoch = -1
    private var dirty:Bool { snapshot.map { $0.enabled != enabled } ?? false }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"calendar").font(.system(size:22)).foregroundColor(NativeChatColors.green)
                Text("Calendar preferences").font(.system(size:20,weight:.bold));Spacer()
                Button("Refresh") { requestCloseOrRefresh(close:false) }.disabled(busy)
                Button("Done") { requestCloseOrRefresh(close:true) }.disabled(busy).keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            VStack(alignment:.leading,spacing:16) {
                VStack(alignment:.leading,spacing:12) {
                    HStack(alignment:.top,spacing:16) {
                        VStack(alignment:.leading,spacing:6) {
                            Text("Detect dates in messages").font(.callout.weight(.semibold))
                            Text("Turn dates into links you can use to create a calendar event.").font(.callout).foregroundColor(NativeChatColors.muted)
                        }
                        Spacer(minLength:10)
                        Toggle("Detect dates in messages",isOn:$enabled).labelsHidden().toggleStyle(.switch).disabled(snapshot == nil || busy)
                    }
                    Text("This preference is shared with your Synology Chat account. Creating an event still requires you to review and send it.")
                        .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
                    .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
                if busy { HStack { ProgressView().controlSize(.small);Text(saving ? "Saving preference…" : "Checking preference…");Spacer();Button("Stop waiting") { request = UUID();task?.cancel();busy = false;if saving { model.calendarSettingsNeedRefresh = true };failure = "Stopped waiting. Refresh to check the server before saving again." }.buttonStyle(NativeToolbarButtonStyle()) } }
                if let failure { Text(failure).font(.callout).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
                if model.calendarSettingsNeedRefresh { Text("Refresh before making another change.").font(.callout).foregroundColor(.orange) }
                HStack {
                    Button("Discard changes") { if let snapshot { enabled = snapshot.enabled } }.buttonStyle(NativeToolbarButtonStyle()).disabled(!dirty || busy)
                    Spacer()
                    Button("Save") { run(save:true) }.buttonStyle(NativeSendButtonStyle()).disabled(!dirty || busy || model.calendarSettingsNeedRefresh)
                }
            }.padding(20)
        }.frame(width:600).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .interactiveDismissDisabled(busy || dirty)
            .confirmationDialog("Discard unsaved calendar preferences?",isPresented:$confirmDiscard,titleVisibility:.visible) {
                Button(closeAfterDiscard ? "Discard and close" : "Discard and refresh",role:.destructive) { if closeAfterDiscard { dismiss() } else { run() } }
                Button("Keep editing",role:.cancel) {}
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
        guard !busy else { return };busy = true;saving = save;failure = nil
        let revision = UUID();request = revision;let desired = enabled
        task = Task { @MainActor in
            defer { if request == revision { busy = false;saving = false } }
            do {
                let result:NativeCalendarPreferenceSnapshot
                if save,let snapshot { result = try await model.saveCalendarDetectionPreference(desired,original:snapshot) }
                else { result = try await model.loadCalendarDetectionPreference() }
                try Task.checkCancellation();guard request == revision else { return }
                snapshot = result;enabled = result.enabled
            } catch is CancellationError {} catch { if request == revision { failure = error.localizedDescription } }
        }
    }
}
