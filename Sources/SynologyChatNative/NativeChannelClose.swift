import SwiftUI

struct NativeChannelCloseView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channel:ChatChannel
    @Environment(\.dismiss) private var dismiss
    @State private var preparation:ChatChannelClosePreparation?
    @State private var receipt:ChatArchive?
    @State private var understood = false
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var generation = -1
    @State private var showArchive = false
    private var pending:Bool { model.pendingChannelClosures[channel.id] != nil }
    private var noun:String { channel.type == "anonymous" ? "conversation" : "channel" }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text(receipt == nil ? "Close \(noun)" : "\(noun.capitalized) closed").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
            }
            Text(model.title(preparation?.channel ?? channel)).font(.headline).textSelection(.enabled)
            if receipt != nil {
                Label("Closed and archived",systemImage:"checkmark.circle.fill").foregroundColor(NativeChatColors.green)
                Text("The server confirmed that this \(noun) is no longer listed and its closed history is archived.")
                if channel.encrypted { Text("This archive is encrypted. Unlock it in archive history with your Chat encryption password.").foregroundColor(.orange) }
                Button("Browse archive history") { showArchive = true }
            } else {
                Text("Closing removes this \(noun) for its members and archives its messages. This operation cannot be undone.").foregroundColor(NativeChatColors.muted)
                if pending {
                    Text("A close request is unconfirmed. Check its status before taking further action.").foregroundColor(.orange)
                    Button("Check close status") { run(check:true) }.disabled(busy)
                } else {
                    Toggle("I understand this \(noun) will be closed.",isOn:$understood).toggleStyle(.checkbox).disabled(busy || preparation == nil)
                    HStack {
                        Button("Refresh review") { run() }.disabled(busy)
                        Spacer()
                        Button("Cancel") { dismiss() }.disabled(busy)
                        Button("Close \(noun)",role:.destructive) { run(close:true) }
                            .disabled(!understood || busy || preparation == nil || preparation.map { !model.canCloseChannel($0.channel) } == true)
                    }
                }
            }
            if let draft = model.drafts[channel.id],!draft.isEmpty {
                Text("Unsent draft — copy it before leaving this screen.").font(.callout.weight(.semibold))
                ScrollView { Text(draft).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:100).padding(10).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:8))
            }
            if busy { ProgressView("Checking \(noun) status…") }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).textSelection(.enabled) }
        }.padding(24).frame(width:590).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy)
            .onAppear { generation = model.accountGeneration;run(check:pending) }
            .onDisappear { task?.cancel() }
            .onChange(of:model.accountGeneration) { if $0 != generation { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .sheet(isPresented:$showArchive) { NativeArchivesView(model:model) }
    }
    private func run(check:Bool = false,close:Bool = false) {
        guard !busy else { return };busy = true;failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                if check { receipt = try await model.checkChannelClose(channelID:channel.id) }
                else if close,let preparation { receipt = try await model.closeChannel(preparation) }
                else { understood = false;preparation = try await model.prepareChannelClose(channelID:channel.id) }
            } catch is CancellationError { }
            catch { preparation = nil;understood = false;failure = error.localizedDescription }
        }
    }
}
