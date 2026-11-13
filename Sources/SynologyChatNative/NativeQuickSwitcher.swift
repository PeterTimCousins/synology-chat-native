import SwiftUI

struct NativeQuickSwitcherView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ChatQuickSwitchSnapshot?
    @State private var query = ""
    @State private var scope = 0
    @State private var selected: String?
    @State private var loading = false
    @State private var opening = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var confirmation: ChatQuickSwitchEntry?
    @State private var epoch = -1
    private var matches: [ChatQuickSwitchEntry] { snapshot?.filtered(query: query, scope: scope) ?? [] }
    private var entries: [ChatQuickSwitchEntry] { Array(matches.prefix(100)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Quick switcher").font(.title2.bold())
                Spacer()
                Button("Refresh") { load() }.disabled(loading || opening)
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction).disabled(opening)
            }
            NativeQuickSwitchSearch(text: $query, enabled: !opening, move: move, submit: submit, cancel: cancel).frame(height: 32)
            Picker("Quick switch scope", selection: $scope) { Text("All").tag(0); Text("Channels").tag(1); Text("Conversations").tag(2) }.pickerStyle(.segmented)
            if loading { ProgressView("Loading destinations…") }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            if let error = model.conversationStartRecoveryError { Text(error).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            if !model.pendingConversationStarts.isEmpty { Text("An earlier conversation start needs verification. Refresh checks for it without sending another request.").font(.caption).foregroundColor(.orange) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in
                            Button { selected = entry.id; activate(entry) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: entry.encrypted ? "lock" : entry.named ? "number" : entry.channel?.type == "chatbot" ? "sparkles" : "bubble.left.and.bubble.right").frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.title).font(.headline).lineLimit(1)
                                        Text(entry.subtitle).font(.caption).foregroundColor(NativeChatColors.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    if let channel = entry.channel, channel.badgeUnreadCount > 0 { Text("\(channel.badgeUnreadCount)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 3).background(NativeChatColors.green.opacity(0.2)).cornerRadius(8) }
                                    if entry.id == selected { Image(systemName: "return").font(.caption) }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .background(entry.id == selected ? NativeChatColors.selected : Color.clear).cornerRadius(8)
                            }.buttonStyle(.plain).id(entry.id).disabled(opening || loading)
                                .accessibilityLabel("\(entry.title), \(entry.subtitle)\(entry.id == selected ? ", selected" : "")")
                        }
                        if entries.isEmpty && !loading { Text(query.isEmpty ? "Type a name to find a conversation or channel." : "No matching destinations").foregroundColor(NativeChatColors.muted).frame(maxWidth: .infinity).padding(.vertical, 50) }
                    }
                }.frame(height: 330)
                    .onChange(of: selected) { _ in if let selected { proxy.scrollTo(selected, anchor: .center) } }
            }
            HStack {
                Text(matches.count > 100 ? "First 100 results · refine your search" : "↑ ↓ choose · Return opens · Esc closes").font(.caption).foregroundColor(NativeChatColors.muted)
                Spacer()
                if opening { ProgressView().controlSize(.small) }
                Button("Open") { submit() }.disabled(selected == nil || loading || opening)
            }
        }.padding(24).frame(width: 650).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .interactiveDismissDisabled(opening)
            .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; load() }
            .onDisappear { task?.cancel(); model.conversationLibraryVisible = false }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of: model.connected) { if !$0 { dismiss() } }
            .onChange(of: model.nameSettings) { _ in if !loading && !opening { load() } }
            .onChange(of: query) { _ in selected = entries.first?.id }
            .onChange(of: scope) { _ in selected = entries.first?.id }
            .confirmationDialog("Start a conversation with \(confirmation?.title ?? "this person")?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                Button("Start conversation") { if let entry = confirmation { open(entry) }; confirmation = nil }
                Button("Cancel", role: .cancel) { confirmation = nil }
            } message: { Text("This creates or opens a direct conversation. No message will be sent.") }
    }
    private func move(_ delta: Int) { guard !loading && !opening else { return }; selected = ChatQuickSwitchSelection.move(selected, in: entries, delta: delta) }
    private func submit() { guard !loading && !opening, let entry = entries.first(where: { $0.id == selected }) else { return }; activate(entry) }
    private func activate(_ entry: ChatQuickSwitchEntry) {
        guard let snapshot, !loading && !opening else { return }
        if entry.channel == nil {
            guard model.conversationStartRecoveryError == nil, !model.quickSwitchStartPending(entry, snapshot: snapshot) else { failure = "This conversation start needs verification. Refresh before trying again."; return }
            confirmation = entry
        } else { open(entry) }
    }
    private func open(_ entry: ChatQuickSwitchEntry) {
        guard let snapshot else { return }; opening = true; failure = nil
        task = Task { @MainActor in
            defer { opening = false }
            do {
                if try await model.openQuickSwitch(entry, snapshot: snapshot) { dismiss() }
                else { failure = "The active conversation changed while waiting. Refresh the switcher when ready." }
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
    private func cancel() { guard !opening else { return }; task?.cancel(); dismiss() }
    private func load() {
        guard !loading && !opening else { return }; loading = true; failure = nil
        task = Task { @MainActor in
            defer { loading = false }
            do { snapshot = try await model.loadQuickSwitcher(); selected = entries.first?.id }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
