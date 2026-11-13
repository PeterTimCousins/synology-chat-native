import Foundation
import Darwin

protocol ChatAccountActionRecord: Codable, Equatable, Identifiable {
    static var journalFolder: String { get }
    func validate() throws
    func conflicts(with other:Self)->Bool
    var recoveryLockKeys:[String] { get }
}
extension ChatAccountActionRecord {
    func conflicts(with other:Self)->Bool { id == other.id }
    var recoveryLockKeys:[String] { [String(describing:id)] }
}

/// Persisted uncertainty receipts. Loading a receipt never dispatches an action.
@MainActor final class ChatAccountActionJournal<Record: ChatAccountActionRecord> {
    private struct Envelope: Codable { let version: Int; let scope: String; let records: [Record] }
    private let directory: URL?
    private var scope: String?
    private var records: [Record] = []
    private let memoryLeaseNamespace = UUID().uuidString
    init(directory: URL? = nil) { self.directory = directory }
    static func applicationSupport() -> ChatAccountActionJournal<Record> {
        let bundle = Bundle.main.bundleIdentifier ?? "com.costwisegroup.synology-chat-native"
        return .init(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").appendingPathComponent(bundle).appendingPathComponent(Record.journalFolder))
    }
    func deactivate() { scope = nil; records = [] }
    func activate(scope: String) throws -> [Record] {
        guard ChatNotificationAccountScope.isValid(scope) else { throw ChatAPIError.invalidResponse }
        let memory = directory == nil && self.scope == scope ? records : []
        self.scope = nil; records = memory
        let result = try locked(scope: scope) { try read(scope: scope) }
        self.scope = scope; records = result; return result
    }
    func remember(_ record: Record) throws {
        try record.validate()
        try update { values in
            guard values.count < 128, !values.contains(where: { $0.id == record.id }) else { throw ChatAPIError.invalidResponse }
            return values + [record]
        }
    }
    /// For workflows permitting only one unresolved request per account. The
    /// empty check and insertion share the same lock across app processes.
    func rememberAsOnlyPending(_ record:Record) throws {
        try record.validate()
        try update { values in
            guard values.isEmpty else { throw ChatAPIError.invalidResponse }
            return [record]
        }
    }
    /// Advance a durable checkpoint under one lock, without a remove/remember crash gap.
    func replace(_ expected:Record,with replacement:Record) throws {
        try replacement.validate()
        guard replacement.id == expected.id else { throw ChatAPIError.invalidResponse }
        try update { values in
            guard let index = values.firstIndex(where:{ $0.id == expected.id }),values[index] == expected else { throw ChatAPIError.invalidResponse }
            var result = values;result[index] = replacement;return result
        }
    }
    /// A late known result belongs to its original account, never the newly active one.
    func replaceInScope(_ expected:Record,with replacement:Record,originalScope:String?) throws {
        if originalScope == scope { try replace(expected,with:replacement);return }
        guard let directory else { return }
        guard let originalScope,ChatNotificationAccountScope.isValid(originalScope) else { throw ChatAPIError.invalidResponse }
        let original = ChatAccountActionJournal<Record>(directory:directory)
        _ = try original.activate(scope:originalScope);try original.replace(expected,with:replacement)
    }
    var accountScope: String? { scope }
    func acquireActionLease(for record:Record) throws -> ChatAccountActionLease {
        try record.validate();return try acquireActionLease(keys:record.recoveryLockKeys)
    }
    func acquireActionLease(keys:[String]) throws -> ChatAccountActionLease {
        guard let scope else { throw ChatAPIError.connection }
        return try .init(directory:directory,scope:scope,keys:keys,memoryNamespace:memoryLeaseNamespace)
    }
    /// Cancel a known-undispatched receipt in its original account, even after sign-out.
    func removeUndispatched(_ expected: Record, originalScope: String?) throws {
        if originalScope == scope { try remove(expected); return }
        guard let directory else { return } // The old in-memory session was discarded.
        guard let originalScope, ChatNotificationAccountScope.isValid(originalScope) else { throw ChatAPIError.invalidResponse }
        let original = ChatAccountActionJournal<Record>(directory: directory)
        _ = try original.activate(scope: originalScope)
        try original.remove(expected)
    }
    func remove(_ expected: Record) throws {
        try update { values in
            guard values.first(where: { $0.id == expected.id }).map({ $0 == expected }) ?? true else { throw ChatAPIError.invalidResponse }
            return values.filter { $0.id != expected.id }
        }
    }
    private func update(_ change: ([Record]) throws -> [Record]) throws {
        guard let scope else { guard directory == nil else { throw ChatAPIError.connection }; let updated = try change(records);try validateConflicts(updated);records = updated; return }
        try locked(scope: scope) {
            let values = directory == nil ? records : try read(scope: scope), updated = try change(values)
            try validateConflicts(updated)
            if let directory {
                let file = directory.appendingPathComponent(scope + ".json")
                if FileManager.default.fileExists(atPath: file.path) { guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { throw ChatAPIError.invalidResponse } }
                let data = try JSONEncoder().encode(Envelope(version: 1, scope: scope, records: updated))
                guard data.count <= 128 * 1024 else { throw ChatAPIError.invalidResponse }
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
            }
            records = updated
        }
    }
    private func read(scope: String) throws -> [Record] {
        guard let directory else { return records }
        let file = directory.appendingPathComponent(scope + ".json")
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        guard attrs[.type] as? FileAttributeType == .typeRegular, ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 128 * 1024 else { throw ChatAPIError.invalidResponse }
        let data = try Data(contentsOf: file); guard data.count <= 128 * 1024 else { throw ChatAPIError.invalidResponse }
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        guard decoded.version == 1, decoded.scope == scope, decoded.records.count <= 128, Set(decoded.records.map(\.id)).count == decoded.records.count else { throw ChatAPIError.invalidResponse }
        try decoded.records.forEach { try $0.validate() };try validateConflicts(decoded.records); return decoded.records
    }
    private func validateConflicts(_ values:[Record]) throws {
        for index in values.indices {
            guard !values[..<index].contains(where:{ $0.conflicts(with:values[index]) || values[index].conflicts(with:$0) }) else { throw ChatAPIError.invalidResponse }
        }
    }
    private func locked<T>(scope: String, _ body: () throws -> T) throws -> T {
        guard let directory else { return try body() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory does not update permissions on an existing folder.
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let fd = Darwin.open(directory.appendingPathComponent(scope + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ChatAPIError.connection }; defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ChatAPIError.connection }; defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}
