import AppKit
import SwiftUI

struct NativeSlashSuggestions: View {
    @ObservedObject var model: NativeChatPreviewModel
    var inThread = false
    private var text: String { inThread ? model.replyDraft : model.draft }
    private var commands: [ChatSlashCommand] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let prefix = String(text.dropFirst())
        return Array(model.availableSlashCommands.filter { $0.name.hasPrefix(prefix) }.prefix(6))
    }
    var body: some View {
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(commands) { command in
                    Button {
                        let completed = ChatSlashSyntax.completing(text, with: command.name)
                        if inThread { model.replyDraft = completed } else { model.draft = completed }
                    } label: { Text("/" + command.name + " — " + command.description).frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).font(.callout).foregroundColor(NativeChatColors.green)
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
}

struct NativeSlashCommandView: View {
    @ObservedObject var model: NativeChatPreviewModel
    let request: NativeSlashCommandRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var response: ChatSlashResult?
    @State private var failure: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var nickname: String?
    @State private var acknowledging:ChatSlashActionIntent?
    init(model: NativeChatPreviewModel, request: NativeSlashCommandRequest) {
        self.model = model; self.request = request; _text = State(initialValue: request.initialText)
    }
    private var command: ChatSlashCommand? { request.commands.first { $0.name == ChatSlashSyntax.name(text) } }
    private var pending:[ChatSlashActionIntent] { model.pendingSlashInvocations.values.filter { $0.channelID == request.channel.id }.sorted { $0.id < $1.id } }
    private var serverCommand:Bool { if let command,case .server = command.kind { return true };return false }
    private var uncertain: Bool { guard let command else { return false }; return model.uncertainSlashInvocations.contains(ChatSlashSyntax.invocationKey(channelID: request.channel.id, command: command, message: text)) }
    var body: some View {
        Group {
            if let nickname {
                NativeProfileEditorView(model: model, initialNickname: nickname, onSaved: { model.finishSlashNickname(request) })
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("Commands").font(.title2.bold()); Spacer(); Button(response == nil ? "Cancel" : "Done") { model.dismissSlashCommands(); dismiss() }.keyboardShortcut(.cancelAction).disabled(busy) }
                    Text(model.title(request.channel) + " · \(request.memberIDs.count) members").font(.headline)
                    if request.rootID != nil { Text("Integration commands run in this conversation's main message history.").font(.caption).foregroundColor(NativeChatColors.muted) }
                    List(request.commands) { command in
                        Button { text = ChatSlashSyntax.completing(text.hasPrefix("/") ? text : "/", with: command.name) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("/" + command.name).font(.headline)
                                Text(command.description).font(.callout).foregroundColor(NativeChatColors.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }.frame(height: 160).scrollContentBackground(.hidden).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                    TextEditor(text: $text).font(.system(size: 14, design: .monospaced)).frame(height: 65).accessibilityLabel("Command and arguments")
                    if let command {
                        Text(command.usage).font(.caption).foregroundColor(NativeChatColors.muted)
                        if case .server = command.kind {
                            Text(command.name == "jitsi" ? "This may create a meeting and post an invitation to this conversation." : "This sends the command and arguments to the configured integration. It may post messages or perform other actions.")
                                .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
                            if request.channel.encrypted { Text("Command arguments are sent to the integration outside conversation encryption.").font(.callout).foregroundColor(.orange) }
                        }
                    } else { Text("Choose an available command.").font(.caption).foregroundColor(NativeChatColors.muted) }
                    if let response {
                        Text("Command response").font(.headline)
                        ScrollView { VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(ChatMessageFormatting.blocks(response.displayMessage).enumerated()), id: \.offset) { item in NativeFormattedMessageBlock(block: item.element, mentions: model.mentionNames, hashtagLinks: false) }
                        } }.frame(height: 120)
                            .environment(\.openURL, OpenURLAction { url in
                                guard model.connected, request.accountGeneration == model.accountGeneration, let web = ChatMessageLinks.webURL(url.absoluteString) else { return .discarded }
                                NSWorkspace.shared.open(web); return .handled
                            })
                    }
                    if let error = model.slashRecoveryError {
                        Text(error).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
                        Button("Refresh saved command state") {
                            do { try model.refreshSlashRecovery(request);failure = nil }
                            catch { failure = error.localizedDescription }
                        }.disabled(busy || model.slashBusy)
                    }
                    if !pending.isEmpty {
                        VStack(alignment:.leading,spacing:10) {
                            Text("Commands needing review").font(.headline)
                            Text("These records survive restarting the app when a reply or recovery update could not be confirmed. Check the conversation and integration before allowing a new manual attempt.").font(.caption).foregroundColor(NativeChatColors.muted)
                            ScrollView {
                                VStack(alignment:.leading,spacing:8) {
                                    ForEach(pending) { receipt in
                                        HStack {
                                            VStack(alignment:.leading,spacing:3) {
                                                Text(commandLabel(receipt)).font(.callout)
                                                Text(model.formattedDate(Date(timeIntervalSince1970:receipt.createdAt)) + " · Attempt " + String(receipt.operationID.uuidString.prefix(6))).font(.caption).foregroundColor(NativeChatColors.muted)
                                            }
                                            Spacer()
                                            Button("I checked the outcome…") { acknowledging = receipt }.disabled(busy || model.slashBusy || model.slashRecoveryError != nil)
                                        }
                                    }
                                }
                            }.frame(maxHeight:100)
                        }.padding(12).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:8))
                    }
                    if uncertain, failure == nil { Text("This command has an unconfirmed result. Check the conversation and integration before attempting it again.").foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
                    if let failure { Text(failure).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    if busy { ProgressView("Running command…") }
                    HStack { Spacer(); Button(command?.kind == .nickname ? "Edit display name…" : command?.kind == .help ? "Show help" : "Run command") { run() }
                        .disabled(busy || model.slashBusy || uncertain || response != nil || command == nil || (serverCommand && model.slashRecoveryError != nil) || !model.canInteract || !ChatMessageText.isAllowed(text)) }
                }.padding(24).frame(width: 570).disabled(busy)
            }
        }.background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy)
            .alert("Allow a new manual attempt?",isPresented:Binding(get:{ acknowledging != nil },set:{ if !$0 { acknowledging = nil } })) {
                Button("Keep blocked",role:.cancel) { acknowledging = nil }
                Button("I checked; allow a new attempt") {
                    if let receipt = acknowledging {
                        do { try model.acknowledgeSlashOutcome(receipt,request:request);failure = nil }
                        catch { failure = error.localizedDescription }
                    }
                    acknowledging = nil
                }
            } message: { Text("The earlier command may already have run. Clear this warning only after checking its outcome. This does not send anything; you must choose Run command separately for a new attempt.") }
            .onDisappear { task?.cancel();acknowledging = nil }
            .onChange(of: text) { _ in response = nil; failure = nil }
            .onChange(of: model.accountGeneration) { if $0 != request.accountGeneration { model.dismissSlashCommands(); dismiss() } }
            .onChange(of: model.selection) { if $0 != request.channel.id { model.dismissSlashCommands(); dismiss() } }
            .onChange(of: model.threadRoot?.id) { if let root = request.rootID, $0 != root { model.dismissSlashCommands(); dismiss() } }
    }
    private func commandLabel(_ receipt:ChatSlashActionIntent) -> String {
        request.commands.first { if case .server(let id) = $0.kind { return id == receipt.commandUserID };return false }.map { "/" + $0.name } ?? "Earlier integration command"
    }
    private func run() {
        guard !busy, let command else { return }; failure = nil
        if command.kind == .nickname {
            let value = ChatSlashSyntax.arguments(text)
            guard !value.isEmpty, value.utf16.count <= 255 else { failure = "Use /nickname followed by a display name of up to 255 characters."; return }
            nickname = value; return
        }
        busy = true; let message = text
        task = Task { @MainActor in
            defer { busy = false }
            do { response = try await model.executeSlashCommand(request, command: command, message: message); try Task.checkCancellation() }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
