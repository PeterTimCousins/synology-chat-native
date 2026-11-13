import SwiftUI
import UniformTypeIdentifiers

struct NativePollComposer:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channelID:Int64
    let editing:ChatPollDetails?
    let saved:()->Void
    @State private var session:Int
    @State private var draft:ChatPollDraft
    @State private var busy = false
    @State private var uncertain = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var chooseLocal = false
    @State private var chooseNAS = false
    @Environment(\.dismiss) private var dismiss
    init(model:NativeChatPreviewModel,channelID:Int64,editing:ChatPollDetails? = nil,saved:@escaping ()->Void = {}) {
        self.model = model;self.channelID = channelID;self.editing = editing;self.saved = saved;_session = State(initialValue:model.pollSessionGeneration)
        _draft = State(initialValue:editing.map(ChatPollDraft.init) ?? model.pollDrafts[channelID] ?? ChatPollDraft())
    }
    private var partial:Bool { (editing?.poll.totalSelections ?? 0) > 0 }
#if DEBUG
    static func renderFixture(model:NativeChatPreviewModel,channelID:Int64,uncertain:Bool = false) -> Self {
        var view = Self(model:model,channelID:channelID);view._uncertain = State(initialValue:uncertain)
        if uncertain { view._failure = State(initialValue:ChatPollCreationFailure.uncertain.message) };return view
    }
