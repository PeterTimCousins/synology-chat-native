import Foundation
import Combine
import CryptoKit

/// This identity deliberately includes encrypted archives without attempting to
/// decrypt them. Archive visibility never implies permission to delete it.
struct ChatArchiveDeletionRecord: ChatAccountActionRecord {
    static let journalFolder = "ArchiveDeletions"
    let archiveID: Int64
    let ownerID: Int64
    let kind: String
    let name: String
    let fingerprint: String
    let operationID: UUID
    var id: Int64 { archiveID }
    var archiveKind: ChatArchiveKind? { ChatArchiveKind(rawValue: kind) }

    init(archive: ChatArchive, kind: ChatArchiveKind, name: String, ownerID: Int64) throws {
        archiveID = archive.id; self.ownerID = ownerID; self.kind = kind.rawValue
        self.name = name; operationID = UUID()
        fingerprint = try Self.identity(archive, kind: kind, name: name)
        try validate()
    }
    func validate() throws {
        guard archiveID > 0, ownerID > 0, archiveKind != nil,
              Self.validName(name), fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ChatAPIError.invalidResponse }
    }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 4096 && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func identity(_ archive: ChatArchive, kind: ChatArchiveKind, name: String) throws -> String {
        let c = archive.props.channel
        guard validName(name), archive.id > 0, c.id > 0, c.type == kind.rawValue,
              c.name.utf8.count <= 4096, archive.props.reason.utf8.count <= 256,
              !archive.props.reason.isEmpty, archive.props.trigger_user_id >= 0,
              archive.post_start.isFinite, archive.post_end.isFinite,
              archive.post_start >= 0, archive.post_end >= archive.post_start,
              archive.post_id_start >= 0, archive.post_id_end >= archive.post_id_start
        else { throw ChatAPIError.invalidResponse }
        // Length framing preserves exact UTF-8 distinctions and delimiter bytes.
        var bytes = Data("SynologyChatArchiveDeletion-v1\0".utf8)
        for value in [kind.rawValue, name, String(archive.id), String(c.id), c.type, c.name,
                      c.encrypted ? "1" : "0", String(archive.post_start.bitPattern), String(archive.post_end.bitPattern),
                      String(archive.post_id_start), String(archive.post_id_end), archive.props.reason,
                      String(archive.props.trigger_user_id)] {
            let data = Data(value.utf8); var size = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }; bytes.append(data)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func validateList(_ list: [ChatArchive], kind: ChatArchiveKind, name: String) throws {
        guard list.count <= 10_000, Set(list.map(\.id)).count == list.count else { throw ChatAPIError.invalidResponse }
        // Validate the scope even for an empty result; [] must be a successful,
        // decoded list supplied by the caller, never a fallback for a failed read.
        guard validName(name) else { throw ChatAPIError.invalidResponse }
        for archive in list { _ = try identity(archive, kind: kind, name: name) }
    }
}
typealias ChatArchiveDeletionJournal = ChatAccountActionJournal<ChatArchiveDeletionRecord>

struct ChatArchiveDeletionPreparation {
    let archive: ChatArchive
    let kind: ChatArchiveKind
    let name: String
    let accountGeneration: Int
    fileprivate let record: ChatArchiveDeletionRecord
    fileprivate let coordinatorRevision: UUID
    fileprivate let scope: String
}

@MainActor final class ChatArchiveDeletionCoordinator: ObservableObject {
    typealias Load = (ChatArchiveKind, String) async throws -> [ChatArchive]
    @Published private(set) var busy = false
    @Published private(set) var pending: [ChatArchiveDeletionRecord] = []
    @Published private(set) var recoveryError: String?
    private let journal: ChatArchiveDeletionJournal
    private var scope: String?
    private var ownerID: Int64?
    private var revision = UUID()

