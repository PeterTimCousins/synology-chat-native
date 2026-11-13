import Foundation
import Combine

enum ChatGuestChange: Equatable {
    case invite(email: String, expireAt: Int64, language: String)
    case expiry(ChatChannelGuest, expireAt: Int64)
    case remove(ChatChannelGuest)
    case resend(ChatChannelGuest)
}

enum ChatGuestInput {
    static var languages: [(String, String)] { ChatRegionalDisplay.languages.filter { $0.0 != "def" } }
    static func email(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard normalized.utf8.count <= 254, parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."), !parts[1].contains(".."),
              !normalized.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              normalized.rangeOfCharacter(from: CharacterSet(charactersIn: "<>;,\"\\")) == nil
        else { throw ChatTransferError(message: "Enter a guest email address, such as name@example.com.") }
        return normalized
    }
    static func expiration(day: Date?, now: Date = Date(), calendar: Calendar = .current) throws -> Int64 {
        guard let day else { return 0 }
        guard let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day),
              end.timeIntervalSince1970.isFinite, end > now, end.timeIntervalSince1970 <= 253_402_300_799
        else { throw ChatTransferError(message: "Choose an expiry date that has not passed.") }
        return Int64(floor(end.timeIntervalSince1970))
    }
}

struct ChatGuestActionRecord: ChatAccountActionRecord {
    enum Kind: String, Codable { case invite, expiry, remove, resend }
    static let journalFolder = "GuestActions"
    let channelID: Int64
    let kind: Kind
    let email: String
    let original: ChatChannelGuest?
    let expireAt: Int64?
    let language: String?
    let priorGuestIDs: [Int64]
    let operationID: UUID
    var id: Int64 { channelID } // One durable unresolved action per channel, across processes.
    var method: String { switch kind { case .invite: return "register"; case .expiry: return "set"; case .remove: return "kick"; case .resend: return "resend_email" } }
    init(change: ChatGuestChange, snapshot: ChatChannelGuestsSnapshot, now: Date = Date()) throws {
        channelID = snapshot.channel.id; operationID = UUID(); priorGuestIDs = snapshot.guests.map(\.id).sorted()
        switch change {
        case .invite(let address, let expires, let lang):
            guard snapshot.policy.allow_guest else { throw ChatTransferError(message: "New guest access is disabled on this server.") }
            kind = .invite; email = try ChatGuestInput.email(address); original = nil; expireAt = expires; language = lang
            guard !snapshot.guests.contains(where: { $0.email.lowercased() == email }) else { throw ChatTransferError(message: "This email already has a guest registration. Refresh the guest list.") }
        case .expiry(let guest, let expires):
            kind = .expiry; original = guest; email = guest.email.lowercased(); expireAt = expires; language = nil
            guard expires != guest.expire_at else { throw ChatTransferError(message: "The expiry date has not changed.") }
        case .remove(let guest): kind = .remove; original = guest; email = guest.email.lowercased(); expireAt = nil; language = nil
        case .resend(let guest):
            guard guest.user_id == 0, guest.status == "uninvited" else { throw ChatTransferError(message: "Only guests awaiting registration can receive another invitation email.") }
            kind = .resend; original = guest; email = guest.email.lowercased(); expireAt = nil; language = nil
        }
        if let original { guard snapshot.guests.contains(original) else { throw ChatTransferError(message: "This guest registration changed. Refresh before continuing.") } }
        if let expireAt, expireAt != 0, Double(expireAt) <= now.timeIntervalSince1970 { throw ChatTransferError(message: "Choose an expiry date that has not passed.") }
        try validate()
    }
    func validate() throws {
        guard channelID > 2, !email.isEmpty, email.utf8.count <= 4096,
              priorGuestIDs.count <= 10_000, priorGuestIDs.allSatisfy({ $0 > 0 }), Set(priorGuestIDs).count == priorGuestIDs.count else { throw ChatAPIError.invalidResponse }
        if kind == .invite {
            guard original == nil, email == (try ChatGuestInput.email(email)), let language,
                  ChatGuestInput.languages.contains(where: { $0.0 == language }) else { throw ChatAPIError.invalidResponse }
        } else {
            guard let original, original.id > 0, priorGuestIDs.contains(original.id), email == original.email.lowercased(), language == nil else { throw ChatAPIError.invalidResponse }
            _ = try ChatChannelGuestList(guests: [original]).validated()
            if kind == .resend { guard original.user_id == 0, original.status == "uninvited" else { throw ChatAPIError.invalidResponse } }
        }
        if kind == .invite || kind == .expiry {
            guard let expireAt, expireAt >= 0, expireAt <= 253_402_300_799 else { throw ChatAPIError.invalidResponse }
        } else { guard expireAt == nil else { throw ChatAPIError.invalidResponse } }
    }
    var parameters: [String: ChatParameter] {
        var fields: [String: ChatParameter] = ["channel_id": .integer(channelID)]
        if kind == .invite { fields["email"] = .string(email); fields["language"] = language.map(ChatParameter.string) }
        else { fields["guest_id"] = original.map { .integer($0.id) } }
        fields["expire_at"] = expireAt.map(ChatParameter.integer)
        return fields
    }
    func confirmed(in snapshot: ChatChannelGuestsSnapshot) -> Bool {
        guard snapshot.channel.id == channelID else { return false }
        switch kind {
        case .invite:
            let matching = snapshot.guests.filter { $0.email.lowercased() == email }
            return matching.count == 1 && !priorGuestIDs.contains(matching[0].id) && matching[0].expire_at == expireAt
        case .expiry: return snapshot.guests.contains { $0.id == original?.id && $0.email.lowercased() == email && $0.expire_at == expireAt }
        case .remove: return !snapshot.guests.contains { $0.id == original?.id }
        case .resend: return false // A list cannot prove an email request happened.
        }
    }
}

