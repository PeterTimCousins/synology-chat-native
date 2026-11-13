import SwiftUI

struct NativeChannelInvitationRecoveryView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let intent:ChatChannelInvitationIntent
    @State private var epoch:Int
    @Environment(\.dismiss) private var dismiss
    @State private var task:Task<Void,Never>?
    @State private var busy = false
    @State private var clearing = false
    @State private var notice:String?
    init(model:NativeChatPreviewModel,intent:ChatChannelInvitationIntent) { self.model = model;self.intent = intent;_epoch = State(initialValue:model.accountGeneration) }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Label("Invitation needs review",systemImage:"person.badge.plus").font(.title2.bold());Spacer();Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(model.channels.first(where:{ $0.id == intent.channelID }).map { model.title($0) } ?? "Channel \(intent.channelID)").font(.headline)
            Text("\(intent.members.count) \(intent.members.count == 1 ? "person" : "people") · Started \(Date(timeIntervalSince1970:intent.createdAt).formatted(date:.abbreviated,time:.shortened))").foregroundColor(NativeChatColors.muted)
            Text("Check status reads the current member list without sending invitations. If every selected person has joined, the warning can be cleared automatically.").fixedSize(horizontal:false,vertical:true)
            if let notice { Text(notice).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true).textSelection(.enabled) }
            if let error = model.invitationRecoveryError { Text(error).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
            HStack { if busy { ProgressView().controlSize(.small) };Spacer();Button("Check status") {
                busy = true;notice = nil
                task = Task { @MainActor in
                    defer { busy = false }
                    do { try await model.checkInvitationStatus(intent,expectedGeneration:epoch);try Task.checkCancellation();notice = "All selected people are confirmed members. No invitation was repeated." }
                    catch { if !Task.isCancelled { notice = error.localizedDescription } }
                }
            }.buttonStyle(NativeSendButtonStyle()).disabled(busy || model.channelManagementBusy || model.pendingInvitations[intent.channelID] != intent) }
            Button("I checked the member list; clear this warning…") { clearing = true }.buttonStyle(NativeToolbarButtonStyle())
                .disabled(busy || model.channelManagementBusy || model.invitationRecoveryError != nil || model.pendingInvitations[intent.channelID] != intent)
        }.padding(24).frame(width:560).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .alert("Clear this invitation warning?",isPresented:$clearing) {
                Button("Cancel",role:.cancel) { }
                Button("Clear warning") { do { try model.acknowledgeInvitationOutcome(intent,expectedGeneration:epoch);dismiss() } catch { notice = error.localizedDescription } }
            } message: { Text("This only removes the local warning. It does not add or remove anyone. Another invitation requires a separate manual action and could repeat an unconfirmed request.") }
            .onDisappear { task?.cancel() }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
    }
}
