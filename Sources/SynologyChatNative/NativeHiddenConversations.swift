import SwiftUI

struct NativeHiddenConversationsView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var session = -1
    private var hidden:[ChatChannel] { model.channels.filter { ($0.last_hide_at ?? 0) > 0 && $0.supportsOrganization(.hide) && (query.isEmpty || model.title($0).localizedCaseInsensitiveContains(query)) } }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label("Hidden conversations",systemImage:"eye.slash").font(.system(size:20,weight:.bold))
                Spacer()
                Button { refresh() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh hidden conversations").disabled(busy || model.conversationOrganizationBusy)
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close hidden conversations").keyboardShortcut(.cancelAction).disabled(model.conversationOrganizationBusy)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            TextField("Find a hidden conversation",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a hidden conversation").padding(.horizontal,20).padding(.bottom,16)
            Divider().overlay(NativeChatColors.separator)
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).frame(maxWidth:.infinity,alignment:.leading).padding(16) }
            ScrollView {
                LazyVStack(spacing:10) {
                    if busy { ProgressView("Refreshing conversations…").padding(20) }
                    if hidden.isEmpty && !busy { Text(query.isEmpty ? "No hidden conversations" : "No matching hidden conversations").foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity).padding(.vertical,60) }
                    ForEach(hidden) { channel in
                        HStack(spacing:12) {
                            NativeUserAvatar(avatars:model.avatars,user:model.sidebarUser(channel),name:model.title(channel),size:32)
                            VStack(alignment:.leading,spacing:4) {
                                Text(model.title(channel)).font(.headline)
                                Text(channel.hiddenFromSidebar(selectedID:model.selection) ? "Hidden from your sidebar" : "Visible while open or with new activity").font(.caption).foregroundColor(NativeChatColors.muted)
                            }
                            Spacer()
                            Button("Open conversation") { open(channel) }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Open " + model.title(channel))
                                .disabled(busy || model.isEditingMessage || !model.canInteract || model.conversationOrganizationBusy)
                        }.padding(14).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                    }
                }.padding(20)
            }
            Text("Open a hidden conversation to show it again. New activity can also bring it back.").font(.caption).foregroundColor(NativeChatColors.muted).padding(20)
        }.frame(width:680,height:520).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(model.conversationOrganizationBusy)
            .onAppear { session = model.accountGeneration;model.conversationLibraryVisible = true;refresh() }
            .onDisappear { task?.cancel();task = nil;model.conversationLibraryVisible = false }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
    }
    private func refresh() {
        task?.cancel();busy = true;failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { try await model.refreshConversationOrganization();try Task.checkCancellation() }
            catch is CancellationError { }
            catch { failure = "Could not refresh conversations. Try again." }
        }
    }
    private func open(_ channel:ChatChannel) {
        failure = nil
        do { try model.openHiddenConversation(channel);dismiss() }
        catch { failure = "Finish any message edit and reconnect before opening this conversation." }
    }
}
