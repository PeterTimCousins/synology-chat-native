import SwiftUI

struct NativeHashtagBrowser: View {
    @ObservedObject var model: NativeChatPreviewModel
    let channelID: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var tags: [String] = []
    @State private var selected: String?
    @State private var loading = false
    @State private var error: String?
    private var visibleTags: [String] { tags.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        if let selected {
            NativeMessageSearchView(model:model,hashtag:selected,fixedChannelID:channelID,backToHashtags:{ self.selected = nil })
        } else {
            VStack(alignment:.leading,spacing:16) {
                HStack {
                    Text("Hashtags").font(.title3.weight(.semibold)); Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                TextField("Find a hashtag",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a hashtag")
                if loading { ProgressView("Loading hashtags…") }
                if let error { Text(error).foregroundColor(.orange); Button("Try again") { Task { await load() } } }
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:4) {
                        if !loading && tags.isEmpty && error == nil {
                            Text("No hashtags yet. Add #topic to a message to create one.").foregroundColor(NativeChatColors.muted).padding(.vertical,16)
                        }
                        if !tags.isEmpty && visibleTags.isEmpty { Text("No matching hashtags.").foregroundColor(NativeChatColors.muted).padding(.vertical,16) }
                        ForEach(visibleTags,id:\.self) { tag in
                            Button { selected = tag } label: {
                                HStack { Text("#" + tag).font(.system(size:14,weight:.medium)); Spacer(); Image(systemName:"chevron.right").font(.caption) }
                                    .padding(10).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Browse hashtag " + tag)
                        }
                    }
                }
            }.padding(20).frame(width:540,height:500).background(NativeChatColors.canvas)
                .foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
                .task(id:channelID) { await load() }
        }
    }
    private func load() async {
        loading = true; error = nil
        do { let loaded = try await model.channelHashtags(channelID:channelID); guard !Task.isCancelled else { return }; tags = loaded }
        catch { if !Task.isCancelled { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load hashtags. Try again." } }
        loading = false
    }
}
