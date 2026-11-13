import SwiftUI

struct NativeScheduledCreationReview:Equatable,Identifiable {
    let accountGeneration:Int
    let record:ChatScheduledCreationIntent
    let matchingJobs:[ChatScheduledMessage]
    let acknowledgedJob:ChatScheduledMessage?
    var id:UUID { record.operationID }
}

struct NativeScheduledCreationRecoveryPanel:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channelID:Int64
    @State private var reviewing = false
    @State private var failure:String?
    var body:some View {
        if model.pendingScheduledCreations[channelID] != nil || model.scheduleCreationRecoveryError != nil {
            VStack(alignment:.leading,spacing:10) {
                Label("Previous scheduled-send attempt",systemImage:"exclamationmark.shield").font(.headline)
                Text(model.scheduleCreationRecoveryError ?? "A previous attempt may have reached the server. New schedules in this conversation are protected until you review its outcome.")
                    .font(.callout).foregroundColor(NativeChatColors.muted)
                if let failure { Text(failure).font(.callout).foregroundColor(.orange) }
                HStack {
                    if model.pendingScheduledCreations[channelID] != nil {
                        Button("Review previous attempt") { reviewing = true }.disabled(model.scheduleBusy)
                    }
                    Button("Refresh recovery state") {
                        do { try model.refreshScheduledCreationRecovery(channelID:channelID);failure = nil }
                        catch { failure = error.localizedDescription }
                    }.disabled(model.scheduleBusy)
                }.buttonStyle(NativeToolbarButtonStyle())
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(NativeChatColors.surface)
                .sheet(isPresented:$reviewing) { NativeScheduledCreationRecoveryView(model:model,channelID:channelID) }
        }
    }
}

struct NativeScheduledCreationRecoveryView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channelID:Int64
    @Environment(\.dismiss) private var dismiss
    @State private var review:NativeScheduledCreationReview?
    @State private var failure:String?
    @State private var busy = false
    @State private var confirming:NativeScheduledCreationReview?
    @State private var task:Task<Void,Never>?
    #if DEBUG
    static func fixture(model:NativeChatPreviewModel,channelID:Int64,review:NativeScheduledCreationReview)->Self {
        var view = Self(model:model,channelID:channelID)
        view._review = State(initialValue:review);return view
    }
    #endif
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Review scheduled-send attempt").font(.title2.bold())
            Text("This check only reads pending messages. It does not send, retry, change or cancel anything.").font(.callout).foregroundColor(NativeChatColors.muted)
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    if let review {
                        Text("Attempted \(model.formattedDate(Date(timeIntervalSince1970:review.record.createdAt)))").font(.callout)
                        if let acknowledged = review.acknowledgedJob {
                            Label(review.record.matches(acknowledged) ? "The server's returned message is still pending" : "The server's returned message has changed",systemImage:"clock")
                            job(acknowledged)
                        } else if review.record.acknowledgedID != nil {
                            Text("The message ID returned by the server is no longer in the pending list.")
                        }
                        if !review.matchingJobs.filter({ $0.id != review.acknowledgedJob?.id }).isEmpty {
                            Text("New matching pending messages: \(review.matchingJobs.filter { $0.id != review.acknowledgedJob?.id }.count)").font(.headline)
                            Text("Matching text and time are evidence, but do not prove which request created a message.").font(.caption).foregroundColor(NativeChatColors.muted)
                            ForEach(review.matchingJobs.filter { $0.id != review.acknowledgedJob?.id }) { job($0) }
                        } else if review.matchingJobs.isEmpty {
                            Text("No new matching message is pending. It may already have been delivered or removed; absence does not prove that the attempt failed.")
                        }
                    } else if busy { ProgressView("Checking scheduled messages…") }
                    if let failure { Text(failure).foregroundColor(.orange) }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Text("Keep protection until you have checked the conversation and pending messages. Clearing it allows another attempt, which could cause duplicate delivery.")
                .font(.callout).foregroundColor(.orange)
            HStack {
                Button("Refresh") { load() }.disabled(busy || model.scheduleBusy)
                Spacer()
                Button("Keep protection") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("I reviewed this outcome…") { confirming = review }.disabled(review == nil || busy || model.scheduleBusy)
            }.buttonStyle(NativeToolbarButtonStyle())
        }.padding(24).frame(width:680,height:540).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .interactiveDismissDisabled(busy)
            .onAppear { if review == nil { load() } }
            .onDisappear { task?.cancel() }
            .alert("Allow another scheduled-send attempt?",isPresented:Binding(get:{ confirming != nil },set:{ if !$0 { confirming = nil } }),presenting:confirming) { captured in
                Button("Keep protection",role:.cancel) { confirming = nil }
                Button("Clear local protection",role:.destructive) { clear(captured);confirming = nil }
            } message: { _ in Text("Only local protection is cleared. The previous message may still be scheduled or already delivered. Scheduling it again could send a duplicate.") }
    }
    private func job(_ value:ChatScheduledMessage)->some View {
        VStack(alignment:.leading,spacing:8) {
            Text(model.formattedDate(value.date)).font(.headline)
            Text(value.message).textSelection(.enabled)
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
    }
    private func load() {
        task?.cancel();busy = true;failure = nil;review = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { let value = try await model.reviewScheduledCreation(channelID:channelID);try Task.checkCancellation();review = value }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
    private func clear(_ captured:NativeScheduledCreationReview) {
        task?.cancel();busy = true;failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { try await model.clearReviewedScheduledCreation(captured);try Task.checkCancellation();dismiss() }
            catch is CancellationError { }
            catch { review = nil;failure = error.localizedDescription }
        }
    }
}
