import SwiftUI

struct NativeReminderEditor:View {
    @ObservedObject var model:NativeChatPreviewModel
    let post:ChatPost
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date(timeIntervalSince1970:ceil((Date().timeIntervalSince1970+600)/60)*60)
    @State private var original:Double?
    @State private var busy = false
    @State private var uncertain = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var session = -1
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                Label(original == nil || original == 0 ? "Remind me about this" : "Edit reminder",systemImage:"bell.badge").font(.system(size:20,weight:.bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close reminder editor").buttonStyle(NativeToolbarButtonStyle()).disabled(busy)
            }
            VStack(alignment:.leading,spacing:8) {
                Text(model.names[post.creator_id] ?? "Message").font(.callout.weight(.semibold))
                Text(model.messageText(post).isEmpty ? (post.file_props?.name ?? "Attachment") : model.messageText(post)).lineLimit(6).textSelection(.enabled)
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            if original != nil {
                DatePicker("Remind at",selection:Binding(get:{ date },set:{ date = ChatScheduleDraft.minutePrecision($0) }),displayedComponents:[.date,.hourAndMinute]).accessibilityLabel("Reminder time")
                Menu("Quick times") {
                    ForEach([10,20,60,120,240,480,1440],id:\.self) { minutes in
                        Button(minutes < 60 ? "In \(minutes) minutes" : minutes == 60 ? "In 1 hour" : minutes < 1440 ? "In \(minutes/60) hours" : "In 1 day") { date = Date(timeIntervalSinceNow:Double(minutes*60)) }
                    }
                }
                Text("Only you receive this reminder. Times use \(TimeZone.current.identifier).").font(.caption).foregroundColor(NativeChatColors.muted)
            }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if (original ?? 0) > 0 { Button("Remove reminder",role:.destructive) { change(remove:true) }.disabled(busy || uncertain || !model.canRemind(post)) }
                Spacer()
                if uncertain || original == nil { Button("Refresh") { load() }.disabled(busy) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Save reminder") { change(remove:false) }.buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.return,modifiers:.command)
                    .disabled(busy || uncertain || original == nil || (try? ChatReminderTime.future(date)) == nil || !model.canRemind(post))
            }
        }.padding(24).frame(width:530).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy)
            .onAppear { session = model.accountGeneration;load() }
            .onDisappear { task?.cancel();task = nil }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.channels) { _ in if !model.canBrowseReminders(channelID:post.channel_id) { dismiss() } }
    }
    private func load() {
        task?.cancel();busy = true;failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { let time = try await model.reminderTime(for:post);try Task.checkCancellation();original = time;uncertain = false;if time > 0 { date = Date(timeIntervalSince1970:time/1000) } }
            catch is CancellationError { }
            catch { failure = "Could not load this reminder. Refresh to try again." }
        }
    }
    private func change(remove:Bool) {
        guard let original else { return };busy = true;failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do { try await model.changeReminder(post,date:remove ? nil : date,expectedTime:original);try Task.checkCancellation();dismiss() }
            catch is CancellationError { }
            catch { failure = error.localizedDescription;uncertain = true }
        }
    }
}

