import SwiftUI

struct NativeMessageSearchView: View {
    @ObservedObject var model: NativeChatPreviewModel
    var hashtag: String? = nil
    var fixedChannelID: Int64? = nil
    var backToHashtags: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var allConversations = false
    @State private var filters = ChatSearchFilters()
    @State private var filtersExpanded = false
    @State private var results: [ChatPost] = []
    @State private var loading = false
    @State private var searched = false
    @State private var hasMore = false
    @State private var failure: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var revision = UUID()
    @State private var offset = 0
    @State private var activeQuery: ChatSearchQuery?
    @State private var activeChannelID: Int64?
    @State private var focused = false
    @State private var selection = NSRange(location:0,length:0)
    @State private var selectedSuggestion: Int?
    @State private var dismissedTrigger: ChatSearchCompletion.Trigger?
    @State private var suggestedDate = Date()
    @State private var showDateCalendar = false
    @State private var previewOwner = UUID()
    private var searchUsers:[ChatSearchEntity] {
        model.directory.map { user in .init(id:user.user_id,label:model.names[user.user_id] ?? user.username ?? "User",aliases:[user.username,user.nickname].compactMap{$0}.filter{!$0.isEmpty},canMention:user.type == "human") }
    }
    private var searchChannels:[ChatSearchEntity] {
        model.channels.filter{$0.supportsSearchSuggestion && (fixedChannelID == nil || fixedChannelID == $0.id) && model.canRead($0.id) && model.canBrowseConversationContent($0.id)}.map { channel in .init(id:channel.id,label:model.title(channel),aliases:[model.title(channel),channel.name].filter{!$0.isEmpty}) }
    }
    private var rawTrigger:ChatSearchCompletion.Trigger? { ChatSearchCompletion.trigger(text:query,selection:selection) }
    private var trigger:ChatSearchCompletion.Trigger? {
        guard let value = rawTrigger,value != dismissedTrigger,!value.prefix.isEmpty || focused else { return nil };return value
    }
    private var datePrefix:String? { trigger.flatMap{["before:","after:"].contains($0.prefix) ? $0.prefix : nil} }
    private var suggestions:[ChatSearchQuery.Suggestion] { trigger.map{ChatSearchQuery.suggestions(token:$0.prefix,users:searchUsers,channels:searchChannels)} ?? [] }

#if DEBUG
    private var renderingFixture = false
    static func renderResultsFixture(model:NativeChatPreviewModel,results:[ChatPost]) -> Self {
        var view = Self(model:model);view._query = State(initialValue:"proposal");view._allConversations = State(initialValue:true)
        view._results = State(initialValue:results);view._searched = State(initialValue:true);view.renderingFixture = true;return view
    }
    static func renderFixture(model:NativeChatPreviewModel,query:String,caret:Int? = nil,selected:Int? = nil,fixedChannelID:Int64? = nil) -> Self {
        var view = Self(model:model,fixedChannelID:fixedChannelID)
        view._query = State(initialValue:query);view._selection = State(initialValue:NSRange(location:caret ?? query.utf16.count,length:0));view._selectedSuggestion = State(initialValue:selected);view._focused = State(initialValue:true);view.renderingFixture = true;return view
    }
#endif
    var body: some View {
        let visibleSuggestions = suggestions
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing:12) {
                if let backToHashtags { Button { backToHashtags() } label: { Label("Hashtags",systemImage:"chevron.left") }.buttonStyle(.plain) }
                Image(systemName:"magnifyingglass").font(.system(size:21)).foregroundColor(NativeChatColors.green)
                Text(hashtag.map { "Messages tagged #" + $0 } ?? "Search messages").font(.system(size:20,weight:.bold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            HStack(spacing:10) {
                NativeSearchTextField(text:$query,selection:$selection,focused:$focused,placeholder:hashtag == nil ? "Words, phrases or search operators" : "Filter tagged messages",command:completionKey)
                    .frame(height:30)
                    .onChange(of: query) { _ in invalidateSearch() }
                Button("Search") { search() }.buttonStyle(NativeSendButtonStyle()).disabled(hashtag == nil && filters.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(8).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(focused ? NativeChatColors.green.opacity(0.65) : NativeChatColors.separator))
                .padding(.horizontal,20)
            if !visibleSuggestions.isEmpty,let displayedTrigger = trigger {
                NativeSearchSuggestions(suggestions:visibleSuggestions,selected:selectedSuggestion) { choose($0,using:displayedTrigger) }
                    .padding(.horizontal,20).padding(.top,8)
            }
            if let datePrefix {
                HStack {
                    DatePicker(datePrefix == "before:" ? "Before date" : "After date",selection:$suggestedDate,displayedComponents:.date).datePickerStyle(.field)
                    Button { showDateCalendar = true } label: { Image(systemName:"calendar") }
                        .accessibilityLabel("Choose search date from calendar")
                        .popover(isPresented:$showDateCalendar,arrowEdge:.bottom) {
                            VStack {
                                DatePicker("Search date",selection:$suggestedDate,displayedComponents:.date).datePickerStyle(.graphical).labelsHidden()
                                Button("Use date") { chooseDate(datePrefix);showDateCalendar = false }
                            }.padding(12)
                        }
                    Button("Use date") { chooseDate(datePrefix) }
                }.font(.caption).padding(.horizontal,20).padding(.top,8)
            }
            Text("Use from:, in:, has:, filetype:, before:, after:, @person or #tag.")
                .font(.caption).foregroundColor(NativeChatColors.muted).padding(.horizontal,20).padding(.top,8)
            if let fixedChannelID {
                Label("In " + channelTitle(fixedChannelID),systemImage:"bubble.left.and.bubble.right")
                    .font(.callout).foregroundColor(NativeChatColors.muted).padding(.horizontal,20).padding(.vertical,14)
            } else {
                Toggle("Search all conversations", isOn: $allConversations)
                    .toggleStyle(.switch).controlSize(.small).font(.callout).padding(.horizontal,20).padding(.vertical,12).disabled(model.selection == nil)
                    .onChange(of: allConversations) { _ in if searched { search() } }
            }
            DisclosureGroup(isExpanded:$filtersExpanded) {
                NativeSearchFilters(filters:$filters,users:model.directory,nameFormat:model.nameFormat)
            } label: {
                Text(filters.isEmpty ? "Filters" : "Filters applied").font(.system(size:12,weight:.medium))
            }.padding(.horizontal,20).padding(.bottom,14)
                .onChange(of:filters) { _ in invalidateSearch() }
            Divider().overlay(NativeChatColors.separator)
            if searched {
                Text(NativeLocalizedStrings.count("%lld messages shown",Int64(results.count))).font(.caption).foregroundColor(NativeChatColors.muted).padding(.horizontal,20).padding(.top,8)
                    .accessibilityIdentifier("message-search-loaded-count")
            }
            if let failure { Label(failure,systemImage:"exclamationmark.triangle").font(.callout).foregroundColor(.orange).textSelection(.enabled).padding(16) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !searched && !loading && failure == nil {
                        VStack(spacing:12) {
                            Image(systemName:"magnifyingglass").font(.system(size:30,weight:.light)).foregroundColor(NativeChatColors.muted)
                            Text("Find a message").font(.system(size:17,weight:.semibold))
                            Text("Search words, phrases, people or files.").font(.callout).foregroundColor(NativeChatColors.muted)
                        }.frame(maxWidth:.infinity).padding(.vertical,60)
                    }
                    if searched && results.isEmpty && !loading && failure == nil {
                        Text("No matching messages.").foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity).padding(.vertical,50)
                    }
                    ForEach(results) { post in
                        if model.canReadSearchResult(post) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Label(channelTitle(post.channel_id),systemImage:"bubble.left.and.bubble.right").font(.caption).foregroundColor(NativeChatColors.muted)
                                Spacer()
                                Button("Open message") {
                                    model.navigateToMessage(channelID: post.channel_id, postID: post.id, threadID: post.isReply ? post.thread_id : nil)
                                    dismiss()
                                }.font(.caption).buttonStyle(.link)
                                    .disabled(!model.canReadSearchResult(post))
                            }
                            HStack(spacing:10) {
                                NativeChatAvatar(name:model.names[post.creator_id] ?? "User \(post.creator_id)",size:28)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(model.names[post.creator_id] ?? "User \(post.creator_id)").font(.system(size:14,weight:.semibold))
                                    Text(model.formattedDate(post.date)).font(.caption).foregroundColor(NativeChatColors.muted)
                                }
                            }
                            NativeSearchResultContent(post:post,model:model,openImage:{ openImage(post) },openDocument:{ model.openSearchDocument(post,owner:previewOwner,playMedia:model.documentKind(post)?.isMedia == true) })
                            if post.isReply { Label("Thread reply",systemImage:"bubble.right").font(.caption).foregroundColor(NativeChatColors.muted) }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
                            .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
                            .accessibilityElement(children:.contain).accessibilityIdentifier("message-search-post-\(post.id)")
                        } else { Label("Message no longer available",systemImage:"lock").foregroundColor(NativeChatColors.muted) }
                    }
                    if hasMore && !loading { Button("More results") { search(more: true) }.buttonStyle(NativeToolbarButtonStyle()).frame(maxWidth:.infinity) }
                    if loading { ProgressView("Searching messages…").frame(maxWidth: .infinity).padding(16) }
                }.padding(20)
            }
        }.frame(width: 680, height: 640).background(NativeChatColors.canvas)
            .foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .onAppear {
#if DEBUG
                if renderingFixture { return }
#endif
                allConversations = fixedChannelID == nil && model.selection == nil;focused = true;if hashtag != nil { search() }
            }
            .onChange(of:focused) { if $0 { dismissedTrigger = nil } }
            .onChange(of:rawTrigger) { _ in selectedSuggestion = nil }
            .onChange(of:visibleSuggestions.map(\.id)) { _ in selectedSuggestion = nil }
            .onChange(of:datePrefix) { value in if value == nil { showDateCalendar = false } }
            .onChange(of:model.accountGeneration) { _ in invalidateSearch();dismiss() }
            .onChange(of:model.selection) { _ in if fixedChannelID == nil && !allConversations { invalidateSearch() } }
            .onChange(of:model.channels) { _ in
                if let fixedChannelID,!model.canRead(fixedChannelID) || !model.canBrowseConversationContent(fixedChannelID) { invalidateSearch();dismiss() }
                else if let activeQuery,activeQuery.filters.channelIDs.contains(where:{!model.canRead($0)}) { invalidateSearch() }
                else if let activeChannelID,!model.canRead(activeChannelID) { invalidateSearch() }
            }
            .onDisappear { searchTask?.cancel();closeOwnedImage();closeOwnedDocument() }
            .sheet(isPresented:Binding(get:{ model.searchImageOwner == previewOwner && model.imageViewerPost != nil },set:{ if !$0 { closeOwnedImage() } })) {
                NativeImageViewer(model:model,didJumpToSource:{ dismiss() })
            }
            .sheet(isPresented:Binding(get:{ model.searchDocumentOwner == previewOwner && model.documentPreviewIsPresented },set:{ if !$0 { closeOwnedDocument() } })) {
                NativeDocumentPreview(model:model,didJumpToSource:{ dismiss() })
            }
    }

    private func invalidateSearch() {
        closeOwnedImage()
        closeOwnedDocument()
        searchTask?.cancel(); revision = UUID()
        loading = false; searched = false; hasMore = false; results = []; failure = nil
        activeQuery = nil;activeChannelID = nil
    }
    private func closeOwnedImage() { if model.searchImageOwner == previewOwner { model.closeImageViewer() } }
    private func closeOwnedDocument() { if model.searchDocumentOwner == previewOwner { model.closeDocumentPreview() } }
    private func openImage(_ post:ChatPost) {
        guard !loading,model.canReadSearchImage(post) else { return }
        model.openSearchImage(post,context:results,owner:previewOwner,hasMore:hasMore,loadMore:{ try await loadMoreImages() })
    }
    @MainActor private func loadMoreImages() async throws -> ChatLibraryImagePage {
        guard model.searchImageOwner == previewOwner,!loading,let activeQuery else { throw CancellationError() }
        guard hasMore else { return .init(posts:results,hasMore:false,cursor:offset) }
        let expected = revision,epoch = model.accountGeneration,next = offset
        loading = true;defer { if revision == expected { loading = false } }
        let page = try await model.searchMessages(query:activeQuery.keyword,channelID:activeChannelID,offset:next,hashtag:hashtag,filters:activeQuery.filters)
        try Task.checkCancellation()
        guard revision == expected,model.accountGeneration == epoch,model.searchImageOwner == previewOwner,page.search_results.count <= 25 else { throw CancellationError() }
        var seen = Set(results.map(\.id));results += page.search_results.filter { seen.insert($0.id).inserted }
        offset = next+page.search_results.count
        hasMore = page.search_results.count >= 25 && (page.total.map { offset < $0 } ?? true)
        return .init(posts:results,hasMore:hasMore,cursor:offset)
    }

    private func channelTitle(_ id: Int64) -> String {
        model.channels.first(where: { $0.id == id }).map(model.title) ?? "Conversation \(id)"
    }
    private func choose(_ suggestion:ChatSearchQuery.Suggestion,using captured:ChatSearchCompletion.Trigger? = nil,requiresCurrentSuggestion:Bool = true) {
        guard let trigger = captured ?? trigger else { return }
        if requiresCurrentSuggestion,!ChatSearchQuery.suggestions(token:trigger.prefix,users:searchUsers,channels:searchChannels).contains(suggestion) { return }
        guard let edit = ChatSearchCompletion.applying(suggestion,trigger:trigger,text:query,selection:selection) else { return }
        query = edit.text;selection = edit.selection;selectedSuggestion = nil;focused = true
    }
    private func chooseDate(_ prefix:String) {
        let c = ChatSearchFilters.localCalendar,parts = c.dateComponents([.year,.month,.day],from:suggestedDate)
        guard let year = parts.year,let month = parts.month,let day = parts.day else { return }
        let value = prefix+String(format:"%04d-%02d-%02d",year,month,day)
        choose(.init(id:value,label:value,replacement:value),requiresCurrentSuggestion:false)
    }
    private func completionKey(_ key:NativeSearchFieldCommand) -> Bool {
        let options = suggestions
        switch key {
        case .previous,.next:
            guard !options.isEmpty else { return false }
            let direction = key == .next ? 1 : -1
            selectedSuggestion = selectedSuggestion.map{($0 + direction + options.count) % options.count} ?? (direction > 0 ? 0 : options.count - 1)
            return true
        case .tab:
            if let datePrefix { chooseDate(datePrefix);return true }
            guard !options.isEmpty else { return false };choose(options[min(selectedSuggestion ?? 0,options.count-1)]);return true
        case .submit:
            if let datePrefix { chooseDate(datePrefix) }
            else if let selectedSuggestion,options.indices.contains(selectedSuggestion) { choose(options[selectedSuggestion]) }
            else { search() }
            return true
        case .cancel:
            if trigger != nil && (!options.isEmpty || datePrefix != nil) { dismissedTrigger = rawTrigger;selectedSuggestion = nil }
            else { dismiss() }
            return true
        }
    }

    private func search(more: Bool = false) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || hashtag != nil || !filters.isEmpty else { return }
        let parsed:ChatSearchQuery
        let channelID:Int64?
        if more {
            guard !loading,hasMore,let activeQuery else { return }
            parsed = activeQuery;channelID = activeChannelID
        } else {
            do { parsed = try ChatSearchQuery.parse(text,base:filters,users:searchUsers,channels:searchChannels,fixedChannelID:fixedChannelID) }
            catch { failure = (error as? LocalizedError)?.errorDescription; return }
            channelID = fixedChannelID ?? (allConversations ? nil : model.selection)
            activeQuery = parsed;activeChannelID = channelID
            dismissedTrigger = rawTrigger;selectedSuggestion = nil
        }
        searchTask?.cancel()
        let key = UUID()
        revision = key
        if !more { results = []; offset = 0 }
        let nextOffset = offset
        let selectedFilters = parsed.filters
        loading = true; searched = true; failure = nil; hasMore = false
        searchTask = Task {
            defer { if revision == key { loading = false } }
            do {
                let page = try await model.searchMessages(query: parsed.keyword, channelID: channelID, offset: nextOffset, hashtag: hashtag, filters:selectedFilters)
                guard revision == key, !Task.isCancelled else { return }
                var seen = Set(results.map(\.id))
                results += page.search_results.filter { seen.insert($0.id).inserted }
                offset = nextOffset + page.search_results.count
                hasMore = page.search_results.count >= 25 && (page.total.map { offset < $0 } ?? true)
            } catch {
                guard revision == key, !Task.isCancelled else { return }
                failure = (error as? LocalizedError)?.errorDescription ?? "Search could not finish. Try again."
            }
        }
    }
}

