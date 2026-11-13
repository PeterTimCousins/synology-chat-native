import SwiftUI

struct NativeMentionPicker: View {
    @ObservedObject var model: NativeChatPreviewModel
    let channelID: Int64
    let choose: (Int64) -> Void
    @State private var query = ""
    @State private var people: [ChatUser] = []
    @State private var loading = true
    @FocusState private var searchFocused: Bool
    @State private var error: String?
    private var matches: [ChatUser] {
        people.filter { ChatNameFormat.matches($0,query:query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mention someone").font(.system(size: 15, weight: .semibold))
            TextField("Find a member", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a member to mention").focused($searchFocused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if loading { ProgressView("Loading members…").padding() }
                    else if let error { Text(error).font(.callout); Button("Try again") { Task { await load() } } }
                    else if matches.isEmpty { Text("No matching members").foregroundColor(NativeChatColors.muted).padding() }
                    ForEach(matches, id: \.user_id) { person in
                        Button { choose(person.user_id) } label: {
                            HStack(spacing: 10) {
                                NativeUserAvatar(avatars:model.avatars,user:person,name:model.displayName(person),size:30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName(person)).font(.system(size: 13, weight: .medium))
                                    Text("@" + (person.username ?? model.displayName(person))).font(.caption).foregroundColor(NativeChatColors.muted)
                                }
                                Spacer()
                            }.padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Mention " + model.displayName(person))
                    }
                }
            }.frame(height: loading || error != nil ? 150 : min(230, max(100, CGFloat(matches.count) * 48)))
        }.padding(16).frame(width: 320).background(NativeChatColors.surface)
            .foregroundColor(NativeChatColors.text).nativeChatAppearance()
            .onAppear { searchFocused = true }.task(id: channelID) { await load() }
    }
    private func load() async {
        loading = true; error = nil; people = []
        do {
            let members = try await model.conversationMembers(channelID: channelID)
            guard !Task.isCancelled, model.connected, model.selection == channelID, model.canRead(channelID) else { return }
            people = members.filter(\.canStartConversation)
        } catch { if !Task.isCancelled { self.error = "Could not load members. Try again when connected." } }
        loading = false
    }
}

struct NativeComposerEmojiPicker: View {
    @ObservedObject var preferences: ChatEmojiPreferences
    let chooseEmoji: (ChatReactionKind) -> Void
    let chooseSticker: (String) -> Void
    @ObservedObject var assets: NativeStickerAssets
    @State private var mode = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Insert type", selection: $mode) { Text("Emoji").tag(0); Text("Stickers").tag(1) }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 12)
            if mode == 0 { NativeReactionPicker(title: "Insert emoji", preferences: preferences) { kind in
                preferences.record(kind); chooseEmoji(kind)
            } }
            else { NativeStickerPicker(assets: assets, title: "Send a sticker", choose: chooseSticker) }
        }.background(NativeChatColors.surface).nativeChatAppearance()
    }
}
