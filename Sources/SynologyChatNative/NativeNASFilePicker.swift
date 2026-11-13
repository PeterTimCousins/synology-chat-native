import SwiftUI

struct NativeNASFilePicker:View {
    @ObservedObject var model:NativeChatPreviewModel
    let inThread:Bool
    var maximumSelection:Int = 100
    let choose:(ChatNASSelection)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var roots:[ChatNASRoot] = []
    @State private var files:[ChatNASFile] = []
    @State private var selected:[ChatNASFile] = []
    @State private var folders:[(String,String)] = []
    @State private var offset = 0
    @State private var total = 0
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var channelID:Int64 = 0
    @State private var rootID:Int64?
    private var folder:String? {folders.last?.0}
    private var selectionLimit:Int { min(100,max(1,maximumSelection)) }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text("Choose files from NAS").font(.title2.bold());Spacer();Button("Refresh") {load()}.disabled(busy);Button("Cancel") {dismiss()}}
            Text("Select files to review before sending to this conversation. Originals stay on the NAS.").font(.callout).foregroundColor(NativeChatColors.muted)
            HStack {Button("Back") {guard !folders.isEmpty else {return};folders.removeLast();load()}.disabled(busy || folders.isEmpty);Text(folders.last?.1 ?? "Shared folders").font(.headline).lineLimit(1).truncationMode(.middle);Spacer();Text("\(selected.count) selected").font(.caption).foregroundColor(NativeChatColors.muted)}
            ScrollView {
                LazyVStack(spacing:6) {
                    if folder == nil {
                        ForEach(roots) {root in Button {folders.append((root.spath,root.text));load()} label:{row(root.text,symbol:"externaldrive",detail:ChatNASFile.validPath(root.spath) ? "Open shared folder" : "Open this location from the official client")}.buttonStyle(.plain).disabled(busy || !ChatNASFile.validPath(root.spath))}
                        if !busy && roots.isEmpty && failure == nil {Text("No shared folders available").foregroundColor(NativeChatColors.muted).padding(30)}
                    } else {
                        ForEach(files) {file in
                            HStack {
                                if file.isdir {Button {folders.append((file.path,file.name));load()} label:{row(file.name,symbol:"folder",detail:"Open folder")}.buttonStyle(.plain).disabled(busy)}
                                else {Toggle(isOn:Binding(get:{selected.contains(where:{$0.path == file.path})},set:{enabled in if enabled {if selected.count < selectionLimit {selected.append(file)}} else {selected.removeAll {$0.path == file.path}}})) {row(file.name,symbol:"doc",detail:ByteCountFormatter.string(fromByteCount:file.additional.size,countStyle:.file))}.toggleStyle(.checkbox).disabled(busy || !file.selectable || (selected.count >= selectionLimit && !selected.contains(where:{$0.path == file.path})))}
                            }.padding(.horizontal,8).padding(.vertical,5)
                        }
                        if !busy && files.isEmpty && failure == nil {Text("This folder is empty").foregroundColor(NativeChatColors.muted).padding(30)}
                        if offset < total {Button("Load more") {load(more:true)}.disabled(busy)}
                    }
                    if busy {ProgressView("Loading NAS files…").padding(24)}
                }
            }.frame(height:350)
            if let failure {Text(failure).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)}
            HStack {Button("Clear selection") {selected = []}.disabled(selected.isEmpty || busy);Spacer();Button(selectionLimit == 1 ? "Use selected file" : "Review \(selected.count) files") {choose(.init(files:selected,channelID:channelID,rootID:rootID,accountGeneration:epoch));dismiss()}.disabled(selected.isEmpty || busy || !model.canChooseNASFiles(inThread:inThread))}
        }.padding(24).frame(width:660).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .onAppear {epoch = model.accountGeneration;channelID = model.selection ?? 0;rootID = inThread ? model.threadRoot?.id : nil;model.conversationLibraryVisible = true;load()}
            .onDisappear {task?.cancel();model.conversationLibraryVisible = false}
            .onChange(of:model.accountGeneration) {if $0 != epoch {dismiss()}}.onChange(of:model.connected) {if !$0 {dismiss()}}
            .onChange(of:model.selection) {if $0 != channelID {dismiss()}}.onChange(of:model.threadRoot?.id) {if inThread && $0 != rootID {dismiss()}}
    }
    private func row(_ name:String,symbol:String,detail:String)->some View {HStack(spacing:12) {Image(systemName:symbol).frame(width:24).foregroundColor(NativeChatColors.green);VStack(alignment:.leading,spacing:3) {Text(name).lineLimit(1).truncationMode(.middle);Text(detail).font(.caption).foregroundColor(NativeChatColors.muted)};Spacer()}.padding(8).contentShape(Rectangle())}
    private func load(more:Bool = false) {
        guard !busy else {return};busy = true;failure = nil;let key = UUID();request = key;let path = folder,next = more ? offset : 0
        if !more {files = [];offset = 0;total = 0;if path == nil {roots = []}}
        task = Task { @MainActor in
            defer {if request == key {busy = false}}
            do {
                if let path {
                    let page = try await model.loadNASFiles(folder:path,offset:next,channelID:channelID,rootID:rootID,epoch:epoch)
                    try Task.checkCancellation();guard request == key else {return}
                    guard !more || !page.files.isEmpty else {throw ChatTransferError(message:"The folder changed while loading. Refresh before continuing.")}
                    guard !more || !page.files.contains(where:{new in files.contains(where:{$0.path == new.path})}) else {throw ChatTransferError(message:"The folder changed while loading. Refresh before continuing.")}
                    files = more ? files+page.files : page.files;offset = page.offset+page.files.count;total = page.total
                } else {
                    let result = try await model.loadNASRoots(channelID:channelID,rootID:rootID,epoch:epoch)
                    try Task.checkCancellation();guard request == key else {return};roots = result
                }
            } catch is CancellationError {} catch {if request == key {failure = error.localizedDescription}}
        }
    }
}
