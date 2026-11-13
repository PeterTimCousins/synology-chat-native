import SwiftUI
import AppKit

struct NativeApplicationLauncherView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot:ChatLauncherSnapshot?
    @State private var applications:[ChatLauncherApplication] = []
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var confirmDiscard = false
    private var dirty:Bool {snapshot.map {$0.applications.map(\.appname) != applications.map(\.appname)} ?? false}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("Synology apps").font(.title2.bold());Spacer();Button("Refresh") {if dirty {confirmDiscard = true} else {run()}}.disabled(busy);Button("Done") {if dirty {confirmDiscard = true} else {dismiss()}}.disabled(busy)}
            Text("Open applications available to your account in your default browser. Use the arrows to arrange this shared Synology launcher.").font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
            if snapshot != nil {
                if applications.isEmpty {Label("No applications available",systemImage:"square.grid.2x2").padding(.vertical,24)}
                else {
                    ScrollView {
                        LazyVStack(spacing:12) {
                            ForEach(Array(applications.enumerated()),id:\.element.id) { index,app in
                                HStack(alignment:.center,spacing:12) {
                                    Image(systemName:Self.symbol(app.appname)).font(.title2).frame(width:30).foregroundColor(NativeChatColors.green)
                                    VStack(alignment:.leading,spacing:5) {HStack {Text(app.name.isEmpty ? app.appname : app.name).font(.headline);if let badge = app.badge,badge > 0 {Text(badge > 999 ? "999+" : String(badge)).font(.caption.bold()).padding(.horizontal,7).padding(.vertical,2).background(NativeChatColors.selected).clipShape(Capsule()).accessibilityLabel("\(badge) unread")}};if !app.description.isEmpty {Text(app.description).font(.caption).foregroundColor(NativeChatColors.muted).lineLimit(2)}}
                                    if !model.launcherCanOpen(app) {Text("Open this route from the official client").font(.caption).foregroundColor(.orange)}
                                    Spacer()
                                    Button {move(index,-1)} label:{Image(systemName:"arrow.up")}.accessibilityLabel("Move \(app.name) up").disabled(busy || index == 0)
                                    Button {move(index,1)} label:{Image(systemName:"arrow.down")}.accessibilityLabel("Move \(app.name) down").disabled(busy || index == applications.count-1)
                                    Button("Open") {run(open:app)}.disabled(busy || dirty || model.launcherNeedsRefresh || !model.launcherCanOpen(app)).accessibilityLabel("Open \(app.name)")
                                }.padding(14).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                            }
                        }
                    }.frame(height:min(420,CGFloat(applications.count)*88))
                    HStack {Button("Discard order changes") {applications = snapshot?.applications ?? []}.disabled(!dirty || busy);Spacer();Button("Save order") {run(save:true)}.disabled(!dirty || busy || model.launcherNeedsRefresh)}
                }
            }
            if busy {ProgressView("Checking applications…");Button("Stop waiting") {request = UUID();task?.cancel();busy = false;failure = "Stopped waiting. Refresh to check the current application list."}}
            if let failure {Text(failure).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
            if model.launcherNeedsRefresh {Text("Refresh before opening apps or saving another order.").foregroundColor(.orange)}
        }.padding(24).frame(width:700).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy || dirty)
            .confirmationDialog("Discard the unsaved application order?",isPresented:$confirmDiscard,titleVisibility:.visible) {Button("Discard and refresh",role:.destructive) {run()};Button("Discard and close",role:.destructive) {dismiss()};Button("Keep arranging",role:.cancel) {}}
            .onAppear {epoch = model.accountGeneration;model.conversationLibraryVisible = true;run()}.onDisappear {task?.cancel();model.conversationLibraryVisible = false}
            .onChange(of:model.accountGeneration) {if $0 != epoch {dismiss()}}.onChange(of:model.connected) {if !$0 {dismiss()}}
    }
    static func symbol(_ name:String)->String {
        switch name {case "SYNO.SDS.Chat.Application":return "bubble.left.and.bubble.right";case "SYNO.Cal.Application":return "calendar";case "SYNO.SDS.Drive.Application":return "externaldrive";case "SYNO.Foto.AppInstance":return "photo.on.rectangle";case "SYNO.Contacts.AppInstance":return "person.crop.rectangle";case "SYNO.SDS.MailClient.Application":return "envelope";default:return "square.grid.2x2"}
    }
    private func move(_ index:Int,_ step:Int) {guard applications.indices.contains(index+step) else {return};applications.swapAt(index,index+step)}
    private func run(save:Bool = false,open:ChatLauncherApplication? = nil) {
        guard !busy else {return};busy = true;failure = nil;let key = UUID();request = key;let names = applications.map(\.appname)
        task = Task { @MainActor in
            defer {if request == key {busy = false}}
            do {
                if let open,let snapshot {
                    let url = try await model.resolveLauncherApplication(open,original:snapshot)
                    try Task.checkCancellation();guard request == key,model.connected,model.accountGeneration == snapshot.accountGeneration else {return}
                    guard NSWorkspace.shared.open(url) else {throw ChatTransferError(message:"The browser could not open this application.")};return
                }
                let result:ChatLauncherSnapshot
                if save,let snapshot {result = try await model.saveLauncherOrder(names,original:snapshot)} else {result = try await model.loadLauncherApplications()}
                try Task.checkCancellation();guard request == key else {return};snapshot = result;applications = result.applications
            } catch is CancellationError {} catch {if request == key {failure = error.localizedDescription}}
        }
    }
}
