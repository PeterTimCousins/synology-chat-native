import SwiftUI

struct NativeEncryptedConversationRecoveryView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let intent:ChatEncryptedConversationIntent
    private let didOpen:()->Void
    @Environment(\.dismiss) private var dismiss
    @State private var epoch:Int
    @State private var busy = false
    @State private var notice:String?
    @State private var status:ChatEncryptedConversationRecovery.Result?
    @State private var openReview:ChatEncryptedConversationOpenReview?
    @State private var confirmingOpen = false
    @State private var confirmingClear = false
    @State private var clearReview:ChatEncryptedConversationIntent?
    @State private var task:Task<Void,Never>?
    init(model:NativeChatPreviewModel,intent:ChatEncryptedConversationIntent,didOpen:@escaping ()->Void = {}) { self.model = model;self.intent = intent;self.didOpen = didOpen;_epoch = State(initialValue:model.accountGeneration) }
    #if DEBUG
    static func renderFixture(model:NativeChatPreviewModel,intent:ChatEncryptedConversationIntent,status:ChatEncryptedConversationRecovery.Result?)->Self {
        var view = Self(model:model,intent:intent);view._status = State(initialValue:status);return view
    }
    #endif
    private var current:ChatEncryptedConversationIntent { model.pendingEncryptedConversationStarts[intent.id] ?? intent }
    private var available:Bool { model.connected && epoch == model.accountGeneration && model.pendingEncryptedConversationStarts[intent.id] != nil && !busy && !model.channelManagementBusy }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Label("Encrypted conversation",systemImage:"lock.shield").font(.title2.bold());Spacer();Button("Done") { dismiss() }.buttonStyle(NativeToolbarButtonStyle()).disabled(busy) }
            Text("An earlier start needs verification. Checking its status never creates another conversation or sends a message.").foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
            Label("\(current.memberIDs.count) participants",systemImage:"person.2").font(.headline)
            if current.candidateChannelID != nil { Text("The server returned a conversation to check.").font(.caption).foregroundColor(NativeChatColors.muted) }
            if let status { Text(description(status.status)).fixedSize(horizontal:false,vertical:true).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10)) }
            if let notice { Text(notice).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
            if !model.encryptionUnlocked { Text("Unlock encryption from your account menu to verify the conversation key and open it.").font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true) }
            HStack {
                if busy { ProgressView().controlSize(.small) };Spacer()
                Button("Check status") { run() }.buttonStyle(NativeToolbarButtonStyle()).disabled(!available)
                Button("Review and open…") { run(prepare:true) }.buttonStyle(NativeSendButtonStyle()).disabled(!available || !model.encryptionUnlocked)
            }
            Divider()
            Button("Clear saved warning…") { clearReview = current;confirmingClear = true }.buttonStyle(NativeToolbarButtonStyle()).help("Check the official app before clearing an unconfirmed start.").disabled(!available)
        }.padding(24).frame(width:580).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().interactiveDismissDisabled(busy)
            .alert(openReview?.requiresExistingReview == true ? "Open this existing encrypted conversation?" : "Open the verified encrypted conversation?",isPresented:$confirmingOpen,presenting:openReview) { review in
                Button("Cancel",role:.cancel) { }
                Button("Open conversation") { open(review) }
            } message: { review in
                Text((review.requiresExistingReview ? "The server returned an existing conversation with a different key. Its current participants and your access have been verified. " : "The conversation and its key match the saved request. ") + "Participants: " + review.participants.map { model.displayName($0) }.joined(separator:", ") + ". Opening sends no message and does not create another conversation.")
            }
            .alert("Clear this start warning?",isPresented:$confirmingClear,presenting:clearReview) { record in
                Button("Cancel",role:.cancel) { }
                Button("Clear warning") { do { try model.acknowledgeEncryptedConversationStart(record,expectedGeneration:epoch);dismiss() } catch { notice = error.localizedDescription } }
            } message: { _ in Text("This removes only the saved warning. It does not delete a conversation. Check the official app first: starting again could create a duplicate.") }
            .onDisappear { task?.cancel() }
            .onChange(of:model.accountGeneration) { if $0 != epoch { task?.cancel();dismiss() } }
            .onChange(of:model.connected) { if !$0 { task?.cancel();dismiss() } }
            .onChange(of:model.encryptionUnlocked) { if !$0 { confirmingOpen = false;openReview = nil;status = nil;task?.cancel() } }
            .onChange(of:model.pendingEncryptedConversationStarts[intent.id]) { _ in confirmingOpen = false;confirmingClear = false;openReview = nil;clearReview = nil;status = nil }
    }
    private func description(_ value:ChatEncryptedConversationRecovery.Status)->String {
        switch value {
        case .pending:return "No matching creation result is confirmed. No request was repeated."
        case .ambiguous:return "More than one result matches. Check your conversations in the official app."
        case .changedKeys:return "A participant or encryption key changed. This request cannot be confirmed with the reviewed keys."
        case .unverified:return "The conversation or its participants could not be verified."
        case .needsUnlock:return "The conversation matches. Unlock encryption to verify its key."
        case .verified:return "The conversation and original key are verified. Review it before opening."
        case .existingNeedsReview:return "An existing encrypted conversation matches these people but uses a different key. Review it before opening."
        }
    }
    private func run(prepare:Bool = false) {
        let record = current;busy = true;notice = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                if prepare { let review = try await model.prepareEncryptedConversationOpen(record,expectedGeneration:epoch);try Task.checkCancellation();openReview = review;confirmingOpen = true }
                else { let result = try await model.checkEncryptedConversationStart(record,expectedGeneration:epoch);try Task.checkCancellation();status = result }
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    private func open(_ review:ChatEncryptedConversationOpenReview) {
        busy = true;notice = nil
        task = Task { @MainActor in defer { busy = false };do { try await model.openRecoveredEncryptedConversation(review);try Task.checkCancellation();didOpen();dismiss() } catch { if !Task.isCancelled { notice = error.localizedDescription } } }
    }
}
