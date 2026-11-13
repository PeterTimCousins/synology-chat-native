import SwiftUI

struct NativeHistoryArchiveActionView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channelID:Int64
    @Environment(\.dismiss) private var dismiss
    @State private var preparation:ChatHistoryArchivePreparation?
    @State private var receipt:ChatArchive?
    @State private var busy = false
    @State private var confirm = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var generation = -1
    @State private var showHistory = false
    private var pending:Bool { model.pendingHistoryArchives[channelID] != nil }
    private var reviewedChannel:ChatChannel? { preparation?.channel ?? model.pendingHistoryArchives[channelID]?.channel }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Label("Archive channel history",systemImage:"archivebox").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
            }
            if let receipt {
                Label("History archived",systemImage:"checkmark.circle.fill").foregroundColor(NativeChatColors.green)
                Text("The server confirmed a new archive for “\(receipt.props.channel.name)”. The channel remains open for new messages.")
                Button("Browse archive history") { showHistory = true }
            } else {
                Text(reviewedChannel.map { pending ? "Unconfirmed history archive for “\(model.title($0))”." : "Archive the current history of “\(model.title($0))”?" } ?? "Review the channel before archiving.").font(.headline)
                Text("Current messages and files move into read-only Archive history for channel members. The channel stays open. Your unsent draft stays here. This client cannot move archived history back into the live channel.").foregroundColor(NativeChatColors.muted)
                if pending { Text("A previous request is still unconfirmed. Check its status before taking further action.").foregroundColor(.orange) }
                HStack {
                    Button(pending ? "Check archive status" : "Refresh review") { run(check:pending) }.disabled(busy)
                    Spacer()
                    if !pending { Button("Archive history…") { confirm = true }.disabled(busy || preparation == nil || preparation.map { !model.canArchiveHistory($0.channel) } == true) }
                }
            }
            if busy { ProgressView("Checking archive history…") }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).textSelection(.enabled) }
        }.padding(24).frame(width:570).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy)
            .onAppear { generation = model.accountGeneration;run(check:pending) }
            .onDisappear { task?.cancel() }
            .onChange(of:model.accountGeneration) { if $0 != generation { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .sheet(isPresented:$showHistory) { NativeArchivesView(model:model) }
            .alert("Archive this channel’s history?",isPresented:$confirm) {
                Button("Cancel",role:.cancel) { }
                Button("Archive history",role:.destructive) { run(archive:true) }
            } message: { Text("All current messages and files in this private channel will move to read-only Archive history for its members. The channel stays open. This client has no restore action.") }
    }
    private func run(check:Bool = false,archive:Bool = false) {
        guard !busy else { return };busy = true;failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                if check { receipt = try await model.checkHistoryArchive(channelID:channelID) }
                else if archive,let preparation { receipt = try await model.archiveHistory(preparation) }
                else { preparation = try await model.prepareHistoryArchive(channelID:channelID) }
            } catch is CancellationError { }
            catch { preparation = nil;failure = error.localizedDescription }
        }
    }
}
