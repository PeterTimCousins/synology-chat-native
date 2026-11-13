import SwiftUI

struct NativeCalendarEventView: View {
    @ObservedObject var model: NativeChatPreviewModel
    let post: ChatPost
    let detected: ChatDateLinks.Selection
    @Environment(\.dismiss) private var dismiss
    @State private var options: NativeCalendarSnapshot?
    @State private var draft = ChatCalendarDraft(calendarID: "", title: "", start: Date(), end: Date(), allDay: false, timeZoneID: TimeZone.current.identifier)
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var error: String?
    @State private var created = false
    @State private var epoch = -1
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Create Calendar event").font(.title2.bold()); Spacer(); Button(created ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy) }
            if created {
                Label("Event saved in Synology Calendar", systemImage: "checkmark.circle.fill").foregroundColor(NativeChatColors.green)
                Text(draft.title).textSelection(.enabled)
            } else if let options {
                TextField("Event title", text: $draft.title).accessibilityLabel("Event title")
                Picker("Calendar", selection: $draft.calendarID) { ForEach(options.calendars) { Text($0.cal_displayname).tag($0.id) } }
                Toggle("All day", isOn: $draft.allDay)
                DatePicker("Starts", selection: $draft.start, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                DatePicker(draft.allDay ? "Last day" : "Ends", selection: $draft.end, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                Picker("Time zone", selection: $draft.timeZoneID) { ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + [draft.timeZoneID])).sorted(), id: \.self) { Text($0).tag($0) } }
                Text("Saved to your unshared calendar with no attendees or reminders. No invitations are sent. Review the detected date before creating the event.").font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Create event") { create(options) }.disabled(busy || !valid || !model.canCreateCalendarEvent(post)) }
            }
            if busy { ProgressView(options == nil ? "Loading Calendar…" : "Creating event…") }
            if let error { Text(error).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        }.padding(24).frame(width: 560).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .environment(\.timeZone, TimeZone(identifier: draft.timeZoneID) ?? .current)
            .disabled(busy || model.calendarBusy)
            .interactiveDismissDisabled(busy)
            .onAppear { epoch = model.accountGeneration; load() }
            .onDisappear { task?.cancel() }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of: model.connected) { if !$0 { dismiss() } }
    }
    private var valid: Bool {
        guard let calendar = options?.calendars.first(where: { $0.id == draft.calendarID }) else { return false }
        return (try? draft.parameters(calendar: calendar)) != nil
    }
    private func load() {
        guard !busy else { return }; busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let loaded = try await model.loadCalendarEventOptions(for: post); try Task.checkCancellation()
                options = loaded
                draft = .init(calendarID: loaded.calendars[0].id, title: model.messageText(post), start: detected.date,
                              end: detected.allDay ? detected.date : detected.date.addingTimeInterval(3600), allDay: detected.allDay, timeZoneID: loaded.timeZoneID)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func create(_ options: NativeCalendarSnapshot) {
        guard !busy else { return }; busy = true; error = nil
        let reviewed = draft
        task = Task { @MainActor in
            defer { busy = false }
            do { _ = try await model.createCalendarEvent(reviewed, post: post, snapshot: options); try Task.checkCancellation(); created = true }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
