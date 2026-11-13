import SwiftUI

struct NativeBotAttachmentsView: View {
    let post: ChatPost
    @ObservedObject var model: NativeChatPreviewModel
    var interactive = true
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private var cards: [ChatBotAttachment] { model.botAttachments(for: post) }
    var body: some View {
        if !cards.isEmpty || model.botActionStatus[post.id] != nil || error != nil {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(cards) { card in
                    VStack(alignment: .leading, spacing: 12) {
                        if !card.text.isEmpty { NativeMessageText(post: post, textOverride: card.text, model: model) }
                        if card.actionCount > 100 { Text("Only the first 100 actions are shown.").font(.caption).foregroundColor(NativeChatColors.muted) }
                        if !card.actions.isEmpty {
                            LazyVGrid(columns: [.init(.adaptive(minimum: 110, maximum: 220), alignment: .leading)], alignment: .leading, spacing: 8) {
                                ForEach(card.actions) { action in
                                    let selection = ChatBotActionSelection(attachmentIndex: card.index, actionIndex: action.index, attachment: card.raw)
                                    Button(role: action.style == "danger" ? .destructive : nil) { run(selection) } label: {
                                        Text(action.text).lineLimit(3).frame(maxWidth: .infinity)
                                    }.buttonStyle(.bordered).tint(action.style == "primary" ? NativeChatColors.green : action.style == "danger" ? .red : .gray)
                                        .disabled(!interactive || !model.canTriggerBotAction(post, selection: selection))
                                        .help(action.type == "button" ? action.text : "Unsupported integration action: " + action.type)
                                }
                            }
                        }
                    }.padding(14).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(NativeChatColors.green.opacity(0.65)).frame(width: 3) }
                }
                if (post.props?.attachments?.count ?? 0) > 100 { Text("Only the first 100 integration cards are shown.").font(.caption).foregroundColor(NativeChatColors.muted) }
                if model.botActionsPending.contains(post.id) { ProgressView("Sending or checking action…").font(.caption) }
                if let recoveryError = model.botActionRecoveryError { Text(recoveryError).font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
                if let status = model.botActionStatus[post.id] { Text(status).font(.caption).foregroundColor(NativeChatColors.muted) }
                if let error { Text(error).font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
                if interactive, !cards.isEmpty || model.uncertainBotActions[post.id] != nil || model.pendingBotActionReceipts[post.id] != nil {
                    Button("Check message") { run(nil) }.font(.caption).disabled(!model.canCheckBotActionMessage(post))
                }
            }.frame(maxWidth: 480, alignment: .leading)
                .onDisappear { task?.cancel() }
        }
    }
    private func run(_ selection: ChatBotActionSelection?) {
        guard interactive, !model.botActionsPending.contains(post.id) else { return }; error = nil
        task = Task { @MainActor in
            do {
                if let selection { try await model.triggerBotAction(post, selection: selection) }
                else { try await model.checkBotActionMessage(post) }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
