import SwiftUI

/// A bounded native popover: categories browse locally, search spans the complete
/// protocol catalogue. Selection is sent only by the parent message action.
struct NativeReactionPicker: View {
    var title = "Add a reaction"
    @ObservedObject var preferences: ChatEmojiPreferences
    let choose: (ChatReactionKind) -> Void
    @State private var query = ""
    @State private var category = "people"
    @State private var searchFocused = true
    @State private var selectedEmoji: String?
    @Environment(\.dismiss) private var dismiss
    private var matches: [ChatReactionKind] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && category == "recent" { return preferences.recent }
        return ChatReactionKind.matching(query: query, category: category, skinTone: preferences.skinTone)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            NativeEmojiPickerSearchField(text: $query, focused: $searchFocused,
                label: title == "Add a reaction" ? "Search reactions" : "Search emoji", command: handleCommand)
                .frame(height: 24)
            HStack {
                Picker("Category", selection: $category) {
                    Text("Recent").tag("recent")
                    ForEach(ChatReactionKind.categories, id: \.self) { Text($0.capitalized).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity)
                Picker("Skin tone", selection: Binding(get: { preferences.skinTone }, set: { preferences.setSkinTone($0) })) {
                    Text("Default tone").tag(0)
                    ForEach(1...5, id: \.self) { value in
                        Text(["", "🏻 Light", "🏼 Medium light", "🏽 Medium", "🏾 Medium dark", "🏿 Dark"][value]).tag(value)
                    }
                }.labelsHidden().frame(width: 145).disabled(category == "recent")
            }.disabled(!query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ScrollViewReader { proxy in
              ScrollView {
                if matches.isEmpty {
                    Text(category == "recent" && query.isEmpty ? "Emoji you choose will appear here." : "No emoji match “\(query)”").foregroundColor(NativeChatColors.muted)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 4), count: 8), spacing: 4) {
                        ForEach(matches) { kind in
                            Button { choose(kind) } label: {
                                Text(kind.emoji).font(.system(size: 24)).frame(width: 36, height: 36)
                                    .background(selectedEmoji == kind.rawValue ? NativeChatColors.green.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).help(kind.displayName + " (:" + kind.rawValue + ":)")
                                .accessibilityLabel(kind.displayName)
                                .accessibilityAddTraits(selectedEmoji == kind.rawValue ? [.isSelected] : [])
                                .id(kind.rawValue)
                        }
                    }.padding(.vertical, 3)
                }
              }.frame(height: 250)
                .onChange(of: selectedEmoji) { value in
                    if let value { proxy.scrollTo(value) }
                }
            }
            Text(selectedEmoji.flatMap { selected in matches.first { $0.rawValue == selected }?.displayName } ?? "\(matches.count) emoji · ↓ to browse, Return to choose")
                .font(.caption).foregroundColor(NativeChatColors.muted).lineLimit(1)
            if preferences.recentSyncing { ProgressView("Syncing recent emoji…").controlSize(.small) }
            else if let notice = preferences.recentSyncNotice {
                Text(notice).font(.caption).foregroundColor(.orange)
                Button("Refresh recent emoji") { preferences.refreshRecents?() }.font(.caption)
            }
        }.padding(16).frame(width: 348).background(NativeChatColors.surface)
            .foregroundColor(NativeChatColors.text).nativeChatAppearance()
            .onAppear { category = preferences.recent.isEmpty ? "people" : "recent"; searchFocused = true }
            .onChange(of: query) { _ in selectedEmoji = nil }
            .onChange(of: matches.map(\.rawValue)) { _ in selectedEmoji = nil }
            .onExitCommand { dismiss() }
    }

    private func handleCommand(_ command: NativeEmojiPickerNavigation.Command) -> Bool {
        if command == .cancel { dismiss(); return true }
        let items = matches
        let current = selectedEmoji.flatMap { selected in items.firstIndex { $0.rawValue == selected } }
        if command == .submit {
            guard let index = NativeEmojiPickerNavigation.submissionIndex(selected: current, count: items.count) else { return true }
            choose(items[index]); return true
        }
        // Left and right remain ordinary search editing until Down/Up starts
        // explicit grid navigation. Typing resets that selection.
        if (command == .left || command == .right) && current == nil { return false }
        selectedEmoji = NativeEmojiPickerNavigation.move(selected: current, count: items.count, command: command).map { items[$0].rawValue }
        return true
    }
}

/// Wraps reaction chips at the actual message width rather than clipping a long
/// row or forcing the conversation to scroll horizontally.
struct NativeReactionFlow: Layout {
    var spacing: CGFloat = 6
    private func positions(_ subviews: Subviews, width: CGFloat) -> ([CGPoint], CGSize) {
        var points: [CGPoint] = []; var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: width, height: y + rowHeight))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(subviews, width: proposal.width ?? 320).1
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = positions(subviews, width: bounds.width).0
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y), proposal: .unspecified)
        }
    }
}
