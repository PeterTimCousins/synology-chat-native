import SwiftUI

@MainActor final class NativeReactionDetailsStore: ObservableObject {
    @Published private(set) var details: ChatReactionDetails?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var updatedAt: Date?
    private var revision = UUID()
    private(set) var task: Task<Void, Never>?
    func clear() {
        task?.cancel(); task = nil; revision = UUID()
        details = nil; loading = false; failure = nil; updatedAt = nil
    }
    func load(using loader: @escaping () async throws -> ChatReactionDetails) {
        clear(); let key = UUID(); revision = key; loading = true
        task = Task { [weak self] in
            do {
                let value = try await loader(); try Task.checkCancellation()
                guard let self, revision == key else { return }
                details = value; updatedAt = Date()
            } catch is CancellationError { }
            catch {
                guard let self, revision == key, !Task.isCancelled else { return }
                failure = "Could not load reaction details. Try again when connected."
            }
            guard let self, revision == key else { return }
            loading = false; task = nil
        }
    }
}

struct NativeReactionDetailsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    let post: ChatPost
    var initialReaction: String? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = NativeReactionDetailsStore()
    @State private var query = ""
    @State private var selected: String?
    @State private var account = -1
    private var people: [ChatReactionDetails.Person] {
        (store.details?.people(reaction: selected) ?? []).filter { person in
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty || name(person.id).localizedCaseInsensitiveContains(q)
                || (person.id == model.userID && "You".localizedCaseInsensitiveContains(q))
                || model.directory.first(where: { $0.user_id == person.id }).map { ChatNameFormat.matches($0, query: q) } == true
        }
    }
    private func name(_ id: Int64) -> String { model.names[id] ?? "User \(id)" }
    private func emoji(_ value: String) -> String { ChatReactionKind(rawValue: value)?.emoji ?? ":\(value):" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Reaction details").font(.title2.bold())
                Spacer()
                Button("Refresh") { load() }.disabled(store.loading).accessibilityLabel("Refresh reaction details")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let details = store.details {
                Text("\(details.people().count) \(details.people().count == 1 ? "person" : "people") · \(details.reactionCount) \(details.reactionCount == 1 ? "reaction" : "reactions")")
                    .font(.callout).foregroundColor(NativeChatColors.muted)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        filter("All", reaction: nil)
                        ForEach(details.groups) { group in
                            filter("\(emoji(group.id)) \(group.userIDs.count)", reaction: group.id)
                        }
                    }.padding(.vertical, 3)
                }
            }
            TextField("Find a person", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Find a person in reaction details")
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.loading { ProgressView("Loading reactions…").frame(maxWidth: .infinity).padding(30) }
                    if let failure = store.failure {
                        Text(failure).foregroundColor(.orange)
                        Button("Try again") { load() }
                    }
                    if store.details != nil && people.isEmpty {
                        Text(query.isEmpty ? "No reactions to show." : "No matching people.")
                            .foregroundColor(NativeChatColors.muted).frame(maxWidth: .infinity).padding(30)
                    }
                    ForEach(people) { person in
                        HStack(spacing: 12) {
                            NativeUserIdentity(model: model, userID: person.id, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name(person.id) + (person.id == model.userID ? " (You)" : ""))
                                if let user = model.directory.first(where: { $0.user_id == person.id }), let additional = model.additionalName(user) {
                                    Text(additional).font(.caption).foregroundColor(NativeChatColors.muted)
                                }
                            }
                            Spacer()
                            Text(person.reactionNames.map(emoji).joined(separator: " ")).font(.title3)
                                .accessibilityLabel(person.reactionNames.map { ChatReactionKind(rawValue: $0)?.displayName ?? $0 }.joined(separator: ", "))
                        }.padding(10).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let updated = store.updatedAt {
                Text("Updated " + model.formattedDate(updated, timeOnly: true) + " · Refresh for the latest reactions")
                    .font(.caption).foregroundColor(NativeChatColors.muted)
            }
        }.padding(20).frame(width: 540, height: 540).background(NativeChatColors.canvas)
            .foregroundColor(NativeChatColors.text).nativeChatAppearance()
            .onAppear { account = model.accountGeneration; selected = initialReaction; load() }
            .onChange(of: model.accountGeneration) { _ in store.clear(); dismiss() }
            .onChange(of: model.canViewReactionDetails(post)) { allowed in if !allowed { store.clear(); dismiss() } }
            .onChange(of: store.details) { value in
                if let value, let selected, !value.groups.contains(where: { $0.id == selected }) { self.selected = nil }
            }
            .onDisappear { store.clear() }
    }
    private func filter(_ title: String, reaction: String?) -> some View {
        Button { selected = reaction } label: {
            Text(title).padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected == reaction ? NativeChatColors.selected : NativeChatColors.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(reaction.flatMap { ChatReactionKind(rawValue: $0)?.displayName } ?? title)
            .accessibilityAddTraits(selected == reaction ? .isSelected : [])
    }
    private func load() {
        guard account == model.accountGeneration, model.canViewReactionDetails(post) else { store.clear(); dismiss(); return }
        store.load { try await model.reactionDetails(post) }
    }
}
