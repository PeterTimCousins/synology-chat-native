import SwiftUI

struct NativeScheduleComposer:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channelID:Int64
    var editing:ChatScheduledMessage? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ChatScheduleDraft()
    @State private var initialized = false
    @State private var session = -1
    @State private var busy = false
    @State private var uncertain = false
    @State private var failure:String?
    @State private var confirmed:ChatScheduledMessage?
    @State private var task:Task<Void,Never>?
    @State private var emoji = false
    @State private var focused = false
    @State private var selection = NSRange(location:NSNotFound,length:0)
    private var valid:Bool { (try? draft.validated()) != nil }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Label(editing == nil ? "Schedule a message" : "Edit scheduled message",systemImage:"clock.badge.checkmark").font(.system(size:20,weight:.bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close scheduled message editor").disabled(busy)
            }.padding(20).buttonStyle(NativeToolbarButtonStyle())
            Divider().overlay(NativeChatColors.separator)
            if let confirmed {
                VStack(alignment:.leading,spacing:16) {
                    Label("Scheduled",systemImage:"checkmark.circle.fill").font(.title2.weight(.semibold)).foregroundColor(NativeChatColors.green)
                    Text(model.formattedDate(confirmed.date)).font(.headline)
                    Text(confirmed.message).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
                    Text("Synology Chat will send this even when the app is closed. You can edit or cancel it in Scheduled messages.").font(.callout).foregroundColor(NativeChatColors.muted)
                }.padding(24)
                Spacer()
            } else if editing != nil || (model.pendingScheduledCreations[channelID] == nil && model.scheduleCreationRecoveryError == nil) {
                VStack(alignment:.leading,spacing:14) {
                    Text(model.channels.first(where:{ $0.id == channelID }).map(model.title) ?? "Conversation").font(.headline)
                    HStack {
                        DatePicker("Send at",selection:Binding(get:{ draft.date },set:{ draft.date = ChatScheduleDraft.minutePrecision($0) }),displayedComponents:[.date,.hourAndMinute]).datePickerStyle(.field).accessibilityLabel("Scheduled send time")
                        Menu("Quick times") {
                            ForEach([10,20,60,120,240,480,1440],id:\.self) { minutes in
                                Button(minutes < 60 ? "In \(minutes) minutes" : minutes == 60 ? "In 1 hour" : minutes < 1440 ? "In \(minutes/60) hours" : "In 1 day") { draft.date = Date(timeIntervalSinceNow:Double(minutes*60)) }
                            }
                        }.fixedSize()
                    }
                    Text("Times use \(TimeZone.current.identifier). Delivery is handled by the server.").font(.caption).foregroundColor(NativeChatColors.muted)
                    NativeComposerText(text:$draft.message,selection:$selection,focused:$focused,label:"Scheduled message text",help:"Write your scheduled message. Use the Emoji button to insert an emoji.")
                        .frame(minHeight:190,maxHeight:.infinity).padding(10).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                    HStack {
                        Button { emoji.toggle() } label: { Label("Emoji",systemImage:"face.smiling") }.buttonStyle(NativeToolbarButtonStyle()).popover(isPresented:$emoji) {
                            NativeReactionPicker(title: "Insert emoji", preferences: model.emojiPreferences) { kind in model.emojiPreferences.record(kind); let edit = ChatComposerEdit.insert(kind.emoji,into:draft.message,selection:selection);draft.message = edit.text;selection = edit.selection;emoji = false;focused = true }
                        }
                        Spacer()
                        Text("\(draft.message.utf16.count) / 2,000").font(.caption).monospacedDigit().foregroundColor(ChatMessageText.isAllowed(draft.message) ? NativeChatColors.muted : .orange)
                    }
                    NativeMessageLengthNotice(text:draft.message)
                }.padding(20).disabled(busy || uncertain)
            } else {
                NativeScheduledCreationRecoveryPanel(model:model,channelID:channelID)
                Spacer(minLength:0)
            }
            if editing == nil,confirmed != nil { NativeScheduledCreationRecoveryPanel(model:model,channelID:channelID) }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).padding(.horizontal,20) }
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Stop waiting") { task?.cancel();busy = false;uncertain = true;failure = "The server may have accepted this change. Check Scheduled messages before trying again." }.buttonStyle(NativeToolbarButtonStyle())
                }
                Spacer()
                if confirmed != nil { Button("Done") { dismiss() }.buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.defaultAction) }
                else if uncertain { Button("Close and check scheduled messages") { dismiss() }.buttonStyle(NativeSendButtonStyle()) }
                else if editing == nil && (model.pendingScheduledCreations[channelID] != nil || model.scheduleCreationRecoveryError != nil) {
                    Button("Close") { dismiss() }.buttonStyle(NativeToolbarButtonStyle()).keyboardShortcut(.cancelAction)
                }
                else {
                    Button("Cancel") { dismiss() }.buttonStyle(NativeToolbarButtonStyle()).keyboardShortcut(.cancelAction).disabled(busy)
                    Button(editing == nil ? "Schedule message" : "Save changes") { submit() }.buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.return,modifiers:.command).disabled(!valid || busy || model.scheduleBusy || !model.canInteract || (editing == nil && (model.pendingScheduledCreations[channelID] != nil || model.scheduleCreationRecoveryError != nil)))
                }
            }.padding(20)
        }.frame(width:700,height:570).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy)
            .onAppear {
                model.conversationLibraryVisible = true
                guard !initialized else { return };initialized = true;session = model.accountGeneration
                if let editing { draft = .init(message:editing.message,date:editing.date) }
                else if let saved = model.scheduleDrafts[channelID] { draft = saved }
                else { let text = model.drafts[channelID] ?? "";draft.message = text;draft.sourceComposerText = text.isEmpty ? nil : text }
                focused = true
            }
            .onChange(of:draft) { value in if initialized,editing == nil,confirmed == nil,model.connected,model.accountGeneration == session { model.scheduleDrafts[channelID] = value } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
            .onChange(of:model.selection) { if $0 != channelID { dismiss() } }
            .onChange(of:model.selectedChannel?.encrypted) { if $0 != false { dismiss() } }
            .onDisappear { task?.cancel();task = nil;model.conversationLibraryVisible = false }
    }
    private func submit() {
        busy = true;failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await model.saveScheduledMessage(channelID:channelID,draft:draft,editing:editing)
                try Task.checkCancellation();confirmed = result
            } catch is CancellationError { }
            catch { failure = error.localizedDescription;uncertain = (error as? ChatScheduleFailure)?.uncertain ?? false }
        }
    }
}

