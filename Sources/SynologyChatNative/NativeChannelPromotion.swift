import SwiftUI

struct NativeChannelPromotionView: View {
    @ObservedObject var model: NativeChatPreviewModel
    let channelID: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ChatChannelPromotionSnapshot?
    @State private var draft = ChatChannelPromotionDraft()
    @State private var reviewing = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: ChatChannel?
    @State private var task: Task<Void, Never>?
    @State private var epoch = -1
    @State private var clearing:ChatChannelPromotionIntent?
    private var pending: ChatChannelPromotionAttempt? { model.pendingPromotions[channelID] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(result != nil ? "Private channel verified" : pending != nil ? "Check channel status" : "Convert to private channel").font(.title2.bold())
                Spacer(); Button(result != nil ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let result {
                Label(result.name, systemImage: "lock.fill").font(.headline).foregroundColor(NativeChatColors.green)
                Text("The channel details and members match your review.").foregroundColor(NativeChatColors.muted)
            } else if let pending {
                Text(pending.reviewedName.map { "A request was already sent for “" + $0 + "”. Checking status only reads the server; it never repeats creation or sends invitations." } ?? "An earlier conversion request needs checking. Status checking only reads the server; it never repeats creation or sends invitations.").fixedSize(horizontal:false,vertical:true)
                Text("Started " + model.formattedDate(Date(timeIntervalSince1970:pending.intent.createdAt))).font(.caption).foregroundColor(NativeChatColors.muted)
                if let id = pending.targetID { Text("Channel ID: \(id)").font(.caption).foregroundColor(NativeChatColors.muted) }
                Button("Check status") { run(checkOnly: true) }
                Button("I checked the outcome; clear this warning…") { clearing = pending.intent }.disabled(model.promotionRecoveryError != nil)
            } else if let snapshot {
                if reviewing {
                    Text(draft.normalized.name).font(.headline)
                    if !draft.normalized.purpose.isEmpty { Text(draft.normalized.purpose).textSelection(.enabled) }
                    Text(draft.mode.detail).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("Channel name", text: $draft.name).accessibilityLabel("Private channel name")
                    TextField("Purpose (optional)", text: $draft.purpose).accessibilityLabel("Private channel purpose")
                    Picker("Message history", selection: $draft.mode) { ForEach(ChatChannelPromotionMode.allCases) { Text($0.title).tag($0) } }
                    Text(draft.mode.detail).font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Members (\(snapshot.memberIDs.count))").font(.headline)
                    ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(snapshot.memberIDs.sorted(), id: \.self) { id in Text(snapshot.memberNames[id] ?? "User \(id)").frame(maxWidth: .infinity, alignment: .leading) } } }.frame(maxHeight: 120)
                }
                Text(draft.mode == .newChannel ? "These members will be invited to the new private channel and may receive a notification." : "The members above keep access. This action changes the existing conversation for everyone in it.").font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if reviewing { Button("Back") { reviewing = false } }
                    Spacer()
                    Button(reviewing ? draft.mode.title : "Review change") { if reviewing { run(checkOnly: false) } else { reviewing = true } }
                        .disabled((try? draft.validate()) == nil || !model.canPromoteConversation(snapshot.channel))
                }
            }
            if let failure = model.promotionRecoveryError {
                Text(failure).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                Button("Refresh saved conversion state") {
                    do {
                        try model.refreshPromotionRecovery(expectedGeneration:epoch);error = nil
                        if pending == nil,model.channels.contains(where:{ $0.id == channelID && $0.supportsPromotion }) { load() }
                    } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if busy { ProgressView("Checking conversation…") }
        }.padding(24).frame(width: 550).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).nativeChatAppearance().tint(NativeChatColors.green)
            .disabled(busy || model.channelManagementBusy).interactiveDismissDisabled(busy)
            .onAppear { epoch = model.accountGeneration; if pending == nil,model.promotionRecoveryError == nil { load() } }
            .alert("Clear this conversion warning?",isPresented:Binding(get:{ clearing != nil },set:{ if !$0 { clearing = nil } })) {
                Button("Keep warning",role:.cancel) { clearing = nil }
                Button("I checked; clear warning") {
                    if let intent = clearing {
                        do { try model.acknowledgePromotionOutcome(intent,epoch:epoch);dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    clearing = nil
                }
            } message: { Text("The conversion or new channel may already exist. Check the conversation and channel list first. This clears only the saved recovery record and sends no requests. Another attempt requires a separate review.") }
            .onDisappear { task?.cancel();clearing = nil }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of: model.connected) { if !$0 { dismiss() } }
    }
    private func load() {
        guard epoch == model.accountGeneration else { return }
        let expected = epoch
        busy = true
        task = Task { @MainActor in
            defer { busy = false }
            do { try Task.checkCancellation();guard expected == model.accountGeneration else { throw CancellationError() };snapshot = try await model.loadPromotionSnapshot(channelID: channelID); try Task.checkCancellation() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func run(checkOnly: Bool) {
        guard !busy,epoch == model.accountGeneration else { return }; let expected = epoch;busy = true; error = nil
        let reviewed = draft
        task = Task { @MainActor in
            defer { busy = false }
            do {
                try Task.checkCancellation();guard expected == model.accountGeneration else { throw CancellationError() }
                if checkOnly { result = try await model.checkPromotionStatus(channelID: channelID,expectedGeneration:expected) }
                else if let snapshot { result = try await model.promoteConversation(snapshot, draft: reviewed) }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
