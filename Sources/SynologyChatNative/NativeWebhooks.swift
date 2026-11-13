import SwiftUI
import AppKit

struct NativeWebhooksView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var catalogue: ChatWebhookCatalogue?
    @State private var snapshot: ChatWebhookSnapshot?
    @State private var draft = ChatWebhookDraft()
    @State private var kind: ChatWebhookKind = .incoming
    @State private var failure: String?
    @State private var busy = false
    @State private var reveal = false
    @State private var confirm: String?
    @State private var reviewedAction:ChatWebhookActionIntent?
    @State private var epoch = -1
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(snapshot == nil ? "Integrations" : "Edit integration").font(.title2.bold())
                Spacer()
                Button("Refresh") { run { if let s = snapshot { accept(try await model.loadWebhook(s.detail.user_id, kind: s.kind)) } else { catalogue = try await model.loadWebhooks() } } }.disabled(busy)
                Button("Done") { dismiss() }.disabled(busy)
            }
            if let recoveryError = model.webhookRecoveryError {
                Text(recoveryError).font(.callout).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
                Button("Refresh saved action state") { run { try model.refreshWebhookRecovery();catalogue = try await model.loadWebhooks() } }.disabled(busy)
            }
            if !model.pendingWebhookActions.isEmpty {
                VStack(alignment:.leading,spacing:10) {
                    Text("Unconfirmed integration actions").font(.callout.weight(.semibold))
                    Text("These actions are remembered after restart and will not be repeated automatically. Check the server outcome before allowing another attempt.").font(.caption).foregroundColor(NativeChatColors.muted)
                    ForEach(Array(model.pendingWebhookActions.values).sorted { $0.id < $1.id }) { record in
                        HStack {
                            Text(recoveryLabel(record)).font(.callout)
                            Spacer()
                            Button("Review outcome…") { reviewedAction = record;confirm = "recover" }.disabled(busy || model.webhookRecoveryError != nil)
                        }
                    }
                }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            }
            if let snapshot { editor(snapshot) }
            else {
                Picker("Integration type", selection: $kind) { ForEach(ChatWebhookKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text(kind == .incoming ? "External services can post to a chosen conversation using a secret URL." : "Matching messages can be forwarded to an external callback. Enable only a destination you trust.").font(.callout).foregroundColor(NativeChatColors.muted)
                if let catalogue {
                    let entries = catalogue.entries.filter { $0.kind == kind }
                    if entries.isEmpty { Text("No \(kind.rawValue) webhooks").padding(.vertical, 20) }
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(entries) { entry in
                                HStack {
                                    VStack(alignment: .leading) { Text(entry.nickname.isEmpty ? "Unnamed integration" : entry.nickname).font(.headline); Text(entry.is_disabled == true ? "Disabled" : "Enabled").font(.caption).foregroundColor(NativeChatColors.muted) }
                                    Spacer()
                                    if entry.editable(by: catalogue.ownerID) { Button("Edit…") { run { accept(try await model.loadWebhook(entry.id, kind: kind)) } } }
                                    else { Text("Managed by another account").font(.caption).foregroundColor(NativeChatColors.muted) }
                                }.padding(12).background(NativeChatColors.surface).cornerRadius(8)
                            }
                        }
                    }.frame(maxHeight: 230)
                    Button("New \(kind.rawValue) webhook…") { confirm = "create" }.disabled(!catalogue.canCreate || model.webhookRecoveryError != nil || model.uncertainWebhookCreates.contains(kind))
                    if model.uncertainWebhookCreates.contains(kind) { Text("An earlier creation is unconfirmed. Inspect integrations in the official client before creating another.").foregroundColor(.orange) }
                }
            }
            if busy { ProgressView("Checking integration…") }
            if let failure { Text(failure).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        }
        .padding(24).frame(width: 640).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
        .interactiveDismissDisabled(busy)
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible,presenting:confirm) { action in
            Button(action == "recover" ? "Mark reviewed" : action == "delete" ? "Remove integration" : action == "rotate" ? "Replace token" : action == "create" ? "Create disabled integration" : "Save changes", role: action == "delete" || action == "rotate" ? .destructive : nil) { confirm = nil; perform(action) }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: { _ in Text(dialogMessage) }
        .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; run { catalogue = try await model.loadWebhooks() } }
        .onDisappear { task?.cancel(); model.conversationLibraryVisible = false }
        .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
        .onChange(of: model.connected) { if !$0 { dismiss() } }
    }
    private func editor(_ value: ChatWebhookSnapshot) -> some View {
        let uncertain = model.webhookRecoveryError != nil || model.uncertainWebhookIDs.contains(value.detail.user_id)
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(value.kind.title) webhook · ID \(value.detail.user_id)").foregroundColor(NativeChatColors.muted)
            TextField("Integration name", text: $draft.nickname)
            Toggle("Enabled", isOn: $draft.enabled)
            Picker("Conversation or channel", selection: $draft.channelID) {
                Text(value.kind == .outgoing ? "Any channel" : "Choose a conversation").tag(Int64(0))
                if draft.channelID != 0 && !value.catalogue.channels.contains(where: { $0.id == draft.channelID }) { Text("Unavailable channel \(draft.channelID)").tag(draft.channelID) }
                ForEach(value.catalogue.channels) { Text(model.title($0)).tag($0.id) }
            }
            if value.kind == .outgoing {
                TextField("Trigger words", text: $draft.triggerWord)
                Group { if reveal { TextField("HTTP or HTTPS callback URL", text: $draft.callbackURL) } else { SecureField("HTTP or HTTPS callback URL", text: $draft.callbackURL) } }
                Text("Any channel requires a trigger word. An enabled outgoing webhook forwards matching messages to this callback.").font(.caption).foregroundColor(NativeChatColors.muted)
            }
            if !uncertain, let token = value.detail.token {
                secretField("Token", value: token.reveal())
                if value.kind == .incoming, let url = try? model.webhookIncomingURL(value) { secretField("Incoming URL", value: url) }
                Toggle("Reveal credentials and callback", isOn: $reveal)
                Text("Anyone with the token or incoming URL can use this integration. Copy only to a service you trust.").font(.caption).foregroundColor(NativeChatColors.muted)
            }
            if uncertain { Text("An operation is unconfirmed. Refresh to inspect the server before further changes.").foregroundColor(.orange) }
            HStack {
                Button("Back") { snapshot = nil; reveal = false; run { catalogue = try await model.loadWebhooks() } }
                Button("Remove…", role: .destructive) { confirm = "delete" }.disabled(uncertain)
                Button("Replace token…") { confirm = "rotate" }.disabled(uncertain || value.detail.token == nil)
                Spacer()
                Button("Save…") { confirm = "save" }.disabled(uncertain || draft.normalized == ChatWebhookDraft(value.detail))
            }
        }.textFieldStyle(.roundedBorder).disabled(busy)
    }
    private func secretField(_ title: String, value: String) -> some View {
        HStack {
            Group { if reveal { TextField(title, text: .constant(value)) } else { SecureField(title, text: .constant(value)) } }.accessibilityLabel(title)
            Button("Copy \(title.lowercased())") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }.disabled(busy)
        }
    }
    private func recoveryLabel(_ record:ChatWebhookActionIntent)->String {
        let operation:String
        switch record.operation { case .create:operation = "Creation";case .edit:operation = "Settings change";case .rotate:operation = "Token replacement";case .remove:operation = "Removal" }
        return operation + " · " + record.kind.title + (record.webhookID.map { " · ID \($0)" } ?? " · ID not confirmed")
    }
    private var dialogTitle: String { switch confirm { case "recover": return "Mark this integration action as reviewed?";case "create": return "Create a disabled \(kind.rawValue) webhook?"; case "rotate": return "Replace this integration’s token?"; case "delete": return "Remove this integration?"; default: return "Save integration changes?" } }
    private var dialogMessage: String { switch confirm { case "recover": return "Check the integration list and its current settings first. If another copy of the app is still handling the action, let it finish. This clears only the local retry guard; it will not create, resend, rotate or remove anything. A later manual attempt could duplicate an earlier creation or replace a token again."; case "create": return "A disabled integration will be created on the server. Configure it before enabling it. Cancelling this confirmation creates nothing."; case "rotate": return "The previous token and incoming URL will stop working. Update any external services that use them."; case "delete": return "This stops the integration. Existing messages remain."; default: return draft.enabled ? "The integration will be enabled with these settings. Outgoing webhooks may forward matching messages to the configured service." : "The integration will remain disabled with these settings." } }
    private func accept(_ value: ChatWebhookSnapshot) { snapshot = value; catalogue = value.catalogue; draft = .init(value.detail); reveal = false }
    private func perform(_ action: String?) {
        let recovery = reviewedAction;reviewedAction = nil
        run {
            switch action {
            case "recover": if let recovery { catalogue = try await model.acknowledgeWebhookOutcome(recovery);snapshot = nil;reveal = false }
            case "create": if let catalogue { accept(try await model.createWebhook(kind: kind, original: catalogue)) }
            case "save": if let snapshot { accept(try await model.saveWebhook(draft, original: snapshot)) }
            case "rotate": if let snapshot { accept(try await model.rotateWebhook(snapshot)) }
            case "delete": if let snapshot { catalogue = try await model.removeWebhook(snapshot); self.snapshot = nil; reveal = false }
            default: break
            }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; failure = nil; reveal = false
        task = Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }
}
