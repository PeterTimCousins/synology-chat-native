import SwiftUI

@MainActor final class NativePollStore:ObservableObject {
    @Published private(set) var details:ChatPollDetails?
    @Published private(set) var busy = false
    @Published private(set) var failure:String?
    private(set) var task:Task<Void,Never>?
    private var revision = UUID()
    private var pendingRefresh = false
    func refresh(model:NativeChatPreviewModel,post:ChatPost) {
        if busy { pendingRefresh = true;return }
        run(model:model,post:post,action:nil)
    }
    func update(model:NativeChatPreviewModel,post:ChatPost,action:ChatPollAction) { guard !busy else { return };run(model:model,post:post,action:action) }
    private func run(model:NativeChatPreviewModel,post:ChatPost,action:ChatPollAction?) {
        let id = UUID();revision = id;busy = true;failure = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result:ChatPollDetails
                if let action { result = try await model.updatePoll(post,action:action) }
                else { result = try await model.pollDetails(post) }
                guard !Task.isCancelled,self.revision == id,model.canReadPoll(post) else { return };self.details = result
            } catch {
                guard !Task.isCancelled,self.revision == id else { return }
                self.failure = (error as? ChatPollError)?.errorDescription ?? "Could not confirm this poll change. Refresh before trying again."
            }
            guard self.revision == id else { return };self.busy = false;self.task = nil
            if self.pendingRefresh { self.pendingRefresh = false;self.refresh(model:model,post:post) }
        }
    }
    func clear() { revision = UUID();task?.cancel();task = nil;details = nil;failure = nil;busy = false;pendingRefresh = false }
}

struct NativePollCard:View {
    let post:ChatPost
    @ObservedObject var model:NativeChatPreviewModel
    @State private var showing = false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label(post.props?.vote?.isOpen() == true ? "Poll" : "Poll results",systemImage:"chart.bar.xaxis").font(.caption.weight(.semibold)).foregroundColor(NativeChatColors.green)
                Spacer()
                if post.props?.vote?.options.anonymous == true { Text("Anonymous").font(.caption).foregroundColor(NativeChatColors.muted) }
            }
            NativeMessageText(post:post,model:model)
            NativePollAttachmentView(post:post,model:model)
            if let poll = post.props?.vote {
                ForEach(Array(poll.sortedResults.prefix(4))) { choice in
                    HStack { Text(choice.text).lineLimit(2);Spacer(minLength:8);Text("\(choice.count)").foregroundColor(NativeChatColors.muted).monospacedDigit() }.font(.callout)
                }
                HStack {
                    Text(poll.totalLabel).font(.caption).foregroundColor(NativeChatColors.muted)
                    Spacer()
                    Button(poll.isOpen() ? "Vote & results" : "View results") { showing = true }.buttonStyle(NativeToolbarButtonStyle()).disabled(!model.canReadPoll(post))
                }
            } else { Button("Load poll") { showing = true }.disabled(!model.canReadPoll(post)) }
        }.padding(16).frame(maxWidth:520,alignment:.leading).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
            .sheet(isPresented:$showing) { NativePollView(model:model,post:post) }
            .onDisappear { showing = false }
    }
}

