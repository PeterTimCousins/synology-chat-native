import SwiftUI

struct NativeArchiveDeletionView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @ObservedObject private var deletions: ChatArchiveDeletionCoordinator
    let archive: ChatArchive
    let kind: ChatArchiveKind
    let name: String
    let onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preparation: ChatArchiveDeletionPreparation?
    @State private var failure: String?
    @State private var loading = true
    @State private var task: Task<Void, Never>?
    @State private var session: Int

    init(model: NativeChatPreviewModel, archive: ChatArchive, kind: ChatArchiveKind, name: String, onDeleted: @escaping () -> Void) {
        self.model = model; self.deletions = model.archiveDeletions
        self.archive = archive; self.kind = kind; self.name = name; self.onDeleted = onDeleted
        _session = State(initialValue: model.accountGeneration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Delete archived history", systemImage: "trash").font(.title2.bold())
            Text(model.title(archive.props.channel)).font(.headline)
            Text(model.archivePeriodPresentation(archive).identifier).font(.caption.weight(.semibold)).foregroundColor(NativeChatColors.muted)
            Text(period).foregroundColor(NativeChatColors.muted).textSelection(.enabled).help(model.archivePeriodPresentation(archive).exactRange)
            Text("Permanently delete this archive period and its archived messages and files. Other archive periods and the live conversation remain available. This cannot be undone.")
                .fixedSize(horizontal: false, vertical: true)
            if kind == .public {
                Label("Only administrators can delete public archives.", systemImage: "lock")
                    .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
            }
            if loading { ProgressView("Checking archive…") }
            if let failure {
                Text(failure).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(task != nil && deletions.busy)
                Spacer()
                if deletions.busy { ProgressView().controlSize(.small) }
                Button("Delete archive", role: .destructive) { delete() }
                    .disabled(preparation == nil || loading || deletions.busy || failure != nil || !model.canReviewArchiveDeletion(kind:kind))
            }
        }.padding(24).frame(width: 510).foregroundColor(NativeChatColors.text)
            .background(NativeChatColors.canvas).nativeChatAppearance()
            .task { await prepare() }
            .onDisappear { task?.cancel() }
            .onChange(of: model.connected) { if !$0 { task?.cancel(); dismiss() } }
            .onChange(of: model.accountGeneration) { if $0 != session { task?.cancel(); dismiss() } }
    }

    private var period: String {
        model.archivePeriodPresentation(archive).summary
    }
    private func prepare() async {
        loading = true
        defer { loading = false }
        do {
            guard model.archivePeriodPresentation(archive).isAvailable else { throw ChatTransferError(message:"This archive's dates are unavailable. Refresh the archive list before deleting it.") }
            preparation = try await model.prepareArchiveDeletion(archive, kind: kind, name: name)
        }
        catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
    private func delete() {
        guard let preparation, !deletions.busy else { return }
        task = Task { @MainActor in
            do {
                try await model.deleteArchive(preparation)
                try Task.checkCancellation()
                guard session == model.accountGeneration else { return }
                onDeleted(); dismiss()
            } catch is CancellationError { }
            catch { if session == model.accountGeneration { failure = error.localizedDescription } }
        }
    }
}

struct NativePendingArchiveDeletionsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @ObservedObject private var deletions: ChatArchiveDeletionCoordinator
    let onResolved: () -> Void
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    init(model: NativeChatPreviewModel, onResolved: @escaping () -> Void) {
        self.model = model; self.deletions = model.archiveDeletions; self.onResolved = onResolved
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = deletions.recoveryError {
                Text(error).foregroundColor(.orange)
                Button("Retry saved-action recovery") { deletions.retryRecovery() }.disabled(deletions.busy)
            }
            if !deletions.pending.isEmpty {
                Text("Archive deletions awaiting confirmation").font(.headline)
                Text("Check the server result without repeating the deletion.").font(.caption).foregroundColor(NativeChatColors.muted)
                ForEach(deletions.pending) { record in
                    HStack {
                        Text("Archive \(record.id)").font(.callout)
                        Spacer()
                        Button("Check status") { check(record) }.disabled(deletions.busy)
                    }
                }
            }
            if let message { Text(message).font(.callout).foregroundColor(NativeChatColors.muted) }
        }.textSelection(.enabled).onDisappear { task?.cancel() }
    }
    private func check(_ record: ChatArchiveDeletionRecord) {
        guard !deletions.busy else { return }
        let epoch = model.accountGeneration
        message = nil
        task = Task { @MainActor in
            do {
                let absent = try await model.checkArchiveDeletion(record)
                guard epoch == model.accountGeneration else { return }
                message = absent ? "The archive is no longer available in this archive list." : "The archive is still present. Deletion remains unconfirmed; no request was repeated."
                if absent { onResolved() }
            } catch is CancellationError { }
            catch { if epoch == model.accountGeneration { message = error.localizedDescription } }
        }
    }
}
