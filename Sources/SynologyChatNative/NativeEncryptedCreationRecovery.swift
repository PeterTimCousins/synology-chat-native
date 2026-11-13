import SwiftUI

struct NativeEncryptedCreationRecoveryView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let intent:ChatEncryptedCreationIntent
    @State private var epoch:Int
    @Environment(\.dismiss) private var dismiss
    @State private var task:Task<Void,Never>?
    @State private var busy = false
    @State private var joining = false
    @State private var clearing = false
    @State private var clearReview:ChatEncryptedCreationIntent?
    @State private var confirmingJoin = false
    @State private var joinReview:ChatEncryptedCreationJoinReview?
    @State private var notice:String?
    init(model:NativeChatPreviewModel,intent:ChatEncryptedCreationIntent) { self.model = model;self.intent = intent;_epoch = State(initialValue:model.accountGeneration) }
    private var current:ChatEncryptedCreationIntent { model.pendingEncryptedCreations[intent.id] ?? intent }
    private var available:Bool { epoch == model.accountGeneration && model.pendingEncryptedCreations[intent.id] != nil && !busy && !model.channelManagementBusy && model.encryptedCreationRecoveryError == nil }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Label("Channel creation needs review",systemImage:"lock.square").font(.title2.bold());Spacer();Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let id = current.channelID { Text("Encrypted channel \(id)").font(.headline) }
            Text("Started \(Date(timeIntervalSince1970:current.createdAt).formatted(date:.abbreviated,time:.shortened))").foregroundColor(NativeChatColors.muted)
            if let time = current.lastJoinAt { Text("Last join attempt \(Date(timeIntervalSince1970:time).formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundColor(NativeChatColors.muted) }
            Text(current.channelID == nil ? "The server did not return a channel ID. Check your channels in the official app before clearing this warning. Matching a name cannot prove which channel was created." : "Check status reads the known channel and member list without changing it. If joining was interrupted, unlock encryption and review Finish joining to use the original saved key. It does not create another channel or invite anyone.")
                .fixedSize(horizontal:false,vertical:true)
            if let notice { Text(notice).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true).textSelection(.enabled) }
            if let error = model.encryptedCreationRecoveryError { Text(error).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
            HStack {
                if busy { ProgressView().controlSize(.small) };Spacer()
                Button("Check status") { checkStatus() }.buttonStyle(NativeToolbarButtonStyle()).disabled(!available || current.channelID == nil)
                if current.channelID != nil {
                    Button("Finish joining…") { prepareJoin() }.buttonStyle(NativeSendButtonStyle()).disabled(!available || !model.encryptionUnlocked || !model.canInteract)
                }
            }
            if current.channelID != nil,!model.encryptionUnlocked { Text("Unlock encryption to finish an interrupted join. Status checks remain available while locked.").font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true) }
            Button("I checked my channels; clear this warning…") { clearReview = current;clearing = true }.buttonStyle(NativeToolbarButtonStyle()).disabled(!available)
        }.padding(24).frame(width:580).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .alert("Clear this creation warning?",isPresented:$clearing,presenting:clearReview) { record in
                Button("Cancel",role:.cancel) { }
                Button("Clear warning") { do { try model.acknowledgeEncryptedCreation(record,expectedGeneration:epoch);dismiss() } catch { notice = error.localizedDescription } }
            } message: { _ in Text("This removes the saved review record and its encrypted key envelope. It does not join or delete a channel. If creation succeeded but joining did not, clearing this record may leave a channel you cannot open here. Another manual creation could create a duplicate.") }
            .alert("Finish joining this channel?",isPresented:$confirmingJoin,presenting:joinReview) { review in
                Button("Cancel",role:.cancel) { }
                Button("Finish joining") { finishJoin(review) }
            } message: { review in Text("Join “\(review.channel.name)” using the original saved encryption key. This sends one join request to this known channel. It does not create a channel or invite anyone. Your current conversation stays open.") }
            .onDisappear { task?.cancel() }
            .onChange(of:model.accountGeneration) { if $0 != epoch { task?.cancel();dismiss() } }
            .onChange(of:model.connected) { if !$0 { task?.cancel();dismiss() } }
            .onChange(of:model.encryptionUnlocked) { if !$0 { confirmingJoin = false;joinReview = nil;if joining { task?.cancel() } } }
            .onChange(of:model.pendingEncryptedCreations[intent.id]) { value in if value != joinReview?.intent { confirmingJoin = false;joinReview = nil } }
    }
    private func checkStatus() {
        let record = current;busy = true;notice = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { try await model.checkEncryptedCreationStatus(record,expectedGeneration:epoch);try Task.checkCancellation();notice = "The encrypted channel is confirmed joined. No creation or join was repeated." }
            catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    private func prepareJoin() {
        let record = current;busy = true;joining = true;notice = nil
        task = Task { @MainActor in
            defer { busy = false;joining = false }
            do { let review = try await model.prepareEncryptedCreationJoin(record,expectedGeneration:epoch);try Task.checkCancellation();joinReview = review;confirmingJoin = true }
            catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    private func finishJoin(_ review:ChatEncryptedCreationJoinReview) {
        busy = true;joining = true;notice = nil
        task = Task { @MainActor in
            defer { busy = false;joining = false }
            do { try await model.finishEncryptedCreationJoin(review);try Task.checkCancellation();notice = "Joining is confirmed. Your current conversation stayed open." }
            catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
}
