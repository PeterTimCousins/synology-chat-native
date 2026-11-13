import Foundation
import Darwin

/// A receipt journal, never a queue: loading a record must not dispatch its action.
/// Records deliberately omit names, message content, credentials and wrapped keys.
struct ChatChannelActionRecord:Codable,Equatable,Identifiable {
    enum Kind:String,Codable { case archive,close }
    let kind:Kind
    let channelID:Int64
    let channelType:String
    let encrypted:Bool
    let latestPostID:Int64?
    let priorArchiveIDs:[Int64]
    var id:Int64 { channelID }
    func validate() throws {
        guard channelID > 2,["private","public","anonymous"].contains(channelType),
              priorArchiveIDs.count <= 10000,priorArchiveIDs == priorArchiveIDs.sorted(),Set(priorArchiveIDs).count == priorArchiveIDs.count,priorArchiveIDs.allSatisfy({ $0 > 0 }),
              kind != .archive || (channelType == "private" && !encrypted && (latestPostID ?? 0) > 0),
              kind != .close || latestPostID == nil else { throw ChatAPIError.invalidResponse }
    }
    func channel(loaded:[ChatChannel]) throws -> ChatChannel {
        if let current = loaded.first(where:{ $0.id == channelID && $0.type == channelType && $0.encrypted == encrypted }) { return current }
        // A closed channel may no longer be listed. This placeholder permits only
        // receipt checking; no recovered record can dispatch a second mutation.
        let object:[String:Any] = ["channel_id":channelID,"name":"Channel \(channelID)","type":channelType,"encrypted":encrypted,"unread":0,"is_joined":true]
        return try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:object))
    }
}

@MainActor final class ChatChannelActionJournal {
    private struct Envelope:Codable { let version:Int;let accountScope:String;let records:[ChatChannelActionRecord] }
    private let directory:URL?
    private var scope:String?
    private var records:[ChatChannelActionRecord] = []
    static func applicationSupport() -> ChatChannelActionJournal {
        let folder = Bundle.main.bundleIdentifier ?? "com.costwisegroup.synology-chat-native"
        return .init(directory:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").appendingPathComponent(folder).appendingPathComponent("ChannelActions"))
    }
    init(directory:URL? = nil) { self.directory = directory }
    func deactivate() { scope = nil;records = [] }
    func activate(scope:String) throws -> [ChatChannelActionRecord] {
        guard ChatNotificationAccountScope.isValid(scope) else { throw ChatAPIError.invalidResponse }
        self.scope = nil;records = []
        let result = try withLock(scope:scope) { try read(scope:scope) }
        self.scope = scope;records = result;return result
    }
    func remember(_ record:ChatChannelActionRecord) throws {
        try record.validate()
        guard !records.contains(where:{ $0.id == record.id }) else { throw ChatAPIError.invalidResponse }
        try update { current in
            guard !current.contains(where:{ $0.id == record.id }),current.count < 128 else { throw ChatAPIError.invalidResponse }
            return current + [record]
        }
    }
    func remove(_ expected:ChatChannelActionRecord) throws {
        try update { current in
            guard current.first(where:{ $0.id == expected.id }).map({ $0 == expected }) ?? true else { throw ChatAPIError.invalidResponse }
            return current.filter { $0.id != expected.id }
        }
    }
    private func update(_ change:([ChatChannelActionRecord]) throws -> [ChatChannelActionRecord]) throws {
        // Injected-client fixtures have no authenticated account scope and use an
        // in-memory journal. Production connects activate a validated scope first.
        guard let scope else {
            guard directory == nil else { throw ChatAPIError.connection }
            records = try change(records);return
        }
        try withLock(scope:scope) {
            let current = directory == nil ? records : try read(scope:scope)
            let updated = try change(current)
            if let directory {
                let payload = try JSONEncoder().encode(Envelope(version:1,accountScope:scope,records:updated.sorted { $0.id < $1.id }))
                guard payload.count <= 1024*1024 else { throw ChatAPIError.invalidResponse }
                let file = directory.appendingPathComponent(scope+".json")
                try payload.write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                let handle = try FileHandle(forWritingTo:file);defer { try? handle.close() };try handle.synchronize()
            }
            records = updated
        }
    }
    private func read(scope:String) throws -> [ChatChannelActionRecord] {
        guard let directory else { return [] }
        let file = directory.appendingPathComponent(scope+".json")
        let attributes:[FileAttributeKey:Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath:file.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        guard attributes[.type] as? FileAttributeType == .typeRegular,((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024*1024 else { throw ChatAPIError.invalidResponse }
        let data = try Data(contentsOf:file)
        guard data.count <= 1024*1024 else { throw ChatAPIError.invalidResponse }
        let envelope = try JSONDecoder().decode(Envelope.self,from:data)
        guard envelope.version == 1,envelope.accountScope == scope,envelope.records.count <= 128,Set(envelope.records.map(\.id)).count == envelope.records.count else { throw ChatAPIError.invalidResponse }
        try envelope.records.forEach { try $0.validate() };return envelope.records
    }
    private func withLock<T>(scope:String,_ body:() throws -> T) throws -> T {
        guard let directory else { return try body() }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor = Darwin.open(directory.appendingPathComponent(scope+".lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard descriptor >= 0 else { throw ChatAPIError.connection }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor,LOCK_EX|LOCK_NB) == 0 else { throw ChatAPIError.connection }
        defer { _ = flock(descriptor,LOCK_UN) }
        return try body()
    }
}
