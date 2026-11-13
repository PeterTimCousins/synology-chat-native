import Foundation
import Combine

/// A transfer receipt, never a stored NAS URL or session credential.
@MainActor final class ChatDownloadRecord: ObservableObject, Identifiable {
    enum State: String { case choosing, transferring, verifying, saved, cancelled, failed
        var active: Bool { [.choosing, .transferring, .verifying].contains(self) }
    }
    let id: UUID
    let postID: Int64
    let channelID: Int64
    @Published var filename: String
    let encrypted: Bool
    let startedAt: Date
    @Published var state: State = .choosing
    @Published var destination: URL?
    @Published var received: Int64 = 0
    @Published var expected: Int64 = 0
    @Published var fileBytes: Int64?
    @Published var available = true
    @Published var failure: String?
    init(id: UUID, postID: Int64, channelID: Int64, filename: String, encrypted: Bool, startedAt: Date) { self.id = id; self.postID = postID; self.channelID = channelID; self.filename = filename; self.encrypted = encrypted; self.startedAt = startedAt }
    var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    var progressLabel: String {
        switch state {
        case .choosing: return "Choosing save location…"
        case .verifying: return "Checking and saving…"
        case .saved: return available ? "Saved" + (fileBytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "") : "File is no longer at its saved location"
        case .failed: return failure ?? "Download failed"
        case .cancelled: return "Cancelled"
        case .transferring:
            let amount = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            return expected > 0 ? amount + " of " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : received > 0 ? amount : "Downloading…"
        }
    }
    func progress(received: Int64, expected: Int64) {
        guard state == .transferring, received >= self.received, received >= 0 else { return }
        self.received = received
        if expected > 0 { self.expected = max(received, expected) }
    }
}

typealias ChatDownloadProgressCallback = @Sendable (Int64, Int64) -> Void

/// Throttle UI work without losing a final known-size progress update.
final class ChatDownloadProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int64 = -1
    private var expected: Int64 = 0
    private var emittedAt: TimeInterval = -.infinity
    private let callback: ChatDownloadProgressCallback
    init(_ callback: @escaping ChatDownloadProgressCallback) { self.callback = callback }
    func snapshot() -> (received: Int64, expected: Int64) { lock.lock(); defer { lock.unlock() }; return (max(0, received), expected) }
    func update(received: Int64, expected: Int64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        guard received >= 0, received >= self.received else { lock.unlock(); return }
        self.received = received; if expected > 0 { self.expected = max(expected, received) }
        guard now - emittedAt >= 0.1 || expected > 0 && received >= expected else { lock.unlock(); return }
        emittedAt = now; lock.unlock(); callback(received, expected)
    }
}

@MainActor final class ChatDownloadPreferences: ObservableObject {
    static let folderKey = "nativeDownloads.lastFolder"
    @Published private(set) var lastFolder: URL?
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let path = defaults?.string(forKey: Self.folderKey), path.hasPrefix("/"), !path.contains("\0") { lastFolder = URL(fileURLWithPath: path, isDirectory: true) }
    }
    var initialFolder: URL? { lastFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }
    static func standard() -> ChatDownloadPreferences { .init(defaults: .standard) }
    func chooseFolder(_ url: URL) {
        guard ChatSavedDownloadFile.validDestination(url) else { return }
        lastFolder = URL(fileURLWithPath: url.path, isDirectory: true); defaults?.set(lastFolder?.path, forKey: Self.folderKey)
    }
    func remember(destination: URL) { guard destination.isFileURL else { return }; chooseFolder(destination.deletingLastPathComponent()) }
    func reset() { lastFolder = nil; defaults?.removeObject(forKey: Self.folderKey) }
}


enum ChatSavedDownloadFile {
    static func validDestination(_ url: URL) -> Bool {
        url.isFileURL && (url.host?.isEmpty != false || url.host?.lowercased() == "localhost") && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && url.path.hasPrefix("/") && !url.path.contains("\0")
    }
    static func available(_ url: URL) -> Bool {
        guard validDestination(url), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }
}
