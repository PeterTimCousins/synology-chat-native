import SwiftUI

struct NativePendingChannelActionsView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var closing:ChatChannel?
    @State private var archiving:ChatChannel?
    @State private var promoting:PromotionRecoveryRoute?
    @State private var forwarding:ChatForwardIntent?
    @State private var creating:ChatEncryptedCreationIntent?
    @State private var inviting:ChatChannelInvitationIntent?
    @State private var startingEncrypted:ChatEncryptedConversationIntent?
    @State private var epoch = -1
    private struct PromotionRecoveryRoute:Identifiable { let id:Int64 }
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:18) {
            HStack { Text("Pending actions").font(.title2.bold());Spacer();Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("These actions may have reached the server. They need a status check. Checking status does not repeat a request.").foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
            if let failure = model.channelActionRecoveryError {
                Text(failure).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                Button("Retry recovery") { model.retryChannelActionRecovery() }.disabled(!model.canRetryChannelActionRecovery)
            }
            if !model.hasPendingActions { Text("No unconfirmed actions.") }
            if let failure = model.encryptedConversationRecoveryError {
                Text(failure).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
                Button("Refresh encrypted conversation recovery") { try? model.refreshEncryptedConversationRecovery(expectedGeneration:epoch) }.disabled(!model.connected || model.channelManagementBusy)
            }
            ForEach(model.pendingEncryptedConversationStarts.values.sorted { $0.createdAt < $1.createdAt }) { intent in
                HStack {
                    VStack(alignment:.leading) { Text("Encrypted conversation");Text("\(intent.memberIDs.count) participants · Start needs review").font(.caption).foregroundColor(.orange) }
                    Spacer();Button("Review conversation") { startingEncrypted = intent }.disabled(model.channelManagementBusy)
                }
            }
            if let failure = model.encryptedCreationRecoveryError {
                Text(failure).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
                Button("Refresh channel creation recovery") { try? model.refreshEncryptedCreationRecovery(expectedGeneration:epoch) }.disabled(!model.connected || model.channelManagementBusy)
            }
            ForEach(model.pendingEncryptedCreations.values.sorted { $0.createdAt < $1.createdAt }) { intent in
                HStack {
                    VStack(alignment:.leading) {
                        Text(intent.channelID.map { "Encrypted channel \($0)" } ?? "Encrypted channel creation")
                        Text("Creation needs review").font(.caption).foregroundColor(.orange)
                    }
                    Spacer();Button("Review creation") { creating = intent }.disabled(model.channelManagementBusy)
                }
            }
            if let failure = model.invitationRecoveryError {
                Text(failure).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
                Button("Refresh invitation recovery") { try? model.refreshInvitationRecovery(expectedGeneration:epoch) }.disabled(!model.connected || model.channelManagementBusy)
            }
            ForEach(model.pendingInvitations.values.sorted { $0.createdAt < $1.createdAt }) { intent in
                HStack {
                    VStack(alignment:.leading) {
                        Text(model.channels.first(where:{ $0.id == intent.channelID }).map { model.title($0) } ?? "Channel \(intent.channelID)")
                        Text("Adding \(intent.members.count) \(intent.members.count == 1 ? "person" : "people") needs review").font(.caption).foregroundColor(.orange)
                    }
                    Spacer();Button("Review invitation") { inviting = intent }.disabled(model.channelManagementBusy)
                }
            }
            if let failure = model.forwardRecoveryError {
                Text(failure).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
                Button("Refresh forwarding recovery") { try? model.refreshForwardRecovery(expectedGeneration:epoch) }.disabled(!model.connected || model.forwardRecoveryBusy)
            }
            ForEach(model.pendingForwards.values.sorted { $0.createdAt < $1.createdAt }) { intent in
                HStack {
                    VStack(alignment:.leading) { Text("Forwarded message \(intent.sourceID)");Text("\(intent.targets.count) \(intent.targets.count == 1 ? "destination needs" : "destinations need") review").font(.caption).foregroundColor(.orange) }
                    Spacer();Button("Review forward") { forwarding = intent }.disabled(model.forwardRecoveryBusy)
                }
            }
            if let failure = model.promotionRecoveryError {
                Text(failure).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                Button("Refresh conversion recovery") { try? model.refreshPromotionRecovery(expectedGeneration:epoch) }.disabled(!model.connected || model.channelManagementBusy)
            }
            ForEach(model.pendingPromotions.keys.sorted(),id:\.self) { id in
                HStack {
                    VStack(alignment:.leading) {
                        Text(model.channels.first(where:{ $0.id == id }).map { model.title($0) } ?? "Conversation \(id)")
                        Text("Conversion needs review").font(.caption).foregroundColor(.orange)
                    }
                    Spacer();Button("Check conversion status") { promoting = .init(id:id) }.disabled(model.channelManagementBusy)
                }
            }
            ForEach(model.pendingChannelClosures.values.map(\.channel).sorted { $0.id < $1.id }) { channel in
                HStack { VStack(alignment:.leading) { Text(model.title(channel));Text("Closing unconfirmed").font(.caption).foregroundColor(.orange) };Spacer();Button("Check close status") { closing = channel } }
            }
            ForEach(model.pendingHistoryArchives.values.map(\.channel).sorted { $0.id < $1.id }) { channel in
                HStack { VStack(alignment:.leading) { Text(model.title(channel));Text("History archive unconfirmed").font(.caption).foregroundColor(.orange) };Spacer();Button("Check archive status") { archiving = channel } }
            }
        }.padding(24) }.frame(width:600,height:520).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .sheet(item:$creating) { NativeEncryptedCreationRecoveryView(model:model,intent:$0) }
            .sheet(item:$startingEncrypted) { NativeEncryptedConversationRecoveryView(model:model,intent:$0,didOpen:{ dismiss() }) }
            .sheet(item:$inviting) { NativeChannelInvitationRecoveryView(model:model,intent:$0) }
            .sheet(item:$forwarding) { NativeForwardRecoveryView(model:model,intent:$0) }
            .sheet(item:$promoting) { NativeChannelPromotionView(model:model,channelID:$0.id) }
            .sheet(item:$closing) { NativeChannelCloseView(model:model,channel:$0) }
            .sheet(item:$archiving) { NativeHistoryArchiveActionView(model:model,channelID:$0.id) }
            .onAppear { epoch = model.accountGeneration }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
    }
}
