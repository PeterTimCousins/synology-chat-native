import SwiftUI

struct NativePostHashtagsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    let post: ChatPost
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ChatPostHashtagSnapshot?
    @State private var tag = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var revision = UUID()
    @State private var epoch = -1
    private var allowed: Bool { !busy && model.canChangePostHashtags(post) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Message hashtags").font(.title2.bold()); Spacer()
                Button("Refresh") { load() }.disabled(busy || model.pendingMessageActions.contains(post.id))
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            Text("Added tags organize this message without changing its text.").font(.callout).foregroundColor(NativeChatColors.muted)
            if let snapshot {
                if !snapshot.otherIndexed.isEmpty {
                    Text("Other indexed tags: " + snapshot.otherIndexed.map { "#" + $0 }.joined(separator: " "))
                        .font(.caption).foregroundColor(NativeChatColors.muted)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if snapshot.additional.isEmpty { Text("No added hashtags.").foregroundColor(NativeChatColors.muted) }
                        ForEach(snapshot.additional) { item in
                            HStack {
                                Text("#" + item.hashtag).foregroundColor(NativeChatColors.green)
                                Spacer()
                                Text("Added by " + (item.user_id.flatMap { model.names[$0] } ?? "Unknown user")).font(.caption).foregroundColor(NativeChatColors.muted)
                                Button("Remove") { change(item.hashtag, enabled: false) }
                                    .accessibilityLabel("Remove added hashtag " + item.hashtag)
                                    .disabled(!allowed || !ChatHashtags.valid(item.hashtag))
                            }.padding(10).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    TextField("Hashtag without #", text: $tag).textFieldStyle(.roundedBorder).accessibilityLabel("New added hashtag")
                        .disabled(!allowed)
                    Button("Add") { change(tag, enabled: true) }
                        .disabled(!allowed || !ChatHashtags.valid(tag) || snapshot.indexed.contains(tag) || snapshot.additional.contains { $0.hashtag == tag })
                }
                Text("\(tag.utf16.count)/32 · No spaces or punctuation such as #, / or .").font(.caption).foregroundColor(NativeChatColors.muted)
            }
            if busy { ProgressView("Updating message tags…") }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange) }
            if model.postHashtagsNeedRefresh.contains(post.id) { Text("The previous change could not be confirmed. Refresh to check the server before changing tags again.").font(.callout).foregroundColor(.orange) }
        }.padding(20).frame(width: 560, height: 420).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).nativeChatAppearance()
            .onAppear { epoch = model.accountGeneration; load() }
            .onChange(of: model.accountGeneration) { _ in task?.cancel(); snapshot = nil; dismiss() }
            .onChange(of: model.canViewPostHashtags(post)) { allowed in if !allowed { task?.cancel(); snapshot = nil; dismiss() } }
            .onDisappear { revision = UUID(); task?.cancel(); snapshot = nil }
    }
    private func load() {
        guard !busy, epoch == model.accountGeneration else { return }
        busy = true; failure = nil; let key = UUID(); revision = key
        task = Task {
            do { let value = try await model.postHashtags(post); guard !Task.isCancelled, revision == key else { return }; snapshot = value }
            catch { guard !Task.isCancelled, revision == key else { return }; failure = "Could not load tags. Try Refresh when connected." }
            if revision == key { busy = false; task = nil }
        }
    }
    private func change(_ value: String, enabled: Bool) {
        guard allowed, let snapshot, epoch == model.accountGeneration else { return }
        busy = true; failure = nil; let key = UUID(); revision = key
        task = Task {
            do {
                let updated = try await model.changeAdditionalHashtag(snapshot, hashtag: value, enabled: enabled)
                guard !Task.isCancelled, revision == key else { return }
                self.snapshot = updated; if enabled { tag = "" }
            } catch {
                guard !Task.isCancelled, revision == key else { return }
                failure = (error as? ChatTransferError)?.errorDescription ?? "Could not update this tag. Refresh to check its current state."
            }
            if revision == key { busy = false; task = nil }
        }
    }
}
