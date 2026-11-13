import SwiftUI

struct NativeNotificationSettingsView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var original:ChatNotificationSettingsSnapshot?
    @State private var draft:ChatNotificationSettingsDraft?
    @State private var duration = 20
    @State private var busy = false
    @State private var saving = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var discard:String?
    @State private var localBusy = false
    private var dirty:Bool { guard let original,let draft else { return false };return draft != .init(original.settings) }
    private var valid:Bool { guard let original,let draft,let patch = try? draft.patch(from:original.settings) else { return false };return !patch.isEmpty }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"bell.badge").font(.system(size:22)).foregroundColor(NativeChatColors.green)
                Text("Notifications").font(.system(size:20,weight:.bold));Spacer()
                Button { requestRefresh() } label:{ Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh notification preferences").disabled(busy)
                Button("Done") { requestClose() }.disabled(busy).keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    section("On this Mac",icon:"desktopcomputer") {
                        HStack(alignment:.center,spacing:14) {
                            VStack(alignment:.leading,spacing:5) {
                                Text(model.notificationsEnabled ? "Notifications enabled" : "Notifications are off in Chat Native").font(.callout.weight(.semibold))
                                Text("macOS controls banners, sounds, badges and Focus restrictions.").font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                            }
                            Spacer(minLength:8)
                            if localBusy { ProgressView().controlSize(.small) }
                            Button(model.notificationsEnabled ? "Turn off" : "Enable notifications") {
                                localBusy = true
                                Task { @MainActor in await model.toggleNotifications();localBusy = false }
                            }.buttonStyle(NativeSendButtonStyle()).disabled(localBusy || busy || !model.connected)
                        }
                        if !model.notificationsEnabled && model.notificationHasStatusNotice {
                            Text(model.notificationStatus).font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                        }
                        Text("This switch applies only to Chat Native on this Mac.").font(.caption).foregroundColor(NativeChatColors.muted)
                    }
                    Text("Account preferences").font(.system(size:13,weight:.semibold)).foregroundColor(NativeChatColors.muted)
                    Text("The settings below are saved to your Synology Chat account.").font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                    if let original,let draft {
                        section("Alerts",icon:"bell") {
                            Toggle("Show message previews",isOn:binding(\.showMessage))
                            Toggle("Notify for visible conversations",isOn:binding(\.notifyVisible))
                            Toggle("Play notification sounds",isOn:Binding(get:{ !(self.draft?.mute ?? true) },set:{ self.draft?.mute = !$0 }))
                        }.toggleStyle(.switch).controlSize(.small).disabled(busy || model.notificationPreferencesNeedRefresh)
                        section("Pause notifications",icon:"bell.slash") {
                            TimelineView(.periodic(from:.now,by:1)) { context in
                                Text(pauseStatus(original,now:context.date)).foregroundColor(NativeChatColors.muted)
                            }
                            HStack {
                                Picker("Pause for",selection:$duration) { ForEach([20,60,120,240,480,1440],id:\.self) { value in Text(value < 60 ? NativeLocalizedStrings.count("%lld minutes",Int64(value)) : "\(value/60) \(value == 60 ? "hour" : "hours")").tag(value) } }.frame(maxWidth:260)
                                Button("Pause") { run(minutes:duration) }
                                Button("Resume now") { run(minutes:0) }.disabled(original.settings.snooze == 0)
                            }.disabled(busy || dirty || model.notificationPreferencesNeedRefresh)
                            if dirty { Text("Save or discard your edits before changing the current pause.").font(.caption).foregroundColor(NativeChatColors.muted) }
                            Text("Resume now clears the temporary pause. An enabled daily schedule still applies.").font(.caption).foregroundColor(NativeChatColors.muted)
                        }
                        section("Daily quiet hours",icon:"moon") {
                            Toggle("Enable daily snooze schedule",isOn:binding(\.scheduleEnabled)).toggleStyle(.switch).controlSize(.small).disabled(original.timeZone == nil)
                            HStack {
                                timePicker("Start",value:binding(\.start),current:draft.start)
                                timePicker("End",value:binding(\.end),current:draft.end)
                            }.disabled(!draft.scheduleEnabled || original.timeZone == nil)
                            Text(original.timeZone.map { "Every day in your Synology account time zone: \($0.identifier). Overnight schedules are supported." } ?? "Your account time zone is unavailable. Schedule editing is disabled; refresh after reconnecting.").font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                            if let error = validation(original,draft) { Text(error).font(.caption).foregroundColor(.orange) }
                        }.disabled(busy || model.notificationPreferencesNeedRefresh)
                    }
                    if busy { ProgressView(saving ? "Saving notification preferences…" : "Loading notification preferences…") }
                    if let failure { Text(failure).font(.callout).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                    if model.notificationPreferencesNeedRefresh { Text("Refresh to check the server before making another change.").font(.callout).foregroundColor(.orange) }
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            }
            Divider().overlay(NativeChatColors.separator)
            HStack {
                if busy { Button("Stop waiting") { request = UUID();task?.cancel();busy = false;failure = "Stopped waiting. Refresh to check the server before continuing." } }
                Spacer()
                Button("Cancel") { requestClose() }.buttonStyle(NativeToolbarButtonStyle()).disabled(busy)
                Button("Save changes") { run(save:true) }.buttonStyle(NativeSendButtonStyle()).disabled(busy || !valid || model.notificationPreferencesNeedRefresh).keyboardShortcut(.return,modifiers:.command)
            }.padding(20)
        }.frame(width:650,height:680).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy || dirty)
            .onAppear { epoch = model.accountGeneration;model.conversationLibraryVisible = true;run() }
            .onDisappear { task?.cancel();model.conversationLibraryVisible = false }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .alert("Discard preference edits?",isPresented:Binding(get:{ discard != nil },set:{ if !$0 { discard = nil } }),presenting:discard) { action in
                Button("Keep editing",role:.cancel) { discard = nil }
                Button("Discard edits",role:.destructive) { discard = nil;if action == "refresh" { run() } else { dismiss() } }
            } message:{ _ in Text("Your unsaved local edits will be discarded.") }
    }
    private func section<Content:View>(_ title:String,icon:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:14) {
            Label(title,systemImage:icon).font(.system(size:14,weight:.semibold))
            content()
        }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
            .background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
    }
    private func binding<T>(_ key:WritableKeyPath<ChatNotificationSettingsDraft,T>)->Binding<T> { Binding(get:{ draft![keyPath:key] },set:{ draft?[keyPath:key] = $0 }) }
    private func timePicker(_ title:String,value:Binding<Int>,current:Int)->some View {
        Picker(title,selection:value) {
            ForEach(Array(Set(stride(from:0,to:86400,by:1800)).union([current])).sorted(),id:\.self) { seconds in
                Text(String(format:"%02d:%02d",seconds/3600,(seconds%3600)/60)).tag(seconds)
            }
        }
    }
    private func pauseStatus(_ snapshot:ChatNotificationSettingsSnapshot,now:Date)->String {
        let date = snapshot.clock.date(now:now)
        guard Double(snapshot.settings.snooze) > date.timeIntervalSince1970*1000 else { return "No temporary pause." }
        let formatter = DateFormatter();formatter.dateStyle = .short;formatter.timeStyle = .short;formatter.timeZone = snapshot.timeZone ?? .current
        let end = Date(timeIntervalSince1970:Double(snapshot.settings.snooze)/1000)
        let label = model.regionalDisplay?.format(end,zone:snapshot.timeZone ?? .current) ?? formatter.string(from:end)
        return "Paused until " + label + " (" + (snapshot.timeZone?.identifier ?? "Mac time") + ")."
    }
    private func validation(_ original:ChatNotificationSettingsSnapshot,_ draft:ChatNotificationSettingsDraft)->String? { do { _ = try draft.patch(from:original.settings);return nil } catch { return error.localizedDescription } }
    private func requestRefresh() { if dirty { discard = "refresh" } else { run() } }
    private func requestClose() { if dirty { discard = "close" } else { dismiss() } }
    private func run(save:Bool = false,minutes:Int? = nil) {
        guard !busy else { return };busy = true;saving = save || minutes != nil;failure = nil;let key = UUID();request = key
        task = Task { @MainActor in
            defer { if request == key { busy = false;saving = false } }
            do {
                let value:ChatNotificationSettingsSnapshot
                if save,let original,let draft { value = try await model.saveNotificationSettings(original:original,draft:draft) }
                else if let minutes,let original { value = try await model.setNotificationSnooze(minutes:minutes,original:original) }
                else { value = try await model.loadNotificationSettings() }
                try Task.checkCancellation();guard request == key else { return };original = value;draft = .init(value.settings)
            } catch is CancellationError { }
            catch { if request == key { failure = error.localizedDescription } }
        }
    }
}