typealias ChatGuestActionJournal = ChatAccountActionJournal<ChatGuestActionRecord>

@MainActor final class ChatGuestManagement: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var pending: [Int64: ChatGuestActionRecord] = [:]
    @Published private(set) var recoveryError: String?
    private let journal: ChatGuestActionJournal
    private var revision = UUID()
    private var scope: String?
    init(journal: ChatGuestActionJournal? = nil) { self.journal = journal ?? .init() }
    func activate(scope: String?) {
        revision = UUID(); busy = false; pending = [:]; self.scope = scope
        guard let scope else { journal.deactivate(); recoveryError = "Guest changes are disabled until this account can be identified for saved-action recovery."; return }
        do { pending = Dictionary(uniqueKeysWithValues: try journal.activate(scope: scope).map { ($0.id, $0) }); recoveryError = nil }
        catch { recoveryError = "Saved guest actions could not be read. Guest changes are disabled; the saved records have been preserved." }
    }
    func deactivate() { revision = UUID(); busy = false; pending = [:]; recoveryError = nil; scope = nil; journal.deactivate() }
    func retryRecovery() { guard !busy, let scope else { return }; activate(scope: scope) }
    func reconcile(_ snapshot: ChatChannelGuestsSnapshot) throws {
        guard !busy, recoveryError == nil, let record = pending[snapshot.channel.id], record.confirmed(in: snapshot) else { return }
        try journal.remove(record); pending.removeValue(forKey: record.id)
    }
    func dismissPending(_ record: ChatGuestActionRecord) throws {
        guard !busy, recoveryError == nil, pending[record.id] == record else { throw ChatAPIError.connection }
        try journal.remove(record); pending.removeValue(forKey: record.id)
    }
    func perform(_ change: ChatGuestChange, original: ChatChannelGuestsSnapshot,
                 read: () async throws -> ChatChannelGuestsSnapshot,
                 dispatch: (ChatGuestActionRecord) async throws -> Void,
                 check: () throws -> Void) async throws -> ChatChannelGuestsSnapshot {
        guard scope != nil, !busy, recoveryError == nil, pending[original.channel.id] == nil else { throw ChatTransferError(message: "Check the pending guest action before making another change.") }
        let token = revision; busy = true
        defer { if revision == token { busy = false } }
        var record: ChatGuestActionRecord?; var dispatched = false
        let receiptScope = journal.accountScope
        func current() throws { try check(); guard token == revision else { throw CancellationError() }; try Task.checkCancellation() }
        do {
            try current(); let fresh = try await read(); try current()
            guard fresh.accountGeneration == original.accountGeneration, fresh.channel.id == original.channel.id, fresh.channel.supportsGuestBrowser else { throw CancellationError() }
            // Check the selected registration, not unrelated records changed by another client.
            switch change {
            case .expiry(let guest, _), .remove(let guest), .resend(let guest):
                guard original.guests.contains(guest), fresh.guests.contains(guest) else { throw ChatTransferError(message: "This guest registration changed. Refresh before continuing.") }
            case .invite: break
            }
            let intent = try ChatGuestActionRecord(change: change, snapshot: fresh); record = intent
            try journal.remember(intent); pending[intent.id] = intent
            try current(); dispatched = true; try await dispatch(intent); try current()
            if intent.kind == .resend {
                // Only a successful write response confirms the email request. Never infer delivery.
                try journal.remove(intent); pending.removeValue(forKey: intent.id); record = nil
            }
            let after = try await read(); try current()
            if let record {
                guard record.confirmed(in: after) else { throw ChatTransferError(message: "The guest change could not be confirmed.") }
                try journal.remove(record); pending.removeValue(forKey: record.id)
            }
            return after
        } catch {
            if let record, !dispatched {
                do { try journal.removeUndispatched(record, originalScope: receiptScope); if revision == token { pending.removeValue(forKey: record.id) } }
                catch { if revision == token { recoveryError = "The undispatched guest-action record could not be cleared. Refresh or reopen the app before continuing." } }
            }
            guard revision == token else { throw CancellationError() }
            if dispatched, record == nil {
                throw ChatTransferError(message: "The invitation email was requested, but the guest list could not be refreshed. Refresh the list; another email request is not needed. Delivery is not verified.")
            }
            if dispatched, record != nil {
                var detail = ""
                if case .server(let code) = error as? ChatAPIError {
                    switch code {
                    case 504: detail = "Synology Chat reported that guest access is disabled. "
                    case 520: detail = "Synology Chat reported an existing guest registration for this email. "
                    case 521: detail = "Synology Chat reported a problem with its invitation email settings. "
                    default: break
                    }
                }
                throw ChatTransferError(message: detail + "The guest request may have reached Synology Chat. Its pending result was saved. Refresh to check the registrations; no request will be retried automatically.")
            }
            throw error
        }
    }
}
