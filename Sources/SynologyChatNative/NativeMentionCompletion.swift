import SwiftUI
import AppKit

/// Shared by the main and thread editors. Catalogue requests are scoped to an
/// active trigger and cancelled when its account/channel/thread context changes.
struct NativeAutocompleteComposer: View {
    @ObservedObject var model: NativeChatPreviewModel
    let channelID: Int64
    var rootID: Int64? = nil
    @Binding var text: String
    @Binding var selection: NSRange
    var focused: Binding<Bool>
    let label: String
    var minimumHeight: CGFloat = 64
    var maximumHeight: CGFloat = 64
    var automaticallySizes = false
    var onAttachmentInput: ((NativeComposerAttachmentInput) -> Void)? = nil
    @Environment(\.isEnabled) private var enabled
    private enum Kind: Hashable { case member, hashtag }
    private struct Trigger: Equatable { let kind: Kind; let token: ChatMentionCompletion.Trigger }
    private enum Suggestion: Identifiable {
        case member(ChatUser), hashtag(String)
        var id: String { switch self { case .member(let user): return "u:\(user.user_id)"; case .hashtag(let tag): return "t:" + tag } }
    }
    @State private var suggestions: [Suggestion] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var selected = 0
    @State private var dismissed: Trigger?
    @State private var retry = 0
    @State private var loadedContext: Context?
    @State private var measuredHeight:CGFloat?
    private struct Context: Hashable { let account: Int; let channel: Int64; let root: Int64?; let kind: Kind; let retry: Int }
    private var trigger: Trigger? {
        guard enabled, focused.wrappedValue, model.connected, model.canRead(channelID), !model.isEditingMessage else { return nil }
        let value: Trigger?
        if let token = ChatMentionCompletion.trigger(text: text, selection: selection) { value = .init(kind: .member, token: token) }
        else if model.canBrowseHashtags(channelID), let token = ChatMentionCompletion.trigger(text: text, selection: selection, marker: "#") { value = .init(kind: .hashtag, token: token) }
        else { value = nil }
        return value == dismissed ? nil : value
    }
    private var context: Context? {
        trigger.map { .init(account: model.accountGeneration, channel: channelID, root: rootID, kind: $0.kind, retry: retry) }
    }
    private var isHashtag: Bool { trigger?.kind == .hashtag }
    private var matches: [Suggestion] {
        guard let trigger, loadedContext == context else { return [] }
        return suggestions.filter {
            switch $0 {
            case .member(let user): return trigger.kind == .member && ChatNameFormat.matches(user, query: trigger.token.query)
            case .hashtag(let tag): return trigger.kind == .hashtag && (trigger.token.query.isEmpty || tag.localizedCaseInsensitiveContains(trigger.token.query))
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if automaticallySizes {
                NativeComposerText(text:$text,selection:$selection,focused:focused,label:label,
                                   onAttachmentInput:onAttachmentInput,onCompletionKey:key,onHeightChanged:{ height in
                    guard height.isFinite else { return }
                    let bounded = min(maximumHeight,max(minimumHeight,height))
                    if measuredHeight != bounded { measuredHeight = bounded }
                }).frame(height:min(maximumHeight,max(minimumHeight,measuredHeight ?? minimumHeight)))
            } else {
                NativeComposerText(text: $text, selection: $selection, focused: focused, label: label,
                                   onAttachmentInput: onAttachmentInput, onCompletionKey: key)
                    .frame(minHeight:minimumHeight,maxHeight:maximumHeight)
            }
            if trigger != nil {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(isHashtag ? "Choose a hashtag" : "Mention a member").font(.caption.bold())
                        Spacer()
                        Button("Dismiss") { dismissed = trigger }.buttonStyle(.plain).font(.caption)
                    }
                    if loading { ProgressView(isHashtag ? "Loading hashtags…" : "Loading members…").controlSize(.small) }
                    else if failure != nil {
                        Text(isHashtag ? "Could not load hashtags." : "Could not load members.").font(.caption)
                        Button("Try again") { retry += 1 }
                    } else if matches.isEmpty {
                        Text(isHashtag ? "No matching hashtags. New tags can be sent as typed." : "No matching members").font(.caption).foregroundColor(NativeChatColors.muted)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 2) {
                                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, suggestion in
                                        Button { choose(suggestion) } label: {
                                            HStack(spacing: 10) {
                                                switch suggestion {
                                                case .member(let person):
                                                    NativeUserAvatar(avatars: model.avatars, user: person, name: model.displayName(person), size: 26)
                                                    Text(model.displayName(person)).font(.system(size: 13, weight: .medium))
                                                    Text("@" + (person.username ?? model.displayName(person))).font(.caption).foregroundColor(NativeChatColors.muted)
                                                case .hashtag(let tag):
                                                    Image(systemName: "number").frame(width: 26).foregroundColor(NativeChatColors.green)
                                                    Text(tag).font(.system(size: 13, weight: .medium))
                                                }
                                                Spacer()
                                            }.padding(6).contentShape(Rectangle())
                                                .background(index == selected ? NativeChatColors.selected : Color.clear)
                                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                        }.buttonStyle(.plain).id(suggestion.id)
                                            .accessibilityLabel(suggestionLabel(suggestion))
                                            .accessibilityAddTraits(index == selected ? .isSelected : [])
                                    }
                                }
                            }.frame(height: min(140, CGFloat(matches.count) * 38))
                                .onChange(of: selected) { index in if matches.indices.contains(index) { proxy.scrollTo(matches[index].id) } }
                        }
                        Text("↑ ↓ choose · Tab or Return insert · Esc dismiss").font(.system(size: 10)).foregroundColor(NativeChatColors.muted)
                    }
                }.padding(10).background(NativeChatColors.elevated).clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain).accessibilityLabel(isHashtag ? "Hashtag suggestions" : "Mention suggestions")
            }
        }
        .task(id: context) {
            guard !Task.isCancelled else { return }
            suggestions = []; loadedContext = nil; failure = nil; selected = 0
            guard let current = context else { loading = false; return }
            loading = true
            do {
                let loaded: [Suggestion]
                switch current.kind {
                case .member: loaded = try await model.conversationMembers(channelID: channelID).filter(\.canStartConversation).map(Suggestion.member)
                case .hashtag: loaded = try await model.channelHashtags(channelID: channelID).map(Suggestion.hashtag)
                }
                guard !Task.isCancelled, context == current else { return }
                suggestions = loaded; loadedContext = current
            } catch {
                guard !Task.isCancelled, context == current else { return }
                failure = "Could not load members."
            }
            guard context == current else { return }; loading = false
        }
        .onChange(of: trigger) { _ in selected = 0 }
        .onChange(of: model.accountGeneration) { _ in suggestions = []; loadedContext = nil; dismissed = nil }
    }
    private func suggestionLabel(_ suggestion: Suggestion) -> String {
        switch suggestion { case .member(let user): return "Mention " + model.displayName(user); case .hashtag(let tag): return "Insert hashtag " + tag }
    }
    private func choose(_ suggestion: Suggestion) {
        guard enabled, let trigger, matches.contains(where: { $0.id == suggestion.id }) else { return }
        let edit: ChatComposerEdit.Result?
        switch suggestion {
        case .member(let user): edit = ChatMentionCompletion.insert(userID: user.user_id, trigger: trigger.token, text: text, selection: selection)
        case .hashtag(let tag): edit = ChatMentionCompletion.insert(hashtag: tag, trigger: trigger.token, text: text, selection: selection)
        }
        guard let edit else { return }
        text = edit.text; selection = edit.selection; focused.wrappedValue = true
    }
    private func key(_ value: NativeComposerCompletionKey) -> Bool {
        guard let trigger else { return false }
        if value == .dismiss { dismissed = trigger; return true }
        guard !loading, failure == nil, !matches.isEmpty else { return false }
        switch value {
        case .next: selected = (selected + 1) % matches.count
        case .previous: selected = (selected + matches.count - 1) % matches.count
        case .accept: choose(matches[min(selected, matches.count - 1)])
        case .dismiss: break
        }
        return true
    }
}
