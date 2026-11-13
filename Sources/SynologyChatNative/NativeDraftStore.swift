import Foundation
import Darwin

/// Local recovery for ordinary text only. Activation requires the verified NAS/account scope.
/// The default store is memory-only; the real app explicitly opts into Application Support.
@MainActor final class NativeDraftStore {
    struct Entry: Codable, Equatable {
        let channelID: Int64
        let rootID: Int64?
        let text: String
        var key: String { rootID.map { "thread:\($0)" } ?? "channel:\(channelID)" }
    }
    private struct Envelope: Codable { let version: Int; let scope: String; let entries: [Entry] }
    static let maximumEntries = 200
    static let maximumTextBytes = 64 * 1024
    static let maximumFileBytes = 2 * 1024 * 1024
    private let directory: URL?
    private var memory: [String: [Entry]] = [:]
    private(set) var scope: String?
    init(directory: URL? = nil) { self.directory = directory }
    static func applicationSupport() -> NativeDraftStore {
        let bundle = Bundle.main.bundleIdentifier ?? "com.costwisegroup.synology-chat-native"
        return .init(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support").appendingPathComponent(bundle).appendingPathComponent("Text Drafts"))
    }
    func deactivate() { scope = nil }
    func activate(scope: String) throws -> [Entry] {
        self.scope = nil
        guard ChatNotificationAccountScope.isValid(scope) else { throw ChatAPIError.invalidResponse }
        let entries: [Entry]
        if directory != nil {
            entries = try withDirectory { fd in
                let file = Darwin.openat(fd, scope + ".json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                if file < 0, errno == ENOENT { return [] }
                guard file >= 0 else { throw ChatAPIError.connection }
                defer { Darwin.close(file) }
                var status = stat()
                guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                      status.st_uid == getuid(), status.st_size >= 0, status.st_size <= Self.maximumFileBytes else { throw ChatAPIError.invalidResponse }
                let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
                let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
                guard data.count <= Self.maximumFileBytes else { throw ChatAPIError.invalidResponse }
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1, envelope.scope == scope else { throw ChatAPIError.invalidResponse }
                return try Self.validate(envelope.entries)
            }
        } else { entries = memory[scope] ?? [] }
        self.scope = scope
        return entries
    }
    func replace(_ entries: [Entry]) throws {
        guard let scope else { return }
        let entries = try Self.validate(entries)
        guard directory != nil else { memory[scope] = entries; return }
        let data = try JSONEncoder().encode(Envelope(version: 1, scope: scope, entries: entries))
        guard data.count <= Self.maximumFileBytes else { throw ChatAPIError.invalidResponse }
        try withDirectory { fd in
            let name = scope + ".json", temporary = ".draft-" + UUID().uuidString
            let file = Darwin.openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard file >= 0 else { throw ChatAPIError.connection }
            defer { Darwin.close(file); _ = unlinkat(fd, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ChatAPIError.connection }; offset += count
                }
            }
            guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0 else { throw ChatAPIError.connection }
            _ = fsync(fd)
        }
    }
    func clear() throws { try replace([]) }
    private static func validate(_ entries: [Entry]) throws -> [Entry] {
        guard entries.count <= maximumEntries, Set(entries.map(\.key)).count == entries.count,
              entries.allSatisfy({ $0.channelID > 0 && ($0.rootID == nil || $0.rootID! > 0) && !$0.text.isEmpty && $0.text.utf8.count <= maximumTextBytes }) else { throw ChatAPIError.invalidResponse }
        return entries
    }
    /// Walk every path component with openat/O_NOFOLLOW; neither file nor directory symlinks are followed.
    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        guard let directory, directory.isFileURL, directory.path.hasPrefix("/") else { throw ChatAPIError.connection }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw ChatAPIError.connection }
        defer { Darwin.close(fd) }
        let components = directory.pathComponents.dropFirst()
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ChatAPIError.connection }
        for component in components {
            var next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0, errno == ENOENT {
                guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw ChatAPIError.connection }
                next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard next >= 0 else { throw ChatAPIError.connection }
            Darwin.close(fd); fd = next
        }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { throw ChatAPIError.connection }
        return try body(fd)
    }
}