#endif
    private var validation:String? { do { _ = try draft.validated();return nil } catch { return error.localizedDescription } }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label(editing == nil ? "Create a poll" : "Edit poll",systemImage:"chart.bar.xaxis").font(.system(size:20,weight:.bold));Spacer()
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Cancel poll editor").disabled(busy).keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if partial { Text("Voting has started. You can change the closing time and whether people may add options.").font(.callout).foregroundColor(NativeChatColors.muted) }
                    VStack(alignment:.leading,spacing:8) {
                        Text("Question").font(.callout.weight(.semibold))
                        TextField("What would you like to ask?",text:$draft.question,axis:.vertical).textFieldStyle(.roundedBorder).lineLimit(2...4).accessibilityLabel("Poll question").disabled(partial || busy)
                        Text("\(draft.question.utf16.count)/120").font(.caption).foregroundColor(draft.question.utf16.count > 120 ? .orange : NativeChatColors.muted).frame(maxWidth:.infinity,alignment:.trailing)
                    }
                    VStack(alignment:.leading,spacing:10) {
                        if editing == nil {
                            if let attachment = model.pollAttachments[channelID] {
                                HStack(spacing:12) {
                                    Image(systemName:"paperclip").foregroundColor(NativeChatColors.green)
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(attachment.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                        Text(attachment.sourceLabel + " · " + ByteCountFormatter.string(fromByteCount:attachment.size,countStyle:.file)).font(.caption).foregroundColor(NativeChatColors.muted)
                                    };Spacer()
                                    Button("Remove") { model.pollAttachments[channelID] = nil }.buttonStyle(NativeToolbarButtonStyle()).disabled(busy || uncertain)
                                }.padding(12).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                            } else {
                                Menu { Button("From this Mac…") { chooseLocal = true };Button("From NAS…") { chooseNAS = true }.disabled(!model.canChooseNASFiles()) } label: { Label("Add an attachment",systemImage:"paperclip") }.menuStyle(.borderlessButton).fixedSize().disabled(busy || uncertain)
                            }
                            Text("One file is included when you create the poll. The original stays in place.").font(.caption).foregroundColor(NativeChatColors.muted)
                        }
                        Text("Options").font(.callout.weight(.semibold))
                        ForEach($draft.choices) { $choice in
                            HStack(spacing:10) {
                                Image(systemName:"circle").foregroundColor(NativeChatColors.muted)
                                TextField("Enter an option",text:$choice.text).textFieldStyle(.roundedBorder).accessibilityLabel("Poll option \((draft.choices.firstIndex(where:{ $0.id == choice.id }) ?? 0)+1)")
                                Button { draft.choices.removeAll { $0.id == choice.id } } label: { Image(systemName:"minus.circle") }.buttonStyle(.plain).accessibilityLabel("Remove poll option").disabled(draft.choices.count <= 2)
                            }
                        }.disabled(partial || busy)
                        Button { draft.choices.append(.init(text:"")) } label: { Label("Add option",systemImage:"plus") }.buttonStyle(NativeToolbarButtonStyle()).disabled(partial || busy)
                    }
                    Divider().overlay(NativeChatColors.separator)
                    Toggle("Allow multiple choices",isOn:$draft.multiple).disabled(partial || busy)
                    Toggle("Anonymous voting",isOn:$draft.anonymous).disabled(partial || busy)
                    Text("Anonymous polls show vote counts without participant names.").font(.caption).foregroundColor(NativeChatColors.muted)
                    Toggle("Let people add options",isOn:$draft.allowAdd).disabled(busy)
                    Toggle("Close at a set time",isOn:$draft.expires).disabled(busy)
                    if draft.expires { DatePicker("Closing time",selection:$draft.expiry,displayedComponents:[.date,.hourAndMinute]).disabled(busy) }
                    if !draft.question.isEmpty,let validation { Text(validation).font(.callout).foregroundColor(.orange) }
                    if let failure { Text(failure).font(.callout).foregroundColor(.orange).textSelection(.enabled) }
                }.padding(24)
            }
            Divider().overlay(NativeChatColors.separator)
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Submitting…").font(.callout).foregroundColor(NativeChatColors.muted)
                    Button("Stop waiting") { task?.cancel();task = nil;busy = false;uncertain = editing == nil;failure = "Stopped waiting. Check the conversation before submitting again." }.buttonStyle(NativeToolbarButtonStyle())
                }
                Spacer()
                if uncertain { Button("Check conversation") { dismiss() }.buttonStyle(NativeSendButtonStyle()) }
                else { Button(editing == nil ? "Create poll" : "Save poll") { submit() }.buttonStyle(NativeSendButtonStyle()).disabled(busy || validation != nil || !model.canInteract) }
            }.padding(20)
        }.frame(minWidth:540,idealWidth:620,maxWidth:820,minHeight:600,idealHeight:740,maxHeight:850)
            .foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .interactiveDismissDisabled(busy)
            .onChange(of:draft) { value in if editing == nil,model.connected,model.pollSessionGeneration == session { model.pollDrafts[channelID] = value } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.pollSessionGeneration) { if $0 != session { dismiss() } }
            .onChange(of:model.selection) { if $0 != channelID { dismiss() } }
            .onChange(of:model.selectedChannel?.encrypted) { if $0 != false { dismiss() } }
            .onAppear { model.conversationLibraryVisible = true }
            .onDisappear { task?.cancel();task = nil;if editing == nil { model.conversationLibraryVisible = false } }
            .fileImporter(isPresented:$chooseLocal,allowedContentTypes:[.data]) { result in
                guard model.pollSessionGeneration == session,model.selection == channelID,model.canCreatePoll,!busy,!uncertain else { return }
                do { model.pollAttachments[channelID] = .local(try ChatPollLocalFile(result.get()));failure = nil }
                catch { if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription } }
            }
            .sheet(isPresented:$chooseNAS) {
                NativeNASFilePicker(model:model,inThread:false,maximumSelection:1) { selection in
                    guard selection.accountGeneration == session,selection.channelID == channelID,selection.files.count == 1,
                          model.pollSessionGeneration == session,model.selection == channelID,model.canCreatePoll,!busy,!uncertain,let file = selection.files.first else { return }
                    model.pollAttachments[channelID] = .nas(file);failure = nil
                }
            }
    }
    private func submit() {
        guard !busy,!uncertain,model.pollSessionGeneration == session else { return }
        busy = true;failure = nil
        task = Task {
            do {
                if let editing { _ = try await model.updatePoll(editing.post,action:.edit(draft)) }
                else { _ = try await model.createPoll(draft,attachment:model.pollAttachments[channelID]) }
                guard !Task.isCancelled,model.pollSessionGeneration == session else { return }
                busy = false;task = nil;saved();dismiss()
            } catch {
                guard !Task.isCancelled,model.pollSessionGeneration == session else { return }
                busy = false;task = nil
                if let error = error as? ChatPollCreationFailure { uncertain = !error.knownUnsent;failure = error.message }
                else if let error = error as? ChatPollError { failure = error.message }
                else if case ChatAPIError.server(let code) = error { failure = "The server rejected this poll change (\(code)). Your draft is kept." }
                else { uncertain = editing == nil;failure = "Delivery could not be confirmed. Check the conversation before creating another poll. Your draft is kept." }
            }
        }
    }
}