struct NativeSearchResultContent:View {
    let post:ChatPost
    @ObservedObject var model:NativeChatPreviewModel
    let openImage:()->Void
    var openDocument:(()->Void)? = nil
    var body:some View {
        if model.canReadSearchResult(post) {
            VStack(alignment:.leading,spacing:10) {
                if post.type == "sticker" {
                    if let name = model.stickerName(post) { NativeStickerImage(assets:model.stickers,name:name,size:120) }
                    else { Label("Sticker unavailable",systemImage:"face.smiling").foregroundColor(NativeChatColors.muted) }
                } else if !post.message.isEmpty { NativeMessageText(post:post,model:model) }
                if model.canReadSearchImage(post) {
                    Button(action:openImage) { NativeImageThumbnail(post:post,model:model) }.buttonStyle(.plain).accessibilityLabel("Open search image: "+model.attachmentName(post))
                }
                if post.file_props?.name != nil {
                    HStack(spacing:10) {
                        Image(systemName:post.file_props?.is_image == true ? "photo" : "doc").foregroundColor(NativeChatColors.green)
                        VStack(alignment:.leading,spacing:3) {
                            Text(model.attachmentName(post)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if let size = post.file_props?.size,size >= 0 { Text(ByteCountFormatter.string(fromByteCount:size,countStyle:.file)).font(.caption).foregroundColor(NativeChatColors.muted) }
                        };Spacer()
                        if let openDocument,model.canPreviewSearchDocument(post) {
                            Button(model.documentKind(post)?.isMedia == true ? "Play" : "Preview",action:openDocument).buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Preview " + model.attachmentName(post))
                        }
                        Button("Save…") { Task { await model.saveAttachment(post) } }.buttonStyle(NativeToolbarButtonStyle()).disabled(model.downloading.contains(post.id))
                    }.padding(10).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:8))
                }
            }
        } else { Label("Message no longer available",systemImage:"lock").font(.callout).foregroundColor(NativeChatColors.muted) }
    }
}