struct NativeRemindersView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var channelID:Int64 = 0
    @State private var rows:[ChatReminder] = []
    @State private var query = ""
    @State private var busy = false
    @State private var loaded = false
    @State private var uncertainAction = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var session = -1
    @State private var editing:ChatReminder?
    @State private var removing:ChatReminder?
    private var channels:[ChatChannel] { model.channels.filter { model.canBrowseReminders(channelID:$0.id) } }
    private var filtered:[ChatReminder] { rows.filter { query.isEmpty || model.messageText($0.post).localizedCaseInsensitiveContains(query) || (model.names[$0.post.creator_id] ?? "").localizedCaseInsensitiveContains(query) || ($0.post.file_props?.name ?? "").localizedCaseInsensitiveContains(query) } }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label("Reminders",systemImage:"bell.badge").font(.system(size:20,weight:.bold))
                Spacer()
                Button { load() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh reminders").disabled(busy || model.reminderBusy || channelID == 0)
                Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close reminders").keyboardShortcut(.cancelAction).disabled(model.reminderBusy)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            HStack {
                Picker("Conversation",selection:$channelID) { ForEach(channels) { channel in Text(model.title(channel)).tag(channel.id) } }.accessibilityLabel("Reminder conversation").disabled(model.reminderBusy)
                TextField("Filter reminders",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Filter reminders")
            }.padding(.horizontal,20).padding(.bottom,16)
            Divider().overlay(NativeChatColors.separator)
            if let failure { Text(failure).foregroundColor(.orange).font(.callout).frame(maxWidth:.infinity,alignment:.leading).padding(16) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    if busy { ProgressView("Loading reminders…").frame(maxWidth:.infinity).padding(30) }
                    if loaded && !busy && filtered.isEmpty {
                        VStack(spacing:12) {
                            Image(systemName:"bell").font(.system(size:30))
                            Text(query.isEmpty ? "No reminders in this conversation" : "No matching reminders").font(.headline)
                            Text("Choose Remind me… from a message’s menu.").font(.callout)
                        }.foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity).padding(.vertical,60)
                    }
                    ForEach(filtered) { reminder in row(reminder) }
                }.padding(20)
            }
            HStack { Text("Personal reminders · \(TimeZone.current.identifier)");Spacer();Text("\(rows.count) \(rows.count == 1 ? "reminder" : "reminders")") }.font(.caption).foregroundColor(NativeChatColors.muted).padding(20)
        }.frame(width:720,height:600).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(model.reminderBusy)
            .onAppear { session = model.accountGeneration;model.conversationLibraryVisible = true;channelID = channels.first(where:{ $0.id == model.selection })?.id ?? channels.first?.id ?? 0;load() }
            .onDisappear { request = UUID();task?.cancel();task = nil;rows = [];model.conversationLibraryVisible = false }
            .onChange(of:channelID) { _ in load() }
            .onChange(of:model.reminderRevision) { _ in if !busy,!model.reminderBusy,editing == nil,removing == nil { load() } }
            .onChange(of:model.accountGeneration) { if $0 != session { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.channels) { _ in if !model.canBrowseReminders(channelID:channelID) { rows = [];dismiss() } }
            .sheet(item:$editing,onDismiss:{ model.conversationLibraryVisible = true;load() }) { NativeReminderEditor(model:model,post:$0.post) }
            .alert("Remove this reminder?",isPresented:Binding(get:{ removing != nil },set:{ if !$0 { removing = nil } }),presenting:removing) { reminder in
                Button("Keep reminder",role:.cancel) { removing = nil }
                Button("Remove reminder",role:.destructive) { remove(reminder);removing = nil }
            } message: { _ in Text("This removes your reminder. The message stays in the conversation.") }
    }
    private func row(_ reminder:ChatReminder) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label(model.formattedDate(reminder.date),systemImage:"bell").font(.callout.weight(.semibold)).foregroundColor(NativeChatColors.green)
                Spacer()
                if reminder.date <= Date() { Text("Due").font(.caption).foregroundColor(NativeChatColors.muted) }
            }
            HStack { NativeUserIdentity(model:model,userID:reminder.post.creator_id,size:26,showsName:true);Spacer() }
            Text((reminder.post.delete_at ?? 0) > 0 ? "Message deleted" : model.messageText(reminder.post).isEmpty ? (reminder.post.file_props?.name ?? "Attachment") : model.messageText(reminder.post)).lineLimit(5).textSelection(.enabled)
            HStack {
                Button("Show in conversation") { dismiss();model.navigateToMessage(channelID:reminder.post.channel_id,postID:reminder.id,threadID:reminder.post.isReply ? reminder.post.thread_id : nil) }.disabled(busy || model.isEditingMessage || (reminder.post.delete_at ?? 0) > 0)
                Spacer()
                Button("Edit") { editing = reminder }.disabled(!model.canRemind(reminder.post) || busy || uncertainAction)
                Button("Remove") { removing = reminder }.disabled(!model.canRemind(reminder.post) || busy || uncertainAction)
            }.font(.callout).buttonStyle(NativeToolbarButtonStyle())
        }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
    }
    private func load() {
        task?.cancel();let key = UUID();request = key;rows = [];loaded = false;failure = nil
        guard channelID > 0 else { busy = false;return };busy = true
        task = Task { @MainActor in
            defer { if request == key { busy = false } }
            do { let result = try await model.reminders(channelID:channelID);try Task.checkCancellation();guard request == key else { return };rows = result;loaded = true;uncertainAction = false }
            catch is CancellationError { }
            catch { if request == key { failure = "Could not load reminders. Refresh to try again." } }
        }
    }
    private func remove(_ reminder:ChatReminder) {
        guard session == model.accountGeneration,model.connected,reminder.post.channel_id == channelID else { return }
        let expected = session,channel = channelID
        task?.cancel();busy = true;failure = nil
        task = Task { @MainActor in
            guard !Task.isCancelled,model.accountGeneration == expected,channelID == channel else { return }
            do {
                try await model.changeReminder(reminder.post,date:nil,expectedTime:reminder.remindAt);try Task.checkCancellation()
                guard model.accountGeneration == expected,channelID == channel else { return }
                busy = false;load()
            }
            catch is CancellationError { busy = false }
            catch { busy = false;uncertainAction = true;failure = error.localizedDescription }
        }
    }
}
