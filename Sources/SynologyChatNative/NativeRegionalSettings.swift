import AppKit
import SwiftUI

struct NativeRegionalSettingsView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot:ChatRegionalSnapshot?
    @State private var language = "def"
    @State private var dateFormat = "system"
    @State private var timeFormat = "system"
    @State private var timezone = "def"
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var confirmDiscard = false
    @State private var closeAfterDiscard = false
    @State private var saving = false
    private var preferencesDirty:Bool { guard let snapshot else {return false};return language != snapshot.personal.language || dateFormat != snapshot.personal.dateFormat || timeFormat != snapshot.personal.timeFormat }
    private var timezoneDirty:Bool { snapshot.map { timezone != $0.selectedTimeZone } ?? false }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"globe").font(.system(size:22)).foregroundColor(NativeChatColors.green)
                Text("Language & time").font(.system(size:20,weight:.bold))
                Spacer()
                Button("Refresh") { requestCloseOrRefresh(close:false) }.disabled(busy)
                Button("Done") { requestCloseOrRefresh(close:true) }.disabled(busy).keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if let snapshot {
                        settingsCard("Language & date formats",icon:"textformat") {
                            choiceMenu("Synology preferred language",selection:$language,options:ChatRegionalDisplay.languages,original:snapshot.personal.language)
                            choiceMenu("Date format",selection:$dateFormat,options:[("system","Server default")]+ChatRegionalDisplay.dateFormats.map { ($0,Self.dateLabel($0)) },original:snapshot.personal.dateFormat)
                            choiceMenu("Time format",selection:$timeFormat,options:[("system","Server default"),("h:i a","12-hour (03:04 pm)"),("H:i","24-hour (15:04)")],original:snapshot.personal.timeFormat)
                            HStack(spacing:8) {
                                Image(systemName:"clock").foregroundColor(NativeChatColors.muted)
                                Text("Example").foregroundColor(NativeChatColors.muted)
                                Spacer()
                                Text(preview(snapshot)).monospacedDigit().foregroundColor(NativeChatColors.green)
                            }.font(.callout).padding(12).background(NativeChatColors.canvas).clipShape(RoundedRectangle(cornerRadius:8))
                            Text("Shared with DSM and Synology apps. Date and time formats apply here after saving. The language choice affects your Synology account; Chat Native’s interface is currently English.")
                                .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                            Divider().overlay(NativeChatColors.separator)
                            HStack {
                                Button("Discard preference changes") { language = snapshot.personal.language;dateFormat = snapshot.personal.dateFormat;timeFormat = snapshot.personal.timeFormat }
                                    .buttonStyle(NativeToolbarButtonStyle()).disabled(!preferencesDirty)
                                Spacer()
                                Button("Save preferences") { run(save:true) }.buttonStyle(NativeSendButtonStyle()).disabled(!preferencesDirty || model.regionalSettingsNeedRefresh)
                            }
                        }.disabled(busy || timezoneDirty)
                        settingsCard("Account timezone",icon:"location") {
                            choiceMenu("Account timezone",selection:$timezone,options:[("def","Device default")]+snapshot.zones.map { ($0.value,$0.display) },original:snapshot.selectedTimeZone).disabled(!snapshot.policy.allows("timezone"))
                            Text("Used for account scheduling and your profile’s local time. Message timestamps follow this Mac’s timezone.")
                                .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                            if !snapshot.policy.allows("timezone") { Text("Your account cannot change its timezone.").font(.caption).foregroundColor(NativeChatColors.muted) }
                            Divider().overlay(NativeChatColors.separator)
                            HStack {
                                Button("Discard timezone change") { timezone = snapshot.selectedTimeZone }.buttonStyle(NativeToolbarButtonStyle()).disabled(!timezoneDirty)
                                Spacer()
                                Button("Save timezone") { run(zone:true) }.buttonStyle(NativeSendButtonStyle()).disabled(!timezoneDirty || !snapshot.policy.allows("timezone") || model.regionalSettingsNeedRefresh)
                            }
                        }.disabled(busy || preferencesDirty)
                    }
                    if busy {
                        HStack(spacing:10) {
                            ProgressView().controlSize(.small)
                            Text(saving ? "Saving regional settings…" : "Checking regional settings…").font(.callout)
                            Spacer()
                            Button("Stop waiting") { request = UUID();task?.cancel();busy = false;failure = "Stopped waiting. Refresh to check the server before saving again." }.buttonStyle(NativeToolbarButtonStyle())
                        }
                    }
                    if let failure { Text(failure).font(.callout).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                    if model.regionalSettingsNeedRefresh { Label("Refresh before changing regional settings again.",systemImage:"exclamationmark.circle").font(.callout).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
                }.padding(20)
            }.frame(maxHeight:.infinity)
        }.frame(width:640,height:650).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .interactiveDismissDisabled(busy || preferencesDirty || timezoneDirty)
            .confirmationDialog("Discard unsaved regional changes?",isPresented:$confirmDiscard,titleVisibility:.visible) {
                Button(closeAfterDiscard ? "Discard and close" : "Discard and refresh",role:.destructive) { if closeAfterDiscard { dismiss() } else { run() } }
                Button("Keep editing",role:.cancel) {}
            }
            .onAppear { epoch = model.accountGeneration;model.conversationLibraryVisible = true;run() }
            .onDisappear { task?.cancel();model.conversationLibraryVisible = false }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
    }
    private func requestCloseOrRefresh(close:Bool) {
        if preferencesDirty || timezoneDirty { closeAfterDiscard = close;confirmDiscard = true }
        else if close { dismiss() } else { run() }
    }
    private func choiceMenu(_ title:String,selection:Binding<String>,options:[(String,String)],original:String)->some View {
        let choices = options.contains(where:{$0.0 == original}) ? options : options+[(original,"Current: \(original)")]
        return HStack(spacing:16) {
            Text(title).font(.callout).frame(width:174,alignment:.leading)
            NativeRegionalChoice(title:title,selection:selection,choices:choices)
                .frame(maxWidth:.infinity).frame(height:34).padding(.horizontal,8)
                .background(NativeChatColors.canvas).clipShape(RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(NativeChatColors.separator))
        }
    }
    private func settingsCard<Content:View>(_ title:String,icon:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:14) {
            Label(title,systemImage:icon).font(.callout.weight(.semibold)).foregroundColor(NativeChatColors.text)
            content()
        }.padding(16).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
    }
    static func dateLabel(_ raw:String)->String { raw.replacingOccurrences(of:"Y",with:"YYYY").replacingOccurrences(of:"m",with:"MM").replacingOccurrences(of:"d",with:"DD") }
    private func preview(_ snapshot:ChatRegionalSnapshot)->String {
        var values = snapshot.personal.Personal;values["dateFormat"] = .string(dateFormat);values["timeFormat"] = .string(timeFormat)
        return ChatRegionalDisplay(personal:.init(Personal:values),defaults:snapshot.defaults).format(Date(timeIntervalSince1970:1767366240))
    }
    private func run(save:Bool = false,zone:Bool = false) {
        guard !busy else {return};busy = true;saving = save || zone;failure = nil;let key = UUID();request = key
        let lang = language,date = dateFormat,time = timeFormat,tz = timezone
        task = Task { @MainActor in
            defer {if request == key {busy = false;saving = false}}
            do {
                let result:ChatRegionalSnapshot
                if zone,let snapshot {result = try await model.saveRegionalTimeZone(tz,original:snapshot)}
                else if save,let snapshot {var draft = ChatRegionalDraft(snapshot.personal);draft.language = lang;draft.dateFormat = date;draft.timeFormat = time;result = try await model.saveRegionalSettings(draft,original:snapshot)}
                else {result = try await model.loadRegionalSettings()}
                try Task.checkCancellation();guard request == key else {return};snapshot = result;language = result.personal.language;dateFormat = result.personal.dateFormat;timeFormat = result.personal.timeFormat;timezone = result.selectedTimeZone
            } catch is CancellationError {} catch {if request == key {failure = error.localizedDescription}}
        }
    }
}

