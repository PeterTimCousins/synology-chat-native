import SwiftUI

struct NativeManualPresenceView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot:ChatManualPresenceSnapshot?
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"person.crop.circle").font(.system(size:22)).foregroundColor(NativeChatColors.green)
                Text("Availability").font(.system(size:20,weight:.bold));Spacer()
                Button("Refresh") { run() }.accessibilityLabel("Refresh availability").disabled(busy)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            VStack(alignment:.leading,spacing:16) {
                if let snapshot {
                    VStack(alignment:.leading,spacing:14) {
                        HStack(spacing:12) {
                            Image(systemName:snapshot.away ? "moon.fill" : "circle.fill")
                                .font(.system(size:18)).foregroundColor(snapshot.away ? .orange : NativeChatColors.green)
                                .frame(width:40,height:40).background(NativeChatColors.elevated).clipShape(RoundedRectangle(cornerRadius:10))
                                .accessibilityHidden(true)
                            Text(snapshot.away ? "You appear away" : "Automatic availability").font(.headline)
                        }
                        Text(snapshot.away ? "You stay away until you turn this off, even while using Chat. You can still send and receive messages." : "Your activity and connection determine your availability. Set yourself away to keep appearing away while you use Chat.")
                            .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                        Divider().overlay(NativeChatColors.separator)
                        Text("This setting is saved on Synology Chat. It does not pause notifications or disconnect your account.")
                            .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                        .background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
                        .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
                    if model.manualAway != snapshot.away {
                        Label("Availability changed elsewhere. Refresh to see the current setting.",systemImage:"exclamationmark.circle")
                            .font(.callout).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
                    }
                }
                if busy {
                    HStack(spacing:10) {
                        ProgressView().controlSize(.small)
                        Text("Checking availability…").font(.callout)
                        Spacer()
                        Button("Stop waiting") { request = UUID();task?.cancel();busy = false;failure = "Stopped waiting. Refresh to check the server before continuing." }.buttonStyle(NativeToolbarButtonStyle())
                    }
                }
                if let failure { Text(failure).font(.callout).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                if model.manualPresenceNeedsRefresh {
                    Label("Refresh before making another availability change.",systemImage:"exclamationmark.circle")
                        .font(.callout).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
                }
            }.padding(20)
            if let snapshot {
                Divider().overlay(NativeChatColors.separator)
                HStack {
                    Spacer()
                    Button(snapshot.away ? "Use automatic availability" : "Set yourself away") { run(away:!snapshot.away) }
                        .buttonStyle(NativeSendButtonStyle())
                        .disabled(busy || model.manualPresenceNeedsRefresh || model.manualAway != snapshot.away)
                }.padding(20)
            }
        }.frame(width:600).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy)
            .onAppear { epoch = model.accountGeneration;model.conversationLibraryVisible = true;run() }
            .onDisappear { task?.cancel();model.conversationLibraryVisible = false }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
    }
    private func run(away:Bool? = nil) {
        guard !busy else { return };busy = true;failure = nil;let key = UUID();request = key
        task = Task { @MainActor in
            defer { if request == key { busy = false } }
            do {
                let value:ChatManualPresenceSnapshot
                if let away,let snapshot { value = try await model.setManualPresence(away:away,original:snapshot) }
                else { value = try await model.loadManualPresence() }
                try Task.checkCancellation();guard request == key else { return };snapshot = value
            } catch is CancellationError { }
            catch { if request == key { failure = error.localizedDescription } }
        }
    }
}