struct NativePollView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let post:ChatPost
    @StateObject private var store = NativePollStore()
    @Environment(\.dismiss) private var dismiss
    @State private var newOption = ""
    @State private var pendingOption:String?
    @State private var showEdit = false
    @State private var confirmClose = false
    @State private var attachmentOwner = UUID()
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label("Poll",systemImage:"chart.bar.xaxis").font(.system(size:20,weight:.bold));Spacer()
                Button { store.refresh(model:model,post:post) } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh poll").disabled(store.busy)
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close poll").keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text(store.details?.post.message ?? model.messageText(post)).font(.system(size:22,weight:.semibold)).textSelection(.enabled)
                    NativePollAttachmentView(post:store.details?.post ?? post,model:model)
                    if let details = store.details {
                        let poll = details.poll
                        HStack(spacing:12) {
                            Text(poll.isOpen() ? (poll.options.multiple ? "Choose one or more options" : "Choose one option") : "Poll closed")
                            if poll.options.anonymous { Text("Anonymous") }
                        }.font(.callout).foregroundColor(NativeChatColors.muted)
                        if poll.options.expire_at > 0 { Text("Closes " + model.formattedDate(Date(timeIntervalSince1970:poll.options.expire_at/1000))).font(.caption).foregroundColor(NativeChatColors.muted) }
                        ForEach(poll.sortedResults) { choice in option(choice,poll:poll) }
                        Text(poll.totalLabel).font(.callout).foregroundColor(NativeChatColors.muted)
                        if poll.isOpen(),poll.options.add_option {
                            HStack {
                                TextField("Add an option",text:$newOption).textFieldStyle(.roundedBorder).accessibilityLabel("New poll option").disabled(store.busy)
                                Button("Add") { pendingOption = newOption.trimmingCharacters(in:.whitespacesAndNewlines);store.update(model:model,post:post,action:.addOption(newOption)) }.disabled(store.busy || newOption.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || newOption.utf16.count > 120)
                            }
                        }
                        if poll.isOpen(),post.creator_id == model.userID {
                            HStack {
                                Button("Edit poll") { showEdit = true }
                                Spacer()
                                Button("Close voting",role:.destructive) { confirmClose = true }
                            }.disabled(store.busy).buttonStyle(NativeToolbarButtonStyle())
                        }
                    }
                    if store.busy { ProgressView("Updating poll…") }
                    if let failure = store.failure { Text(failure).foregroundColor(.orange).font(.callout);Button("Refresh poll") { store.refresh(model:model,post:post) }.disabled(store.busy) }
                }.padding(24)
            }
        }.frame(minWidth:540,idealWidth:620,maxWidth:820,minHeight:480,idealHeight:650,maxHeight:800)
            .foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .onAppear { model.pollAttachmentOwner = attachmentOwner;model.conversationLibraryVisible = true;store.refresh(model:model,post:post) }
            .onDisappear { store.clear();model.releasePollAttachmentPresentation(attachmentOwner);model.conversationLibraryVisible = false }
            .onChange(of:store.busy) { busy in
                if !busy,store.failure == nil,let pendingOption,store.details?.poll.choices.contains(where:{ $0.text == pendingOption }) == true {
                    if newOption.trimmingCharacters(in:.whitespacesAndNewlines) == pendingOption { newOption = "" };self.pendingOption = nil
                }
            }
            .onChange(of:model.pollRevision) { _ in store.refresh(model:model,post:post) }
            .onChange(of:model.canReadPoll(post)) { if !$0 { store.clear();dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.selection) { if $0 != post.channel_id { dismiss() } }
            .onChange(of:model.selectedChannel?.encrypted) { if $0 != false { dismiss() } }
            .alert("Close voting?",isPresented:$confirmClose) { Button("Cancel",role:.cancel) { };Button("Close voting",role:.destructive) { store.update(model:model,post:post,action:.close) } } message: { Text("People can still see results, but they can no longer vote or add options.") }
            .sheet(isPresented:$showEdit) {
                if let details = store.details { NativePollComposer(model:model,channelID:post.channel_id,editing:details) { store.refresh(model:model,post:post) } }
            }
            .sheet(isPresented:Binding(get:{ model.pollAttachmentOwner == attachmentOwner && model.searchDocumentOwner == nil && model.documentPreviewIsPresented },set:{ if !$0,model.pollAttachmentOwner == attachmentOwner,model.searchDocumentOwner == nil { model.closeDocumentPreview() } })) { NativeDocumentPreview(model:model) }
            .sheet(isPresented:Binding(get:{ model.pollAttachmentOwner == attachmentOwner && model.searchImageOwner == nil && model.imageViewerPost != nil },set:{ if !$0,model.pollAttachmentOwner == attachmentOwner,model.searchImageOwner == nil { model.closeImageViewer() } })) { NativeImageViewer(model:model) }
    }
    private func option(_ choice:ChatPollChoice,poll:ChatPoll)->some View {
        let selected = model.userID.map { choice.voters?.contains($0) == true } ?? false
        return VStack(alignment:.leading,spacing:8) {
            Button {
                var ids = model.userID.map { poll.selected(by:$0) } ?? []
                if selected { ids.removeAll { $0 == choice.id } }
                else if poll.options.multiple { ids.append(choice.id) } else { ids = [choice.id] }
                store.update(model:model,post:post,action:.vote(ids))
            } label: {
                HStack(spacing:12) {
                    Image(systemName:selected ? "checkmark.circle.fill" : "circle").foregroundColor(selected ? NativeChatColors.green : NativeChatColors.muted)
                    Text(choice.text).multilineTextAlignment(.leading);Spacer(minLength:12)
                    Text("\(choice.count)").monospacedDigit().foregroundColor(NativeChatColors.muted)
                }.padding(14).background(selected ? NativeChatColors.selected : NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            }.buttonStyle(.plain).disabled(store.busy || !poll.isOpen() || !model.canInteract).accessibilityLabel("\(choice.text), \(choice.count) " + (choice.count == 1 ? "vote" : "votes") + (selected ? ", selected" : ""))
            GeometryReader { geo in RoundedRectangle(cornerRadius:2).fill(NativeChatColors.green.opacity(0.65)).frame(width:geo.size.width*Double(choice.count)/Double(max(1,poll.choices.map(\.count).max() ?? 1))) }.frame(height:3)
            if !poll.options.anonymous,let voters = choice.voters,!voters.isEmpty {
                Text(voters.map { model.names[$0] ?? "User \($0)" }.joined(separator:", ")).font(.caption).foregroundColor(NativeChatColors.muted).textSelection(.enabled)
            }
        }
    }
}

struct NativePollAttachmentView:View {
    let post:ChatPost
    @ObservedObject var model:NativeChatPreviewModel
    var body:some View {
        if post.file_props?.name != nil,model.canReadPoll(post) {
            VStack(alignment:.leading,spacing:8) {
                NativeFileAttachmentCard(post:post,model:model)
                if post.file_props?.is_image == true {
                    Button { model.openPollImage(post) } label: { Label("Open image",systemImage:"photo") }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Open poll image: "+model.attachmentName(post))
                }
            }
        }
    }
}
