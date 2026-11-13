import Foundation
import Combine
import CryptoKit

struct ChatEncryptionManagementSnapshot {
    let owner: ChatEncryptionOwnerState
    let accountGeneration: Int
    let connectionID: String?
}
enum ChatEncryptionChange {
    case setup(password: String, confirmation: String)
    case rewrap(oldPassword: String, password: String, confirmation: String)
    var requiresConnection: Bool {
        if case .rewrap = self { return true }
        return false
    }
}

/// A private uncertainty receipt contains only intent and fingerprints, never a
/// password, raw private key or server-wrapped private key. Loading cannot write.
struct ChatEncryptionWriteRecord: ChatAccountActionRecord {
    enum Kind: String, Codable { case setup, rewrap }
    static let journalFolder = "EncryptionChanges"
    let ownerID: Int64
    let kind: Kind
    let originalFingerprint: String
    let desiredFingerprint: String
    let operationID: UUID
    var id: Int64 { ownerID }

    init(ownerID: Int64, plan: ChatEncryptionManagement.Plan) throws {
        self.ownerID = ownerID
        switch plan.operation {
        case .initialSetup: kind = .setup
        case .passwordRewrap: kind = .rewrap
        case .keyRenewal: throw ChatAPIError.unsupportedAPI
        }
        originalFingerprint = Self.pairFingerprint(plan.original)
        desiredFingerprint = Self.pairFingerprint(plan.replacement)
        operationID = UUID()
        try validate()
    }
    static func pairFingerprint(_ pair: ChatEncryptionKeyPair) -> String {
        var bytes = Data("SynologyChatEncryptionPair\0".utf8)
        for value in [pair.public_key, pair.private_key_enc] {
            let data = Data(value.utf8)
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        guard ownerID > 0, Self.validFingerprint(originalFingerprint), Self.validFingerprint(desiredFingerprint),
              originalFingerprint != desiredFingerprint else { throw ChatAPIError.invalidResponse }
    }
    private static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func confirmed(in snapshot: ChatEncryptionManagementSnapshot) -> Bool {
        snapshot.owner.userID == ownerID && Self.pairFingerprint(snapshot.owner.pair) == desiredFingerprint
    }
}
typealias ChatEncryptionWriteJournal = ChatAccountActionJournal<ChatEncryptionWriteRecord>

@MainActor final class ChatEncryptionChangeCoordinator: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var pending: ChatEncryptionWriteRecord?
    @Published private(set) var recoveryError: String?
    private let journal: ChatEncryptionWriteJournal
    private var scope: String?
    private var ownerID: Int64?
    private var revision = UUID()

    init(journal: ChatEncryptionWriteJournal? = nil) { self.journal = journal ?? .init() }
    func activate(scope: String?, ownerID: Int64?) {
        revision = UUID(); busy = false; pending = nil
        self.scope = scope; self.ownerID = ownerID
        guard let scope, ChatNotificationAccountScope.isValid(scope), let ownerID, ownerID > 0 else {
            journal.deactivate()
            recoveryError = "Encryption changes are disabled until this account can be identified for saved-action recovery."
            return
        }
        do {
            let records = try journal.activate(scope: scope)
            guard records.count <= 1, records.allSatisfy({ $0.ownerID == ownerID }) else { throw ChatAPIError.invalidResponse }
            pending = records.first; recoveryError = nil
        } catch {
            recoveryError = "Saved encryption changes could not be read. Changes are disabled; saved records have been preserved."
        }
    }
    func deactivate() {
        revision = UUID(); busy = false; pending = nil; recoveryError = nil
        scope = nil; ownerID = nil; journal.deactivate()
    }
    func retryRecovery() {
        guard !busy, let scope, let ownerID else { return }
        activate(scope: scope, ownerID: ownerID)
    }
    /// The caller must supply a fresh account/generation-guarded strict read.
    /// Original state, read failures and unknown outcomes cannot dismiss intent.
    func reconcile(_ snapshot: ChatEncryptionManagementSnapshot) throws {
        guard !busy, recoveryError == nil, snapshot.owner.userID == ownerID,
              let pending, pending.confirmed(in: snapshot) else { return }
        try journal.remove(pending); self.pending = nil
    }
    func perform(_ change: ChatEncryptionChange, original: ChatEncryptionManagementSnapshot,
                 read: () async throws -> ChatEncryptionManagementSnapshot,
                 dispatch: (ChatEncryptionManagement.Plan, String?) async throws -> Void,
                 check: () throws -> Void) async throws -> ChatEncryptionManagementSnapshot {
        guard scope != nil, let ownerID, ownerID == original.owner.userID,
              !busy, recoveryError == nil, pending == nil else {
            throw ChatTransferError(message: "Refresh to check the pending encryption change before making another change.")
        }
        let token = revision, receiptScope = journal.accountScope
        busy = true
        defer { if revision == token { busy = false } }
        var record: ChatEncryptionWriteRecord?
        var dispatched = false
        func current() throws {
            try check(); try Task.checkCancellation()
            guard token == revision, self.ownerID == ownerID, scope == receiptScope else { throw CancellationError() }
        }
        do {
            try current()
            let fresh = try await read()
            try current()
            guard fresh.owner.userID == ownerID, fresh.accountGeneration == original.accountGeneration else { throw CancellationError() }
            guard fresh.owner == original.owner else {
                throw ChatTransferError(message: "Encryption keys changed in another client. Refresh before continuing.")
            }
            let connectionID: String?
            if change.requiresConnection {
                guard let value = fresh.connectionID, !value.isEmpty, value == original.connectionID else {
                    throw ChatTransferError(message: "The live connection changed. Refresh before changing the encryption password.")
                }
                connectionID = value
            } else { connectionID = nil }
            let plan: ChatEncryptionManagement.Plan
            switch change {
            case .setup(let password, let confirmation):
                plan = try ChatEncryptionManagement.initialPlan(existing: fresh.owner.pair, password: password, confirmation: confirmation)
            case .rewrap(let oldPassword, let password, let confirmation):
                plan = try ChatEncryptionManagement.passwordRewrapPlan(existing: fresh.owner.pair,
                    oldPassword: oldPassword, password: password, confirmation: confirmation)
            }
            let intent = try ChatEncryptionWriteRecord(ownerID: ownerID, plan: plan)
            record = intent
            try journal.remember(intent)
            pending = intent
            try current()
            dispatched = true
            try await dispatch(plan, connectionID)
            try current()
            let after = try await read()
            try current()
            guard after.accountGeneration == original.accountGeneration, after.owner.userID == ownerID else { throw CancellationError() }
            guard intent.confirmed(in: after) else {
                throw ChatTransferError(message: "The encryption change could not be confirmed.")
            }
            try journal.remove(intent)
            pending = nil
            return after
        } catch {
            if let record, !dispatched {
                do {
                    try journal.removeUndispatched(record, originalScope: receiptScope)
                    if revision == token { pending = nil }
                } catch {
                    if revision == token {
                        recoveryError = "The undispatched encryption record could not be cleared. Refresh saved-action recovery before continuing."
                    }
                }
            }
            guard revision == token else { throw CancellationError() }
            if dispatched {
                throw ChatTransferError(message: "The encryption change may have reached Synology Chat. Its pending result was saved. Refresh to check the keys; it will not be retried automatically.")
            }
            throw error
        }
    }
}
