#if DEBUG
import Foundation

/// One bounded real transport test, scoped to the previously authorized Peter DM.
@MainActor
enum ChatUploadCancellationProbe {
    static let resultFile = URL(fileURLWithPath: "/private/tmp/synology-native-upload-cancel-result.json")
    static func run() async -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-chat-cancel-probe-" + UUID().uuidString)
        do {
            let account = try OfficialChatSessionLoader.load()
            guard account.session.baseURL.host?.lowercased() == "costwisegroup.synology.me", account.session.baseURL.port == 2891 else {
                throw ChatTransferError(message: "Authorized NAS does not match. No upload attempted.")
            }
            let api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let people = try await api.users()
            guard people.first(where: { $0.username?.caseInsensitiveCompare(account.username) == .orderedSame })?.user_id == 10 else {
                throw ChatTransferError(message: "Authorized account does not match. No upload attempted.")
            }
            let target = try await ChatAuthorizedTestTarget.peter(api: api, username: account.username)
            guard target.id == 93 else { throw ChatTransferError(message: "Authorized Peter DM does not match. No upload attempted.") }
            let filename = "synology-native-cancel-test-512MiB.bin"
            func matches() async throws -> [ChatPost] {
                try await api.posts(channelID: target.id).filter { $0.creator_id == 10 && $0.type == "file" && $0.file_props?.name == filename }
            }
            guard try await matches().isEmpty else { throw ChatTransferError(message: "A matching test already exists. No repeat upload attempted.") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent(filename)
            guard FileManager.default.createFile(atPath: source.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            let file = try FileHandle(forWritingTo: source)
            try file.truncate(atOffset: 512 * 1024 * 1024)
            try file.close()
            let live = ChatLiveConnection(session: account.session, version: try await api.runtimeVersion())
            defer { live.stop() }
            live.start()
            for _ in 0..<100 where live.connectionID == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            guard let connectionID = live.connectionID else { throw ChatAPIError.connection }
            func staging() throws -> Set<String> {
                Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("native-chat-upload-") })
            }
            let before = try staging()
            let cancellation = ProbeCancellation()
            let transfer = Task<ChatPost, Error> {
                try await api.uploadAttachment(channelID: target.id, file: source,
                    caption: "Native large-upload cancellation check — keep this caption.", connectionID: connectionID,
                    onProgress: { sent, total in cancellation.report(sent: sent, total: total) })
            }
            cancellation.install(transfer)
            var cancelled = false
            var completed: ChatPost?
            var failure: String?
            do { completed = try await transfer.value }
            catch is CancellationError { cancelled = true }
            catch { failure = (error as? ChatTransferError)?.errorDescription ?? (error as? ChatAPIError)?.errorDescription ?? "Transfer failed; details suppressed." }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let first = try await matches()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let second = try await matches()
            let observation = cancellation.observation
            let leftover = try staging().subtracting(before)
            let passed = cancelled && observation != nil && first.isEmpty && second.isEmpty && leftover.isEmpty
            let result: [String: Any] = ["channel_id": target.id, "creator_id": 10, "filename": filename,
                "source_size": 512 * 1024 * 1024, "synthetic_zero_data": true, "temporary_directory": root.path,
                "cancel_requested_after_bytes": observation?.sent ?? 0, "total_body_bytes": observation?.total ?? 0,
                "native_api_cancelled": cancelled, "completed_post_id": completed.map { NSNumber(value: $0.id) } ?? NSNull(),
                "failure": failure as Any? ?? NSNull(), "matching_posts_first": first.map(\.id), "matching_posts_second": second.map(\.id),
                "new_staging_files_leftover": Array(leftover), "passed": passed, "ui_exercised": false,
                "keychain_access": false, "session_revoked": false, "automatic_retry": false]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: resultFile, options: .atomic)
            print(passed ? "Native real upload cancelled while bytes remained; two canonical reads show no matching post, and staging was removed." : "Native cancellation check is inconclusive; retained bounded diagnostic result. No retry.")
            return passed
        } catch {
            print((error as? ChatTransferError)?.errorDescription ?? (error as? ChatAPIError)?.errorDescription ?? "Native upload cancellation probe failed; details suppressed. No retry.")
            return false
        }
    }
}

private final class ProbeCancellation: @unchecked Sendable {
    struct Observation { let sent: Int64; let total: Int64 }
    private let lock = NSLock()
    private var task: Task<ChatPost, Error>?
    private var recorded: Observation?
    var observation: Observation? { lock.lock(); defer { lock.unlock() }; return recorded }
    func install(_ task: Task<ChatPost, Error>) {
        lock.lock(); self.task = task; let pending = recorded != nil; lock.unlock()
        if pending { task.cancel() }
    }
    func report(sent: Int64, total: Int64) {
        lock.lock()
        guard recorded == nil, sent > 0, total > sent else { lock.unlock(); return }
        recorded = Observation(sent: sent, total: total)
        let current = task
        lock.unlock()
        current?.cancel()
    }
}
#endif
