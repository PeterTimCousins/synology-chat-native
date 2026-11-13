import SwiftUI

@MainActor final class NativeReadStatusStore: ObservableObject {
    @Published private(set) var status: ChatPostReadStatus?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var updatedAt:Date?
    private var revision = UUID()
    private(set) var task: Task<Void,Never>?
    func clear() {
        task?.cancel();task = nil;revision = UUID()
        status = nil;failure = nil;loading = false;updatedAt = nil
    }
    func load(using loader:@escaping () async throws -> ChatPostReadStatus) {
        clear();let key = UUID();revision = key;loading = true
        task = Task {
            defer { if revision == key { loading = false;task = nil } }
            do {
                let result = try await loader();try result.validate()
                guard !Task.isCancelled, revision == key else { return }
                status = result;updatedAt = Date()
            } catch {
                guard !Task.isCancelled, revision == key else { return }
                failure = "Could not load read details. Try again."
            }
        }
    }
}

struct NativeMessageReadStatusView: View {
    @ObservedObject var model: NativeChatPreviewModel
    let post: ChatPost
    let initialUnread: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = NativeReadStatusStore()
    @State private var unread = false
    @State private var query = ""
    private var ids:[Int64] { unread ? store.status?.unreadIDs ?? [] : store.status?.readIDs ?? [] }
    private func name(_ id:Int64) -> String { model.names[id] ?? "User \(id)" }
    private var visible:[Int64] {
        ids.filter { id in
            query.isEmpty || name(id).localizedCaseInsensitiveContains(query)
                || model.directory.first(where:{ $0.user_id == id }).map { ChatNameFormat.matches($0,query:query) } == true
        }.sorted { left,right in
            let order = name(left).localizedCaseInsensitiveCompare(name(right))
            return order == .orderedSame ? left < right : order == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"checkmark.message").font(.system(size:21)).foregroundColor(NativeChatColors.green)
                VStack(alignment:.leading,spacing:3) {
                    Text("Read details").font(.system(size:19,weight:.bold))
                    Text(model.channels.first(where:{ $0.id == post.channel_id }).map(model.title) ?? "Conversation")
                        .font(.callout).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button { load() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh read details").disabled(store.loading)
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close read details").keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Text(post.type == "file" ? model.attachmentName(post) : post.type == "sticker" ? "Sticker message" : model.messageText(post))
                .font(.system(size:13)).lineLimit(2).foregroundColor(NativeChatColors.muted).padding(.horizontal,20).padding(.bottom,16)
            Picker("Read status",selection:$unread) {
                Text("Read (\(store.status?.readIDs.count ?? 0))").tag(false)
                Text("Not read (\(store.status?.unreadIDs.count ?? 0))").tag(true)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal,20).padding(.bottom,12)
            TextField("Find a person",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a person in read details")
                .padding(.horizontal,20).padding(.bottom,16)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:4) {
                    if store.loading { ProgressView("Loading read details…").frame(maxWidth:.infinity).padding(.vertical,40) }
                    if let failure = store.failure {
                        Text(failure).foregroundColor(.orange)
                        Button("Try again") { load() }
                    }
                    if store.status != nil && visible.isEmpty {
                        Text(query.isEmpty ? (unread ? "No one is listed as unread." : "No one is listed as having read this message yet.") : "No matching people.")
                            .font(.callout).foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity).padding(.vertical,40)
                    }
                    ForEach(visible,id:\.self) { id in
                        HStack(spacing:12) {
                            NativeUserIdentity(model:model,userID:id,size:32)
                            VStack(alignment:.leading,spacing:3) {
                                Text(name(id)).font(.system(size:14,weight:.medium))
                                if let user = model.directory.first(where:{ $0.user_id == id }), let additional = model.additionalName(user) {
                                    Text(additional).font(.system(size:11)).foregroundColor(NativeChatColors.muted)
                                }
                            }
                            Spacer()
                            Image(systemName:unread ? "circle" : "checkmark.circle.fill")
                                .foregroundColor(unread ? NativeChatColors.muted : NativeChatColors.green)
                                .accessibilityLabel(unread ? "Not read" : "Read")
                        }.padding(10).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:8))
                    }
                }.padding(16)
            }
            if let updated = store.updatedAt {
                Text("Updated " + model.formattedDate(updated,timeOnly:true)).font(.system(size:10)).foregroundColor(NativeChatColors.muted)
                    .padding(.horizontal,20).padding(.bottom,14)
            }
        }.frame(width:500,height:570).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text)
            .tint(NativeChatColors.green).nativeChatAppearance()
            .onAppear { unread = initialUnread;model.conversationLibraryVisible = true;load() }
            .onChange(of:model.canViewReadStatus(post)) { allowed in if !allowed { store.clear();dismiss() } }
            .onDisappear { store.clear();model.conversationLibraryVisible = false }
    }
    private func load() { store.load { try await model.readStatus(post) } }
}