    init(journal: ChatArchiveDeletionJournal? = nil) { self.journal = journal ?? .init() }
    func activate(scope: String?, ownerID: Int64?) {
        revision = UUID(); busy = false; pending = []; self.scope = scope; self.ownerID = ownerID
        guard let scope, ChatNotificationAccountScope.isValid(scope), let ownerID, ownerID > 0 else {
            journal.deactivate(); recoveryError = "Archive deletion is disabled until this account can be identified for saved-action recovery."; return
        }
        do {
            let records = try journal.activate(scope: scope)
            guard records.allSatisfy({ $0.ownerID == ownerID }) else { throw ChatAPIError.invalidResponse }
            pending = records; recoveryError = nil
        } catch { recoveryError = "Saved archive deletions could not be read. Records have been preserved and deletion is disabled." }
    }
    func deactivate() {
        revision = UUID(); busy = false; pending = []; recoveryError = nil
        scope = nil; ownerID = nil; journal.deactivate()
    }
    func retryRecovery() {
        guard !busy, let scope, let ownerID else { return }; activate(scope: scope, ownerID: ownerID)
    }
    private func current(_ token: UUID, scope: String, ownerID: Int64, check: () throws -> Void) throws {
        try check(); try Task.checkCancellation()
        guard revision == token, self.scope == scope, self.ownerID == ownerID else { throw CancellationError() }
    }
    func prepare(archive: ChatArchive, kind: ChatArchiveKind, name: String, accountGeneration: Int,
                 load: Load, checkCurrent: () throws -> Void) async throws -> ChatArchiveDeletionPreparation {
        guard !busy, recoveryError == nil, let scope, let ownerID,
              !pending.contains(where: { $0.id == archive.id }) else { throw ChatTransferError(message: "Check the saved archive deletion before continuing.") }
        let token = revision
        busy = true; defer { if token == revision { busy = false } }
        try current(token, scope: scope, ownerID: ownerID, check: checkCurrent)
        let record = try ChatArchiveDeletionRecord(archive: archive, kind: kind, name: name, ownerID: ownerID)
        let list = try await load(kind, name)
        try current(token, scope: scope, ownerID: ownerID, check: checkCurrent)
        try Self.match(record, in: list)
        return .init(archive: archive, kind: kind, name: name, accountGeneration: accountGeneration,
                     record: record, coordinatorRevision: token, scope: scope)
    }
    private static func match(_ record: ChatArchiveDeletionRecord, in list: [ChatArchive]) throws {
        guard let kind = record.archiveKind else { throw ChatAPIError.invalidResponse }
        try ChatArchiveDeletionRecord.validateList(list, kind: kind, name: record.name)
        guard let archive = list.first(where: { $0.id == record.id }),
              try ChatArchiveDeletionRecord.identity(archive, kind: kind, name: record.name) == record.fingerprint
        else { throw ChatTransferError(message: "This archive changed or is no longer available. Refresh before deleting it.") }
    }
    func delete(_ preparation: ChatArchiveDeletionPreparation, load: Load,
                dispatch: (Int64) async throws -> Void, checkCurrent: () throws -> Void) async throws {
        let record = preparation.record, token = revision, receiptScope = journal.accountScope
        guard !busy, recoveryError == nil, let scope, scope == preparation.scope,
              token == preparation.coordinatorRevision, record.ownerID == ownerID,
              !pending.contains(where: { $0.id == record.id }) else { throw CancellationError() }
        busy = true; defer { if token == revision { busy = false } }
        var remembered = false, dispatched = false, rejected = false
        do {
            try current(token, scope: scope, ownerID: record.ownerID, check: checkCurrent)
            let fresh = try await load(preparation.kind, preparation.name)
            try current(token, scope: scope, ownerID: record.ownerID, check: checkCurrent)
            try Self.match(record, in: fresh)
            try journal.remember(record); remembered = true; pending.append(record)
            try current(token, scope: scope, ownerID: record.ownerID, check: checkCurrent)
            dispatched = true
            do { try await dispatch(record.id) }
            catch {
                if case .server = error as? ChatAPIError { rejected = true }
                throw error
            }
            try current(token, scope: scope, ownerID: record.ownerID, check: checkCurrent)
            let after = try await load(preparation.kind, preparation.name)
            try current(token, scope: scope, ownerID: record.ownerID, check: checkCurrent)
            guard try resolve(record, list: after) else { throw ChatTransferError(message: "The archive deletion could not be confirmed.") }
        } catch {
            if remembered && (!dispatched || rejected) {
                do {
                    try journal.removeUndispatched(record, originalScope: receiptScope)
                    if token == revision { pending.removeAll { $0 == record } }
                } catch { if token == revision { recoveryError = "The undispatched deletion record could not be cleared. Refresh saved-action recovery before continuing." } }
            }
            guard token == revision else { throw CancellationError() }
            if dispatched && !rejected { throw ChatTransferError(message: "The archive deletion may have reached Synology Chat. Its pending result was saved. Check its status; it will not be retried automatically.") }
            throw error
        }
    }
    /// Read-only recovery. A present or changed archive cannot dismiss intent.
    @discardableResult func checkOutcome(_ record: ChatArchiveDeletionRecord, load: Load,
                                        checkCurrent: () throws -> Void) async throws -> Bool {
        guard !busy, recoveryError == nil, let scope, record.ownerID == ownerID,
              pending.contains(record), let kind = record.archiveKind else { throw CancellationError() }
        let token = revision
        busy = true; defer { if token == revision { busy = false } }
        try current(token, scope: scope, ownerID: record.ownerID, check: checkCurrent)
        let after = try await load(kind, record.name)
        try current(token, scope: scope, ownerID: record.ownerID, check: checkCurrent)
        return try resolve(record, list: after)
    }
    private func resolve(_ record: ChatArchiveDeletionRecord, list: [ChatArchive]) throws -> Bool {
        guard let kind = record.archiveKind else { throw ChatAPIError.invalidResponse }
        try ChatArchiveDeletionRecord.validateList(list, kind: kind, name: record.name)
        guard !list.contains(where: { $0.id == record.id }) else { return false }
        try journal.remove(record); pending.removeAll { $0 == record }; return true
    }
}

extension ChatAPIClient {
    /// The backend remains the ACL authority, including public-archive admin access.
    func deleteArchive(id: Int64) async throws {
        guard id > 0 else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.Archive", method: "delete", version: 1, parameters: ["archive_id": .integer(id)])
    }
}
