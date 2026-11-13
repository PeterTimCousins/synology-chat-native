import SwiftUI

struct NativeEncryptionManagementView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @ObservedObject private var changes: ChatEncryptionChangeCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ChatEncryptionManagementSnapshot?
    @State private var oldPassword = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var saving = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var task: Task<Void, Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    private var valid: Bool {
        guard let snapshot, model.encryptionChangeBlockReason == nil, !busy, !changes.busy,
              changes.pending == nil, changes.recoveryError == nil,
              (8...64).contains(password.utf16.count), password.utf8.elementsEqual(confirmation.utf8) else { return false }
        return !snapshot.owner.isInitialized || (!oldPassword.isEmpty && snapshot.connectionID?.isEmpty == false)
    }
    init(model: NativeChatPreviewModel) { self.model = model; self.changes = model.encryptionChanges }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Encryption settings", systemImage: "lock.shield").font(.title2.bold())
                Spacer()
                Button("Refresh") { run() }.disabled(busy || changes.busy)
                Button("Done") { clearPasswords(); dismiss() }.disabled(busy || changes.busy).keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if busy || changes.busy { ProgressView(saving ? "Confirming encryption change…" : "Checking encryption status…") }
                    if let failure { Text(failure).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
                    if let error = changes.recoveryError { Text(error).foregroundColor(.orange).font(.callout) }
                    if let notice { Label(notice, systemImage: "checkmark.shield").foregroundColor(NativeChatColors.green) }
                    if changes.pending != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("An encryption change is awaiting confirmation", systemImage: "exclamationmark.shield").font(.headline)
                            Text("Refresh to check the keys saved on Synology Chat. Another change is blocked, and the request will not be retried automatically.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let reason = model.encryptionChangeBlockReason { Text(reason).font(.callout).foregroundColor(.orange) }
                    if let snapshot {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(snapshot.owner.isInitialized ? "Encryption is set up" : "Set up encrypted conversations").font(.headline)
                            Text(snapshot.owner.isInitialized
                                 ? "Change the password that unlocks your encrypted conversations. The same encryption keys and message history are kept."
                                 : "Create a separate password for encrypted conversations. Your NAS sign-in password does not unlock them.")
                                .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 14) {
                            if snapshot.owner.isInitialized {
                                SecureField("Current encryption password", text: $oldPassword).accessibilityLabel("Current encryption password")
                                if snapshot.connectionID?.isEmpty != false { Text("Reconnect live updates, then refresh before changing the password.").font(.caption).foregroundColor(.orange) }
                            }
                            SecureField("New encryption password", text: $password).accessibilityLabel("New encryption password")
                            SecureField("Confirm encryption password", text: $confirmation).accessibilityLabel("Confirm encryption password")
                            Text("Use 8–64 characters. Keep this password somewhere safe.").font(.caption).foregroundColor(NativeChatColors.muted)
                            if !confirmation.isEmpty, !password.utf8.elementsEqual(confirmation.utf8) { Text("The new passwords do not match.").font(.caption).foregroundColor(.orange) }
                            Text("Encrypted conversations will lock when settings change. Finish any encrypted drafts and transfers first.")
                                .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
                            Button(snapshot.owner.isInitialized ? "Change encryption password" : "Set up encryption") {
                                let change: ChatEncryptionChange = snapshot.owner.isInitialized
                                    ? .rewrap(oldPassword: oldPassword, password: password, confirmation: confirmation)
                                    : .setup(password: password, confirmation: confirmation)
                                clearPasswords(); run(change)
                            }.buttonStyle(NativeSendButtonStyle()).disabled(!valid).keyboardShortcut(.return, modifiers: .command)
                        }.textFieldStyle(.roundedBorder).disabled(busy || changes.busy || changes.pending != nil || changes.recoveryError != nil)
                        Text("For a forgotten encryption password, use Synology Chat’s recovery tools.").font(.caption).foregroundColor(NativeChatColors.muted)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            if busy {
                Divider()
                Button("Stop waiting") {
                    request = UUID(); task?.cancel(); busy = false; saving = false; clearPasswords()
                    failure = "Stopped waiting. Refresh encryption status before making another change."
                }.padding(20)
            }
        }.frame(width: 650, height: 650).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas)
            .nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy || changes.busy)
            .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; run() }
            .onDisappear { request = UUID(); task?.cancel(); clearPasswords(); model.conversationLibraryVisible = false }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of: model.connected) { if !$0 { dismiss() } }
    }
    private func clearPasswords() { oldPassword = ""; password = ""; confirmation = "" }
    private func run(_ change: ChatEncryptionChange? = nil) {
        guard !busy, !changes.busy else { return }
        let original = snapshot
        if change == nil { clearPasswords(); snapshot = nil; if changes.recoveryError != nil { changes.retryRecovery() } }
        busy = true; saving = change != nil; failure = nil; notice = nil
        let token = UUID(); request = token
        task = Task { @MainActor in
            defer { if request == token { busy = false; saving = false } }
            do {
                let value: ChatEncryptionManagementSnapshot
                if let change, let original { value = try await model.changeEncryption(change, original: original) }
                else { value = try await model.loadEncryptionManagement() }
                try Task.checkCancellation(); guard request == token else { return }
                snapshot = value
                if change != nil { notice = "Encryption change confirmed. Unlock encrypted conversations with your new password." }
                else { try changes.reconcile(value) }
            } catch is CancellationError { }
            catch { if request == token { failure = (error as? ChatCryptoError)?.errorDescription ?? error.localizedDescription } }
        }
    }
}
