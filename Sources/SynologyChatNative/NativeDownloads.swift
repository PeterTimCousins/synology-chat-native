import SwiftUI
import AppKit

struct NativeDownloadsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showSettings = false
    @State private var clearAll = false
    @State private var epoch = -1
    private var records: [ChatDownloadRecord] { model.downloadHistory.filter { query.isEmpty || model.downloadName($0).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Downloads").font(.title2.bold()); Spacer()
                Button("Refresh files") { Task { await model.refreshDownloadFiles() } }.disabled(model.checkingDownloadFiles)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Find a download", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(records) { record in NativeDownloadRow(model: model, record: record) }
                    if records.isEmpty { Text(query.isEmpty ? "No downloads in this session" : "No matching downloads").foregroundColor(NativeChatColors.muted).frame(maxWidth: .infinity).padding(.vertical, 60) }
                }
            }.frame(height: 350)
            HStack {
                Button("Clear finished") { model.clearDownloadHistory() }.disabled(!model.downloadHistory.contains { !$0.state.active })
                if model.downloadHistory.contains(where: { $0.state.active }) { Button("Cancel all and clear…") { clearAll = true } }
                Spacer(); Button("Download settings…") { showSettings = true }
            }
            Text("History is kept for this account until sign-out or quitting. Clearing history leaves saved files in place.").font(.caption).foregroundColor(NativeChatColors.muted)
        }.padding(24).frame(width: 720).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; Task { await model.refreshDownloadFiles() } }
            .onDisappear { model.conversationLibraryVisible = false }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
            .sheet(isPresented: $showSettings) { NativeDownloadSettingsView(preferences: model.downloadPreferences) }
            .confirmationDialog("Cancel active downloads and clear this list?", isPresented: $clearAll, titleVisibility: .visible) {
                Button("Cancel downloads and clear history", role: .destructive) { model.clearDownloadHistory(cancelActive: true) }
                Button("Keep downloads", role: .cancel) { }
            } message: { Text("Downloads still running will stop. Saved files will stay on your Mac.") }
    }
}
private struct NativeDownloadRow: View {
    @ObservedObject var model: NativeChatPreviewModel
    @ObservedObject var record: ChatDownloadRecord
    @ObservedObject private var opening: ChatSavedFileOpening
    init(model: NativeChatPreviewModel, record: ChatDownloadRecord) {
        self.model = model; self.record = record; self.opening = model.savedFileOpening
    }
    private var locked: Bool { model.downloadIsLocked(record) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: locked ? "lock" : record.state == .saved ? "doc" : "arrow.down.circle").foregroundColor(NativeChatColors.green)
                Text(model.downloadName(record)).font(.headline).lineLimit(1).help(locked ? "Unlock the conversation to view this download" : record.filename)
                Spacer(); Text(record.startedAt, style: .time).font(.caption).foregroundColor(NativeChatColors.muted)
            }
            Text(record.progressLabel).font(.caption).foregroundColor(record.state == .failed ? .orange : NativeChatColors.muted)
            if record.state == .transferring { if let fraction = record.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) } }
            if record.state == .saved, let failure = record.failure { Text(failure).foregroundColor(.orange).font(.caption) }
            HStack {
                if record.state.active { Button("Cancel download") { model.cancelDownload(postID: record.postID) } }
                else {
                    if record.state == .saved {
                        Button("Open") { Task { await model.openDownload(record.id) } }.disabled(opening.busy || !model.canUseSavedDownload(record))
                        Button("Show in Folder") { Task { await model.openDownload(record.id, reveal: true) } }.disabled(!model.canUseSavedDownload(record))
                    }
                    Button(record.state == .saved ? "Save another copy…" : "Retry…") { Task { await model.retryDownload(record.id) } }.disabled(!model.canRetryDownload(record))
                }
                Spacer()
            }
        }.padding(14).background(NativeChatColors.surface).cornerRadius(10)
    }
}
struct NativeDownloadSettingsView: View {
    @ObservedObject var preferences: ChatDownloadPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var panel: NSOpenPanel?
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"arrow.down.to.line").font(.system(size:22)).foregroundColor(NativeChatColors.green)
                Text("Download settings").font(.system(size:20,weight:.bold));Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("Choose the folder where Save dialogs start. Every attachment still asks you to choose its filename and location.")
                    .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                VStack(alignment:.leading,spacing:14) {
                    Label("Save location",systemImage:"folder").font(.system(size:14,weight:.semibold))
                    Text(preferences.lastFolder?.path ?? "Default Downloads folder").textSelection(.enabled).font(.callout)
                        .lineLimit(3).truncationMode(.middle).help(preferences.lastFolder?.path ?? "Default Downloads folder")
                    HStack(spacing:12) {
                Button("Choose folder…") {
                    let next = NSOpenPanel(); next.title = "Choose download folder"; next.prompt = "Use Folder"; next.canChooseDirectories = true; next.canChooseFiles = false; next.allowsMultipleSelection = false; next.directoryURL = preferences.lastFolder; panel = next
                    next.begin { result in
                        Task { @MainActor in if result == .OK, let url = next.url { preferences.chooseFolder(url) }; panel = nil }
                    }
                }.buttonStyle(NativeSendButtonStyle()).disabled(panel != nil)
                Button("Use default folder") { preferences.reset() }.buttonStyle(NativeToolbarButtonStyle()).disabled(preferences.lastFolder == nil || panel != nil)
                    }
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                    .background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
                    .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
                Text("After a successful location choice, the next Save dialog starts in that folder.")
                    .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.frame(width:600,height:360).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .onDisappear { panel?.cancel(nil) }
    }
}