struct NativeScheduledMessagesView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channelID:Int64
    @Environment(\.dismiss) private var dismiss
    @State private var rows:[ChatScheduledMessage] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var requestID = UUID()
    @State private var session = -1
    @State private var editing:ChatScheduledMessage?
    @State private var cancellation:ChatScheduledMessage?
    @State private var creating = false
    @State private var uncertain = false
    var body:some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("Scheduled messages").font(.system(size:20,weight:.bold))
                    Text(model.channels.first(where:{ $0.id == channelID }).map(model.title) ?? "Conversation").font(.caption).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button { creating = true } label: { Image(systemName:"plus") }.accessibilityLabel("New scheduled message").disabled(!model.canCreateSchedule || loading || uncertain)
                Button { load() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh scheduled messages").disabled(loading || model.scheduleBusy)
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close scheduled messages").keyboardShortcut(.cancelAction).disabled(model.scheduleBusy)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            NativeScheduledCreationRecoveryPanel(model:model,channelID:channelID)
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).frame(maxWidth:.infinity,alignment:.leading).padding(16) }
            if loading && !loaded { Spacer();ProgressView("Loading scheduled messages…");Spacer() }
            else if rows.isEmpty {
                Spacer()
                Image(systemName:"clock").font(.system(size:35)).foregroundColor(NativeChatColors.muted)
                Text(loaded ? "No scheduled messages" : "Could not load scheduled messages").font(.headline).padding(.top,10)
                Text("Pending sends for this conversation appear here.").font(.callout).foregroundColor(NativeChatColors.muted).padding(.top,4)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing:12) {
                        ForEach(rows) { job in
                            VStack(alignment:.leading,spacing:12) {
                                HStack {
                                    Label(model.formattedDate(job.date),systemImage:"clock").font(.callout.weight(.semibold)).foregroundColor(NativeChatColors.green)
                                    Spacer()
                                    Button("Edit") { editing = job }.buttonStyle(NativeToolbarButtonStyle())
                                    Button { cancellation = job } label: { Image(systemName:"trash") }.accessibilityLabel("Cancel scheduled message \(job.message)").buttonStyle(NativeToolbarButtonStyle())
                                }.disabled(model.scheduleBusy || loading || uncertain || !model.canInteract)
                                Text(job.message).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                                if job.date <= Date() { Text("Delivery is due. Refresh to check whether the server has sent it.").font(.caption).foregroundColor(NativeChatColors.muted) }
                            }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
                        }
                    }.padding(20)
                }
            }
            HStack {
                if loading || model.scheduleBusy { ProgressView().controlSize(.small) }
                Text("Scheduled by you · \(TimeZone.current.identifier)").font(.caption).foregroundColor(NativeChatColors.muted)
                Spacer();Text("\(rows.count) pending").font(.caption).foregroundColor(NativeChatColors.muted)
            }.padding(20)
        }.frame(width:720,height:600).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(model.scheduleBusy)
            .onAppear { session = model.accountGeneration;model.conversationLibraryVisible = true;load() }
            .onDisappear { task?.cancel();task = nil;rows = [];model.conversationLibraryVisible = false }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
            .onChange(of:model.selection) { if $0 != channelID { dismiss() } }
            .onChange(of:model.selectedChannel?.encrypted) { if $0 != false { dismiss() } }
            .onReceive(Timer.publish(every:15,on:.main,in:.common).autoconnect()) { _ in if !model.scheduleBusy,!loading,editing == nil,!creating,cancellation == nil { load() } }
            .sheet(item:$editing,onDismiss:{ model.conversationLibraryVisible = true;load() }) { job in NativeScheduleComposer(model:model,channelID:channelID,editing:job) }
            .sheet(isPresented:$creating,onDismiss:{ model.conversationLibraryVisible = true;load() }) { NativeScheduleComposer(model:model,channelID:channelID) }
            .alert("Cancel this scheduled message?",isPresented:Binding(get:{ cancellation != nil },set:{ if !$0 { cancellation = nil } }),presenting:cancellation) { job in
                Button("Keep scheduled",role:.cancel) { cancellation = nil }
                Button("Cancel scheduled message",role:.destructive) { cancel(job);cancellation = nil }
            } message: { _ in Text("The server will not send it if cancellation succeeds before delivery.") }
    }
    private func load() {
        task?.cancel();let key = UUID();requestID = key;loading = true;failure = nil
        task = Task { @MainActor in
            defer { if requestID == key { loading = false } }
            do { let result = try await model.scheduledMessages(channelID:channelID);try Task.checkCancellation();guard requestID == key else { return };rows = result;loaded = true;uncertain = false }
            catch is CancellationError { }
            catch { if requestID == key { failure = error.localizedDescription } }
        }
    }
    private func cancel(_ job:ChatScheduledMessage) {
        guard session == model.accountGeneration,model.connected,model.selection == channelID else { return }
        let expected = session
        task?.cancel()
        task = Task { @MainActor in
            guard !Task.isCancelled,model.accountGeneration == expected,model.selection == channelID else { return }
            do {
                try await model.cancelScheduledMessage(job,channelID:channelID);try Task.checkCancellation()
                guard model.accountGeneration == expected,model.selection == channelID else { return }
                rows.removeAll { $0.id == job.id };failure = nil
            }
            catch is CancellationError { }
            catch { failure = error.localizedDescription;uncertain = (error as? ChatScheduleFailure)?.uncertain ?? false }
        }
    }
}
