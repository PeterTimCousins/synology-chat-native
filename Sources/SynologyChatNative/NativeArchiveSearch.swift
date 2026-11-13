import SwiftUI

struct NativeArchiveSearchView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let kind:ChatArchiveKind
    let name:String
    let scopes:[ChatArchive]
    let onOpen:(ChatArchiveMatch)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var submitted = ""
    @State private var collection:ChatArchiveCollection = .messages
    @State private var selectedPeriod:Int64 = 0
    @State private var matches:[ChatArchiveMatch] = []
    @State private var total:Int?
    @State private var offset = 0
    @State private var hasMore = false
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var session = -1
    private var readable:[ChatArchive] { scopes.filter { $0.isReadable && model.canReadArchive($0) && model.archivePeriodPresentation($0).isAvailable } }
    private var chosen:[ChatArchive] { readable.filter { selectedPeriod == 0 || $0.id == selectedPeriod } }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text("Search archived history").font(.system(size:20,weight:.bold))
                Spacer()
                Button { dismiss() } label:{ Image(systemName:"xmark") }.accessibilityLabel("Close archive search").keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            HStack {
                TextField("Search message text",text:$query).textFieldStyle(.roundedBorder).onSubmit { search(reset:true) }.accessibilityLabel("Search archived message text")
                Button("Search") { search(reset:true) }.disabled(busy || query.utf16.count > 1000)
            }.padding(.horizontal,20).padding(.bottom,12)
            HStack {
                Picker("Archive period",selection:$selectedPeriod) {
                    Text("All periods").tag(Int64(0))
                    ForEach(readable) { Text(period($0)).tag($0.id) }
                }
                if let total { Text(NativeLocalizedStrings.count("%lld results",Int64(total))).font(.caption).foregroundColor(NativeChatColors.muted) }
            }.padding(.horizontal,20).padding(.bottom,12)
            Picker("Archived collection",selection:$collection) { ForEach(ChatArchiveCollection.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).padding(.horizontal,20).padding(.bottom,14)
            Divider()
            if let failure { Text(failure).foregroundColor(.orange).padding(12) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    if matches.isEmpty && !busy && failure == nil { Text("No matching archived messages").foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity).padding(.vertical,70) }
                    ForEach(matches) { match in
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                Text(model.names[match.post.displayAuthorID] ?? "User \(match.post.displayAuthorID)").font(.headline)
                                Spacer()
                                Text(model.formattedDate(match.post.date)).font(.caption).foregroundColor(NativeChatColors.muted)
                            }
                            if (match.post.delete_at ?? 0) > 0 { Text("Message deleted").italic() }
                            else if match.post.type == "system" { Text(match.post.systemEventText(names:model.names)) }
                            else {
                                ForEach(Array(ChatMessageFormatting.blocks(model.archiveMessageText(match.post,archive:match.archive)).enumerated()),id:\.offset) { item in
                                    NativeFormattedMessageBlock(block:item.element,mentions:model.mentionNames,hashtagLinks:false)
                                }.environment(\.openURL,OpenURLAction { _ in .discarded })
                                if match.post.file_props != nil { Label(model.archiveFilename(match.post,archive:match.archive),systemImage:"doc").font(.callout) }
                            }
                            HStack {
                                Text(period(match.archive)).font(.caption).foregroundColor(NativeChatColors.muted)
                                Spacer()
                                Button(match.post.isReply ? "Open archived reply" : "Open archived message") { onOpen(match);dismiss() }.disabled(busy || !model.canReadArchive(match.archive))
                            }
                        }.textSelection(.enabled).padding(16).frame(maxWidth:.infinity,alignment:.leading).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                    }
                    if busy { ProgressView("Searching archive history…").frame(maxWidth:.infinity).padding(20) }
                    if hasMore && !busy { Button("Load more archived results") { search(reset:false) }.frame(maxWidth:.infinity) }
                }.padding(20)
            }
            Text("Encrypted message text may not appear in search results. Browse an archive period to read all its messages.").font(.caption).foregroundColor(NativeChatColors.muted).padding(12)
        }.frame(width:800,height:620).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .onAppear { session = model.accountGeneration;search(reset:true) }
            .onDisappear { task?.cancel();request = UUID() }
            .onChange(of:model.archiveContentEpoch) { _ in
                if scopes.contains(where:{ $0.props.channel.encrypted }) {
                    task?.cancel();request = UUID();matches = [];total = nil;query = "";submitted = "";busy = false;dismiss()
                }
            }
            .onChange(of:collection) { _ in search(reset:true) }
            .onChange(of:selectedPeriod) { _ in search(reset:true) }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
    }
    private func period(_ item:ChatArchive)->String {
        model.archivePeriodPresentation(item).label
    }
    private func search(reset:Bool) {
        task?.cancel();request = UUID();let id = request
        if reset { matches = [];total = nil;offset = 0;submitted = query;hasMore = false }
        let start = offset,keyword = submitted,category = collection,periods = chosen,epoch = model.archiveContentEpoch
        guard !periods.isEmpty,keyword.utf16.count <= 1000 else { busy = false;failure = "Choose a readable archive period and a search of up to 1,000 characters.";return }
        busy = true;failure = nil
        task = Task { @MainActor in
            defer { if request == id { busy = false } }
            do {
                let result = try await model.searchArchivedMessages(kind:kind,name:name,scopes:periods,query:keyword,collection:category,offset:start)
                try Task.checkCancellation();guard request == id,model.archiveContentEpoch == epoch else { return }
                let known = Set(matches.map(\.id)),new = result.matches.filter { !known.contains($0.id) }
                matches += new;total = result.total;offset = result.nextOffset
                hasMore = !new.isEmpty && result.matches.count == 25 && (result.total == nil || offset < result.total!)
            } catch is CancellationError { }
            catch { if request == id { failure = "Could not search archive history. Refresh the archive and try again." } }
        }
    }
}
