import SwiftUI

struct NativeForwardRecoveryView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let intent:ChatForwardIntent
    private let epoch:Int
    @Environment(\.dismiss) private var dismiss
    @State private var task:Task<Void,Never>?
    @State private var busy = false
    @State private var clearWarning = false
    @State private var notice:String?
    init(model:NativeChatPreviewModel,intent:ChatForwardIntent) { self.model = model;self.intent = intent;epoch = model.accountGeneration }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Label("Forwarding needs review",systemImage:"arrowshape.turn.up.right").font(.title2.bold());Spacer();Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Message \(intent.sourceID) · Conversation \(intent.sourceChannelID)").font(.headline)
            Text("\(intent.targets.count) \(intent.targets.count == 1 ? "destination" : "destinations") · Started \(Date(timeIntervalSince1970:intent.createdAt).formatted(date:.abbreviated,time:.shortened))").foregroundColor(NativeChatColors.muted)
            Text("Checking reads recent history without sending anything. If the source changed or a copy is outside recent history, check each destination yourself before clearing the warning.").fixedSize(horizontal:false,vertical:true)
            if let notice { Text(notice).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true).textSelection(.enabled) }
            if let error = model.forwardRecoveryError { Text(error).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Check status") {
                    busy = true;notice = nil
                    task = Task { @MainActor in
                        defer { busy = false }
                        do { let copies = try await model.checkForwardStatus(intent,expectedGeneration:epoch);try Task.checkCancellation();notice = "Confirmed in all \(copies.count) destinations. No forward request was repeated." }
                        catch { if !Task.isCancelled { notice = error.localizedDescription } }
                    }
                }.buttonStyle(NativeSendButtonStyle()).disabled(busy || model.forwardRecoveryBusy || model.pendingForwards[intent.id] != intent)
            }
            Button("I checked the outcome; clear this warning…") { clearWarning = true }
                .buttonStyle(NativeToolbarButtonStyle()).disabled(busy || model.forwardRecoveryBusy || model.forwardRecoveryError != nil || model.pendingForwards[intent.id] != intent)
        }.padding(24).frame(width:560).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .alert("Clear this forwarding warning?",isPresented:$clearWarning) {
                Button("Cancel",role:.cancel) { }
                Button("Clear warning") { do { try model.acknowledgeForwardOutcome(intent,expectedGeneration:epoch);dismiss() } catch { notice = error.localizedDescription } }
            } message: { Text("This only removes the saved warning. It does not send or remove messages. Forwarding again requires a separate manual action and may create duplicate copies.") }
            .onDisappear { task?.cancel() }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
    }
}