/// A real menu control retains keyboard and accessibility semantics when its
/// selection changes. Its bezel is provided by the surrounding settings row.
private struct NativeRegionalChoice:NSViewRepresentable {
    let title:String
    @Binding var selection:String
    let choices:[(String,String)]
    func makeCoordinator()->Coordinator { Coordinator(selection:$selection) }
    func makeNSView(context:Context)->NSPopUpButton {
        let button = NSPopUpButton(frame:.zero,pullsDown:false)
        button.isBordered = false;button.font = .systemFont(ofSize:13)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setContentHuggingPriority(.defaultLow,for:.horizontal)
        button.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        button.target = context.coordinator;button.action = #selector(Coordinator.choose(_:))
        return button
    }
    func updateNSView(_ button:NSPopUpButton,context:Context) {
        context.coordinator.selection = $selection;context.coordinator.choices = choices
        if button.itemArray.map(\.title) != choices.map(\.1) {
            button.removeAllItems();button.addItems(withTitles:choices.map(\.1))
        }
        button.selectItem(at:choices.firstIndex(where:{$0.0 == selection}) ?? -1)
        button.isEnabled = context.environment.isEnabled
        button.contentTintColor = NSColor(NativeChatColors.text)
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(button.titleOfSelectedItem ?? selection)
    }
    final class Coordinator:NSObject {
        var selection:Binding<String>
        var choices:[(String,String)] = []
        init(selection:Binding<String>) { self.selection = selection }
        @objc func choose(_ sender:NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard choices.indices.contains(index) else { return }
            selection.wrappedValue = choices[index].0
            sender.setAccessibilityValue(choices[index].1)
        }
    }
}
