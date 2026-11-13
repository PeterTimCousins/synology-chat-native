import Foundation
import Combine
import Darwin

enum ChatSavedFileOpeningError: LocalizedError, Equatable {
    case unavailable, changed, couldNotOpen
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This downloaded file is no longer available as a regular local file. Save it again before opening it."
        case .changed: return "This downloaded file changed while you were reviewing it. Review it again before opening it."
        case .couldNotOpen: return "This downloaded file could not be opened on this Mac."
        }
    }
}

/// Native trusted-user actions require one review, with no Electron-style
/// attention timer, silent cooldown or automatic retry. Workspace effects and
/// the actual alert are supplied by the owner, which must cancel its alert on
/// account retirement and capture the current account/download/key scope.
@MainActor final class ChatSavedFileOpening: ObservableObject {
    struct Review {
        let localURL: URL
        let displayName: String
    }
    enum Decision: Equatable { case open, reveal, cancel }
    enum Result: Equatable { case opened, revealed, cancelled, busy }
    @Published private(set) var busy = false
    private var revision = UUID()

    func retire() { revision = UUID(); busy = false }

    func request(url: URL, checkCurrent: () throws -> Void,
                 confirm: (Review) async -> Decision,
                 open: (URL) -> Bool, reveal: (URL) -> Void) async throws -> Result {
        guard !busy else { return .busy }
        let token = revision
        busy = true
        defer { if token == revision { busy = false } }
        func current() throws {
            try Task.checkCancellation()
            guard token == revision else { throw CancellationError() }
            try checkCurrent()
            guard token == revision else { throw CancellationError() }
            try Task.checkCancellation()
        }
        try current()
        let original = try await Self.readIdentity(url)
        try current()
        let decision = await confirm(.init(localURL: url, displayName: Self.displayName(url.lastPathComponent)))
        try current()
        if case .cancel = decision { return .cancelled }
        let fresh = try await Self.readIdentity(url)
        try current()
        guard fresh == original else { throw ChatSavedFileOpeningError.changed }
        // No await between the final owner check and the single local effect.
        try current()
        switch decision {
        case .open:
            guard open(url) else { throw ChatSavedFileOpeningError.couldNotOpen }
            return .opened
        case .reveal:
            reveal(url); return .revealed
        case .cancel: return .cancelled
        }
    }
    /// Reveal stays available while an Open review is pending. It neither owns
    /// nor changes that review's busy state and never opens the file.
    func reveal(url: URL, checkCurrent: () throws -> Void, reveal: (URL) -> Void) async throws -> Result {
        let token = revision
        func current() throws {
            try Task.checkCancellation()
            guard token == revision else { throw CancellationError() }
            try checkCurrent()
            guard token == revision else { throw CancellationError() }
            try Task.checkCancellation()
        }
        try current()
        let original = try await Self.readIdentity(url)
        try current()
        let fresh = try await Self.readIdentity(url)
        try current()
        guard fresh == original else { throw ChatSavedFileOpeningError.changed }
        try current()
        reveal(url)
        return .revealed
    }
    static func displayName(_ basename: String) -> String {
        let clean = basename.unicodeScalars.reduce(into: "") { text, scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: break
            default: text.unicodeScalars.append(scalar)
            }
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Downloaded file" : clean
    }
    private struct FileIdentity: Equatable, Sendable {
        let resolvedPath: String
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }
    nonisolated private static func readIdentity(_ url: URL) async throws -> FileIdentity {
        try Task.checkCancellation()
        // Mounted paths may take longer than a local stat; keep that I/O off the
        // main actor, then require the owner/revision to be current after await.
        return try await Task.detached(priority: .utility) { try identity(url) }.value
    }
    nonisolated private static func identity(_ url: URL) throws -> FileIdentity {
        guard ChatSavedDownloadFile.validDestination(url), !url.lastPathComponent.isEmpty else { throw ChatSavedFileOpeningError.unavailable }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = parent.appendingPathComponent(url.lastPathComponent)
        let first = try metadata(url.path, resolvedPath: resolved.path)
        // Inspect the final component with lstat, preserving legitimate parent
        // symlinks such as /tmp and /var while refusing a symlink leaf.
        let canonical = try metadata(resolved.path, resolvedPath: resolved.path)
        let parentAgain = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let last = try metadata(url.path, resolvedPath: resolved.path)
        guard first == canonical, first == last, parent.path == parentAgain.path else { throw ChatSavedFileOpeningError.changed }
        return first
    }
    nonisolated private static func metadata(_ path: String, resolvedPath: String) throws -> FileIdentity {
        var info = stat()
        guard path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0 else { throw ChatSavedFileOpeningError.unavailable }
        return .init(resolvedPath: resolvedPath, device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size,
                     modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                     changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}
