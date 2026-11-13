import SwiftUI

struct NativeChannelGuestsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @ObservedObject private var actions: ChatGuestManagement
    let channelID: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ChatChannelGuestsSnapshot?
    @State private var busy = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var task: Task<Void, Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var showEditor = false
    @State private var editingGuest: ChatChannelGuest?
    @State private var confirmation: ChatGuestChange?
    @State private var dismissingPending = false
    private var pending: ChatGuestActionRecord? { actions.pending[channelID] }
    private var canChange: Bool { !busy && !actions.busy && actions.recoveryError == nil && pending == nil }
    init(model: NativeChatPreviewModel, channelID: Int64) { self.model = model; self.actions = model.guestManagement; self.channelID = channelID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Channel guests").font(.title2.bold())
                    if let snapshot { Text(model.title(snapshot.channel)).foregroundColor(NativeChatColors.muted) }
                }
                Spacer()
                Button("Refresh") { run() }.disabled(busy || actions.busy)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if busy { ProgressView("Checking guest registrations…") }
                    if let failure { Text(failure).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
                    if let error = actions.recoveryError { Text(error).foregroundColor(.orange).font(.callout) }
                    if let notice { Text(notice).foregroundColor(NativeChatColors.green).font(.callout) }
                    if pending != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("A guest request has an unconfirmed result", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.headline)
                            Text("Refresh to check registrations. Requests are never retried automatically. Email delivery cannot be checked here.").font(.callout)
                            Button("Review pending result…") { dismissingPending = true }.disabled(busy || actions.busy)
                        }.foregroundColor(.orange).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let snapshot {
                        if snapshot.policy.allow_guest {
                            HStack {
                                Text("Invite a guest to this private channel.").font(.callout).foregroundColor(NativeChatColors.muted)
                                Spacer()
                                Button("Invite guest…") { editingGuest = nil; showEditor = true }.disabled(!canChange)
                            }
                        } else {
                            Label("New guest access is disabled on this server. Existing registrations are shown below.", systemImage: "person.crop.circle.badge.exclamationmark")
                                .font(.callout).foregroundColor(NativeChatColors.muted)
                        }
                        if snapshot.guests.isEmpty { Label("No guest registrations", systemImage: "person.crop.circle.badge.questionmark").font(.headline).padding(.vertical, 24) }
                        ForEach(snapshot.guests) { guest in guestRow(guest) }
                    }
                    Text("Opening or refreshing this list sends no invitations and changes no guest access.")
                        .font(.caption).foregroundColor(NativeChatColors.muted)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(width: 650, height: 590).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas)
            .nativeChatAppearance().tint(NativeChatColors.green)
            .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; run() }
            .onDisappear { request = UUID(); task?.cancel(); model.conversationLibraryVisible = false }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of: model.connected) { if !$0 { dismiss() } }
            .onChange(of: model.selection) { if $0 != channelID { dismiss() } }
            .sheet(isPresented: $showEditor) {
                NativeGuestEditor(guest: editingGuest) { change in showEditor = false; run(change) }
            }
            .alert("Confirm guest action", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button("Cancel", role: .cancel) { confirmation = nil }
                if let confirmation {
                    switch confirmation {
                    case .remove: Button("Remove guest", role: .destructive) { let change = self.confirmation; self.confirmation = nil; run(change) }
                    case .resend: Button("Send invitation email") { let change = self.confirmation; self.confirmation = nil; run(change) }
                    default: EmptyView()
                    }
                }
            } message: {
                if case .remove(let guest) = confirmation { Text("Remove \(guest.email) from this channel? Their channel access will be removed.") }
                if case .resend(let guest) = confirmation { Text("Ask Synology Chat to send another invitation email to \(guest.email)? This does not verify delivery.") }
            }
            .alert("Dismiss the pending result?", isPresented: $dismissingPending) {
                Button("Keep pending", role: .cancel) { }
                Button("Dismiss pending result") {
                    guard let pending else { return }
                    do { try actions.dismissPending(pending); notice = "Pending result dismissed. No request was repeated or undone." }
                    catch { failure = error.localizedDescription }
                }
            } message: {
                Text("The request may have reached Synology Chat. Refresh and check registrations first. Dismissing clears only the local pending record; it does not undo or retry the request. Another invitation or resend could send a duplicate email.")
            }
    }
    private func guestRow(_ guest: ChatChannelGuest) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.crop.circle").font(.title).foregroundColor(NativeChatColors.green)
            VStack(alignment: .leading, spacing: 5) {
                Text(guest.email).font(.headline).textSelection(.enabled)
                Text(guest.statusLabel).font(.callout).foregroundColor(NativeChatColors.muted)
                if let expiration = guest.expiration { Text("Expires \(expiration.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                else { Text("No expiry").font(.caption) }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Change expiry…") { editingGuest = guest; showEditor = true }
                if guest.user_id == 0, guest.status == "uninvited" { Button("Resend invitation email…") { confirmation = .resend(guest) } }
                Divider()
                Button("Remove guest…", role: .destructive) { confirmation = .remove(guest) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(!canChange)
                .accessibilityLabel("Guest actions for " + guest.email)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func run(_ change: ChatGuestChange? = nil) {
        guard !busy, !actions.busy else { return }
        task?.cancel(); let token = UUID(); request = token; busy = true; failure = nil; notice = nil
        let original = snapshot
        if change == nil { snapshot = nil; if actions.recoveryError != nil { actions.retryRecovery() } }
        task = Task { @MainActor in
            defer { if request == token { busy = false } }
            do {
                let value: ChatChannelGuestsSnapshot
                if let change, let original { value = try await model.changeChannelGuest(change, original: original) }
                else { value = try await model.loadChannelGuests(channelID: channelID) }
                try Task.checkCancellation(); guard request == token else { return }
                snapshot = value
                if let change {
                    switch change {
                    case .invite: notice = "Guest registration confirmed. Synology Chat handles the invitation email."
                    case .expiry: notice = "Guest expiry updated."
                    case .remove: notice = "Guest removed from this channel."
                    case .resend: notice = "Invitation email requested. Delivery is not verified."
                    }
                } else { try actions.reconcile(value) }
            } catch is CancellationError { }
            catch { if request == token { failure = error.localizedDescription } }
        }
    }
}

private struct NativeGuestEditor: View {
    let guest: ChatChannelGuest?
    let submit: (ChatGuestChange) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var language = "enu"
    @State private var noExpiry = true
    @State private var day = Date()
    private var expiration: Int64? { try? ChatGuestInput.expiration(day: noExpiry ? nil : day) }
    private var valid: Bool { expiration != nil && (guest != nil || (try? ChatGuestInput.email(email)) != nil) && (guest == nil || expiration != guest?.expire_at) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(guest == nil ? "Invite a channel guest" : "Change guest expiry").font(.title2.bold())
            if let guest { Text(guest.email).font(.headline).textSelection(.enabled) }
            else {
                TextField("Guest email address", text: $email).textFieldStyle(.roundedBorder).accessibilityLabel("Guest email address")
                Picker("Invitation language", selection: $language) { ForEach(ChatGuestInput.languages, id: \.0) { Text($0.1).tag($0.0) } }
                Text("Synology Chat will send an invitation email. Guests can access the channel’s available history. Archive history in Channel details first if needed.")
                    .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("No expiry", isOn: $noExpiry).toggleStyle(.checkbox)
            if !noExpiry {
                DatePicker("Expiry date", selection: $day, displayedComponents: .date)
                Text("Access expires at the end of this date in \(TimeZone.current.identifier).").font(.caption).foregroundColor(NativeChatColors.muted)
                if expiration == nil { Text("Choose a date that has not passed.").font(.caption).foregroundColor(.orange) }
            }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(guest == nil ? "Send invitation" : "Save expiry") {
                    guard let expiration else { return }
                    if let guest { submit(.expiry(guest, expireAt: expiration)) }
                    else { submit(.invite(email: email, expireAt: expiration, language: language)) }
                }.disabled(!valid).keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(24).frame(width: 520).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .onAppear { if let guest { email = guest.email; noExpiry = guest.expire_at == 0; day = guest.expiration ?? Date() } }
    }
}
