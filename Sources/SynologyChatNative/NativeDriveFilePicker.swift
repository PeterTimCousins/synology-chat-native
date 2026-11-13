import SwiftUI

struct NativeDriveFilePicker:View {
    @ObservedObject var model:NativeChatPreviewModel
    let inThread:Bool
    @Environment(\.dismiss) private var dismiss
    @State private var location:ChatDriveLocation = .myDrive
    @State private var folders:[(String,String)] = []
    @State private var files:[ChatDriveFile] = []
    @State private var teams:[ChatDriveTeamFolder] = []
    @State private var labels:[ChatDriveLabel] = []
    @State private var label:ChatDriveLabel?
    @State private var searchText = ""
    @State private var activeSearch:String?
    @State private var offset = 0
    @State private var hasMore = false
    @State private var review:ChatDriveReview?
    @State private var access = ChatDriveAccessDraft()
    @State private var confirmAccess = false
    @State private var savedAccess = false
    @State private var busy = false
    @State private var uncertain = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var epoch = -1
    @State private var channelID:Int64 = 0
    @State private var rootID:Int64?
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text(review == nil ? "Choose from Synology Drive" : "Review Drive link").font(.title2.bold());Spacer();Button("Cancel") {dismiss()}.disabled(busy)}
            if let review {
                Label(review.file.name,systemImage:review.file.isFolder ? "folder" : "doc").font(.headline).lineLimit(2)
                Text("Add a link to your message. You can review and send it afterward.").foregroundColor(NativeChatColors.muted)
                GroupBox("Access") {
                    VStack(alignment:.leading,spacing:8) {
                        Text("Current permissions").font(.headline)
                        Text("Creating this link does not grant conversation members access. Recipients may need to request access in Drive.").font(.callout).foregroundColor(NativeChatColors.muted)
                        if review.file.shared_with.isEmpty {Text("No explicit sharing entries reported.").font(.caption)}
                        ScrollView {VStack(alignment:.leading,spacing:6) {ForEach(Array(review.file.shared_with.enumerated()),id:\.offset) {_,entry in
                            Text(permissionDescription(entry)).font(.caption).textSelection(.enabled)
                        }}}.frame(maxHeight:80)
                        Picker("Link access",selection:$access.scope) {ForEach(scopes(review)) {Text($0.title).tag($0)}}.disabled(busy || uncertain).onChange(of:access.scope) {_ in access.role = .viewer}
                        if access.scope != .keep {
                            Picker("Permission",selection:$access.role) {ForEach(review.file.roles(for:access.scope)) {Text($0.title).tag($0)}}.disabled(busy || uncertain)
                            Text(accessDescription(review)).font(.caption).foregroundColor(access.scope == .publicLink ? .orange : NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                            Button("Review access change…") {confirmAccess = true}.disabled(busy || uncertain)
                        }
                        if savedAccess && access.scope == .keep {Text("Access change confirmed by the server.").font(.caption).foregroundColor(NativeChatColors.green)}
                        if !review.file.capabilities.can_organize {Text("You can share the existing link, but cannot change this item's permissions.").font(.caption).foregroundColor(NativeChatColors.muted)}
                        if review.policy.sharing_permission?.public_sharing == true && !review.policy.allowsPublicWithoutAdvancedSetup {Text("Public links require advanced security settings. Configure these in Synology Drive.").font(.caption).foregroundColor(NativeChatColors.muted)}
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
                }
                Spacer()
                if let failure {Text(failure).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)}
                if busy {ProgressView("Preparing Drive link…")}
                HStack {Button(uncertain ? "Refresh file" : "Back") {self.review = nil;uncertain = false;load()}.disabled(busy);Spacer();Button("Create link and add to message") {insert(review)}.disabled(busy || uncertain || access.scope != .keep || !model.canChooseDriveFiles(inThread:inThread))}
            } else {
                Picker("Location",selection:$location) {ForEach(ChatDriveLocation.allCases) {Text($0.title).tag($0)}}.disabled(busy).onChange(of:location) {_ in folders = [];label = nil;activeSearch = nil;searchText = "";load()}
                HStack {Button("Back") {if !folders.isEmpty {folders.removeLast()} else {label = nil};load()}.disabled(busy || (folders.isEmpty && label == nil));Text(folders.last?.1 ?? activeSearch.map {"Search: "+$0} ?? label?.name ?? location.title).font(.headline).lineLimit(1);Spacer();Button("Refresh") {load()}.disabled(busy)}
                HStack {
                    TextField("Search Drive",text:$searchText).onSubmit {search()}.disabled(busy)
                    Button("Search") {search()}.disabled(busy || searchText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || searchText.utf16.count > 512)
                    if activeSearch != nil {Button("Clear") {searchText = "";activeSearch = nil;folders = [];load()}.disabled(busy)}
                }
                ScrollView {
                    LazyVStack(spacing:6) {
                        ForEach(labels) {item in Button {label = item;folders = [];load()} label:{row(item.name,detail:"Open label",symbol:"tag")}.buttonStyle(.plain).disabled(busy)}
                        ForEach(teams) {team in Button {folders.append((team.id,team.name));load()} label:{row(team.name,detail:"Open team folder",symbol:"externaldrive")}.buttonStyle(.plain).disabled(busy || !team.capabilities.can_read)}
                        ForEach(files) {file in HStack {
                            if file.isFolder {Button {folders.append((file.id,file.name));load()} label:{row(file.name,detail:"Open folder",symbol:"folder")}.buttonStyle(.plain).disabled(busy || !file.selectable);Button("Choose folder") {select(file)}.disabled(busy || !file.selectable)}
                            else {Button {select(file)} label:{row(file.name,detail:file.selectable ? ByteCountFormatter.string(fromByteCount:file.size,countStyle:.file) : "Unavailable for link sharing",symbol:"doc")}.buttonStyle(.plain).disabled(busy || !file.selectable)}
                        }}
                        if !busy && files.isEmpty && teams.isEmpty && labels.isEmpty && failure == nil {Text("No items here").foregroundColor(NativeChatColors.muted).padding(30)}
                        if hasMore {Button("Load more") {load(more:true)}.disabled(busy)}
                        if busy {ProgressView("Loading Drive…").padding(24)}
                    }
                }.frame(height:320)
                if let failure {Text(failure).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)}
                Text("Files stay in Drive. Review access before adding a link.").font(.caption).foregroundColor(NativeChatColors.muted)
            }
        }.padding(24).frame(width:680,height:review == nil ? 530 : 650).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .confirmationDialog("Change access to this Drive item?",isPresented:$confirmAccess,titleVisibility:.visible) {
                Button("Apply access change") {changeAccess()}
                Button("Cancel",role:.cancel) {}
            } message: {Text((review?.file.name ?? "Drive item")+"\n"+(review.map(accessDescription) ?? ""))}
            .onAppear {epoch = model.accountGeneration;channelID = model.selection ?? 0;rootID = inThread ? model.threadRoot?.id : nil;model.conversationLibraryVisible = true;load()}
            .onDisappear {task?.cancel();model.conversationLibraryVisible = false}
            .onChange(of:model.accountGeneration) {if $0 != epoch {dismiss()}}.onChange(of:model.connected) {if !$0 {dismiss()}}
            .onChange(of:model.selection) {if $0 != channelID {dismiss()}}.onChange(of:model.threadRoot?.id) {if inThread && $0 != rootID {dismiss()}}
    }
    private func permissionDescription(_ entry:ChatJSON)->String {
        let type = entry["type"]?.string ?? "Unknown access",name = entry["display_name"]?.string ?? entry["name"]?.string ?? type,role = entry["role"]?.string ?? "Unknown role"
        return name+" · "+role
    }
    private func row(_ name:String,detail:String,symbol:String)->some View {HStack(spacing:12) {Image(systemName:symbol).frame(width:24).foregroundColor(NativeChatColors.green);VStack(alignment:.leading,spacing:3) {Text(name).lineLimit(1).truncationMode(.middle);Text(detail).font(.caption).foregroundColor(NativeChatColors.muted)};Spacer()}.padding(10).contentShape(Rectangle())}
    private func load(more:Bool = false) {
        guard !busy else {return};busy = true;failure = nil;let next = more ? offset : 0
        if !more {files = [];teams = [];labels = [];offset = 0;hasMore = false}
        task = Task { @MainActor in
            defer {busy = false}
            do {
                let page = try await model.loadDriveFiles(location:location,folderID:folders.last?.0,offset:next,channelID:channelID,rootID:rootID,epoch:epoch,labelID:folders.isEmpty ? label?.id : nil,query:folders.isEmpty ? activeSearch : nil);try Task.checkCancellation()
                guard !more || !(page.files.isEmpty && page.teams.isEmpty && page.labels.isEmpty && page.hasMore),!page.files.contains(where:{new in files.contains(where:{$0.id == new.id})}),!page.teams.contains(where:{new in teams.contains(where:{$0.id == new.id})}),!page.labels.contains(where:{new in labels.contains(where:{$0.id == new.id})}) else {throw ChatTransferError(message:"Drive changed while loading. Refresh before continuing.")}
                files += page.files;teams += page.teams;labels += page.labels;offset = next+page.files.count+page.teams.count+page.labels.count;hasMore = page.hasMore
            } catch is CancellationError {} catch {failure = error.localizedDescription}
        }
    }
    private func search() {
        guard !busy else {return};let value = searchText.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.utf16.count <= 512 else {return};activeSearch = value;folders = [];label = nil;load()
    }
    private func select(_ file:ChatDriveFile) {
        busy = true;failure = nil
        task = Task { @MainActor in defer {busy = false};do {review = try await model.reviewDriveFile(file,channelID:channelID,rootID:rootID,epoch:epoch);access = .init();savedAccess = false;try Task.checkCancellation()} catch is CancellationError {} catch {failure = error.localizedDescription} }
    }
    private func scopes(_ review:ChatDriveReview)->[ChatDriveAccessScope] {
        ChatDriveAccessScope.allCases.filter {$0 == .keep || review.file.permissionEdits(.init(scope:$0,role:.viewer),recipients:review.recipients,policy:review.policy) != nil}
    }
    private func accessDescription(_ review:ChatDriveReview)->String {
        let role = access.role.title.lowercased()
        switch access.scope {
        case .keep:return "Keep the current permissions."
        case .members:return "Give "+review.recipients.map(\.name).joined(separator:", ")+" permission to "+role+". Guests and bots are excluded. Existing roles for these people will be replaced; other access stays as shown above."
        case .internalLink:return "People on this NAS who have the link will be able to "+role+". This replaces any public link policy; individual permissions stay as shown above."
        case .publicLink:return "Anyone with this link will be able to "+role+" without signing in. This replaces any internal link policy; individual permissions stay as shown above."
        }
    }
    private func changeAccess() {
        guard let review else {return};busy = true;failure = nil;let proposed = access
        task = Task { @MainActor in
            defer {busy = false}
            do {self.review = try await model.changeDriveAccess(review,draft:proposed);access = .init();savedAccess = true}
            catch {uncertain = true;failure = error.localizedDescription+" Refresh to inspect current access before another change."}
        }
    }
    private func insert(_ review:ChatDriveReview) {
        busy = true;failure = nil
        task = Task { @MainActor in
            defer {busy = false}
            do {try await model.insertDriveLink(review);dismiss()}
            catch is CancellationError {uncertain = true;failure = "Link preparation was interrupted. Refresh the file before trying again; no chat message was sent."}
            catch {uncertain = true;failure = error.localizedDescription+" No chat message was sent. Refresh the file before trying again."}
        }
    }
}
