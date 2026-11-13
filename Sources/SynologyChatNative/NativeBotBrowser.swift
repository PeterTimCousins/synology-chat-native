import SwiftUI

struct NativeBotBrowserView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var catalogue: ChatBotCatalogue?
    @State private var query = ""
    @State private var scope = 0
    @State private var busy = false
    @State private var failure: String?
    @State private var confirmation: ChatBotEntry?
    @State private var removing = false
    @State private var task: Task<Void, Never>?
    @State private var epoch = -1
    private var entries: [ChatBotEntry] {
        (catalogue?.entries ?? []).filter {
            (scope == 0 || scope == 1 && $0.subscribed || scope == 2 && $0.blocked)
            && (query.isEmpty || $0.bot.nickname.localizedCaseInsensitiveContains(query) || ($0.bot.chatbot_props?.purpose.localizedCaseInsensitiveContains(query) ?? false))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Browse bots", systemImage: "sparkles").font(.title2.bold())
                Spacer()
                Button("Refresh") { refresh() }.disabled(busy)
                Button("Done") { dismiss() }.disabled(busy)
            }
            Text("Bots are integrations connected to your Synology account. Subscribing can enable their messages; unsubscribing affects only your account.").font(.callout).foregroundColor(NativeChatColors.muted)
            HStack {
                Picker("Bot status", selection: $scope) { Text("All").tag(0); Text("Subscribed").tag(1); Text("Unsubscribed").tag(2) }.pickerStyle(.segmented)
                TextField("Find a bot", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a bot").frame(width: 200)
            }
            if busy { ProgressView("Checking bots…") }
            if let failure { Text(failure).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            if let error = model.botSubscriptionRecoveryError { Text(error).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            if !model.pendingBotSubscriptions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Refresh checks pending operations without repeating them, including after an app restart.").font(.callout)
                    ForEach(model.pendingBotSubscriptions.values.sorted { $0.botID < $1.botID }) { intent in
                        let name = catalogue?.entries.first(where: { $0.id == intent.botID })?.bot.nickname ?? "Bot \(intent.botID)"
                        Text("\(name) · \(intent.blocked ? "unsubscribe" : "subscribe") awaiting confirmation").font(.caption)
                    }
                }.foregroundColor(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in row(entry) }
                    if catalogue != nil && entries.isEmpty && !busy { Text(query.isEmpty ? "No bots in this view" : "No matching bots").foregroundColor(NativeChatColors.muted).frame(maxWidth: .infinity).padding(.vertical, 50) }
                }
            }.frame(minHeight: 180, maxHeight: 350)
        }.padding(24).frame(width: 700).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .interactiveDismissDisabled(busy)
            .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                Button(removing ? "Unsubscribe" : "Subscribe and open", role: removing ? .destructive : nil) { if let entry = confirmation { act(entry, unsubscribe: removing) }; confirmation = nil }
                Button("Cancel", role: .cancel) { confirmation = nil }
            } message: { Text(removing ? "This account will stop receiving this bot’s messages. Existing history and local drafts are preserved. You can subscribe again here." : "This enables messages from the bot for your account and may display a welcome message. Messages you send to a bot can be processed by its configured service.") }
            .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; refresh() }
            .onDisappear { task?.cancel(); model.conversationLibraryVisible = false }
            .onChange(of: model.connected) { if !$0 { dismiss() } }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
    }
    private var confirmationTitle: String { "\(removing ? "Unsubscribe from" : "Subscribe to") \(confirmation?.bot.nickname ?? "this bot")?" }
    private func row(_ entry: ChatBotEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").foregroundColor(NativeChatColors.green)
                Text(entry.bot.nickname).font(.headline)
                Spacer()
                Text(entry.blocked ? "Unsubscribed" : entry.subscribed ? "Subscribed" : "Available").font(.caption).foregroundColor(NativeChatColors.muted)
            }
            if let props = entry.bot.chatbot_props, !props.purpose.isEmpty { Text(props.purpose).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            HStack {
                Button(entry.subscribed ? "Open" : entry.blocked ? "Subscribe again…" : "Subscribe…") {
                    if entry.subscribed { act(entry) } else { removing = false; confirmation = entry }
                }
                if entry.subscribed { Button("Unsubscribe…", role: .destructive) { removing = true; confirmation = entry } }
                if model.pendingBotSubscriptions[entry.id] != nil { Text("Check pending operation").font(.caption).foregroundColor(.orange) }
                Spacer()
            }.disabled(busy || model.botSubscriptionRecoveryError != nil || model.pendingBotSubscriptions[entry.id] != nil)
        }.padding(16).background(NativeChatColors.surface).cornerRadius(10)
    }
    private func refresh() {
        run { catalogue = try await model.loadBots() }
    }
    private func act(_ entry: ChatBotEntry, unsubscribe: Bool = false) {
        guard let catalogue else { return }
        run {
            if unsubscribe { self.catalogue = try await model.unsubscribeBot(entry, catalogue: catalogue) }
            else if try await model.openBot(entry, catalogue: catalogue) { dismiss() }
            else { self.catalogue = try await model.loadBots(); failure = "Subscription checked. The active conversation changed while waiting; choose Open to navigate when ready." }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }
}
